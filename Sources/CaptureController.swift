import AppKit

/// Orchestrates a capture from trigger (panel button / hotkey / menu) through
/// overlay interaction to the output router.
@MainActor
final class CaptureController {
    static let shared = CaptureController()
    private init() {}

    /// Set by AppDelegate so the panel can hide itself during captures.
    var panelToHide: NSWindow?

    func perform(_ action: CaptureAction) {
        // Import from Clipboard is not a screen capture — handle it first so it
        // never triggers the Screen Recording permission prompt.
        if action == .importClipboard {
            EditorWindowController.openFromClipboard()
            return
        }
        guard PermissionGuide.ensureScreenRecordingPermission() else { return }
        guard SelectionOverlayController.current == nil,
              WindowPickOverlayController.current == nil else { return }

        // The app the user was in BEFORE we activate for the overlay. Activating
        // our (accessory) app lifts ALL our windows — including the editor — above
        // that app, so a full-display capture would show the editor hollowing the
        // window the user actually wanted. We reactivate this app right before
        // compositing to put the z-order back to what the user saw. (Window-object
        // captures are isolated, so they don't need this.)
        let frontApp = NSWorkspace.shared.frontmostApplication

        switch action {
        case .rectangleClipboard:
            // Rect → clipboard should NOT steal focus: capture the frontmost app
            // and hand focus back once we're done (no editor/preview appears).
            let prevApp = frontApp
            withHiddenPanel { done in
                _ = SelectionOverlayController(mode: .rectangle) { result in
                    guard case let .rect(rect, screen)? = result else {
                        done()
                        prevApp?.activate()
                        return
                    }
                    Task { @MainActor in
                        defer { done() }   // restore the panel only after the capture
                        do {
                            await self.restoreFront(prevApp)   // also puts z-order back
                            let image = try await ScreenshotEngine.captureRect(rect, on: screen)
                            OutputRouter.copyToClipboard(image)
                            OutputRouter.notifyHUD(Loc.t("已复制到剪贴板", "Copied to clipboard"))
                        } catch {
                            OutputRouter.notifyHUD(Loc.t("截图失败：\(error.localizedDescription)", "Capture failed: \(error.localizedDescription)"))
                        }
                        prevApp?.activate()   // return focus to the user's app
                    }
                }
            }
        case .importClipboard:
            break  // handled above
        case .rectangle:
            // NB: restore the panel only AFTER the capture (finish(after:)),
            // otherwise it pops back into frame and lands in the screenshot.
            withHiddenPanel { done in
                _ = SelectionOverlayController(mode: .rectangle) { result in
                    guard case let .rect(rect, screen)? = result else { done(); return }
                    self.finish(after: done) {
                        await self.restoreFront(frontApp)
                        return try await ScreenshotEngine.captureRect(rect, on: screen)
                    }
                }
            }
        case .freehand:
            withHiddenPanel { done in
                _ = SelectionOverlayController(mode: .freehand) { result in
                    guard case let .path(points, screen)? = result else { done(); return }
                    self.finish(after: done) {
                        await self.restoreFront(frontApp)
                        return try await ScreenshotEngine.captureFreehand(path: points, on: screen)
                    }
                }
            }
        case .fixedSize:
            withHiddenPanel { done in
                _ = SelectionOverlayController(mode: .fixedSize(Settings.shared.fixedSize)) { result in
                    guard case let .rect(rect, screen)? = result else { done(); return }
                    self.finish(after: done) {
                        await self.restoreFront(frontApp)
                        return try await ScreenshotEngine.captureRect(rect, on: screen)
                    }
                }
            }
        case .fullScreen:
            withHiddenPanel { done in
                if Settings.shared.fullScreenAllDisplays {
                    self.finishMulti(screens: NSScreen.screens, restoring: frontApp, done: done)
                } else {
                    let mouse = NSEvent.mouseLocation
                    let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
                    guard let screen else { done(); return }
                    self.finish(after: done) {
                        await self.restoreFront(frontApp)
                        return try await ScreenshotEngine.captureDisplay(screen: screen)
                    }
                }
            }
        case .activeWindow:
            guard let target = WindowPickOverlayController.activeWindow() else {
                OutputRouter.notifyHUD(Loc.t("没有找到活动窗口", "No active window found"))
                return
            }
            withHiddenPanel { done in
                self.finish(after: done) { try await ScreenshotEngine.captureWindow(windowID: target.windowID) }
            }
        case .windowObject:
            withHiddenPanel { done in
                _ = WindowPickOverlayController { picked in
                    guard let picked else { done(); return }
                    self.finish(after: done) { try await ScreenshotEngine.captureWindow(windowID: picked.windowID) }
                }
            }
        case .captureText:
            withHiddenPanel { done in
                _ = SelectionOverlayController(mode: .rectangle) { result in
                    guard case let .rect(rect, screen)? = result else { done(); return }
                    Task { @MainActor in
                        do {
                            await self.restoreFront(frontApp)
                            let image = try await ScreenshotEngine.captureRect(rect, on: screen)
                            done()   // restore panel only AFTER the capture
                            OCRTool.recognize(image)
                        } catch {
                            done()
                            OutputRouter.notifyHUD(Loc.t("截图失败：\(error.localizedDescription)", "Capture failed: \(error.localizedDescription)"))
                        }
                    }
                }
            }
        case .pinToScreen:
            withHiddenPanel { done in
                _ = SelectionOverlayController(mode: .rectangle) { result in
                    guard case let .rect(rect, screen)? = result else { done(); return }
                    Task { @MainActor in
                        do {
                            await self.restoreFront(frontApp)
                            let image = try await ScreenshotEngine.captureRect(rect, on: screen)
                            done()   // restore panel only AFTER the capture
                            PinWindow.show(image: image, at: rect)
                        } catch {
                            done()
                            OutputRouter.notifyHUD(Loc.t("截图失败：\(error.localizedDescription)", "Capture failed: \(error.localizedDescription)"))
                        }
                    }
                }
            }
        case .scrolling:
            withHiddenPanel { done in
                ScrollCapture.begin()
                done()
            }
        case .intervalCapture:
            AutoCapture.begin()
        }
    }

