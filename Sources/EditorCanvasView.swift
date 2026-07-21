import AppKit

// MARK: - selection model

enum SelectShape: String, CaseIterable {
    case pan          // Pan / Scroll mode (not a shape)
    case rectangle
    case oval
    case freehand     // drag lasso
    case polygon      // "Freehand 2": click-to-add-vertex, double-click closes
    case rrect        // rounded rectangle

    var label: String {
        switch self {
        case .pan: return "Pan / Scroll"
        case .rectangle: return "Rectangle"
        case .oval: return "Circle"
        case .freehand: return "Freehand"
        case .polygon: return "Freehand 2"
        case .rrect: return "R-Rectangle"
        }
    }

    var symbolName: String {
        switch self {
        case .pan: return "hand.raised"
        case .rectangle: return "rectangle.dashed"
        case .oval: return "circle.dashed"
        case .freehand: return "lasso"
        case .polygon: return "point.topleft.down.to.point.bottomright.curvepath"
        case .rrect: return "rectangle.roundedtop"
        }
    }
}

/// A selection in image pixel coords (top-left origin).
struct EditorSelection {
    var shape: SelectShape
    var rect: CGRect = .zero        // rectangle / oval / rrect
    var points: [CGPoint] = []      // freehand / polygon (closed)
    /// When set (Invert Selection), overrides `cgPath` with a raw even-odd
    /// path — the image rect with the original selection punched out as a hole.
    var rawPath: CGPath? = nil

    /// True while this is an inverted (image-minus-shape) selection. Callers
    /// must clip / fill it with the even-odd rule so the hole reads correctly.
    var isInverted: Bool { rawPath != nil }

    var bounds: CGRect {
        if let rawPath { return rawPath.boundingBox }
        switch shape {
        case .freehand, .polygon:
            var r = CGRect.null
            for p in points { r = r.union(CGRect(origin: p, size: .zero)) }
            return r
        default:
            return rect.standardized
        }
    }

    var cgPath: CGPath {
        if let rawPath { return rawPath }
        let path = CGMutablePath()
        switch shape {
        case .oval:
            path.addEllipse(in: rect.standardized)
        case .rrect:
            let r = rect.standardized
            path.addRoundedRect(in: r, cornerWidth: min(12, r.width / 2),
                                cornerHeight: min(12, r.height / 2))
        case .freehand, .polygon:
            guard points.count >= 3 else { break }
            path.move(to: points[0])
            for p in points.dropFirst() { path.addLine(to: p) }
            path.closeSubpath()
        default:
            path.addRect(rect.standardized)
        }
        return path
    }

    var isRectangular: Bool { shape == .rectangle && rawPath == nil }

    mutating func translate(by d: CGPoint) {
        rect.origin.x += d.x
        rect.origin.y += d.y
        points = points.map { CGPoint(x: $0.x + d.x, y: $0.y + d.y) }
        if let rawPath {
            var t = CGAffineTransform(translationX: d.x, y: d.y)
            self.rawPath = rawPath.copy(using: &t)
        }
    }
}

/// Selection content lifted off the background (moving / copying / pasting).
private struct FloatingContent {
    var image: CGImage
    var origin: CGPoint          // top-left, image coords
    var holePath: CGPath?        // filled white on anchor (move; nil for copy/paste)
}

// MARK: - delegate

@MainActor
protocol EditorCanvasDelegate: AnyObject {
    func canvasSelectionChanged(_ selection: CGRect?)
    func canvasRequestsCrop()
    func canvasKeyCommand(_ key: String)
    func canvasCanvasResized()
}

// MARK: - canvas

/// Editor canvas (Select Mode): composited document + selection interactions +
/// draggable canvas edges. Lives inside a CenteringClipView so the image sits
/// centered with padding around it.
@MainActor
final class EditorCanvasView: NSView {
    weak var delegate: EditorCanvasDelegate?

    var document: EditorDocument? {
        didSet {
            selection = nil
            floating = nil
            refreshFromDocument()
        }
    }

    var selectShape: SelectShape = .rectangle {
        didSet {
            if selectShape == .pan { commitSelectionState(clear: true) }
            polygonDraft = []
            needsDisplay = true
        }
    }

