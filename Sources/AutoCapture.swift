import AppKit

/// Auto Screen Capture (定时自动截图) — FastStone's TIntervalCaptureWin.
/// Repeatedly grabs a chosen region at a fixed interval and writes every frame
/// to a folder with a sequence-numbered filename. A config dialog collects the
/// region source / interval / folder / stop conditions; a running session drives
/// a Timer and shows a small non-activating HUD with a live count and a Stop
/// button (Esc also stops). Self-contained, mirroring ScrollCapture.swift.
@MainActor
enum AutoCapture {

    static func begin() {
        guard PermissionGuide.ensureScreenRecordingPermission() else { return }
        guard SelectionOverlayController.current == nil,
              WindowPickOverlayController.current == nil,
              AutoCaptureSession.active == nil else { return }
        AutoCaptureConfigController.present()
    }
}

/// What the session captures each tick.
enum AutoRegionSource {
    case fullScreen(NSScreen)
    case rectangle(CGRect, NSScreen)   // Cocoa global coords
}

/// Everything the config dialog produces for a session.
struct AutoCaptureConfig {
    var isRectangle: Bool          // resolve the actual rect after the dialog closes
    var interval: TimeInterval     // seconds between frames
    var folder: URL                // output folder (already includes dated subfolder)
    var frameLimit: Int?           // stop after N frames
    var minutesLimit: Double?      // stop after M minutes
}

// MARK: - Config dialog

/// AppKit config window (built programmatically, like PermissionGuide). Kept
/// alive by a static reference while on screen.
@MainActor
final class AutoCaptureConfigController: NSObject {
    private static var current: AutoCaptureConfigController?

    private let window: NSWindow
    private let fullScreenRadio = NSButton(radioButtonWithTitle: Loc.t("全屏", "Full Screen"), target: nil, action: nil)
    private let rectRadio = NSButton(radioButtonWithTitle: Loc.t("矩形区域", "Rectangular Region"), target: nil, action: nil)
    private let intervalField = NSTextField(string: "10")
    private let folderLabel = NSTextField(labelWithString: "")
    private let datedSubfolderCheck = NSButton(checkboxWithTitle: Loc.t("在文件夹内按日期建子文件夹", "Create a dated subfolder inside"), target: nil, action: nil)
    private let frameLimitCheck = NSButton(checkboxWithTitle: Loc.t("截取张数后停止：", "Stop after frames:"), target: nil, action: nil)
    private let frameLimitField = NSTextField(string: "50")
    private let minutesLimitCheck = NSButton(checkboxWithTitle: Loc.t("运行分钟后停止：", "Stop after minutes:"), target: nil, action: nil)
    private let minutesLimitField = NSTextField(string: "10")
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let pointerCheck = NSButton(checkboxWithTitle: Loc.t("包含鼠标指针", "Include Mouse Pointer"), target: nil, action: nil)

    private var folder: URL = Settings.shared.autoSaveFolder

    static func present() {
        if let c = current {
            NSApp.activate(ignoringOtherApps: true)
            c.window.makeKeyAndOrderFront(nil)
            return
        }
        let c = AutoCaptureConfigController()
        current = c
        NSApp.activate(ignoringOtherApps: true)
        c.window.makeKeyAndOrderFront(nil)
    }

    override init() {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 460, height: 10),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = Loc.t("定时自动截图", "Auto Screen Capture")
        window.isReleasedWhenClosed = false
        window.delegate = self

        // Region source (radio group: shared action makes them mutually exclusive).
        fullScreenRadio.target = self; fullScreenRadio.action = #selector(pickSource(_:))
        rectRadio.target = self;       rectRadio.action = #selector(pickSource(_:))
        fullScreenRadio.state = .on
        let regionRow = labeled(Loc.t("捕获区域", "Region"), NSStackView(views: [fullScreenRadio, rectRadio]))

        // Interval seconds.
        intervalField.alignment = .right
        intervalField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let intervalRow = labeled(Loc.t("间隔（秒）", "Interval (s)"), stack([intervalField, NSTextField(labelWithString: Loc.t("秒 / 张", "s / frame"))]))

