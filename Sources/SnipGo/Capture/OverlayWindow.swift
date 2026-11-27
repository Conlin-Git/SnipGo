import AppKit

/// 每块屏幕一个的全屏遮罩窗口
final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// 焦点在结果卡片的文本框里时，Esc 关闭卡片（文本框自己会把 Esc 当作补全，输入法组字时除外）
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
           var v = firstResponder as? NSView {
            while !(v is TextResultCard), let parent = v.superview { v = parent }
            if let card = v as? TextResultCard, !card.hasMarkedText {
                card.onClose?()
                return
            }
        }
        super.sendEvent(event)
    }
}

/// 浮在遮罩之上的面板（长图 HUD、预览、录制 HUD 等）
final class FloatingPanel: NSPanel {
    init(rect: NSRect, level: NSWindow.Level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)) {
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
}

/// 深色圆角背景容器
class HUDBackgroundView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.11, alpha: 0.94).cgColor
        layer?.cornerRadius = 10
        layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        layer?.borderWidth = 0.5
    }

    required init?(coder: NSCoder) { fatalError() }
}
