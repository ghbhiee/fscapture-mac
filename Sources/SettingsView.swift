import AppKit
import SwiftUI

/// Settings window: Capture / Files / Hotkeys tabs (SwiftUI forms).
@MainActor
final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?

    static func show() {
        if shared == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 420),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = Loc.t("FSCapture 设置", "FSCapture Settings")
            window.center()
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsRootView())
            shared = SettingsWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        shared?.window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsRootView: View {
    var body: some View {
        TabView {
            GeneralSettingsView().tabItem { Label(Loc.t("通用", "General"), systemImage: "gearshape") }
            CaptureSettingsView().tabItem { Label(Loc.t("捕获", "Capture"), systemImage: "camera.viewfinder") }
            FileSettingsView().tabItem { Label(Loc.t("文件", "Files"), systemImage: "folder") }
            HotkeySettingsView().tabItem { Label(Loc.t("热键", "Hotkeys"), systemImage: "keyboard") }
        }
        .frame(width: 520, height: 420)
        .padding(.top, 4)
    }
}

// MARK: - General tab (language)

struct GeneralSettingsView: View {
    @State private var language = Loc.language

    var body: some View {
        Form {
            Section(Loc.t("语言", "Language")) {
                Picker(Loc.t("界面语言", "Interface language"), selection: $language) {
                    ForEach(AppLanguage.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .onChange(of: language) { _, v in
                    Loc.setLanguage(v)
                    promptRestart()
                }
                Text(Loc.t("切换语言需要重启应用后生效。", "Changing the language takes effect after a restart."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(Loc.t("关于", "About")) {
                LabeledContent(Loc.t("作者", "Author"), value: "guohongbo")
                LabeledContent(Loc.t("邮箱", "Email"), value: "ghbhiee@gmail.com")
                LabeledContent("GitHub") {
                    Link("github.com/ghbhiee/fscapture-mac",
                         destination: URL(string: "https://github.com/ghbhiee/fscapture-mac")!)
                }
                Button(Loc.t("发送反馈（问题 / 需求）…", "Send Feedback (Bug / Idea)…")) {
                    Feedback.present()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func promptRestart() {
        let alert = NSAlert()
        alert.messageText = Loc.t("重启以应用语言", "Restart to apply language")
        alert.informativeText = Loc.t("现在重启 FSCapture 以切换界面语言？",
                                      "Restart FSCapture now to switch the interface language?")
        alert.addButton(withTitle: Loc.t("重启", "Restart"))
        alert.addButton(withTitle: Loc.t("稍后", "Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            let path = Bundle.main.bundlePath
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-n", path]
            try? task.run()
            NSApp.terminate(nil)
        }
    }
}

// MARK: - Capture tab

struct CaptureSettingsView: View {
    @State private var includePointer = Settings.shared.includePointer
    @State private var previewEnabled = Settings.shared.previewEnabled
    @State private var destination = Settings.shared.destination
    @State private var editorAlsoClip = Settings.shared.editorAlsoCopyToClipboard
    @State private var allDisplays = Settings.shared.fullScreenAllDisplays
    @State private var showPanelOnLaunch = Settings.shared.showPanelOnLaunch
    @State private var fixedW = Int(Settings.shared.fixedSize.width)
    @State private var fixedH = Int(Settings.shared.fixedSize.height)

    var body: some View {
        Form {
            Picker(Loc.t("默认输出目标", "Default Destination"), selection: $destination) {
                ForEach(OutputDestination.allCases, id: \.self) { Text($0.label) }
            }
            .onChange(of: destination) { _, v in Settings.shared.destination = v }

            Toggle(Loc.t("启动时显示捕获面板", "Show capture panel on launch"), isOn: $showPanelOnLaunch)
                .onChange(of: showPanelOnLaunch) { _, v in Settings.shared.showPanelOnLaunch = v }

            Toggle(Loc.t("捕获后先在预览窗中确认", "Confirm in preview window after capture"), isOn: $previewEnabled)
                .onChange(of: previewEnabled) { _, v in Settings.shared.previewEnabled = v }

            Toggle(Loc.t("送到编辑器时同时复制到剪贴板", "Copy to clipboard when sending to editor"), isOn: $editorAlsoClip)
                .onChange(of: editorAlsoClip) { _, v in Settings.shared.editorAlsoCopyToClipboard = v }

            Toggle(Loc.t("包含鼠标指针", "Include mouse pointer"), isOn: $includePointer)
                .onChange(of: includePointer) { _, v in Settings.shared.includePointer = v }

            Toggle(Loc.t("全屏截图包含所有显示器（每屏一张）", "Full-screen capture covers all displays (one per screen)"), isOn: $allDisplays)
                .onChange(of: allDisplays) { _, v in Settings.shared.fullScreenAllDisplays = v }

            HStack {
                Text(Loc.t("固定尺寸区域", "Fixed-size region"))
                TextField(Loc.t("宽", "Width"), value: $fixedW, format: .number).frame(width: 70)
                Text("×")
                TextField(Loc.t("高", "Height"), value: $fixedH, format: .number).frame(width: 70)
                Text("px")
            }
            .onChange(of: fixedW) { _, v in Settings.shared.fixedSize.width = CGFloat(max(16, v)) }
            .onChange(of: fixedH) { _, v in Settings.shared.fixedSize.height = CGFloat(max(16, v)) }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Files tab

struct FileSettingsView: View {
    @State private var folder = Settings.shared.autoSaveFolder.path
    @State private var template = Settings.shared.filenameTemplate
    @State private var copyToClipboard = Settings.shared.autoSaveCopyToClipboard
    @State private var format = Settings.shared.imageFormat
    @State private var jpegQuality = Settings.shared.jpegQuality

    var body: some View {
        Form {
            Section(Loc.t("自动保存", "Auto Save")) {
                HStack {
                    Text(folder).truncationMode(.middle).lineLimit(1)
                    Spacer()
                    Button(Loc.t("选择…", "Choose…")) { pickFolder() }
                }
                Toggle(Loc.t("自动保存时同时复制到剪贴板", "Copy to clipboard on auto save"), isOn: $copyToClipboard)
                    .onChange(of: copyToClipboard) { _, v in Settings.shared.autoSaveCopyToClipboard = v }
            }
            Section(Loc.t("文件名模板", "Filename Template")) {
                TextField(Loc.t("模板", "Template"), text: $template)
                    .onChange(of: template) { _, v in Settings.shared.filenameTemplate = v }
                Text(Loc.t("$Y 年 · $M 月 · $D 日 · $H 时 · $N 分 · $S 秒 · # 自增序号（多个#补零）\n示例：\(FilenameTemplate.expand(template))",
                           "$Y year · $M month · $D day · $H hour · $N min · $S sec · # counter (repeat # to zero-pad)\nExample: \(FilenameTemplate.expand(template))"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(Loc.t("格式", "Format")) {
                Picker(Loc.t("图像格式", "Image format"), selection: $format) {
                    ForEach(ImageFormat.allCases, id: \.self) { Text($0.label) }
                }
                .onChange(of: format) { _, v in Settings.shared.imageFormat = v }
                if format == .jpeg {
                    HStack {
                        Text(Loc.t("JPEG 质量", "JPEG quality"))
                        Slider(value: $jpegQuality, in: 0.3...1.0)
                            .onChange(of: jpegQuality) { _, v in Settings.shared.jpegQuality = v }
                        Text(String(format: "%.0f%%", jpegQuality * 100)).monospacedDigit()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Settings.shared.autoSaveFolder
        if panel.runModal() == .OK, let url = panel.url {
            Settings.shared.autoSaveFolder = url
            folder = url.path
        }
    }
}

// MARK: - Hotkeys tab

struct HotkeySettingsView: View {
    @State private var recordingAction: CaptureAction?
    @State private var combos: [CaptureAction: KeyCombo] = Self.load()
    @State private var monitor: Any?

    static func load() -> [CaptureAction: KeyCombo] {
        var d: [CaptureAction: KeyCombo] = [:]
        for a in CaptureAction.allCases {
            if let c = Settings.shared.hotkey(for: a) { d[a] = c }
        }
        return d
    }

    var body: some View {
        Form {
            Text(Loc.t("点击右侧按钮后按下新组合键（需至少一个修饰键）；⌫ 清除，⎋ 取消。\n注意避开系统截图键 ⌘⇧3/4/5。",
                       "Click a button, then press the new combo (needs at least one modifier); ⌫ clears, ⎋ cancels.\nAvoid the system shortcuts ⌘⇧3/4/5."))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(CaptureAction.allCases, id: \.rawValue) { action in
                HStack {
                    Text(action.label)
                    Spacer()
                    Button(buttonTitle(for: action)) { toggleRecording(action) }
                        .frame(minWidth: 110)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onDisappear { stopRecording() }
    }

    private func buttonTitle(for action: CaptureAction) -> String {
        if recordingAction == action { return Loc.t("按下组合键…", "Press combo…") }
        return combos[action]?.displayString ?? Loc.t("未设置", "Not set")
    }

    private func toggleRecording(_ action: CaptureAction) {
        if recordingAction == action {
            stopRecording()
            return
        }
        stopRecording()
        recordingAction = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            defer { stopRecording() }
            if event.keyCode == 53 { return nil }             // Esc: cancel
            if event.keyCode == 51 {                          // Delete: clear
                Settings.shared.setHotkey(nil, for: action)
                combos[action] = nil
                HotkeyManager.shared.reloadFromSettings()
                return nil
            }
            if let combo = KeyCombo(event: event) {
                Settings.shared.setHotkey(combo, for: action)
                combos[action] = combo
                HotkeyManager.shared.reloadFromSettings()
                return nil
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingAction = nil
    }
}