        // Output folder.
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.stringValue = folder.path
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let chooseBtn = NSButton(title: Loc.t("选择…", "Choose…"), target: self, action: #selector(chooseFolder(_:)))
        let folderRow = labeled(Loc.t("输出文件夹", "Output Folder"), stack([folderLabel, chooseBtn]))

        datedSubfolderCheck.state = .on

        // Stop conditions.
        frameLimitCheck.state = .on
        frameLimitField.alignment = .right
        frameLimitField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let frameRow = stack([frameLimitCheck, frameLimitField, NSTextField(labelWithString: Loc.t("张", "frames"))])
        minutesLimitField.alignment = .right
        minutesLimitField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let minutesRow = stack([minutesLimitCheck, minutesLimitField, NSTextField(labelWithString: Loc.t("分钟", "minutes"))])
        let stopRow = labeled(Loc.t("停止条件", "Stop When"), NSStackView(views: [frameRow, minutesRow]).vertical())

        // Format + pointer (reuse Settings).
        for f in ImageFormat.allCases { formatPopup.addItem(withTitle: f.label) }
        formatPopup.selectItem(withTitle: Settings.shared.imageFormat.label)
        pointerCheck.state = Settings.shared.includePointer ? .on : .off
        let optionsRow = labeled(Loc.t("图片格式", "Image Format"), stack([formatPopup, pointerCheck]))

        // Buttons.
        let startBtn = NSButton(title: Loc.t("开始", "Start"), target: self, action: #selector(start(_:)))
        startBtn.keyEquivalent = "\r"
        let cancelBtn = NSButton(title: Loc.t("取消", "Cancel"), target: self, action: #selector(cancel(_:)))
        let buttons = NSStackView(views: [NSView(), cancelBtn, startBtn])
        buttons.orientation = .horizontal
        buttons.distribution = .fill

        let stackView = NSStackView(views: [
            regionRow, intervalRow, folderRow, datedSubfolderCheck,
            stopRow, optionsRow, NSBox.horizontalSeparator(), buttons,
        ])
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 12
        stackView.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: content.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -48),
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.center()
    }

    // MARK: layout helpers

    /// A "Label:" + control row with a fixed-width leading label.
    private func labeled(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 80).isActive = true
        return stack([label, control])
    }

    private func stack(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 8
        s.alignment = .centerY
        return s
    }

    // MARK: actions

    @objc private func pickSource(_ sender: NSButton) {
        fullScreenRadio.state = (sender == fullScreenRadio) ? .on : .off
        rectRadio.state = (sender == rectRadio) ? .on : .off
    }

    @objc private func chooseFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = Loc.t("选择", "Choose")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.folder = url
            self.folderLabel.stringValue = url.path
        }
    }

    @objc private func cancel(_ sender: Any?) {
        window.close()
    }

    @objc private func start(_ sender: Any?) {
        // Persist the reused options.
        if let fmt = ImageFormat.allCases.first(where: { $0.label == formatPopup.titleOfSelectedItem }) {
            Settings.shared.imageFormat = fmt
        }
        Settings.shared.includePointer = (pointerCheck.state == .on)

        // Resolve the output folder (optionally a dated subfolder).
        var outFolder = folder
        if datedSubfolderCheck.state == .on {
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            outFolder = folder.appendingPathComponent(df.string(from: Date()))
        }
        Settings.shared.autoSaveFolder = folder   // remember the chosen root

        let interval = max(1, intervalField.doubleValue == 0 ? 10 : intervalField.doubleValue)
        let frameLimit = frameLimitCheck.state == .on ? max(1, frameLimitField.integerValue) : nil
        let minutesLimit = minutesLimitCheck.state == .on ? max(0.1, minutesLimitField.doubleValue) : nil

        let config = AutoCaptureConfig(isRectangle: rectRadio.state == .on,
                                       interval: interval, folder: outFolder,
                                       frameLimit: frameLimit, minutesLimit: minutesLimit)
        window.close()

        if config.isRectangle {
            // Pick the region, then start.
            _ = SelectionOverlayController(mode: .rectangle) { result in
                guard case let .rect(rect, screen)? = result,
                      rect.width >= 16, rect.height >= 16 else {
                    if case .rect? = result { OutputRouter.notifyHUD(Loc.t("区域太小（至少 16×16）", "Region too small (at least 16×16)")) }
                    return
                }
                AutoCaptureSession.start(source: .rectangle(rect, screen), config: config)
            }
        } else {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            guard let screen else { return }
            AutoCaptureSession.start(source: .fullScreen(screen), config: config)
        }
    }
}

extension AutoCaptureConfigController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        AutoCaptureConfigController.currentDidClose()
    }
    fileprivate static func currentDidClose() { current = nil }
}

// MARK: - Running session

/// Drives the repeating capture Timer, writes each frame, and enforces the stop
/// conditions. Runs on the main run loop; captures are async but a `capturing`
/// guard skips a tick if the previous grab hasn't finished (short interval).
@MainActor
final class AutoCaptureSession {
    static private(set) var active: AutoCaptureSession?

    private let source: AutoRegionSource
    private let config: AutoCaptureConfig
    private let format = Settings.shared.imageFormat
    private var timer: Timer?
    private var monitors: [Any] = []
    private var hud: AutoCaptureHUD?
    private let startDate = Date()
    private var frameCount = 0
    private var capturing = false

    private init(source: AutoRegionSource, config: AutoCaptureConfig) {
        self.source = source
        self.config = config
    }

    static func start(source: AutoRegionSource, config: AutoCaptureConfig) {
        let s = AutoCaptureSession(source: source, config: config)
        active = s
        s.run()
    }

