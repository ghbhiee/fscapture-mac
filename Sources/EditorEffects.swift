import AppKit

/// FastStone editor effects (Edge/Watermark · Caption · Date-Time Stamp ·
/// Reflection) — small AppKit config dialogs plus their EditorWindowController
/// wiring. The raster work lives in ImageOps; these only gather parameters and
/// route through `applyRasterOp` so Undo keeps working.

// MARK: - shared token expansion (used by Caption + Stamp)

enum EffectTokens {
    /// Replace <date>/<time>/<datetime>/<computer>/<user> tokens with live
    /// values — mirrors FastStone's caption auto-insert menu.
    static func expand(_ s: String, format: String = "yyyy-MM-dd HH:mm:ss") -> String {
        let df = DateFormatter()
        df.dateFormat = format
        let now = df.string(from: Date())
        let dOnly = DateFormatter(); dOnly.dateFormat = "yyyy-MM-dd"
        let tOnly = DateFormatter(); tOnly.dateFormat = "HH:mm:ss"
        return s
            .replacingOccurrences(of: "<datetime>", with: now)
            .replacingOccurrences(of: "<date>", with: dOnly.string(from: Date()))
            .replacingOccurrences(of: "<time>", with: tOnly.string(from: Date()))
            .replacingOccurrences(of: "<computer>", with: Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
            .replacingOccurrences(of: "<user>", with: NSFullUserName())
    }
}

// MARK: - small AppKit dialog helpers

private extension NSView {
    func addLabel(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat = 90) {
        let l = NSTextField(labelWithString: text)
        l.frame = CGRect(x: x, y: y, width: w, height: 18)
        l.font = .systemFont(ofSize: 11)
        addSubview(l)
    }
}

// MARK: - Combine Images  (TCombineImages)

@MainActor
enum CombinePanel {
    struct Options { let horizontal: Bool; let spacing: Int; let background: NSColor }

    /// FastStone's Combine dialog: direction / spacing / background color.
    static func run(count: Int) -> Options? {
        let alert = NSAlert()
        alert.messageText = Loc.t("合并图像", "Combine Images")
        alert.informativeText = Loc.t("把当前 \(count) 个标签页合并成一张图。", "Combine the current \(count) tabs into one image.")
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 110))

        view.addLabel(Loc.t("方向:", "Direction:"), x: 0, y: 82, w: 60)
        let dir = NSPopUpButton(frame: CGRect(x: 64, y: 78, width: 220, height: 26))
        dir.addItems(withTitles: [Loc.t("垂直（上下）", "Vertical (top-bottom)"), Loc.t("水平（左右）", "Horizontal (left-right)")])
        view.addSubview(dir)

        view.addLabel(Loc.t("间距 px:", "Spacing px:"), x: 0, y: 46, w: 60)
        let spacing = NSTextField(frame: CGRect(x: 64, y: 44, width: 70, height: 22))
        spacing.stringValue = "0"
        view.addSubview(spacing)

        view.addLabel(Loc.t("背景:", "Background:"), x: 156, y: 46, w: 44)
        let bg = NSColorWell(frame: CGRect(x: 202, y: 40, width: 60, height: 26))
        bg.color = .white
        view.addSubview(bg)

        alert.accessoryView = view
        alert.addButton(withTitle: Loc.t("合并", "Combine"))
        alert.addButton(withTitle: Loc.t("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return Options(horizontal: dir.indexOfSelectedItem == 1,
                       spacing: max(0, Int(spacing.stringValue) ?? 0),
                       background: bg.color)
    }
}

// MARK: - Canvas Size  (exact width × height + anchor)

