import AppKit
import CoreImage

/// 在录制队列上采样鼠标；启动时在主线程准备 AppKit 的手型图片。
final class RecordingPointer {
    struct State: Equatable {
        var position: CGPoint?
        var pressed = false
    }

    private let region: CGRect
    private let primaryHeight: CGFloat
    private let showsHand: Bool
    private var previousClickCount: UInt32
    private let hand: CIImage
    private let hotSpot: CGPoint
    private let dot: CIImage

    private static var clickCount: UInt32 {
        [.leftMouseDown, .rightMouseDown, .otherMouseDown].reduce(0) {
            $0 &+ CGEventSource.counterForEventType(.combinedSessionState, eventType: $1)
        }
    }

    @MainActor
    init(region: CGRect, showsHand: Bool) {
        self.region = region
        self.showsHand = showsHand
        primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        previousClickCount = Self.clickCount
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

    func sample() -> State {
        let count = Self.clickCount
        let pressed = count != previousClickCount || NSEvent.pressedMouseButtons != 0
        previousClickCount = count
        guard (showsHand || pressed), let location = CGEvent(source: nil)?.location else { return State() }
        let mouse = CGPoint(x: location.x, y: primaryHeight - location.y)
        guard region.contains(mouse) else { return State() }
        return State(position: CGPoint(x: mouse.x - region.minX, y: mouse.y - region.minY), pressed: pressed)
    }

    func frame(_ source: CIImage, state: State) -> CIImage {
        guard let point = state.position else { return source }
        let image = state.pressed ? dot : hand
        let anchor = state.pressed ? CGPoint(x: dot.extent.midX, y: dot.extent.midY) : hotSpot
        let bounds = source.extent
        let sx = bounds.width / region.width
        let sy = bounds.height / region.height
        let transform = CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
                                          tx: bounds.minX + (point.x - anchor.x) * sx,
                                          ty: bounds.minY + (point.y - anchor.y) * sy)
        return image.transformed(by: transform).composited(over: source).cropped(to: bounds)
    }
}
