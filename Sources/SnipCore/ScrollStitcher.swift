import CoreGraphics
import CoreVideo
import Foundation

/// 一帧 BGRA 图像的抽象，便于用 CVPixelBuffer（实际采集）和 CGImage（单测）两种来源。
public protocol StitchFrame {
    var width: Int { get }
    var height: Int { get }
    /// 以 BGRA 8bit 形式访问像素，第 0 行为图像顶部。
    func withBGRA<R>(_ body: (UnsafePointer<UInt8>, Int) -> R) -> R
    /// 生成该帧的 CGImage（仅在帧被接受时调用）。
    func makeCGImage() -> CGImage?
}

/// 滚动长图拼接器。非线程安全：所有调用须在同一串行队列上。
public final class ScrollStitcher: @unchecked Sendable {
    public enum Result: Equatable {
        case first          // 第一帧
        case unchanged      // 未滚动
        case appended(Int)  // 追加了 n 行
        case rejected       // 无法匹配（滚动过快 / 向上滚 / 动态内容）
        case limitReached   // 达到高度上限
    }

    struct Features {
        static let blocks = 32
        let rows: Int
        var values: [Float]     // rows * blocks，每个列块的平均亮度
        var detail: [Bool]      // 该行是否“有内容”
    }

    public let maxHeight: Int
    public private(set) var frameWidth = 0
    public private(set) var frameHeight = 0
    public private(set) var fixedTop = 0
    public private(set) var fixedBottom = 0

    private var head: CGImage?
    private var strips: [CGImage] = []
    private var footer: CGImage?
    private var last: Features?
    private var locked = false
    private var stripRows = 0

    /// 行匹配阈值：各列块平均亮度差的均值
    private let rowThreshold: Float = 1.5
    /// 行“有内容”阈值：相邻采样点亮度差均值
    private let detailThreshold: Float = 1.2

    public init(maxHeight: Int = 50_000) {
        self.maxHeight = maxHeight
    }

    /// 当前拼接结果的总高度（像素）。
    public var totalHeight: Int {
        guard head != nil else { return 0 }
        if stripRows == 0 { return frameHeight }
        return frameHeight - fixedBottom + stripRows + (footer?.height ?? 0)
    }

    public var isEmpty: Bool { head == nil }

    // MARK: - 处理一帧

    @discardableResult
    public func process(_ frame: StitchFrame) -> Result {
        let feats = Self.extract(frame, detailThreshold: detailThreshold)
        guard let prev = last, head != nil else {
            guard let img = frame.makeCGImage() else { return .rejected }
            head = img.copyPixels()
            frameWidth = frame.width
            frameHeight = frame.height
            last = feats
            return .first
        }
        guard frame.width == frameWidth, frame.height == frameHeight else { return .rejected }
        if totalHeight >= maxHeight { return .limitReached }

        let H = frameHeight
        var top = fixedTop, bottom = fixedBottom
        if !locked {
            // 完全相同 → 没滚动
            var same = true
            for i in 0..<H where rowDiff(prev, i, feats, i) >= rowThreshold { same = false; break }
            if same { return .unchanged }
            (top, bottom) = detectFixed(prev, feats)
        }

        guard let dy = findOffset(prev, feats, top: top, bottom: bottom) else { return .rejected }
        if dy == 0 { return .unchanged }

        if !locked {
            fixedTop = top
            fixedBottom = bottom
            locked = true
        }

        guard let img = frame.makeCGImage() else { return .rejected }
        let end = H - fixedBottom
        let add = min(dy, maxHeight - totalHeight)
        guard add > 0 else { return .limitReached }
        let stripRect = CGRect(x: 0, y: end - add, width: frameWidth, height: add)
        guard let strip = img.cropping(to: stripRect)?.copyPixels() else { return .rejected }
        strips.append(strip)
        stripRows += add
        if fixedBottom > 0 {
            footer = img.cropping(to: CGRect(x: 0, y: end, width: frameWidth, height: fixedBottom))?.copyPixels()
        }
        last = feats
        return add < dy ? .limitReached : .appended(add)
    }

    // MARK: - 合成

    /// 合成完整长图；scale < 1 时生成缩略预览。
    public func compose(scale: CGFloat = 1) -> CGImage? {
        guard let head else { return nil }
        let total = totalHeight
        let outW = max(1, Int((CGFloat(frameWidth) * scale).rounded()))
        let outH = max(1, Int((CGFloat(total) * scale).rounded()))
        let space = head.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            ?? CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = scale < 1 ? .medium : .none

        // 从顶部累计源图行数，共享取整后的目标边界，避免相邻条带各自覆盖半个像素。
        var sourceEnd = 0
        var targetEnd = 0
        func draw(_ img: CGImage) {
            sourceEnd += img.height
            let start = targetEnd
            targetEnd = (sourceEnd * outH + total / 2) / total
            guard targetEnd > start else { return }
            ctx.draw(img, in: CGRect(x: 0, y: outH - targetEnd, width: outW, height: targetEnd - start))
        }
        if stripRows == 0 {
            draw(head)
        } else {
            let headRows = frameHeight - fixedBottom
            if let top = head.cropping(to: CGRect(x: 0, y: 0, width: frameWidth, height: headRows)) {
                draw(top)
            }
            strips.forEach(draw)
            if let footer { draw(footer) }
        }
        return ctx.makeImage()
    }

    // MARK: - 特征与匹配

