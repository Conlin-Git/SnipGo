import AppKit

/// QuickTime「新建录屏」风格的底部控制条：✕ | 录制整个屏幕 · 录制所选部分 | 选项 ⌄ · 录制
final class RecordControlBar: NSVisualEffectView {
    enum Command {
        case close
        case fullScreen
        case region
        case record
    }

    var onCommand: ((Command) -> Void)?
    private(set) var isFullScreen = false

    private let stack = NSStackView()
    private var fullButton: NSButton!
    private var regionButton: NSButton!
    private var optionsButton: NSButton!

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        layer?.borderWidth = 0.5

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let close = iconButton(["xmark.circle.fill"], tip: "关闭 Esc", action: #selector(closeClicked), size: 18)
        close.contentTintColor = NSColor(white: 1, alpha: 0.55)
        stack.addArrangedSubview(close)
        stack.addArrangedSubview(separator())
        fullButton = iconButton(["menubar.dock.rectangle.badge.record", "display"], tip: "录制整个屏幕",
                                action: #selector(fullClicked), size: 20)
        regionButton = iconButton(["rectangle.dashed.badge.record", "rectangle.dashed"], tip: "录制所选部分",
                                  action: #selector(regionClicked), size: 20)
        stack.addArrangedSubview(fullButton)
        stack.addArrangedSubview(regionButton)
        stack.addArrangedSubview(separator())

        optionsButton = textButton("选项", chevron: true, action: #selector(optionsClicked))
        stack.addArrangedSubview(optionsButton)
        let record = textButton("录制", chevron: false, action: #selector(recordClicked))
        record.keyEquivalent = "\r"
        stack.addArrangedSubview(record)

        setFrameSize(stack.fittingSize)
        setMode(fullScreen: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setMode(fullScreen: Bool) {
        isFullScreen = fullScreen
        for (b, on) in [(fullButton!, fullScreen), (regionButton!, !fullScreen)] {
            b.layer?.backgroundColor = on ? NSColor(white: 1, alpha: 0.2).cgColor : nil
            b.contentTintColor = on ? .white : NSColor(white: 1, alpha: 0.7)
        }
    }

    // MARK: - 构建

    private func iconButton(_ symbols: [String], tip: String, action: Selector, size: CGFloat) -> NSButton {
        let img = symbols.lazy.compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: tip) }.first?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular))
        let b = NSButton(image: img ?? NSImage(), target: self, action: action)
        b.isBordered = false
        b.toolTip = tip
        b.contentTintColor = .white
        b.wantsLayer = true
        b.layer?.cornerRadius = 7
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 44).isActive = true
        b.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return b
    }

    private func textButton(_ title: String, chevron: Bool, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.isBordered = false
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 14, weight: .medium),
        ])
        if chevron {
            b.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
            b.imagePosition = .imageTrailing
            b.contentTintColor = .white
        }
        b.wantsLayer = true
        b.layer?.cornerRadius = 7
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 36).isActive = true
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: chevron ? 70 : 60).isActive = true
        return b
    }

    private func separator() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 1, alpha: 0.2).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return v
    }

    // MARK: - 动作

    @objc private func closeClicked() { onCommand?(.close) }
    @objc private func fullClicked() { setMode(fullScreen: true); onCommand?(.fullScreen) }
    @objc private func regionClicked() { setMode(fullScreen: false); onCommand?(.region) }
    @objc private func recordClicked() { onCommand?(.record) }

    @objc private func optionsClicked() {
        let menu = NSMenu()
        menu.appearance = NSAppearance(named: .darkAqua)
        func toggle(_ title: String, _ on: Bool, _ action: Selector) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            i.state = on ? .on : .off
            menu.addItem(i)
        }
        menu.addItem(NSMenuItem.sectionHeader(title: "声音"))
        toggle("录制麦克风", AppSettings.recordMicrophone, #selector(toggleMic))
        toggle("录制系统声音", AppSettings.recordSystemAudio, #selector(toggleAudio))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "选项"))
        toggle("显示鼠标指针", AppSettings.recordShowCursor, #selector(toggleCursor))
        toggle("显示点击圆环", AppSettings.recordShowClicks, #selector(toggleClicks))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "存储位置"))
        let path = NSMenuItem(title: (AppSettings.saveDirectory.path as NSString).abbreviatingWithTildeInPath, action: nil, keyEquivalent: "")
        path.isEnabled = false
        menu.addItem(path)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: optionsButton.bounds.height + 4), in: optionsButton)
    }

    @objc private func toggleMic() { AppSettings.recordMicrophone.toggle() }
    @objc private func toggleAudio() { AppSettings.recordSystemAudio.toggle() }
    @objc private func toggleClicks() { AppSettings.recordShowClicks.toggle() }
    @objc private func toggleCursor() {
        AppSettings.defaults.set(!AppSettings.recordShowCursor, forKey: SettingsKey.recordShowCursor)
    }
}
