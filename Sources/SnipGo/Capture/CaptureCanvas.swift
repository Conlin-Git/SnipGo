import AppKit

/// 所有屏幕共享的截图状态。坐标统一为全局 Cocoa 坐标（左下角原点，pt），
/// 每块屏幕的 SelectionView 把自己的 bounds 原点设为该屏幕的全局位置，因此可以直接使用这些坐标绘制。
@MainActor
final class CaptureCanvas {
    let mode: CaptureMode
    /// 前后顺序的普通窗口矩形（全局坐标，最前在前）
    let windowRects: [CGRect]
    private(set) var views: [SelectionView] = []

    var selection: CGRect? { didSet { if oldValue != selection { redraw() } } }
    var hoverRect: CGRect? { didSet { if oldValue != hoverRect { redraw() } } }
    var tool: AnnotationTool? { didSet { redraw() } }
    var annotations: [Annotation] = [] {
        didSet {
            views.forEach { $0.closeTextCard() }
            redraw()
        }
    }
    var current: Annotation? { didSet { redraw() } }

    /// 正在新建 / 调整选区（此时也显示取色放大镜）
    var isAdjusting = false { didSet { if oldValue != isAdjusting { redraw() } } }
    /// 取色放大镜跟随的鼠标位置
    var cursor: CGPoint? {
        didSet {
            guard oldValue != cursor else { return }
            for v in views {
                if let o = oldValue { v.invalidateMagnifier(at: o) }
                if let c = cursor { v.invalidateMagnifier(at: c) }
            }
        }
    }
    /// 取色器显示格式：true = HEX，false = RGB（本次运行内记住）
    static var colorAsHex = true

    /// 临时提示（如「长截图不支持跨屏」）
    private(set) var message: String?
    private var messageTask: Task<Void, Never>?

    init(mode: CaptureMode, windowRects: [CGRect]) {
        self.mode = mode
        self.windowRects = windowRects
        cursor = NSEvent.mouseLocation
    }

    func add(_ view: SelectionView) { views.append(view) }

    func detachViews() { views.removeAll() }

    func redraw() { views.forEach { $0.needsDisplay = true } }

    /// 所有屏幕的外接矩形（截图模式下选区可在其中自由移动）
    var unionRect: CGRect { views.reduce(CGRect.null) { $0.union($1.bounds) } }

    func view(containing p: CGPoint) -> SelectionView? { views.first { $0.bounds.contains(p) } }

    /// 选区涉及的屏幕
    func views(intersecting r: CGRect) -> [SelectionView] {
        views.filter { let i = $0.bounds.intersection(r); return !i.isNull && i.width > 0 && i.height > 0 }
    }

    /// 选区完全落在其中的那块屏幕（跨屏时为 nil）
    func singleScreenView(for r: CGRect) -> SelectionView? {
        views.first { $0.bounds.insetBy(dx: -0.5, dy: -0.5).contains(r) }
    }

    /// 显示工具栏的屏幕：选区底边中点所在的屏幕，否则取与选区重叠面积最大的屏幕
    var barOwner: SelectionView? {
        guard let sel = selection else { return nil }
        if let v = view(containing: CGPoint(x: sel.midX, y: sel.minY + 1)) { return v }
        return largestOverlap(sel)
    }

    /// 显示尺寸标签的屏幕：选区左上角所在的屏幕
    var labelOwner: SelectionView? {
        guard let sel = selection else { return nil }
        return view(containing: CGPoint(x: sel.minX + 1, y: sel.maxY - 1)) ?? barOwner
    }

    private func largestOverlap(_ r: CGRect) -> SelectionView? {
        views.max { a, b in
            let ia = a.bounds.intersection(r), ib = b.bounds.intersection(r)
            return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
        }
    }

    // MARK: - 跨屏操作

    func refreshBars() { views.forEach { $0.updateOwnBars() } }
    func hideBars() { views.forEach { $0.hideOwnBars() } }

    var hasPendingText: Bool { views.contains { $0.hasPendingText } }
    func commitPendingText() { views.forEach { $0.commitPendingText() } }

    func flash(_ text: String) {
        message = text
        redraw()
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.message = nil
            self?.redraw()
        }
    }
}
