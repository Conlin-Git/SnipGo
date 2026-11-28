import CoreGraphics
import XCTest
@testable import SnipCore

final class ScrollStitcherTests: XCTestCase {
    let W = 400

    // 伪随机，保证可复现
    struct LCG {
        var s: UInt64
        mutating func next() -> Int { s = s &* 6364136223846793005 &+ 1442695040888963407; return Int((s >> 33) & 0x7fffffff) }
    }

    /// 生成类似网页的内容：白底 + 文字行（含空白段落）
    func makeContent(height: Int, seed: UInt64) -> [UInt8] {
        var rng = LCG(s: seed)
        var px = [UInt8](repeating: 255, count: W * height * 4)
        var y = 10
        while y < height - 20 {
            if rng.next() % 9 == 0 { y += 60 + rng.next() % 80; continue } // 段落空白
            let lineH = 10 + rng.next() % 6
            var x = 12
            while x < W - 30 {
                let wordW = 8 + rng.next() % 50
                let tone = UInt8(20 + rng.next() % 120)
                for yy in y..<min(height, y + lineH) {
                    for xx in x..<min(W, x + wordW) where (xx * 7 + yy * 3 + rng.next()) % 3 != 0 {
                        let o = (yy * W + xx) * 4
                        px[o] = tone; px[o + 1] = tone &+ 10; px[o + 2] = tone &+ 20; px[o + 3] = 255
                    }
                }
                x += wordW + 6 + rng.next() % 8
            }
            y += lineH + 8 + rng.next() % 10
        }
        return px
    }

