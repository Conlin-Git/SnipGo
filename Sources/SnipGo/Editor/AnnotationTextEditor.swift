import AppKit

private final class AnnotationInputView: NSTextView {
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76),
           event.modifierFlags.intersection([.shift, .command, .control, .option]) == .shift,
           !hasMarkedText() {
            insertText("\n", replacementRange: selectedRange())
            return
        }
        super.keyDown(with: event)
    }
}

/// 文字标注始终使用同一个输入视图，输入法组字和调整可见范围可以同时进行。
final class AnnotationTextEditor: NSScrollView, NSTextViewDelegate {
    let input: NSTextView = AnnotationInputView(usingTextLayoutManager: false)
    private let annotation: Annotation
    var onFinish: ((Bool) -> Void)?
    private let area: CGRect
    private let topLeft: CGPoint
    private let minimumWidth: CGFloat
    private var originalEditorTop: CGFloat?
    private let inset: CGFloat = 2

    init(annotation: Annotation, at point: CGPoint, in area: CGRect, isNew: Bool) {
        self.annotation = annotation
        self.area = area
        let font = NSFont.systemFont(ofSize: annotation.fontSize, weight: .semibold)
        minimumWidth = ceil(("zhongwen" as NSString).size(withAttributes: [.font: font]).width) + 6
        let lineHeight = ceil(font.ascender - font.descender + font.leading) + 4
        let corner = isNew ? CGPoint(x: point.x, y: point.y + lineHeight / 2)
                           : CGPoint(x: point.x - inset, y: point.y + inset)
        topLeft = CGPoint(x: max(area.minX, min(corner.x, area.maxX - (isNew ? minimumWidth : 12))),
                          y: min(area.maxY, max(corner.y, area.minY + lineHeight)))
        super.init(frame: .zero)
        drawsBackground = false
        wantsLayer = true
        layer?.borderColor = NSColor(white: 1, alpha: 0.6).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 3

        input.isRichText = false
        input.drawsBackground = false
        input.allowsUndo = true
        input.isHorizontallyResizable = false
        input.isVerticallyResizable = false
        input.textContainerInset = NSSize(width: inset, height: inset)
        input.textContainer?.lineFragmentPadding = 0
        input.textContainer?.widthTracksTextView = false
        input.textContainer?.heightTracksTextView = false
        input.textContainer?.containerSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        input.font = font
        input.textColor = annotation.color
        input.string = annotation.text
        input.delegate = self
        documentView = input
        resizeToText()
        if !isNew { originalEditorTop = frame.maxY }
        if let storage = input.textStorage {
            NotificationCenter.default.addObserver(self, selector: #selector(storageChanged(_:)),
                                                   name: NSTextStorage.didProcessEditingNotification, object: storage)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func storageChanged(_ note: Notification) {
        guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
        DispatchQueue.main.async { [weak self] in self?.resizeToText() }
    }

    private func resizeToText() {
        guard let layout = input.layoutManager, let container = input.textContainer, let font = input.font else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let width = max(minimumWidth, ceil(used.maxX) + 2 * inset + 2)
        let height = ceil(max(used.maxY, layout.extraLineFragmentUsedRect.maxY, layout.defaultLineHeight(for: font))) + 2 * inset
        let visible = CGSize(width: min(width, area.maxX - topLeft.x), height: min(height, area.height))
        let frame = CGRect(x: topLeft.x, y: max(area.minY, topLeft.y - visible.height), width: visible.width, height: visible.height)
        if self.frame != frame { self.frame = frame }
        let documentSize = CGSize(width: width, height: height)
        if input.frame.size != documentSize { input.setFrameSize(documentSize) }
        if window?.firstResponder === input { input.scrollRangeToVisible(input.selectedRange()) }

    }

    func placeCaret(at canvasPoint: CGPoint) {
        guard let anchor = annotation.points.first else { return }
        let point = CGPoint(x: canvasPoint.x - anchor.x + inset, y: anchor.y - canvasPoint.y + inset)
        let index = input.characterIndexForInsertion(at: point)
        input.setSelectedRange(NSRange(location: index, length: 0))
        input.scrollRangeToVisible(input.selectedRange())
    }

    func result() -> Annotation {
        resizeToText()
        var result = annotation
        if let originalEditorTop {
            result.points[0].y += frame.maxY - originalEditorTop
        } else {
            result.points = [CGPoint(x: frame.minX + inset, y: frame.maxY - inset)]
        }
        result.text = input.string
        result.color = input.textColor ?? annotation.color
        return result
    }

    func textView(_ textView: NSTextView, doCommandBy command: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        let newline = command == #selector(NSResponder.insertNewline(_:))
        if command == #selector(NSResponder.insertLineBreak(_:)) {
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        }
        if newline || command == #selector(NSResponder.insertTab(_:)) || command == #selector(NSResponder.insertBacktab(_:)) {
            onFinish?(true)
            return true
        }
        if command == #selector(NSResponder.cancelOperation(_:)) {
            onFinish?(false)
            return true
        }
        return false
    }
}
