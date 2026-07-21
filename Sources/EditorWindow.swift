import AppKit
import PDFKit
import UniformTypeIdentifiers

/// The multi-tab editor window (FastStone TImgFrame equivalent, Phase 2).
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, EditorCanvasDelegate {
    static let shared = EditorWindowController()

    private var documents: [EditorDocument] = []
    private var currentIndex = -1

    private let tabBar = NSStackView()
    private let toolStrip = NSStackView()
    private let canvas = EditorCanvasView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var drawController: DrawModeController?
    private var editorRootView: NSView!

    var currentDocument: EditorDocument? {
        documents.indices.contains(currentIndex) ? documents[currentIndex] : nil
    }

    private init() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1080, height: 760),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = Loc.t("FSCapture 编辑器", "FSCapture Editor")
        window.center()
        window.setFrameAutosaveName("EditorWindow")
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()

        NotificationCenter.default.addObserver(forName: .editorDocumentChanged,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.canvas.refreshFromDocument()
                self?.refreshTabBar()
                self?.updateStatus()
            }
        }
        // Keep the zoom % in the status bar honest during live zoom/scroll.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatus() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: public entry points

    static func open(image: CGImage, url: URL? = nil) {
        let doc = EditorDocument(background: image, fileURL: url)
        shared.add(document: doc)
        shared.present()
    }

    /// Open the current clipboard image in a new editor tab (⌥V / menu).
    static func openFromClipboard() {
        let pb = NSPasteboard.general
        guard let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: data), let cg = rep.cgImage else {
            OutputRouter.notifyHUD(Loc.t("剪贴板里没有图像", "No image on the clipboard"))
            return
        }
        open(image: cg)
    }

    static func open(url: URL) {
        do {
            if url.pathExtension.lowercased() == "fscx" {
                let doc = try FSCX.load(from: url)
                shared.add(document: doc)
            } else if let img = NSImage(contentsOf: url),
                      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                shared.add(document: EditorDocument(background: cg, fileURL: url))
            } else {
                let name = url.lastPathComponent
                OutputRouter.notifyHUD(Loc.t("无法打开 \(name)", "Can't open \(name)"))
                return
            }
            shared.present()
        } catch {
            OutputRouter.notifyHUD(Loc.t("打开失败：\(error.localizedDescription)", "Open failed: \(error.localizedDescription)"))
        }
    }

    func present() {
        DockIcon.update(editorVisible: true)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
    }

    var hasContent: Bool { !documents.isEmpty }

    // MARK: UI skeleton

    private func buildUI() {
        tabBar.orientation = .horizontal
        tabBar.spacing = 2
        tabBar.alignment = .centerY
        tabBar.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        // Distinct background so the tab row reads apart from the tool strip.
        tabBar.wantsLayer = true
        tabBar.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor

        buildToolStrip()

        scrollView.contentView = CenteringClipView()
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 16
        // FastStone's editor background: mid gray RGB(200,200,200) (measured).
        scrollView.backgroundColor = NSColor(srgbRed: 200 / 255, green: 200 / 255,
                                             blue: 200 / 255, alpha: 1)
        // Breathing room around the canvas — especially on top, so a white
        // screenshot never blends into the toolbar.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 28, left: 24, bottom: 24, right: 24)
        canvas.delegate = self
        (scrollView.contentView as? CenteringClipView)?.onBackgroundMouseDown = { [weak self] in
            self?.canvas.clearSelection()
        }

        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        let statusBar = NSView()
        statusBar.addSubview(statusLabel)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 10),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 22),
        ])

        let root = NSStackView(views: [tabBar, toolStrip, scrollView, statusBar])
        root.orientation = .vertical
        root.spacing = 0
        root.distribution = .fill
        tabBar.heightAnchor.constraint(equalToConstant: 30).isActive = true
        toolStrip.heightAnchor.constraint(equalToConstant: 34).isActive = true
        editorRootView = root
        window?.contentView = root
    }

    private func toolButton(_ symbol: String, _ tooltip: String, _ action: Selector) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        let b = NSButton(image: img ?? NSImage(), target: self, action: action)
        b.bezelStyle = .texturedRounded
        b.isBordered = false
        b.toolTip = tooltip
        b.widthAnchor.constraint(equalToConstant: 30).isActive = true
        return b
    }

    private func stripSeparator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 10).isActive = true
        return box
    }

    private func buildToolStrip() {
        toolStrip.orientation = .horizontal
        toolStrip.spacing = 2
        toolStrip.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
        // Select-mode popup (Pan/Scroll · Rectangle · Circle · Freehand ·
        // Freehand 2 · R-Rectangle), mirroring the original dropdown.
        let selectPopup = NSPopUpButton()
        for shape in SelectShape.allCases {
            selectPopup.addItem(withTitle: shape.label)
            selectPopup.lastItem?.image = NSImage(systemSymbolName: shape.symbolName,
                                                  accessibilityDescription: shape.label)
        }
        selectPopup.selectItem(at: 1)  // Rectangle default
        selectPopup.target = self
        selectPopup.action = #selector(selectModeChanged(_:))
        selectPopup.toolTip = Loc.t("选区形状 / 平移", "Select Mode — shape / pan")
        selectPopup.widthAnchor.constraint(equalToConstant: 130).isActive = true

        let items: [NSView] = [
            toolButton("folder", Loc.t("打开… (⌘O)", "Open… (⌘O)"), #selector(openDocument(_:))),
            toolButton("square.and.arrow.down", Loc.t("保存 (⌘S)", "Save (⌘S)"), #selector(saveDocument(_:))),
            toolButton("square.and.arrow.down.on.square", Loc.t("另存为… (⌥⌘S)", "Save As… (⌥⌘S)"), #selector(saveDocumentAs(_:))),
            stripSeparator(),
            selectPopup,
            toolButton("paintbrush.pointed", Loc.t("Draw 标注 (D)", "Draw / Annotate (D)"), #selector(enterDraw(_:))),
            stripSeparator(),
            toolButton("crop", Loc.t("裁剪到选区 (X)", "Crop to Selection (X)"), #selector(cropAction(_:))),
            toolButton("arrow.up.left.and.arrow.down.right", Loc.t("调整尺寸… (⌘R)", "Resize… (⌘R)"), #selector(resizeAction(_:))),
            toolButton("rotate.left", Loc.t("左转 (L)", "Rotate Left (L)"), #selector(rotateLeft(_:))),
            toolButton("rotate.right", Loc.t("右转 (R)", "Rotate Right (R)"), #selector(rotateRight(_:))),
            toolButton("arrow.left.and.right.righttriangle.left.righttriangle.right", Loc.t("水平翻转 (H)", "Flip Horizontal (H)"), #selector(flipH(_:))),
            toolButton("arrow.up.and.down.righttriangle.up.righttriangle.down", Loc.t("垂直翻转 (V)", "Flip Vertical (V)"), #selector(flipV(_:))),
            stripSeparator(),
            toolButton("slider.horizontal.3", Loc.t("调整颜色… (⌘E)", "Adjust Colors… (⌘E)"), #selector(adjustColors(_:))),
            toolButton("circle.lefthalf.filled", Loc.t("灰度", "Grayscale"), #selector(grayscaleAction(_:))),
            toolButton("circle.righthalf.filled.inverse", Loc.t("反色 (⌘I)", "Negative (⌘I)"), #selector(invertAction(_:))),
            toolButton("wand.and.rays", Loc.t("锐化/模糊… (⌘U)", "Sharpen / Blur… (⌘U)"), #selector(sharpenBlur(_:))),
            toolButton("mosaic", Loc.t("模糊选区 (B)", "Blur Selection (B)"), #selector(blurSelection(_:))),
            toolButton("flashlight.on.fill", Loc.t("聚光灯 (O)", "Spotlight (O)"), #selector(spotlightSelection(_:))),
            stripSeparator(),
            toolButton("square.dashed", Loc.t("边缘 / 水印… (G)", "Edge / Watermark… (G)"), #selector(edgeWatermarkEffect(_:))),
            toolButton("text.below.photo", Loc.t("标题栏… (T)", "Caption… (T)"), #selector(captionEffect(_:))),
            toolButton("calendar.badge.clock", Loc.t("日期时间戳… (J)", "Date Time Stamp… (J)"), #selector(stampEffect(_:))),
            toolButton("photo.stack", Loc.t("倒影… (F)", "Reflection… (F)"), #selector(reflectionEffect(_:))),
            stripSeparator(),
            toolButton("doc.on.doc", Loc.t("复制 (⌘C)", "Copy (⌘C)"), #selector(copyImage(_:))),
            toolButton("rectangle.stack", Loc.t("合并所有标签为一张图… (⌘H)", "Combine All Tabs into One Image… (⌘H)"), #selector(combineIntoImage(_:))),
            toolButton("doc.append", Loc.t("合并所有标签为 PDF… (⌘G)", "Combine All Tabs into PDF… (⌘G)"), #selector(combineIntoPDF(_:))),
            toolButton("printer", Loc.t("打印… (⌘P)", "Print… (⌘P)"), #selector(printImageAction(_:))),
            toolButton("square.and.arrow.up", Loc.t("分享…", "Share…"), #selector(shareImageAction(_:))),
        ]
        for v in items { toolStrip.addArrangedSubview(v) }
        toolStrip.addArrangedSubview(NSView())  // spring
    }

    // MARK: tabs

    private var untitledSeq = 0

    private func add(document: EditorDocument) {
        if document.fileURL == nil, document.title == nil {
            untitledSeq += 1
            document.title = Loc.t("未命名 \(untitledSeq)", "Untitled \(untitledSeq)")
        }
        documents.append(document)
        currentIndex = documents.count - 1
        canvas.document = document
        refreshTabBar()
        updateStatus()
        fitIfLarge()
    }

    private func selectTab(_ index: Int) {
        guard documents.indices.contains(index) else { return }
        currentIndex = index
        canvas.document = documents[index]
        refreshTabBar()
        updateStatus()
        fitIfLarge()
        window?.makeFirstResponder(canvas)
    }

    private func closeTab(_ index: Int) {
        guard documents.indices.contains(index) else { return }
        let doc = documents[index]
        if doc.isDirty {
            let alert = NSAlert()
            let docName = doc.displayName
            alert.messageText = Loc.t("「\(docName)」有未保存的修改", "\"\(docName)\" has unsaved changes")
            alert.addButton(withTitle: Loc.t("保存", "Save"))
            alert.addButton(withTitle: Loc.t("不保存", "Don't Save"))
            alert.addButton(withTitle: Loc.t("取消", "Cancel"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                currentIndex = index
                saveDocument(nil)
                if doc.isDirty { return }  // save was cancelled
            case .alertThirdButtonReturn:
                return
            default:
                break
            }
        }
        documents.remove(at: index)
        if documents.isEmpty {
            currentIndex = -1
            canvas.document = nil
            window?.orderOut(nil)
            DockIcon.update(editorVisible: false)
        } else {
            currentIndex = min(index, documents.count - 1)
            canvas.document = documents[currentIndex]
        }
        refreshTabBar()
        updateStatus()
    }

    private func refreshTabBar() {
        // Only show the tab row when there's more than one document (a lone tab
        // needs no chrome).
        tabBar.isHidden = documents.count <= 1
        for v in tabBar.arrangedSubviews { v.removeFromSuperview() }
        for (i, doc) in documents.enumerated() {
            let title = (doc.isDirty ? "● " : "") + doc.displayName
            let btn = NSButton(title: title, target: self, action: #selector(tabClicked(_:)))
            btn.tag = i
            btn.bezelStyle = .texturedRounded
            btn.state = i == currentIndex ? .on : .off
            btn.font = .systemFont(ofSize: 11, weight: i == currentIndex ? .semibold : .regular)
            btn.contentTintColor = i == currentIndex ? .controlAccentColor : .secondaryLabelColor
            tabBar.addArrangedSubview(btn)
            let close = NSButton(title: "×", target: self, action: #selector(tabCloseClicked(_:)))
            close.tag = i
            close.isBordered = false
            close.font = .systemFont(ofSize: 11)
            tabBar.addArrangedSubview(close)
        }
        tabBar.addArrangedSubview(NSView())
    }

    @objc private func tabClicked(_ sender: NSButton) { selectTab(sender.tag) }
    @objc private func tabCloseClicked(_ sender: NSButton) { closeTab(sender.tag) }

    private func fitIfLarge() {
        guard let doc = currentDocument else { return }
        let insets = scrollView.contentInsets
        let avail = CGSize(width: scrollView.frame.width - insets.left - insets.right - 4,
                           height: scrollView.frame.height - insets.top - insets.bottom - 4)
        guard avail.width > 50, avail.height > 50 else {
            // Window not laid out yet (first open) — retry after layout.
            DispatchQueue.main.async { [weak self] in self?.fitIfLarge() }
            return
        }
        let ratio = min(avail.width / doc.pixelSize.width, avail.height / doc.pixelSize.height)
        scrollView.magnification = min(1, ratio)
        // Re-run the centering constraint explicitly — it otherwise only fires
        // on window resize/scroll, leaving a freshly opened canvas top-left.
        let clip = scrollView.contentView
        let fitsW = doc.pixelSize.width * scrollView.magnification + insets.left + insets.right
            <= scrollView.frame.width + 1
        let fitsH = doc.pixelSize.height * scrollView.magnification + insets.top + insets.bottom
            <= scrollView.frame.height + 1
        if fitsW && fitsH {
            clip.setBoundsOrigin(clip.constrainBoundsRect(clip.bounds).origin)
        } else {
            clip.scroll(to: CGPoint(x: -insets.left, y: -insets.top))
        }
        scrollView.reflectScrolledClipView(clip)
        updateStatus()
    }

    private func updateStatus() {
        guard let doc = currentDocument else {
            statusLabel.stringValue = ""
            return
        }
        var s = "\(Int(doc.pixelSize.width)) × \(Int(doc.pixelSize.height)) px"
        s += String(format: "   %.0f%%", scrollView.magnification * 100)
        if let sel = canvas.selectionRect {
            s += Loc.t("   选区 \(Int(sel.width)) × \(Int(sel.height))", "   Selection \(Int(sel.width)) × \(Int(sel.height))")
        }
        if !doc.annotations.isEmpty {
            let n = doc.annotations.count
            s += Loc.t("   〔\(n) 个标注对象〕", "   [\(n) annotations]")
        }
        statusLabel.stringValue = s
    }

    // MARK: EditorCanvasDelegate

    func canvasSelectionChanged(_ selection: CGRect?) { updateStatus() }

    func canvasRequestsCrop() { cropAction(nil) }

    func canvasCanvasResized() {
        refreshTabBar()
        updateStatus()
    }

    @objc private func selectModeChanged(_ sender: NSPopUpButton) {
        let shape = SelectShape.allCases[max(0, sender.indexOfSelectedItem)]
        canvas.selectShape = shape
        window?.invalidateCursorRects(for: canvas)
        window?.makeFirstResponder(canvas)
    }

    func canvasKeyCommand(_ key: String) {
        switch key {
        case "remove-h": stripAction(horizontal: true, insert: false)
        case "remove-v": stripAction(horizontal: false, insert: false)
        case "insert-h": stripAction(horizontal: true, insert: true)
        case "insert-v": stripAction(horizontal: false, insert: true)
        case "d": enterDraw(nil)
        case "l": rotateLeft(nil)
        case "r": rotateRight(nil)
        case "h": flipH(nil)
        case "v": flipV(nil)
        case "b": blurSelection(nil)
        case "o": spotlightSelection(nil)
        case "g": edgeWatermarkEffect(nil)
        case "t": captionEffect(nil)
        case "j": stampEffect(nil)
        case "f": reflectionEffect(nil)
        case "c": cloneToolAction(nil)
        case "0": fitIfLarge(); updateStatus()
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            scrollView.magnification = CGFloat(Int(key) ?? 1)
            updateStatus()
        case "+", "=": scrollView.magnification *= 1.25; updateStatus()
        case "-": scrollView.magnification /= 1.25; updateStatus()
        default: break
        }
    }

    // MARK: file actions

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .gif, .pdf,
                                     UTType(filenameExtension: "fscx") ?? .data]
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls { EditorWindowController.open(url: url) }
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        guard let doc = currentDocument else { return }
        canvas.anchorFloating()
        if let url = doc.fileURL {
            do {
                try write(doc, to: url)
                doc.isDirty = false
                refreshTabBar()
                let name = url.lastPathComponent
                OutputRouter.notifyHUD(Loc.t("已保存 \(name)", "Saved \(name)"))
            } catch {
                OutputRouter.notifyHUD(Loc.t("保存失败：\(error.localizedDescription)", "Save failed: \(error.localizedDescription)"))
            }
        } else {
            saveDocumentAs(sender)
        }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard let doc = currentDocument else { return }
        canvas.anchorFloating()
        let panel = NSSavePanel()
        var types: [UTType] = []
        if let fscx = UTType(filenameExtension: "fscx") { types.append(fscx) }
        types += [.png, .jpeg, .tiff, .bmp, .gif, .pdf]
        panel.allowedContentTypes = types
        let defaultExt = doc.annotations.isEmpty ? "png" : "fscx"
        panel.nameFieldStringValue = FilenameTemplate.expand(Settings.shared.filenameTemplate)
            + "." + defaultExt
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try self.write(doc, to: url)
                doc.fileURL = url
                doc.isDirty = false
                self.refreshTabBar()
                let name = url.lastPathComponent
                OutputRouter.notifyHUD(Loc.t("已保存 \(name)", "Saved \(name)"))
            } catch {
                OutputRouter.notifyHUD(Loc.t("保存失败：\(error.localizedDescription)", "Save failed: \(error.localizedDescription)"))
            }
        }
    }

    private func write(_ doc: EditorDocument, to url: URL) throws {
        let format = ExportFormat.from(extension: url.pathExtension) ?? .png
        if format == .fscx {
            try FSCX.save(doc, to: url)
        } else {
            try Export.write(doc.composited, to: url, format: format)
        }
    }

    @objc func copyImage(_ sender: Any?) {
        guard currentDocument != nil else { return }
        canvas.copySelectionOrAll()
    }

    /// New Tab (⌘T) — the standard macOS multi-tab shortcut. Opens a fresh
    /// blank white canvas as a new tab (FastStone "New" / TNewImage).
    @objc func newBlankTab(_ sender: Any?) {
        let w = 800, h = 600
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        guard let img = ctx.makeImage() else { return }
        EditorWindowController.open(image: img)
    }

    @objc func pasteAsNewTab(_ sender: Any?) {
        let pb = NSPasteboard.general
        guard let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: data), let cg = rep.cgImage else {
            OutputRouter.notifyHUD(Loc.t("剪贴板里没有图像", "No image on the clipboard"))
            return
        }
        EditorWindowController.open(image: cg)
    }

    // MARK: output / batch

    /// Print the current tab's composited image (⌘P).
    @objc func printImageAction(_ sender: Any?) {
        guard let doc = currentDocument else { return }
        canvas.anchorFloating()
        OutputRouter.printImage(doc.composited)
    }

    /// Send the current tab's composited image to the macOS share sheet.
    @objc func shareImageAction(_ sender: Any?) {
        guard let doc = currentDocument else { return }
        canvas.anchorFloating()
        // Anchor the popover to the clicking control when possible, otherwise
        // to the tool strip.
        let anchor = (sender as? NSView) ?? toolStrip
        OutputRouter.shareImage(doc.composited, from: anchor)
    }

    /// Combine every open tab into one multi-page PDF, one page per image (⌘G).
    @objc func combineIntoPDF(_ sender: Any?) {
        guard !documents.isEmpty else { return }
        canvas.anchorFloating()
        let pdf = PDFDocument()
        for (i, doc) in documents.enumerated() {
            let img = doc.composited
            let nsImage = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
            if let page = PDFPage(image: nsImage) { pdf.insert(page, at: i) }
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = FilenameTemplate.expand(Settings.shared.filenameTemplate) + ".pdf"
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if pdf.write(to: url) {
                let pages = pdf.pageCount
                OutputRouter.notifyHUD(Loc.t("已导出 PDF（\(pages) 页）", "Exported PDF (\(pages) pages)"))
            } else {
                OutputRouter.notifyHUD(Loc.t("导出 PDF 失败", "PDF export failed"))
            }
        }
    }

    /// Combine every open tab into one image, opened as a new tab (⌘H /
    /// tool strip). Shows the FastStone TCombineImages dialog first
    /// (direction / spacing / background), then stacks accordingly.
    @objc func combineIntoImage(_ sender: Any?) {
        guard !documents.isEmpty else { return }
        canvas.anchorFloating()
        let images = documents.map { $0.composited }
        guard images.count >= 2 else {
            OutputRouter.notifyHUD(Loc.t("至少需要两个标签页才能合并", "Need at least two tabs to combine"))
            return
        }
        guard let opts = CombinePanel.run(count: images.count) else { return }
        guard let combined = ImageOps.stack(images, horizontal: opts.horizontal,
                                            spacing: opts.spacing, fill: opts.background) else {
            OutputRouter.notifyHUD(Loc.t("合并图像失败", "Failed to combine images"))
            return
        }
        EditorWindowController.open(image: combined)
        let n = images.count
        OutputRouter.notifyHUD(Loc.t("已合并 \(n) 张图像", "Combined \(n) images"))
    }

    // MARK: edit actions

    @objc func cropAction(_ sender: Any?) {
        guard currentDocument != nil, let sel = canvas.selectionRect,
              sel.width >= 2, sel.height >= 2 else { return }
        canvas.cropToSelectionPath()
        refreshTabBar()
        updateStatus()
    }

    @objc func cutAction(_ sender: Any?) {
        canvas.cutSelection()
        refreshTabBar()
        updateStatus()
    }

    @objc func deleteAction(_ sender: Any?) {
        canvas.deleteSelection()
        refreshTabBar()
        updateStatus()
    }

    @objc func pasteAction(_ sender: Any?) {
        if currentDocument != nil {
            canvas.pasteAsFloating()
        } else {
            pasteAsNewTab(sender)
        }
    }

    @objc func rotateLeft(_ sender: Any?) { rasterOp(Loc.t("左转", "Rotate Left")) { ImageOps.rotate90($0, clockwise: false) } }
    @objc func rotateRight(_ sender: Any?) { rasterOp(Loc.t("右转", "Rotate Right")) { ImageOps.rotate90($0, clockwise: true) } }
    @objc func flipH(_ sender: Any?) { rasterOp(Loc.t("水平翻转", "Flip Horizontal")) { ImageOps.flip($0, horizontal: true) } }
    @objc func flipV(_ sender: Any?) { rasterOp(Loc.t("垂直翻转", "Flip Vertical")) { ImageOps.flip($0, horizontal: false) } }
    @objc func grayscaleAction(_ sender: Any?) { rasterOp(Loc.t("灰度", "Grayscale")) { ImageOps.grayscale($0) } }
    @objc func sepiaAction(_ sender: Any?) { rasterOp(Loc.t("怀旧色", "Sepia")) { ImageOps.sepia($0) } }
    @objc func invertAction(_ sender: Any?) { rasterOp(Loc.t("反色", "Negative")) { ImageOps.invert($0) } }
    @objc func sketchAction(_ sender: Any?) { rasterOp(Loc.t("素描", "Sketch")) { ImageOps.sketch($0) } }
    @objc func oilPaintAction(_ sender: Any?) { rasterOp(Loc.t("油画", "Oil Painting")) { ImageOps.oilPaint($0) } }

    /// Reduce Colors submenu: the clicked item's `tag` carries the per-channel
    /// posterize level (see AppDelegate's mapping from the nominal color count).
    @objc func reduceColorsAction(_ sender: Any?) {
        let levels = (sender as? NSMenuItem)?.tag ?? 6
        rasterOp(Loc.t("减少颜色", "Reduce Colors")) { ImageOps.reduceColors($0, levels: levels) }
    }

    /// Toggle the interactive clone-stamp tool on the canvas (C).
    @objc func cloneToolAction(_ sender: Any?) {
        guard currentDocument != nil else { return }
        canvas.toggleCloneMode()
    }

    /// Shared driver for the effect dialogs (defined in EditorEffects.swift):
    /// bake the floating selection, run the panel, then refresh once it applies.
    /// The panel closure receives the `onApply` callback to invoke after it
    /// mutates the document.
    func runEffectPanel(_ present: (_ onApply: @escaping () -> Void) -> Void) {
        canvas.anchorFloating()
        present { [weak self] in
            guard let self else { return }
            self.canvas.clearSelection()
            self.canvas.refreshFromDocument()
            self.refreshTabBar()
            self.updateStatus()
        }
    }

    private func rasterOp(_ name: String, _ op: @escaping (CGImage) -> CGImage) {
        guard let doc = currentDocument else { return }
        canvas.anchorFloating()
        doc.applyRasterOp(name, op)
        canvas.clearSelection()
        canvas.refreshFromDocument()
        refreshTabBar()
        updateStatus()
    }

    @objc func blurSelection(_ sender: Any?) {
        guard let doc = currentDocument, let sel = canvas.selectionRect else {
            OutputRouter.notifyHUD(Loc.t("先拖拽一个选区", "Drag a selection first"))
            return
        }
        canvas.anchorFloating()
        doc.applyRasterOp(Loc.t("模糊选区", "Blur Selection")) { ImageOps.blurRegion($0, rect: sel, pixelate: true, amount: 14) }
        canvas.refreshFromDocument()
    }

    @objc func spotlightSelection(_ sender: Any?) {
        guard let doc = currentDocument, let sel = canvas.selectionRect else {
            OutputRouter.notifyHUD(Loc.t("先拖拽一个选区", "Drag a selection first"))
            return
        }
        canvas.anchorFloating()
        doc.applyRasterOp(Loc.t("聚光灯", "Spotlight")) { ImageOps.spotlight($0, rect: sel) }
        canvas.clearSelection()
        canvas.refreshFromDocument()
    }

    /// FastStone Remove/Insert Strip: the selection's rows (H) or columns (V)
    /// define the band; the other axis is always full-width/height. Inserted
    /// bands are white.
    private func stripAction(horizontal: Bool, insert: Bool) {
        guard currentDocument != nil, let sel = canvas.selectionRect else {
            OutputRouter.notifyHUD(Loc.t("先拖拽一个选区来定义条带", "Drag a selection to define the strip first"))
            return
        }
        if insert {
            let pos = horizontal ? sel.minY : sel.minX
            let thickness = horizontal ? sel.height : sel.width
            rasterOp(horizontal ? Loc.t("插入水平条带", "Insert Horizontal Strip") : Loc.t("插入垂直条带", "Insert Vertical Strip")) {
                ImageOps.insertStrip($0, horizontal: horizontal, at: pos, thickness: thickness)
            }
        } else {
            let range = horizontal ? sel.minY...sel.maxY : sel.minX...sel.maxX
            rasterOp(horizontal ? Loc.t("移除水平条带", "Remove Horizontal Strip") : Loc.t("移除垂直条带", "Remove Vertical Strip")) {
                ImageOps.removeStrip($0, horizontal: horizontal, range: range)
            }
        }
    }

    @objc func removeHStrip(_ sender: Any?) { stripAction(horizontal: true, insert: false) }
    @objc func removeVStrip(_ sender: Any?) { stripAction(horizontal: false, insert: false) }
    @objc func insertHStrip(_ sender: Any?) { stripAction(horizontal: true, insert: true) }
    @objc func insertVStrip(_ sender: Any?) { stripAction(horizontal: false, insert: true) }

    @objc func selectAllAction(_ sender: Any?) { canvas.selectAll2() }
    @objc func deselectAction(_ sender: Any?) { canvas.clearSelection() }

    @objc func undoAction(_ sender: Any?) {
        currentDocument?.undoManager.undo()
        canvas.refreshFromDocument()
        refreshTabBar()
        updateStatus()
    }

    @objc func redoAction(_ sender: Any?) {
        currentDocument?.undoManager.redo()
        canvas.refreshFromDocument()
        refreshTabBar()
        updateStatus()
    }

    @objc func closeTabAction(_ sender: Any?) {
        if currentIndex >= 0 { closeTab(currentIndex) }
    }

    @objc func nextTab(_ sender: Any?) { selectTab(min(currentIndex + 1, documents.count - 1)) }
    @objc func prevTab(_ sender: Any?) { selectTab(max(currentIndex - 1, 0)) }

    // MARK: dialogs

    @objc func resizeAction(_ sender: Any?) {
        guard let doc = currentDocument else { return }
        let alert = NSAlert()
        alert.messageText = Loc.t("调整尺寸", "Resize")
        alert.informativeText = Loc.t("当前 \(Int(doc.pixelSize.width)) × \(Int(doc.pixelSize.height)) px",
                                      "Current \(Int(doc.pixelSize.width)) × \(Int(doc.pixelSize.height)) px")
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 220, height: 28))
        let wField = NSTextField(frame: CGRect(x: 0, y: 2, width: 80, height: 24))
        wField.integerValue = Int(doc.pixelSize.width)
        let xLabel = NSTextField(labelWithString: "×")
        xLabel.frame = CGRect(x: 88, y: 5, width: 16, height: 18)
        let hField = NSTextField(frame: CGRect(x: 110, y: 2, width: 80, height: 24))
        hField.integerValue = Int(doc.pixelSize.height)
        view.addSubview(wField); view.addSubview(xLabel); view.addSubview(hField)
        alert.accessoryView = view
        alert.addButton(withTitle: Loc.t("确定", "OK"))
        alert.addButton(withTitle: Loc.t("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let size = CGSize(width: max(1, wField.integerValue), height: max(1, hField.integerValue))
        rasterOp(Loc.t("调整尺寸", "Resize")) { ImageOps.resize($0, to: size) }
    }

    @objc func adjustColors(_ sender: Any?) {
        guard let doc = currentDocument else { return }
        AdjustColorsPanel.run(for: doc) { [weak self] in
            self?.canvas.refreshFromDocument()
            self?.refreshTabBar()
        }
    }

    @objc func sharpenBlur(_ sender: Any?) {
        guard currentDocument != nil else { return }
        let alert = NSAlert()
        alert.messageText = Loc.t("锐化 / 模糊", "Sharpen / Blur")
        let seg = NSSegmentedControl(labels: [Loc.t("锐化", "Sharpen"), Loc.t("模糊", "Blur")], trackingMode: .selectOne,
                                     target: nil, action: nil)
        seg.selectedSegment = 0
        seg.frame = CGRect(x: 0, y: 30, width: 160, height: 24)
        let slider = NSSlider(value: 5, minValue: 1, maxValue: 20, target: nil, action: nil)
        slider.frame = CGRect(x: 0, y: 0, width: 220, height: 24)
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 220, height: 58))
        view.addSubview(seg); view.addSubview(slider)
        alert.accessoryView = view
        alert.addButton(withTitle: Loc.t("应用", "Apply"))
        alert.addButton(withTitle: Loc.t("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let amount = slider.doubleValue
        if seg.selectedSegment == 0 {
            rasterOp(Loc.t("锐化", "Sharpen")) { ImageOps.sharpen($0, amount: amount / 10) }
        } else {
            rasterOp(Loc.t("模糊", "Blur")) { ImageOps.gaussianBlur($0, radius: amount) }
        }
    }

    // MARK: Draw mode (strict FastStone separation: D → Draw → Save/OK/Cancel)

    @objc func enterDraw(_ sender: Any?) {
        guard let doc = currentDocument, drawController == nil, let window else { return }
        canvas.anchorFloating()
        canvas.clearSelection()
        let controller = DrawModeController(document: doc) { [weak self] outcome in
            guard let self else { return }
            self.drawController = nil
            self.window?.contentView = self.editorRootView
            self.window?.makeFirstResponder(self.canvas)
            switch outcome {
            case .ok(let annotations, let stepCounter):
                doc.setAnnotations(annotations, actionName: Loc.t("标注", "Annotate"))
                doc.stepCounter = stepCounter
            case .save(let annotations, let stepCounter):
                doc.setAnnotations(annotations, actionName: Loc.t("标注", "Annotate"))
                doc.stepCounter = stepCounter
                self.saveDocument(nil)
            case .cancel:
                break
            }
            self.canvas.refreshFromDocument()
            self.refreshTabBar()
            self.updateStatus()
        }
        drawController = controller
        window.contentView = controller.rootView
        window.makeFirstResponder(controller.canvas)
    }

    // MARK: window

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { DockIcon.update(editorVisible: false) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let drawController {
            drawController.requestCancel()
            return false
        }
        while let doc = documents.first {
            let count = documents.count
            closeTab(0)
            if documents.count == count { return false }  // user cancelled
            _ = doc
        }
        return true
    }
}

// MARK: - File / Selection precision ops (FastStone editor extras)

@MainActor
extension EditorWindowController {

    /// Save ONLY the current selection region to a file (Save Selection, ⇧S).
    @objc func saveSelectionAction(_ sender: Any?) {
        guard currentDocument != nil else { return }
        guard canvas.selectionRect != nil, let img = canvas.selectionExportImage() else {
            OutputRouter.notifyHUD(Loc.t("先选择一个区域", "Select a region first"))
            return
        }
        let panel = NSSavePanel()
        let format = Settings.shared.imageFormat
        panel.allowedContentTypes = [format == .png ? UTType.png : UTType.jpeg, .png, .jpeg]
        panel.nameFieldStringValue = FilenameTemplate.expand(Settings.shared.filenameTemplate)
            + Loc.t("-选区.", "-selection.") + format.fileExtension
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let chosen: ImageFormat = url.pathExtension.lowercased().hasPrefix("j") ? .jpeg : .png
            guard let data = OutputRouter.encode(img, format: chosen) else {
                OutputRouter.notifyHUD(Loc.t("编码失败", "Encoding failed"))
                return
            }
            do {
                try data.write(to: url)
                let name = url.lastPathComponent
                OutputRouter.notifyHUD(Loc.t("已保存选区 \(name)", "Saved selection \(name)"))
            } catch {
                OutputRouter.notifyHUD(Loc.t("保存失败：\(error.localizedDescription)", "Save failed: \(error.localizedDescription)"))
            }
        }
    }

    /// Save every open tab (Save All, ⌘⇧S). Tabs with a fileURL are overwritten
    /// in place; untitled tabs are written into the auto-save folder using the
    /// filename template.
    @objc func saveAllAction(_ sender: Any?) {
        guard !documents.isEmpty else { return }
        canvas.anchorFloating()
        let folder = Settings.shared.autoSaveFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var saved = 0
        for doc in documents {
            if let url = doc.fileURL {
                do {
                    try write(doc, to: url)
                    doc.isDirty = false
                    saved += 1
                } catch {
                    let name = url.lastPathComponent
                    OutputRouter.notifyHUD(Loc.t("保存 \(name) 失败", "Failed to save \(name)"))
                }
            } else {
                let format = Settings.shared.imageFormat
                let base = FilenameTemplate.expand(Settings.shared.filenameTemplate)
                let url = FilenameTemplate.uniqueURL(in: folder, baseName: base, ext: format.fileExtension)
                if let data = OutputRouter.encode(doc.composited, format: format),
                   (try? data.write(to: url)) != nil {
                    doc.fileURL = url
                    doc.isDirty = false
                    saved += 1
                }
            }
        }
        refreshTabBar()
        updateStatus()
        OutputRouter.notifyHUD(Loc.t("已保存 \(saved) 个标签", "Saved \(saved) tabs"))
    }

    /// Set an EXACT canvas width × height with a 9-grid anchor (Canvas Size, ⌘K).
    @objc func canvasSizeAction(_ sender: Any?) {
        guard let doc = currentDocument else { return }
        canvas.anchorFloating()
        guard let result = CanvasSizePanel.run(current: doc.pixelSize) else { return }
        let cur = doc.pixelSize
        let extraW = result.size.width - cur.width
        let extraH = result.size.height - cur.height
        let col = result.anchor.rawValue % 3, row = result.anchor.rawValue / 3
        // Where the existing image sits → how the delta splits across edges.
        let left = col == 0 ? 0 : (col == 1 ? (extraW / 2).rounded() : extraW)
        let right = extraW - left
        let top = row == 0 ? 0 : (row == 1 ? (extraH / 2).rounded() : extraH)
        let bottom = extraH - top
        rasterOp(Loc.t("画布大小", "Canvas Size")) {
            ImageOps.resizeCanvas($0, left: left, top: top, right: right, bottom: bottom)
        }
    }

    /// Grow the canvas by N px on each side, white fill (Expand Canvas, ⌥E).
    @objc func expandCanvasAction(_ sender: Any?) {
        guard currentDocument != nil else { return }
        canvas.anchorFloating()
        guard let e = ExpandCanvasPanel.run() else { return }
        guard e.left + e.top + e.right + e.bottom >= 1 else { return }
        rasterOp(Loc.t("扩展画布", "Expand Canvas")) {
            ImageOps.resizeCanvas($0, left: e.left, top: e.top, right: e.right, bottom: e.bottom)
        }
    }

    /// Set the current rectangular selection's exact px size (Set Selection Size, ⌘J).
    @objc func setSelectionSizeAction(_ sender: Any?) {
        guard currentDocument != nil else { return }
        guard let sel = canvas.selectionRect else {
            OutputRouter.notifyHUD(Loc.t("先创建一个矩形选区", "Create a rectangular selection first"))
            return
        }
        guard let size = SelectionSizePanel.run(current: sel.size) else { return }
        canvas.setSelectionSize(size)
        updateStatus()
    }

    /// Invert the current selection within the image bounds (Invert Selection, ⌘⇧I).
    @objc func invertSelectionAction(_ sender: Any?) {
        guard currentDocument != nil else { return }
        canvas.invertSelection()
        updateStatus()
    }
}
