import AppKit

/// Screen-Recording (TCC) permission onboarding.
@MainActor
enum PermissionGuide {
    private static var window: NSWindow?

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Returns true when capture may proceed; otherwise shows the guide.
    @discardableResult
    static func ensureScreenRecordingPermission() -> Bool {
        if hasPermission { return true }
        show()
        return false
    }

    static func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let win = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 460, height: 250),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = Loc.t("需要屏幕录制权限", "Screen Recording Permission Needed")
        win.center()
        win.isReleasedWhenClosed = false

        let title = NSTextField(labelWithString: Loc.t("FSCapture 需要「屏幕录制」权限才能截图",
                                                        "FSCapture needs Screen Recording permission to capture"))
        title.font = .boldSystemFont(ofSize: 16)

        let body = NSTextField(wrappingLabelWithString: Loc.t("""
        macOS 要求截图/录屏类应用先获得授权：

        1. 点击下方「打开系统设置」
        2. 在 隐私与安全性 › 屏幕与系统录音 中勾选 FSCapture
        3. 授权后回到这里点「重新检测」

        注意：如果 FSCapture 已在列表中但仍不生效，请先移除再重新添加，
        或授权后点「重启 App」（macOS 的授权变更常需重启应用才生效）。
        """, """
        macOS requires screenshot / screen-recording apps to be authorized first:

        1. Click "Open System Settings" below
        2. Check FSCapture under Privacy & Security › Screen & System Audio Recording
        3. Come back and click "Re-check" after granting

        Note: if FSCapture is listed but still doesn't work, remove and re-add it,
        or click "Relaunch App" after granting (macOS often needs a restart for permission changes to take effect).
        """))
        body.font = .systemFont(ofSize: 13)

        let openBtn = NSButton(title: Loc.t("打开系统设置", "Open System Settings"), target: PermissionActions.shared,
                               action: #selector(PermissionActions.openSettings))
        openBtn.keyEquivalent = "\r"
        let checkBtn = NSButton(title: Loc.t("重新检测", "Re-check"), target: PermissionActions.shared,
                                action: #selector(PermissionActions.recheck))
        let relaunchBtn = NSButton(title: Loc.t("重启 App", "Relaunch App"), target: PermissionActions.shared,
                                   action: #selector(PermissionActions.relaunch))
        let buttons = NSStackView(views: [openBtn, checkBtn, relaunchBtn])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let stack = NSStackView(views: [title, body, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        win.contentView = content
        window = win

        // Ask macOS to register us in the Screen Recording list (shows the
        // system prompt on first run).
        CGRequestScreenCaptureAccess()

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    static func close() {
        window?.orderOut(nil)
    }
}

/// Objc target for the guide buttons (NSButton needs an NSObject target).
final class PermissionActions: NSObject {
    @MainActor static let shared = PermissionActions()

    @MainActor @objc func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    @MainActor @objc func recheck() {
        if PermissionGuide.hasPermission {
            PermissionGuide.close()
            OutputRouter.notifyHUD(Loc.t("屏幕录制权限已就绪 ✓", "Screen Recording access ready ✓"))
        } else {
            OutputRouter.notifyHUD(Loc.t("还没有检测到权限，请在系统设置中勾选后重试",
                                         "Permission not detected yet — enable it in System Settings and retry"))
        }
    }

    @MainActor @objc func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
