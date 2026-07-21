import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Keep the delegate alive for the app's lifetime.
    objc_setAssociatedObject(app, "fscapture.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.setActivationPolicy(.accessory)  // menu-bar resident, no Dock icon
    app.run()
}
