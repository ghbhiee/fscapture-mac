import AppKit

/// What kind of region the overlay collects.
enum SelectionMode {
    case rectangle
    case freehand
    case fixedSize(CGSize)
}

enum SelectionResult {
    case rect(CGRect, NSScreen)          // Cocoa global coords
    case path([CGPoint], NSScreen)       // Cocoa global coords
}

/// Full-screen transparent windows (one per display) that let the user drag a
/// rectangle / draw a freehand region / place a fixed-size frame.
/// Esc or right-click cancels — same as the original app.
@MainActor
final class SelectionOverlayController {
    static var current: SelectionOverlayController?  // keep alive while showing

    private var windows: [OverlayWindow] = []
    private let completion: (SelectionResult?) -> Void

    init(mode: SelectionMode, completion: @escaping (SelectionResult?) -> Void) {
        self.completion = completion
        for screen in NSScreen.screens {
            let win = OverlayWindow(screen: screen, mode: mode) { [weak self] result in
                self?.finish(with: result)
            }
            windows.append(win)
            win.orderFrontRegardless()
        }
        // Key window = the one under the mouse, so Esc lands somewhere useful.
        let mouse = NSEvent.mouseLocation
        let target = windows.first { $0.screen?.frame.contains(mouse) ?? false } ?? windows.first
        NSApp.activate(ignoringOtherApps: true)
        target?.makeKeyAndOrderFront(nil)
        SelectionOverlayController.current = self
    }

    private func finish(with result: SelectionResult?) {
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        SelectionOverlayController.current = nil
        completion(result)
    }
}

