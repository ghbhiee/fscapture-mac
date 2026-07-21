import AppKit

/// The app normally lives in the menu bar only (accessory). While the editor
/// has content on screen we surface a Dock icon so the window can always be
/// found again after switching apps.
@MainActor
enum DockIcon {
    static func update(editorVisible: Bool) {
        let target: NSApplication.ActivationPolicy = editorVisible ? .regular : .accessory
        guard NSApp.activationPolicy() != target else { return }
        NSApp.setActivationPolicy(target)
        if editorVisible {
            // Policy switches need a nudge to (re)display the Dock tile and menu.
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
