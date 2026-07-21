import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panelController: CapturePanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()

        let panel = CapturePanelController()
        panelController = panel
        CaptureController.shared.panelToHide = panel.panel
        panel.show()

        HotkeyManager.shared.onAction = { action in
            CaptureController.shared.perform(action)
        }
        HotkeyManager.shared.reloadFromSettings()

        // Refresh panel tooltips whenever hotkeys change.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelController?.refreshTooltips() }
        }

        if !PermissionGuide.hasPermission {
            PermissionGuide.show()
        }

        Updater.checkOnLaunch()   // quiet auto-update check
    }

    @objc private func checkForUpdates(_ sender: Any?) { Updater.checkManually() }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { EditorWindowController.open(url: url) }
    }

    /// Dock icon clicked: bring the editor back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if EditorWindowController.shared.hasContent {
            EditorWindowController.shared.present()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false  // stay resident in the menu bar, like the original's tray mode
    }

    // MARK: status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIcon.make()
        let menu = NSMenu()

        let toggle = NSMenuItem(title: Loc.t("显示/隐藏捕获面板", "Show / Hide Capture Panel"), action: #selector(togglePanel(_:)), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        // Show Editor sits right below the panel toggle (user request).
        let editorTop = NSMenuItem(title: Loc.t("显示编辑器", "Show Editor"), action: #selector(showEditor(_:)), keyEquivalent: "")
        editorTop.target = self
        menu.addItem(editorTop)
        menu.addItem(.separator())

        // Explicit status-menu order: rectangleClipboard sits right after rectangle.
        let statusActions: [CaptureAction] = [
            .activeWindow, .windowObject, .rectangle, .rectangleClipboard,
            .freehand, .fullScreen, .scrolling, .fixedSize,
            .captureText, .pinToScreen, .intervalCapture,
        ]
        for action in statusActions {
            // Global hotkeys don't render as menu key equivalents, so show the
            // combo inline in the title as a hint.
            var title = action.label
            if let combo = Settings.shared.hotkey(for: action) {
                title = "\(action.label)   \(combo.displayString)"
            }
            let item = NSMenuItem(title: title, action: #selector(captureFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(action.rawValue)
            item.image = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: nil)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        for tool in ScreenTool.allCases {
            let item = NSMenuItem(title: tool.label, action: #selector(toolFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tool.rawValue
            item.image = NSImage(systemSymbolName: tool.symbolName, accessibilityDescription: nil)
            menu.addItem(item)
        }

        if NSScreen.screens.count > 1 {
            menu.addItem(.separator())
            for (i, screen) in NSScreen.screens.enumerated() {
                let item = NSMenuItem(title: Loc.t("捕获显示器 \(i + 1) (\(Int(screen.frame.width))×\(Int(screen.frame.height)))",
                                                   "Capture Display \(i + 1) (\(Int(screen.frame.width))×\(Int(screen.frame.height)))"),
                                      action: #selector(captureDisplay(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        // Import from Clipboard — show its ⌥V shortcut hint (it's an app-local
        // menu key equivalent, not a global hotkey, so we render the hint here).
        let importItem = NSMenuItem(title: Loc.t("从剪贴板导入   ⌥V", "Import from Clipboard   ⌥V"),
                                    action: #selector(importClipboard(_:)), keyEquivalent: "")
        importItem.target = self
        menu.addItem(importItem)
        let settings = NSMenuItem(title: Loc.t("设置…", "Settings…"), action: #selector(openSettings(_:)), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: Loc.t("退出 FSCapture", "Quit FSCapture"), action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    @objc private func togglePanel(_ sender: Any?) { panelController?.toggle() }

    @objc private func captureFromMenu(_ sender: NSMenuItem) {
        guard let action = CaptureAction(rawValue: UInt32(sender.tag)) else { return }
        // Small delay so the status menu is closed before the capture starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            CaptureController.shared.perform(action)
        }
    }

    @objc private func toolFromMenu(_ sender: NSMenuItem) {
        guard let tool = ScreenTool(rawValue: sender.tag) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            CaptureController.shared.runTool(tool)
        }
    }

    @objc private func captureDisplay(_ sender: NSMenuItem) {
        let screens = NSScreen.screens
        guard sender.tag < screens.count else { return }
        let screen = screens[sender.tag]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            CaptureController.shared.captureDisplay(screen)
        }
    }

    @objc private func importClipboard(_ sender: Any?) {
        EditorWindowController.openFromClipboard()
    }

    @objc private func showEditor(_ sender: Any?) { EditorWindowController.shared.present() }
    @objc private func openSettings(_ sender: Any?) { SettingsWindowController.show() }
    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }

    // MARK: main menu (needed so ⌘C/⌘V/⌘S/⌘W key equivalents work in windows)

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: Loc.t("关于 FSCapture", "About FSCapture"), action: nil, keyEquivalent: "")
        let checkUpdate = NSMenuItem(title: Loc.t("检查更新…", "Check for Updates…"),
                                     action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        checkUpdate.target = self
        appMenu.addItem(checkUpdate)
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: Loc.t("设置…", "Settings…"), action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: Loc.t("退出 FSCapture", "Quit FSCapture"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: Loc.t("文件", "File"))
        fileMenu.addItem(withTitle: Loc.t("新建标签页", "New Tab"),
                         action: #selector(EditorWindowController.newBlankTab(_:)), keyEquivalent: "t")
        fileMenu.addItem(withTitle: Loc.t("打开…", "Open…"),
                         action: #selector(EditorWindowController.openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: Loc.t("保存", "Save"),
                         action: #selector(EditorWindowController.saveDocument(_:)), keyEquivalent: "s")
        let saveAs = NSMenuItem(title: Loc.t("另存为…", "Save As…"),
                                action: #selector(EditorWindowController.saveDocumentAs(_:)), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .option]
        fileMenu.addItem(saveAs)
        let saveSel = NSMenuItem(title: Loc.t("保存选区…", "Save Selection…"),
                                 action: #selector(EditorWindowController.saveSelectionAction(_:)), keyEquivalent: "s")
        saveSel.keyEquivalentModifierMask = [.shift]
        fileMenu.addItem(saveSel)
        let saveAll = NSMenuItem(title: Loc.t("全部保存", "Save All"),
                                 action: #selector(EditorWindowController.saveAllAction(_:)), keyEquivalent: "s")
        saveAll.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(saveAll)
        fileMenu.addItem(withTitle: Loc.t("关闭标签页", "Close Tab"),
                         action: #selector(EditorWindowController.closeTabAction(_:)), keyEquivalent: "w")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: Loc.t("打印…", "Print…"),
                         action: #selector(EditorWindowController.printImageAction(_:)), keyEquivalent: "p")
        fileMenu.addItem(withTitle: Loc.t("共享…", "Share…"),
                         action: #selector(EditorWindowController.shareImageAction(_:)), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: Loc.t("合并图片为单个 PDF", "Convert Images into a Single PDF"),
                         action: #selector(EditorWindowController.combineIntoPDF(_:)), keyEquivalent: "g")
        fileMenu.addItem(withTitle: Loc.t("合并图片为单张图片", "Combine Images into a Single Image"),
                         action: #selector(EditorWindowController.combineIntoImage(_:)), keyEquivalent: "h")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: Loc.t("编辑", "Edit"))
        editMenu.addItem(withTitle: Loc.t("撤销", "Undo"),
                         action: #selector(EditorWindowController.undoAction(_:)), keyEquivalent: "z")
        let redo = NSMenuItem(title: Loc.t("重做", "Redo"),
                              action: #selector(EditorWindowController.redoAction(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: Loc.t("剪切", "Cut"),
                         action: #selector(EditorWindowController.cutAction(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: Loc.t("复制", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: Loc.t("粘贴", "Paste"),
                         action: #selector(EditorWindowController.pasteAction(_:)), keyEquivalent: "v")
        // ⌥V import-from-clipboard is APP-LOCAL (only when FSCapture is focused),
        // so it's a menu key equivalent rather than a global hotkey.
        let importItem = NSMenuItem(title: Loc.t("从剪贴板导入 → 新标签页", "Import from Clipboard → New Tab"),
                                    action: #selector(importClipboard(_:)), keyEquivalent: "v")
        importItem.keyEquivalentModifierMask = [.option]
        importItem.target = self
        editMenu.addItem(importItem)
        editMenu.addItem(withTitle: Loc.t("删除", "Delete"),
                         action: #selector(EditorWindowController.deleteAction(_:)), keyEquivalent: "")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: Loc.t("全选", "Select All"),
                         action: #selector(EditorWindowController.selectAllAction(_:)), keyEquivalent: "a")
        editMenu.addItem(withTitle: Loc.t("取消选择", "Deselect"),
                         action: #selector(EditorWindowController.deselectAction(_:)), keyEquivalent: "d")
        editMenu.addItem(withTitle: Loc.t("设置选区尺寸…", "Set Selection Size…"),
                         action: #selector(EditorWindowController.setSelectionSizeAction(_:)), keyEquivalent: "j")
        let invertSel = NSMenuItem(title: Loc.t("反转选区", "Invert Selection"),
                                   action: #selector(EditorWindowController.invertSelectionAction(_:)), keyEquivalent: "i")
        invertSel.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(invertSel)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: Loc.t("删除水平条带 (⇧H)", "Remove Horizontal Strip (⇧H)"),
                         action: #selector(EditorWindowController.removeHStrip(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: Loc.t("删除垂直条带 (⇧V)", "Remove Vertical Strip (⇧V)"),
                         action: #selector(EditorWindowController.removeVStrip(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: Loc.t("插入水平条带 (⌥⇧H)", "Insert Horizontal Strip (⌥⇧H)"),
                         action: #selector(EditorWindowController.insertHStrip(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: Loc.t("插入垂直条带 (⌥⇧V)", "Insert Vertical Strip (⌥⇧V)"),
                         action: #selector(EditorWindowController.insertVStrip(_:)), keyEquivalent: "")
        editMenu.addItem(.separator())
        let resize = NSMenuItem(title: Loc.t("调整尺寸…", "Resize…"),
                                action: #selector(EditorWindowController.resizeAction(_:)), keyEquivalent: "r")
        editMenu.addItem(resize)
        editMenu.addItem(withTitle: Loc.t("画布尺寸…", "Canvas Size…"),
                         action: #selector(EditorWindowController.canvasSizeAction(_:)), keyEquivalent: "k")
        let expandCanvas = NSMenuItem(title: Loc.t("扩展画布…", "Expand Canvas…"),
                                      action: #selector(EditorWindowController.expandCanvasAction(_:)), keyEquivalent: "e")
        expandCanvas.keyEquivalentModifierMask = [.option]
        editMenu.addItem(expandCanvas)
        editMenu.addItem(withTitle: Loc.t("调整颜色…", "Adjust Colors…"),
                         action: #selector(EditorWindowController.adjustColors(_:)), keyEquivalent: "e")
        editMenu.addItem(withTitle: Loc.t("反色", "Negative"),
                         action: #selector(EditorWindowController.invertAction(_:)), keyEquivalent: "i")
        editMenu.addItem(withTitle: Loc.t("锐化 / 模糊…", "Sharpen / Blur…"),
                         action: #selector(EditorWindowController.sharpenBlur(_:)), keyEquivalent: "u")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Effects menu — FastStone image-level effects. The originals use bare
        // letters G/T/J/F while the canvas is key (handled via canvasKeyCommand,
        // like D/X); the menu shows the letter as a hint. ⌘G/⌘H are already the
        // File-menu combine actions, so we don't set conflicting equivalents.
        let effectsMenuItem = NSMenuItem()
        let effectsMenu = NSMenu(title: Loc.t("效果", "Effects"))
        effectsMenu.addItem(withTitle: Loc.t("边框 / 水印… (G)", "Edge / Watermark… (G)"),
                            action: #selector(EditorWindowController.edgeWatermarkEffect(_:)), keyEquivalent: "")
        effectsMenu.addItem(withTitle: Loc.t("标题文字… (T)", "Caption… (T)"),
                            action: #selector(EditorWindowController.captionEffect(_:)), keyEquivalent: "")
        effectsMenu.addItem(withTitle: Loc.t("日期时间戳… (J)", "Date Time Stamp… (J)"),
                            action: #selector(EditorWindowController.stampEffect(_:)), keyEquivalent: "")
        effectsMenu.addItem(withTitle: Loc.t("倒影… (F)", "Reflection… (F)"),
                            action: #selector(EditorWindowController.reflectionEffect(_:)), keyEquivalent: "")
        effectsMenu.addItem(.separator())

        // One-shot color/artistic filters (Grayscale + Negative already live in
        // the Edit menu / tool strip; Sepia only had an orphaned action).
        effectsMenu.addItem(withTitle: Loc.t("灰度", "Grayscale"),
                            action: #selector(EditorWindowController.grayscaleAction(_:)), keyEquivalent: "")
        effectsMenu.addItem(withTitle: Loc.t("棕褐色", "Sepia"),
                            action: #selector(EditorWindowController.sepiaAction(_:)), keyEquivalent: "")
        effectsMenu.addItem(withTitle: Loc.t("素描", "Sketch"),
                            action: #selector(EditorWindowController.sketchAction(_:)), keyEquivalent: "")
        effectsMenu.addItem(withTitle: Loc.t("油画", "Oil Painting"),
                            action: #selector(EditorWindowController.oilPaintAction(_:)), keyEquivalent: "")

        // Reduce Colors → nominal total-color choices, each mapped to a
        // per-channel posterize level (stored in the item's tag).
        let reduceItem = NSMenuItem(title: Loc.t("减少颜色", "Reduce Colors"), action: nil, keyEquivalent: "")
        let reduceMenu = NSMenu(title: Loc.t("减少颜色", "Reduce Colors"))
        let reduceChoices: [(String, Int)] = [
            (Loc.t("256 色", "256 Colors"), 16), (Loc.t("128 色", "128 Colors"), 12),
            (Loc.t("64 色", "64 Colors"), 8), (Loc.t("32 色", "32 Colors"), 6),
            (Loc.t("16 色", "16 Colors"), 5), (Loc.t("8 色", "8 Colors"), 4),
            (Loc.t("4 色", "4 Colors"), 3), (Loc.t("2 色", "2 Colors"), 2),
        ]
        for (title, levels) in reduceChoices {
            let mi = NSMenuItem(title: title,
                                action: #selector(EditorWindowController.reduceColorsAction(_:)), keyEquivalent: "")
            mi.tag = levels
            reduceMenu.addItem(mi)
        }
        reduceItem.submenu = reduceMenu
        effectsMenu.addItem(reduceItem)
        effectsMenu.addItem(.separator())

        // ⌘T is now File ▸ New Tab (standard macOS), so transparent moves to ⌥⌘T.
        let transparentItem = NSMenuItem(title: Loc.t("背景透明化", "Make Background Transparent"),
                                         action: #selector(EditorWindowController.makeTransparentEffect(_:)), keyEquivalent: "t")
        transparentItem.keyEquivalentModifierMask = [.command, .option]
        effectsMenu.addItem(transparentItem)
        effectsMenu.addItem(withTitle: Loc.t("克隆工具 (C)", "Clone Tool (C)"),
                            action: #selector(EditorWindowController.cloneToolAction(_:)), keyEquivalent: "")

        effectsMenuItem.submenu = effectsMenu
        mainMenu.addItem(effectsMenuItem)

        NSApp.mainMenu = mainMenu
    }
}
