import AppKit

// MARK: - Screen Color Picker

/// System eyedropper (NSColorSampler) + a small result window with the
/// picked color in Hex/RGB; hex is copied to the clipboard automatically.
@MainActor
enum ColorPickerTool {
    private static var resultWindow: NSWindow?

    static func run() {
        NSColorSampler().show { color in
            DispatchQueue.main.async {
                guard let color = color?.usingColorSpace(.sRGB) else { return }
                showResult(color)
            }
        }
    }

    private static func showResult(_ color: NSColor) {
        let hex = String(format: "#%02X%02X%02X",
                         Int(round(color.redComponent * 255)),
                         Int(round(color.greenComponent * 255)),
                         Int(round(color.blueComponent * 255)))
        let rgb = "RGB(\(Int(round(color.redComponent * 255))), \(Int(round(color.greenComponent * 255))), \(Int(round(color.blueComponent * 255))))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)

        resultWindow?.close()
        let win = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 96),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = Loc.t("取色结果", "Picked Color")
        win.level = .floating
        win.isReleasedWhenClosed = false

        let swatch = NSView(frame: CGRect(x: 16, y: 20, width: 56, height: 56))
        swatch.wantsLayer = true
        swatch.layer?.backgroundColor = color.cgColor
        swatch.layer?.cornerRadius = 8
        swatch.layer?.borderWidth = 1
        swatch.layer?.borderColor = NSColor.separatorColor.cgColor

        let hexLabel = NSTextField(labelWithString: hex + Loc.t("  (已复制)", "  (copied)"))
        hexLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        hexLabel.frame = CGRect(x: 84, y: 50, width: 150, height: 20)
        let rgbLabel = NSTextField(labelWithString: rgb)
        rgbLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        rgbLabel.textColor = .secondaryLabelColor
        rgbLabel.frame = CGRect(x: 84, y: 28, width: 150, height: 18)

        let content = NSView()
        content.addSubview(swatch)
        content.addSubview(hexLabel)
        content.addSubview(rgbLabel)
        win.contentView = content

        // Near the cursor.
        let mouse = NSEvent.mouseLocation
        win.setFrameOrigin(CGPoint(x: mouse.x + 16, y: mouse.y - 110))
        win.orderFrontRegardless()
        resultWindow = win
    }
}

// MARK: - Screen Magnifier

/// Floating loupe following the cursor: samples the screen under the mouse
/// and shows it at 4× with a crosshair and the center pixel's color.
@MainActor
final class MagnifierTool {
    static var shared: MagnifierTool?

    private let window: NSWindow
    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?
    private let zoom: CGFloat = 4
    private let viewSize = CGSize(width: 264, height: 176)

    static func toggle() {
        if let s = shared {
            s.close()
        } else {
            shared = MagnifierTool()
        }
    }

    private init() {
        window = LoupeWindow(contentRect: CGRect(origin: .zero, size: CGSize(width: viewSize.width, height: viewSize.height + 22)),
                             styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        // Mouse passes through to the content beneath; keyboard still reaches
        // us because we make the window key below.
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = LoupeContentView(frame: CGRect(origin: .zero, size: CGSize(width: viewSize.width, height: viewSize.height + 22)))
        content.onEscape = { MagnifierTool.shared?.close() }
        content.wantsLayer = true
        content.layer?.cornerRadius = 8
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 2
        content.layer?.borderColor = NSColor.controlAccentColor.cgColor
        content.layer?.backgroundColor = NSColor.black.cgColor

        imageView.frame = CGRect(x: 0, y: 22, width: viewSize.width, height: viewSize.height)
        imageView.imageScaling = .scaleAxesIndependently
        content.addSubview(imageView)

        label.frame = CGRect(x: 8, y: 2, width: viewSize.width - 16, height: 18)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        content.addSubview(label)

        // Crosshair overlay.
        let cross = CrossView(frame: imageView.frame)
        content.addSubview(cross)

        window.contentView = content
        window.orderFrontRegardless()
        // Become key so Esc closes the loupe.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(content)
        OutputRouter.notifyHUD(Loc.t("放大镜已开启 · Esc 或再次点击图标关闭",
                                     "Magnifier on · press Esc or click the icon again to close"))

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    private final class LoupeWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private final class LoupeContentView: NSView {
        var onEscape: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
        }
    }

    private final class CrossView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.systemRed.withAlphaComponent(0.8).setStroke()
            let p = NSBezierPath()
            p.move(to: CGPoint(x: bounds.midX, y: bounds.midY - 12))
            p.line(to: CGPoint(x: bounds.midX, y: bounds.midY + 12))
            p.move(to: CGPoint(x: bounds.midX - 12, y: bounds.midY))
            p.line(to: CGPoint(x: bounds.midX + 12, y: bounds.midY))
            p.lineWidth = 1
            p.stroke()
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private func tick() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let displayID = ScreenshotEngine.displayID(of: screen)

        // Sample rect around the cursor, in display-local top-left coords.
        let sampleW = viewSize.width / zoom
        let sampleH = viewSize.height / zoom
        let localX = mouse.x - screen.frame.minX - sampleW / 2
        let localYTop = screen.frame.maxY - mouse.y - sampleH / 2
        let rect = CGRect(x: localX, y: localYTop, width: sampleW, height: sampleH)

        if let cg = CGDisplayCreateImage(displayID, rect: rect) {
            let img = NSImage(cgImage: cg, size: viewSize)
            imageView.image = img
            // Center pixel color.
            if let rep = NSBitmapImageRep(data: img.tiffRepresentation ?? Data()),
               let color = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?
                   .usingColorSpace(.sRGB) {
                let hex = String(format: "#%02X%02X%02X",
                                 Int(round(color.redComponent * 255)),
                                 Int(round(color.greenComponent * 255)),
                                 Int(round(color.blueComponent * 255)))
                label.stringValue = "(\(Int(mouse.x)), \(Int(mouse.y)))  \(hex)  \(Int(zoom))x"
            }
        }

        // Keep the loupe near — but away from — the cursor.
        var origin = CGPoint(x: mouse.x + 24, y: mouse.y + 24)
        if origin.x + window.frame.width > screen.visibleFrame.maxX {
            origin.x = mouse.x - window.frame.width - 24
        }
        if origin.y + window.frame.height > screen.visibleFrame.maxY {
            origin.y = mouse.y - window.frame.height - 24
        }
        window.setFrameOrigin(origin)
    }

