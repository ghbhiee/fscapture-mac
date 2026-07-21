import AppKit

/// Outcome of a Draw session (FastStone TTextBoard: Save · OK · Cancel).
enum DrawOutcome {
    case ok([Annotation], Int)      // annotations, stepCounter
    case save([Annotation], Int)
    case cancel
}

/// The Draw tool layer, entered from the editor with `D`. Owns a tool strip,
/// a properties strip and an object-editing canvas; commits or discards the
/// whole session via OK / Save / Cancel like the original.
@MainActor
final class DrawModeController {
    private(set) var rootView: NSView = NSView()
    let canvas: DrawCanvasView

    private let completion: (DrawOutcome) -> Void
    private var toolButtons: [NSButton] = []

    init(document: EditorDocument, completion: @escaping (DrawOutcome) -> Void) {
        self.completion = completion
        canvas = DrawCanvasView(background: document.background,
                                annotations: document.annotations,
                                stepCounter: document.stepCounter)

        let scroll = NSScrollView()
        scroll.contentView = CenteringClipView()
        scroll.documentView = canvas
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 28, left: 24, bottom: 24, right: 24)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 16
        scroll.backgroundColor = NSColor(srgbRed: 200 / 255, green: 200 / 255,
                                         blue: 200 / 255, alpha: 1)

        // Tool buttons for the LEFT vertical 2-column panel (assembled into a
        // grid at the end of init) — mirrors the original TTextBoard layout.
        // Select tool first, then every object tool.
        func makeTool(_ symbolName: String, _ id: String, _ tip: String) -> NSButton {
            let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: tip)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
            let b = NSButton(image: img ?? NSImage(), target: self, action: #selector(toolSelected(_:)))
            b.bezelStyle = .texturedRounded
            b.setButtonType(.toggle)
            b.toolTip = tip
            b.identifier = NSUserInterfaceItemIdentifier(id)
            b.widthAnchor.constraint(equalToConstant: 32).isActive = true
            b.heightAnchor.constraint(equalToConstant: 28).isActive = true
            return b
        }
        let selectBtn = makeTool("cursorarrow", "select", Loc.t("选择 / 移动", "Select / Move"))
        selectBtn.state = .on
        toolButtons.append(selectBtn)
        for type in AnnotationType.allCases {
            toolButtons.append(makeTool(type.symbolName, type.rawValue, type.label))
        }

        // Properties strip
        let strokeWell = NSColorWell(style: .minimal)
        strokeWell.color = .systemRed
        strokeWell.target = self
        strokeWell.action = #selector(strokeChanged(_:))
        strokeWell.toolTip = Loc.t("边框/文字颜色", "Border / Text Color")
        strokeWell.widthAnchor.constraint(equalToConstant: 34).isActive = true

        let widthPopup = NSPopUpButton()
        for w in Self.widthChoices { widthPopup.addItem(withTitle: "\(w) px") }
        widthPopup.selectItem(at: 3)  // 3 px
        widthPopup.target = self
        widthPopup.action = #selector(widthChanged(_:))
        widthPopup.toolTip = Loc.t("线宽 / 边框宽度 (0 = 无框)", "Line / border width (0 = none)")

