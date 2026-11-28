import AppKit
import ScreenCaptureKit
import XCTest
@testable import SnipGo

private final class TextTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func makeKeyAndOrderFront(_ sender: Any?) {}
}

final class AnnotationTextTests: XCTestCase {
    @MainActor
    func testMultilineEditingAndDragging() async throws {
        _ = NSApplication.shared
        let content = try await SCShareableContent.currentProcess
        guard let screen = NSScreen.main, let display = content.displays.first else { throw XCTSkip("需要显示器") }
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 500, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let canvas = CaptureCanvas(mode: .screenshot, windowRects: [])
        defer { canvas.detachViews() }
        let snapshot = ScreenSnapshot(screen: screen, display: display, image: try XCTUnwrap(bitmap.makeImage()))
        let view = SelectionView(snapshot: snapshot, canvas: canvas)
        let window = TextTestWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        canvas.selection = view.bounds
        canvas.tool = .text

        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func click(_ point: CGPoint) {
            view.mouseDown(with: mouse(.leftMouseDown, point))
            view.mouseUp(with: mouse(.leftMouseUp, point))
        }
        func key(_ code: UInt16, shift: Bool = false) {
            let chars = code == 53 ? "\u{1b}" : "\r"
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, characters: chars,
                                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            window.firstResponder?.keyDown(with: event)
        }
        func pixels() -> Data? { view.renderResult()?.dataProvider?.data as Data? }
        let start = CGPoint(x: 80, y: 280)
        click(start)
        let input = try XCTUnwrap(window.firstResponder as? NSTextView)
        let box = try XCTUnwrap(input.enclosingScrollView)
        let initialFrame = box.frame
        input.insertText("第一行", replacementRange: input.selectedRange())
        key(36, shift: true)
        key(36, shift: true)
        let marked = "zhongwenshurufalianda"
        input.setMarkedText(marked, selectedRange: NSRange(location: marked.utf16.count, length: 0), replacementRange: input.selectedRange())
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        XCTAssertGreaterThan(box.frame.width, initialFrame.width)
        XCTAssertGreaterThan(box.frame.height, initialFrame.height * 2)
        XCTAssertEqual(box.frame.maxY, initialFrame.maxY, accuracy: 0.1)
        let last = input.firstRect(forCharacterRange: NSRange(location: NSMaxRange(input.markedRange()) - 1, length: 1), actualRange: nil)
        let viewport = window.convertToScreen(box.convert(box.bounds, to: nil))
        XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(last))
        XCTAssertTrue(input.hasMarkedText())
        XCTAssertTrue(window.firstResponder === input)
        XCTAssertEqual(input.string, "第一行\n\n" + marked)
        input.insertText("中文", replacementRange: input.markedRange())
        key(36)
        let original = try XCTUnwrap(canvas.annotations.first)
        XCTAssertEqual(original.text, "第一行\n\n中文")
        let image = try XCTUnwrap(pixels())
        let exported = NSBitmapImageRep(cgImage: try XCTUnwrap(view.renderResult()))
        // 检查三个行框的像素，确认中间空行和末行都如实导出。
        let lineHeight = original.textBounds.height / 3
        var painted = [false, false, false]
        for i in painted.indices {
            let top = Int(view.bounds.height - original.textBounds.maxY + CGFloat(i) * lineHeight)
            for y in top..<(top + Int(lineHeight)) {
                for x in Int(original.textBounds.minX)..<Int(original.textBounds.maxX)
                    where (exported.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                    painted[i] = true
                }
            }
        }
        XCTAssertEqual(painted, [true, false, true])
        let lastLine = CGPoint(x: original.textBounds.minX + 5, y: original.textBounds.minY + 8)
        XCTAssertEqual(canvas.annotationIndex(at: lastLine), 0)

        canvas.tool = nil
        click(lastLine)
        let reopened = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(canvas.visibleAnnotations.isEmpty)
        XCTAssertGreaterThanOrEqual(reopened.selectedRange().location, "第一行\n\n".utf16.count)
        reopened.selectAll(nil)
        reopened.insertText("第二版", replacementRange: reopened.selectedRange())
        key(53)
        XCTAssertEqual(canvas.annotations.first?.text, original.text)
        XCTAssertEqual(pixels(), image)

        click(lastLine)
        let edited = try XCTUnwrap(window.firstResponder as? NSTextView)
        edited.selectAll(nil)
        edited.insertText("已改", replacementRange: edited.selectedRange())
        key(36)
        XCTAssertEqual(canvas.annotations.count, 1)
        XCTAssertEqual(canvas.annotations.first?.text, "已改")
        XCTAssertEqual(canvas.annotations.first?.points, original.points)
        XCTAssertNotEqual(pixels(), image)
        view.undo()
        XCTAssertEqual(pixels(), image)

        let end = CGPoint(x: lastLine.x + 20, y: lastLine.y + 10)
        view.mouseDown(with: mouse(.leftMouseDown, lastLine))
        view.mouseDragged(with: mouse(.leftMouseDragged, end))
        view.mouseUp(with: mouse(.leftMouseUp, end))
        XCTAssertFalse(view.hasPendingText)
        XCTAssertEqual(canvas.annotations[0].points[0], CGPoint(x: original.points[0].x + 20, y: original.points[0].y + 10))
    }
}
