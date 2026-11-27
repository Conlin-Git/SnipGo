import AppKit
import CoreImage
import ScreenCaptureKit
import SnipCore

enum ScrollFinishAction {
    case copy
    case save
    case pin
    case cancel
}

/// 在后台串行队列上接收 SCStream 帧并拼接
final class ScrollFrameProcessor: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let stitcher = ScrollStitcher()
    let queue = DispatchQueue(label: "snipgo.scroll", qos: .userInitiated)
    var previewScale: CGFloat = 0.25
    /// 主线程回调：总高度、预览图（可能为空）、本帧结果
    var onUpdate: ((Int, CGImage?, ScrollStitcher.Result) -> Void)?
    var onError: ((Error) -> Void)?

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var lastPreview = Date.distantPast
    private var stopped = false

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopped, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pb = sampleBuffer.imageBuffer else { return }

        let ctx = ciContext
        let frame = PixelBufferFrame(buffer: pb) { buf in
            let rect = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buf), height: CVPixelBufferGetHeight(buf))
            return ctx.createCGImage(CIImage(cvPixelBuffer: buf), from: rect)
        }
        let result = stitcher.process(frame)
        var preview: CGImage?
        let now = Date()
        switch result {
        case .first, .appended, .limitReached:
            if now.timeIntervalSince(lastPreview) > 0.2 || result == .first {
                preview = stitcher.compose(scale: previewScale)
                lastPreview = now
            }
        default:
            break
        }
        let total = stitcher.totalHeight
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(total, preview, result) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
    }

    /// 停止接收并合成（在处理队列上执行，保证在途帧已处理完）
    func stopAndCompose(_ compose: Bool, completion: @escaping (CGImage?) -> Void) {
        queue.async { [self] in
            stopped = true
            let img = compose ? stitcher.compose() : nil
            DispatchQueue.main.async { completion(img) }
        }
    }
}

@MainActor
final class ScrollCaptureSession {
    var onFinish: ((CGImage?, ScrollFinishAction) -> Void)?

    private let snapshot: ScreenSnapshot
    private let selection: CGRect           // 屏幕本地坐标
    private var stream: SCStream?
    private let processor = ScrollFrameProcessor()
    private var finished = false

    private var hud: FloatingPanel?
    private var previewPanel: FloatingPanel?
    private let previewView = NSImageView()

    init(snapshot: ScreenSnapshot, selection: CGRect) {
        self.snapshot = snapshot
        self.selection = selection
    }

    private var globalSelection: CGRect {
        selection.offsetBy(dx: snapshot.screen.frame.minX, dy: snapshot.screen.frame.minY)
    }

    func start() {
        buildHUD()
        buildPreview()
        let scale = snapshot.screen.backingScaleFactor
        processor.previewScale = min(1, (220 * scale) / (selection.width * scale)) // 预览最宽 220pt
        processor.onUpdate = { [weak self] total, preview, result in self?.update(total: total, preview: preview, result: result) }
        processor.onError = { [weak self] error in
            guard let self, !self.finished else { return }
            CaptureCoordinator.showError("长截图中断", error)
            self.finish(.copy)
        }
        Task { @MainActor in
            do {
                try await startStream()
            } catch {
                CaptureCoordinator.showError("无法开始长截图", error)
                self.finished = true
                self.closePanels()
                self.onFinish?(nil, .cancel)
            }
        }
    }

    private func startStream() async throws {
        let filter = try await ScreenSnapshotter.filterExcludingSelf(display: snapshot.display)
        let scale = snapshot.screen.backingScaleFactor
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = ScreenSnapshotter.sourceRect(forLocal: selection, screenHeight: snapshot.screen.frame.height)
        cfg.width = Int((selection.width * scale).rounded())
        cfg.height = Int((selection.height * scale).rounded())
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        cfg.queueDepth = 5
        cfg.captureResolution = .best
        let s = SCStream(filter: filter, configuration: cfg, delegate: processor)
        try s.addStreamOutput(processor, type: .screen, sampleHandlerQueue: processor.queue)
        try await s.startCapture()
        if finished {
            try? await s.stopCapture()
            return
        }
        stream = s
    }