    func close() {
        timer?.invalidate()
        window.orderOut(nil)
        MagnifierTool.shared = nil
    }
}

// MARK: - Screen Ruler

/// Semi-transparent pixel ruler. Drag to move, double-click to rotate,
/// drag the right/bottom edge to resize, Esc or right-click → Close.
@MainActor
final class RulerTool {
    static var shared: RulerTool?
    private let window: NSWindow

    static func toggle() {
        if let s = shared {
            s.close()
        } else {
            shared = RulerTool()
        }
    }

    private init() {
        let mouse = NSEvent.mouseLocation
        window = RulerWindow(contentRect: CGRect(x: mouse.x - 300, y: mouse.y - 40, width: 600, height: 80),
                             styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = RulerView()
        window.orderFrontRegardless()
        window.makeKey()
    }

    func close() {
        window.orderOut(nil)
        RulerTool.shared = nil
    }

    private final class RulerWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private final class RulerView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let bg = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
            NSColor(srgbRed: 1.0, green: 0.95, blue: 0.6, alpha: 0.88).setFill()
            bg.fill()
            NSColor(srgbRed: 0.6, green: 0.55, blue: 0.2, alpha: 1).setStroke()
            bg.lineWidth = 1
            bg.stroke()

            let horizontal = bounds.width >= bounds.height
            let length = Int(horizontal ? bounds.width : bounds.height)
            let dark = NSColor(srgbRed: 0.25, green: 0.22, blue: 0.05, alpha: 1)
            dark.setStroke()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: dark,
            ]
            for i in stride(from: 0, through: length, by: 2) {
                let tick: CGFloat = i % 50 == 0 ? 14 : (i % 10 == 0 ? 9 : 5)
                let p = NSBezierPath()
                if horizontal {
                    p.move(to: CGPoint(x: CGFloat(i), y: bounds.maxY))
                    p.line(to: CGPoint(x: CGFloat(i), y: bounds.maxY - tick))
                    p.move(to: CGPoint(x: CGFloat(i), y: bounds.minY))
                    p.line(to: CGPoint(x: CGFloat(i), y: bounds.minY + tick))
                } else {
                    p.move(to: CGPoint(x: bounds.minX, y: bounds.maxY - CGFloat(i)))
                    p.line(to: CGPoint(x: bounds.minX + tick, y: bounds.maxY - CGFloat(i)))
                    p.move(to: CGPoint(x: bounds.maxX, y: bounds.maxY - CGFloat(i)))
                    p.line(to: CGPoint(x: bounds.maxX - tick, y: bounds.maxY - CGFloat(i)))
                }
                p.lineWidth = 1
                p.stroke()
                if i % 50 == 0, i > 0 {
                    let s = "\(i)"
                    if horizontal {
                        s.draw(at: CGPoint(x: CGFloat(i) - 8, y: bounds.midY + 6), withAttributes: attrs)
                    } else {
                        s.draw(at: CGPoint(x: bounds.midX - 8, y: bounds.maxY - CGFloat(i) - 4), withAttributes: attrs)
                    }
                }
            }
            let info = "\(length) px"
            let infoAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: dark,
            ]
            info.draw(at: CGPoint(x: bounds.midX - 24, y: bounds.midY - 8), withAttributes: infoAttrs)
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                // Rotate: swap width/height around the same origin.
                if let w = window {
                    var f = w.frame
                    (f.size.width, f.size.height) = (f.height, f.width)
                    w.setFrame(f, display: true)
                }
                return
            }
            window?.performDrag(with: event)
        }

        override func rightMouseDown(with event: NSEvent) { RulerTool.shared?.close() }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { RulerTool.shared?.close() }
        }

        override var acceptsFirstResponder: Bool { true }
    }
}

