import AppKit
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noPermission
    case displayNotFound
    case windowNotFound
    case cropFailed

    var errorDescription: String? {
        switch self {
        case .noPermission:   return Loc.t("没有屏幕录制权限", "No Screen Recording permission")
        case .displayNotFound: return Loc.t("找不到目标显示器", "Target display not found")
        case .windowNotFound: return Loc.t("找不到目标窗口", "Target window not found")
        case .cropFailed:     return Loc.t("裁剪图像失败", "Failed to crop image")
        }
    }
}

/// Thin wrapper around ScreenCaptureKit's screenshot API.
enum ScreenshotEngine {

    static func shareableContent() async throws -> SCShareableContent {
        // onScreenWindowsOnly: false — otherwise SCK drops occluded windows
        // (e.g. our editor sitting behind the window being captured) from the
        // display composite, leaving that area blank in the screenshot.
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    }

    /// Window-picking / active-window helpers still want just the on-screen set.
    static func onScreenContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    private static func scale(for screen: NSScreen) -> CGFloat { screen.backingScaleFactor }

    /// Flush our own windows' backing stores before compositing a screenshot.
    ///
    /// Our windows are drawn by this very process, and layer-backed content (the
    /// SwiftUI settings window in particular) can still have an uncommitted
    /// CoreAnimation transaction when the capture composites — which is one way
    /// our own windows end up blank in a shot. Forcing a draw + commit is cheap
    /// insurance; deliberately no long sleep here, so captures stay responsive.
    private static func settleBeforeCapture() async {
        await MainActor.run {
            for window in NSApp.windows where window.isVisible {
                window.displayIfNeeded()
            }
            CATransaction.flush()
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Full capture of one screen, own windows excluded. Returns a CGImage in pixels.
    static func captureDisplay(screen: NSScreen) async throws -> CGImage {
        await settleBeforeCapture()
        let content = try await shareableContent()
        let displayID = displayID(of: screen)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }
        // Don't exclude our own windows: the capture panel and selection
        // overlays are already hidden before capture, and the user DOES want
        // the editor/preview windows to appear in screenshots.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let s = scale(for: screen)
        config.width = Int(CGFloat(display.width) * s)
        config.height = Int(CGFloat(display.height) * s)
        config.showsCursor = Settings.shared.includePointer
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Capture a rectangle given in Cocoa GLOBAL coordinates (bottom-left origin,
    /// points), confined to `screen`. Returns cropped pixels.
    static func captureRect(_ rect: CGRect, on screen: NSScreen) async throws -> CGImage {
        let full = try await captureDisplay(screen: screen)
        let s = scale(for: screen)
        // Convert global Cocoa rect -> top-left-origin local pixel rect.
        let local = CGRect(
            x: (rect.minX - screen.frame.minX) * s,
            y: (screen.frame.maxY - rect.maxY) * s,
            width: rect.width * s,
            height: rect.height * s
        ).integral
        guard let cropped = full.cropping(to: local) else { throw CaptureError.cropFailed }
        return cropped
    }

    /// Freehand capture: crop the path's bounding box, then mask everything
    /// outside the closed path to transparent. `path` points are Cocoa global.
    static func captureFreehand(path: [CGPoint], on screen: NSScreen) async throws -> CGImage {
        guard path.count >= 3 else { throw CaptureError.cropFailed }
        var bbox = CGRect.null
        for p in path { bbox = bbox.union(CGRect(origin: p, size: .zero)) }
        bbox = bbox.intersection(screen.frame)
        guard bbox.width >= 2, bbox.height >= 2 else { throw CaptureError.cropFailed }

        let cropped = try await captureRect(bbox, on: screen)
        let s = scale(for: screen)
        let w = cropped.width, h = cropped.height

        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError.cropFailed
        }
        // CGContext origin is bottom-left, matching Cocoa: convert each global
        // point to bbox-local pixels directly.
        let cgPath = CGMutablePath()
        let pts = path.map { CGPoint(x: ($0.x - bbox.minX) * s, y: ($0.y - bbox.minY) * s) }
        cgPath.move(to: pts[0])
        for p in pts.dropFirst() { cgPath.addLine(to: p) }
        cgPath.closeSubpath()
        ctx.addPath(cgPath)
        ctx.clip()
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { throw CaptureError.cropFailed }
        return out
    }

    /// Capture a single window by CGWindowID via desktop-independent filter.
    static func captureWindow(windowID: CGWindowID) async throws -> CGImage {
        await settleBeforeCapture()
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        // Pick the scale of the screen the window mostly lives on.
        let cocoaFrame = cocoaRect(fromCGGlobal: window.frame)
        let screen = NSScreen.screens.max(by: {
            $0.frame.intersection(cocoaFrame).area < $1.frame.intersection(cocoaFrame).area
        }) ?? NSScreen.main
        let s = screen?.backingScaleFactor ?? 2
        config.width = Int(window.frame.width * s)
        config.height = Int(window.frame.height * s)
        config.showsCursor = Settings.shared.includePointer
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// CGWindow/SCWindow frames use a top-left global origin; convert to Cocoa.
    static func cocoaRect(fromCGGlobal r: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