@MainActor
enum CanvasSizePanel {
    /// Returns the target canvas size and where the existing image is anchored.
    static func run(current: CGSize) -> (size: CGSize, anchor: ImageOps.GridAnchor)? {
        let alert = NSAlert()
        alert.messageText = Loc.t("画布大小", "Canvas Size")
        alert.informativeText = Loc.t("设置精确的画布宽高（px），并选择原图对齐的位置；新增区域填充白色。",
                                      "Set exact canvas width/height (px) and where the existing image anchors; new areas are filled white.")
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 84))

        view.addLabel(Loc.t("宽度:", "Width:"), x: 0, y: 56, w: 46)
        let wField = NSTextField(frame: CGRect(x: 48, y: 52, width: 80, height: 24))
        wField.integerValue = Int(current.width)
        view.addSubview(wField)
        view.addLabel(Loc.t("高度:", "Height:"), x: 150, y: 56, w: 46)
        let hField = NSTextField(frame: CGRect(x: 198, y: 52, width: 80, height: 24))
        hField.integerValue = Int(current.height)
        view.addSubview(hField)

        view.addLabel(Loc.t("锚点:", "Anchor:"), x: 0, y: 12, w: 46)
        let anchor = NSPopUpButton(frame: CGRect(x: 48, y: 8, width: 150, height: 26))
        anchor.addItems(withTitles: ImageOps.GridAnchor.allCases.map(\.label))
        anchor.selectItem(at: ImageOps.GridAnchor.center.rawValue)
        view.addSubview(anchor)

        alert.accessoryView = view
        alert.addButton(withTitle: Loc.t("确定", "OK"))
        alert.addButton(withTitle: Loc.t("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let size = CGSize(width: max(1, wField.integerValue), height: max(1, hField.integerValue))
        let a = ImageOps.GridAnchor(rawValue: anchor.indexOfSelectedItem) ?? .center
        return (size, a)
    }
}

// MARK: - Expand Canvas  (grow each side by N px, white fill)

@MainActor
enum ExpandCanvasPanel {
    /// Per-edge expansion in px (left, top, right, bottom). Empty sides fall
    /// back to the shared "四边" value.
    static func run() -> (left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat)? {
        let alert = NSAlert()
        alert.messageText = Loc.t("扩展画布", "Expand Canvas")
        alert.informativeText = Loc.t("在每一边增加空白（px），填充白色。留空的边使用「四边」的值。",
                                      "Add white space (px) on each side. Empty sides use the \"All Sides\" value.")
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 260, height: 120))

        view.addLabel(Loc.t("四边:", "All Sides:"), x: 0, y: 92, w: 46)
        let all = NSTextField(frame: CGRect(x: 48, y: 88, width: 70, height: 24))
        all.integerValue = 20
        view.addSubview(all)

        view.addLabel(Loc.t("左:", "Left:"), x: 0, y: 54, w: 34)
        let lf = NSTextField(frame: CGRect(x: 36, y: 50, width: 64, height: 22)); view.addSubview(lf)
        view.addLabel(Loc.t("上:", "Top:"), x: 128, y: 54, w: 34)
        let tf = NSTextField(frame: CGRect(x: 164, y: 50, width: 64, height: 22)); view.addSubview(tf)
        view.addLabel(Loc.t("右:", "Right:"), x: 0, y: 18, w: 34)
        let rf = NSTextField(frame: CGRect(x: 36, y: 14, width: 64, height: 22)); view.addSubview(rf)
        view.addLabel(Loc.t("下:", "Bottom:"), x: 128, y: 18, w: 34)
        let bf = NSTextField(frame: CGRect(x: 164, y: 14, width: 64, height: 22)); view.addSubview(bf)

        alert.accessoryView = view
        alert.addButton(withTitle: Loc.t("确定", "OK"))
        alert.addButton(withTitle: Loc.t("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let base = CGFloat(max(0, all.integerValue))
        func v(_ f: NSTextField) -> CGFloat {
            f.stringValue.isEmpty ? base : CGFloat(max(0, Int(f.stringValue) ?? 0))
        }
        return (v(lf), v(tf), v(rf), v(bf))
    }
}

// MARK: - Selection Size  (exact width × height, top-left kept)

@MainActor
enum SelectionSizePanel {
    static func run(current: CGSize) -> CGSize? {
        let alert = NSAlert()
        alert.messageText = Loc.t("选区大小", "Selection Size")
        alert.informativeText = Loc.t("设置矩形选区的精确宽高（px），保持左上角不变。",
                                      "Set the rectangular selection's exact width/height (px), keeping the top-left corner.")
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 220, height: 28))
        let wField = NSTextField(frame: CGRect(x: 0, y: 2, width: 80, height: 24))
        wField.integerValue = Int(current.width)
        let xLabel = NSTextField(labelWithString: "×")
        xLabel.frame = CGRect(x: 88, y: 5, width: 16, height: 18)
        let hField = NSTextField(frame: CGRect(x: 110, y: 2, width: 80, height: 24))
        hField.integerValue = Int(current.height)
        view.addSubview(wField); view.addSubview(xLabel); view.addSubview(hField)
        alert.accessoryView = view
        alert.addButton(withTitle: Loc.t("确定", "OK"))
        alert.addButton(withTitle: Loc.t("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return CGSize(width: max(1, wField.integerValue), height: max(1, hField.integerValue))
    }
}