// MARK: - Crosshair & Focus overlays

/// Full-screen utility overlays: crosshair guide lines / focus spotlight
/// following the mouse. Click anywhere or press Esc to dismiss.
@MainActor
final class OverlayTool {
    enum Kind { case crosshair, focus }

    static var current: OverlayTool?
    private var windows: [NSWindow] = []
    private var timer: Timer?
    private let kind: Kind
    var focusRadius: CGFloat = 130

    static func toggle(_ kind: Kind) {
        if let cur = current {
            let sameKind = cur.kind == kind
            cur.close()
            if sameKind { return }
        }
        current = OverlayTool(kind: kind)
    }

    private init(kind: Kind) {
        self.kind = kind
        for screen in NSScreen.screens {
            let win = KeyableWindow(contentRect: screen.frame, styleMask: .borderless,
                                    backing: .buffered, defer: false)
            win.level = .screenSaver
            win.backgroundColor = .clear
            win.isOpaque = false
            win.ignoresMouseEvents = false
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            win.contentView = OverlayView(kind: kind, tool: self)
            win.orderFrontRegardless()
            windows.append(win)
        }
        let mouse = NSEvent.mouseLocation
        (windows.first { $0.screen?.frame.contains(mouse) ?? false } ?? windows.first)?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                for w in self?.windows ?? [] { w.contentView?.needsDisplay = true }
            }
        }
    }

    func close() {
        timer?.invalidate()
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        OverlayTool.current = nil
    }

    private final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private final class OverlayView: NSView {
        let kind: Kind
        weak var tool: OverlayTool?

        init(kind: Kind, tool: OverlayTool) {
            self.kind = kind
            self.tool = tool
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }
        override var acceptsFirstResponder: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            guard let window, let screenFrame = window.screen?.frame else { return }
            let mouse = NSEvent.mouseLocation
            let local = CGPoint(x: mouse.x - screenFrame.minX, y: mouse.y - screenFrame.minY)

            switch kind {
            case .crosshair:
                guard screenFrame.contains(mouse) else { return }
                NSColor.systemRed.withAlphaComponent(0.85).setStroke()
                let p = NSBezierPath()
                p.move(to: CGPoint(x: local.x, y: bounds.minY))
                p.line(to: CGPoint(x: local.x, y: bounds.maxY))
                p.move(to: CGPoint(x: bounds.minX, y: local.y))
                p.line(to: CGPoint(x: bounds.maxX, y: local.y))
                p.lineWidth = 1
                p.stroke()
                let text = "(\(Int(mouse.x)), \(Int(mouse.y)))"
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: NSColor.white,
                ]
                let size = text.size(withAttributes: attrs)
                let bg = CGRect(x: local.x + 12, y: local.y + 12, width: size.width + 12, height: size.height + 6)
                NSColor.black.withAlphaComponent(0.7).setFill()
                NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).fill()
                text.draw(at: CGPoint(x: bg.minX + 6, y: bg.minY + 3), withAttributes: attrs)

            case .focus:
                guard let ctx = NSGraphicsContext.current?.cgContext else { return }
                NSColor.black.withAlphaComponent(0.62).setFill()
                if screenFrame.contains(mouse) {
                    let r = tool?.focusRadius ?? 130
                    let hole = CGRect(x: local.x - r, y: local.y - r, width: r * 2, height: r * 2)
                    ctx.saveGState()
                    ctx.addRect(bounds)
                    ctx.addEllipse(in: hole)
                    ctx.clip(using: .evenOdd)
                    ctx.fill(bounds)
                    ctx.restoreGState()
                } else {
                    bounds.fill()
                }
            }
        }

        override func mouseDown(with event: NSEvent) { tool?.close() }
        override func rightMouseDown(with event: NSEvent) { tool?.close() }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { tool?.close() }
        }

        override func scrollWheel(with event: NSEvent) {
            guard kind == .focus, let tool else { return }
            tool.focusRadius = (tool.focusRadius + event.scrollingDeltaY).clamped(50, 500)
            needsDisplay = true
        }
    }
}
