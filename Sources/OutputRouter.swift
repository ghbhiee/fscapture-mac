import AppKit
import UniformTypeIdentifiers

/// Routes a finished capture to its destination (clipboard / save dialog /
/// auto-save), optionally passing through the preview window first.
@MainActor
enum OutputRouter {

    static func deliver(_ image: CGImage) {
        let destination = Settings.shared.destination
        if destination == .editor {
            EditorWindowController.open(image: image)
            if Settings.shared.editorAlsoCopyToClipboard {
                copyToClipboard(image)
                notifyHUD(Loc.t("已进编辑器并复制到剪贴板", "Opened in editor and copied to clipboard"))
            }
        } else if Settings.shared.previewEnabled {
            PreviewWindowController.show(image: image)
        } else {
            send(image, to: destination)
        }
    }

    static func send(_ image: CGImage, to destination: OutputDestination) {
        switch destination {
        case .editor:
            EditorWindowController.open(image: image)
        case .clipboard:
            copyToClipboard(image)
            notifyHUD(Loc.t("已复制到剪贴板", "Copied to clipboard"))
        case .file:
            saveWithDialog(image)
        case .autoSave:
            if let url = autoSave(image) {
                if Settings.shared.autoSaveCopyToClipboard { copyToClipboard(image) }
                let name = url.lastPathComponent
                notifyHUD(Loc.t("已保存 \(name)", "Saved \(name)"))
            }
        case .printer:
            printImage(image)
        case .share:
            shareImage(image)
        }
    }

    // MARK: printer

    /// Print a single image on one page, scaled to fit (FastStone "To Printer").
    static func printImage(_ image: CGImage) {
        NSApp.activate(ignoringOtherApps: true)
        let size = NSSize(width: image.width, height: image.height)
        let view = NSImageView(frame: CGRect(origin: .zero, size: size))
        view.image = NSImage(cgImage: image, size: size)
        view.imageScaling = .scaleProportionallyUpOrDown
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.run()
    }

    // MARK: share sheet

    /// Retained so the transient anchor window outlives this call while the
    /// share popover is on screen.
    private static var shareAnchorWindow: NSWindow?

    /// Present the macOS share sheet for `image`. `anchor` is a live view the
    /// popover attaches to; when nil (capture routed straight to Share, no host
    /// window) a tiny transparent anchor is floated near the top of the screen.
    static func shareImage(_ image: CGImage, from anchor: NSView? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let size = NSSize(width: image.width, height: image.height)
        let nsImage = NSImage(cgImage: image, size: size)
        let picker = NSSharingServicePicker(items: [nsImage])
        if let anchor {
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            return
        }
        guard let screen = NSScreen.main else { return }
        let anchorSize = CGSize(width: 40, height: 8)
        let frame = CGRect(x: screen.frame.midX - anchorSize.width / 2,
                           y: screen.visibleFrame.maxY - 40,
                           width: anchorSize.width, height: anchorSize.height)
        shareAnchorWindow?.orderOut(nil)
        let win = NSWindow(contentRect: frame, styleMask: .borderless,
                           backing: .buffered, defer: false)
        win.level = .statusBar
        win.backgroundColor = .clear
        win.isOpaque = false
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .transient]
        let view = NSView(frame: CGRect(origin: .zero, size: anchorSize))
        win.contentView = view
        win.orderFrontRegardless()
        shareAnchorWindow = win
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    // MARK: clipboard

    static func copyToClipboard(_ image: CGImage) {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = CGSize(width: image.width, height: image.height)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)
        if let tiff = rep.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
    }

    // MARK: files

    static func encode(_ image: CGImage, format: ImageFormat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = CGSize(width: image.width, height: image.height)
        switch format {
        case .png:
            return rep.representation(using: .png, properties: [:])
        case .jpeg:
            return rep.representation(using: .jpeg,
                                      properties: [.compressionFactor: Settings.shared.jpegQuality])
        }
    }

    static func saveWithDialog(_ image: CGImage) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        let format = Settings.shared.imageFormat
        panel.allowedContentTypes = [format == .png ? UTType.png : UTType.jpeg, .png, .jpeg]
        panel.nameFieldStringValue = FilenameTemplate.expand(Settings.shared.filenameTemplate)
            + "." + format.fileExtension
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let chosen: ImageFormat = url.pathExtension.lowercased().hasPrefix("j") ? .jpeg : .png
            if let data = encode(image, format: chosen) {
                try? data.write(to: url)
            }
        }
    }

    /// Writes with the filename template into the auto-save folder. Returns the URL.
    @discardableResult
    static func autoSave(_ image: CGImage) -> URL? {
        let folder = Settings.shared.autoSaveFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let format = Settings.shared.imageFormat
        let base = FilenameTemplate.expand(Settings.shared.filenameTemplate)
        let url = FilenameTemplate.uniqueURL(in: folder, baseName: base, ext: format.fileExtension)
        guard let data = encode(image, format: format) else { return nil }
        do {
            try data.write(to: url)
            return url
        } catch {
            NSLog("FSCapture: auto-save failed: \(error)")
            return nil
        }
    }

    // MARK: HUD

    /// Small transient confirmation near the top of the screen.
    static func notifyHUD(_ text: String) {
        guard let screen = NSScreen.main else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        let w = size.width + 32, h = size.height + 16
        let frame = CGRect(x: screen.frame.midX - w / 2,
                           y: screen.visibleFrame.maxY - h - 24, width: w, height: h)
        let win = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.level = .statusBar
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = true
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .transient]

        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        view.layer?.cornerRadius = h / 2
        let label = NSTextField(labelWithString: text)
        label.font = attrs[.font] as? NSFont
        label.textColor = .white
        label.frame = CGRect(x: 16, y: 8, width: size.width, height: size.height)
        view.addSubview(label)
        win.contentView = view
        win.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                win.animator().alphaValue = 0
            }, completionHandler: {
                win.orderOut(nil)
            })
        }
    }
}