private final class OverlayWindow: NSWindow {
    init(screen: NSScreen, mode: SelectionMode, onDone: @escaping (SelectionResult?) -> Void) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = SelectionView(screen: screen, mode: mode, onDone: onDone)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class SelectionView: NSView {
    private let mode: SelectionMode
    private let onDone: (SelectionResult?) -> Void
    private let overlayScreen: NSScreen

    private var dragStart: CGPoint?          // view coords
    private var dragCurrent: CGPoint?
    private var pathPoints: [CGPoint] = []   // view coords
    private var mousePos: CGPoint = .zero
    private var trackingArea: NSTrackingArea?

    init(screen: NSScreen, mode: SelectionMode, onDone: @escaping (SelectionResult?) -> Void) {
        self.overlayScreen = screen
        self.mode = mode
        self.onDone = onDone
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        mousePos = convertGlobal(NSEvent.mouseLocation)
        updateTracking()
        NSCursor.crosshair.set()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTracking()
    }

    private func updateTracking() {
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseMoved, .activeAlways, .cursorUpdate],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    /// Cocoa global -> view coords (window covers whole screen, so this is a translation).
    private func convertGlobal(_ p: CGPoint) -> CGPoint {
        guard let window else { return p }
        return convert(window.convertPoint(fromScreen: p), from: nil)
    }

    private func viewToGlobal(_ p: CGPoint) -> CGPoint {
        guard let window else { return p }
        return window.convertPoint(toScreen: convert(p, to: nil))
    }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch mode {
        case .rectangle:
            dragStart = p
            dragCurrent = p
        case .freehand:
            pathPoints = [p]
        case .fixedSize(let size):
            let rect = fixedRect(at: p, size: size)
            let global = CGRect(origin: viewToGlobal(rect.origin), size: rect.size)
            onDone(.rect(global, overlayScreen))
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mousePos = p
        switch mode {
        case .rectangle: dragCurrent = p
        case .freehand: pathPoints.append(p)
        case .fixedSize: break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch mode {
        case .rectangle:
            guard let s = dragStart, let c = dragCurrent else { return }
            let rect = normalizedRect(s, c)
            if rect.width >= 3, rect.height >= 3 {
                let global = CGRect(origin: viewToGlobal(rect.origin), size: rect.size)
                onDone(.rect(global, overlayScreen))
            } else {
                dragStart = nil
                dragCurrent = nil
                needsDisplay = true
            }
        case .freehand:
            if pathPoints.count >= 3 {
                onDone(.path(pathPoints.map { viewToGlobal($0) }, overlayScreen))
            } else {
                pathPoints = []
                needsDisplay = true
            }
        case .fixedSize:
            break
        }
    }

    override func mouseMoved(with event: NSEvent) {
        mousePos = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) { onDone(nil) }
    override func otherMouseDown(with event: NSEvent) { onDone(nil) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDone(nil) } // Esc
    }

    // MARK: geometry

    private func normalizedRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func fixedRect(at center: CGPoint, size: CGSize) -> CGRect {
        var r = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                       width: size.width, height: size.height)
        // Clamp inside this screen.
        if r.minX < bounds.minX { r.origin.x = bounds.minX }
        if r.minY < bounds.minY { r.origin.y = bounds.minY }
        if r.maxX > bounds.maxX { r.origin.x = bounds.maxX - r.width }
        if r.maxY > bounds.maxY { r.origin.y = bounds.maxY - r.height }
        return r
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let dim = NSColor.black.withAlphaComponent(0.25)
        var cutout: CGRect?
        var strokePath: NSBezierPath?

        switch mode {
        case .rectangle:
            if let s = dragStart, let c = dragCurrent { cutout = normalizedRect(s, c) }
        case .fixedSize(let size):
            cutout = fixedRect(at: mousePos, size: size)
        case .freehand:
            if pathPoints.count > 1 {
                let p = NSBezierPath()
                p.move(to: pathPoints[0])
                for pt in pathPoints.dropFirst() { p.line(to: pt) }
                strokePath = p
            }
        }

        // Dim everything, punch out the selection.
        dim.setFill()
        ctx.fill(bounds)
        if let cutout {
            ctx.setBlendMode(.clear)
            ctx.fill(cutout)
            ctx.setBlendMode(.normal)

            NSColor.systemRed.setStroke()
            let border = NSBezierPath(rect: cutout.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            border.stroke()

            drawSizeLabel(text: "\(Int(cutout.width)) × \(Int(cutout.height))", near: cutout)
        } else if let strokePath {
            NSColor.systemRed.setStroke()
            strokePath.lineWidth = 2
            strokePath.stroke()
        } else {
            // Idle: crosshair guide lines through the mouse.
            NSColor.white.withAlphaComponent(0.6).setStroke()
            let guide = NSBezierPath()
            guide.move(to: CGPoint(x: mousePos.x, y: bounds.minY))
            guide.line(to: CGPoint(x: mousePos.x, y: bounds.maxY))
            guide.move(to: CGPoint(x: bounds.minX, y: mousePos.y))
            guide.line(to: CGPoint(x: bounds.maxX, y: mousePos.y))
            guide.lineWidth = 1
            guide.stroke()
            drawHint()
        }
    }

    private func drawSizeLabel(text: String, near rect: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        var origin = CGPoint(x: rect.minX, y: rect.maxY + 6)
        if origin.y + size.height + 8 > bounds.maxY { origin.y = rect.maxY - size.height - 14 }
        if origin.x + size.width + 12 > bounds.maxX { origin.x = bounds.maxX - size.width - 12 }
        let bg = CGRect(x: origin.x, y: origin.y, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: origin.x + 6, y: origin.y + 3), withAttributes: attrs)
    }

    private func drawHint() {
        let hint: String
        switch mode {
        case .rectangle: hint = Loc.t("拖拽选择区域 · Esc/右键 取消", "Drag to select a region · Esc / right-click to cancel")
        case .freehand:  hint = Loc.t("按住拖动画出任意形状 · Esc/右键 取消", "Hold and drag to draw any shape · Esc / right-click to cancel")
        case .fixedSize(let s): hint = Loc.t("单击放置 \(Int(s.width))×\(Int(s.height)) 区域 · Esc/右键 取消",
                                            "Click to place a \(Int(s.width))×\(Int(s.height)) region · Esc / right-click to cancel")
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = hint.size(withAttributes: attrs)
        let bg = CGRect(x: bounds.midX - size.width / 2 - 12, y: bounds.maxY - 80,
                        width: size.width + 24, height: size.height + 12)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 6, yRadius: 6).fill()
        hint.draw(at: CGPoint(x: bg.minX + 12, y: bg.minY + 6), withAttributes: attrs)
    }
}
