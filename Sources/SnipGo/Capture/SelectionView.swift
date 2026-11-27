import AppKit

@MainActor
protocol SelectionViewDelegate: AnyObject {
    func selectionViewShouldBegin(_ view: SelectionView) -> Bool
    func selectionViewDidBegin(_ view: SelectionView)
    func selectionView(_ view: SelectionView, perform command: ToolbarCommand)
}

/// 遮罩窗口的内容：底层显示冻结的截图，上层绘制遮罩、选区、标注
final class OverlayContentView: NSView {
    let selectionView: SelectionView

    init(snapshot: ScreenSnapshot, mode: CaptureMode) {
        selectionView = SelectionView(snapshot: snapshot, mode: mode)
        super.init(frame: NSRect(origin: .zero, size: snapshot.screen.frame.size))
        wantsLayer = true
        layer?.contents = snapshot.image
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .nearest
        selectionView.frame = bounds
        selectionView.autoresizingMask = [.width, .height]
        addSubview(selectionView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func showFrozenImage(_ show: Bool) {
        layer?.contents = show ? selectionView.snapshot.image : nil
    }
}

final class SelectionView: NSView, NSTextFieldDelegate {
    weak var delegate: SelectionViewDelegate?

    let snapshot: ScreenSnapshot
    let mode: CaptureMode

    private(set) var selection: CGRect?
    private var hoverRect: CGRect?
    /// 另一块屏幕已开始选区，本屏只显示遮罩
    var isPassive = false { didSet { hoverRect = nil; needsDisplay = true } }
    private(set) var isScrolling = false

    private var tool: AnnotationTool?
    private(set) var annotations: [Annotation] = []
    private var current: Annotation?
    private var mosaicImage: CGImage?

    private enum Drag {
        case none
        case creating(start: CGPoint)
        case moving(start: CGPoint, original: CGRect)
        case resizing(handle: Int, start: CGPoint, original: CGRect)
        case drawing
    }

    private var drag: Drag = .none
    private var didDrag = false

    private var toolbar: ToolbarView?
    private var styleBar: StyleBarView?
    private var pinButton: PinCornerButton?
    /// 录屏模式：底部控制条
    private var recordBar: RecordControlBar?
    private(set) var recordFullScreen = false
    private var lastRegion: CGRect?
    private var textField: NSTextField?

    private let accent = NSColor(srgbRed: 0.16, green: 0.5, blue: 1, alpha: 1)

    init(snapshot: ScreenSnapshot, mode: CaptureMode) {
        self.snapshot = snapshot
        self.mode = mode
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                       owner: self, userInfo: nil))
    }

    private var pixelScale: CGFloat {
        bounds.width > 0 ? CGFloat(snapshot.image.width) / bounds.width : snapshot.screen.backingScaleFactor
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let hole: CGRect? = selection ?? (isPassive || isScrolling ? nil : hoverRect)

        // 遮罩
        ctx.saveGState()
        ctx.setFillColor(NSColor(white: 0, alpha: isScrolling ? 0.28 : 0.4).cgColor)
        ctx.addRect(bounds)
        if let hole { ctx.addRect(hole) }
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()

        if let sel = selection, !isScrolling {
            ctx.saveGState()
            ctx.clip(to: sel)
            for a in annotations { AnnotationRenderer.draw(a, in: ctx, mosaic: mosaicImage, imageRect: bounds) }
            if let current { AnnotationRenderer.draw(current, in: ctx, mosaic: mosaicImage, imageRect: bounds) }
            ctx.restoreGState()
        }

        if let hole {
            ctx.saveGState()
            let isSelection = selection != nil
            if mode == .record && isSelection {
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineDash(phase: 0, lengths: [6, 4])
            } else {
                ctx.setStrokeColor(accent.cgColor)
            }
            ctx.setLineWidth(isSelection ? 1.5 : 2.5)
            // 边框画在选区外侧，避免进入截图 / 录制区域
            ctx.stroke(hole.insetBy(dx: -0.75, dy: -0.75))
            ctx.restoreGState()
        }

        if let sel = selection, !isScrolling {
            if tool == nil, !(mode == .record && recordFullScreen) { drawHandles(sel, in: ctx) }
            if !(mode == .record && recordFullScreen) { drawSizeLabel(sel) }
        } else if selection == nil, mode == .screenshot, !isPassive, !isScrolling, case .none = drag {
            drawHint()
        }
    }

