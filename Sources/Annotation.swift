import AppKit

/// Draw-tool object types (FastStone TTextBoard palette, Phase 2 subset).
/// Per spec §3.1 the three text tools are SEPARATE tools:
///   .text      — plain text, NO frame / NO background (BntText2, icon A)
///   .textRect  — rectangular text box  (BntText, border + optional background)
///   .textOval  — oval text box         (BntText3, border + optional background)
/// Draw palette object types. Order below drives the tool-strip layout
/// (allCases). Grouped: text · lines/arrows · shapes · highlighters ·
/// callout/step · special (magnifier/pointer/blur/emoji).
enum AnnotationType: String, Codable, CaseIterable {
    case text, textRect, textOval,
         line, arrow, lline, polyline, fancyLine, bracket,
         rect, ellipse, polygon,
         highlighter, marker, freehand, eraser,
         callout, step, magnifier, mousePointer, blur, emoji

    var label: String {
        switch self {
        case .text: return Loc.t("文本", "Text")
        case .textRect: return Loc.t("矩形文本框", "Text Box")
        case .textOval: return Loc.t("椭圆文本框", "Oval Text Box")
        case .line: return Loc.t("直线", "Line")
        case .arrow: return Loc.t("箭头", "Arrow")
        case .lline: return Loc.t("L 型线", "L-Shaped Line")
        case .polyline: return Loc.t("折线", "Polyline")
        case .fancyLine: return Loc.t("花式线", "Fancy Line")
        case .bracket: return Loc.t("括号", "Bracket")
        case .rect: return Loc.t("矩形", "Rectangle")
        case .ellipse: return Loc.t("椭圆", "Ellipse")
        case .polygon: return Loc.t("填充多边形", "Filled Polygon")
        case .highlighter: return Loc.t("荧光笔", "Highlighter")
        case .marker: return Loc.t("线荧光笔", "Marker")
        case .freehand: return Loc.t("铅笔", "Pencil")
        case .eraser: return Loc.t("橡皮", "Eraser")
        case .callout: return Loc.t("气泡", "Callout")
        case .step: return Loc.t("序号", "Step Number")
        case .magnifier: return Loc.t("放大镜", "Magnifier")
        case .mousePointer: return Loc.t("鼠标指针", "Mouse Pointer")
        case .blur: return Loc.t("马赛克", "Mosaic")
        case .emoji: return "Emoji"
        }
    }

    var symbolName: String {
        switch self {
        case .text: return "textformat"
        case .textRect: return "character.textbox"
        case .textOval: return "oval.portrait"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .lline: return "arrow.turn.right.down"
        case .polyline: return "scribble.variable"
        case .fancyLine: return "wand.and.stars"
        case .bracket: return "curlybraces"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .polygon: return "pentagon.fill"
        case .highlighter: return "rectangle.fill"
        case .marker: return "highlighter"
        case .freehand: return "pencil.and.outline"
        case .eraser: return "eraser"
        case .callout: return "bubble.left"
        case .step: return "1.circle"
        case .magnifier: return "plus.magnifyingglass"
        case .mousePointer: return "cursorarrow"
        case .blur: return "mosaic"
        case .emoji: return "face.smiling"
        }
    }

    /// One of the three single-click text tools (placed, then edited in the panel).
    var isTextTool: Bool { self == .text || self == .textRect || self == .textOval }

    /// Line-family: rendered as a stroked point path with endpoint caps
    /// (spec §4). Bracket/polygon are point/frame based but drawn specially.
    var isLineFamily: Bool {
        switch self {
        case .line, .arrow, .lline, .polyline, .fancyLine: return true
        default: return false
        }
    }

    /// Objects whose geometry is a point list (bbox derived from points).
    var isPointBased: Bool {
        switch self {
        case .line, .arrow, .lline, .polyline, .fancyLine,
             .freehand, .marker, .eraser, .polygon: return true
        default: return false
        }
    }

