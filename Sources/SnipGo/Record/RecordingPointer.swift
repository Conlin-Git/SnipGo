import AppKit
import AVFoundation
import CoreImage

/// 只保存录制区域内指针的变化，使用与屏幕采样帧相同的主机时钟。
@MainActor
final class RecordingPointer {
    struct Sample {
        let time: Double
        let position: CGPoint?
        let pressed: Bool
    }

    private let region: CGRect
    private let showsHand: Bool
    private var timer: Timer?
    private var samples: [Sample] = []
    private var previousClickCount: UInt32 = 0

    init(region: CGRect, showsHand: Bool) {
        self.region = region
        self.showsHand = showsHand
    }

    // 计数器也能捕获在两次采样之间已经松开的短点击。
    private var clickCount: UInt32 {
        [.leftMouseDown, .rightMouseDown, .otherMouseDown].reduce(0) {
            $0 &+ CGEventSource.counterForEventType(.combinedSessionState, eventType: $1)
        }
    }

    func start() {
        previousClickCount = clickCount
        sample()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        let mouse = NSEvent.mouseLocation
        let count = clickCount
        let pressed = NSEvent.pressedMouseButtons != 0 || count != previousClickCount
        previousClickCount = count
        let visible = region.contains(mouse) && (showsHand || pressed)
        let position = visible ? CGPoint(x: mouse.x - region.minX, y: mouse.y - region.minY) : nil
        let dot = visible && pressed
        guard samples.last?.position != position || samples.last?.pressed != dot else { return }
        samples.append(Sample(time: CMClockGetTime(CMClockGetHostTimeClock()).seconds,
                              position: position, pressed: dot))
    }

    func finishVideo(at url: URL, firstFrameTime: Double) async throws {
        guard samples.contains(where: { $0.position != nil }) else { return }
        let asset = AVURLAsset(url: url)
        let renderer = PointerRenderer(regionSize: region.size, samples: samples, firstFrameTime: firstFrameTime)
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: { request in
            request.finish(with: renderer.frame(request.sourceImage, at: request.compositionTime.seconds), context: nil)
        })
        // 即使桌面静止，手型移动和短点击也按 60 fps 输出。
        composition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        composition.frameDuration = CMTime(value: 1, timescale: 60)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw CocoaError(.featureUnsupported)
        }
        export.videoComposition = composition
        let temp = url.deletingLastPathComponent().appendingPathComponent(".snipgo-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temp) }
        try await export.export(to: temp, as: .mp4)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }
}

struct PointerRenderer {
    let regionSize: CGSize
    let samples: [RecordingPointer.Sample]
    let firstFrameTime: Double
    private let hand: CIImage
    private let hotSpot: CGPoint
    private let dot: CIImage

    @MainActor
    init(regionSize: CGSize, samples: [RecordingPointer.Sample], firstFrameTime: Double) {
        self.regionSize = regionSize
        self.samples = samples
        self.firstFrameTime = firstFrameTime
        let cursor = NSCursor.pointingHand
        let size = cursor.image.size
        hotSpot = CGPoint(x: cursor.hotSpot.x, y: size.height - cursor.hotSpot.y)
        // 使用矢量绘图上下文的两倍分辨率，光标尺寸仍以屏幕点计。
        func sprite(size: CGSize, draw: (CGContext) -> Void) -> CIImage {
            let context = CGContext(data: nil, width: Int(ceil(size.width * 2)), height: Int(ceil(size.height * 2)),
                                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.scaleBy(x: 2, y: 2)
            draw(context)
            return CIImage(cgImage: context.makeImage()!).transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        }
        hand = sprite(size: size) { context in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            cursor.image.draw(in: CGRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
        }
        let dotSize = CGSize(width: 16, height: 16)
        dot = sprite(size: dotSize) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fillEllipse(in: CGRect(origin: .zero, size: dotSize))
        }
    }

    func frame(_ source: CIImage, at seconds: Double) -> CIImage {
        let time = firstFrameTime + seconds
        var low = 0
        var high = samples.count
        while low < high {
            let mid = low + (high - low) / 2
            if samples[mid].time <= time { low = mid + 1 } else { high = mid }
        }
        guard low > 0, let point = samples[low - 1].position else { return source }
        let pressed = samples[low - 1].pressed
        let image = pressed ? dot : hand
        let anchor = pressed ? CGPoint(x: dot.extent.midX, y: dot.extent.midY) : hotSpot
        let bounds = source.extent
        let sx = bounds.width / regionSize.width
        let sy = bounds.height / regionSize.height
        let transform = CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
                                          tx: bounds.minX + (point.x - anchor.x) * sx,
                                          ty: bounds.minY + (point.y - anchor.y) * sy)
        return image.transformed(by: transform).composited(over: source).cropped(to: bounds)
    }
}
