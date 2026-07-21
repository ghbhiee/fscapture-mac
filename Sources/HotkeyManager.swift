import AppKit
import Carbon.HIToolbox

/// A key + Carbon modifier mask, serialized as "keyCode:modifiers".
struct KeyCombo: Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    var stringValue: String { "\(keyCode):\(carbonModifiers)" }

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    init?(stringValue: String) {
        let parts = stringValue.split(separator: ":")
        guard parts.count == 2, let k = UInt32(parts[0]), let m = UInt32(parts[1]) else { return nil }
        self.init(keyCode: k, carbonModifiers: m)
    }

    init?(event: NSEvent) {
        var mods: UInt32 = 0
        if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
        guard mods != 0 else { return nil }  // require at least one modifier
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: mods)
    }

    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        s += KeyCombo.keyName(for: keyCode)
        return s
    }

    static func keyName(for keyCode: UInt32) -> String {
        let special: [UInt32: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
            103: "F11", 105: "F13", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
            118: "F4", 120: "F2", 122: "F1",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        if let name = special[keyCode] { return name }
        // Translate through the current keyboard layout.
        if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let err = data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> OSStatus in
                let layout = buf.bindMemory(to: UCKeyboardLayout.self).baseAddress!
                return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                      UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysMask),
                                      &deadKeyState, chars.count, &length, &chars)
            }
            if err == noErr, length > 0 {
                return String(utf16CodeUnits: chars, count: length).uppercased()
            }
        }
        return "key\(keyCode)"
    }
}

/// Registers Carbon global hotkeys for capture actions and fires callbacks.
final class HotkeyManager {
    static let shared = HotkeyManager()

    var onAction: ((CaptureAction) -> Void)?

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var handlerInstalled = false

    private init() {}

    func reloadFromSettings() {
        installHandlerIfNeeded()
        for (_, ref) in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()

        for action in CaptureAction.allCases {
            // Import-from-clipboard is app-local (a menu ⌥V), never a global key.
            if action == .importClipboard { continue }
            guard let combo = Settings.shared.hotkey(for: action) else { continue }
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x46534341) /* 'FSCA' */, id: action.rawValue)
            let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hotKeyID,
                                             GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref {
                hotKeyRefs[action.rawValue] = ref
            } else {
                NSLog("FSCapture: failed to register hotkey \(combo.displayString) for \(action) (err \(status))")
            }
        }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData!).takeUnretainedValue()
            if let action = CaptureAction(rawValue: hotKeyID.id) {
                DispatchQueue.main.async { manager.onAction?(action) }
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)
        handlerInstalled = true
    }
}
