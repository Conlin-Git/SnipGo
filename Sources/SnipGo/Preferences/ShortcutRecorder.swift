import AppKit
import SwiftUI

extension Notification.Name {
    static let shortcutsChanged = Notification.Name("SnipGo.shortcutsChanged")
    static let shortcutRecordingBegan = Notification.Name("SnipGo.shortcutRecordingBegan")
    static let shortcutRecordingEnded = Notification.Name("SnipGo.shortcutRecordingEnded")
}

/// 快捷键录制控件：点击后按下组合键；Delete 清除，Esc 取消
final class ShortcutRecorderControl: NSView {
    let action: HotKeyAction
    private var recording = false { didSet { needsDisplay = true } }
    private let clearButton = NSButton()

    init(action: HotKeyAction) {
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: 180, height: 26))
        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "清除")
        clearButton.isBordered = false
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(clear)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clearButton)
        NSLayoutConstraint.activate([
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 180, height: 26) }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()
        let text: String
        if recording { text = "请按下组合键…" } else { text = action.shortcut?.displayString ?? "点击设置" }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: recording || action.shortcut == nil ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - 20 - size.width) / 2, y: (bounds.height - size.height) / 2),
                                withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        recording = true
        window?.makeFirstResponder(self)
        NotificationCenter.default.post(name: .shortcutRecordingBegan, object: nil)
    }

    override func resignFirstResponder() -> Bool {
        if recording {
            recording = false
            NotificationCenter.default.post(name: .shortcutRecordingEnded, object: nil)
        }
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch Int(event.keyCode) {
        case 53 where mods.isEmpty: // Esc
            endRecording()
            return
        case 51 where mods.isEmpty, 117 where mods.isEmpty: // Delete
            action.shortcut = nil
            endRecording(changed: true)
            return
        default:
            break
        }
        // 至少需要 ⌘ / ⌃ / ⌥ 之一；F1–F12（Mac 键盘上即 fn+F1…F12）可单独使用
        guard !mods.intersection([.command, .control, .option]).isEmpty || Shortcut.isFunctionKey(event.keyCode)
        else { NSSound.beep(); return }
        action.shortcut = Shortcut(keyCode: UInt32(event.keyCode), modifiers: mods, key: Shortcut.keyName(for: event))
        endRecording(changed: true)
    }

    private func endRecording(changed: Bool = false) {
        recording = false
        window?.makeFirstResponder(nil)
        NotificationCenter.default.post(name: .shortcutRecordingEnded, object: nil)
        if changed { NotificationCenter.default.post(name: .shortcutsChanged, object: nil) }
        needsDisplay = true
    }

    @objc private func clear() {
        action.shortcut = nil
        NotificationCenter.default.post(name: .shortcutsChanged, object: nil)
        needsDisplay = true
    }
}

struct ShortcutRecorderView: NSViewRepresentable {
    let action: HotKeyAction

    func makeNSView(context: Context) -> ShortcutRecorderControl { ShortcutRecorderControl(action: action) }
    func updateNSView(_ nsView: ShortcutRecorderControl, context: Context) {}
}
