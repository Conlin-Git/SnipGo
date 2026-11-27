import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ImageOutput {
    static let soundPath = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"

    static func playCaptureSound() {
        guard AppSettings.playSound else { return }
        if let s = NSSound(contentsOfFile: soundPath, byReference: true) { s.play() } else { NSSound(named: "Pop")?.play() }
    }

    /// 生成不重名的文件 URL
    static func uniqueURL(ext: String) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let base = AppSettings.filePrefix + f.string(from: Date())
        let dir = AppSettings.saveDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir.appendingPathComponent("\(base).\(ext)")
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)_\(n).\(ext)")
            n += 1
        }
        return url
    }

    /// 按偏好格式保存，返回文件 URL
    @discardableResult
    static func save(_ image: CGImage) -> URL? {
        let isJPG = AppSettings.imageFormat == "jpg"
        let url = uniqueURL(ext: isJPG ? "jpg" : "png")
        let type = (isJPG ? UTType.jpeg : UTType.png).identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        var img = image
        if isJPG {
            props[kCGImageDestinationLossyCompressionQuality] = 0.92
            img = flattened(image) ?? image
        }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return url
    }

    static func copyToPasteboard(_ image: CGImage, pointSize: NSSize? = nil) {
        let size = pointSize ?? NSSize(width: image.width, height: image.height)
        let ns = NSImage(cgImage: image, size: size)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([ns])
        if let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            pb.setData(png, forType: .png)
        }
    }

    /// JPG 不支持透明：铺白底
    private static func flattened(_ image: CGImage) -> CGImage? {
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}
