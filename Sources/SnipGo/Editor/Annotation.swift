import AppKit
import CoreImage
import CoreText

enum AnnotationTool: Int, CaseIterable {
    case rect, ellipse, line, arrow, pen, mosaic, text, step

    var symbol: String {
        switch self {
        case .rect: return "square"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.left"
        case .pen: return "pencil"
        case .mosaic: return "squareshape.split.3x3"
        case .step: return "1.circle"
        case .text: return "textformat"
        }
    }

    var title: String {
        switch self {
        case .rect: return "矩形"
        case .ellipse: return "椭圆"
        case .line: return "直线"
        case .arrow: return "箭头"
        case .pen: return "画笔"
        case .mosaic: return "马赛克"
        case .step: return "步骤编号"
        case .text: return "文字"
        }
    }

    /// 是否使用颜色
    var usesColor: Bool { self != .mosaic }
}

struct Annotation {
    var tool: AnnotationTool
    var color: NSColor
    var width: CGFloat
    var points: [CGPoint]
    var text: String = ""
    var fontSize: CGFloat = 22
    var number = 0

    var stepDiameter: CGFloat {
        let width = (String(number) as NSString).size(withAttributes: [.font: stepFont]).width
        return ceil(max(fontSize * 1.55, width + 9))
    }

    var stepFont: NSFont { .monospacedDigitSystemFont(ofSize: fontSize, weight: .heavy) }

    var isMeaningful: Bool {
        switch tool {
        case .step: return !points.isEmpty
        case .pen, .mosaic: return points.count > 1
        case .text: return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            guard let a = points.first, let b = points.last else { return false }
            return hypot(a.x - b.x, a.y - b.y) > 3
        }
    }

    /// 只命中空心图形的轮廓，让用户仍能在圈内继续标注。
    var hitPath: CGPath {
        guard let a = points.first, let b = points.last else { return CGMutablePath() }
        let tolerance: CGFloat = 4
        let box = AnnotationRenderer.rect(a, b)
        let path: CGPath
        switch tool {
        case .text:
            let size = (text as NSString).size(withAttributes: Self.textAttributes(fontSize: fontSize, color: color))
            return CGPath(rect: CGRect(origin: a, size: size).insetBy(dx: -tolerance, dy: -tolerance), transform: nil)
        case .step:
            let radius = stepDiameter / 2 + tolerance
            return CGPath(ellipseIn: CGRect(x: a.x - radius, y: a.y - radius, width: 2 * radius, height: 2 * radius), transform: nil)
        case .rect: path = CGPath(rect: box, transform: nil)
        case .ellipse: path = CGPath(ellipseIn: box, transform: nil)
        case .pen, .mosaic: path = AnnotationRenderer.smoothPath(points)
        case .line, .arrow:
            let line = CGMutablePath()
            line.move(to: a)
            line.addLine(to: b)
            path = line
        }
        let stroke = path.copy(strokingWithWidth: width + 2 * tolerance, lineCap: .round, lineJoin: .round, miterLimit: 10)
        if tool == .arrow, let head = AnnotationRenderer.arrowHead(from: a, to: b, width: width) {
            return stroke.union(head.path)
        }
        return stroke
    }

    static func textAttributes(fontSize: CGFloat, color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: color]
    }
}

/// 屏幕绘制与导出共用的渲染器（坐标系：非翻转，单位 pt）
enum AnnotationRenderer {
    /// - Parameters:
    ///   - mosaic: 马赛克底图（覆盖整屏，绘制到 imageRect）
    static func draw(_ a: Annotation, in ctx: CGContext, mosaic: CGImage?, imageRect: CGRect) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(a.width)

