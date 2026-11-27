import AppKit

/// 复制成功的轻提示：鼠标旁显示「已复制 …」，约 1.2 秒后淡出；不抢焦点、不拦截鼠标
@MainActor
enum CopyToast {
    private static var panel: FloatingPanel?
    private static var hideTask: Task<Void, Never>?

    /// point：全局坐标（一般是鼠标位置）；swatch：附带显示的色块
    static func show(_ text: String, swatch: NSColor? = nil, near point: CGPoint) {
        hideTask?.cancel()
        panel?.orderOut(nil)

        let content = ToastView(text: text, swatch: swatch)
        let size = content.frame.size
        // 放在鼠标右下方，超出屏幕时翻到另一侧
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = CGPoint(x: point.x + 16, y: point.y - 16 - size.height)
        if origin.x + size.width > visible.maxX - 8 { origin.x = point.x - 16 - size.width }
        if origin.y < visible.minY + 8 { origin.y = point.y + 16 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)

        let p = FloatingPanel(rect: NSRect(origin: origin, size: size))
        p.ignoresMouseEvents = true
        p.canHide = false   // 截图结束时应用可能被隐藏，提示仍要显示
        p.hasShadow = true
        p.contentView = content
        p.alphaValue = 1
        p.orderFrontRegardless()
        panel = p

        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                p.animator().alphaValue = 0
            }
            guard !Task.isCancelled else { return }
            p.orderOut(nil)
            if panel === p { panel = nil }
        }
    }
}

private final class ToastView: HUDBackgroundView {
    init(text: String, swatch: NSColor?) {
        super.init(frame: .zero)
        layer?.backgroundColor = ToolbarStyle.background.cgColor
        layer?.borderColor = ToolbarStyle.border.cgColor

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let check = NSImageView()
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        check.contentTintColor = NSColor(srgbRed: 0.3, green: 0.85, blue: 0.45, alpha: 1)
        stack.addArrangedSubview(check)

        if let swatch {
            let box = NSView()
            box.wantsLayer = true
            box.layer?.backgroundColor = swatch.cgColor
            box.layer?.cornerRadius = 4
            box.layer?.borderColor = NSColor(white: 1, alpha: 0.35).cgColor
            box.layer?.borderWidth = 0.5
            box.translatesAutoresizingMaskIntoConstraints = false
            box.widthAnchor.constraint(equalToConstant: 16).isActive = true
            box.heightAnchor.constraint(equalToConstant: 16).isActive = true
            stack.addArrangedSubview(box)
        }

        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.textColor = ToolbarStyle.icon
        stack.addArrangedSubview(label)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        setFrameSize(size)
        layer?.cornerRadius = size.height / 2
    }

    required init?(coder: NSCoder) { fatalError() }
}
