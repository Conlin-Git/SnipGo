// 生成 SnipGo 应用图标：苹果风白色圆角方块 + 红色剪刀（Resources/AppIconSource.png）
// 用法: swift scripts/make_icon.swift <剪刀源图.png> <输出的 .iconset 目录>
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: make_icon.swift <source.png> <out.iconset>")
    exit(1)
}
guard let srcImage = NSImage(contentsOfFile: args[1]),
      let glyph = srcImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("无法读取源图: \(args[1])")
    exit(1)
}
let outDir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(size px: Int) -> Data? {
    let s = CGFloat(px)
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let unit = s / 1024
    // macOS 图标网格：主体 824x824，居中
    let body = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    let corner = 185 * unit
    let bodyPath = CGPath(roundedRect: body, cornerWidth: corner, cornerHeight: corner, transform: nil)

    // 投影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * unit), blur: 28 * unit,
                  color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(bodyPath)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // 白色底：轻微上亮下暗
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                        colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 0.94, alpha: 1)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    ctx.restoreGState()

    // 剪刀：居中，占主体约 70%，带轻微投影
    let side = 580 * unit
    let glyphRect = CGRect(x: body.midX - side / 2, y: body.midY - side / 2, width: side, height: side)
    ctx.saveGState()
    ctx.interpolationQuality = .high
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * unit), blur: 18 * unit,
                  color: CGColor(srgbRed: 0.8, green: 0.1, blue: 0.15, alpha: 0.22))
    ctx.draw(glyph, in: glyphRect)
    ctx.restoreGState()

    guard let img = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    guard let data = render(size: px) else { fatalError("render failed") }
    try data.write(to: outDir.appendingPathComponent("\(name).png"))
}
print("iconset written to \(outDir.path)")
