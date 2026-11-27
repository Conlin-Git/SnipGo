import AppKit
import NaturalLanguage
import SnipCore
import Vision

/// 基于 Vision 的离线文字识别
enum TextRecognizer {
    /// 希望支持的识别语言（按优先级）；实际使用时与系统支持的取交集
    static let preferredLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]

    /// 识别图片中的文字，返回排好版的文本（没有文字时返回空字符串）
    static func recognize(_ image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try recognizeSync(image)
        }.value
    }

    private static func recognizeSync(_ source: CGImage) throws -> String {
        // 小字：先放大 2 倍再识别
        let image = source.height < 64 ? (upscaled(source, factor: 2) ?? source) : source
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let languages = preferredLanguages.filter { supported.contains($0) }
        if !languages.isEmpty { request.recognitionLanguages = languages }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        let w = Double(image.width), h = Double(image.height)
        let fragments: [TextFragment] = (request.results ?? []).compactMap { obs in
            guard let text = obs.topCandidates(1).first?.string else { return nil }
            let b = obs.boundingBox   // 归一化坐标，左下角为原点
            return TextFragment(text: text,
                                minX: Double(b.minX) * w, minY: (1 - Double(b.maxY)) * h,
                                maxX: Double(b.maxX) * w, maxY: (1 - Double(b.minY)) * h)
        }
        return TextLayout.compose(fragments)
    }

    private static func upscaled(_ image: CGImage, factor: Int) -> CGImage? {
        let w = image.width * factor, h = image.height * factor
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// 判断文本的主要语言（识别不出时返回 nil）
    static func dominantLanguage(of text: String) -> NLLanguage? {
        let r = NLLanguageRecognizer()
        r.processString(text)
        return r.dominantLanguage
    }
}
