import AppKit
import ScreenCaptureKit

/// Scrolling capture. The user marquees a region; we auto-scroll the target
/// (synthetic wheel events → needs Accessibility), sample that region with
/// ScreenCaptureKit (excluding our own windows), and stitch the frames.
///
/// Stitch offset strategy (informed by reverse-engineering FastStone 11.1,
/// which reads the real scrollbar Δpos instead of image-matching): because we
/// COMMAND the scroll, the expected per-frame shift is known, so we search SAD
/// only in a small window around that prior with a uniqueness guard — this
/// stops the matcher from locking onto a periodic false minimum one row-period
/// too deep (the cause of the earlier seam overlap). Frames are also captured
/// only once they've stopped changing, so we never measure a mid-scroll frame.
@MainActor
enum ScrollCapture {

    static func begin() {
        // Auto-scroll drives another app's content → needs Accessibility.
        guard AXPermission.ensure() else { return }
        // Remember who was in front so we can drive scrolling on it.
        let prevApp = NSWorkspace.shared.frontmostApplication
        _ = SelectionOverlayController(mode: .rectangle) { result in
            guard case let .rect(rect, screen)? = result,
                  rect.width >= 60, rect.height >= 60 else {
                if case .rect? = result { OutputRouter.notifyHUD(Loc.t("区域太小（至少 60×60）", "Region too small (at least 60×60)")) }
                return
            }
            ScrollSession.start(region: rect, screen: screen, previousApp: prevApp) { image in
                if let image { OutputRouter.deliver(image) }
            }
        }
    }
}

/// Raw RGBA8888 frame buffer with a stable data pointer (top row first).
final class ScrollBitmap {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let context: CGContext
    let data: UnsafeMutablePointer<UInt8>