    /// Tools built by multi-click then double-click / Enter (spec §4.2, #16/#25).
    var isMultiClick: Bool { self == .polyline || self == .polygon }
}

/// Frame shape for a text object (spec §3.1). `.none` = plain text (no frame).
enum TextBoxShape: String, Codable {
    case none, rect, oval
}

/// Endpoint cap for a line object (spec §4.1). The 10 dropdown presets are
/// every meaningful {start, end} combination of these four caps.
enum LineCap: String, Codable {
    case none, thinArrow, thickArrow, dot
}

/// One vector annotation object. All coordinates are IMAGE PIXEL space,
/// TOP-LEFT origin — the persistent representation inside .fscx.
struct Annotation: Codable, Identifiable, Equatable {
    var id = UUID()
    var type: AnnotationType
    var frame: CGRect = .zero          // bounding box (line/arrow: from points)
    var points: [CGPoint] = []         // line/arrow endpoints, freehand path, callout tail anchor
    var text: String = ""
    var fontSize: CGFloat = 24
    var strokeHex: String = "#FF3B30FF"
    var fillHex: String?               // nil = no fill
    var lineWidth: CGFloat = 3         // stroke / border width (0 = no border, e.g. text outline off)
    var shadow: Bool = true
    var number: Int = 1                // step
    var pixelate: Bool = true          // blur style
    var blurAmount: CGFloat = 14
    var z: Int = 0

    // Text-object extras (spec §3). Only meaningful for text/textRect/textOval.
    var textBoxShape: TextBoxShape = .none   // .none = plain text (no frame)
    var hasBackground: Bool = false          // §3.5: background checkbox, default OFF
    var backgroundHex: String = "#FFFFFFFF"  // §3.5: background color, default white
    var roundCorner: Bool = false            // §3.5: rectangular text box rounded corner

    // Line-object extras (spec §4). Endpoint caps at start/end (the 10 presets),
    // dashed style, an outline/halo (width 0–10 + color), and endpoint size 1–10.
    var startCap: LineCap = .none
    var endCap: LineCap = .none
    var dashed: Bool = false
    var outlineWidth: CGFloat = 0            // 0 = no outline
    var outlineHex: String = "#000000FF"
    var endpointSize: CGFloat = 5            // §4.2 PLineEndSize, 1–10
    var closed: Bool = false                 // polyline/polygon closed
    var smooth: Bool = false                 // polyline/pencil/polygon smoothing

    // Bracket (spec §5 #23): 0–7 selects one of the 8 bracket shapes.
    var bracketShape: Int = 0

    // Magnifier (spec §5 #22): zoom factor (1.5 / 2.0 / 2.5).
    var magnifyZoom: CGFloat = 2.0

    // Highlighter block shape (spec §5 #8): 0 = rect, 1 = rounded, 2 = oval.
    var highlightShape: Int = 0

    // Step letters (spec §5 #18): render A/B/C instead of 1/2/3, optional lowercase.
    var stepLetter: Bool = false
    var stepLowercase: Bool = false

    // Mouse pointer / icon (spec §5 #17): right-button variant, `hasBackground`
    // doubles as the highlight toggle.
    var pointerRight: Bool = false

    // Per-object opacity (spec §5/§9). 0 = fully opaque … 100 = fully transparent.
    var opacity: Int = 0

    /// The 10 endpoint presets (spec §4.1) as {start, end} cap pairs.
    static let endpointPresets: [(LineCap, LineCap)] = [
        (.none, .none),            // 1  纯线
        (.none, .thinArrow),       // 2  终点细箭头
        (.dot, .thinArrow),        // 3  起点圆点 + 终点细箭头
        (.none, .thickArrow),      // 4  终点粗箭头
        (.dot, .thickArrow),       // 5  起点圆点 + 终点粗箭头
        (.none, .dot),             // 6  终点圆点
        (.dot, .none),             // 7  起点圆点
        (.dot, .dot),              // 8  两端圆点
        (.thinArrow, .thinArrow),  // 9  双向细箭头
        (.thickArrow, .thickArrow),// 10 双向粗箭头
    ]

