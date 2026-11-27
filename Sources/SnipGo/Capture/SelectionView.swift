import AppKit
import SnipCore

@MainActor
protocol SelectionViewDelegate: AnyObject {
    func selectionViewShouldBegin(_ view: SelectionView) -> Bool
    func selectionViewDidBegin(_ view: SelectionView)
    func selectionView(_ view: SelectionView, perform command: ToolbarCommand)
}

/// 遮罩窗口的内容：底层显示冻结的截图，上层绘制遮罩、选区、标注
final class OverlayContentView: NSView {
    let selectionView: SelectionView

    init(snapshot: ScreenSnapshot, canvas: CaptureCanvas) {
        selectionView = SelectionView(snapshot: snapshot, canvas: canvas)
        super.init(frame: NSRect(origin: .zero, size: snapshot.screen.frame.size))
        wantsLayer = true
        layer?.contents = snapshot.image
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .nearest
        selectionView.frame = bounds
        // 选区视图的坐标系 = 全局坐标：所有屏幕共用同一套选区 / 标注坐标，选区可以跨屏
        selectionView.setBoundsOrigin(snapshot.screen.frame.origin)
        addSubview(selectionView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func showFrozenImage(_ show: Bool) {
        layer?.contents = show ? selectionView.snapshot.image : nil
    }
}

/// 单块屏幕上的选区视图。选区、标注、当前工具等状态保存在共享的 CaptureCanvas 中，
/// 本视图的 bounds 即该屏幕的全局矩形。
final class SelectionView: NSView, NSTextFieldDelegate {
    weak var delegate: SelectionViewDelegate?

    let snapshot: ScreenSnapshot
    let canvas: CaptureCanvas
    var mode: CaptureMode { canvas.mode }

    private(set) var selection: CGRect? {
        get { canvas.selection }
        set { canvas.selection = newValue }
    }
    private var hoverRect: CGRect? {
        get { canvas.hoverRect }
        set { canvas.hoverRect = newValue }
    }
    private var tool: AnnotationTool? {
        get { canvas.tool }
        set { canvas.tool = newValue }
    }
    private(set) var annotations: [Annotation] {
        get { canvas.annotations }
        set { canvas.annotations = newValue }
    }
    private var current: Annotation? {
        get { canvas.current }
        set { canvas.current = newValue }
    }

    /// 录屏模式下另一块屏幕已开始选区，本屏只显示遮罩
    var isPassive = false { didSet { hoverRect = nil; needsDisplay = true } }
    private(set) var isScrolling = false
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
    private var shiftDown = false

    private var toolbar: ToolbarView?
    private var styleBar: StyleBarView?
    /// 主工具栏下方的文字工具条（提取文字 / 翻译）
    private var textBar: TextToolBarView?
    /// 识别 / 翻译结果卡片（内嵌在遮罩里，贴在选区旁）
    private var textCard: TextResultCard?
    private var pinButton: PinCornerButton?
    /// 录屏模式：底部控制条
    private var recordBar: RecordControlBar?
    private(set) var recordFullScreen = false
    private var lastRegion: CGRect?
    private var textField: NSTextField?

    private let accent = NSColor(srgbRed: 0.16, green: 0.5, blue: 1, alpha: 1)

    init(snapshot: ScreenSnapshot, canvas: CaptureCanvas) {
        self.snapshot = snapshot
        self.canvas = canvas
        super.init(frame: .zero)
        canvas.add(self)
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

    var pixelScale: CGFloat {
        bounds.width > 0 ? CGFloat(snapshot.image.width) / bounds.width : snapshot.screen.backingScaleFactor
    }

    /// 选区可移动 / 调整的范围：截图可跨屏；录屏只能在本屏（一次只录一块显示器）
    private var limit: CGRect { mode == .screenshot ? canvas.unionRect : bounds }

    private func ensureMosaic() -> CGImage? {
        if mosaicImage == nil {
            mosaicImage = AnnotationRenderer.makeMosaic(from: snapshot.image, blockPixels: 9 * pixelScale)
        }
        return mosaicImage
    }

    private func draw(_ a: Annotation, in ctx: CGContext) {
        AnnotationRenderer.draw(a, in: ctx, mosaic: a.tool == .mosaic ? ensureMosaic() : nil, imageRect: bounds)
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
            for a in annotations { draw(a, in: ctx) }
            if let current { draw(current, in: ctx) }
            ctx.restoreGState()
        }

        if let hole {
            ctx.saveGState()
            let isSelection = selection != nil
            if mode == .record && isSelection {
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineDash(phase: 0, lengths: [6, 4])
            } else {
                ctx.setStrokeColor(NSColor.white.cgColor)   // 截图选区框 / 窗口悬停高亮：白色实线
            }
            ctx.setLineWidth(isSelection ? 1.5 : 2.5)
            // 边框画在选区外侧，避免进入截图 / 录制区域
            ctx.stroke(hole.insetBy(dx: -0.75, dy: -0.75))
            ctx.restoreGState()
        }

        if let sel = selection, !isScrolling {
            if tool == nil, !(mode == .record && recordFullScreen) { drawHandles(sel, in: ctx) }
            if !(mode == .record && recordFullScreen), canvas.labelOwner === self { drawSizeLabel(sel) }
        } else if selection == nil, mode == .screenshot, !isPassive, !isScrolling, case .none = drag {
            drawHint()
        }

        if let message = canvas.message, (canvas.barOwner ?? self) === self { drawBanner(message) }

        if let p = canvas.cursor { drawMagnifier(at: p, in: ctx) }
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
            ctx.setStrokeColor(NSColor(white: 0.3, alpha: 1).cgColor)   // 白底灰边，白色选区框上也看得清
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: h)
        }
    }

