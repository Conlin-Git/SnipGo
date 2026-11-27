import AppKit

enum CaptureMode {
    case screenshot
    case record
}

/// 工具栏种类
enum ToolbarKind {
    case screenshot
    case scrolling   // 长截图进行中
}

enum ToolbarCommand {
    case tool(AnnotationTool)
    case pin
    case undo
    case scroll
    case cancel
    case save
    case copy
    case startRecord
    case recognizeText
    case translate
    case color(Int)
    case size(Int)
}

private func symbolImage(_ name: String, size: CGFloat = 19, weight: NSFont.Weight = .regular) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
}

/// 工具栏统一配色（参考样式：近黑底、白色细线图标、红色取消）
enum ToolbarStyle {
    static let background = NSColor(white: 0.04, alpha: 0.94)
    static let border = NSColor(white: 1, alpha: 0.08)
    static let icon = NSColor(white: 1, alpha: 0.92)
    static let disabledAlpha: CGFloat = 0.3
    static let active = NSColor(srgbRed: 0.33, green: 0.62, blue: 1, alpha: 1)
    static let cancel = NSColor(srgbRed: 1, green: 0.2, blue: 0.2, alpha: 1)
    static let buttonSize = NSSize(width: 40, height: 40)
    static let hover = NSColor(white: 1, alpha: 0.1)
    static let selected = NSColor(white: 1, alpha: 0.14)
}

/// 带悬停样式的按钮：鼠标移入时显示浅色背景，光标变为手形；isActive 时保持选中背景
class HoverButton: NSButton {
    /// 常态背景（nil 为透明）
    var baseColor: NSColor? { didSet { refreshBackground() } }
    var hoverColor = ToolbarStyle.hover { didSet { refreshBackground() } }
    var activeColor = ToolbarStyle.selected
    var isActive = false { didSet { refreshBackground() } }
    private var hovering = false

    override var isEnabled: Bool {
        didSet {
            if !isEnabled { hovering = false }
            refreshBackground()
            window?.invalidateCursorRects(for: self)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        hovering = true
        refreshBackground()
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        guard hovering else { return }
        hovering = false
        refreshBackground()
        NSCursor.arrow.set()
    }

    override func viewDidHide() {
        super.viewDidHide()
        hovering = false
        refreshBackground()
    }

    func refreshBackground() {
        wantsLayer = true
        let color = isActive ? activeColor : (hovering && isEnabled ? hoverColor : baseColor)
        layer?.backgroundColor = color?.cgColor
    }
}

/// 主工具栏
final class ToolbarView: HUDBackgroundView {
    var onCommand: ((ToolbarCommand) -> Void)?

    private let kind: ToolbarKind
    private let stack = NSStackView()
    private var commands: [ToolbarCommand] = []
    private var toolButtons: [AnnotationTool: HoverButton] = [:]
    private var undoButton: NSButton?

    init(kind: ToolbarKind) {
        self.kind = kind
        super.init(frame: .zero)
        layer?.backgroundColor = ToolbarStyle.background.cgColor
        layer?.borderColor = ToolbarStyle.border.cgColor
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 18, bottom: 4, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        build()
        setFrameSize(stack.fittingSize)
        layer?.cornerRadius = frame.height / 2   // 胶囊形
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        switch kind {
        case .scrolling:
            add(symbol: "xmark", tip: "取消 Esc", command: .cancel, tint: ToolbarStyle.cancel, weight: .medium, size: 21)
            add(symbol: "pin", tip: "钉在桌面", command: .pin)
            add(symbol: "tray.and.arrow.down", tip: "保存 ⌘S", command: .save)
            add(symbol: "doc.on.doc", tip: "完成并复制 ↩", command: .copy)
        case .screenshot:
            for t in AnnotationTool.allCases {
                if t == .text {
                    toolButtons[t] = add(text: "A", tip: t.title, command: .tool(t))
                } else {
                    toolButtons[t] = add(symbol: t.symbol, tip: t.title, command: .tool(t))
                }
            }
            separator()
            undoButton = add(symbol: "arrow.uturn.backward", tip: "撤销 ⌘Z", command: .undo)
            separator()
            add(symbol: "xmark", tip: "取消 Esc", command: .cancel, tint: ToolbarStyle.cancel, weight: .medium, size: 21)
            add(symbol: "rectangle.expand.vertical", tip: "长截图（滚动截图）", command: .scroll)
            add(symbol: "tray.and.arrow.down", tip: "保存 ⌘S", command: .save)
            add(symbol: "doc.on.doc", tip: "复制到剪贴板 ↩ / ⌘C", command: .copy)
        }
    }