    var strokeColor: NSColor { NSColor(hex: strokeHex) }
    var fillColor: NSColor? { fillHex.map { NSColor(hex: $0) } }
    var backgroundColor: NSColor { NSColor(hex: backgroundHex) }
    var outlineColor: NSColor { NSColor(hex: outlineHex) }

    /// Step badge text: number (default) or a letter A/B/C… (spec §5 #18).
    var stepLabel: String {
        guard stepLetter else { return "\(number)" }
        let idx = ((number - 1) % 26 + 26) % 26
        let scalar = UnicodeScalar((stepLowercase ? 97 : 65) + idx)!
        return String(Character(scalar))
    }

    /// Alpha multiplier derived from `opacity` (0–100 → 1…0).
    var alpha: CGFloat { max(0, min(1, 1 - CGFloat(opacity) / 100)) }

    /// Whether this object holds editable text (double-click re-opens the editor).
    var isTextual: Bool { type.isTextTool || type == .callout }

    /// Normalized frame (some drags produce negative width/height).
    var bounds: CGRect { frame.standardized }

    /// Rect used for hit-testing/selection display.
    var selectionBounds: CGRect {
        if type.isPointBased {
            var r = CGRect.null
            for p in points { r = r.union(CGRect(origin: p, size: .zero)) }
            if type == .lline, points.count >= 2 {   // include the elbow corner
                r = r.union(CGRect(origin: CGPoint(x: points[1].x, y: points[0].y), size: .zero))
            }
            return r.isNull ? bounds : r.insetBy(dx: -6, dy: -6)
        }
        return bounds
    }

    mutating func move(by delta: CGPoint) {
        frame.origin.x += delta.x
        frame.origin.y += delta.y
        points = points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
    }
}

/// Renders annotations into the CURRENT NSGraphicsContext, which must be
/// flipped (top-left origin) and already scaled to image pixel space. Used by
/// the Draw canvas, the editor composite, exports and .fscx thumbnails.
enum AnnotationRenderer {

    static func render(_ annotations: [Annotation], background: CGImage?) {
        for a in annotations.sorted(by: { $0.z < $1.z }) {
            render(a, background: background)
        }
    }