    private(set) var selection: EditorSelection? {
        didSet { delegate?.canvasSelectionChanged(selection?.bounds) }
    }

    /// Back-compat accessor used by the window controller (crop/copy/status).
    var selectionRect: CGRect? { selection?.bounds }

    private var floating: FloatingContent?
    private var compositedCache: NSImage?
    private var polygonDraft: [CGPoint] = []
    private var mousePos: CGPoint = .zero

    // Clone-stamp tool (minimal TCloneWin): ⌥-click sets the source, drag paints
    // a round brush copying pixels from source+offset onto the image.
    private(set) var cloneMode = false
    private var cloneSource: CGPoint?     // image top-left coords
    private var cloneOffset: CGPoint?     // dest − source, fixed per stroke
    private var cloneCtx: CGContext?      // live stroke buffer (bottom-left origin)
    private var cloneSnapshot: CGImage?   // pixels sampled during the stroke
    private var cloneLast: CGPoint?
    private let cloneRadius: CGFloat = 24

    private enum Drag {
        case none
        case creating(start: CGPoint)
        case lasso
        case movingContent(last: CGPoint)
        case movingFrame(last: CGPoint)
        case resizingCanvas(edges: NSEdgeInsets0, start: CGPoint, preview: CGRect)
        case panning(last: CGPoint)  // window coords
    }
    private var drag: Drag = .none

    struct NSEdgeInsets0 {
        var left = false, right = false, top = false, bottom = false
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var trackingArea: NSTrackingArea?

    /// Claim clicks slightly OUTSIDE the canvas too, so the edge/corner
    /// handles (which sit exactly on the frame boundary) are grabbable from
    /// both sides — AppKit's default hit test excludes the max edges.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        let t = tol(14)
        return bounds.insetBy(dx: -t, dy: -t).contains(local) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    // MARK: document sync

    func refreshFromDocument() {
        guard let doc = document else {
            compositedCache = nil
            setFrameSize(.zero)
            needsDisplay = true
            return
        }
        let img = doc.composited
        compositedCache = NSImage(cgImage: img, size: doc.pixelSize)
        setFrameSize(doc.pixelSize)
        needsDisplay = true
    }

    private var magnification: CGFloat {
        enclosingScrollView?.magnification ?? 1
    }

    /// Screen-stable tolerance expressed in image px.
    private func tol(_ px: CGFloat) -> CGFloat { px / max(magnification, 0.01) }

    // MARK: public ops (called from the window controller)

    func clearSelection() {
        commitSelectionState(clear: true)
        needsDisplay = true
    }

    func selectAll2() {
        guard let doc = document else { return }
        anchorFloating()
        selection = EditorSelection(shape: .rectangle,
                                    rect: CGRect(origin: .zero, size: doc.pixelSize))
        needsDisplay = true
    }

    // MARK: clone tool

