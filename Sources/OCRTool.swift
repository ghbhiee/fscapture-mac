import AppKit
import Vision

/// "Capture Text": OCR a captured region via Vision (Chinese + English) and
/// show the result in an editable window; text is also copied to clipboard.
@MainActor
enum OCRTool {
    private static var windows: [NSWindow] = []

    static func recognize(_ image: CGImage) {
        let request = VNRecognizeTextRequest { request, error in
            let lines: [String] = (request.results as? [VNRecognizedTextObservation])?
                .compactMap { $0.topCandidates(1).first?.string } ?? []
            DispatchQueue.main.async {
                if let error {
                    OutputRouter.notifyHUD(Loc.t("OCR 失败：\(error.localizedDescription)", "OCR failed: \(error.localizedDescription)"))
                    return
                }
                showResult(lines.joined(separator: "\n"))
            }
        }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = true

        DispatchQueue.global(qos: .userInitiated).async {
            let handler = VNImageRequestHandler(cgImage: image)
            do {
                try handler.perform([request])
            } catch {
                DispatchQueue.main.async {
                    OutputRouter.notifyHUD(Loc.t("OCR 失败：\(error.localizedDescription)", "OCR failed: \(error.localizedDescription)"))
                }
            }
        }
    }

    private static func showResult(_ text: String) {
        if text.isEmpty {
            OutputRouter.notifyHUD(Loc.t("未识别到文字", "No text recognized"))
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        let win = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 460, height: 360),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = Loc.t("识别文字 — 已复制到剪贴板（\(text.count) 字符）",
                          "Recognized Text — Copied to Clipboard (\(text.count) chars)")
        win.center()
        win.isReleasedWhenClosed = false
        win.level = .floating

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let textView = NSTextView()
        textView.string = text
        textView.font = .systemFont(ofSize: 13)
        textView.isEditable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = CGSize(width: 8, height: 8)
        scroll.documentView = textView

        let copyBtn = NSButton(title: Loc.t("复制全部", "Copy All"), target: OCRActions.shared,
                               action: #selector(OCRActions.copyAll(_:)))
        copyBtn.translatesAutoresizingMaskIntoConstraints = false
        OCRActions.shared.textProvider[ObjectIdentifier(copyBtn)] = { textView.string }

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(copyBtn)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: copyBtn.topAnchor, constant: -8),
            copyBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            copyBtn.centerXAnchor.constraint(equalTo: content.centerXAnchor),
        ])
        win.contentView = content
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        windows.append(win)
    }
}

final class OCRActions: NSObject {
    @MainActor static let shared = OCRActions()
    @MainActor var textProvider: [ObjectIdentifier: () -> String] = [:]

    @MainActor @objc func copyAll(_ sender: NSButton) {
        guard let provider = textProvider[ObjectIdentifier(sender)] else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(provider(), forType: .string)
        OutputRouter.notifyHUD(Loc.t("已复制全部文字", "Copied all text"))
    }
}
