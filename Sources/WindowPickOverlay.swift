import AppKit

struct PickableWindow {
    let windowID: CGWindowID
    let frame: CGRect        // Cocoa global coords
    let title: String
    let appName: String
}

/// "Capture Window / Object": transparent overlay across all screens; the
/// window under the mouse gets a red highlight border; click captures it.
@MainActor
final class WindowPickOverlayController {
    static var current: WindowPickOverlayController?

    private var windows: [PickWindow] = []
    private let completion: (PickableWindow?) -> Void
    private var finished = false
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init(completion: @escaping (PickableWindow?) -> Void) {
        self.completion = completion
        for screen in NSScreen.screens {
            let win = PickWindow(screen: screen) { [weak self] result in
                self?.finish(with: result)
            }
            windows.append(win)
            win.orderFrontRegardless()
        }
        let mouse = NSEvent.mouseLocation
        let target = windows.first { $0.screen?.frame.contains(mouse) ?? false } ?? windows.first
        NSApp.activate(ignoringOtherApps: true)
        target?.makeKeyAndOrderFront(nil)
        WindowPickOverlayController.current = self

        // App-wide Esc / right-click cancel so the overlay can never trap the desktop,
        // even if no window became key.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .rightMouseDown || event.keyCode == 53 { self.finish(with: nil); return nil }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .rightMouseDown]) { [weak self] event in
            if event.type == .rightMouseDown || event.keyCode == 53 { self?.finish(with: nil) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !self.finished,
                  !self.windows.contains(where: { $0.isKeyWindow }) else { return }
            NSApp.activate(ignoringOtherApps: true)
            target?.makeKeyAndOrderFront(nil)
        }
    }

    private func finish(with result: PickableWindow?) {
        guard !finished else { return }
        finished = true
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        NSCursor.arrow.set()
        if WindowPickOverlayController.current === self { WindowPickOverlayController.current = nil }
        completion(result)
    }

    /// Topmost on-screen window under `point` (Cocoa global), excluding our own.
    static func window(under point: CGPoint) -> PickableWindow? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        let cgPoint = CGPoint(x: point.x, y: primaryHeight - point.y)

        // System chrome that hover-picking should never land on (the Dock owns
        // an invisible full-screen window that would otherwise win every time).
        let systemOwners: Set<String> = ["Dock", "Window Server", "WindowManager", "Wallpaper"]

        for info in list {  // already front-to-back
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let alpha = info[kCGWindowAlpha as String] as? CGFloat ?? 1
            if alpha < 0.05 { continue }
            if let owner = info[kCGWindowOwnerName as String] as? String,
               systemOwners.contains(owner) { continue }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            if layer >= NSWindow.Level.screenSaver.rawValue { continue }  // don't pick overlays above us
            let cgFrame = CGRect(x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                                 width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0)
            if cgFrame.width < 8 || cgFrame.height < 8 { continue }
            guard cgFrame.contains(cgPoint) else { continue }
            let cocoaFrame = ScreenshotEngine.cocoaRect(fromCGGlobal: cgFrame)
            let title = info[kCGWindowName as String] as? String ?? ""
            let app = info[kCGWindowOwnerName as String] as? String ?? ""
            return PickableWindow(windowID: windowID, frame: cocoaFrame, title: title, appName: app)
        }
        return nil
    }

    /// Front window of the frontmost (non-self) application.
    static func activeWindow() -> PickableWindow? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if frontPID == ownPID { frontPID = nil }

        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }
            if let frontPID, pid != frontPID { continue }
            let cgFrame = CGRect(x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                                 width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0)
            if cgFrame.width < 8 || cgFrame.height < 8 { continue }
            let title = info[kCGWindowName as String] as? String ?? ""
            let app = info[kCGWindowOwnerName as String] as? String ?? ""
            return PickableWindow(windowID: windowID,
                                  frame: ScreenshotEngine.cocoaRect(fromCGGlobal: cgFrame),
                                  title: title, appName: app)
        }
        return nil
    }
}

private final class PickWindow: NSWindow {
    init(screen: NSScreen, onDone: @escaping (PickableWindow?) -> Void) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = PickView(onDone: onDone)
    }

    override var canBecomeKey: Bool { true }
}

private final class PickView: NSView {
    private let onDone: (PickableWindow?) -> Void
    private var highlighted: PickableWindow?
    private var trackingArea: NSTrackingArea?

    init(onDone: @escaping (PickableWindow?) -> Void) {
        self.onDone = onDone
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    // See SelectionView: accept the first mouse so clicks register even while our
    // accessory app is still inactive.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        refreshHighlight(at: NSEvent.mouseLocation)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    private func refreshHighlight(at globalPoint: CGPoint) {
        highlighted = WindowPickOverlayController.window(under: globalPoint)
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        guard let window else { return }
        refreshHighlight(at: window.convertPoint(toScreen: event.locationInWindow))
    }

    override func mouseDown(with event: NSEvent) { onDone(highlighted) }
    override func rightMouseDown(with event: NSEvent) { onDone(nil) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDone(nil) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let window, let screenFrame = window.screen?.frame else { return }
        if let hl = highlighted {
            let local = CGRect(x: hl.frame.minX - screenFrame.minX,
                               y: hl.frame.minY - screenFrame.minY,
                               width: hl.frame.width, height: hl.frame.height)
                .intersection(bounds)
            guard !local.isEmpty else { return }
            NSColor.systemRed.withAlphaComponent(0.12).setFill()
            local.fill()
            NSColor.systemRed.setStroke()
            let border = NSBezierPath(rect: local.insetBy(dx: 1.5, dy: 1.5))
            border.lineWidth = 3
            border.stroke()

            let label = hl.appName + (hl.title.isEmpty ? "" : " — \(hl.title)")
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let size = label.size(withAttributes: attrs)
            var origin = CGPoint(x: local.minX, y: local.maxY + 6)
            if origin.y + size.height + 8 > bounds.maxY { origin.y = local.maxY - size.height - 14 }
            let bg = CGRect(x: origin.x, y: origin.y, width: size.width + 12, height: size.height + 6)
            NSColor.black.withAlphaComponent(0.75).setFill()
            NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).fill()
            label.draw(at: CGPoint(x: origin.x + 6, y: origin.y + 3), withAttributes: attrs)
        }
    }
}
