import AppKit

@MainActor
final class RecentThumbnailPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(image: NSImage, screen: NSScreen, export: @escaping () -> NSURL?, open: @escaping () -> Void) {
        let area = screen.visibleFrame
        let rect = NSRect(x: area.maxX - 222, y: area.minY + 16, width: 206, height: 74)
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        canHide = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .none
        contentView = RecentThumbnailView(image: image, size: rect.size, export: export, open: open)
    }

    func present() {
        orderFrontRegardless()
        (contentView as? RecentThumbnailView)?.scheduleDismissal()
    }
}

@MainActor
private final class RecentThumbnailView: NSVisualEffectView, NSDraggingSource {
    private let preview: NSImageView
    private let export: () -> NSURL?
    private let open: () -> Void
    private var dismissTask: Task<Void, Never>?
    private var press: NSPoint?
    private var dragging = false
    private var hovering = false

    init(image: NSImage, size: NSSize, export: @escaping () -> NSURL?, open: @escaping () -> Void) {
        self.export = export
        self.open = open
        preview = NSImageView(image: image)
        super.init(frame: NSRect(origin: .zero, size: size))
        material = .popover
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        preview.frame = NSRect(x: 8, y: 8, width: 76, height: 58)
        preview.imageScaling = .scaleProportionallyUpOrDown
        addSubview(preview)
        let title = NSTextField(labelWithString: "最近截图")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 94, y: 38, width: 105, height: 19)
        addSubview(title)
        let hint = NSTextField(labelWithString: "点开历史 · 拖出图片")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 94, y: 18, width: 108, height: 17)
        addSubview(hint)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("打开最近截图")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func accessibilityPerformPress() -> Bool { open(); return true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    func scheduleDismissal() {
        dismissTask?.cancel()
        guard !hovering, !dragging, press == nil else { return }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.window?.orderOut(nil)
        }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; dismissTask?.cancel() }
    override func mouseExited(with event: NSEvent) { hovering = false; scheduleDismissal() }

    override func mouseDown(with event: NSEvent) {
        press = event.locationInWindow
        dismissTask?.cancel()
    }

    override func mouseUp(with event: NSEvent) {
        guard press != nil else { return }
        press = nil
        if bounds.contains(convert(event.locationInWindow, from: nil)) { open() }
        else { scheduleDismissal() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = press, !dragging else { return }
        let current = event.locationInWindow
        guard hypot(current.x - start.x, current.y - start.y) >= 4 else { return }
        press = nil
        guard let url = export() else { NSSound.beep(); scheduleDismissal(); return }
        dragging = true
        let item = NSDraggingItem(pasteboardWriter: url)
        item.setDraggingFrame(preview.frame, contents: preview.image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func draggingSession(_ session: NSDraggingSession, endedAt point: NSPoint, operation: NSDragOperation) {
        dragging = false
        if operation == .copy { window?.orderOut(nil) }
        else { hovering = window?.frame.contains(point) == true; scheduleDismissal() }
    }
}
