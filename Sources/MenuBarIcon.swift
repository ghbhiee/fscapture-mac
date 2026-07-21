import AppKit

/// Monochrome line-art version of the app's pinwheel-sail motif, used as the
/// status-bar (menu bar) template image. Drawn at runtime — no assets.
@MainActor
enum MenuBarIcon {

    static func make() -> NSImage {
        let side: CGFloat = 18
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            // Same petal geometry as the app icon, scaled from the 1024 design.
            func petal(pivot: CGPoint, tip: CGPoint, width: CGFloat) -> NSBezierPath {
                let dx = tip.x - pivot.x, dy = tip.y - pivot.y
                let len = max(1, sqrt(dx * dx + dy * dy))
                let nx = -dy / len, ny = dx / len
                let p = NSBezierPath()
                p.move(to: pivot)
                p.curve(to: tip,
                        controlPoint1: CGPoint(x: pivot.x + dx * 0.25 + nx * width,
                                               y: pivot.y + dy * 0.25 + ny * width),
                        controlPoint2: CGPoint(x: pivot.x + dx * 0.82 + nx * width * 0.85,
                                               y: pivot.y + dy * 0.82 + ny * width * 0.85))
                p.curve(to: pivot,
                        controlPoint1: CGPoint(x: pivot.x + dx * 0.80 - nx * width * 0.30,
                                               y: pivot.y + dy * 0.80 - ny * width * 0.30),
                        controlPoint2: CGPoint(x: pivot.x + dx * 0.25 - nx * width * 0.40,
                                               y: pivot.y + dy * 0.25 - ny * width * 0.40))
                p.close()
                return p
            }

            let s = side / 1024
            // Slightly enlarged relative to the tile since there is no bezel.
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: (x - 512) * 1.25 * s + side / 2, y: (y - 500) * 1.25 * s + side / 2)
            }
            let hub = pt(500, 470)
            let sails: [(CGPoint, CGFloat)] = [
                (pt(250, 856), 168 * 1.25 * s),
                (pt(862, 610), 150 * 1.25 * s),
                (pt(388, 158), 122 * 1.25 * s),
            ]
            NSColor.black.setStroke()
            for (tip, w) in sails {
                let path = petal(pivot: hub, tip: tip, width: w)
                path.lineWidth = 1.2
                path.lineJoinStyle = .round
                path.stroke()
            }
            return true
        }
        img.isTemplate = true   // adapts to light/dark menu bar automatically
        return img
    }
}