// MARK: - 1. Edge / Watermark  (TEdgeSettings)

@MainActor
enum EdgeWatermarkPanel {
    static func run(for doc: EditorDocument, onApply: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = Loc.t("边缘 / 水印", "Edge / Watermark")
        alert.informativeText = Loc.t("选择一种边缘效果或叠加图片水印。", "Choose an edge effect or overlay an image watermark.")

        let view = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 210))

        view.addLabel(Loc.t("效果:", "Effect:"), x: 0, y: 184, w: 60)
        let kind = NSPopUpButton(frame: CGRect(x: 64, y: 180, width: 250, height: 26))
        kind.addItems(withTitles: [Loc.t("阴影边缘", "Shadow Edge"), Loc.t("实心边框", "Solid Border"),
                                   Loc.t("淡出边缘", "Fade Edge"), Loc.t("撕裂边缘", "Torn Edge"), Loc.t("图片水印", "Image Watermark")])
        view.addSubview(kind)

        // Shared strength slider (depth / border width / fade depth).
        view.addLabel(Loc.t("强度:", "Strength:"), x: 0, y: 150, w: 60)
        let strength = NSSlider(value: 24, minValue: 4, maxValue: 80, target: nil, action: nil)
        strength.frame = CGRect(x: 64, y: 146, width: 250, height: 24)
        view.addSubview(strength)

        // Color well (border / fade / torn color).
        view.addLabel(Loc.t("颜色:", "Color:"), x: 0, y: 116, w: 60)
        let colorWell = NSColorWell(frame: CGRect(x: 64, y: 110, width: 60, height: 26))
        colorWell.color = .white
        view.addSubview(colorWell)

        // Watermark controls.
        view.addLabel(Loc.t("水印图片:", "Watermark:"), x: 0, y: 78, w: 70)
        let pathLabel = NSTextField(labelWithString: Loc.t("（未选择）", "(none)"))
        pathLabel.frame = CGRect(x: 74, y: 78, width: 160, height: 18)
        pathLabel.font = .systemFont(ofSize: 10)
        pathLabel.lineBreakMode = .byTruncatingHead
        view.addSubview(pathLabel)
        var markImage: CGImage?
        let pickButton = NSButton(title: Loc.t("选择…", "Choose…"), target: PickTarget.shared, action: #selector(PickTarget.pick(_:)))
        pickButton.frame = CGRect(x: 238, y: 74, width: 76, height: 26)
        pickButton.bezelStyle = .rounded
        PickTarget.shared.onPick = { img, name in
            markImage = img
            pathLabel.stringValue = name
        }
        view.addSubview(pickButton)

        view.addLabel(Loc.t("位置:", "Position:"), x: 0, y: 44, w: 60)
        let anchor = NSPopUpButton(frame: CGRect(x: 64, y: 40, width: 120, height: 26))
        anchor.addItems(withTitles: ImageOps.GridAnchor.allCases.map(\.label))
        anchor.selectItem(at: ImageOps.GridAnchor.bottomRight.rawValue)
        view.addSubview(anchor)
        view.addLabel(Loc.t("不透明度:", "Opacity:"), x: 192, y: 44, w: 66)
        let opacity = NSSlider(value: 0.4, minValue: 0.05, maxValue: 1, target: nil, action: nil)
        opacity.frame = CGRect(x: 200, y: 8, width: 114, height: 24)
        view.addSubview(opacity)

        alert.accessoryView = view
        alert.addButton(withTitle: Loc.t("应用", "Apply"))
        alert.addButton(withTitle: Loc.t("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let s = CGFloat(strength.doubleValue)
        let color = colorWell.color
        switch kind.indexOfSelectedItem {
        case 0:
            doc.applyRasterOp(Loc.t("阴影边缘", "Shadow Edge")) { ImageOps.shadowEdge($0, depth: s, blur: s / 2, darkness: 0.5) }
        case 1:
            doc.applyRasterOp(Loc.t("实心边框", "Solid Border")) { ImageOps.solidBorder($0, width: s / 3 + 1, color: color) }
        case 2:
            doc.applyRasterOp(Loc.t("淡出边缘", "Fade Edge")) { ImageOps.fadeEdge($0, depth: s, color: color) }
        case 3:
            doc.applyRasterOp(Loc.t("撕裂边缘", "Torn Edge")) { ImageOps.tornEdge($0, depth: s / 2, color: color) }
        default:
            guard let mark = markImage else {
                OutputRouter.notifyHUD(Loc.t("请先选择一张水印图片", "Choose a watermark image first"))
                return
            }
            let a = ImageOps.GridAnchor(rawValue: anchor.indexOfSelectedItem) ?? .bottomRight
            let op = CGFloat(opacity.doubleValue)
            doc.applyRasterOp(Loc.t("图片水印", "Image Watermark")) { ImageOps.watermark($0, mark: mark, anchor: a, opacity: op) }
        }
        onApply()
    }

    /// Objective-C target for the "选择…" button's file panel.
    @MainActor
    final class PickTarget: NSObject {
        static let shared = PickTarget()
        var onPick: ((CGImage, String) -> Void)?
        @objc func pick(_ sender: Any?) {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .gif]
            panel.allowsMultipleSelection = false
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let url = panel.url,
                  let img = NSImage(contentsOf: url),
                  let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            onPick?(cg, url.lastPathComponent)
        }
    }
}