    init?(width: Int, height: Int, clearWhite: Bool = false) {
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let raw = ctx.data else { return nil }
        self.width = width
        self.height = height
        self.bytesPerRow = ctx.bytesPerRow
        self.context = ctx
        self.data = raw.assumingMemoryBound(to: UInt8.self)
        if clearWhite {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Plain full-rect draw — bitmap-context memory row 0 is the TOP scanline,
    /// so `data` ends up top-row-first (the convention the stitcher assumes;
    /// identical to the verified MacPaint implementation).
    func load(_ img: CGImage) {
        context.saveGState()
        context.interpolationQuality = .none
        context.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.restoreGState()
    }

    func cgImage() -> CGImage? {
        context.makeImage()
    }
}

/// Manual-scroll capture session.
final class ScrollSession: @unchecked Sendable {
    private static var active: ScrollSession?

    private let region: CGRect            // Cocoa global, points
    private let screen: NSScreen
    private let previousApp: NSRunningApplication?
    private let completion: (CGImage?) -> Void
    private var hud: ScrollHUD?
    private var monitors: [Any] = []
    private var cancelled = false        // discard
    private var stoppedByUser = false    // finish + stitch (Esc / button / bottom)
    private let scale: CGFloat
    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private let scrollStep: Int32        // scroll-wheel pixels per tick
    private var scrollLocation = CGPoint.zero  // CG global, top-left origin

    private init(region: CGRect, screen: NSScreen, previousApp: NSRunningApplication?,
                 completion: @escaping (CGImage?) -> Void) {
        self.region = region
        self.screen = screen
        self.previousApp = previousApp
        self.completion = completion
        self.scale = screen.backingScaleFactor
        // ~35% of the region per tick → ~65% overlap, plenty for the matcher.
        self.scrollStep = Int32(max(60, min(220, region.height * 0.35)))
    }

    /// Expected per-frame shift in DEVICE px if the target scrolls ~1:1 with
    /// the commanded wheel amount — used to seed the constrained SAD search.
    private var expectedShiftPrior: Int { Int(CGFloat(scrollStep) * scale) }

    @MainActor
    static func start(region: CGRect, screen: NSScreen, previousApp: NSRunningApplication?,
                      completion: @escaping (CGImage?) -> Void) {
        let s = ScrollSession(region: region, screen: screen, previousApp: previousApp, completion: completion)
        active = s
        s.run()
    }

    @MainActor
    private func run() {
        let hud = ScrollHUD(region: region, screen: screen,
                            onFinish: { [weak self] in self?.stoppedByUser = true },
                            onCancel: { [weak self] in self?.cancelled = true })
        self.hud = hud
        hud.show()

        // Esc / Enter finish and stitch (Accessibility is granted here, so the
        // global monitor is reliable); the HUD buttons are a visible fallback.
        let handler: (NSEvent) -> Void = { [weak self] e in
            guard let self else { return }
            if e.keyCode == 53 || e.keyCode == 36 || e.keyCode == 76 { self.stoppedByUser = true }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { handler($0) }) {
            monitors.append(g)
        }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { handler($0); return $0 } as Any)

        // Make the target frontmost so it receives our synthetic scroll events.
        previousApp?.activate()

        // Where to aim the scroll events (CG global, top-left origin).
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        scrollLocation = CGPoint(x: region.midX, y: primaryHeight - region.midY)

        let regionLocal = CGRect(
            x: region.minX - screen.frame.minX,
            y: screen.frame.maxY - region.maxY,   // display-local top-left
            width: region.width, height: region.height)
        let displayID = ScreenshotEngine.displayID(of: screen)

        SCShareableContent.getWithCompletionHandler { [weak self] content, error in
            guard let self else { return }
            guard let content,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else {
                NSLog("FSCapture scrollcap: no SC display (\(String(describing: error)))")
                DispatchQueue.main.async { self.finish(with: nil) }
                return
            }
            let ours = content.applications.first { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter: SCContentFilter = ours.map {
                SCContentFilter(display: display, excludingApplications: [$0], exceptingWindows: [])
            } ?? SCContentFilter(display: display, excludingWindows: [])
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.captureLoop(filter: filter, sourceRect: regionLocal)
                DispatchQueue.main.async { self.finish(with: result) }
            }
        }
    }

    /// One SC snapshot of the region (our app excluded), device pixels.
    private func captureSC(filter: SCContentFilter, sourceRect: CGRect) -> CGImage? {
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = Int(sourceRect.width * scale)
        config.height = Int(sourceRect.height * scale)
        config.showsCursor = false
        config.scalesToFit = false
        let sem = DispatchSemaphore(value: 0)
        var out: CGImage?
        Task {
            out = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2.0)
        return out
    }

    /// Post one scroll-down wheel event aimed at the capture region.
    private func scrollDown() {
        guard let ev = CGEvent(scrollWheelEvent2Source: eventSource, units: .pixel,
                               wheelCount: 1, wheel1: -scrollStep, wheel2: 0, wheel3: 0) else { return }
        ev.location = scrollLocation
        ev.post(tap: .cghidEventTap)
    }

    /// Capture the region repeatedly until it stops changing (the scroll has
    /// settled and the target has finished repainting), then return that frame.
    private func captureStable(filter: SCContentFilter, sourceRect: CGRect) -> ScrollBitmap? {
        let deadline = Date().addingTimeInterval(1.2)
        var last: ScrollBitmap?
        while Date() < deadline && !cancelled && !stoppedByUser {
            guard let img = captureSC(filter: filter, sourceRect: sourceRect),
                  let bm = Self.bitmap(from: img) else { continue }
            if let l = last, l.width == bm.width, l.height == bm.height,
               memcmp(l.data, bm.data, bm.height * bm.bytesPerRow) == 0 {
                return bm   // two identical captures in a row → settled
            }
            last = bm
            Thread.sleep(forTimeInterval: 0.05)
        }
        return last
    }

    private func captureLoop(filter: SCContentFilter, sourceRect: CGRect) -> CGImage? {
        Thread.sleep(forTimeInterval: 0.3)
        guard let first = captureStable(filter: filter, sourceRect: sourceRect) else {
            NSLog("FSCapture scrollcap: first capture failed")
            return nil
        }
        var frames: [ScrollBitmap] = [first]
        var shifts: [Int] = []
        var stuckTicks = 0
        let startTime = Date()
        let minMove = 6
        let bottomTicks = 3          // consecutive no-move scrolls → at the bottom
        // Running estimate of the per-frame shift; seeded from the commanded
        // scroll amount and refined from confident measurements.
        var prior = expectedShiftPrior
        let radius = 60              // ±px search window (< one row height)
        while !cancelled && !stoppedByUser {
            scrollDown()
            Thread.sleep(forTimeInterval: 0.05)
            guard let bm = captureStable(filter: filter, sourceRect: sourceRect),
                  bm.width == first.width, bm.height == first.height else { continue }
            // First real frame searches wide (top of page is rarely periodic);
            // afterwards we lock to prior ± radius so a periodic row pattern
            // can't pull the match one row-period too deep.
            let firstFrame = shifts.isEmpty
            let (d, confident) = Self.measureShift(
                prev: frames.last!, next: bm,
                expected: firstFrame ? nil : prior,
                radius: firstFrame ? bm.height : radius)
            // When the match is ambiguous (periodic content), trust the
            // commanded scroll amount instead of a guessed offset.
            let shift = confident ? d : min(bm.height - 8, prior)
            if shift > minMove && shift < bm.height - 8 {
                frames.append(bm)
                shifts.append(shift)
                if confident { prior = (prior + d) / 2 }   // ease toward measured
                stuckTicks = 0
                let h = first.height + shifts.reduce(0, +)
                let count = frames.count
                DispatchQueue.main.async { [weak self] in self?.hud?.update(frames: count, deviceHeight: h) }
            } else {
                stuckTicks += 1
            }
            if stuckTicks >= bottomTicks { break }       // reached the bottom
            if Date().timeIntervalSince(startTime) > 180 { break }
            if frames.count > 800 { break }
        }
        if cancelled { return nil }
        if frames.count == 1 { return frames[0].cgImage() }
        return Self.stitch(frames: frames, shifts: shifts)
    }

    @MainActor
    private func finish(with image: CGImage?) {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        hud?.close()
        ScrollSession.active = nil
        if image == nil { OutputRouter.notifyHUD(Loc.t("滚动截图已取消", "Scrolling capture cancelled")) }
        completion(image)
    }

    // MARK: stitching (verified algorithm from MacPaint ScrollSnap)

    static func bitmap(from img: CGImage) -> ScrollBitmap? {
        guard let bm = ScrollBitmap(width: img.width, height: img.height) else { return nil }
        bm.load(img)
        return bm
    }

    /// How many device-pixel rows `next` adds BELOW `prev` after a downward
    /// scroll, by template-matching `next`'s top strip against `prev`.
    /// Searches only `expected ± radius` (whole range when `expected` is nil),
    /// prefers the smallest shift on ties, and reports `confident` only when
    /// the best match clearly beats any alternative a strip-height away —
    /// otherwise the content is periodic and the caller should fall back to
    /// the commanded scroll amount. Returns (shift, confident).
    static func measureShift(prev: ScrollBitmap, next: ScrollBitmap,
                             expected: Int?, radius: Int) -> (Int, Bool) {
        let h = prev.height, w = prev.width
        guard next.height == h, next.width == w, h > 80 else { return (0, false) }
        if memcmp(prev.data, next.data, h * prev.bytesPerRow) == 0 { return (0, true) }
        let stripH = min(48, h / 5)
        let x0 = w / 6, x1 = w - w / 6
        let colStep = 4
        let rowStep = max(1, stripH / 24)
        let maxShift = h - stripH
        let minMove = 6
        let lo = max(minMove, (expected.map { $0 - radius }) ?? minMove)
        let hi = min(maxShift, (expected.map { $0 + radius }) ?? maxShift)
        guard lo <= hi else { return (expected ?? 0, false) }

        var scores = [Int](repeating: 0, count: hi - lo + 1)
        for d in lo...hi {
            var score = 0
            for row in stride(from: 0, to: stripH, by: rowStep) {
                let pa = prev.data + (d + row) * prev.bytesPerRow
                let pb = next.data + row * next.bytesPerRow
                for x in stride(from: x0, to: x1, by: colStep) {
                    let o = x * 4
                    score += abs(Int(pa[o]) - Int(pb[o]))
                        + abs(Int(pa[o + 1]) - Int(pb[o + 1]))
                        + abs(Int(pa[o + 2]) - Int(pb[o + 2]))
                }
            }
            scores[d - lo] = score
        }
        // Best = smallest shift among the minima (strict <, so ties keep the
        // smaller d and never over-shoot into already-captured rows).
        var bestIdx = 0
        for i in 1..<scores.count where scores[i] < scores[bestIdx] { bestIdx = i }
        let bestScore = scores[bestIdx]
        // Nearest strong competitor at least a strip-height away.
        var second = Int.max
        for i in 0..<scores.count where abs(i - bestIdx) >= stripH {
            second = min(second, scores[i])
        }
        let confident = expected != nil || bestScore == 0
            || second == Int.max || bestScore * 3 < second
        return (bestIdx + lo, confident)
    }

    static func stitch(frames: [ScrollBitmap], shifts: [Int]) -> CGImage? {
        guard let first = frames.first else { return nil }
        let w = first.width, frameH = first.height
        let total = frameH + shifts.reduce(0, +)
        guard let out = ScrollBitmap(width: w, height: total, clearWhite: true) else { return nil }
        for row in 0..<frameH {
            memcpy(out.data + row * out.bytesPerRow,
                   first.data + row * first.bytesPerRow, w * 4)
        }
        var y = frameH
        for (i, shift) in shifts.enumerated() {
            let bm = frames[i + 1]
            let startRow = frameH - shift
            for row in 0..<shift {
                memcpy(out.data + (y + row) * out.bytesPerRow,
                       bm.data + (startRow + row) * bm.bytesPerRow, w * 4)
            }
            y += shift
        }
        return out.cgImage()
    }
}

/// Non-activating instruction HUD with guaranteed Finish/Cancel buttons
/// (works even without key-event monitoring). Excluded from the capture
/// like all our windows, and positioned outside the region anyway.
@MainActor
final class ScrollHUD {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")

