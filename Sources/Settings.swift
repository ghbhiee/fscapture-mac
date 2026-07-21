import Foundation

/// Where a finished capture goes (FastStone "Output > Destination").
enum OutputDestination: String, CaseIterable {
    case editor      // open in the annotation editor
    case clipboard
    case file        // Save-As dialog
    case autoSave    // template-named file in the auto-save folder, no dialog
    case printer     // NSPrintOperation
    case share       // macOS share sheet (FastStone "To Email/OneNote/…")

    var label: String {
        switch self {
        case .editor:    return Loc.t("打开到编辑器", "To Editor")
        case .clipboard: return Loc.t("复制到剪贴板", "To Clipboard")
        case .file:      return Loc.t("保存为文件", "To File")
        case .autoSave:  return Loc.t("自动保存文件", "To File (Auto Save)")
        case .printer:   return Loc.t("打印", "To Printer")
        case .share:     return Loc.t("邮件 / 共享", "To Email / Share")
        }
    }
}

enum ImageFormat: String, CaseIterable {
    case png, jpeg

    var label: String { self == .png ? "PNG" : "JPEG" }
    var fileExtension: String { self == .png ? "png" : "jpg" }
}

/// All the global capture actions that can carry a hotkey.
/// Raw value doubles as the Carbon hot-key ID, so keep them stable.
enum CaptureAction: UInt32, CaseIterable {
    case activeWindow = 1
    case windowObject = 2
    case rectangle = 3
    case freehand = 4
    case fullScreen = 5
    case scrolling = 6
    case fixedSize = 7
    case captureText = 8   // OCR
    case pinToScreen = 9
    case intervalCapture = 10   // 定时自动截图 (FastStone TIntervalCaptureWin)
    case rectangleClipboard = 11 // 矩形区域直接进剪贴板（无视 Output 目标）
    case importClipboard = 12    // 从剪贴板导入编辑器（非截图动作，不需屏幕录制权限）

    var label: String {
        switch self {
        case .activeWindow: return Loc.t("捕获活动窗口", "Capture Active Window")
        case .windowObject: return Loc.t("捕获窗口 / 对象", "Capture Window / Object")
        case .rectangle:    return Loc.t("捕获矩形区域", "Capture Rectangular Region")
        case .freehand:     return Loc.t("捕获手绘区域", "Capture Freehand Region")
        case .fullScreen:   return Loc.t("捕获全屏", "Capture Full Screen")
        case .scrolling:    return Loc.t("捕获滚动窗口", "Capture Scrolling Window")
        case .fixedSize:    return Loc.t("捕获固定尺寸区域", "Capture Fixed-Size Region")
        case .captureText:  return Loc.t("捕获文字 (OCR)", "Capture Text (OCR)")
        case .pinToScreen:  return Loc.t("钉在屏幕上", "Pin to Screen")
        case .intervalCapture: return Loc.t("定时自动截图", "Auto Screen Capture")
        case .rectangleClipboard: return Loc.t("矩形区域 → 仅复制到剪贴板", "Rectangle → Copy to Clipboard")
        case .importClipboard: return Loc.t("从剪贴板导入", "Import from Clipboard")
        }
    }

    var symbolName: String {
        switch self {
        case .activeWindow: return "macwindow"
        case .windowObject: return "cursorarrow.click.2"
        case .rectangle:    return "rectangle.dashed"
        case .freehand:     return "scribble"
        case .fullScreen:   return "display"
        case .scrolling:    return "arrow.up.and.down.text.horizontal"
        case .fixedSize:    return "crop"
        case .captureText:  return "text.viewfinder"
        case .pinToScreen:  return "pin"
        case .intervalCapture: return "timer"
        case .rectangleClipboard: return "rectangle.on.rectangle"
        case .importClipboard: return "doc.on.clipboard"
        }
    }
}

/// Screen tools (FastStone's toolbar utilities) — no global hotkeys for now.
enum ScreenTool: Int, CaseIterable {
    case colorPicker = 1
    case magnifier = 2
    case ruler = 3
    case crosshair = 4
    case focus = 5

    var label: String {
        switch self {
        case .colorPicker: return Loc.t("屏幕取色器", "Screen Color Picker")
        case .magnifier:   return Loc.t("屏幕放大镜", "Screen Magnifier")
        case .ruler:       return Loc.t("屏幕标尺", "Screen Ruler")
        case .crosshair:   return Loc.t("屏幕准线", "Screen Crosshair")
        case .focus:       return Loc.t("屏幕聚焦", "Screen Focus")
        }
    }

    var symbolName: String {
        switch self {
        case .colorPicker: return "eyedropper"
        case .magnifier:   return "magnifyingglass"
        case .ruler:       return "ruler"
        case .crosshair:   return "plus.viewfinder"
        case .focus:       return "flashlight.on.fill"
        }
    }
}