    /// Enter/leave the clone-stamp mode. While active the canvas ignores the
    /// selection gestures and paints instead.
    func toggleCloneMode() {
        cloneMode.toggle()
        if cloneMode {
            commitSelectionState(clear: true)
        } else {
            endCloneStroke(commit: false)
            cloneSource = nil
        }
        cloneOffset = nil
        window?.invalidateCursorRects(for: self)
        OutputRouter.notifyHUD(cloneMode
            ? Loc.t("克隆工具：按住 ⌥ 点击设定源，拖拽绘制（再按 C 退出）",
                    "Clone tool: ⌥-click to set the source, then drag to paint (press C again to exit)")
            : Loc.t("已退出克隆工具", "Exited clone tool"))
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func cloneMouseDown(_ event: NSEvent) {
        guard let doc = document else { return }
        let p = clamp(convert(event.locationInWindow, from: nil))
        if event.modifierFlags.contains(.option) {
            cloneSource = p
            cloneOffset = nil
            OutputRouter.notifyHUD(Loc.t("克隆源已设置", "Clone source set"))
            needsDisplay = true
            return
        }
        guard let src = cloneSource else {
            OutputRouter.notifyHUD(Loc.t("先按住 ⌥ 点击设定克隆源", "⌥-click to set the clone source first"))
            return
        }
        // Begin a stroke: snapshot the current composited pixels and paint into
        // a live buffer so the whole stroke is one undo step.
        let snap = doc.composited
        cloneSnapshot = snap
        let w = snap.width, h = snap.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.draw(snap, in: CGRect(x: 0, y: 0, width: w, height: h))
        cloneCtx = ctx
        cloneOffset = CGPoint(x: p.x - src.x, y: p.y - src.y)
        cloneLast = nil
        clonePaint(to: p)
    }

    private func clonePaint(to point: CGPoint) {
        guard let ctx = cloneCtx, let snap = cloneSnapshot, let offset = cloneOffset else { return }
        let w = CGFloat(snap.width), h = CGFloat(snap.height)
        let from = cloneLast ?? point
        let dist = hypot(point.x - from.x, point.y - from.y)
        let steps = max(1, Int(dist / (cloneRadius / 3)))
        for s in 0...steps {
            let t = CGFloat(s) / CGFloat(steps)
            let d = CGPoint(x: from.x + (point.x - from.x) * t,
                            y: from.y + (point.y - from.y) * t)
            ctx.saveGState()
            // Circle center in bottom-left buffer coords.
            let cx = d.x, cy = h - d.y
            ctx.addEllipse(in: CGRect(x: cx - cloneRadius, y: cy - cloneRadius,
                                      width: cloneRadius * 2, height: cloneRadius * 2))
            ctx.clip()
            // Draw the snapshot shifted so source pixel (d − offset) lands at d.
            ctx.draw(snap, in: CGRect(x: offset.x, y: -offset.y, width: w, height: h))
            ctx.restoreGState()
        }
        cloneLast = point
        if let img = ctx.makeImage() {
            compositedCache = NSImage(cgImage: img, size: CGSize(width: w, height: h))
        }
        needsDisplay = true
    }

    private func endCloneStroke(commit: Bool) {
        defer { cloneCtx = nil; cloneSnapshot = nil; cloneLast = nil }
        guard let ctx = cloneCtx else { return }
        if commit, let img = ctx.makeImage(), let doc = document {
            doc.applyRasterOp(Loc.t("克隆", "Clone")) { _ in img }
            refreshFromDocument()
            delegate?.canvasSelectionChanged(nil)
        } else {
            refreshFromDocument()
        }
    }

    /// Anchor any floating content into the document (single undo step),
    /// keeping the selection. Call before every raster op / save / copy-all.
    func anchorFloating() {
        guard let doc = document, let f = floating else { return }
        floating = nil
        doc.applyRasterOp(Loc.t("移动选区", "Move Selection")) { base in
            Self.composite(base: base, floating: f)
        }
        refreshFromDocument()
    }

    private func commitSelectionState(clear: Bool) {
        anchorFloating()
        if clear { selection = nil }
        polygonDraft = []
    }

    private static func composite(base: CGImage, floating f: FloatingContent) -> CGImage {
        let w = base.width, h = base.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return base }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        if let hole = f.holePath {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.addPath(hole)
            ctx.fillPath()
        }
        // Draw floating (flip back for raster draw).
        ctx.saveGState()
        let dest = CGRect(x: f.origin.x, y: f.origin.y,
                          width: CGFloat(f.image.width), height: CGFloat(f.image.height))
        ctx.translateBy(x: dest.minX, y: dest.minY + dest.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(f.image, in: CGRect(origin: .zero, size: dest.size))
        ctx.restoreGState()
        return ctx.makeImage() ?? base
    }

    /// Masked image of the current selection (transparent outside path).
    func selectionImage() -> CGImage? {
        guard let doc = document, let sel = selection else { return nil }
        if let f = floating { return f.image }
        return ImageOps.maskedCrop(doc.background, path: sel.cgPath, evenOdd: sel.isInverted)
    }

    /// Composited pixels of the current selection, for Save Selection.
    /// Rectangular = plain crop; other shapes (incl. inverted) get a
    /// white-filled masked crop, mirroring Copy.
    func selectionExportImage() -> CGImage? {
        guard let doc = document, selection != nil else { return nil }
        anchorFloating()
        guard let sel = selection else { return nil }
        if sel.isRectangular {
            return ImageOps.crop(doc.composited, to: sel.bounds)
        }
        return ImageOps.maskedCrop(doc.composited, path: sel.cgPath,
                                   fillWhite: true, evenOdd: sel.isInverted)
    }

    /// Resize the current rectangular selection to an exact px size, keeping
    /// its top-left origin and clamping to the image (Set Selection Size, ⌘J).
    func setSelectionSize(_ size: CGSize) {
        guard let doc = document else { return }
        anchorFloating()
        guard var sel = selection, sel.isRectangular else {
            OutputRouter.notifyHUD(Loc.t("先创建一个矩形选区", "Create a rectangular selection first"))
            return
        }
        let origin = sel.rect.standardized.origin
        let w = max(1, min(size.width, doc.pixelSize.width - origin.x))
        let h = max(1, min(size.height, doc.pixelSize.height - origin.y))
        sel.rect = CGRect(x: origin.x, y: origin.y, width: w, height: h)
        selection = sel
        needsDisplay = true
    }

    /// Invert the current selection within the image bounds (⌘⇧I). Builds an
    /// even-odd path = whole image with the current shape punched out as a
    /// hole. Toggling again restores the original shape.
    func invertSelection() {
        guard let doc = document else { return }
        anchorFloating()
        guard let sel = selection else {
            OutputRouter.notifyHUD(Loc.t("先选择一个区域", "Select a region first"))
            return
        }
        if sel.isInverted {
            var restored = sel
            restored.rawPath = nil
            selection = restored
            OutputRouter.notifyHUD(Loc.t("已取消反选", "Selection un-inverted"))
            needsDisplay = true
            return
        }
        let inv = CGMutablePath()
        inv.addRect(CGRect(origin: .zero, size: doc.pixelSize))
        inv.addPath(sel.cgPath)   // even-odd → image minus the shape
        var newSel = sel
        newSel.rawPath = inv
        selection = newSel
        OutputRouter.notifyHUD(Loc.t("已反选", "Selection inverted"))
        needsDisplay = true
    }

    func cutSelection() {
        guard let doc = document, let sel = selection else { return }
        if let img = selectionImage() {
            OutputRouter.copyToClipboard(img)
        }
        if floating != nil {
            // Cutting a floating selection just discards it (already lifted).
            discardFloatingRestoringHole()
        } else {
            doc.applyRasterOp(Loc.t("剪切", "Cut")) { ImageOps.fillPath($0, path: sel.cgPath, evenOdd: sel.isInverted) }
        }
        selection = nil
        refreshFromDocument()
    }

    func deleteSelection() {
        guard let doc = document, let sel = selection else { return }
        if floating != nil {
            discardFloatingRestoringHole()
        } else {
            doc.applyRasterOp(Loc.t("删除", "Delete")) { ImageOps.fillPath($0, path: sel.cgPath, evenOdd: sel.isInverted) }
        }
        selection = nil
        refreshFromDocument()
    }

    private func discardFloatingRestoringHole() {
        guard let doc = document, let f = floating else { return }
        floating = nil
        if let hole = f.holePath {
            doc.applyRasterOp(Loc.t("删除选区", "Delete Selection")) { ImageOps.fillPath($0, path: hole) }
        }
        refreshFromDocument()
    }

    @objc func copy(_ sender: Any?) { copySelectionOrAll() }

    func copySelectionOrAll() {
        guard let doc = document else { return }
        anchorFloating()
        if let sel = selection {
            if sel.isRectangular {
                OutputRouter.copyToClipboard(ImageOps.crop(doc.composited, to: sel.bounds))
            } else if let img = ImageOps.maskedCrop(doc.composited, path: sel.cgPath,
                                                    fillWhite: true, evenOdd: sel.isInverted) {
                OutputRouter.copyToClipboard(img)
            }
        } else {
            OutputRouter.copyToClipboard(doc.composited)
        }
        OutputRouter.notifyHUD(Loc.t("已复制到剪贴板", "Copied to clipboard"))
    }

    /// Paste clipboard image as a floating selection centered in the view.
    func pasteAsFloating() {
        guard let doc = document else { return }
        let pb = NSPasteboard.general
        guard let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: data), let cg = rep.cgImage else {
            OutputRouter.notifyHUD(Loc.t("剪贴板里没有图像", "No image on the clipboard"))
            return
        }
        anchorFloating()
        // Center in the visible portion of the canvas.
        let visible = enclosingScrollView?.documentVisibleRect ?? bounds
        var origin = CGPoint(x: visible.midX - CGFloat(cg.width) / 2,
                             y: visible.midY - CGFloat(cg.height) / 2)
        origin.x = max(min(origin.x, doc.pixelSize.width - CGFloat(cg.width)),
                       min(0, doc.pixelSize.width - CGFloat(cg.width)))
        origin.y = max(min(origin.y, doc.pixelSize.height - CGFloat(cg.height)),
                       min(0, doc.pixelSize.height - CGFloat(cg.height)))
        floating = FloatingContent(image: cg, origin: origin, holePath: nil)
        selection = EditorSelection(shape: .rectangle,
                                    rect: CGRect(origin: origin,
                                                 size: CGSize(width: cg.width, height: cg.height)))
        needsDisplay = true
    }