        guard let p0 = a.points.first, let p1 = a.points.last else { return }
        switch a.tool {
        case .rect:
            ctx.stroke(rect(p0, p1))
        case .ellipse:
            ctx.strokeEllipse(in: rect(p0, p1))
        case .line:
            ctx.move(to: p0)
            ctx.addLine(to: p1)
            ctx.strokePath()
        case .arrow:
            drawArrow(from: p0, to: p1, width: a.width, in: ctx)
        case .pen:
            ctx.addPath(smoothPath(a.points))
            ctx.strokePath()
        case .mosaic:
            guard let mosaic else { return }
            ctx.addPath(smoothPath(a.points))
            ctx.setLineWidth(a.width)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            ctx.interpolationQuality = .none
            ctx.draw(mosaic, in: imageRect)
        case .step:
            drawStep(a, at: p0, in: ctx)
        case .text:
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            NSAttributedString(string: a.text, attributes: Annotation.textAttributes(fontSize: a.fontSize, color: a.color))
                .draw(at: p0)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private static func drawStep(_ a: Annotation, at point: CGPoint, in ctx: CGContext) {
        let diameter = a.stepDiameter
        let bounds = CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2,
                            width: diameter, height: diameter)
        ctx.setFillColor(NSColor(white: 0, alpha: 0.62).cgColor)
        ctx.fillEllipse(in: bounds)
        let isRed = a.color == AnnotationPalette.colors[0]
        let fill = isRed ? NSColor(srgbRed: 0.79, green: 0.12, blue: 0.16, alpha: 1) : a.color
        ctx.setFillColor(fill.cgColor)
        ctx.fillEllipse(in: bounds.insetBy(dx: 0.75, dy: 0.75))

        let brightness = fill.usingColorSpace(.genericGray)?.whiteComponent ?? 0
        let ink: NSColor = isRed || brightness < 0.58 ? .white : .black
        let label = NSAttributedString(string: String(a.number), attributes: [.font: a.stepFont, .foregroundColor: ink])
        let line = CTLineCreateWithAttributedString(label)
        // Center the actual numeral outline, which excludes ascender and descender padding.
        let glyphs = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: point.x - glyphs.midX, y: point.y - glyphs.midY)
        CTLineDraw(line, ctx)
    }

    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func smoothPath(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count == 1 {
            path.addLine(to: first)
            return path
        }
        for i in 1..<pts.count {
            let prev = pts[i - 1], cur = pts[i]
            let mid = CGPoint(x: (prev.x + cur.x) / 2, y: (prev.y + cur.y) / 2)
            path.addQuadCurve(to: mid, control: prev)
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }

    static func arrowHead(from s: CGPoint, to e: CGPoint, width: CGFloat) -> (base: CGPoint, path: CGPath)? {
        let len = hypot(e.x - s.x, e.y - s.y)
        guard len > 0.5 else { return nil }
        let angle = atan2(e.y - s.y, e.x - s.x)
        let headLen = min(max(14, width * 4.5), len * 0.8)
        let headW = headLen * 0.8
        let base = CGPoint(x: e.x - cos(angle) * headLen * 0.85, y: e.y - sin(angle) * headLen * 0.85)
        let back = CGPoint(x: e.x - cos(angle) * headLen, y: e.y - sin(angle) * headLen)
        let perp = CGPoint(x: -sin(angle), y: cos(angle))
        let path = CGMutablePath()
        path.move(to: e)
        path.addLine(to: CGPoint(x: back.x + perp.x * headW / 2, y: back.y + perp.y * headW / 2))
        path.addLine(to: CGPoint(x: back.x - perp.x * headW / 2, y: back.y - perp.y * headW / 2))
        path.closeSubpath()
        return (base, path)
    }

    static func drawArrow(from s: CGPoint, to e: CGPoint, width: CGFloat, in ctx: CGContext) {
        guard let head = arrowHead(from: s, to: e, width: width) else { return }
        ctx.move(to: s)
        ctx.addLine(to: head.base)
        ctx.strokePath()
        ctx.addPath(head.path)
        ctx.fillPath()
    }

    /// 生成整张截图的马赛克底图
    static func makeMosaic(from image: CGImage, blockPixels: CGFloat) -> CGImage? {
        let ci = CIImage(cgImage: image)
        let out = ci.clampedToExtent()
            .applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: blockPixels,
                kCIInputCenterKey: CIVector(x: 0, y: 0),
            ])
            .cropped(to: ci.extent)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        return ctx.createCGImage(out, from: ci.extent, format: .RGBA8, colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}
