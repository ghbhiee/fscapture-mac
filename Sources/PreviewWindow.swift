import AppKit
import UniformTypeIdentifiers

/// Basic preview window ("Preview in Editor" placeholder until the Phase 2
/// editor exists). Supports ⌘C copy, ⌘S save-as, Esc/⌘W close, plus toolbar
/// buttons for the three output destinations.
@MainActor
final class PreviewWindowController: NSWindowController, NSWindowDelegate {
    private static var controllers: [PreviewWindowController] = []

    private let image: CGImage

    static func show(image: CGImage) {
        let c = PreviewWindowController(image: image)
        controllers.append(c)
        NSApp.activate(ignoringOtherApps: true)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }

    /// ⌘V / "Import from Clipboard": open the current pasteboard image.
    static func showFromClipboard() {
        let pb = NSPasteboard.general
        guard let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: data),
              let cg = rep.cgImage else {
            OutputRouter.notifyHUD(Loc.t("剪贴板里没有图像", "No image on the clipboard"))
            return
        }
        show(image: cg)
    }

    private init(image: CGImage) {
        self.image = image

        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var contentSize = CGSize(width: CGFloat(image.width) / scale,
                                 height: CGFloat(image.height) / scale)
        let maxSize = CGSize(width: screen.width * 0.8, height: screen.height * 0.8)
        let ratio = min(1, maxSize.width / contentSize.width, maxSize.height / contentSize.height)
        contentSize = CGSize(width: max(320, contentSize.width * ratio),
                             height: max(160, contentSize.height * ratio))

        let window = NSWindow(contentRect: CGRect(origin: .zero, size: contentSize),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = Loc.t("预览 — \(image.width) × \(image.height)", "Preview — \(image.width) × \(image.height)")
        window.center()
        super.init(window: window)
        window.delegate = self

        let imageView = NSImageView()
        let nsImage = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale,
                                                           height: CGFloat(image.height) / scale))
        imageView.image = nsImage
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let editBtn = NSButton(title: Loc.t("编辑", "Edit"), target: self, action: #selector(editAction(_:)))
        let copyBtn = NSButton(title: Loc.t("复制 ⌘C", "Copy ⌘C"), target: self, action: #selector(copyAction(_:)))
        let saveBtn = NSButton(title: Loc.t("另存为… ⌘S", "Save As… ⌘S"), target: self, action: #selector(saveAction(_:)))
        let autoBtn = NSButton(title: Loc.t("自动保存", "Auto Save"), target: self, action: #selector(autoSaveAction(_:)))
        let bar = NSStackView(views: [editBtn, copyBtn, saveBtn, autoBtn])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(imageView)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            bar.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            imageView.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            imageView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            imageView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
        window.contentView = content
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        PreviewWindowController.controllers.removeAll { $0 === self }
    }

    // MARK: actions (also reachable via the main menu's key equivalents)

    @objc func editAction(_ sender: Any?) {
        EditorWindowController.open(image: image)
        close()
    }

    @objc func copyAction(_ sender: Any?) {
        OutputRouter.copyToClipboard(image)
        OutputRouter.notifyHUD(Loc.t("已复制到剪贴板", "Copied to clipboard"))
    }

    @objc func saveAction(_ sender: Any?) {
        OutputRouter.saveWithDialog(image)
    }

    @objc func autoSaveAction(_ sender: Any?) {
        if let url = OutputRouter.autoSave(image) {
            let name = url.lastPathComponent
            OutputRouter.notifyHUD(Loc.t("已保存 \(name)", "Saved \(name)"))
        }
    }

    @objc func copy(_ sender: Any?) { copyAction(sender) }
    @objc func saveDocument(_ sender: Any?) { saveAction(sender) }
}