    static func extract(_ frame: StitchFrame, detailThreshold: Float) -> Features {
        let W = frame.width, H = frame.height
        let B = Features.blocks
        var values = [Float](repeating: 0, count: H * B)
        var detail = [Bool](repeating: false, count: H)
        let step = W > 800 ? 3 : 2
        frame.withBGRA { base, bpr in
            for y in 0..<H {
                let row = base + y * bpr
                var sums = [Float](repeating: 0, count: B)
                var counts = [Int](repeating: 0, count: B)
                var prevL: Int = -1
                var edge = 0
                var samples = 0
                var x = 0
                while x < W {
                    let p = row + x * 4
                    let l = (Int(p[2]) * 77 + Int(p[1]) * 150 + Int(p[0]) * 29) >> 8
                    let b = min(B - 1, x * B / W)
                    sums[b] += Float(l)
                    counts[b] += 1
                    if prevL >= 0 { edge += abs(l - prevL) }
                    prevL = l
                    samples += 1
                    x += step
                }
                for b in 0..<B {
                    values[y * B + b] = counts[b] > 0 ? sums[b] / Float(counts[b]) : 0
                }
                detail[y] = samples > 1 && Float(edge) / Float(samples - 1) > detailThreshold
            }
        }
        return Features(rows: H, values: values, detail: detail)
    }

    @inline(__always)
    func rowDiff(_ a: Features, _ ia: Int, _ b: Features, _ ib: Int) -> Float {
        let B = Features.blocks
        var s: Float = 0
        a.values.withUnsafeBufferPointer { av in
            b.values.withUnsafeBufferPointer { bv in
                let oa = ia * B, ob = ib * B
                for k in 0..<B { s += abs(av[oa + k] - bv[ob + k]) }
            }
        }
        return s / Float(B)
    }

    /// 首尾连续相同且含内容的行 → 吸顶 / 吸底区域
    func detectFixed(_ a: Features, _ b: Features) -> (Int, Int) {
        let H = a.rows
        let cap = H / 3
        var top = 0, topInfo = false
        while top < cap, rowDiff(a, top, b, top) < rowThreshold {
            if a.detail[top] { topInfo = true }
            top += 1
        }
        var bottom = 0, bottomInfo = false
        while bottom < cap, rowDiff(a, H - 1 - bottom, b, H - 1 - bottom) < rowThreshold {
            if a.detail[H - 1 - bottom] { bottomInfo = true }
            bottom += 1
        }
        return (topInfo ? top : 0, bottomInfo ? bottom : 0)
    }

    /// 在中间带内寻找位移 dy：当前帧第 i 行 ↔ 上一帧第 i+dy 行
    func findOffset(_ prev: Features, _ cur: Features, top: Int, bottom: Int) -> Int? {
        let start = top, end = prev.rows - bottom
        let band = end - start
        guard band >= 24 else { return nil }
        let minOverlap = max(8, band / 8)
        // 选择不匹配行最少的位移；相同时取匹配到的“有内容行”最多者
        var best: (dy: Int, mis: Int, score: Int)? = nil
        var ambiguous: [Int] = []

        for dy in 0...(band - minOverlap) {
            let overlap = band - dy
            var allowed = max(2, overlap / 50)
            if let b = best, b.mis < allowed { allowed = b.mis }
            var mismatched = 0, score = 0
            var i = start
            while i < end - dy {
                let j = i + dy
                if rowDiff(prev, j, cur, i) < rowThreshold {
                    if prev.detail[j] { score += 1 }
                } else {
                    mismatched += 1
                    if mismatched > allowed { break }
                }
                i += 1
            }
            guard mismatched <= allowed else { continue }
            if score == 0 {
                if mismatched == 0 { ambiguous.append(dy) }
            } else if score >= 3 {
                if let b = best, (mismatched > b.mis || (mismatched == b.mis && score <= b.score)) { continue }
                best = (dy, mismatched, score)
            }
        }

        if let best { return best.dy }
        // 重叠区全是空白：若当前帧带有新内容，取最小可行位移（压缩空白）
        if let dmin = ambiguous.first(where: { $0 > 0 }) {
            var curHasContent = false
            for i in start..<end where cur.detail[i] { curHasContent = true; break }
            if curHasContent { return dmin }
        }
        if ambiguous.first == 0 { return 0 }
        return nil
    }
}

// MARK: - 帧来源实现

/// 实际采集：ScreenCaptureKit 输出的 BGRA CVPixelBuffer
public struct PixelBufferFrame: StitchFrame {
    public let buffer: CVPixelBuffer
    let makeImage: (CVPixelBuffer) -> CGImage?

    public init(buffer: CVPixelBuffer, makeImage: @escaping (CVPixelBuffer) -> CGImage?) {
        self.buffer = buffer
        self.makeImage = makeImage
    }

    public var width: Int { CVPixelBufferGetWidth(buffer) }
    public var height: Int { CVPixelBufferGetHeight(buffer) }

    public func withBGRA<R>(_ body: (UnsafePointer<UInt8>, Int) -> R) -> R {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        return body(UnsafePointer(base), CVPixelBufferGetBytesPerRow(buffer))
    }

    public func makeCGImage() -> CGImage? { makeImage(buffer) }
}

/// 单测 / 通用：CGImage 帧
public struct CGImageFrame: StitchFrame {
    public let image: CGImage
    private let bytes: [UInt8]
    private let bpr: Int

    public init(_ image: CGImage) {
        self.image = image
        let w = image.width, h = image.height
        bpr = w * 4
        var data = [UInt8](repeating: 0, count: bpr * h)
        data.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        bytes = data
    }

    public var width: Int { image.width }
    public var height: Int { image.height }

    public func withBGRA<R>(_ body: (UnsafePointer<UInt8>, Int) -> R) -> R {
        bytes.withUnsafeBufferPointer { body($0.baseAddress!, bpr) }
    }

    public func makeCGImage() -> CGImage? { image }
}

extension CGImage {
    /// 深拷贝像素，释放对原始整帧缓冲的引用。
    func copyPixels() -> CGImage? {
        let space = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info)
            ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)
        else { return nil }
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