    static func render(_ a: Annotation, background: CGImage?) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }

        // Per-object opacity (spec §5/§9). Blur is a pixel op, opacity N/A.
        if a.alpha < 1 && a.type != .blur {
            ctx.setAlpha(a.alpha)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        defer {
            if a.alpha < 1 && a.type != .blur { ctx.endTransparencyLayer() }
        }

        if a.shadow && a.type != .blur && a.type != .marker && a.type != .highlighter {
            ctx.setShadow(offset: CGSize(width: 2, height: -2), blur: 3,
                          color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
        }

        let stroke = a.strokeColor
        switch a.type {
        case .rect:
            let p = NSBezierPath(roundedRect: a.bounds, xRadius: 2, yRadius: 2)
            if let fill = a.fillColor { fill.setFill(); p.fill() }
            stroke.setStroke()
            p.lineWidth = a.lineWidth
            p.stroke()

        case .ellipse:
            let p = NSBezierPath(ovalIn: a.bounds)
            if let fill = a.fillColor { fill.setFill(); p.fill() }
            stroke.setStroke()
            p.lineWidth = a.lineWidth
            p.stroke()

        case .line, .arrow, .lline, .polyline, .fancyLine:
            renderLineFamily(a, stroke: stroke)

        case .bracket:
            let path = bracketPath(a.bracketShape, in: a.bounds)
            strokePath(path, a, stroke)

        case .polygon:
            let path = linePath(a)
            a.backgroundColor.setFill()
            path.fill()
            strokePath(path, a, stroke)

        case .magnifier:
            renderMagnifier(a, stroke: stroke, background: background, ctx: ctx)

        case .mousePointer:
            drawPointer(in: a.bounds, right: a.pointerRight,
                        highlight: a.hasBackground, color: stroke)

        case .highlighter:
            ctx.setBlendMode(.multiply)
            let path: NSBezierPath
            switch a.highlightShape {
            case 2:  path = NSBezierPath(ovalIn: a.bounds)
            case 1:  path = NSBezierPath(roundedRect: a.bounds, xRadius: 10, yRadius: 10)
            default: path = NSBezierPath(rect: a.bounds)
            }
            stroke.withAlphaComponent(0.4).setFill()
            path.fill()

        case .marker:
            guard a.points.count >= 2 else { break }
            ctx.setBlendMode(.multiply)
            let p = NSBezierPath()
            p.move(to: a.points[0])
            for pt in a.points.dropFirst() { p.line(to: pt) }
            p.lineWidth = max(a.lineWidth * 5, 12)
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            stroke.withAlphaComponent(0.45).setStroke()
            p.stroke()

        case .freehand, .eraser:
            // Pencil (§5 #2) and eraser (§5 #14, a solid color-cover brush).
            guard a.points.count >= 2 else { break }
            let p = a.smooth && a.points.count > 2
                ? smoothPath(a.points, closed: false)
                : NSBezierPath()
            if !(a.smooth && a.points.count > 2) {
                p.move(to: a.points[0])
                for pt in a.points.dropFirst() { p.line(to: pt) }
            }
            p.lineWidth = a.lineWidth
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            stroke.setStroke()
            p.stroke()

        case .text, .textRect, .textOval:
            renderTextObject(a, stroke: stroke)

        case .callout:
            let box = a.bounds
            let tail = a.points.first ?? CGPoint(x: box.midX, y: box.maxY + 40)
            let path = calloutPath(box: box, tail: tail)
            (a.fillColor ?? .white).setFill()
            path.fill()
            stroke.setStroke()
            path.lineWidth = a.lineWidth
            path.stroke()
            drawText(a.text.isEmpty ? " " : a.text, in: box.insetBy(dx: 8, dy: 6),
                     size: a.fontSize, color: .black)

        case .step:
            let box = a.bounds
            let d = min(box.width, box.height)
            let circle = CGRect(x: box.midX - d / 2, y: box.midY - d / 2, width: d, height: d)
            stroke.setFill()
            NSBezierPath(ovalIn: circle).fill()
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 2
            ring.stroke()
            let font = NSFont.boldSystemFont(ofSize: d * 0.52)
            let s = a.stepLabel
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let size = s.size(withAttributes: attrs)
            s.draw(at: CGPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2),
                   withAttributes: attrs)

        case .blur:
            guard let background else { break }
            let clamped = a.bounds.intersection(
                CGRect(x: 0, y: 0, width: background.width, height: background.height))
            guard clamped.width >= 2, clamped.height >= 2 else { break }
            let region = ImageOps.crop(background, to: clamped)
            let processed = a.pixelate
                ? ImageOps.pixellate(region, scale: a.blurAmount)
                : ImageOps.gaussianBlur(region, radius: a.blurAmount)
            NSImage(cgImage: processed, size: clamped.size).draw(in: clamped)

        case .emoji:
            drawText(a.text.isEmpty ? "😀" : a.text, in: a.bounds,
                     size: min(a.bounds.width, a.bounds.height) * 0.85, color: .black,
                     centered: true)
        }
    }

    /// Renders one of the three text objects (spec §3.1).
    /// `.text` = plain text (NO frame, NO background), only colored glyphs +
    /// optional outline/描边 (lineWidth>0) + shadow. `.textRect` / `.textOval`
    /// draw a border (lineWidth, 0 = none) + optional background block.
    private static func renderTextObject(_ a: Annotation, stroke: NSColor) {
        let box = a.bounds
        if a.textBoxShape != .none {
            let corner: CGFloat = a.roundCorner ? 12 : 3
            let framePath = a.textBoxShape == .oval
                ? NSBezierPath(ovalIn: box)
                : NSBezierPath(roundedRect: box, xRadius: corner, yRadius: corner)
            if a.hasBackground {
                a.backgroundColor.setFill()
                framePath.fill()
            }
            if a.lineWidth > 0 {
                stroke.setStroke()
                framePath.lineWidth = a.lineWidth
                framePath.stroke()
            }
            // Text inside a box renders in a legible dark color.
            drawText(a.text.isEmpty ? " " : a.text, in: box.insetBy(dx: 8, dy: 6),
                     size: a.fontSize, color: NSColor(hex: "#222222FF"))
        } else {
            // Plain text: glyphs in stroke color, optional outline halo.
            drawText(a.text.isEmpty ? " " : a.text, in: box.insetBy(dx: 3, dy: 2),
                     size: a.fontSize, color: stroke, outlineWidth: a.lineWidth)
        }
    }

    private static func drawText(_ text: String, in rect: CGRect, size: CGFloat,
                                 color: NSColor, centered: Bool = false,
                                 outlineWidth: CGFloat = 0) {
        let para = NSMutableParagraphStyle()
        para.alignment = centered ? .center : .left
        para.lineBreakMode = .byWordWrapping
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: color,
            .paragraphStyle: para,
        ]
        if outlineWidth > 0 {
            // Negative strokeWidth = fill + stroke (glyph outline). White halo
            // keeps text legible over photos; strokeWidth is a % of font size.
            attrs[.strokeColor] = NSColor.white
            attrs[.strokeWidth] = -Double(outlineWidth * 4)
        }
        (text as NSString).draw(in: rect, withAttributes: attrs)
    }

    // MARK: line family (spec §4)

    /// Point list expanded for rendering: L-Line inserts its right-angle elbow.
    private static func linePoints(_ a: Annotation) -> [CGPoint] {
        guard a.type == .lline, a.points.count >= 2 else { return a.points }
        return [a.points[0], CGPoint(x: a.points[1].x, y: a.points[0].y), a.points[1]]
    }

    /// The stroked path for a line-family / polygon object (straight or smoothed).
    private static func linePath(_ a: Annotation) -> NSBezierPath {
        let pts = linePoints(a)
        if a.smooth && pts.count > 2 { return smoothPath(pts, closed: a.closed) }
        let path = NSBezierPath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        for p in pts.dropFirst() { path.line(to: p) }
        if a.closed { path.close() }
        return path
    }

    /// Catmull-Rom → cubic Bézier smoothing through the given points.
    private static func smoothPath(_ pts: [CGPoint], closed: Bool) -> NSBezierPath {
        let path = NSBezierPath()
        guard pts.count > 2 else {
            if let f = pts.first { path.move(to: f); for p in pts.dropFirst() { path.line(to: p) } }
            return path
        }
        var p = pts
        if closed { p.append(pts[0]) }
        path.move(to: p[0])
        for i in 0..<(p.count - 1) {
            let p0 = p[max(i - 1, 0)]
            let p1 = p[i]
            let p2 = p[i + 1]
            let p3 = p[min(i + 2, p.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.curve(to: p2, controlPoint1: c1, controlPoint2: c2)
        }
        if closed { path.close() }
        return path
    }

    /// Stroke a path with the object's outline (halo) + dash + width (spec §4.2).
    private static func strokePath(_ path: NSBezierPath, _ a: Annotation, _ stroke: NSColor) {
        if a.outlineWidth > 0 {
            let o = path.copy() as! NSBezierPath
            o.lineWidth = max(a.lineWidth, 0.5) + a.outlineWidth * 2
            o.lineCapStyle = .round
            o.lineJoinStyle = .round
            a.outlineColor.setStroke()
            o.stroke()
        }
        if a.dashed {
            path.setLineDash([max(a.lineWidth * 3, 4), max(a.lineWidth * 2, 3)], count: 2, phase: 0)
        }
        path.lineWidth = max(a.lineWidth, 0.5)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        stroke.setStroke()
        path.stroke()
    }

    private static func renderLineFamily(_ a: Annotation, stroke: NSColor) {
        let pts = linePoints(a)
        guard pts.count >= 2 else { return }
        strokePath(linePath(a), a, stroke)

        // Endpoint caps. `.arrow` keeps its classic thick head when left default.
        var start = a.startCap, end = a.endCap
        if a.type == .arrow && start == .none && end == .none { end = .thickArrow }
        let startDir = atan2(pts[0].y - pts[1].y, pts[0].x - pts[1].x)
        let endDir = atan2(pts[pts.count - 1].y - pts[pts.count - 2].y,
                           pts[pts.count - 1].x - pts[pts.count - 2].x)
        drawCap(start, at: pts[0], dir: startDir, a: a, color: stroke)
        drawCap(end, at: pts[pts.count - 1], dir: endDir, a: a, color: stroke)
    }

    /// Draws one endpoint cap (spec §4.1). `dir` points OUTWARD from the tip.
    private static func drawCap(_ cap: LineCap, at tip: CGPoint, dir: CGFloat,
                                a: Annotation, color: NSColor) {
        let scale = max(a.endpointSize, 1) / 5
        switch cap {
        case .none:
            break
        case .dot:
            let r = max(a.lineWidth * 1.7, 4) * scale
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: tip.x - r, y: tip.y - r, width: 2 * r, height: 2 * r)).fill()
        case .thinArrow:
            let len = max(a.lineWidth * 3.4, 12) * scale
            let spread: CGFloat = .pi / 6
            let p = NSBezierPath()
            p.move(to: CGPoint(x: tip.x - len * cos(dir - spread), y: tip.y - len * sin(dir - spread)))
            p.line(to: tip)
            p.line(to: CGPoint(x: tip.x - len * cos(dir + spread), y: tip.y - len * sin(dir + spread)))
            p.lineWidth = max(a.lineWidth, 1.5)
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            color.setStroke()
            p.stroke()
        case .thickArrow:
            let len = max(a.lineWidth * 4.2, 14) * scale
            let spread: CGFloat = .pi / 7
            let p = NSBezierPath()
            p.move(to: tip)
            p.line(to: CGPoint(x: tip.x - len * cos(dir - spread), y: tip.y - len * sin(dir - spread)))
            p.line(to: CGPoint(x: tip.x - len * cos(dir + spread), y: tip.y - len * sin(dir + spread)))
            p.close()
            color.setFill()
            p.fill()
        }
    }

    // MARK: bracket (spec §5 #23 — 8 shapes)

    private static func bracketPath(_ shape: Int, in b: CGRect) -> NSBezierPath {
        switch shape {
        case 0: return curlyVertical(b, tipLeft: true)     // {
        case 1: return curlyVertical(b, tipLeft: false)    // }
        case 2: return squareBracket(b, openRight: true)   // [
        case 3: return squareBracket(b, openRight: false)  // ]
        case 4: return roundBracket(b, openRight: true)    // (
        case 5: return roundBracket(b, openRight: false)   // )
        case 6: return curlyHorizontal(b, tipTop: true)    // ⏞ top
        default: return curlyHorizontal(b, tipTop: false)  // ⏟ bottom
        }
    }

    private static func curlyVertical(_ b: CGRect, tipLeft: Bool) -> NSBezierPath {
        let p = NSBezierPath()
        let mx = b.midX
        let tipX = tipLeft ? b.minX : b.maxX
        let backX = tipLeft ? b.maxX : b.minX
        let q = b.height * 0.25
        p.move(to: CGPoint(x: backX, y: b.minY))
        p.curve(to: CGPoint(x: mx, y: b.minY + q),
                controlPoint1: CGPoint(x: mx, y: b.minY), controlPoint2: CGPoint(x: mx, y: b.minY + q * 0.5))
        p.curve(to: CGPoint(x: tipX, y: b.midY),
                controlPoint1: CGPoint(x: mx, y: b.midY - q * 0.5), controlPoint2: CGPoint(x: mx, y: b.midY))
        p.curve(to: CGPoint(x: mx, y: b.maxY - q),
                controlPoint1: CGPoint(x: mx, y: b.midY), controlPoint2: CGPoint(x: mx, y: b.maxY - q * 0.5))
        p.curve(to: CGPoint(x: backX, y: b.maxY),
                controlPoint1: CGPoint(x: mx, y: b.maxY - q * 0.5), controlPoint2: CGPoint(x: mx, y: b.maxY))
        return p
    }

    private static func curlyHorizontal(_ b: CGRect, tipTop: Bool) -> NSBezierPath {
        let p = NSBezierPath()
        let my = b.midY
        let tipY = tipTop ? b.minY : b.maxY
        let backY = tipTop ? b.maxY : b.minY
        let q = b.width * 0.25
        p.move(to: CGPoint(x: b.minX, y: backY))
        p.curve(to: CGPoint(x: b.minX + q, y: my),
                controlPoint1: CGPoint(x: b.minX, y: my), controlPoint2: CGPoint(x: b.minX + q * 0.5, y: my))
        p.curve(to: CGPoint(x: b.midX, y: tipY),
                controlPoint1: CGPoint(x: b.midX - q * 0.5, y: my), controlPoint2: CGPoint(x: b.midX, y: my))
        p.curve(to: CGPoint(x: b.maxX - q, y: my),
                controlPoint1: CGPoint(x: b.midX, y: my), controlPoint2: CGPoint(x: b.maxX - q * 0.5, y: my))
        p.curve(to: CGPoint(x: b.maxX, y: backY),
                controlPoint1: CGPoint(x: b.maxX - q * 0.5, y: my), controlPoint2: CGPoint(x: b.maxX, y: my))
        return p
    }

    private static func squareBracket(_ b: CGRect, openRight: Bool) -> NSBezierPath {
        let p = NSBezierPath()
        let spine = openRight ? b.minX : b.maxX
        let arm = openRight ? b.maxX : b.minX
        p.move(to: CGPoint(x: arm, y: b.minY))
        p.line(to: CGPoint(x: spine, y: b.minY))
        p.line(to: CGPoint(x: spine, y: b.maxY))
        p.line(to: CGPoint(x: arm, y: b.maxY))
        return p
    }

    private static func roundBracket(_ b: CGRect, openRight: Bool) -> NSBezierPath {
        let p = NSBezierPath()
        let arm = openRight ? b.maxX : b.minX
        let bulge = openRight ? b.minX - b.width * 0.25 : b.maxX + b.width * 0.25
        p.move(to: CGPoint(x: arm, y: b.minY))
        p.curve(to: CGPoint(x: arm, y: b.maxY),
                controlPoint1: CGPoint(x: bulge, y: b.minY + b.height * 0.1),
                controlPoint2: CGPoint(x: bulge, y: b.maxY - b.height * 0.1))
        return p
    }

    // MARK: magnifier (spec §5 #22)

    /// Draws a magnified copy of the background beneath this region, clipped to
    /// the object's bounds, with a border. Samples the raw background image.
    private static func renderMagnifier(_ a: Annotation, stroke: NSColor,
                                        background: CGImage?, ctx: CGContext) {
        let box = a.bounds
        guard let background, box.width >= 2, box.height >= 2 else {
            // Fallback: just an empty framed box.
            stroke.setStroke()
            let bp = NSBezierPath(rect: box); bp.lineWidth = max(a.lineWidth, 1); bp.stroke()
            return
        }
        let zoom = max(a.magnifyZoom, 1.1)
        let srcSize = CGSize(width: box.width / zoom, height: box.height / zoom)
        var src = CGRect(x: box.midX - srcSize.width / 2, y: box.midY - srcSize.height / 2,
                         width: srcSize.width, height: srcSize.height)
        src = src.intersection(CGRect(x: 0, y: 0, width: background.width, height: background.height))
        guard src.width >= 1, src.height >= 1 else {
            stroke.setStroke()
            let bp = NSBezierPath(rect: box); bp.lineWidth = max(a.lineWidth, 1); bp.stroke()
            return
        }
        let crop = ImageOps.crop(background, to: src)
        ctx.saveGState()
        NSBezierPath(rect: box).addClip()
        NSImage(cgImage: crop, size: box.size).draw(in: box)
        ctx.restoreGState()
        stroke.setStroke()
        let border = NSBezierPath(rect: box)
        border.lineWidth = max(a.lineWidth, 1)
        border.stroke()
    }

    // MARK: mouse pointer / icon (spec §5 #17)

    private static func drawPointer(in b: CGRect, right: Bool, highlight: Bool, color: NSColor) {
        if highlight {
            NSColor.systemYellow.withAlphaComponent(0.55).setFill()
            let d = max(b.width, b.height) * 1.5
            NSBezierPath(ovalIn: CGRect(x: b.midX - d / 2, y: b.midY - d / 2, width: d, height: d)).fill()
        }
        // Classic arrow cursor in a 0…1 unit space (tip at top-left).
        let unit: [CGPoint] = [(0, 0), (0, 0.72), (0.2, 0.55), (0.32, 0.86),
                               (0.46, 0.80), (0.34, 0.5), (0.62, 0.5)].map { CGPoint(x: $0.0, y: $0.1) }
        let p = NSBezierPath()
        for (i, u) in unit.enumerated() {
            let x = right ? (1 - u.x) : u.x
            let pt = CGPoint(x: b.minX + x * b.width, y: b.minY + u.y * b.height)
            if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
        }
        p.close()
        color.setFill()
        p.fill()
        NSColor.white.setStroke()
        p.lineWidth = 1.5
        p.stroke()
    }

    private static func calloutPath(box: CGRect, tail: CGPoint) -> NSBezierPath {
        let path = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        // Tail triangle from the edge nearest the anchor.
        let cx = box.midX.clamped(box.minX + 14, box.maxX - 14)
        let tailWidth: CGFloat = 14
        let tri = NSBezierPath()
        if tail.y > box.maxY {          // below
            tri.move(to: CGPoint(x: cx - tailWidth / 2, y: box.maxY - 1))
            tri.line(to: tail)
            tri.line(to: CGPoint(x: cx + tailWidth / 2, y: box.maxY - 1))
        } else if tail.y < box.minY {   // above
            tri.move(to: CGPoint(x: cx - tailWidth / 2, y: box.minY + 1))
            tri.line(to: tail)
            tri.line(to: CGPoint(x: cx + tailWidth / 2, y: box.minY + 1))
        } else if tail.x < box.minX {   // left
            let cy = tail.y.clamped(box.minY + 14, box.maxY - 14)
            tri.move(to: CGPoint(x: box.minX + 1, y: cy - tailWidth / 2))
            tri.line(to: tail)
            tri.line(to: CGPoint(x: box.minX + 1, y: cy + tailWidth / 2))
        } else {                        // right
            let cy = tail.y.clamped(box.minY + 14, box.maxY - 14)
            tri.move(to: CGPoint(x: box.maxX - 1, y: cy - tailWidth / 2))
            tri.line(to: tail)
            tri.line(to: CGPoint(x: box.maxX - 1, y: cy + tailWidth / 2))
        }
        tri.close()
        path.append(tri)
        return path
    }
}

extension CGFloat {
    func clamped(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { Swift.min(Swift.max(self, lo), hi) }
}

extension CGRect {
    /// Codable via array is handled natively by CGRect on Apple platforms.
}

/// Offscreen compositing helper shared by bake/export/thumbnail.
enum Compositor {
    /// background + annotations → flattened CGImage (pixel space).
    static func flatten(background: CGImage, annotations: [Annotation]) -> CGImage {
        let w = background.width, h = background.height
        guard !annotations.isEmpty else { return background }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return background
        }
        // Flip so drawing happens in top-left-origin image space.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        NSImage(cgImage: background, size: CGSize(width: w, height: h))
            .draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        AnnotationRenderer.render(annotations, background: background)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage() ?? background
    }
}
