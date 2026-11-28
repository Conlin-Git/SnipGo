import XCTest
@testable import SnipCore

final class TextLayoutTests: XCTestCase {

    /// 生成一行：每个字宽 w、高 h
    private func frag(_ text: String, x: Double, y: Double, charWidth: Double = 10, h: Double = 20) -> TextFragment {
        TextFragment(text: text, minX: x, minY: y, maxX: x + Double(text.count) * charWidth, maxY: y + h)
    }

    func testLinesSortedTopToBottomAndLeftToRight() {
        let items = [
            frag("world", x: 70, y: 0),
            frag("second line", x: 0, y: 26),
            frag("hello", x: 0, y: 2),     // 与 world 同一行，略有错位
        ]
        XCTAssertEqual(TextLayout.compose(items), "hello world\nsecond line")
    }

    func testChineseFragmentsJoinWithoutSpace() {
        let items = [frag("今天天气", x: 0, y: 0, charWidth: 20), frag("很好", x: 82, y: 0, charWidth: 20)]
        XCTAssertEqual(TextLayout.compose(items), "今天天气很好")
    }

    func testMixedChineseEnglishKeepsSpace() {
        let items = [frag("使用", x: 0, y: 0, charWidth: 20), frag("SwiftUI", x: 50, y: 0)]
        XCTAssertEqual(TextLayout.compose(items), "使用 SwiftUI")
    }

    func testParagraphGapProducesBlankLine() {
        let items = [
            frag("line one", x: 0, y: 0),
            frag("line two", x: 0, y: 26),
            frag("next para", x: 0, y: 80),
            frag("last line", x: 0, y: 106),
        ]
        XCTAssertEqual(TextLayout.compose(items), "line one\nline two\n\nnext para\nlast line")
    }

    func testTwoColumnsReadColumnByColumn() {
        var items: [TextFragment] = []
        for i in 0..<4 {
            items.append(frag("left column text \(i)", x: 0, y: Double(i) * 26))
            items.append(frag("right column txt \(i)", x: 300, y: Double(i) * 26))
        }
        XCTAssertEqual(TextLayout.compose(items),
                       "left column text 0\nleft column text 1\nleft column text 2\nleft column text 3\n\n"
                       + "right column txt 0\nright column txt 1\nright column txt 2\nright column txt 3")
    }

    func testTableIsNotSplitIntoColumns() {
        // 短单元格、行数少于 3 的不分栏，按行读
        let items = [
            frag("名称", x: 0, y: 0, charWidth: 20), frag("价格", x: 300, y: 0, charWidth: 20),
            frag("苹果", x: 0, y: 26, charWidth: 20), frag("5", x: 300, y: 26),
            frag("香蕉", x: 0, y: 52, charWidth: 20), frag("3", x: 300, y: 52),
        ]
        XCTAssertEqual(TextLayout.compose(items), "名称 价格\n苹果 5\n香蕉 3")
    }

    func testTableKeepsMissingCellsAndColumnOrder() {
        let items = [frag("C", x: 180, y: 1), frag("A", x: 0, y: 0), frag("B", x: 90, y: 0),
                     frag("3", x: 185, y: 26), frag("1", x: 0, y: 26),
                     frag("中", x: 90, y: 52)]
        let rows = TextLayout.tableRows(items)
        XCTAssertEqual(rows, [["A", "B", "C"], ["1", "", "3"], ["", "中", ""]])
        XCTAssertEqual(TextLayout.tabSeparated(rows), "A\tB\tC\n1\t\t3\n\t中\t")
    }

    func testTableJoinsTextFragmentsInsideCell() {
        let items = [frag("苹", x: 0, y: 0), frag("果", x: 12, y: 0), frag("8", x: 92, y: 0)]
        XCTAssertEqual(TextLayout.tableRows(items), [["苹果", "8"]])
        XCTAssertTrue(TextLayout.tableRows([]).isEmpty)
    }

    func testEmptyInput() {
        XCTAssertEqual(TextLayout.compose([]), "")
        XCTAssertEqual(TextLayout.compose([frag("   ", x: 0, y: 0)]), "")
    }

    func testReflow() {
        XCTAssertEqual(TextLayout.reflow("The quick brown\nfox jumps"), "The quick brown fox jumps")
        XCTAssertEqual(TextLayout.reflow("这是第一行\n这是第二行"), "这是第一行这是第二行")
        XCTAssertEqual(TextLayout.reflow("an exam-\nple here"), "an example here")
        XCTAssertEqual(TextLayout.reflow("well-\nKnown"), "well- Known")
    }

    func testParagraphs() {
        XCTAssertEqual(TextLayout.paragraphs("a\nb\n\n\nc\n  \nd"), ["a\nb", "c", "d"])
        XCTAssertEqual(TextLayout.paragraphs("\n\n"), [])
    }
}