    func runTool(_ tool: ScreenTool) {
        switch tool {
        case .colorPicker: ColorPickerTool.run()
        case .magnifier: MagnifierTool.toggle()
        case .ruler: RulerTool.toggle()
        case .crosshair: OverlayTool.toggle(.crosshair)
        case .focus: OverlayTool.toggle(.focus)
        }
    }

    /// Capture one screen per display (multi-monitor "all displays" mode).
    func captureDisplay(_ screen: NSScreen) {
        guard PermissionGuide.ensureScreenRecordingPermission() else { return }
        withHiddenPanel { done in
            self.finish(after: done) { try await ScreenshotEngine.captureDisplay(screen: screen) }
        }
    }

    /// Reactivate the app that was frontmost before we showed the overlay, so the
    /// screenshot composites in the z-order the user actually saw (our editor is
    /// no longer floating on top of their window). No-op when that app was us or
    /// is gone. The short wait lets the window server finish reordering.
    func restoreFront(_ app: NSRunningApplication?) async {
        guard let app,
              app.processIdentifier != NSRunningApplication.current.processIdentifier,
              !app.isTerminated else { return }
        app.activate()
        try? await Task.sleep(nanoseconds: 130_000_000)
    }

    private func finishMulti(screens: [NSScreen], restoring app: NSRunningApplication? = nil,
                             done: @escaping () -> Void) {
        Task { @MainActor in
            defer { done() }
            await self.restoreFront(app)
            for screen in screens {
                do {
                    let image = try await ScreenshotEngine.captureDisplay(screen: screen)
                    OutputRouter.deliver(image)
                } catch {
                    self.report(error)
                }
            }
        }
    }

    private func finish(after done: (() -> Void)? = nil,
                        _ produce: @escaping () async throws -> CGImage) {
        Task { @MainActor in
            defer { done?() }
            do {
                let image = try await produce()
                OutputRouter.deliver(image)
            } catch {
                self.report(error)
            }
        }
    }

    /// Hides the capture panel while the overlay/screenshot runs, restores after.
    private func withHiddenPanel(_ body: @escaping (@escaping () -> Void) -> Void) {
        let panel = panelToHide
        let wasVisible = panel?.isVisible ?? false
        panel?.orderOut(nil)
        // Give WindowServer a beat to actually remove the panel before capturing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            body {
                if wasVisible { panel?.orderFrontRegardless() }
            }
        }
    }

    private func report(_ error: Error) {
        NSLog("FSCapture: capture failed: \(error)")
        OutputRouter.notifyHUD(Loc.t("截图失败：\(error.localizedDescription)", "Capture failed: \(error.localizedDescription)"))
    }
}
