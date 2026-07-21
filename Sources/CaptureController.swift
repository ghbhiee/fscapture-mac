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

        switch action {
        case .rectangleClipboard:
            // Rect → clipboard should NOT steal focus: capture the frontmost app
            // and hand focus back once we're done (no editor/preview appears).
            let prevApp = NSWorkspace.shared.frontmostApplication
            withHiddenPanel { done in
                _ = SelectionOverlayController(mode: .rectangle) { result in
                    done()
                    guard case let .rect(rect, screen)? = result else {
                        prevApp?.activate()
                        return
                    }
                    Task { @MainActor in
                        do {
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
            withHiddenPanel { done in
                _ = SelectionOverlayController(mode: .rectangle) { result in
                    done()
                    guard case let .rect(rect, screen)? = result else { return }
                    self.finish { try await ScreenshotEngine.captureRect(rect, on: screen) }
                }
            }
        case .freehand:
            withHiddenPanel { done in
                _ = SelectionOverlayController(mode: .freehand) { result in
                    done()
                    guard case let .path(points, screen)? = result else { return }
                    self.finish { try await ScreenshotEngine.captureFreehand(path: points, on: screen) }
                }
            }
        case .fixedSize:
            withHiddenPanel { done in
                _ = SelectionOverlayController(mode: .fixedSize(Settings.shared.fixedSize)) { result in
                    done()
                    guard case let .rect(rect, screen)? = result else { return }
                    self.finish { try await ScreenshotEngine.captureRect(rect, on: screen) }
                }
            }
        case .fullScreen:
            withHiddenPanel { done in
                if Settings.shared.fullScreenAllDisplays {
                    self.finishMulti(screens: NSScreen.screens, done: done)
                } else {
                    let mouse = NSEvent.mouseLocation
                    let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
                    guard let screen else { done(); return }
                    self.finish(after: done) { try await ScreenshotEngine.captureDisplay(screen: screen) }
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
                    done()
                    guard let picked else { return }
                    self.finish { try await ScreenshotEngine.captureWindow(windowID: picked.windowID) }
                }
            }
        case .captureText:
            withHiddenPanel { done in
                _ = SelectionOverlayController(mode: .rectangle) { result in
                    done()
                    guard case let .rect(rect, screen)? = result else { return }
                    Task { @MainActor in
                        do {
                            let image = try await ScreenshotEngine.captureRect(rect, on: screen)
                            OCRTool.recognize(image)
                        } catch {
                            OutputRouter.notifyHUD(Loc.t("截图失败：\(error.localizedDescription)", "Capture failed: \(error.localizedDescription)"))
                        }
                    }
                }
            }
        case .pinToScreen:
            withHiddenPanel { done in
                _ = SelectionOverlayController(mode: .rectangle) { result in
                    done()
                    guard case let .rect(rect, screen)? = result else { return }
                    Task { @MainActor in
                        do {
                            let image = try await ScreenshotEngine.captureRect(rect, on: screen)
                            PinWindow.show(image: image, at: rect)
                        } catch {
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

    private func finishMulti(screens: [NSScreen], done: @escaping () -> Void) {
        Task { @MainActor in
            defer { done() }
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