        let fontPopup = NSPopUpButton()
        for s in [14, 18, 24, 32, 48, 64] { fontPopup.addItem(withTitle: "\(s) pt") }
        fontPopup.selectItem(at: 2)
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged(_:))
        fontPopup.toolTip = Loc.t("字号", "Font Size")

        let shadowCheck = NSButton(checkboxWithTitle: Loc.t("阴影", "Shadow"), target: self, action: #selector(shadowChanged(_:)))
        shadowCheck.state = .on

        // Fill / background (text boxes: background checkbox+color; shapes: fill).
        let fillCheck = NSButton(checkboxWithTitle: Loc.t("填充/背景", "Fill / Background"), target: self, action: #selector(fillChanged(_:)))
        let fillWell = NSColorWell(style: .minimal)
        fillWell.color = .white
        fillWell.target = self
        fillWell.action = #selector(fillColorChanged(_:))
        fillWell.toolTip = Loc.t("填充 / 背景颜色", "Fill / Background Color")
        fillWell.widthAnchor.constraint(equalToConstant: 34).isActive = true
        self.fillWell = fillWell
        self.fillCheck = fillCheck

        // Per-object opacity (0 = 不透明 … 100 = 全透明), spec §5/§9.
        let opacityLabel = NSTextField(labelWithString: Loc.t("透明", "Transp."))
        opacityLabel.font = .systemFont(ofSize: 11)
        let opacitySlider = NSSlider(value: 0, minValue: 0, maxValue: 100,
                                     target: self, action: #selector(opacityChanged(_:)))
        opacitySlider.isContinuous = true
        opacitySlider.toolTip = Loc.t("不透明度 0–100", "Transparency 0–100")
        opacitySlider.widthAnchor.constraint(equalToConstant: 70).isActive = true
        self.opacitySlider = opacitySlider

        // Red × delete (spec §2, BntDelete).
        let deleteBtn = NSButton(image: symbol("xmark", weight: .bold) ?? NSImage(),
                                 target: self, action: #selector(deleteSelected(_:)))
        deleteBtn.bezelStyle = .texturedRounded
        deleteBtn.contentTintColor = .systemRed
        deleteBtn.toolTip = Loc.t("删除选中对象 (⌫)", "Delete selected object (⌫)")

        // Independent Draw Undo / Redo (spec §1).
        let undoBtn = NSButton(image: symbol("arrow.uturn.backward") ?? NSImage(),
                               target: self, action: #selector(undoTapped(_:)))
        undoBtn.bezelStyle = .texturedRounded
        undoBtn.toolTip = Loc.t("撤销 (⌘Z)", "Undo (⌘Z)")
        let redoBtn = NSButton(image: symbol("arrow.uturn.forward") ?? NSImage(),
                               target: self, action: #selector(redoTapped(_:)))
        redoBtn.bezelStyle = .texturedRounded
        redoBtn.toolTip = Loc.t("重做 (⌘⇧Z)", "Redo (⌘⇧Z)")
        self.undoBtn = undoBtn
        self.redoBtn = redoBtn

        // Endpoint style dropdown — the 10 presets (spec §4.1).
        let endpointPopup = NSPopUpButton()
        for title in Self.endpointTitles { endpointPopup.addItem(withTitle: title) }
        endpointPopup.target = self
        endpointPopup.action = #selector(endpointChanged(_:))
        endpointPopup.toolTip = Loc.t("端点样式（起点/终点）", "Endpoint style (start / end)")
        self.endpointPopup = endpointPopup

        let dashCheck = NSButton(checkboxWithTitle: Loc.t("虚线", "Dashed"), target: self, action: #selector(dashChanged(_:)))
        self.dashCheck = dashCheck

        let endSizePopup = NSPopUpButton()
        for n in 1...10 { endSizePopup.addItem(withTitle: Loc.t("端点\(n)", "End \(n)")) }
        endSizePopup.selectItem(at: 4)   // default 5
        endSizePopup.target = self
        endSizePopup.action = #selector(endSizeChanged(_:))
        endSizePopup.toolTip = Loc.t("端点尺寸 1–10", "Endpoint size 1–10")
        self.endSizePopup = endSizePopup

        let outlinePopup = NSPopUpButton()
        for w in Self.outlineChoices { outlinePopup.addItem(withTitle: Loc.t("描边\(w)", "Outline \(w)")) }
        outlinePopup.target = self
        outlinePopup.action = #selector(outlineChanged(_:))
        outlinePopup.toolTip = Loc.t("轮廓宽度 0–10", "Outline width 0–10")
        self.outlinePopup = outlinePopup

        let outlineWell = NSColorWell(style: .minimal)
        outlineWell.color = .black
        outlineWell.target = self
        outlineWell.action = #selector(outlineColorChanged(_:))
        outlineWell.toolTip = Loc.t("轮廓颜色", "Outline Color")
        outlineWell.widthAnchor.constraint(equalToConstant: 34).isActive = true
        self.outlineWell = outlineWell

        let bracketPopup = NSPopUpButton()
        for title in [Loc.t("{ 左花括", "{ Left Brace"), Loc.t("} 右花括", "} Right Brace"),
                      Loc.t("[ 左方括", "[ Left Bracket"), Loc.t("] 右方括", "] Right Bracket"),
                      Loc.t("( 左圆括", "( Left Paren"), Loc.t(") 右圆括", ") Right Paren"),
                      Loc.t("⏞ 上括", "⏞ Top Brace"), Loc.t("⏟ 下括", "⏟ Bottom Brace")] {
            bracketPopup.addItem(withTitle: title)
        }
        bracketPopup.target = self
        bracketPopup.action = #selector(bracketChanged(_:))
        bracketPopup.toolTip = Loc.t("括号形状（8 种）", "Bracket shape (8 kinds)")
        self.bracketPopup = bracketPopup

        let magnifierPopup = NSPopUpButton()
        for title in ["150%", "200%", "250%"] { magnifierPopup.addItem(withTitle: title) }
        magnifierPopup.selectItem(at: 1)   // default 200%
        magnifierPopup.target = self
        magnifierPopup.action = #selector(magnifierChanged(_:))
        magnifierPopup.toolTip = Loc.t("放大倍数", "Zoom Factor")
        self.magnifierPopup = magnifierPopup

        let highlightPopup = NSPopUpButton()
        for title in [Loc.t("矩形", "Rectangle"), Loc.t("圆角", "Rounded"), Loc.t("椭圆", "Ellipse")] { highlightPopup.addItem(withTitle: title) }
        highlightPopup.target = self
        highlightPopup.action = #selector(highlightChanged(_:))
        highlightPopup.toolTip = Loc.t("荧光笔形状", "Highlighter shape")
        self.highlightPopup = highlightPopup

        let smoothCheck = NSButton(checkboxWithTitle: Loc.t("平滑", "Smooth"), target: self, action: #selector(smoothChanged(_:)))
        self.smoothCheck = smoothCheck
        let closedCheck = NSButton(checkboxWithTitle: Loc.t("闭合", "Closed"), target: self, action: #selector(closedChanged(_:)))
        self.closedCheck = closedCheck
        let letterCheck = NSButton(checkboxWithTitle: Loc.t("字母", "Letters"), target: self, action: #selector(letterChanged(_:)))
        letterCheck.toolTip = Loc.t("序号用字母 A B C…（spec §5 #18）", "Number with letters A B C…")
        self.letterCheck = letterCheck
        let pointerRightCheck = NSButton(checkboxWithTitle: Loc.t("右键", "Right"), target: self, action: #selector(pointerRightChanged(_:)))
        pointerRightCheck.toolTip = Loc.t("鼠标指针右键变体", "Right-click pointer variant")
        self.pointerRightCheck = pointerRightCheck

        // ===== Left vertical tool panel — 2 columns + undo/redo/delete =====
        for b in [undoBtn, redoBtn, deleteBtn] {
            b.widthAnchor.constraint(equalToConstant: 32).isActive = true
            b.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        let toolGrid = NSGridView(numberOfColumns: 2, rows: 0)
        toolGrid.rowSpacing = 2
        toolGrid.columnSpacing = 2
        var ti = 0
        while ti < toolButtons.count {
            let a: NSView = toolButtons[ti]
            let b: NSView = ti + 1 < toolButtons.count ? toolButtons[ti + 1] : NSView()
            toolGrid.addRow(with: [a, b])
            ti += 2
        }
        let editGrid = NSGridView(numberOfColumns: 2, rows: 0)
        editGrid.rowSpacing = 2
        editGrid.columnSpacing = 2
        editGrid.addRow(with: [undoBtn, redoBtn])
        editGrid.addRow(with: [deleteBtn, NSView()])

        let leftStack = NSStackView(views: [toolGrid, hSeparator(), editGrid])
        leftStack.orientation = .vertical
        leftStack.spacing = 6
        leftStack.alignment = .centerX
        leftStack.edgeInsets = NSEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        // Flipped document so a short tool list pins to the TOP (not the bottom).
        let leftDoc = FlippedView()
        leftDoc.translatesAutoresizingMaskIntoConstraints = false
        leftDoc.addSubview(leftStack)
        let leftClip = NSScrollView()
        leftClip.drawsBackground = false
        leftClip.hasVerticalScroller = true
        leftClip.documentView = leftDoc
        NSLayoutConstraint.activate([
            leftDoc.topAnchor.constraint(equalTo: leftClip.contentView.topAnchor),
            leftDoc.leadingAnchor.constraint(equalTo: leftClip.contentView.leadingAnchor),
            leftDoc.trailingAnchor.constraint(equalTo: leftClip.contentView.trailingAnchor),
            leftStack.topAnchor.constraint(equalTo: leftDoc.topAnchor),
            leftStack.leadingAnchor.constraint(equalTo: leftDoc.leadingAnchor),
            leftStack.trailingAnchor.constraint(equalTo: leftDoc.trailingAnchor),
            leftStack.bottomAnchor.constraint(equalTo: leftDoc.bottomAnchor),
        ])
        leftClip.widthAnchor.constraint(equalToConstant: 92).isActive = true

        // ===== Bottom property strip — contextual, horizontally scrollable so
        // the window can shrink freely (hidden controls collapse out) =====
        let propStack = NSStackView(views: [strokeWell, widthPopup, fontPopup, shadowCheck,
                                            fillCheck, fillWell, endpointPopup, dashCheck, endSizePopup,
                                            outlinePopup, outlineWell, bracketPopup, magnifierPopup,
                                            highlightPopup, smoothCheck, closedCheck, letterCheck,
                                            pointerRightCheck, opacityLabel, opacitySlider])
        propStack.orientation = .horizontal
        propStack.spacing = 6
        propStack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        propStack.translatesAutoresizingMaskIntoConstraints = false
        let propClip = NSScrollView()
        propClip.drawsBackground = false
        propClip.hasHorizontalScroller = true
        propClip.hasVerticalScroller = false
        propClip.documentView = propStack
        NSLayoutConstraint.activate([
            propStack.leadingAnchor.constraint(equalTo: propClip.contentView.leadingAnchor),
            propStack.topAnchor.constraint(equalTo: propClip.contentView.topAnchor),
            propStack.bottomAnchor.constraint(equalTo: propClip.contentView.bottomAnchor),
        ])
        propClip.heightAnchor.constraint(equalToConstant: 40).isActive = true

        // ===== Save / OK / Cancel — always visible, bottom-right =====
        let saveBtn = NSButton(title: Loc.t("保存", "Save"), target: self, action: #selector(saveTapped(_:)))
        let okBtn = NSButton(title: "OK", target: self, action: #selector(okTapped(_:)))
        okBtn.keyEquivalent = "\r"
        let cancelBtn = NSButton(title: Loc.t("取消", "Cancel"), target: self, action: #selector(cancelTapped(_:)))
        let actionRow = NSStackView(views: [NSView(), saveBtn, okBtn, cancelBtn])
        actionRow.orientation = .horizontal
        actionRow.spacing = 8
        actionRow.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 6, right: 10)

        refreshContext(for: nil)   // hide contextual controls until a tool/object is active

        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        let rightStack = NSStackView(views: [scroll, propClip, actionRow])
        rightStack.orientation = .vertical
        rightStack.spacing = 0
        rightStack.distribution = .fill
        rightStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let root = NSStackView(views: [leftClip, rightStack])
        root.orientation = .horizontal
        root.spacing = 0
        root.distribution = .fill
        rootView = root

        canvas.onSelectionChanged = { [weak self] a in
            self?.syncProperties(from: a)
            self?.refreshContext(for: a?.type ?? self?.canvas.currentTool)
        }
        canvas.onUndoStateChanged = { [weak self] in self?.updateUndoButtons() }
        canvas.onCancelRequested = { [weak self] in self?.requestCancel() }
        canvas.onRequestSelectTool = { [weak self] in self?.selectPointerTool() }
        self.strokeWell = strokeWell
        self.widthPopup = widthPopup
        self.fontPopup = fontPopup
        self.shadowCheck = shadowCheck
        updateUndoButtons()
    }

    static let widthChoices = [0, 1, 2, 3, 5, 8, 12]

    /// Titles for the 10 endpoint presets (spec §4.1), aligned to `Annotation.endpointPresets`.
    static var endpointTitles: [String] {
        [
            Loc.t("—— 无端点", "—— None"), Loc.t("——▷ 细箭头", "——▷ Thin Arrow"),
            Loc.t("•——▷ 点+细箭头", "•——▷ Dot + Thin Arrow"), Loc.t("——▶ 粗箭头", "——▶ Thick Arrow"),
            Loc.t("•——▶ 点+粗箭头", "•——▶ Dot + Thick Arrow"), Loc.t("——• 终点圆点", "——• End Dot"),
            Loc.t("•—— 起点圆点", "•—— Start Dot"), Loc.t("•——• 两端圆点", "•——• Both Dots"),
            Loc.t("◁——▷ 双向细", "◁——▷ Two-Way Thin"), Loc.t("◀——▶ 双向粗", "◀——▶ Two-Way Thick"),
        ]
    }

    private weak var strokeWell: NSColorWell?
    private weak var fillWell: NSColorWell?
    private weak var fillCheck: NSButton?
    private weak var widthPopup: NSPopUpButton?
    private weak var fontPopup: NSPopUpButton?
    private weak var shadowCheck: NSButton?
    private weak var opacitySlider: NSSlider?
    private weak var undoBtn: NSButton?
    private weak var redoBtn: NSButton?

    // Contextual controls (spec §4/§5) — shown per active tool / selection.
    private weak var endpointPopup: NSPopUpButton?
    private weak var dashCheck: NSButton?
    private weak var endSizePopup: NSPopUpButton?
    private weak var outlinePopup: NSPopUpButton?
    private weak var outlineWell: NSColorWell?
    private weak var bracketPopup: NSPopUpButton?
    private weak var magnifierPopup: NSPopUpButton?
    private weak var highlightPopup: NSPopUpButton?
    private weak var smoothCheck: NSButton?
    private weak var closedCheck: NSButton?
    private weak var letterCheck: NSButton?
    private weak var pointerRightCheck: NSButton?

    static let outlineChoices = [0, 1, 2, 3, 4, 6, 8, 10]

    private func symbol(_ name: String, weight: NSFont.Weight = .medium) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: weight))
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 8).isActive = true
        return box
    }

    /// Horizontal separator for the vertical left tool panel.
    private func hSeparator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.heightAnchor.constraint(equalToConstant: 8).isActive = true
        return box
    }

    private func updateUndoButtons() {
        undoBtn?.isEnabled = canvas.canUndo
        redoBtn?.isEnabled = canvas.canRedo
    }

    // MARK: tool + property plumbing

    /// Reset the tool strip to the pointer/select tool (after a text commit).
    private func selectPointerTool() {
        for b in toolButtons { b.state = b.identifier?.rawValue == "select" ? .on : .off }
        canvas.currentTool = nil
        refreshContext(for: nil)
    }

    @objc private func toolSelected(_ sender: NSButton) {
        canvas.endTextEditing()   // switching tools commits any open text editor
        for b in toolButtons { b.state = b === sender ? .on : .off }
        let id = sender.identifier?.rawValue ?? "select"
        let tool = id == "select" ? nil : AnnotationType(rawValue: id)
        // Reflect each tool's own endpoint default so the dropdown is meaningful.
        if let tool {
            switch tool {
            case .arrow: canvas.defaults.startCap = .none; canvas.defaults.endCap = .thickArrow
            case .line, .lline, .polyline, .fancyLine: canvas.defaults.startCap = .none; canvas.defaults.endCap = .none
            default: break
            }
        }
        canvas.currentTool = tool
        // Picking a creation tool: reflect the tool's own defaults in the strip.
        if tool != nil { syncProperties(from: canvas.defaults) }
        refreshContext(for: tool)
    }

    /// Bidirectional property strip: selecting an object (or a creation tool)
    /// mirrors its properties here; editing a control applies live (see handlers).
    private func syncProperties(from a: Annotation?) {
        guard let a else { return }
        strokeWell?.color = a.strokeColor
        // Text boxes expose background; shapes expose fill; both map to these wells.
        if a.textBoxShape != .none || a.type == .mousePointer {
            fillCheck?.state = a.hasBackground ? .on : .off
            fillWell?.color = a.backgroundColor
        } else if let fill = a.fillColor {
            fillCheck?.state = .on
            fillWell?.color = fill
        } else {
            fillCheck?.state = .off
        }
        if let i = Self.widthChoices.firstIndex(of: Int(a.lineWidth.rounded())) {
            widthPopup?.selectItem(at: i)
        }
        shadowCheck?.state = a.shadow ? .on : .off
        opacitySlider?.doubleValue = Double(a.opacity)

        // Contextual controls (spec §4/§5).
        endpointPopup?.selectItem(at: endpointPresetIndex(start: a.startCap, end: a.endCap))
        dashCheck?.state = a.dashed ? .on : .off
        endSizePopup?.selectItem(at: min(max(Int(a.endpointSize.rounded()) - 1, 0), 9))
        if let i = Self.outlineChoices.firstIndex(of: Int(a.outlineWidth.rounded())) { outlinePopup?.selectItem(at: i) }
        outlineWell?.color = a.outlineColor
        bracketPopup?.selectItem(at: min(max(a.bracketShape, 0), 7))
        magnifierPopup?.selectItem(at: [1.5, 2.0, 2.5].firstIndex(of: a.magnifyZoom) ?? 1)
        highlightPopup?.selectItem(at: min(max(a.highlightShape, 0), 2))
        smoothCheck?.state = a.smooth ? .on : .off
        closedCheck?.state = a.closed ? .on : .off
        letterCheck?.state = a.stepLetter ? .on : .off
        pointerRightCheck?.state = a.pointerRight ? .on : .off
    }

    /// Reverse lookup: which of the 10 endpoint presets matches these caps.
    private func endpointPresetIndex(start: LineCap, end: LineCap) -> Int {
        Annotation.endpointPresets.firstIndex { $0.0 == start && $0.1 == end } ?? 0
    }

    /// Shows/hides the contextual controls based on the active tool / selection.
    private func refreshContext(for type: AnnotationType?) {
        let isLine = type?.isLineFamily ?? false
        let isBracket = type == .bracket
        endpointPopup?.isHidden = !isLine
        dashCheck?.isHidden = !(isLine || isBracket)
        endSizePopup?.isHidden = !isLine
        outlinePopup?.isHidden = !(isLine || isBracket)
        outlineWell?.isHidden = !(isLine || isBracket)
        bracketPopup?.isHidden = !isBracket
        magnifierPopup?.isHidden = type != .magnifier
        highlightPopup?.isHidden = type != .highlighter
        // Smooth applies to polyline/polygon/fancy line/pencil; closed to polyline/polygon.
        let smoothable: Set<AnnotationType> = [.polyline, .polygon, .fancyLine, .freehand]
        smoothCheck?.isHidden = !(type.map(smoothable.contains) ?? false)
        closedCheck?.isHidden = !(type == .polyline || type == .polygon)
        letterCheck?.isHidden = type != .step
        pointerRightCheck?.isHidden = type != .mousePointer
        // Endpoint dropdown offers arrow presets only for true line family.
        endpointPopup?.isEnabled = isLine
    }

    /// True when the current selection is a rect/oval text box.
    private var selectionIsTextBox: Bool { canvas.selectedTextBoxShape.map { $0 != .none } ?? false }

    /// Objects that use the `hasBackground` flag rather than `fillHex`: text
    /// boxes (background) and the mouse pointer (highlight, spec §5 #17).
    private var selectionUsesBackground: Bool {
        selectionIsTextBox || canvas.selectionType == .mousePointer
    }

    @objc private func strokeChanged(_ sender: NSColorWell) {
        canvas.updateStyle { $0.strokeHex = sender.color.hexString }
        canvas.defaults.strokeHex = sender.color.hexString
    }

    @objc private func fillChanged(_ sender: NSButton) {
        let on = sender.state == .on
        let color = (fillWell?.color ?? .white)
        if selectionUsesBackground {
            canvas.updateStyle { $0.hasBackground = on; $0.backgroundHex = color.hexString }
        } else {
            canvas.updateStyle { $0.fillHex = on ? color.hexString : nil }
        }
        canvas.defaults.fillHex = on ? color.hexString : nil
        canvas.defaults.hasBackground = on
        canvas.defaults.backgroundHex = color.hexString
    }

    @objc private func fillColorChanged(_ sender: NSColorWell) {
        guard fillCheck?.state == .on else { return }
        if selectionUsesBackground {
            canvas.updateStyle { $0.backgroundHex = sender.color.hexString }
        } else {
            canvas.updateStyle { $0.fillHex = sender.color.hexString }
        }
        canvas.defaults.fillHex = sender.color.hexString
        canvas.defaults.backgroundHex = sender.color.hexString
    }

    @objc private func widthChanged(_ sender: NSPopUpButton) {
        let w = CGFloat(Self.widthChoices[max(0, sender.indexOfSelectedItem)])
        canvas.updateStyle { $0.lineWidth = w }
        canvas.defaults.lineWidth = w
    }

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        let s: CGFloat = [14, 18, 24, 32, 48, 64].map(CGFloat.init)[max(0, sender.indexOfSelectedItem)]
        canvas.updateStyle { $0.fontSize = s }
        canvas.defaults.fontSize = s
    }

    @objc private func shadowChanged(_ sender: NSButton) {
        canvas.updateStyle { $0.shadow = sender.state == .on }
        canvas.defaults.shadow = sender.state == .on
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        // Coalesce the continuous drag into a single undo step.
        canvas.updateStyle(coalesce: true) { $0.opacity = sender.integerValue }
        canvas.defaults.opacity = sender.integerValue
    }

    @objc private func endpointChanged(_ sender: NSPopUpButton) {
        let (s, e) = Annotation.endpointPresets[max(0, min(sender.indexOfSelectedItem, 9))]
        canvas.updateStyle { $0.startCap = s; $0.endCap = e }
        canvas.defaults.startCap = s
        canvas.defaults.endCap = e
    }

    @objc private func dashChanged(_ sender: NSButton) {
        canvas.updateStyle { $0.dashed = sender.state == .on }
        canvas.defaults.dashed = sender.state == .on
    }

    @objc private func endSizeChanged(_ sender: NSPopUpButton) {
        let v = CGFloat(sender.indexOfSelectedItem + 1)
        canvas.updateStyle { $0.endpointSize = v }
        canvas.defaults.endpointSize = v
    }

    @objc private func outlineChanged(_ sender: NSPopUpButton) {
        let w = CGFloat(Self.outlineChoices[max(0, sender.indexOfSelectedItem)])
        canvas.updateStyle { $0.outlineWidth = w }
        canvas.defaults.outlineWidth = w
    }

    @objc private func outlineColorChanged(_ sender: NSColorWell) {
        canvas.updateStyle { $0.outlineHex = sender.color.hexString }
        canvas.defaults.outlineHex = sender.color.hexString
    }

    @objc private func bracketChanged(_ sender: NSPopUpButton) {
        let i = max(0, sender.indexOfSelectedItem)
        canvas.updateStyle { $0.bracketShape = i }
        canvas.defaults.bracketShape = i
    }

    @objc private func magnifierChanged(_ sender: NSPopUpButton) {
        let z: CGFloat = [1.5, 2.0, 2.5][max(0, min(sender.indexOfSelectedItem, 2))]
        canvas.updateStyle { $0.magnifyZoom = z }
        canvas.defaults.magnifyZoom = z
    }

    @objc private func highlightChanged(_ sender: NSPopUpButton) {
        let i = max(0, sender.indexOfSelectedItem)
        canvas.updateStyle { $0.highlightShape = i }
        canvas.defaults.highlightShape = i
    }

    @objc private func smoothChanged(_ sender: NSButton) {
        canvas.updateStyle { $0.smooth = sender.state == .on }
        canvas.defaults.smooth = sender.state == .on
    }

    @objc private func closedChanged(_ sender: NSButton) {
        canvas.updateStyle { $0.closed = sender.state == .on }
        canvas.defaults.closed = sender.state == .on
    }

    @objc private func letterChanged(_ sender: NSButton) {
        canvas.updateStyle { $0.stepLetter = sender.state == .on }
        canvas.defaults.stepLetter = sender.state == .on
    }

    @objc private func pointerRightChanged(_ sender: NSButton) {
        canvas.updateStyle { $0.pointerRight = sender.state == .on }
        canvas.defaults.pointerRight = sender.state == .on
    }

    @objc private func undoTapped(_ sender: Any?) { canvas.undo() }
    @objc private func redoTapped(_ sender: Any?) { canvas.redo() }

    @objc private func deleteSelected(_ sender: Any?) { canvas.deleteSelection() }

    // MARK: Save / OK / Cancel

    @objc private func saveTapped(_ sender: Any?) {
        canvas.endTextEditing()
        completion(.save(canvas.annotations, canvas.stepCounter))
    }

    @objc private func okTapped(_ sender: Any?) {
        canvas.endTextEditing()
        completion(.ok(canvas.annotations, canvas.stepCounter))
    }

    @objc private func cancelTapped(_ sender: Any?) { requestCancel() }

    func requestCancel() {
        canvas.endTextEditing()
        completion(.cancel)
    }
}

// MARK: - Draw canvas

@MainActor
final class DrawCanvasView: NSView {
    private let backgroundImage: CGImage
    private let backgroundNSImage: NSImage
    private(set) var annotations: [Annotation]
    var stepCounter: Int

    var currentTool: AnnotationType? {   // nil = select tool
        didSet { if oldValue != currentTool { cancelPolyBuild() } }
    }
    var defaults = Annotation(type: .rect)
    var onSelectionChanged: ((Annotation?) -> Void)?
    var onUndoStateChanged: (() -> Void)?
    var onCancelRequested: (() -> Void)?     // Esc = discard Draw (spec §10)
    var onRequestSelectTool: (() -> Void)?   // after text commit → pointer tool

    /// In-app clipboard for annotation objects (⌘C/⌘X/⌘V in Draw).
    private static var objectClipboard: Annotation?

    private var selectedID: UUID?
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private var coalescingUndo = false       // true while a slider drag is in flight

    /// Shape of the current selection if it is a text object, else nil.
    var selectedTextBoxShape: TextBoxShape? { selected.map(\.textBoxShape) }

    /// Type of the current selection (for the property strip's context switch).
    var selectionType: AnnotationType? { selected?.type }

    private enum DragMode {
        case none
        case creating
        case moving(CGPoint)                   // last point
        case resizing(handle: Int, original: Annotation)
        case movingTail
    }
    private var dragMode: DragMode = .none
    private var draft: Annotation?
    private var moveUndoSnapshot: [Annotation]?   // pending move/resize step
    private var buildingPoly = false              // polyline/polygon vertex build in flight

    // Floating multiline text editor (spec §3.2): Enter = newline,
    // ⌘/Ctrl+Enter = commit & close. Decoupled from canvas clicks.
    private var textEditor: DrawTextView?
    private var textEditorScroll: NSScrollView?
    private var editingID: UUID?
    private var editingIsNew = false
    private var editingUndoSnapshot: [Annotation]?

    init(background: CGImage, annotations: [Annotation], stepCounter: Int) {
        self.backgroundImage = background
        self.backgroundNSImage = NSImage(cgImage: background,
                                         size: CGSize(width: background.width, height: background.height))
        self.annotations = annotations
        self.stepCounter = stepCounter
        super.init(frame: CGRect(x: 0, y: 0, width: background.width, height: background.height))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var selected: Annotation? {
        annotations.first { $0.id == selectedID }
    }

    private func setSelected(_ id: UUID?) {
        selectedID = id
        onSelectionChanged?(selected)
        needsDisplay = true
    }

    // MARK: undo (independent Draw stack, spec §1)

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private func recordUndo(_ snapshot: [Annotation]) {
        undoStack.append(snapshot)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        onUndoStateChanged?()
    }

    /// Snapshot the CURRENT state as one undo step (call BEFORE mutating).
    func pushUndo() { recordUndo(annotations) }

    func undo() {
        endTextEditing()
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = prev
        if selected == nil { setSelected(nil) } else { onSelectionChanged?(selected) }
        onUndoStateChanged?()
        needsDisplay = true
    }

    func redo() {
        endTextEditing()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        onSelectionChanged?(selected)
        onUndoStateChanged?()
        needsDisplay = true
    }

    // MARK: style updates from the properties strip

    /// Apply a live property change to the selected object, one undo step.
    /// `coalesce` merges a continuous drag (e.g. opacity slider) into a single
    /// step: the first call snapshots, subsequent calls mutate in place.
    func updateStyle(coalesce: Bool = false, _ mutate: (inout Annotation) -> Void) {
        guard let id = selectedID, let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        if coalesce {
            if !coalescingUndo { pushUndo(); coalescingUndo = true }
        } else {
            pushUndo()
        }
        mutate(&annotations[idx])
        needsDisplay = true
    }

    /// End a coalesced run (called on mouseUp anywhere).
    private func endCoalescing() { coalescingUndo = false }

    func deleteSelection() {
        guard let id = selectedID else { return }
        endTextEditing()
        pushUndo()
        annotations.removeAll { $0.id == id }
        setSelected(nil)
    }

    // MARK: object copy / cut / paste (⌘C / ⌘X / ⌘V, spec §2)

    func copySelectedObject() {
        if let a = selected { DrawCanvasView.objectClipboard = a }
    }

    func cutSelectedObject() {
        guard let a = selected else { return }
        DrawCanvasView.objectClipboard = a
        deleteSelection()
    }

    /// Paste a clone (new id, offset +16,+16) on top; it becomes the selection.
    func pasteObject() {
        guard var a = DrawCanvasView.objectClipboard else { return }
        endTextEditing()
        a.id = UUID()
        a.move(by: CGPoint(x: 16, y: 16))
        a.z = (annotations.map(\.z).max() ?? 0) + 1
        pushUndo()
        annotations.append(a)
        setSelected(a.id)
        needsDisplay = true
    }

    func selectLastObject() {
        setSelected(annotations.max(by: { $0.z < $1.z })?.id)
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        backgroundNSImage.draw(in: CGRect(origin: .zero, size: frame.size))
        AnnotationRenderer.render(annotations, background: backgroundImage)
        if let draft {
            AnnotationRenderer.render(draft, background: backgroundImage)
        }
        if let sel = selected {
            drawSelectionChrome(for: sel)
        }
    }

    private func drawSelectionChrome(for a: Annotation) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: a.selectionBounds)
        outline.setLineDash([4, 3], count: 2, phase: 0)
        outline.lineWidth = 1
        outline.stroke()
        for h in handles(for: a) {
            NSColor.white.setFill()
            NSColor.controlAccentColor.setStroke()
            let r = NSBezierPath(ovalIn: CGRect(x: h.x - 4, y: h.y - 4, width: 8, height: 8))
            r.fill()
            r.stroke()
        }
    }

    /// Handle positions. Boxes: 8 (corners + edges, indices 0-7). Lines: 2
    /// endpoints (indices 0-1). Callout: extra tail handle at last index.
    private func handles(for a: Annotation) -> [CGPoint] {
        switch a.type {
        case .line, .arrow, .lline, .fancyLine:
            return Array(a.points.prefix(2))
        case .polyline, .polygon:
            return a.points
        case .freehand, .marker, .eraser:
            return []
        case .callout:
            let b = a.bounds
            var pts = boxHandles(b)
            if let tail = a.points.first { pts.append(tail) }
            return pts
        default:
            return boxHandles(a.bounds)
        }
    }

    private func boxHandles(_ b: CGRect) -> [CGPoint] {
        [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.midX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
         CGPoint(x: b.maxX, y: b.midY), CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.midX, y: b.maxY),
         CGPoint(x: b.minX, y: b.maxY), CGPoint(x: b.minX, y: b.midY)]
    }

    // MARK: hit testing

    private func hitAnnotation(at p: CGPoint) -> Annotation? {
        for a in annotations.sorted(by: { $0.z > $1.z }) {
            if a.selectionBounds.insetBy(dx: -4, dy: -4).contains(p) { return a }
        }
        return nil
    }

    private func hitHandle(at p: CGPoint, of a: Annotation) -> Int? {
        for (i, h) in handles(for: a).enumerated() {
            if abs(h.x - p.x) <= 6, abs(h.y - p.y) <= 6 { return i }
        }
        return nil
    }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        // A click on the canvas OUTSIDE the text editor commits the current text
        // (Mac-native click-away confirm — user preference), then is consumed.
        // Clicks INSIDE the editor go to the NSTextView, never here.
        if textEditor != nil {
            endTextEditing(resetTool: true)   // click-away commits → pointer tool
            return
        }
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)

        // Double-click a text object → re-open the editor with its content (§3.4).
        if event.clickCount == 2, let hit = hitAnnotation(at: p), hit.isTextual {
            setSelected(hit.id)
            openTextEditor(for: hit.id, isNew: false, snapshot: annotations)
            return
        }

        if let tool = currentTool {
            if tool.isMultiClick {
                handlePolyClick(tool, at: p, clickCount: event.clickCount)  // §4.2 折线/多边形
            } else if tool.isTextTool {
                placeTextObject(tool, at: p)   // single click places + opens editor (§3.2)
            } else {
                beginCreate(tool: tool, at: p)
            }
            return
        }

        // Pointer / select tool (spec §2).
        if let sel = selected, let handle = hitHandle(at: p, of: sel) {
            let isTail = sel.type == .callout && handle == handles(for: sel).count - 1 && !sel.points.isEmpty
            moveUndoSnapshot = annotations
            dragMode = isTail ? .movingTail : .resizing(handle: handle, original: sel)
            return
        }
        if let hit = hitAnnotation(at: p) {
            setSelected(hit.id)
            moveUndoSnapshot = annotations
            dragMode = .moving(p)
        } else {
            setSelected(nil)   // clicking empty deselects, never creates (spec §2)
            dragMode = .none
        }
    }

    /// Single-click placement of a text object, immediately opening the editor.
    private func placeTextObject(_ tool: AnnotationType, at p: CGPoint) {
        var a = Annotation(type: tool)
        a.strokeHex = defaults.strokeHex
        a.fontSize = defaults.fontSize
        a.shadow = defaults.shadow
        a.opacity = defaults.opacity
        a.z = (annotations.map(\.z).max() ?? 0) + 1
        switch tool {
        case .textRect:
            a.textBoxShape = .rect
            a.lineWidth = 1
            a.hasBackground = defaults.hasBackground
            a.backgroundHex = defaults.backgroundHex
            a.frame = CGRect(x: p.x, y: p.y, width: 160, height: 54)
        case .textOval:
            a.textBoxShape = .oval
            a.lineWidth = 1
            a.hasBackground = defaults.hasBackground
            a.backgroundHex = defaults.backgroundHex
            a.frame = CGRect(x: p.x, y: p.y, width: 176, height: 72)
        default:  // .text — plain, no frame, no background, outline off
            a.textBoxShape = .none
            a.lineWidth = 0
            a.frame = CGRect(x: p.x, y: p.y, width: 140, height: a.fontSize * 1.6)
        }
        let snapshot = annotations   // undo target = state BEFORE placement
        annotations.append(a)
        setSelected(a.id)
        openTextEditor(for: a.id, isNew: true, snapshot: snapshot)
        needsDisplay = true
    }

    private func beginCreate(tool: AnnotationType, at p: CGPoint) {
        var a = makeDraft(tool: tool)
        switch tool {
        case .rect, .ellipse, .blur, .highlighter, .bracket, .magnifier:
            a.fillHex = tool == .rect || tool == .ellipse ? defaults.fillHex : nil
            a.frame = CGRect(origin: p, size: .zero)
        case .callout:
            a.fillHex = defaults.fillHex ?? "#FFFFFFD9"
            a.frame = CGRect(origin: p, size: .zero)
            a.points = [CGPoint(x: p.x - 30, y: p.y + 60)]
        case .line, .arrow, .lline, .fancyLine:
            a.points = [p, p]
        case .marker, .freehand, .eraser:
            a.points = [p]
        case .step:
            a.frame = CGRect(x: p.x - 18, y: p.y - 18, width: 36, height: 36)
            a.number = stepCounter
        case .emoji:
            a.frame = CGRect(x: p.x - 28, y: p.y - 28, width: 56, height: 56)
            a.text = "😀"
        case .mousePointer:
            a.frame = CGRect(x: p.x, y: p.y, width: 24, height: 36)  // single-click placed
        case .text, .textRect, .textOval, .polyline, .polygon:
            return  // text = single-click; polyline/polygon = multi-click build
        }
        draft = a
        dragMode = .creating
        needsDisplay = true
    }

    /// A fresh object carrying the current tool defaults (spec §5/§9 common props).
    private func makeDraft(tool: AnnotationType) -> Annotation {
        var a = Annotation(type: tool)
        a.strokeHex = defaults.strokeHex
        a.lineWidth = defaults.lineWidth
        a.fontSize = defaults.fontSize
        a.shadow = defaults.shadow
        a.opacity = defaults.opacity
        a.z = (annotations.map(\.z).max() ?? 0) + 1
        // Line-family common props (spec §4.2).
        a.dashed = defaults.dashed
        a.outlineWidth = defaults.outlineWidth
        a.outlineHex = defaults.outlineHex
        a.endpointSize = defaults.endpointSize
        a.startCap = defaults.startCap
        a.endCap = defaults.endCap
        a.smooth = defaults.smooth
        switch tool {
        case .arrow:
            a.startCap = .none; a.endCap = .thickArrow
        case .highlighter:
            a.shadow = false; a.highlightShape = defaults.highlightShape
        case .marker, .eraser:
            a.shadow = false
        case .bracket:
            a.bracketShape = defaults.bracketShape
        case .magnifier:
            a.magnifyZoom = defaults.magnifyZoom
        case .polygon:
            a.hasBackground = true
            a.backgroundHex = defaults.backgroundHex
            a.closed = true
        case .step:
            a.stepLetter = defaults.stepLetter
            a.stepLowercase = defaults.stepLowercase
        default:
            break
        }
        return a
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch dragMode {
        case .creating:
            guard var a = draft else { return }
            switch a.type {
            case .line, .arrow:
                a.points[1] = p
            case .marker, .freehand:
                a.points.append(p)
            case .step, .emoji:
                a.frame.origin = CGPoint(x: p.x - a.frame.width / 2, y: p.y - a.frame.height / 2)
            case .callout:
                a.frame = CGRect(x: min(a.frame.minX, p.x), y: min(a.frame.minY, p.y),
                                 width: abs(p.x - a.frame.minX), height: abs(p.y - a.frame.minY))
            default:
                let o = a.frame.origin
                a.frame = CGRect(x: o.x, y: o.y, width: p.x - o.x, height: p.y - o.y)
            }
            draft = a
            needsDisplay = true

        case .moving(let last):
            guard let id = selectedID, let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
            annotations[idx].move(by: CGPoint(x: p.x - last.x, y: p.y - last.y))
            dragMode = .moving(p)
            needsDisplay = true

        case .resizing(let handle, let original):
            guard let id = selectedID, let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
            annotations[idx] = resized(original, handle: handle, to: p)
            needsDisplay = true

        case .movingTail:
            guard let id = selectedID, let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
            if annotations[idx].points.isEmpty {
                annotations[idx].points = [p]
            } else {
                annotations[idx].points[0] = p
            }
            needsDisplay = true

        case .none:
            break
        }
    }

    private func resized(_ a: Annotation, handle: Int, to p: CGPoint) -> Annotation {
        var out = a
        switch a.type {
        case .line, .arrow, .lline, .fancyLine, .polyline, .polygon:
            if handle < out.points.count { out.points[handle] = p }
        default:
            var b = a.bounds
            switch handle {
            case 0: b = CGRect(x: p.x, y: p.y, width: b.maxX - p.x, height: b.maxY - p.y)
            case 1: b = CGRect(x: b.minX, y: p.y, width: b.width, height: b.maxY - p.y)
            case 2: b = CGRect(x: b.minX, y: p.y, width: p.x - b.minX, height: b.maxY - p.y)
            case 3: b = CGRect(x: b.minX, y: b.minY, width: p.x - b.minX, height: b.height)
            case 4: b = CGRect(x: b.minX, y: b.minY, width: p.x - b.minX, height: p.y - b.minY)
            case 5: b = CGRect(x: b.minX, y: b.minY, width: b.width, height: p.y - b.minY)
            case 6: b = CGRect(x: p.x, y: b.minY, width: b.maxX - p.x, height: p.y - b.minY)
            case 7: b = CGRect(x: p.x, y: b.minY, width: b.maxX - p.x, height: b.height)
            default: break
            }
            out.frame = b.standardized
        }
        return out
    }

    override func mouseUp(with event: NSEvent) {
        switch dragMode {
        case .creating:
            guard var a = draft else { break }
            draft = nil
            a.frame = a.frame.standardized
            let tooSmall: Bool
            switch a.type {
            case .line, .arrow, .lline, .fancyLine:
                tooSmall = a.points.count < 2 || hypot(a.points[1].x - a.points[0].x,
                                                       a.points[1].y - a.points[0].y) < 4
            case .marker, .freehand, .eraser:
                tooSmall = a.points.count < 2
            case .step, .emoji, .mousePointer:
                tooSmall = false
            case .callout:
                if a.frame.width < 24 { a.frame.size.width = 160 }
                if a.frame.height < 24 { a.frame.size.height = 60 }
                tooSmall = false
            default:
                tooSmall = a.frame.width < 4 || a.frame.height < 4
            }
            if !tooSmall {
                pushUndo()
                if a.type == .step { stepCounter += 1 }
                annotations.append(a)
                setSelected(a.id)
                if a.type == .callout {
                    openTextEditor(for: a.id, isNew: false, snapshot: annotations)
                }
            }
            needsDisplay = true
        case .moving, .resizing, .movingTail:
            // Commit the drag as ONE undo step, only if it actually changed.
            if let snap = moveUndoSnapshot, snap != annotations { recordUndo(snap) }
            moveUndoSnapshot = nil
        default:
            break
        }
        endCoalescing()
        dragMode = .none
    }

    // MARK: multi-click build — polyline / filled polygon (spec §4.2, #16/#25)

    /// Click-to-add-vertex creation. Each single click fixes a vertex; the last
    /// point rubber-bands to the cursor (see `mouseMoved`). A double-click (or
    /// Enter) finishes; Esc cancels.
    private func handlePolyClick(_ tool: AnnotationType, at p: CGPoint, clickCount: Int) {
        if clickCount >= 2 { finishPolyBuild(); return }
        window?.makeFirstResponder(self)
        if !buildingPoly {
            var a = makeDraft(tool: tool)
            a.points = [p, p]           // first vertex + rubber-band point
            draft = a
            buildingPoly = true
        } else {
            draft?.points.append(p)     // the current rubber point becomes committed
        }
        needsDisplay = true
    }

    private func finishPolyBuild() {
        guard buildingPoly, var a = draft else { return }
        buildingPoly = false
        draft = nil
        if !a.points.isEmpty { a.points.removeLast() }   // drop the trailing rubber point
        // Drop duplicate trailing vertices left by the finishing double-click.
        while a.points.count >= 2,
              hypot(a.points[a.points.count - 1].x - a.points[a.points.count - 2].x,
                    a.points[a.points.count - 1].y - a.points[a.points.count - 2].y) < 4 {
            a.points.removeLast()
        }
        let minCount = a.type == .polygon ? 3 : 2
        if a.points.count >= minCount {
            pushUndo()
            annotations.append(a)
            setSelected(a.id)
        }
        needsDisplay = true
    }

    private func cancelPolyBuild() {
        guard buildingPoly else { return }
        buildingPoly = false
        draft = nil
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard buildingPoly, draft != nil, !draft!.points.isEmpty else { return }
        draft!.points[draft!.points.count - 1] = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    // MARK: text editing overlay (spec §3.2 — independent multiline editor)

    private func editorRect(for a: Annotation) -> CGRect {
        if a.type == .text {   // plain text: comfortable editing box
            let w = max(150, a.frame.width)
            let h = max(a.fontSize * 1.9, a.frame.height)
            return CGRect(x: a.frame.minX, y: a.frame.minY, width: w, height: h)
        }
        return a.bounds.insetBy(dx: -1, dy: -1)
    }

    /// Opens the floating multiline editor over an object. `snapshot` is the
    /// state to record for undo when the edit commits with content; `isNew`
    /// means a fresh placement (an empty commit just discards it, no undo entry).
    private func openTextEditor(for id: UUID, isNew: Bool, snapshot: [Annotation]) {
        endTextEditing()
        guard let a = annotations.first(where: { $0.id == id }) else { return }
        let rect = editorRect(for: a)

        let scroll = NSScrollView(frame: rect)
        scroll.borderType = .lineBorder
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = .white

        let tv = DrawTextView(frame: CGRect(origin: .zero, size: rect.size))
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.isRichText = false
        tv.drawsBackground = true
        tv.backgroundColor = .white
        tv.font = .systemFont(ofSize: a.fontSize, weight: .medium)
        tv.textColor = a.type == .text ? a.strokeColor : NSColor(hex: "#222222FF")
        tv.textContainerInset = NSSize(width: 3, height: 2)
        tv.string = a.text
        tv.onCommit = { [weak self] in self?.endTextEditing(resetTool: true) }
        scroll.documentView = tv

        addSubview(scroll)
        textEditor = tv
        textEditorScroll = scroll
        editingID = id
        editingIsNew = isNew
        editingUndoSnapshot = snapshot
        window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: (a.text as NSString).length, length: 0))
    }

    /// Commit & close the editor (⌘/Ctrl+Enter or Esc). Empty text removes the
    /// object. `resetTool` switches back to the pointer tool afterwards (used
    /// when the user finishes text via click-away / ⌘Enter — user request).
    func endTextEditing(resetTool: Bool = false) {
        guard let tv = textEditor, let id = editingID else { return }
        let newText = tv.string
        let snapshot = editingUndoSnapshot
        let wasNew = editingIsNew
        textEditorScroll?.removeFromSuperview()
        textEditor = nil
        textEditorScroll = nil
        editingID = nil
        editingUndoSnapshot = nil
        editingIsNew = false

        guard let idx = annotations.firstIndex(where: { $0.id == id }) else {
            window?.makeFirstResponder(self); needsDisplay = true; return
        }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            annotations.remove(at: idx)
            if !wasNew, let snapshot { recordUndo(snapshot) }
            if selectedID == id { setSelected(nil) }
        } else {
            let changed = annotations[idx].text != newText
            if (changed || wasNew), let snapshot { recordUndo(snapshot) }
            annotations[idx].text = newText
            if annotations[idx].type == .text {
                annotations[idx].frame = fittedFrame(for: annotations[idx])
            }
            setSelected(id)   // stays selected after commit
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
        if resetTool { onRequestSelectTool?() }   // back to pointer (user request)
    }

    /// Auto-size a plain-text object's frame to fit its content.
    private func fittedFrame(for a: Annotation) -> CGRect {
        let font = NSFont.systemFont(ofSize: a.fontSize, weight: .medium)
        let bounding = (a.text as NSString).boundingRect(
            with: CGSize(width: 4000, height: 4000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        let pad: CGFloat = 8
        return CGRect(x: a.frame.minX, y: a.frame.minY,
                      width: ceil(bounding.width) + pad, height: ceil(bounding.height) + pad)
    }

    // MARK: keys

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let c = event.charactersIgnoringModifiers?.lowercased() ?? ""
            switch c {
            case "z":
                if event.modifierFlags.contains(.shift) { redo() } else { undo() }
                return
            case "c": copySelectedObject(); return
            case "x": cutSelectedObject(); return
            case "v": pasteObject(); return
            case "a": selectLastObject(); return
            default: break
            }
        }
        switch event.keyCode {
        case 36, 76:  // Return / keypad Enter → finish a polyline/polygon build (§4.2)
            if buildingPoly { finishPolyBuild(); return }
        case 51, 117:  // Delete
            deleteSelection()
            return
        case 53:  // Esc → cancel an in-progress build, else discard & exit Draw (§10)
            if buildingPoly { cancelPolyBuild(); return }
            onCancelRequested?()
            return
        case 48:  // Tab → cycle objects
            guard !annotations.isEmpty else { return }
            let sorted = annotations.sorted { $0.z < $1.z }
            if let cur = selectedID, let i = sorted.firstIndex(where: { $0.id == cur }) {
                setSelected(sorted[(i + 1) % sorted.count].id)
            } else {
                setSelected(sorted.first?.id)
            }
            return
        case 123, 124, 125, 126:  // arrows nudge
            guard let id = selectedID, let idx = annotations.firstIndex(where: { $0.id == id }) else { break }
            let d: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            var delta = CGPoint.zero
            switch event.keyCode {
            case 123: delta.x = -d
            case 124: delta.x = d
            case 125: delta.y = d
            case 126: delta.y = -d
            default: break
            }
            pushUndo()
            annotations[idx].move(by: delta)
            needsDisplay = true
            return
        default:
            break
        }
        super.keyDown(with: event)
    }
}

/// Flipped container so a short document pins to the top of its scroll view.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Floating text editor

/// Multiline text editor used by the Draw canvas (spec §3.2).
/// Enter inserts a newline; ⌘Enter / Ctrl+Enter (or Esc) commits & closes.
@MainActor
final class DrawTextView: NSTextView {
    var onCommit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:   // Return / keypad Enter
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
                onCommit?()       // ⌘/Ctrl+Enter = commit & close
                return
            }
            super.keyDown(with: event)   // plain Enter = newline
        case 53:       // Esc = commit & close (avoid losing typed text)
            onCommit?()
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - Adjust Colors dialog

@MainActor
enum AdjustColorsPanel {
    static func run(for doc: EditorDocument, onApply: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = Loc.t("调整颜色", "Adjust Colors")
        let labels = [Loc.t("亮度", "Brightness"), Loc.t("对比度", "Contrast"), Loc.t("饱和度", "Saturation"), "Gamma"]
        let ranges: [(Double, Double, Double)] = [(-0.5, 0.5, 0), (0.4, 2.0, 1), (0, 2.5, 1), (0.3, 2.5, 1)]
        var sliders: [NSSlider] = []
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 280, height: CGFloat(labels.count) * 30))
        for (i, label) in labels.enumerated() {
            let y = CGFloat(labels.count - 1 - i) * 30
            let l = NSTextField(labelWithString: label)
            l.frame = CGRect(x: 0, y: y + 4, width: 60, height: 18)
            l.font = .systemFont(ofSize: 11)
            let s = NSSlider(value: ranges[i].2, minValue: ranges[i].0, maxValue: ranges[i].1,
                             target: nil, action: nil)
            s.frame = CGRect(x: 66, y: y, width: 210, height: 24)
            view.addSubview(l)
            view.addSubview(s)
            sliders.append(s)
        }
        alert.accessoryView = view
        alert.addButton(withTitle: Loc.t("应用", "Apply"))
        alert.addButton(withTitle: Loc.t("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let b = sliders[0].doubleValue, c = sliders[1].doubleValue
        let s = sliders[2].doubleValue, g = sliders[3].doubleValue
        doc.applyRasterOp(Loc.t("调整颜色", "Adjust Colors")) {
            ImageOps.adjust($0, brightness: b, contrast: c, saturation: s, gamma: g)
        }
        onApply()
    }
}