// MARK: - 2. Caption  (TCommentSettings)

@MainActor
enum CaptionPanel {
    static func run(for doc: EditorDocument, onApply: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = Loc.t("标题栏", "Caption")
        alert.informativeText = Loc.t("在图像上/下方添加文字标题。可用记号：<date> <time> <datetime> <computer> <user>",
                                      "Add a text caption above/below the image. Tokens: <date> <time> <datetime> <computer> <user>")

        let view = NSView(frame: CGRect(x: 0, y: 0, width: 340, height: 150))
        view.addLabel(Loc.t("文字:", "Text:"), x: 0, y: 124, w: 50)
        let text = NSTextField(frame: CGRect(x: 54, y: 120, width: 286, height: 24))
        text.stringValue = "<datetime>"
        view.addSubview(text)

        view.addLabel(Loc.t("位置:", "Position:"), x: 0, y: 88, w: 50)
        let position = NSSegmentedControl(labels: [Loc.t("顶部", "Top"), Loc.t("底部", "Bottom")], trackingMode: .selectOne,
                                          target: nil, action: nil)
        position.frame = CGRect(x: 54, y: 84, width: 120, height: 24)
        position.selectedSegment = 1
        view.addSubview(position)

        view.addLabel(Loc.t("字号:", "Font Size:"), x: 190, y: 88, w: 44)
        let fontSize = NSTextField(frame: CGRect(x: 236, y: 84, width: 50, height: 24))
        fontSize.integerValue = 18
        view.addSubview(fontSize)

        view.addLabel(Loc.t("背景:", "Background:"), x: 0, y: 48, w: 50)
        let bg = NSColorWell(frame: CGRect(x: 54, y: 42, width: 54, height: 26))
        bg.color = NSColor(white: 0.12, alpha: 1)
        view.addSubview(bg)
        view.addLabel(Loc.t("文字色:", "Text Color:"), x: 120, y: 48, w: 54)
        let fg = NSColorWell(frame: CGRect(x: 178, y: 42, width: 54, height: 26))
        fg.color = .white
        view.addSubview(fg)

        let borderCheck = NSButton(checkboxWithTitle: Loc.t("描边框", "Border"), target: nil, action: nil)
        borderCheck.frame = CGRect(x: 54, y: 8, width: 120, height: 22)
        view.addSubview(borderCheck)

        alert.accessoryView = view
        alert.addButton(withTitle: Loc.t("应用", "Apply"))
        alert.addButton(withTitle: Loc.t("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let resolved = EffectTokens.expand(text.stringValue)
        guard !resolved.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: CGFloat(max(6, fontSize.integerValue)))
        let top = position.selectedSegment == 0
        let bgColor = bg.color, fgColor = fg.color
        let border = borderCheck.state == .on ? fgColor : nil
        doc.applyRasterOp(Loc.t("标题栏", "Caption")) {
            ImageOps.caption($0, text: resolved, font: font, top: top,
                             background: bgColor, textColor: fgColor, border: border)
        }
        onApply()
    }
}

// MARK: - 3. Date-Time Stamp  (TStampSettings)

@MainActor
enum StampPanel {
    static func run(for doc: EditorDocument, onApply: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = Loc.t("日期时间戳", "Date Time Stamp")
        alert.informativeText = Loc.t("在图像角落叠加日期时间。", "Overlay the date and time in a corner of the image.")

        let view = NSView(frame: CGRect(x: 0, y: 0, width: 320, height: 150))
        view.addLabel(Loc.t("格式:", "Format:"), x: 0, y: 124, w: 50)
        let format = NSTextField(frame: CGRect(x: 54, y: 120, width: 266, height: 24))
        format.stringValue = "yyyy-MM-dd HH:mm:ss"
        view.addSubview(format)

        view.addLabel(Loc.t("位置:", "Position:"), x: 0, y: 88, w: 50)
        let anchor = NSPopUpButton(frame: CGRect(x: 54, y: 84, width: 150, height: 26))
        anchor.addItems(withTitles: ImageOps.GridAnchor.allCases.map(\.label))
        anchor.selectItem(at: ImageOps.GridAnchor.bottomRight.rawValue)
        view.addSubview(anchor)

        view.addLabel(Loc.t("字号:", "Font Size:"), x: 214, y: 88, w: 44)
        let fontSize = NSTextField(frame: CGRect(x: 260, y: 84, width: 50, height: 24))
        fontSize.integerValue = 20
        view.addSubview(fontSize)

        view.addLabel(Loc.t("颜色:", "Color:"), x: 0, y: 48, w: 50)
        let color = NSColorWell(frame: CGRect(x: 54, y: 42, width: 54, height: 26))
        color.color = .yellow
        view.addSubview(color)

        let shadowCheck = NSButton(checkboxWithTitle: Loc.t("阴影", "Shadow"), target: nil, action: nil)
        shadowCheck.frame = CGRect(x: 130, y: 44, width: 100, height: 22)
        shadowCheck.state = .on
        view.addSubview(shadowCheck)

        alert.accessoryView = view
        alert.addButton(withTitle: Loc.t("应用", "Apply"))
        alert.addButton(withTitle: Loc.t("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let fmt = format.stringValue.isEmpty ? "yyyy-MM-dd HH:mm:ss" : format.stringValue
        let stamp = EffectTokens.expand("<datetime>", format: fmt)
        let font = NSFont.boldSystemFont(ofSize: CGFloat(max(6, fontSize.integerValue)))
        let a = ImageOps.GridAnchor(rawValue: anchor.indexOfSelectedItem) ?? .bottomRight
        let c = color.color
        let shadow = shadowCheck.state == .on
        doc.applyRasterOp(Loc.t("日期时间戳", "Date Time Stamp")) {
            ImageOps.dateStamp($0, text: stamp, font: font, anchor: a, color: c, shadow: shadow)
        }
        onApply()
    }
}

// MARK: - 4. Reflection  (TReflectionWin)

@MainActor
enum ReflectionPanel {
    static func run(for doc: EditorDocument, onApply: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = Loc.t("倒影", "Reflection")
        alert.informativeText = Loc.t("在图像下方添加渐隐镜像倒影。", "Add a fading mirror reflection below the image.")

        let view = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        view.addLabel(Loc.t("倒影高度 %:", "Reflection Height %:"), x: 0, y: 72, w: 90)
        let height = NSSlider(value: 40, minValue: 10, maxValue: 100, target: nil, action: nil)
        height.frame = CGRect(x: 96, y: 68, width: 204, height: 24)
        view.addSubview(height)

        view.addLabel(Loc.t("起始不透明度:", "Start Opacity:"), x: 0, y: 40, w: 100)
        let opacity = NSSlider(value: 0.5, minValue: 0.1, maxValue: 1, target: nil, action: nil)
        opacity.frame = CGRect(x: 100, y: 36, width: 200, height: 24)
        view.addSubview(opacity)

        view.addLabel(Loc.t("背景:", "Background:"), x: 0, y: 4, w: 50)
        let bg = NSColorWell(frame: CGRect(x: 54, y: 0, width: 54, height: 24))
        bg.color = .white
        view.addSubview(bg)

        alert.accessoryView = view
        alert.addButton(withTitle: Loc.t("应用", "Apply"))
        alert.addButton(withTitle: Loc.t("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let frac = CGFloat(height.doubleValue / 100)
        let op = CGFloat(opacity.doubleValue)
        let bgColor = bg.color
        doc.applyRasterOp(Loc.t("倒影", "Reflection")) {
            ImageOps.reflection($0, heightFraction: frac, startOpacity: op, background: bgColor)
        }
        onApply()
    }
}

// MARK: - 5. Make Background Transparent  (TMakeTransparentWin)

@MainActor
enum TransparentPanel {
    static func run(for doc: EditorDocument, onApply: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = Loc.t("背景透明", "Make Background Transparent")
        alert.informativeText = Loc.t("把与所选颜色相近的像素变透明（导出 PNG 保留透明）。默认取左上角像素颜色。",
                                      "Make pixels close to the chosen color transparent (kept when exporting PNG). Defaults to the top-left pixel color.")

        let view = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        view.addLabel(Loc.t("颜色:", "Color:"), x: 0, y: 72, w: 50)
        let colorWell = NSColorWell(frame: CGRect(x: 54, y: 66, width: 54, height: 26))
        colorWell.color = ImageOps.topLeftColor(doc.background)
        view.addSubview(colorWell)

        view.addLabel(Loc.t("容差:", "Tolerance:"), x: 0, y: 32, w: 50)
        let tolerance = NSSlider(value: 30, minValue: 0, maxValue: 128, target: nil, action: nil)
        tolerance.frame = CGRect(x: 54, y: 28, width: 200, height: 24)
        view.addSubview(tolerance)
        let tolValue = NSTextField(labelWithString: "30")
        tolValue.frame = CGRect(x: 258, y: 30, width: 40, height: 18)
        tolValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        view.addSubview(tolValue)
        SliderEcho.shared.bind(tolerance, to: tolValue)

        alert.accessoryView = view
        alert.addButton(withTitle: Loc.t("应用", "Apply"))
        alert.addButton(withTitle: Loc.t("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let color = colorWell.color
        let tol = tolerance.integerValue
        doc.applyRasterOp(Loc.t("背景透明", "Make Background Transparent")) { ImageOps.makeTransparent($0, color: color, tolerance: tol) }
        onApply()
    }

    /// Live-echoes an integer slider's value into a label.
    @MainActor
    final class SliderEcho: NSObject {
        static let shared = SliderEcho()
        private var label: NSTextField?
        func bind(_ slider: NSSlider, to label: NSTextField) {
            self.label = label
            slider.target = self
            slider.action = #selector(changed(_:))
        }
        @objc func changed(_ sender: NSSlider) { label?.integerValue = sender.integerValue }
    }
}

// MARK: - EditorWindowController wiring

@MainActor
extension EditorWindowController {
    @objc func edgeWatermarkEffect(_ sender: Any?) {
        guard let doc = currentDocument else { return }
        runEffectPanel { onApply in EdgeWatermarkPanel.run(for: doc, onApply: onApply) }
    }

    @objc func captionEffect(_ sender: Any?) {
        guard let doc = currentDocument else { return }
        runEffectPanel { onApply in CaptionPanel.run(for: doc, onApply: onApply) }
    }

    @objc func stampEffect(_ sender: Any?) {
        guard let doc = currentDocument else { return }
        runEffectPanel { onApply in StampPanel.run(for: doc, onApply: onApply) }
    }

    @objc func reflectionEffect(_ sender: Any?) {
        guard let doc = currentDocument else { return }
        runEffectPanel { onApply in ReflectionPanel.run(for: doc, onApply: onApply) }
    }

    @objc func makeTransparentEffect(_ sender: Any?) {
        guard let doc = currentDocument else { return }
        runEffectPanel { onApply in TransparentPanel.run(for: doc, onApply: onApply) }
    }
}