    private func handleRects(_ r: CGRect) -> [CGRect] {
        let pts = [
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
            CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY),
        ]
        return pts.map { CGRect(x: $0.x - 4, y: $0.y - 4, width: 8, height: 8) }
    }

    private func drawHandles(_ r: CGRect, in ctx: CGContext) {
        for h in handleRects(r) {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: h)
            ctx.setStrokeColor((mode == .record ? NSColor(white: 0.3, alpha: 1) : accent).cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: h)
        }
    }

    private func drawSizeLabel(_ sel: CGRect) {
        let text = "\(Int(sel.width.rounded())) × \(Int(sel.height.rounded())) pt"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        var box = CGRect(x: sel.minX, y: sel.maxY + 6, width: size.width + 12, height: size.height + 6)
        if box.maxY > bounds.maxY - 2 { box.origin.y = sel.maxY - box.height - 6; box.origin.x = sel.minX + 6 }
        box.origin.x = min(max(box.minX, bounds.minX + 2), bounds.maxX - box.width - 2)
        (mode == .record ? NSColor(white: 0.15, alpha: 0.85) : accent).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3), withAttributes: attrs)
    }

    private func drawHint() {
        let text = mode == .record
            ? "拖拽选择录制区域 · 单击选择窗口 · 单击空白处录制整屏 · Esc 取消"
            : "拖拽选择区域 · 单击选择窗口 · Esc 取消"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let box = CGRect(x: bounds.midX - size.width / 2 - 14, y: bounds.maxY - 90, width: size.width + 28, height: size.height + 14)
        NSColor(white: 0.1, alpha: 0.8).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 14, y: box.minY + 7), withAttributes: attrs)
    }

    // MARK: - 鼠标

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if selection == nil, !isPassive, !isScrolling {
            let r = snapshot.windowRects.first(where: { $0.contains(p) })?.intersection(bounds) ?? bounds
            if r != hoverRect { hoverRect = r; needsDisplay = true }
            NSCursor.crosshair.set()
        } else if let sel = selection {
            if tool != nil, sel.contains(p) {
                (tool == .text ? NSCursor.iBeam : NSCursor.crosshair).set()
            } else if tool == nil, handleIndex(at: p, in: sel) != nil {
                NSCursor.crosshair.set()
            } else if tool == nil, sel.contains(p) {
                NSCursor.openHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        delegate?.selectionView(self, perform: .cancel)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isScrolling else { return }
        let p = convert(event.locationInWindow, from: nil)
        didDrag = false

        if textField != nil {
            commitText()
            return
        }

        if mode == .record, recordFullScreen {
            if event.clickCount == 2 { delegate?.selectionView(self, perform: .startRecord) }
            return
        }

        if let sel = selection {
            if event.clickCount == 2, sel.contains(p), tool == nil {
                delegate?.selectionView(self, perform: mode == .record ? .startRecord : .copy)
                return
            }
            if let tool, sel.contains(p) {
                if tool == .text {
                    beginText(at: p)
                    return
                }
                let size = AppSettings.annotationSize
                let width = tool == .mosaic ? AnnotationPalette.mosaicWidths[size] : AnnotationPalette.lineWidths[size]
                if tool == .mosaic, mosaicImage == nil {
                    mosaicImage = AnnotationRenderer.makeMosaic(from: snapshot.image, blockPixels: 9 * pixelScale)
                }
                current = Annotation(tool: tool, color: AnnotationPalette.color(AppSettings.annotationColorIndex),
                                     width: width, points: [p, p])
                drag = .drawing
                hideBars()
                return
            }
            if tool == nil, let h = handleIndex(at: p, in: sel) {
                drag = .resizing(handle: h, start: p, original: sel)
                hideBars()
                return
            }
            if tool == nil, sel.contains(p) {
                drag = .moving(start: p, original: sel)
                NSCursor.closedHand.set()
                hideBars()
                return
            }
            if tool == nil, annotations.isEmpty {
                // 在选区外拖拽：重新选择
                selection = nil
                drag = .creating(start: p)
                hideBars()
                needsDisplay = true
            }
            return
        }

        guard !isPassive, delegate?.selectionViewShouldBegin(self) ?? true else { return }
        drag = .creating(start: p)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .none:
            return
        case .creating(let start):
            if !didDrag, hypot(p.x - start.x, p.y - start.y) < 3 { return }
            if !didDrag { delegate?.selectionViewDidBegin(self) }
            didDrag = true
            let clamped = CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
            selection = AnnotationRenderer.rect(start, clamped)
        case .moving(let start, let original):
            didDrag = true
            var r = original.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
            r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
            selection = r
        case .resizing(let h, let start, let o):
            didDrag = true
            let dx = p.x - start.x, dy = p.y - start.y
            var minX = o.minX, maxX = o.maxX, minY = o.minY, maxY = o.maxY
            if [0, 6, 7].contains(h) { minX += dx }
            if [2, 3, 4].contains(h) { maxX += dx }
            if [0, 1, 2].contains(h) { minY += dy }
            if [4, 5, 6].contains(h) { maxY += dy }
            let r = AnnotationRenderer.rect(CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: maxY))
            selection = r.intersection(bounds)
        case .drawing:
            didDrag = true
            guard var c = current, let sel = selection else { return }
            let q = CGPoint(x: min(max(p.x, sel.minX), sel.maxX), y: min(max(p.y, sel.minY), sel.maxY))
            if c.tool == .pen || c.tool == .mosaic {
                if let last = c.points.last, hypot(last.x - q.x, last.y - q.y) >= 1.5 { c.points.append(q) }
            } else {
                c.points[c.points.count - 1] = q
            }
            current = c
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .none:
            return
        case .creating:
            if !didDrag {
                // 单击：选择鼠标下的窗口（无窗口则整屏）
                delegate?.selectionViewDidBegin(self)
                selection = (hoverRect ?? bounds).intersection(bounds)
            } else if let s = selection, s.width < 4 || s.height < 4 {
                selection = nil
            }
        case .drawing:
            if let c = current, c.isMeaningful { annotations.append(c) }
            current = nil
        case .moving, .resizing:
            break
        }
        drag = .none
        if let s = selection { selection = snapped(s) }
        needsDisplay = true
        showBars()
        window?.invalidateCursorRects(for: self)
    }

    private func handleIndex(at p: CGPoint, in sel: CGRect) -> Int? {
        handleRects(sel).firstIndex { $0.insetBy(dx: -4, dy: -4).contains(p) }
    }

    /// 对齐到像素网格
    private func snapped(_ r: CGRect) -> CGRect {
        let s = pixelScale
        let minX = (r.minX * s).rounded() / s, minY = (r.minY * s).rounded() / s
        let maxX = (r.maxX * s).rounded() / s, maxY = (r.maxY * s).rounded() / s
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: // Esc
            delegate?.selectionView(self, perform: .cancel)
        case 36, 76: // Enter
            if selection != nil { delegate?.selectionView(self, perform: mode == .record ? .startRecord : .copy) }
        case 123, 124, 125, 126: // 方向键微调
            guard var s = selection, tool == nil else { return }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            switch Int(event.keyCode) {
            case 123: s.origin.x -= step
            case 124: s.origin.x += step
            case 125: s.origin.y -= step
            default: s.origin.y += step
            }
            s.origin.x = min(max(s.minX, bounds.minX), bounds.maxX - s.width)
            s.origin.y = min(max(s.minY, bounds.minY), bounds.maxY - s.height)
            selection = s
            layoutBars()
            needsDisplay = true
        default:
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard textField == nil, event.modifierFlags.contains(.command), selection != nil else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "z": undo(); return true
        case "c" where mode == .screenshot: delegate?.selectionView(self, perform: .copy); return true
        case "s" where mode == .screenshot: delegate?.selectionView(self, perform: .save); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    // MARK: - 工具栏

    private func showBars() {
        if mode == .record {
            showRecordBar()
            return
        }
        guard let sel = selection, !isScrolling, sel.width >= 4 else { hideBars(); return }
        if toolbar == nil {
            let tb = ToolbarView(kind: .screenshot)
            tb.onCommand = { [weak self] in self?.handle($0) }
            addSubview(tb)
            toolbar = tb
        }
        toolbar?.isHidden = false
        if pinButton == nil {
            let pb = PinCornerButton(target: self, action: #selector(pinClicked))
            addSubview(pb)
            pinButton = pb
        }
        pinButton?.isHidden = false
        toolbar?.setActiveTool(tool)
        toolbar?.setUndoEnabled(!annotations.isEmpty)
        if let tool {
            if styleBar == nil {
                let sb = StyleBarView(frame: .zero)
                sb.onCommand = { [weak self] in self?.handle($0) }
                addSubview(sb)
                styleBar = sb
            }
            styleBar?.refresh(showColors: tool.usesColor)
            styleBar?.isHidden = false
        } else {
            styleBar?.isHidden = true
        }
        layoutBars()
    }

    private func hideBars() {
        toolbar?.isHidden = true
        styleBar?.isHidden = true
        pinButton?.isHidden = true
    }

    @objc private func pinClicked() {
        if textField != nil { commitText() }
        delegate?.selectionView(self, perform: .pin)
    }

    private func layoutBars() {
        guard let sel = selection, let tb = toolbar else { return }
        let gap: CGFloat = 14
        let size = tb.frame.size
        let sb = (styleBar?.isHidden == false) ? styleBar : nil
        let sbH = sb.map { $0.frame.height + 8 } ?? 0
        let needed = size.height + sbH + gap
        var y: CGFloat
        var styleY: CGFloat
        if sel.minY - needed >= bounds.minY + 4 {
            // 选区下方
            y = sel.minY - gap - size.height
            styleY = y - sbH
        } else if sel.maxY + 34 + needed <= bounds.maxY - 4 {
            // 选区上方（让出尺寸标签）
            y = sel.maxY + 34 + gap
            styleY = y + size.height + 8
        } else {
            // 选区内部底部
            y = sel.minY + gap + sbH
            styleY = y - sbH
        }
        // 参考样式：工具栏在选区下方居中
        let x = min(max(sel.midX - size.width / 2, bounds.minX + 6), bounds.maxX - size.width - 6)
        tb.setFrameOrigin(CGPoint(x: x, y: y))
        if let sb {
            let sx = min(max(sel.midX - sb.frame.width / 2, bounds.minX + 6), bounds.maxX - sb.frame.width - 6)
            sb.setFrameOrigin(CGPoint(x: sx, y: styleY))
        }
        if let pb = pinButton {
            // 选区右上角外侧；右边放不下时放进选区内的右上角
            let d = PinCornerButton.diameter
            var px = sel.maxX + 10
            var py = sel.maxY - d - 2
            if px + d > bounds.maxX - 4 { px = sel.maxX - d - 8; py = sel.maxY - d - 8 }
            py = min(max(py, bounds.minY + 4), bounds.maxY - d - 4)
            pb.setFrameOrigin(CGPoint(x: px, y: py))
        }
    }

    private func handle(_ command: ToolbarCommand) {
        switch command {
        case .tool(let t):
            setTool(tool == t ? nil : t)
        case .undo:
            undo()
        case .color(let i):
            AppSettings.annotationColorIndex = i
            styleBar?.refresh(showColors: tool?.usesColor ?? true)
            if let tf = textField { tf.textColor = AnnotationPalette.color(i) }
        case .size(let i):
            AppSettings.annotationSize = i
            styleBar?.refresh(showColors: tool?.usesColor ?? true)
            layoutBars()
        default:
            if textField != nil { commitText() }
            delegate?.selectionView(self, perform: command)
        }
    }

    private func setTool(_ t: AnnotationTool?) {
        if textField != nil { commitText() }
        tool = t
        showBars()
        needsDisplay = true
    }

    func undo() {
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
        toolbar?.setUndoEnabled(!annotations.isEmpty)
        needsDisplay = true
    }

    // MARK: - 录屏控制条

    /// 进入录屏时预先选中一块区域（QuickTime 风格）
    func preselect(_ rect: CGRect) {
        selection = snapped(rect.intersection(bounds))
        lastRegion = selection
        showBars()
        needsDisplay = true
    }

    private func showRecordBar() {
        if recordBar == nil {
            let bar = RecordControlBar()
            bar.onCommand = { [weak self] in self?.handleRecordBar($0) }
            addSubview(bar)
            recordBar = bar
        }
        guard let bar = recordBar else { return }
        bar.setMode(fullScreen: recordFullScreen)
        bar.setFrameOrigin(NSPoint(x: (bounds.width - bar.frame.width) / 2, y: bounds.minY + 64))
        bar.isHidden = false
    }

    private func handleRecordBar(_ cmd: RecordControlBar.Command) {
        switch cmd {
        case .close:
            delegate?.selectionView(self, perform: .cancel)
        case .fullScreen:
            if !recordFullScreen, let s = selection { lastRegion = s }
            recordFullScreen = true
            selection = bounds
        case .region:
            recordFullScreen = false
            selection = lastRegion ?? Self.defaultRegion(in: bounds)
        case .record:
            if selection == nil { selection = bounds }
            delegate?.selectionView(self, perform: .startRecord)
        }
        needsDisplay = true
    }

    static func defaultRegion(in bounds: CGRect) -> CGRect {
        let w = (bounds.width * 0.6).rounded(), h = (bounds.height * 0.6).rounded()
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2 + 30, width: w, height: h)
    }

    // MARK: - 文字

    private func beginText(at p: CGPoint) {
        let size = AnnotationPalette.fontSizes[AppSettings.annotationSize]
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        let h = ceil(font.ascender - font.descender + font.leading) + 4
        let tf = NSTextField(frame: NSRect(x: p.x, y: p.y - h / 2, width: 60, height: h))
        tf.font = font
        tf.textColor = AnnotationPalette.color(AppSettings.annotationColorIndex)
        tf.isBordered = false
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        tf.delegate = self
        tf.wantsLayer = true
        tf.layer?.borderColor = NSColor(white: 1, alpha: 0.6).cgColor
        tf.layer?.borderWidth = 1
        tf.layer?.cornerRadius = 3
        addSubview(tf)
        window?.makeFirstResponder(tf)
        textField = tf
        hideBars()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let tf = textField else { return }
        let w = (tf.stringValue as NSString).size(withAttributes: [.font: tf.font!]).width + 24
        tf.setFrameSize(NSSize(width: max(60, min(w, (selection?.maxX ?? bounds.maxX) - tf.frame.minX)), height: tf.frame.height))
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitText()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            textField?.removeFromSuperview()
            textField = nil
            window?.makeFirstResponder(self)
            showBars()
            return true
        }
        return false
    }

    private func commitText() {
        guard let tf = textField else { return }
        textField = nil
        let font = tf.font ?? NSFont.systemFont(ofSize: 22)
        // NSTextField 文字左侧约 2pt 内边距；draw(at:) 的原点是文字框左下角
        let origin = CGPoint(x: tf.frame.minX + 2, y: tf.frame.minY + 2)
        let a = Annotation(tool: .text, color: tf.textColor ?? .red, width: 0, points: [origin],
                           text: tf.stringValue, fontSize: font.pointSize)
        tf.removeFromSuperview()
        if a.isMeaningful { annotations.append(a) }
        window?.makeFirstResponder(self)
        showBars()
        needsDisplay = true
    }

    // MARK: - 长图模式

    func enterScrollingMode() {
        if textField != nil { commitText() }
        isScrolling = true
        tool = nil
        hideBars()
        needsDisplay = true
    }

    // MARK: - 导出

    /// 渲染选区 + 标注为像素图
    func renderResult() -> CGImage? {
        guard let sel = selection else { return nil }
        let s = pixelScale
        let w = Int((sel.width * s).rounded()), h = Int((sel.height * s).rounded())
        guard w > 0, h > 0 else { return nil }
        let space = snapshot.image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
            ?? CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)
        else { return nil }
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -sel.minX, y: -sel.minY)
        ctx.interpolationQuality = .none
        ctx.draw(snapshot.image, in: bounds)
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        for a in annotations { AnnotationRenderer.draw(a, in: ctx, mosaic: mosaicImage, imageRect: bounds) }
        return ctx.makeImage()
    }
}