    private func run() {
        try? FileManager.default.createDirectory(at: config.folder, withIntermediateDirectories: true)

        // Hide the capture panel so it stays out of full-screen frames.
        panelWasVisible = CaptureController.shared.panelToHide?.isVisible ?? false
        if panelWasVisible { CaptureController.shared.panelToHide?.orderOut(nil) }

        let hud = AutoCaptureHUD(source: source) { [weak self] in self?.stop(reason: Loc.t("已手动停止", "Stopped manually")) }
        self.hud = hud
        hud.show()

        // Esc stops (button is the visible fallback).
        let handler: (NSEvent) -> Void = { [weak self] e in
            if e.keyCode == 53 { self?.stop(reason: Loc.t("已停止（Esc）", "Stopped (Esc)")) }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { handler($0) }) {
            monitors.append(g)
        }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { handler($0); return $0 } as Any)

        // Fire immediately, then on the interval.
        captureFrame()
        let t = Timer.scheduledTimer(withTimeInterval: config.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = t
    }

    private var panelWasVisible = false

    private func tick() {
        if let minutes = config.minutesLimit,
           Date().timeIntervalSince(startDate) >= minutes * 60 {
            stop(reason: Loc.t("已到时间上限，共 \(frameCount) 张", "Time limit reached, \(frameCount) frames total"))
            return
        }
        captureFrame()
    }

    private func captureFrame() {
        guard !capturing else { return }   // skip if the previous grab is still running
        capturing = true
        Task { @MainActor in
            defer { self.capturing = false }
            do {
                let image: CGImage
                switch source {
                case .fullScreen(let screen):
                    image = try await ScreenshotEngine.captureDisplay(screen: screen)
                case .rectangle(let rect, let screen):
                    image = try await ScreenshotEngine.captureRect(rect, on: screen)
                }
                frameCount += 1
                write(image, index: frameCount)
                hud?.update(count: frameCount)
                if let limit = config.frameLimit, frameCount >= limit {
                    stop(reason: Loc.t("已捕获 \(frameCount) 张，完成", "Captured \(frameCount) frames, done"))
                }
            } catch {
                NSLog("FSCapture autocap: frame failed: \(error)")
            }
        }
    }

    /// `<timestamp>_<0000-index>.<ext>` via FilenameTemplate (# stripped so the
    /// shared sequence counter isn't consumed — the session owns its numbering).
    private func write(_ image: CGImage, index: Int) {
        let template = Settings.shared.filenameTemplate.replacingOccurrences(of: "#", with: "")
        let stamp = FilenameTemplate.expand(template)
        let base = "\(stamp)_\(String(format: "%04d", index))"
        let url = FilenameTemplate.uniqueURL(in: config.folder, baseName: base, ext: format.fileExtension)
        guard let data = OutputRouter.encode(image, format: format) else { return }
        try? data.write(to: url)
    }

    private func stop(reason: String) {
        guard AutoCaptureSession.active === self else { return }
        timer?.invalidate(); timer = nil
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        hud?.close(); hud = nil
        if panelWasVisible { CaptureController.shared.panelToHide?.orderFrontRegardless() }
        AutoCaptureSession.active = nil
        OutputRouter.notifyHUD(reason)
    }
}

// MARK: - HUD

/// Non-activating count HUD with a guaranteed Stop button, mirroring ScrollHUD.
/// Parked at the top-center of the source screen, out of the captured region.
@MainActor
final class AutoCaptureHUD {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")

    init(source: AutoRegionSource, onStop: @escaping () -> Void) {
        let screen: NSScreen
        switch source {
        case .fullScreen(let s): screen = s
        case .rectangle(_, let s): screen = s
        }
        let hudW: CGFloat = 340, hudH: CGFloat = 56
        let frame = NSRect(x: screen.frame.midX - hudW / 2,
                           y: screen.visibleFrame.maxY - hudH - 14,
                           width: hudW, height: hudH)

        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true

        label.frame = NSRect(x: 14, y: 8, width: hudW - 120, height: hudH - 16)
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = .white
        label.maximumNumberOfLines = 2
        label.stringValue = Loc.t("定时截图中… · Esc 停止", "Auto-capturing… · press Esc to stop")
        bg.addSubview(label)

        let holder = AutoCaptureHUDActions(onStop: onStop)
        self.actions = holder
        let stopBtn = NSButton(title: Loc.t("停止", "Stop"), target: holder, action: #selector(AutoCaptureHUDActions.stop))
        stopBtn.bezelStyle = .rounded
        stopBtn.frame = NSRect(x: hudW - 98, y: 13, width: 86, height: 30)
        bg.addSubview(stopBtn)

        panel.contentView = bg
    }

    private var actions: AutoCaptureHUDActions?

    func show() { panel.orderFrontRegardless() }
    func close() { panel.orderOut(nil) }

    func update(count: Int) {
        label.stringValue = Loc.t("已捕获 \(count) 张 · Esc 停止", "Captured \(count) frames · press Esc to stop")
    }
}

final class AutoCaptureHUDActions: NSObject {
    private let onStop: () -> Void
    init(onStop: @escaping () -> Void) { self.onStop = onStop }
    @objc func stop() { onStop() }
}

// MARK: - small AppKit helpers

private extension NSStackView {
    func vertical() -> NSStackView {
        orientation = .vertical
        alignment = .leading
        spacing = 6
        return self
    }
}

private extension NSBox {
    static func horizontalSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
