import XCTest
@testable import SnipCore

final class PixelColorTests: XCTestCase {
    func testFormats() {
        let c = PixelColor(r: 26, g: 43, b: 255)
        XCTAssertEqual(c.hex, "#1A2BFF")
        XCTAssertEqual(c.rgb, "RGB(26, 43, 255)")
        XCTAssertEqual(c.string(hex: true), "#1A2BFF")
        XCTAssertEqual(c.string(hex: false), "RGB(26, 43, 255)")
    }

    func testUnpremultiply() {
        XCTAssertEqual(PixelColor(premultipliedR: 10, g: 20, b: 30, a: 255), PixelColor(r: 10, g: 20, b: 30))
        XCTAssertEqual(PixelColor(premultipliedR: 64, g: 0, b: 128, a: 128), PixelColor(r: 128, g: 0, b: 255))
        XCTAssertEqual(PixelColor(premultipliedR: 0, g: 0, b: 0, a: 0), PixelColor(r: 0, g: 0, b: 0))
    }

    func testLightness() {
        XCTAssertTrue(PixelColor(r: 255, g: 255, b: 255).isLight)
        XCTAssertFalse(PixelColor(r: 0, g: 0, b: 0).isLight)
    }
}
