import AppKit

/// "Pin to Screen": a captured image floating above everything like a sticky
/// note. Drag to move, scroll to scale, double-click or Esc to close,
/// right-click for copy/save/opacity/close.
@MainActor
final class PinWindow: NSWindow {
    private static var pins: [PinWindow] = []
    private let image: CGImage
    private var scaleFactor: CGFloat = 1

    /// `frame` is the on-screen rect (Cocoa points) where the capture came
    /// from, so the pin appears exactly in place.
    static func show(image: CGImage, at frame: CGRect) {
        let pin = PinWindow(image: image, frame: frame)
        pins.append(pin)
        pin.orderFrontRegardless()
    }

    private init(image: CGImage, frame: CGRect) {
        self.image = image
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = PinView(image: image)
        contentView = view
    }

    override var canBecomeKey: Bool { true }

    private func rescale(by delta: CGFloat) {
        scaleFactor = (scaleFactor * (1 + delta)).clamped(0.2, 4)
        let base = CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
        let screenScale = screen?.backingScaleFactor ?? 2
        let size = CGSize(width: base.width / screenScale * scaleFactor,
                          height: base.height / screenScale * scaleFactor)
        var f = frame
        let center = CGPoint(x: f.midX, y: f.midY)
        f = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                   width: size.width, height: size.height)
        setFrame(f, display: true)
    }

    private func closePin() {
        orderOut(nil)
        PinWindow.pins.removeAll { $0 === self }
    }

    private final class PinView: NSView {
        let image: CGImage
        private let closeButton = NSButton()
        init(image: CGImage) {
            self.image = image
            super.init(frame: .zero)
            wantsLayer = true
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.9).cgColor

            // Close (×) button in the top-right corner.
            closeButton.title = "✕"
            closeButton.isBordered = false
            closeButton.font = .systemFont(ofSize: 11, weight: .bold)
            closeButton.contentTintColor = .white
            closeButton.wantsLayer = true
            closeButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
            closeButton.layer?.cornerRadius = 9
            closeButton.target = self
            closeButton.action = #selector(closeTapped)
            addSubview(closeButton)
        }
        required init?(coder: NSCoder) { fatalError() }
        override var acceptsFirstResponder: Bool { true }

        override func layout() {
            super.layout()
            let s: CGFloat = 18   // top-right (view is bottom-left origin)
            closeButton.frame = CGRect(x: bounds.maxX - s - 4, y: bounds.maxY - s - 4, width: s, height: s)
        }

        @objc private func closeTapped() { (window as? PinWindow)?.closePin() }

        override func draw(_ dirtyRect: NSRect) {
            NSImage(cgImage: image, size: bounds.size).draw(in: bounds)
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                (window as? PinWindow)?.closePin()
                return
            }
            window?.performDrag(with: event)
        }

        override func scrollWheel(with event: NSEvent) {
            (window as? PinWindow)?.rescale(by: event.scrollingDeltaY * 0.01)
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 53, 51: (window as? PinWindow)?.closePin()  // Esc / Delete
            default: super.keyDown(with: event)
            }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = NSMenu()
            let copy = NSMenuItem(title: Loc.t("复制图像", "Copy Image"), action: #selector(copyImage(_:)), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
            let save = NSMenuItem(title: Loc.t("另存为…", "Save As…"), action: #selector(saveImage(_:)), keyEquivalent: "")
            save.target = self
            menu.addItem(save)
            let edit = NSMenuItem(title: Loc.t("在编辑器中打开", "Open in Editor"), action: #selector(editImage(_:)), keyEquivalent: "")
            edit.target = self
            menu.addItem(edit)
            menu.addItem(.separator())
            for pct in [100, 80, 60, 40] {
                let item = NSMenuItem(title: Loc.t("不透明度 \(pct)%", "Opacity \(pct)%"), action: #selector(setOpacity(_:)), keyEquivalent: "")
                item.target = self
                item.tag = pct
                item.state = Int((window?.alphaValue ?? 1) * 100) == pct ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let close = NSMenuItem(title: Loc.t("关闭钉屏", "Close Pin"), action: #selector(closeSelf(_:)), keyEquivalent: "")
            close.target = self
            menu.addItem(close)
            return menu
        }

        @objc private func copyImage(_ sender: Any?) {
            OutputRouter.copyToClipboard(image)
            OutputRouter.notifyHUD(Loc.t("已复制到剪贴板", "Copied to clipboard"))
        }

        @objc private func saveImage(_ sender: Any?) {
            OutputRouter.saveWithDialog(image)
        }

        @objc private func editImage(_ sender: Any?) {
            EditorWindowController.open(image: image)
        }

        @objc private func setOpacity(_ sender: NSMenuItem) {
            window?.alphaValue = CGFloat(sender.tag) / 100
        }

        @objc private func closeSelf(_ sender: Any?) {
            (window as? PinWindow)?.closePin()
        }
    }
}