    private func update(total: Int, preview: CGImage?, result: ScrollStitcher.Result) {
        guard !finished, let preview else { return }
        previewView.image = NSImage(cgImage: preview, size: NSSize(width: preview.width, height: preview.height))
        layoutPreview(imageSize: NSSize(width: preview.width, height: preview.height))
    }

    func finish(_ action: ScrollFinishAction) {
        guard !finished else { return }
        finished = true
        stopStream()
        processor.stopAndCompose(action != .cancel) { [weak self] img in
            guard let self else { return }
            self.closePanels()
            self.onFinish?(img, action)
        }
    }

    /// 被外部取消：静默停止，不回调
    func cancel() {
        guard !finished else { return }
        finished = true
        stopStream()
        processor.stopAndCompose(false) { _ in }
        closePanels()
    }

    private func stopStream() {
        guard let s = stream else { return }
        stream = nil
        Task { try? await s.stopCapture() }
    }

    // MARK: - 面板

    /// 选区下方居中的图标工具栏（取消 / 钉图 / 保存 / 完成）
    private func buildHUD() {
        let g = globalSelection
        let screen = snapshot.screen.frame
        let toolbar = ToolbarView(kind: .scrolling)
        toolbar.onCommand = { [weak self] cmd in
            guard let self else { return }
            switch cmd {
            case .cancel: CaptureCoordinator.shared.cancel()
            case .pin: self.finish(.pin)
            case .save: self.finish(.save)
            case .copy: self.finish(.copy)
            default: break
            }
        }
        let size = toolbar.frame.size
        var origin = NSPoint(x: g.midX - size.width / 2, y: g.minY - size.height - 12)
        if origin.y < screen.minY + 6 { origin.y = g.maxY + 12 }
        if origin.y + size.height > screen.maxY - 6 { origin.y = g.minY + 12 }
        origin.x = min(max(origin.x, screen.minX + 6), screen.maxX - size.width - 6)

        let panel = FloatingPanel(rect: NSRect(origin: origin, size: size))
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        toolbar.setFrameOrigin(.zero)
        container.addSubview(toolbar)
        panel.contentView = container
        panel.orderFrontRegardless()
        hud = panel
    }

    /// 选区右侧的长图实时预览（与选区顶部对齐，随长图增长）
    private func buildPreview() {
        let panel = FloatingPanel(rect: NSRect(x: 0, y: 0, width: 10, height: 10))
        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.imageAlignment = .alignTop
        previewView.wantsLayer = true
        previewView.layer?.backgroundColor = NSColor.white.cgColor
        previewView.layer?.borderColor = NSColor(white: 0, alpha: 0.15).cgColor
        previewView.layer?.borderWidth = 0.5
        previewView.autoresizingMask = [.width, .height]
        panel.contentView = previewView
        previewPanel = panel
    }

    private func layoutPreview(imageSize: NSSize) {
        guard let panel = previewPanel, imageSize.width > 0 else { return }
        let g = globalSelection
        let screen = snapshot.screen.frame
        let maxW: CGFloat = 220
        let maxH = g.maxY - (screen.minY + 20)
        var w = min(maxW, g.width * 0.45)
        var h = w * imageSize.height / imageSize.width
        if h > maxH { h = maxH; w = h * imageSize.width / imageSize.height }
        var x = g.maxX + 14
        if x + w > screen.maxX - 6 { x = g.minX - 14 - w }
        if x < screen.minX + 6 { x = screen.maxX - w - 6 }
        let frame = NSRect(x: x, y: g.maxY - h, width: w, height: h)
        panel.setFrame(frame, display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func closePanels() {
        hud?.orderOut(nil)
        hud?.close()
        hud = nil
        previewPanel?.orderOut(nil)
        previewPanel?.close()
        previewPanel = nil
    }

}