    private func drawSizeLabel(_ sel: CGRect) {
        let text = "\(Int(sel.width.rounded())) × \(Int(sel.height.rounded())) pt"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: mode == .record ? NSColor.white : NSColor(white: 0.1, alpha: 1),
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        var box = CGRect(x: sel.minX, y: sel.maxY + 6, width: size.width + 12, height: size.height + 6)
        if box.maxY > bounds.maxY - 2 { box.origin.y = sel.maxY - box.height - 6; box.origin.x = sel.minX + 6 }
        box.origin.x = min(max(box.minX, bounds.minX + 2), bounds.maxX - box.width - 2)
        box.origin.y = min(max(box.minY, bounds.minY + 2), bounds.maxY - box.height - 2)
        (mode == .record ? NSColor(white: 0.15, alpha: 0.85) : NSColor(white: 1, alpha: 0.95)).setFill()   // 截图：白底深色字
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3), withAttributes: attrs)
    }

    private func drawHint() {
        let text = mode == .record
            ? "拖拽选择录制区域 · 单击选择窗口 · 单击空白处录制整屏 · Esc 取消"
            : "拖拽选择区域（可跨屏） · 单击选择窗口 · ⌘A 选中所有屏幕 · C 复制颜色 · Esc 取消"
        drawBanner(text)
    }

    private func drawBanner(_ text: String) {
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

    // MARK: - 取色器（放大镜）

    private static let magGrid = 17                // 放大显示 17×17 个像素
    private static let magCell: CGFloat = 8        // 每个像素放大成 8pt
    private static var magSide: CGFloat { CGFloat(magGrid) * magCell }
    private static let magInfoHeight: CGFloat = 58

    /// 新建 / 调整选区前后显示放大镜
    var showsMagnifier: Bool {
        mode == .screenshot && !isScrolling && !isPassive && !canvas.hasPendingText
            && (canvas.selection == nil || canvas.isAdjusting)
    }

    private func magnifierFrame(at p: CGPoint) -> CGRect? {
        guard showsMagnifier, bounds.contains(p) else { return nil }
        let w = Self.magSide, h = Self.magSide + Self.magInfoHeight
        var x = p.x + 20, y = p.y - 20 - h
        if x + w > bounds.maxX - 4 { x = p.x - 20 - w }
        if y < bounds.minY + 4 { y = p.y + 20 }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    func invalidateMagnifier(at p: CGPoint) {
        guard let f = magnifierFrame(at: p) else { return }
        setNeedsDisplay(f.insetBy(dx: -4, dy: -4))
    }

    /// 取鼠标所在像素周围 17×17 的区域（sRGB）和中心像素颜色
    func sample(at p: CGPoint) -> (image: CGImage, color: PixelColor)? {
        let img = snapshot.image
        let s = pixelScale
        let n = Self.magGrid, half = n / 2
        let px = min(max(Int(((p.x - bounds.minX) * s).rounded(.down)), 0), img.width - 1)
        let py = min(max(Int(((bounds.maxY - p.y) * s).rounded(.down)), 0), img.height - 1)   // 图像坐标：左上角原点
        let want = CGRect(x: px - half, y: py - half, width: n, height: n)
        let crop = want.intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        guard !crop.isNull, let part = img.cropping(to: crop),
              let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        // 位图上下文左下角为原点；裁剪区域贴边时按偏移放置，保持中心像素位置不变
        let dx = crop.minX - want.minX, dyTop = crop.minY - want.minY
        ctx.draw(part, in: CGRect(x: dx, y: CGFloat(n) - dyTop - crop.height, width: crop.width, height: crop.height))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self), let out = ctx.makeImage() else { return nil }
        let o = half * ctx.bytesPerRow + half * 4          // 内存第一行是图像顶部
        return (out, PixelColor(premultipliedR: data[o], g: data[o + 1], b: data[o + 2], a: data[o + 3]))
    }

    private func drawMagnifier(at p: CGPoint, in ctx: CGContext) {
        guard let f = magnifierFrame(at: p), let picked = sample(at: p) else { return }
        let image = picked.image, color = picked.color
        let side = Self.magSide
        let mag = CGRect(x: f.minX, y: f.maxY - side, width: side, height: side)

        ctx.saveGState()
        NSColor(white: 0.08, alpha: 0.94).setFill()
        NSBezierPath(roundedRect: f, xRadius: 6, yRadius: 6).fill()

        ctx.saveGState()
        NSBezierPath(roundedRect: mag, xRadius: 6, yRadius: 6).addClip()
        ctx.interpolationQuality = .none
        ctx.draw(image, in: mag)
        // 像素网格
        ctx.setStrokeColor(NSColor(white: 0.5, alpha: 0.18).cgColor)
        ctx.setLineWidth(0.5)
        for i in 1..<Self.magGrid {
            let d = CGFloat(i) * Self.magCell
            ctx.move(to: CGPoint(x: mag.minX + d, y: mag.minY)); ctx.addLine(to: CGPoint(x: mag.minX + d, y: mag.maxY))
            ctx.move(to: CGPoint(x: mag.minX, y: mag.minY + d)); ctx.addLine(to: CGPoint(x: mag.maxX, y: mag.minY + d))
        }
        ctx.strokePath()
        // 中心十字线 + 中心像素框
        let c = CGFloat(Self.magGrid / 2) * Self.magCell
        let center = CGRect(x: mag.minX + c, y: mag.minY + c, width: Self.magCell, height: Self.magCell)
        ctx.setFillColor(accent.withAlphaComponent(0.25).cgColor)
        ctx.fill(CGRect(x: mag.minX, y: center.minY, width: side, height: Self.magCell))
        ctx.fill(CGRect(x: center.minX, y: mag.minY, width: Self.magCell, height: side))
        ctx.setStrokeColor((color.isLight ? NSColor.black : NSColor.white).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(center.insetBy(dx: 0.5, dy: 0.5))
        ctx.restoreGState()

        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.25).cgColor)
        ctx.setLineWidth(1)
        NSBezierPath(roundedRect: f.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).stroke()

        // 文字：坐标 / 颜色 / 操作提示
        let mono = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let white: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: NSColor.white]
        let gray: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 1, alpha: 0.6)]
        let x = Int((p.x - bounds.minX).rounded(.down)), y = Int((bounds.maxY - p.y).rounded(.down))
        ("(\(x), \(y))" as NSString).draw(at: CGPoint(x: f.minX + 8, y: mag.minY - 20), withAttributes: white)
        let swatch = CGRect(x: f.minX + 8, y: mag.minY - 37, width: 12, height: 12)
        ctx.setFillColor(NSColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1).cgColor)
        ctx.fill(swatch)
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.6).cgColor)
        ctx.stroke(swatch.insetBy(dx: 0.5, dy: 0.5))
        (color.string(hex: CaptureCanvas.colorAsHex) as NSString).draw(at: CGPoint(x: swatch.maxX + 6, y: swatch.minY - 2), withAttributes: white)
        ("C 复制颜色 · ⇧ 切换格式" as NSString).draw(at: CGPoint(x: f.minX + 8, y: f.minY + 5), withAttributes: gray)
        ctx.restoreGState()
    }

    /// C 键：复制鼠标处的颜色并结束截图
    private func copyColorUnderCursor() -> Bool {
        guard let p = canvas.cursor, let v = canvas.view(containing: p), v.showsMagnifier,
              let color = v.sample(at: p)?.color else { return false }
        let text = color.string(hex: CaptureCanvas.colorAsHex)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let swatch = NSColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
        CopyToast.show("已复制 \(text)", swatch: swatch, near: p)
        delegate?.selectionView(self, perform: .cancel)
        return true
    }

    // MARK: - 鼠标

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        canvas.cursor = p
        if selection == nil, !isPassive, !isScrolling {
            let clip = mode == .screenshot ? canvas.unionRect : bounds
            let r = canvas.windowRects.first(where: { $0.contains(p) })?.intersection(clip) ?? bounds
            hoverRect = r
            NSCursor.crosshair.set()
        } else if let sel = selection {
            // 鼠标在工具栏、按钮、结果卡片等子视图上时，光标交给子视图（按钮显示手形）
            if subviews.contains(where: { !$0.isHidden && $0.frame.contains(p) }) { return }
            if tool != nil, sel.contains(p) {
                (tool == .text ? NSCursor.iBeam : NSCursor.crosshair).set()
            } else if tool == nil, let h = handleIndex(at: p, in: sel) {
                Self.resizeCursor(forHandle: h).set()
            } else if tool == nil, sel.contains(p) {
                NSCursor.openHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        if let c = canvas.cursor, bounds.contains(c), case .none = drag { canvas.cursor = nil }
    }

    override func rightMouseDown(with event: NSEvent) {
        delegate?.selectionView(self, perform: .cancel)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isScrolling, !isPassive else { return }
        let p = convert(event.locationInWindow, from: nil)
        didDrag = false

        if canvas.hasPendingText {
            canvas.commitPendingText()
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
                current = Annotation(tool: tool, color: AnnotationPalette.color(AppSettings.annotationColorIndex),
                                     width: width, points: [p, p])
                drag = .drawing
                hideBars()
                return
            }
            if tool == nil, let h = handleIndex(at: p, in: sel) {
                Self.resizeCursor(forHandle: h).set()
                drag = .resizing(handle: h, start: p, original: sel)
                canvas.isAdjusting = true
                canvas.cursor = p
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
                // 在选区外拖拽：重新选择（可以在另一块屏幕上）
                selection = nil
                drag = .creating(start: p)
                canvas.isAdjusting = true
                hideBars()
                needsDisplay = true
            }
            return
        }

        guard delegate?.selectionViewShouldBegin(self) ?? true else { return }
        drag = .creating(start: p)
        canvas.isAdjusting = true
    }

    override func mouseDragged(with event: NSEvent) {
        // 拖到其他屏幕时事件仍发给本视图，坐标超出本屏 bounds，正好是全局坐标
        let p = convert(event.locationInWindow, from: nil)
        let lim = limit
        switch drag {
        case .none:
            return
        case .creating(let start):
            let clamped = CGPoint(x: min(max(p.x, lim.minX), lim.maxX), y: min(max(p.y, lim.minY), lim.maxY))
            canvas.cursor = clamped
            if !didDrag, hypot(p.x - start.x, p.y - start.y) < 3 { return }
            if !didDrag { delegate?.selectionViewDidBegin(self) }
            didDrag = true
            selection = AnnotationRenderer.rect(start, clamped)
        case .moving(let start, let original):
            didDrag = true
            var r = original.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            r.origin.x = min(max(r.minX, lim.minX), lim.maxX - r.width)
            r.origin.y = min(max(r.minY, lim.minY), lim.maxY - r.height)
            selection = r
        case .resizing(let h, let start, let o):
            didDrag = true
            canvas.cursor = p
            let dx = p.x - start.x, dy = p.y - start.y
            var minX = o.minX, maxX = o.maxX, minY = o.minY, maxY = o.maxY
            if [0, 6, 7].contains(h) { minX += dx }
            if [2, 3, 4].contains(h) { maxX += dx }
            if [0, 1, 2].contains(h) { minY += dy }
            if [4, 5, 6].contains(h) { maxY += dy }
            let r = AnnotationRenderer.rect(CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: maxY))
            selection = r.intersection(lim)
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
                selection = (hoverRect ?? bounds).intersection(limit)
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
        canvas.isAdjusting = false
        if let s = selection { selection = snapped(s) }
        needsDisplay = true
        showBars()
        window?.invalidateCursorRects(for: self)
    }

    /// 选区节点的调整光标：四边为上下 / 左右箭头，四角为斜向箭头
    /// 节点顺序：0 左下、1 下、2 右下、3 右、4 右上、5 上、6 左上、7 左
    private static func resizeCursor(forHandle h: Int) -> NSCursor {
        let positions: [NSCursor.FrameResizePosition] = [.bottomLeft, .bottom, .bottomRight, .right, .topRight, .top, .topLeft, .left]
        guard positions.indices.contains(h) else { return .crosshair }
        return .frameResize(position: positions[h], directions: .all)
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
        let noCmd = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        if mode == .screenshot, noCmd, event.charactersIgnoringModifiers?.lowercased() == "c", copyColorUnderCursor() {
            return
        }
        switch Int(event.keyCode) {
        case 53: // Esc：有结果卡片时先关闭卡片
            if textCard != nil { closeTextCard() } else { delegate?.selectionView(self, perform: .cancel) }
        case 36, 76: // Enter
            if selection != nil { delegate?.selectionView(self, perform: mode == .record ? .startRecord : .copy) }
        case 123, 124, 125, 126: // 方向键微调
            guard var s = selection, tool == nil else { return }
            let lim = limit
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            switch Int(event.keyCode) {
            case 123: s.origin.x -= step
            case 124: s.origin.x += step
            case 125: s.origin.y -= step
            default: s.origin.y += step
            }
            s.origin.x = min(max(s.minX, lim.minX), lim.maxX - s.width)
            s.origin.y = min(max(s.minY, lim.minY), lim.maxY - s.height)
            selection = s
            showBars()
        default:
            super.keyDown(with: event)
        }
    }

    /// 按下 ⇧ 切换取色器的 HEX / RGB 显示
    override func flagsChanged(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        if shift, !shiftDown, mode == .screenshot, let c = canvas.cursor {
            CaptureCanvas.colorAsHex.toggle()
            canvas.views.forEach { $0.invalidateMagnifier(at: c) }
        }
        shiftDown = shift
        super.flagsChanged(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘A：选中所有屏幕（同时截取多块屏幕）
        if mode == .screenshot, !isScrolling, !canvas.hasPendingText, annotations.isEmpty,
           event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "a" {
            delegate?.selectionViewDidBegin(self)
            selection = canvas.unionRect
            showBars()
            return true
        }
        // 焦点在结果卡片内：⌘C 复制文字，其余（⌘A / ⌘V / ⌘Z 等）交给文本框
        if let card = textCard, !card.isHidden, card.containsFirstResponder {
            if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
               event.charactersIgnoringModifiers?.lowercased() == "c" {
                card.copyText()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
        guard !canvas.hasPendingText, event.modifierFlags.contains(.command), selection != nil else {
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

    /// 工具栏只显示在一块屏幕上（选区底边中点所在的屏幕）
    private func showBars() { canvas.refreshBars() }
    private func hideBars() { canvas.hideBars() }

    func updateOwnBars() {
        // 录屏时选区可能暂时为空（重新拖拽中），控制条留在当前录制的屏幕上
        let owner = canvas.barOwner ?? (mode == .record && !isPassive ? self : nil)
        guard owner === self else { hideOwnBars(); recordBar?.isHidden = true; return }
        if mode == .record {
            showRecordBar()
            return
        }
        guard let sel = selection, !isScrolling, sel.width >= 4 else { hideOwnBars(); return }
        // 选区移到另一块屏幕时工具栏跟过来；把这块屏幕的窗口设为 key，按钮第一下点击就能响应
        if let w = window, !w.isKeyWindow, case .none = drag {
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(self)
        }
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
        if mode == .screenshot {
            if textBar == nil {
                let bar = TextToolBarView(frame: .zero)
                bar.onCommand = { [weak self] in self?.handle($0) }
                addSubview(bar)
                textBar = bar
            }
            textBar?.isHidden = false
        }
        if let card = textCard {
            // 选区移动 / 调整后识别结果失效，关闭卡片；只是画了标注则继续显示
            if card.anchor != sel { closeTextCard() } else { card.isHidden = false }
        }
        if textCard != nil { pinButton?.isHidden = true }   // 卡片在选区右侧，钉图按钮会被它挡住
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

    func hideOwnBars() {
        toolbar?.isHidden = true
        styleBar?.isHidden = true
        textBar?.isHidden = true
        pinButton?.isHidden = true
        if let card = textCard {
            if card.anchor != selection { closeTextCard() } else { card.isHidden = true }
        }
    }

    // MARK: - 提取文字 / 翻译

    private func showTextCard(translate: Bool) {
        guard let sel = selection else { return }
        if let card = textCard, card.anchor == sel {
            // 同一选区：复用已识别的文字，只切换显示内容
            if translate { card.model.startTranslation() } else { card.model.showRecognition() }
        } else {
            closeTextCard()
            guard let img = renderResult() else { return }
            let card = TextResultCard(image: img, anchor: sel, translate: translate)
            card.onClose = { [weak self] in self?.closeTextCard() }
            addSubview(card)
            textCard = card
        }
        textBar?.setActive(translate ? .translate : .recognize)
        updateOwnBars()
    }

    func closeTextCard() {
        guard let card = textCard else { return }
        let hadFocus = card.containsFirstResponder
        card.removeFromSuperview()
        textCard = nil
        textBar?.setActive(nil)
        if hadFocus || window?.firstResponder == nil || window?.firstResponder === window { window?.makeFirstResponder(self) }
        if canvas.barOwner === self, selection != nil, !isScrolling { pinButton?.isHidden = false; layoutBars() }
    }

    @objc private func pinClicked() {
        canvas.commitPendingText()
        delegate?.selectionView(self, perform: .pin)
    }

    private func layoutBars() {
        guard let sel = selection, let tb = toolbar else { return }
        let gap: CGFloat = 14
        let barGap: CGFloat = 8
        let size = tb.frame.size
        // 主工具栏之外的条，按离主工具栏由近到远排列：文字工具条紧贴主工具栏（参考样式），样式行在其后
        let extras: [NSView] = [textBar, styleBar].compactMap { $0?.isHidden == false ? $0 : nil }
        let extrasH = extras.reduce(CGFloat(0)) { $0 + $1.frame.height + barGap }
        let needed = size.height + extrasH + gap
        var y: CGFloat
        let stackDown: Bool   // 其他条是否排在主工具栏下方
        if sel.minY - needed >= bounds.minY + 4 {
            // 选区下方
            y = sel.minY - gap - size.height
            stackDown = true
        } else if sel.maxY + 34 + needed <= bounds.maxY - 4 {
            // 选区上方（让出尺寸标签）
            y = sel.maxY + 34 + gap
            stackDown = false
        } else {
            // 选区内部底部
            y = sel.minY + gap + extrasH
            stackDown = true
        }
        var ys: [CGFloat] = []
        var edge = stackDown ? y : y + size.height
        for v in extras {
            if stackDown {
                edge -= barGap + v.frame.height
                ys.append(edge)
            } else {
                edge += barGap
                ys.append(edge)
                edge += v.frame.height
            }
        }
        // 跨屏时选区可能超出本屏：工具栏和其他条整体平移，始终留在本屏内
        var lo = y, hi = y + size.height
        for (v, vy) in zip(extras, ys) { lo = min(lo, vy); hi = max(hi, vy + v.frame.height) }
        var shift: CGFloat = 0
        if hi + shift > bounds.maxY - 4 { shift = bounds.maxY - 4 - hi }
        if lo + shift < bounds.minY + 4 { shift = bounds.minY + 4 - lo }
        y += shift
        // 参考样式：工具栏在选区下方居中
        let x = min(max(sel.midX - size.width / 2, bounds.minX + 6), bounds.maxX - size.width - 6)
        tb.setFrameOrigin(CGPoint(x: x, y: y))
        for (v, vy) in zip(extras, ys) {
            // 文字工具条与主工具栏左对齐；样式行在选区下方居中
            let vx = v === textBar ? x : min(max(sel.midX - v.frame.width / 2, bounds.minX + 6), bounds.maxX - v.frame.width - 6)
            v.setFrameOrigin(CGPoint(x: vx, y: vy + shift))
        }
        if let pb = pinButton {
            // 选区右上角外侧；右边放不下时放进选区内的右上角
            let d = PinCornerButton.diameter
            var px = sel.maxX + 10
            var py = sel.maxY - d - 2
            if px + d > bounds.maxX - 4 { px = sel.maxX - d - 8; py = sel.maxY - d - 8 }
            px = min(max(px, bounds.minX + 4), bounds.maxX - d - 4)
            py = min(max(py, bounds.minY + 4), bounds.maxY - d - 4)
            pb.setFrameOrigin(CGPoint(x: px, y: py))
        }
        if let card = textCard, !card.isHidden {
            // 结果卡片：选区右侧，底边与选区底边对齐；右侧放不下放左侧，都放不下放进选区内右下角
            let w = card.frame.width, h = card.frame.height, g: CGFloat = 12
            var cx: CGFloat
            var cy = sel.minY
            if sel.maxX + g + w <= bounds.maxX - 6 {
                cx = sel.maxX + g
            } else if sel.minX - g - w >= bounds.minX + 6 {
                cx = sel.minX - g - w
            } else {
                cx = sel.maxX - g - w
                cy = sel.minY + g
            }
            cx = min(max(cx, bounds.minX + 6), bounds.maxX - w - 6)
            cy = min(max(cy, bounds.minY + 6), bounds.maxY - h - 6)
            card.setFrameOrigin(CGPoint(x: cx, y: cy))
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
            canvas.views.forEach { $0.textField?.textColor = AnnotationPalette.color(i) }
        case .size(let i):
            AppSettings.annotationSize = i
            styleBar?.refresh(showColors: tool?.usesColor ?? true)
            layoutBars()
        case .recognizeText, .translate:
            canvas.commitPendingText()
            var translate = false
            if case .translate = command { translate = true }
            showTextCard(translate: translate)
        default:
            canvas.commitPendingText()
            delegate?.selectionView(self, perform: command)
        }
    }

    private func setTool(_ t: AnnotationTool?) {
        canvas.commitPendingText()
        tool = t
        showBars()
    }

    func undo() {
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
        showBars()
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
        bar.setFrameOrigin(NSPoint(x: bounds.midX - bar.frame.width / 2, y: bounds.minY + 64))
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
        showBars()
        needsDisplay = true
    }

    static func defaultRegion(in bounds: CGRect) -> CGRect {
        let w = (bounds.width * 0.6).rounded(), h = (bounds.height * 0.6).rounded()
        return CGRect(x: bounds.minX + (bounds.width - w) / 2, y: bounds.minY + (bounds.height - h) / 2 + 30, width: w, height: h)
    }

    // MARK: - 文字

    var hasPendingText: Bool { textField != nil }
    func commitPendingText() { if textField != nil { commitText() } }

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
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(tf)
        textField = tf
        hideBars()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let tf = textField else { return }
        let w = (tf.stringValue as NSString).size(withAttributes: [.font: tf.font!]).width + 24
        let right = min(selection?.maxX ?? bounds.maxX, bounds.maxX)
        tf.setFrameSize(NSSize(width: max(60, min(w, right - tf.frame.minX)), height: tf.frame.height))
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
        commitPendingText()
        isScrolling = true
        tool = nil
        closeTextCard()
        hideOwnBars()
        needsDisplay = true
    }

    // MARK: - 导出

    /// 渲染选区 + 标注为像素图；选区跨屏时把各屏的冻结图拼在一起，按最高的像素密度输出
    func renderResult() -> CGImage? {
        guard let sel = selection else { return nil }
        let parts = canvas.views(intersecting: sel)
        guard let first = parts.first else { return nil }
        let s = parts.map(\.pixelScale).max() ?? pixelScale
        let w = Int((sel.width * s).rounded()), h = Int((sel.height * s).rounded())
        guard w > 0, h > 0 else { return nil }
        let space = first.snapshot.image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
            ?? CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)
        else { return nil }
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -sel.minX, y: -sel.minY)
        for v in parts {
            // 低分屏的内容放大到高分屏密度时用平滑插值，同密度保持像素原样
            ctx.interpolationQuality = v.pixelScale == s ? .none : .high
            ctx.draw(v.snapshot.image, in: v.bounds)
        }
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        for a in canvas.annotations {
            if a.tool == .mosaic {
                // 马赛克底图按屏生成，逐屏裁剪绘制
                for v in parts {
                    ctx.saveGState()
                    ctx.clip(to: v.bounds)
                    AnnotationRenderer.draw(a, in: ctx, mosaic: v.ensureMosaic(), imageRect: v.bounds)
                    ctx.restoreGState()
                }
            } else {
                AnnotationRenderer.draw(a, in: ctx, mosaic: nil, imageRect: first.bounds)
            }
        }
        return ctx.makeImage()
    }
}
