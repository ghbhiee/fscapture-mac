import AppKit

/// In-app feedback: a small dialog to submit a feature request or bug report,
/// POSTed as JSON to the feedback endpoint. No personal data is sent unless the
/// user types a contact; the app version + OS are attached for triage.
@MainActor
enum Feedback {
    static let endpoint = URL(string: "https://www.tokencv.com/fscapture/feedback")!

    static func present() {
        let alert = NSAlert()
        alert.messageText = Loc.t("反馈问题 / 需求", "Send Feedback")
        alert.informativeText = Loc.t("你的建议会帮助改进 FSCapture。留邮箱可选（方便回复）。",
                                      "Your input helps improve FSCapture. Email is optional (for a reply).")

        let view = NSView(frame: CGRect(x: 0, y: 0, width: 360, height: 210))

        let kind = NSSegmentedControl(labels: [Loc.t("问题", "Bug"), Loc.t("需求", "Idea")],
                                      trackingMode: .selectOne, target: nil, action: nil)
        kind.selectedSegment = 0
        kind.frame = CGRect(x: 0, y: 180, width: 200, height: 24)
        view.addSubview(kind)

        let scroll = NSScrollView(frame: CGRect(x: 0, y: 40, width: 360, height: 132))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: CGRect(origin: .zero, size: scroll.contentSize))
        text.isRichText = false
        text.font = .systemFont(ofSize: 12)
        text.textContainerInset = NSSize(width: 4, height: 4)
        scroll.documentView = text
        view.addSubview(scroll)

        let contact = NSTextField(frame: CGRect(x: 0, y: 6, width: 360, height: 24))
        contact.placeholderString = Loc.t("邮箱（可选）", "Email (optional)")
        view.addSubview(contact)

        alert.accessoryView = view
        alert.addButton(withTitle: Loc.t("发送", "Send"))
        alert.addButton(withTitle: Loc.t("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let message = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            OutputRouter.notifyHUD(Loc.t("请输入反馈内容", "Please enter your feedback"))
            return
        }
        submit(kind: kind.selectedSegment == 0 ? "bug" : "idea",
               message: String(message.prefix(4000)),
               contact: String(contact.stringValue.prefix(200)))
    }

    private static func submit(kind: String, message: String, contact: String) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let payload: [String: String] = [
            "kind": kind,
            "message": message,
            "contact": contact,
            "version": version,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 15
        OutputRouter.notifyHUD(Loc.t("正在发送…", "Sending…"))
        URLSession.shared.dataTask(with: req) { _, response, error in
            let ok = error == nil && (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } == true
            DispatchQueue.main.async {
                OutputRouter.notifyHUD(ok ? Loc.t("反馈已发送，谢谢！", "Feedback sent, thank you!")
                                          : Loc.t("发送失败，请稍后再试", "Sending failed, please try later"))
            }
        }.resume()
    }
}
