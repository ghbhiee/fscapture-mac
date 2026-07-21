import AppKit

/// The floating capture toolbar — FSCapture's TMainPanel equivalent.
/// Non-activating so clicking it doesn't steal focus from the app you want
/// to capture. Draggable by its background.
@MainActor
final class CapturePanelController {
    let panel: NSPanel

    private let captureButtons: [CaptureAction] = [
        .activeWindow, .windowObject, .rectangle, .freehand,
        .fullScreen, .scrolling, .fixedSize, .captureText, .pinToScreen,
        .intervalCapture,
    ]

    init() {
        panel = NSPanel(contentRect: .zero,
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.title = "FSCapture"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true

        var views: [NSView] = []
        for action in captureButtons {
            let btn = makeButton(symbol: action.symbolName, tooltip: hotkeyTooltip(for: action),
                                 tag: Int(action.rawValue), action: #selector(PanelActions.capture(_:)))
            views.append(btn)
        }
        views.append(separator())
        for tool in ScreenTool.allCases {
            let btn = makeButton(symbol: tool.symbolName, tooltip: tool.label,
                                 tag: tool.rawValue, action: #selector(PanelActions.tool(_:)))
            views.append(btn)
        }
        views.append(separator())
        views.append(makeButton(symbol: "square.and.arrow.up", tooltip: Loc.t("输出目标", "Output"),
                                tag: 0, action: #selector(PanelActions.outputMenu(_:))))
        views.append(makeButton(symbol: "gearshape", tooltip: Loc.t("设置", "Settings"),
                                tag: 0, action: #selector(PanelActions.settingsMenu(_:))))

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)

        // Restore last position or default to top-right.
        if let saved = UserDefaults.standard.string(forKey: "panelOrigin") {
            panel.setFrameOrigin(NSPointFromString(saved))
        } else if let screen = NSScreen.main {
            panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.maxX - stack.fittingSize.width - 40,
                                         y: screen.visibleFrame.maxY - 80))
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                UserDefaults.standard.set(NSStringFromPoint(self.panel.frame.origin), forKey: "panelOrigin")
            }
        }
    }

    func refreshTooltips() {
        guard let stack = panel.contentView as? NSStackView else { return }
        for view in stack.arrangedSubviews {
            guard let btn = view as? NSButton, btn.tag != 0,
                  let action = CaptureAction(rawValue: UInt32(btn.tag)) else { continue }
            btn.toolTip = hotkeyTooltip(for: action)
        }
    }

    private func hotkeyTooltip(for action: CaptureAction) -> String {
        if let combo = Settings.shared.hotkey(for: action) {
            return "\(action.label)  (\(combo.displayString))"
        }
        return action.label
    }

    private func makeButton(symbol: String, tooltip: String, tag: Int, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        let btn = NSButton(image: image ?? NSImage(), target: PanelActions.shared, action: action)
        btn.bezelStyle = .texturedRounded
        btn.isBordered = false
        btn.toolTip = tooltip
        btn.tag = tag
        btn.setFrameSize(CGSize(width: 30, height: 26))
        btn.widthAnchor.constraint(equalToConstant: 30).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return btn
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 8).isActive = true
        return box
    }

    func show() { panel.orderFrontRegardless() }
    func toggle() {
        if panel.isVisible { panel.orderOut(nil) } else { show() }
    }
}

/// Shared objc target for panel buttons and menus.
final class PanelActions: NSObject {
    @MainActor static let shared = PanelActions()

    @MainActor @objc func capture(_ sender: NSButton) {
        guard let action = CaptureAction(rawValue: UInt32(sender.tag)) else { return }
        CaptureController.shared.perform(action)
    }

    @MainActor @objc func tool(_ sender: NSButton) {
        guard let tool = ScreenTool(rawValue: sender.tag) else { return }
        CaptureController.shared.runTool(tool)
    }

    @MainActor @objc func outputMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: Loc.t("输出目标：", "Destination:"), action: nil, keyEquivalent: "")
        for dest in OutputDestination.allCases {
            let item = NSMenuItem(title: dest.label, action: #selector(setDestination(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = dest.rawValue
            item.state = Settings.shared.destination == dest ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let preview = NSMenuItem(title: Loc.t("先预览再送出", "Preview in Editor"),
                                 action: #selector(togglePreview(_:)), keyEquivalent: "")
        preview.target = self
        preview.state = Settings.shared.previewEnabled ? .on : .off
        menu.addItem(preview)
        let pointer = NSMenuItem(title: Loc.t("包含鼠标指针", "Include Mouse Pointer"),
                                 action: #selector(togglePointer(_:)), keyEquivalent: "")
        pointer.target = self
        pointer.state = Settings.shared.includePointer ? .on : .off
        menu.addItem(pointer)
        let editorClip = NSMenuItem(title: Loc.t("送到编辑器时同时复制到剪贴板", "Copy to Clipboard When Sending to Editor"),
                                    action: #selector(toggleEditorClip(_:)), keyEquivalent: "")
        editorClip.target = self
        editorClip.state = Settings.shared.editorAlsoCopyToClipboard ? .on : .off
        menu.addItem(editorClip)
        popup(menu, from: sender)
    }

    @MainActor @objc func toggleEditorClip(_ sender: NSMenuItem) {
        Settings.shared.editorAlsoCopyToClipboard.toggle()
    }

    @MainActor @objc func settingsMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let settings = NSMenuItem(title: Loc.t("设置…", "Settings…"), action: #selector(openSettings(_:)), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        let editorItem = NSMenuItem(title: Loc.t("显示编辑器", "Show Editor"),
                                    action: #selector(showEditor(_:)), keyEquivalent: "")
        editorItem.target = self
        menu.addItem(editorItem)
        let importItem = NSMenuItem(title: Loc.t("从剪贴板导入", "Import from Clipboard"),
                                    action: #selector(importClipboard(_:)), keyEquivalent: "")
        importItem.target = self
        menu.addItem(importItem)
        menu.addItem(.separator())
        let about = NSMenuItem(title: Loc.t("关于 FSCapture", "About FSCapture"), action: #selector(about(_:)), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: Loc.t("退出 FSCapture", "Quit FSCapture"), action: #selector(quit(_:)), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        popup(menu, from: sender)
    }

    @MainActor private func popup(_ menu: NSMenu, from view: NSView) {
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: view.bounds.minY - 4), in: view)
    }

    @MainActor @objc func setDestination(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String,
           let dest = OutputDestination(rawValue: raw) {
            Settings.shared.destination = dest
        }
    }

    @MainActor @objc func togglePreview(_ sender: NSMenuItem) {
        Settings.shared.previewEnabled.toggle()
    }

    @MainActor @objc func togglePointer(_ sender: NSMenuItem) {
        Settings.shared.includePointer.toggle()
    }

    @MainActor @objc func openSettings(_ sender: Any?) {
        SettingsWindowController.show()
    }

    @MainActor @objc func importClipboard(_ sender: Any?) {
        let pb = NSPasteboard.general
        guard let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: data), let cg = rep.cgImage else {
            OutputRouter.notifyHUD(Loc.t("剪贴板里没有图像", "No image on the clipboard"))
            return
        }
        EditorWindowController.open(image: cg)
    }

    @MainActor @objc func showEditor(_ sender: Any?) {
        EditorWindowController.shared.present()
    }

    @MainActor @objc func about(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "FSCapture 0.1.0 (Phase 1)"
        alert.informativeText = Loc.t("FastStone Capture 的 macOS clean-room 克隆\n个人学习用途",
                                      "A clean-room macOS clone of FastStone Capture\nFor personal study use")
        alert.runModal()
    }

    @MainActor @objc func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}