/// UserDefaults-backed app settings.
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "destination": OutputDestination.editor.rawValue,
            "previewEnabled": true,
            "includePointer": false,
            "autoSaveCopyToClipboard": true,
            "filenameTemplate": "$Y-$M-$D_$H$N$S",
            "sequenceCounter": 1,
            "imageFormat": ImageFormat.png.rawValue,
            "jpegQuality": 0.9,
            "fixedSizeWidth": 800,
            "fixedSizeHeight": 600,
            "fullScreenAllDisplays": false,
            // Default hotkeys (user decision): ⌘⇧S = rectangle, ⌘⇧D = scrolling,
            // ⌥⇧S = rectangle→clipboard, ⌥V = import from clipboard.
            // Carbon modifier bits: cmd=256 shift=512 option=2048 control=4096.
            "hotkey.\(CaptureAction.rectangle.rawValue)": KeyCombo(keyCode: 1, carbonModifiers: 768).stringValue,   // ⌘⇧S
            "hotkey.\(CaptureAction.scrolling.rawValue)": KeyCombo(keyCode: 2, carbonModifiers: 768).stringValue,   // ⌘⇧D
            "hotkey.\(CaptureAction.rectangleClipboard.rawValue)": KeyCombo(keyCode: 1, carbonModifiers: 2560).stringValue, // ⌥⇧S
            "hotkey.\(CaptureAction.importClipboard.rawValue)": KeyCombo(keyCode: 9, carbonModifiers: 2048).stringValue,    // ⌥V
            "hotkey.\(CaptureAction.pinToScreen.rawValue)": KeyCombo(keyCode: 2, carbonModifiers: 2560).stringValue,      // ⌥⇧D
        ])
    }

    var destination: OutputDestination {
        get { OutputDestination(rawValue: d.string(forKey: "destination") ?? "") ?? .editor }
        set { d.set(newValue.rawValue, forKey: "destination") }
    }

    var previewEnabled: Bool {
        get { d.bool(forKey: "previewEnabled") }
        set { d.set(newValue, forKey: "previewEnabled") }
    }

    var includePointer: Bool {
        get { d.bool(forKey: "includePointer") }
        set { d.set(newValue, forKey: "includePointer") }
    }

    var autoSaveCopyToClipboard: Bool {
        get { d.bool(forKey: "autoSaveCopyToClipboard") }
        set { d.set(newValue, forKey: "autoSaveCopyToClipboard") }
    }

    /// When the destination is "To Editor", also copy the capture to the
    /// clipboard (user-requested "To Editor + Clipboard").
    var editorAlsoCopyToClipboard: Bool {
        get { d.bool(forKey: "editorAlsoCopyToClipboard") }
        set { d.set(newValue, forKey: "editorAlsoCopyToClipboard") }
    }

    var autoSaveFolder: URL {
        get {
            if let path = d.string(forKey: "autoSaveFolder"), !path.isEmpty {
                return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            }
            return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FSCapture")
        }
        set { d.set(newValue.path, forKey: "autoSaveFolder") }
    }

    var filenameTemplate: String {
        get { d.string(forKey: "filenameTemplate") ?? "$Y-$M-$D_$H$N$S" }
        set { d.set(newValue, forKey: "filenameTemplate") }
    }

    var sequenceCounter: Int {
        get { d.integer(forKey: "sequenceCounter") }
        set { d.set(newValue, forKey: "sequenceCounter") }
    }

    var imageFormat: ImageFormat {
        get { ImageFormat(rawValue: d.string(forKey: "imageFormat") ?? "") ?? .png }
        set { d.set(newValue.rawValue, forKey: "imageFormat") }
    }

    var jpegQuality: Double {
        get { d.double(forKey: "jpegQuality") }
        set { d.set(newValue, forKey: "jpegQuality") }
    }

    var fixedSize: CGSize {
        get { CGSize(width: max(16, d.integer(forKey: "fixedSizeWidth")),
                     height: max(16, d.integer(forKey: "fixedSizeHeight"))) }
        set {
            d.set(Int(newValue.width), forKey: "fixedSizeWidth")
            d.set(Int(newValue.height), forKey: "fixedSizeHeight")
        }
    }

    var fullScreenAllDisplays: Bool {
        get { d.bool(forKey: "fullScreenAllDisplays") }
        set { d.set(newValue, forKey: "fullScreenAllDisplays") }
    }

    func hotkey(for action: CaptureAction) -> KeyCombo? {
        guard let s = d.string(forKey: "hotkey.\(action.rawValue)"), !s.isEmpty else { return nil }
        return KeyCombo(stringValue: s)
    }

    func setHotkey(_ combo: KeyCombo?, for action: CaptureAction) {
        d.set(combo?.stringValue ?? "", forKey: "hotkey.\(action.rawValue)")
    }
}