    func cropToSelectionPath() {
        guard let doc = document, let sel = selection else { return }
        anchorFloating()
        if sel.isRectangular {
            doc.applyRasterOp(Loc.t("裁剪", "Crop")) { ImageOps.crop($0, to: sel.bounds) }
        } else {
            doc.applyRasterOp(Loc.t("裁剪", "Crop")) { ImageOps.maskedCrop($0, path: sel.cgPath, fillWhite: true, evenOdd: sel.isInverted) ?? $0 }
        }
        selection = nil
        refreshFromDocument()
        delegate?.canvasCanvasResized()
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let image = compositedCache else { return }
        NSColor(white: 0.92, alpha: 1).setFill()
        bounds.fill()
        image.draw(in: CGRect(origin: .zero, size: frame.size))

        // Floating content preview (hole + lifted image).
        if let f = floating {
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState()
                if let hole = f.holePath {
                    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                    ctx.addPath(hole)
                    ctx.fillPath()
                }
                ctx.restoreGState()
            }
            NSImage(cgImage: f.image, size: CGSize(width: f.image.width, height: f.image.height))
                .draw(in: CGRect(x: f.origin.x, y: f.origin.y,
                                 width: CGFloat(f.image.width), height: CGFloat(f.image.height)))
        }

        // Clone tool: source marker + brush ring, no selection chrome.
        if cloneMode {
            drawCloneOverlay()
            return
        }