    private func makeButton(tip: String, command: ToolbarCommand) -> HoverButton {
        let b = HoverButton(title: "", target: self, action: #selector(clicked(_:)))
        b.isBordered = false
        b.toolTip = tip
        b.tag = commands.count
        b.wantsLayer = true
        b.layer?.cornerRadius = 8
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: ToolbarStyle.buttonSize.width).isActive = true
        b.heightAnchor.constraint(equalToConstant: ToolbarStyle.buttonSize.height).isActive = true
        commands.append(command)
        stack.addArrangedSubview(b)
        return b
    }

    @discardableResult
    private func add(symbol: String, tip: String, command: ToolbarCommand, tint: NSColor = ToolbarStyle.icon,
                     weight: NSFont.Weight = .regular, size: CGFloat = 19) -> HoverButton {
        let b = makeButton(tip: tip, command: command)
        if let img = symbolImage(symbol, size: size, weight: weight) {
            b.image = img
            b.imagePosition = .imageOnly
        } else {
            b.title = String(tip.prefix(1))
        }
        b.contentTintColor = tint
        return b
    }

    /// 文字工具：参考样式用一个细体的大写 A
    @discardableResult
    private func add(text: String, tip: String, command: ToolbarCommand) -> HoverButton {
        let b = makeButton(tip: tip, command: command)
        setTextTitle(b, text, color: ToolbarStyle.icon)
        return b
    }

    private func setTextTitle(_ b: NSButton, _ text: String, color: NSColor) {
        b.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 23, weight: .light), .foregroundColor: color,
        ])
    }

    private func separator() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 1, alpha: 0.28).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 16).isActive = true
        stack.addArrangedSubview(v)
        stack.setCustomSpacing(10, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
        stack.setCustomSpacing(10, after: v)
    }

    @objc private func clicked(_ sender: NSButton) {
        guard sender.tag < commands.count else { return }
        onCommand?(commands[sender.tag])
    }

    func setActiveTool(_ tool: AnnotationTool?) {
        for (t, b) in toolButtons {
            let on = t == tool
            b.isActive = on
            let color = on ? ToolbarStyle.active : ToolbarStyle.icon
            if t == .text { setTextTitle(b, "A", color: color) } else { b.contentTintColor = color }
        }
    }

    func setUndoEnabled(_ enabled: Bool) {
        undoButton?.isEnabled = enabled
        undoButton?.alphaValue = enabled ? 1 : ToolbarStyle.disabledAlpha
    }
}

/// 主工具栏下方的文字工具条：提取文字、翻译（带文字标签，结果显示在选区旁的卡片里）
final class TextToolBarView: HUDBackgroundView {
    enum Item { case recognize, translate }

    var onCommand: ((ToolbarCommand) -> Void)?
    private let stack = NSStackView()
    private var buttons: [Item: HoverButton] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.backgroundColor = ToolbarStyle.background.cgColor
        layer?.borderColor = ToolbarStyle.border.cgColor
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        buttons[.recognize] = add(symbol: "text.viewfinder", title: "提取文字", item: .recognize)
        buttons[.translate] = add(symbol: "character.bubble", title: "翻译", item: .translate)
        layoutSubtreeIfNeeded()
        setFrameSize(stack.fittingSize)
        setActive(nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 与主工具栏一致的胶囊形：初始化时 fittingSize 可能还没算出来，尺寸变化时再更新圆角
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layer?.cornerRadius = newSize.height / 2
    }

    private func add(symbol: String, title: String, item: Item) -> HoverButton {
        let b = HoverButton(title: title, target: self, action: #selector(clicked(_:)))
        b.isBordered = false
        b.tag = item == .recognize ? 0 : 1
        b.image = symbolImage(symbol, size: 16)
        b.imagePosition = .imageLeading
        b.imageHugsTitle = true
        b.wantsLayer = true
        b.layer?.cornerRadius = 8
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: ToolbarStyle.icon,
        ])
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 32).isActive = true
        b.widthAnchor.constraint(equalToConstant: b.intrinsicContentSize.width + 20).isActive = true
        stack.addArrangedSubview(b)
        return b
    }

    @objc private func clicked(_ sender: NSButton) {
        onCommand?(sender.tag == 0 ? .recognizeText : .translate)
    }

    /// 高亮当前结果卡片对应的按钮
    func setActive(_ item: Item?) {
        for (i, b) in buttons {
            let on = i == item
            let color = on ? ToolbarStyle.active : ToolbarStyle.icon
            b.isActive = on
            b.contentTintColor = color
            b.attributedTitle = NSAttributedString(string: b.title, attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: color,
            ])
        }
    }
}