    func bar(height: Int, tone: UInt8) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: W * height * 4)
        for y in 0..<height {
            for x in 0..<W {
                let o = (y * W + x) * 4
                let v: UInt8 = (x / 20 + y / 10) % 2 == 0 ? tone : tone &+ 60
                px[o] = v; px[o + 1] = v; px[o + 2] = v &+ 30; px[o + 3] = 255
            }
        }
        return px
    }

    func rows(_ src: [UInt8], _ from: Int, _ count: Int) -> [UInt8] {
        Array(src[(from * W * 4)..<((from + count) * W * 4)])
    }

    func image(_ px: [UInt8], height: Int) -> CGImage {
        let data = Data(px) as CFData
        return CGImage(width: W, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    func pixels(_ img: CGImage) -> [UInt8] {
        let f = CGImageFrame(img)
        return f.withBGRA { p, bpr in
            var out = [UInt8](); out.reserveCapacity(img.width * img.height * 4)
            for y in 0..<img.height { out.append(contentsOf: UnsafeBufferPointer(start: p + y * bpr, count: img.width * 4)) }
            return out
        }
    }

    func testStitchWithStickyHeaderAndFooter() throws {
        let contentH = 3000, headerH = 40, footerH = 30, frameH = 300
        let band = frameH - headerH - footerH
        let content = makeContent(height: contentH, seed: 42)
        let header = bar(height: headerH, tone: 60)
        let footer = bar(height: footerH, tone: 120)

        func frame(at offset: Int) -> CGImage {
            image(header + rows(content, offset, band) + footer, height: frameH)
        }

        let st = ScrollStitcher()
        XCTAssertEqual(st.process(CGImageFrame(frame(at: 0))), .first)
        XCTAssertEqual(st.process(CGImageFrame(frame(at: 0))), .unchanged)

        var offset = 0
        // 真实采集为 30fps，单帧位移远小于可视高度；重叠区需大于最长空白段落
        let steps = [37, 90, 3, 80, 61, 88, 1, 88, 70, 85, 75, 60, 89, 50, 90, 40, 77, 66, 90, 12, 85, 90, 64]
        for s in steps {
            offset += s
            if offset + band > contentH { break }
            let r = st.process(CGImageFrame(frame(at: offset)))
            XCTAssertEqual(r, .appended(s), "offset \(offset)")
        }
        // 向上滚：拒绝；再滚回原处：无变化
        XCTAssertNotEqual(st.process(CGImageFrame(frame(at: offset - 50))), .appended(50))
        XCTAssertEqual(st.process(CGImageFrame(frame(at: offset))), .unchanged)

        XCTAssertEqual(st.fixedTop, headerH)
        XCTAssertEqual(st.fixedBottom, footerH)

        let out = try XCTUnwrap(st.compose())
        let expectedH = headerH + offset + band + footerH
        XCTAssertEqual(out.height, expectedH)
        XCTAssertEqual(out.width, W)
        let expected = header + rows(content, 0, offset + band) + footer
        XCTAssertTrue(pixels(out) == expected, "像素不一致")

        let preview = try XCTUnwrap(st.compose(scale: 0.25))
        XCTAssertEqual(preview.width, W / 4)
    }

    func testPreviewHasNoSeamsBetweenThinStrips() throws {
        let content = makeContent(height: 1000, seed: 7)
        let stitcher = ScrollStitcher()
        let frameHeight = 360
        var offset = 0
        stitcher.process(CGImageFrame(image(rows(content, offset, frameHeight), height: frameHeight)))
        for step in [3, 7, 13, 4, 1, 8, 19, 2, 12, 5, 11, 23, 1] {
            offset += step
            XCTAssertEqual(stitcher.process(CGImageFrame(image(rows(content, offset, frameHeight), height: frameHeight))), .appended(step))
        }
        // 源图有不透明的白边，缩小后每一行仍应完全覆盖。
        for scale in [0.17, 0.253, 0.55] {
            let preview = try XCTUnwrap(stitcher.compose(scale: scale))
            let data = pixels(preview)
            let gaps = (0..<preview.height).filter { row in
                let index = (row * preview.width + 1) * 4
                return data[index + 3] != 255
            }
            XCTAssertTrue(gaps.isEmpty, "scale=\(scale), uncovered rows=\(gaps)")
        }
    }

    func testStitchPlainContent() throws {
        let contentH = 2400, frameH = 360
        let content = makeContent(height: contentH, seed: 7)
        let st = ScrollStitcher()
        var offset = 0
        st.process(CGImageFrame(image(rows(content, 0, frameH), height: frameH)))
        while offset + 110 + frameH <= contentH {
            offset += 110
            XCTAssertEqual(st.process(CGImageFrame(image(rows(content, offset, frameH), height: frameH))), .appended(110))
        }
        let out = try XCTUnwrap(st.compose())
        XCTAssertTrue(pixels(out) == rows(content, 0, offset + frameH), "像素不一致")
    }

    /// 超过可视高度的大段空白：无法判断位移时压缩空白，但必须能继续拼接后续内容
    func testLongBlankGapDoesNotStall() throws {
        var content = makeContent(height: 1000, seed: 11)
        content += [UInt8](repeating: 255, count: W * 600 * 4)
        content += makeContent(height: 1000, seed: 12)
        let st = ScrollStitcher()
        st.process(CGImageFrame(image(rows(content, 0, 300), height: 300)))
        var offset = 0
        var appendedAfterGap = false
        while offset + 60 + 300 <= 2600 {
            offset += 60
            if case .appended = st.process(CGImageFrame(image(rows(content, offset, 300), height: 300))), offset > 1700 {
                appendedAfterGap = true
            }
        }
        XCTAssertTrue(appendedAfterGap)
        XCTAssertGreaterThan(st.totalHeight, 2000)
    }

    func testTooFastScrollIsRejected() {
        let content = makeContent(height: 2000, seed: 3)
        let st = ScrollStitcher()
        st.process(CGImageFrame(image(rows(content, 0, 300), height: 300)))
        // 跳过整整一屏，没有重叠
        let r = st.process(CGImageFrame(image(rows(content, 600, 300), height: 300)))
        XCTAssertEqual(r, .rejected)
    }

    func testHeightLimit() {
        let content = makeContent(height: 2000, seed: 9)
        let st = ScrollStitcher(maxHeight: 500)
        st.process(CGImageFrame(image(rows(content, 0, 300), height: 300)))
        XCTAssertEqual(st.process(CGImageFrame(image(rows(content, 150, 300), height: 300))), .appended(150))
        XCTAssertEqual(st.process(CGImageFrame(image(rows(content, 300, 300), height: 300))), .limitReached)
        XCTAssertEqual(st.totalHeight, 500)
    }
}