    init(region: CGRect, screen: NSScreen, onFinish: @escaping () -> Void, onCancel: @escaping () -> Void) {
        let hudW: CGFloat = 560, hudH: CGFloat = 56
        var y = region.minY - hudH - 14                      // below the region
        if y < screen.visibleFrame.minY + 10 { y = region.maxY + 14 }  // else above
        let frame = NSRect(x: region.midX - hudW / 2, y: y, width: hudW, height: hudH)

        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true

        label.frame = NSRect(x: 14, y: 8, width: hudW - 210, height: hudH - 16)
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = .white
        label.maximumNumberOfLines = 2
        label.stringValue = Loc.t("自动向下滚动截取中… 到底自动完成 · Esc 结束并保存",
                                  "Auto-scrolling and capturing… stops at the bottom · press Esc to finish and save")
        bg.addSubview(label)

        let holder = ScrollHUDActions(onFinish: onFinish, onCancel: onCancel)
        self.actions = holder
        let finishBtn = NSButton(title: Loc.t("完成", "Finish"), target: holder, action: #selector(ScrollHUDActions.finish))
        finishBtn.bezelStyle = .rounded
        finishBtn.frame = NSRect(x: hudW - 190, y: 13, width: 86, height: 30)
        bg.addSubview(finishBtn)
        let cancelBtn = NSButton(title: Loc.t("取消", "Cancel"), target: holder, action: #selector(ScrollHUDActions.cancel))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.frame = NSRect(x: hudW - 98, y: 13, width: 86, height: 30)
        bg.addSubview(cancelBtn)

        panel.contentView = bg
    }

    private var actions: ScrollHUDActions?

    func show() { panel.orderFrontRegardless() }
    func close() { panel.orderOut(nil) }

    func update(frames: Int, deviceHeight: Int) {
        label.stringValue = Loc.t("已捕获 \(frames) 屏（约 \(deviceHeight) px）· 继续滚动 · 停 2 秒完成",
                                  "Captured \(frames) frames (~\(deviceHeight) px) · keep scrolling · stops after 2 s idle")
    }
}

final class ScrollHUDActions: NSObject {
    private let onFinish: () -> Void
    private let onCancel: () -> Void
    init(onFinish: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onFinish = onFinish
        self.onCancel = onCancel
    }
    @objc func finish() { onFinish() }
    @objc func cancel() { onCancel() }
}