        // Selection outline (white base + black dashes = visible on any bg).
        if let sel = selection {
            strokeMarchingAnts(NSBezierPath(cgPath: sel.cgPath))
        }

        // Polygon in progress.
        if polygonDraft.count >= 1 {
            let p = NSBezierPath()
            p.move(to: polygonDraft[0])
            for pt in polygonDraft.dropFirst() { p.line(to: pt) }
            p.line(to: mousePos)
            strokeMarchingAnts(p)
        }

        // Canvas resize preview.
        if case let .resizingCanvas(_, _, preview) = drag {
            let p = NSBezierPath(rect: preview)
            p.lineWidth = tol(2)
            NSColor.controlAccentColor.setStroke()
            p.setLineDash([tol(6), tol(4)], count: 2, phase: 0)
            p.stroke()
        } else if selection == nil, floating == nil {
            drawCanvasHandles()
        }
    }

    private func drawCloneOverlay() {
        if let src = cloneSource {
            let r = tol(7)
            let ring = NSBezierPath(ovalIn: CGRect(x: src.x - r, y: src.y - r, width: r * 2, height: r * 2))
            ring.lineWidth = tol(1.5)
            NSColor.systemGreen.setStroke()
            ring.stroke()
            let cross = NSBezierPath()
            cross.move(to: CGPoint(x: src.x - r, y: src.y)); cross.line(to: CGPoint(x: src.x + r, y: src.y))
            cross.move(to: CGPoint(x: src.x, y: src.y - r)); cross.line(to: CGPoint(x: src.x, y: src.y + r))
            cross.lineWidth = tol(1)
            cross.stroke()
        }
        let brush = NSBezierPath(ovalIn: CGRect(x: mousePos.x - cloneRadius, y: mousePos.y - cloneRadius,
                                                width: cloneRadius * 2, height: cloneRadius * 2))
        brush.lineWidth = tol(1)
        NSColor.systemBlue.setStroke()
        brush.stroke()
    }

