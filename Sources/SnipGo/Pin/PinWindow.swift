import AppKit

/// 管理所有钉图窗口
@MainActor
enum PinManager {
    private static var windows: [PinWindow] = []

    static var count: Int { windows.count }

    /// 钉图
    /// - Parameters:
    ///   - image: 像素图
    ///   - frame: 初始位置（全局 Cocoa 坐标，pt）
    ///   - pointSize: 100% 缩放时的尺寸（pt）
    static func pin(_ image: CGImage, frame: NSRect, pointSize: NSSize) {
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        // 太大的图（如长图）先缩小到屏幕内
        let fit = min(1, (visible.height * 0.9) / pointSize.height, (visible.width * 0.9) / pointSize.width)
        var rect = NSRect(x: frame.minX, y: frame.maxY - pointSize.height * fit,
                          width: pointSize.width * fit, height: pointSize.height * fit)
        rect.origin.x = min(max(rect.minX, visible.minX), visible.maxX - rect.width)
        rect.origin.y = min(max(rect.minY, visible.minY), visible.maxY - rect.height)

        let w = PinWindow(image: image, frame: rect, baseSize: pointSize, zoom: fit)
        windows.append(w)
        w.orderFrontRegardless()
        w.makeKey()
    }

    static func remove(_ w: PinWindow) {
        windows.removeAll { $0 === w }
    }

    static func closeAll() {
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
    }
}

/// 钉在桌面最上层的图片窗口：拖动移动，滚轮 / 触控板捏合缩放
final class PinWindow: NSPanel {
    let image: CGImage
    let baseSize: NSSize
    private(set) var zoom: CGFloat
    private let pinView: PinView

    static let minZoom: CGFloat = 0.1
    static let maxZoom: CGFloat = 8

    init(image: CGImage, frame: NSRect, baseSize: NSSize, zoom: CGFloat) {
        self.image = image
        self.baseSize = baseSize
        self.zoom = zoom
        pinView = PinView(frame: NSRect(origin: .zero, size: frame.size))
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // 高于所有应用窗口（含全屏应用），仅低于截图遮罩
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        animationBehavior = .none
        pinView.pinWindow = self
        pinView.autoresizingMask = [.width, .height]
        contentView = pinView
    }

    override var canBecomeKey: Bool { true }

    func setZoom(_ newZoom: CGFloat, anchor: NSPoint? = nil) {
        let z = min(max(newZoom, Self.minZoom), Self.maxZoom)
        let old = frame
        let size = NSSize(width: max(20, baseSize.width * z), height: max(20, baseSize.height * z))
        let a = anchor ?? NSPoint(x: old.midX, y: old.midY)
        let rx = old.width > 0 ? (a.x - old.minX) / old.width : 0.5
        let ry = old.height > 0 ? (a.y - old.minY) / old.height : 0.5
        let origin = NSPoint(x: a.x - size.width * rx, y: a.y - size.height * ry)
        zoom = z
        setFrame(NSRect(origin: origin, size: size), display: true)
        pinView.flashZoomLabel()
    }

    func zoom(by factor: CGFloat, anchor: NSPoint? = nil) {
        setZoom(zoom * factor, anchor: anchor)
    }

    func copyImage() {
        ImageOutput.copyToPasteboard(image, pointSize: baseSize)
        ImageOutput.playCaptureSound()
    }

    func saveImage() {
        if let url = ImageOutput.save(image) {
            ImageOutput.playCaptureSound()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func closePin() {
        orderOut(nil)
        MainActor.assumeIsolated { PinManager.remove(self) }
    }
}

final class PinView: NSView {
    weak var pinWindow: PinWindow?
    private let zoomLabel = NSTextField(labelWithString: "")
    private var hideLabelWork: DispatchWorkItem?
    private var isHovering = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        zoomLabel.textColor = .white
        zoomLabel.alignment = .center
        zoomLabel.wantsLayer = true
        zoomLabel.drawsBackground = true
        zoomLabel.backgroundColor = NSColor(white: 0, alpha: 0.65)
        zoomLabel.layer?.cornerRadius = 5
        zoomLabel.isHidden = true
        addSubview(zoomLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func draw(_ dirtyRect: NSRect) {
        guard let w = pinWindow, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = w.zoom >= 2 ? .none : .high
        ctx.draw(w.image, in: bounds)
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = isHovering ? 2 : 1
        (isHovering ? NSColor.controlAccentColor : NSColor(white: 0.5, alpha: 0.5)).setStroke()
        border.stroke()
    }

    func flashZoomLabel() {
        guard let w = pinWindow else { return }
        zoomLabel.stringValue = "\(Int((w.zoom * 100).rounded()))%"
        let size = NSSize(width: 56, height: 22)
        zoomLabel.frame = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                 width: size.width, height: size.height)
        zoomLabel.isHidden = false
        hideLabelWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.zoomLabel.isHidden = true }
        hideLabelWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    // MARK: - 交互

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        if event.clickCount == 2 {
            pinWindow?.closePin()
            return
        }
        window?.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.scrollingDeltaY
        guard dy != 0 else { return }
        let factor = exp(dy * (event.hasPreciseScrollingDeltas ? 0.01 : 0.08))
        pinWindow?.zoom(by: factor, anchor: NSEvent.mouseLocation)
    }

    override func magnify(with event: NSEvent) {
        pinWindow?.zoom(by: 1 + event.magnification, anchor: NSEvent.mouseLocation)
    }

    override func keyDown(with event: NSEvent) {
        guard let w = pinWindow else { return }
        let cmd = event.modifierFlags.contains(.command)
        switch (event.keyCode, event.charactersIgnoringModifiers ?? "") {
        case (53, _): w.closePin()                                   // Esc
        case (_, "c") where cmd: w.copyImage()
        case (_, "s") where cmd: w.saveImage()
        case (_, "w") where cmd: w.closePin()
        case (_, "="), (_, "+"): w.zoom(by: 1.25)
        case (_, "-"): w.zoom(by: 0.8)
        case (_, "0"): w.setZoom(1)
        default: super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true, event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c", "s", "w", "=", "-", "0":
            keyDown(with: event)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = self
            return i
        }
        menu.addItem(item("复制", #selector(menuCopy), "c"))
        menu.addItem(item("保存", #selector(menuSave), "s"))
        menu.addItem(.separator())
        menu.addItem(item("放大", #selector(menuZoomIn), "="))
        menu.addItem(item("缩小", #selector(menuZoomOut), "-"))
        menu.addItem(item("实际大小 100%", #selector(menuZoomReset), "0"))
        menu.addItem(.separator())
        menu.addItem(item("关闭", #selector(menuClose), "w"))
        menu.addItem(item("关闭所有钉图", #selector(menuCloseAll)))
        return menu
    }

    @objc private func menuCopy() { pinWindow?.copyImage() }
    @objc private func menuSave() { pinWindow?.saveImage() }
    @objc private func menuZoomIn() { pinWindow?.zoom(by: 1.25) }
    @objc private func menuZoomOut() { pinWindow?.zoom(by: 0.8) }
    @objc private func menuZoomReset() { pinWindow?.setZoom(1) }
    @objc private func menuClose() { pinWindow?.closePin() }
    @objc private func menuCloseAll() { MainActor.assumeIsolated { PinManager.closeAll() } }
}