/// 选区右上角外侧的圆形钉图按钮
final class PinCornerButton: HoverButton {
    static let diameter: CGFloat = 32

    init(target: AnyObject, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
        self.target = target
        self.action = action
        isBordered = false
        title = ""
        toolTip = "钉在桌面"
        wantsLayer = true
        layer?.cornerRadius = Self.diameter / 2
        baseColor = NSColor(white: 0.22, alpha: 0.88)
        hoverColor = NSColor(white: 0.34, alpha: 0.92)
        layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        layer?.borderWidth = 0.5
        image = symbolImage("pin.fill", size: 15, weight: .medium)
        imagePosition = .imageOnly
        contentTintColor = .white
        // 参考样式：图钉斜放
        if let img = image { image = img.rotated(by: -45) }
    }

    required init?(coder: NSCoder) { fatalError() }
}

private extension NSImage {
    func rotated(by degrees: CGFloat) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            let t = NSAffineTransform()
            t.translateX(by: rect.midX, yBy: rect.midY)
            t.rotate(byDegrees: degrees)
            t.translateX(by: -rect.midX, yBy: -rect.midY)
            t.concat()
            self.draw(in: rect)
            return true
        }
        img.isTemplate = isTemplate
        return img
    }
}

/// 颜色 / 粗细选择行
final class StyleBarView: HUDBackgroundView {
    var onCommand: ((ToolbarCommand) -> Void)?
    private let stack = NSStackView()
    private var sizeButtons: [SwatchButton] = []
    private var colorButtons: [SwatchButton] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.backgroundColor = ToolbarStyle.background.cgColor
        layer?.borderColor = ToolbarStyle.border.cgColor
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 16, bottom: 5, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for (i, d) in [CGFloat(5), 9, 13].enumerated() {
            let b = SwatchButton(kind: .size(d), tag: i, target: self, action: #selector(sizeClicked(_:)))
            sizeButtons.append(b)
            stack.addArrangedSubview(b)
        }
        let sep = NSView()
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor(white: 1, alpha: 0.18).cgColor
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.widthAnchor.constraint(equalToConstant: 1).isActive = true
        sep.heightAnchor.constraint(equalToConstant: 16).isActive = true
        stack.addArrangedSubview(sep)
        for (i, c) in AnnotationPalette.colors.enumerated() {
            let b = SwatchButton(kind: .color(c), tag: i, target: self, action: #selector(colorClicked(_:)))
            colorButtons.append(b)
            stack.addArrangedSubview(b)
        }
        setFrameSize(stack.fittingSize)
        layer?.cornerRadius = frame.height / 2
        refresh(showColors: true)
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh(showColors: Bool) {
        let size = AppSettings.annotationSize
        let color = AppSettings.annotationColorIndex
        sizeButtons.forEach { $0.isOn = $0.tag == size; $0.needsDisplay = true }
        colorButtons.forEach { $0.isOn = $0.tag == color; $0.isHidden = !showColors; $0.needsDisplay = true }
        stack.arrangedSubviews.first { !($0 is SwatchButton) }?.isHidden = !showColors
        layoutSubtreeIfNeeded()
        setFrameSize(stack.fittingSize)
        layer?.cornerRadius = frame.height / 2
    }

    @objc private func sizeClicked(_ b: NSButton) { onCommand?(.size(b.tag)) }
    @objc private func colorClicked(_ b: NSButton) { onCommand?(.color(b.tag)) }
}

final class SwatchButton: HoverButton {
    enum Kind {
        case size(CGFloat)
        case color(NSColor)
    }

    let kind: Kind
    var isOn = false

    init(kind: Kind, tag: Int, target: AnyObject, action: Selector) {
        self.kind = kind
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        self.tag = tag
        self.target = target
        self.action = action
        isBordered = false
        title = ""
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        switch kind {
        case .size(let d):
            let r = NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
            (isOn ? NSColor(srgbRed: 0.45, green: 0.72, blue: 1, alpha: 1) : NSColor(white: 1, alpha: 0.75)).setFill()
            NSBezierPath(ovalIn: r).fill()
        case .color(let color):
            let r = NSRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16)
            color.setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            NSColor(white: 1, alpha: 0.35).setStroke()
            let border = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            border.lineWidth = 0.5
            border.stroke()
            if isOn {
                NSColor.white.setStroke()
                let ring = NSBezierPath(roundedRect: r.insetBy(dx: -3, dy: -3), xRadius: 6, yRadius: 6)
                ring.lineWidth = 1.5
                ring.stroke()
            }
        }
    }
}