    private func strokeMarchingAnts(_ path: NSBezierPath) {
        path.lineWidth = tol(1)
        NSColor.white.setStroke()
        path.stroke()
        let dashed = path.copy() as! NSBezierPath
        dashed.setLineDash([tol(5), tol(4)], count: 2, phase: 0)
        NSColor.black.setStroke()
        dashed.stroke()
    }

    private func drawCanvasHandles() {
        let s = tol(7)
        NSColor.controlAccentColor.setFill()
        NSColor.white.setStroke()
        for p in canvasHandlePoints() {
            let r = NSBezierPath(ovalIn: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s))
            r.fill()
            r.lineWidth = tol(1)
            r.stroke()
        }
    }

    private func canvasHandlePoints() -> [CGPoint] {
        let b = bounds
        return [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.midX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                CGPoint(x: b.maxX, y: b.midY), CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.midX, y: b.maxY),
                CGPoint(x: b.minX, y: b.maxY), CGPoint(x: b.minX, y: b.midY)]
    }

    /// Which canvas edges a point near the border grabs.
    private func canvasEdges(at p: CGPoint) -> NSEdgeInsets0? {
        let t = tol(12)
        var e = NSEdgeInsets0()
        let nearL = abs(p.x - bounds.minX) <= t
        let nearR = abs(p.x - bounds.maxX) <= t
        let nearT = abs(p.y - bounds.minY) <= t
        let nearB = abs(p.y - bounds.maxY) <= t
        guard nearL || nearR || nearT || nearB else { return nil }
        // Must also be within the canvas band (not far outside).
        guard p.x >= bounds.minX - t, p.x <= bounds.maxX + t,
              p.y >= bounds.minY - t, p.y <= bounds.maxY + t else { return nil }
        e.left = nearL
        e.right = nearR
        e.top = nearT
        e.bottom = nearB
        return e
    }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        mousePos = p

        if cloneMode {
            cloneMouseDown(event)
            return
        }

        if selectShape == .pan {
            drag = .panning(last: event.locationInWindow)
            NSCursor.closedHand.set()
            return
        }

        // Double-click: crop (like the original) or close polygon.
        if event.clickCount == 2 {
            if !polygonDraft.isEmpty {
                closePolygon()
                return
            }
            if let sel = selection, sel.cgPath.contains(p), floating == nil {
                delegate?.canvasRequestsCrop()
                return
            }
        }

        // Polygon mode: clicks add vertices.
        if selectShape == .polygon, floating == nil {
            if selection != nil, selection!.cgPath.contains(p) {
                // fall through to move logic below
            } else {
                if polygonDraft.isEmpty { commitSelectionState(clear: true) }
                polygonDraft.append(p)
                needsDisplay = true
                return
            }
        }

        // Inside existing selection → move/copy content or move frame.
        if let sel = selection, sel.cgPath.contains(p) {
            if event.modifierFlags.contains(.option) {
                anchorFloating()
                drag = .movingFrame(last: p)
                return
            }
            if floating == nil {
                // Windows Ctrl+drag=copy → Mac ⌘+drag (project-wide Ctrl→⌘ mapping;
                // ⌃+click would collide with the context-menu gesture anyway).
                liftSelection(copy: event.modifierFlags.contains(.command))
            } else if event.modifierFlags.contains(.command) {
                // ⌘drag on an already-floating selection stamps a copy.
                if let doc = document, let f = floating {
                    doc.applyRasterOp(Loc.t("复制选区", "Duplicate Selection")) { Self.composite(base: $0, floating: f) }
                    floating?.holePath = nil
                    refreshFromDocument()
                }
            }
            drag = .movingContent(last: p)
            return
        }

        // Near canvas border → canvas resize (only when nothing selected).
        if selection == nil, floating == nil, let edges = canvasEdges(at: p) {
            drag = .resizingCanvas(edges: edges, start: p, preview: bounds)
            return
        }

        // Start a new selection.
        commitSelectionState(clear: true)
        switch selectShape {
        case .rectangle, .oval, .rrect:
            selection = nil
            drag = .creating(start: p)
        case .freehand:
            selection = EditorSelection(shape: .freehand, points: [p])
            drag = .lasso
        default:
            break
        }
        needsDisplay = true
    }

    private func liftSelection(copy: Bool) {
        guard let doc = document, let sel = selection else { return }
        guard let lifted = ImageOps.maskedCrop(doc.background, path: sel.cgPath, evenOdd: sel.isInverted) else { return }
        // If there are annotations, bake them first so the lift matches what
        // the user sees.
        if !doc.annotations.isEmpty {
            doc.applyRasterOp(Loc.t("合并标注", "Merge Annotations")) { $0 }
            guard let l2 = ImageOps.maskedCrop(doc.background, path: sel.cgPath, evenOdd: sel.isInverted) else { return }
            floating = FloatingContent(image: l2, origin: sel.bounds.origin,
                                       holePath: copy ? nil : sel.cgPath)
        } else {
            floating = FloatingContent(image: lifted, origin: sel.bounds.origin,
                                       holePath: copy ? nil : sel.cgPath)
        }
        refreshFromDocument()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mousePos = p
        if cloneMode {
            if cloneCtx != nil { clonePaint(to: clamp(p)) }
            needsDisplay = true
            return
        }
        switch drag {
        case .creating(let start):
            var sel = EditorSelection(shape: selectShape)
            sel.rect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                              width: abs(start.x - p.x), height: abs(start.y - p.y))
                .intersection(bounds)
            selection = sel.rect.width >= 2 && sel.rect.height >= 2 ? sel : nil
        case .lasso:
            selection?.points.append(clamp(p))
        case .movingContent(let last):
            let d = CGPoint(x: p.x - last.x, y: p.y - last.y)
            floating?.origin.x += d.x
            floating?.origin.y += d.y
            selection?.translate(by: d)
            drag = .movingContent(last: p)
        case .movingFrame(let last):
            let d = CGPoint(x: p.x - last.x, y: p.y - last.y)
            selection?.translate(by: d)
            drag = .movingFrame(last: p)
        case .resizingCanvas(let edges, let start, _):
            var r = bounds
            let d = CGPoint(x: p.x - start.x, y: p.y - start.y)
            if edges.left { r.origin.x += d.x; r.size.width -= d.x }
            if edges.right { r.size.width += d.x }
            if edges.top { r.origin.y += d.y; r.size.height -= d.y }
            if edges.bottom { r.size.height += d.y }
            r.size.width = max(16, r.width)
            r.size.height = max(16, r.height)
            drag = .resizingCanvas(edges: edges, start: start, preview: r)
        case .panning(let last):
            guard let scroll = enclosingScrollView else { break }
            let cur = event.locationInWindow
            let d = CGPoint(x: (cur.x - last.x) / magnification,
                            y: (cur.y - last.y) / magnification)
            var origin = scroll.contentView.bounds.origin
            origin.x -= d.x
            origin.y += d.y  // flipped doc view
            scroll.contentView.setBoundsOrigin(origin)
            scroll.reflectScrolledClipView(scroll.contentView)
            drag = .panning(last: cur)
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if cloneMode {
            endCloneStroke(commit: cloneCtx != nil)
            needsDisplay = true
            return
        }
        switch drag {
        case .lasso:
            if let sel = selection, sel.points.count >= 3 {
                // closed implicitly by cgPath
            } else {
                selection = nil
            }
        case .resizingCanvas(_, _, let preview):
            applyCanvasResize(to: preview)
        case .panning:
            NSCursor.openHand.set()
        default:
            break
        }
        drag = .none
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        mousePos = convert(event.locationInWindow, from: nil)
        if !polygonDraft.isEmpty || cloneMode { needsDisplay = true }
    }

    private func closePolygon() {
        if polygonDraft.count >= 3 {
            selection = EditorSelection(shape: .polygon, points: polygonDraft)
        }
        polygonDraft = []
        needsDisplay = true
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x.clamped(bounds.minX, bounds.maxX),
                y: p.y.clamped(bounds.minY, bounds.maxY))
    }

    private func applyCanvasResize(to newRect: CGRect) {
        guard let doc = document else { return }
        let old = bounds
        let left = old.minX - newRect.minX
        let right = newRect.maxX - old.maxX
        let top = old.minY - newRect.minY
        let bottom = newRect.maxY - old.maxY
        guard abs(left) + abs(right) + abs(top) + abs(bottom) >= 1 else { return }
        doc.applyRasterOp(Loc.t("调整画布", "Adjust Canvas")) {
            ImageOps.resizeCanvas($0, left: left, top: top, right: right, bottom: bottom)
        }
        refreshFromDocument()
        delegate?.canvasCanvasResized()
    }

    // MARK: cursors

    override func resetCursorRects() {
        if cloneMode {
            addCursorRect(bounds, cursor: .crosshair)
            return
        }
        if selectShape == .pan {
            addCursorRect(bounds, cursor: .openHand)
            return
        }
        addCursorRect(bounds, cursor: .crosshair)
        let t = tol(8)
        addCursorRect(CGRect(x: bounds.minX - t, y: bounds.minY, width: t * 2, height: bounds.height),
                      cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: bounds.maxX - t, y: bounds.minY, width: t * 2, height: bounds.height),
                      cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: bounds.minX, y: bounds.minY - t, width: bounds.width, height: t * 2),
                      cursor: .resizeUpDown)
        addCursorRect(CGRect(x: bounds.minX, y: bounds.maxY - t, width: bounds.width, height: t * 2),
                      cursor: .resizeUpDown)
        if let sel = selection {
            addCursorRect(sel.bounds, cursor: .openHand)
        }
    }

    // MARK: keys

    override func keyDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.command) else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 53:  // Esc
            if cloneMode {
                toggleCloneMode()
            } else if !polygonDraft.isEmpty {
                polygonDraft = []
                needsDisplay = true
            } else {
                clearSelection()
            }
            return
        case 36, 76:  // Return / Enter
            if !polygonDraft.isEmpty {
                closePolygon()
            } else if selection != nil {
                delegate?.canvasRequestsCrop()
            }
            return
        case 51, 117:  // Delete
            if selection != nil {
                deleteSelection()
                return
            }
        case 123, 124, 125, 126:  // arrows: move selection frame (⇧ = resize)
            if var sel = selection {
                let d: CGFloat = 1
                if event.modifierFlags.contains(.shift), sel.isRectangular || sel.shape == .oval || sel.shape == .rrect {
                    switch event.keyCode {
                    case 123: sel.rect.size.width -= d
                    case 124: sel.rect.size.width += d
                    case 125: sel.rect.size.height += d
                    case 126: sel.rect.size.height -= d
                    default: break
                    }
                } else {
                    var delta = CGPoint.zero
                    switch event.keyCode {
                    case 123: delta.x = -d
                    case 124: delta.x = d
                    case 125: delta.y = d
                    case 126: delta.y = -d
                    default: break
                    }
                    sel.translate(by: delta)
                    if floating != nil {
                        floating?.origin.x += delta.x
                        floating?.origin.y += delta.y
                    }
                }
                selection = sel
                needsDisplay = true
                return
            }
        default:
            break
        }
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // Remove/Insert Strip: ⇧H/⇧V remove, ⌥⇧H/⌥⇧V insert (FastStone keys).
        if (chars == "h" || chars == "v"), event.modifierFlags.contains(.shift) {
            let cmd = (event.modifierFlags.contains(.option) ? "insert-" : "remove-") + chars
            delegate?.canvasKeyCommand(cmd)
            return
        }
        switch chars {
        case "x": if selection != nil { delegate?.canvasRequestsCrop(); return }
        case "d", "l", "r", "h", "v", "b", "o", "g", "t", "j", "f", "c",
             "0", "1", "2", "3", "4", "5",
             "6", "7", "8", "9", "+", "-", "=":
            delegate?.canvasKeyCommand(chars)
            return
        default:
            break
        }
        super.keyDown(with: event)
    }
}

// MARK: - centering clip view

/// Keeps the (smaller-than-viewport) document centered, so the canvas floats
/// in the middle of the editor instead of hugging the top-left corner.
final class CenteringClipView: NSClipView {
    /// Clicking the gray background outside the canvas (editor only): anchor
    /// floating content / clear the selection.
    var onBackgroundMouseDown: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onBackgroundMouseDown?()
        super.mouseDown(with: event)
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        let docFrame = doc.frame
        if rect.width >= docFrame.width {
            rect.origin.x = docFrame.minX - (rect.width - docFrame.width) / 2
        }
        if rect.height >= docFrame.height {
            rect.origin.y = docFrame.minY - (rect.height - docFrame.height) / 2
        }
        return rect
    }
}
