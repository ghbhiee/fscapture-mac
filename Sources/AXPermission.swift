import AppKit
import ApplicationServices

/// Accessibility (TCC) onboarding — required to post synthetic scroll events
/// for auto-scrolling capture.
@MainActor
enum AXPermission {
    private static var window: NSWindow?

    static var trusted: Bool { AXIsProcessTrusted() }

    /// Returns true when auto-scroll may proceed; otherwise triggers the
    /// system prompt + our guide and returns false.
    @discardableResult
    static func ensure() -> Bool {
        if trusted { return true }
        // Ask macOS to surface the standard "open Accessibility settings" prompt.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
        showGuide()
        return false
    }

    static func showGuide() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let win = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 470, height: 240),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = Loc.t("滚动截图需要辅助功能权限", "Scrolling Capture Needs Accessibility Access")
        win.center()
        win.isReleasedWhenClosed = false

        let title = NSTextField(labelWithString: Loc.t("自动滚动截图需要「辅助功能」权限",
                                                        "Auto-scrolling capture requires Accessibility permission"))
        title.font = .boldSystemFont(ofSize: 16)
        let body = NSTextField(wrappingLabelWithString: Loc.t("""
        FSCapture 需要模拟滚动来自动截取长页面，macOS 要求授予「辅助功能」权限：

        1. 点「打开系统设置」
        2. 在 隐私与安全性 › 辅助功能 中打开 FSCapture 的开关
        3. 回到这里点「重新检测」（若已在列表中但仍不生效，授权后点「重启 App」）
        """, """
        FSCapture simulates scrolling to capture long pages automatically, which macOS requires Accessibility permission for:

        1. Click "Open System Settings"
        2. Enable FSCapture under Privacy & Security › Accessibility
        3. Come back and click "Re-check" (if it's listed but still not working, click "Relaunch App" after granting)
        """))
        body.font = .systemFont(ofSize: 13)

        let openBtn = NSButton(title: Loc.t("打开系统设置", "Open System Settings"), target: AXActions.shared,
                               action: #selector(AXActions.openSettings))
        openBtn.keyEquivalent = "\r"
        let checkBtn = NSButton(title: Loc.t("重新检测", "Re-check"), target: AXActions.shared,
                                action: #selector(AXActions.recheck))
        let relaunchBtn = NSButton(title: Loc.t("重启 App", "Relaunch App"), target: AXActions.shared,
                                   action: #selector(AXActions.relaunch))
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
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    static func close() { window?.orderOut(nil) }
}

final class AXActions: NSObject {
    @MainActor static let shared = AXActions()

    @MainActor @objc func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @MainActor @objc func recheck() {
        if AXPermission.trusted {
            AXPermission.close()
            OutputRouter.notifyHUD(Loc.t("辅助功能权限已就绪 ✓ 现在可以用滚动截图了",
                                         "Accessibility access ready ✓ Scrolling capture is now available"))
        } else {
            OutputRouter.notifyHUD(Loc.t("还没检测到权限，请在系统设置中打开 FSCapture 开关",
                                         "Permission not detected yet — enable FSCapture in System Settings"))
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
