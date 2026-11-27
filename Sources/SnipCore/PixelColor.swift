import Foundation

/// 取色器读到的 sRGB 颜色（0–255）
public struct PixelColor: Equatable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// 从预乘 alpha 的 RGBA 像素还原（截屏像素通常不透明，alpha 为 0 时视为黑色）
    public init(premultipliedR r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        guard a > 0, a < 255 else { self.init(r: a == 0 ? 0 : r, g: a == 0 ? 0 : g, b: a == 0 ? 0 : b); return }
        func un(_ v: UInt8) -> UInt8 { UInt8(min(255, (Int(v) * 255 + Int(a) / 2) / Int(a))) }
        self.init(r: un(r), g: un(g), b: un(b))
    }

    public var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
    public var rgb: String { "RGB(\(r), \(g), \(b))" }

    public func string(hex useHex: Bool) -> String { useHex ? hex : rgb }

    /// 感知亮度，用于决定在色块上画深色还是浅色描边
    public var isLight: Bool { (299 * Int(r) + 587 * Int(g) + 114 * Int(b)) / 1000 > 160 }
}
