import AppKit
import ScreenCaptureKit

/// 只在录制目标上画边框，窗口不接受鼠标或键盘事件。
@MainActor
final class RecordingBoundary: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func drawOutline(_ path: CGRect, in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [6, 4])
        context.stroke(path)
        context.restoreGState()
    }

    private final class OutlineView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            RecordingBoundary.drawOutline(bounds.insetBy(dx: 0.75, dy: 0.75), in: context)
        }
    }

    init(screen: NSScreen, localRect: CGRect) {
        let frame = localRect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        canHide = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        let view = OutlineView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        if frame.width >= 100 && frame.height >= 40 {
            let badge = NSTextField(labelWithString: "●  录制中")
            badge.font = .systemFont(ofSize: 11, weight: .semibold)
            badge.textColor = .white
            badge.alignment = .center
            badge.frame = CGRect(x: 3, y: frame.height - 23, width: 62, height: 18)
            badge.wantsLayer = true
            badge.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.86).cgColor
            badge.layer?.cornerRadius = 4
            view.addSubview(badge)
        }
        contentView = view
        setFrame(frame, display: false)
    }

    func captureFilter(for display: SCDisplay) async throws -> SCContentFilter {
        let content = try await SCShareableContent.currentProcess
        let id = CGWindowID(windowNumber)
        if let window = content.windows.first(where: { $0.windowID == id }) {
            return SCContentFilter(display: display, excludingWindows: [window])
        }
        // 某些系统会略去透明面板。排除本进程，同时保留可见的钉图等窗口。
        guard let app = content.applications.first(where: { $0.processID == ProcessInfo.processInfo.processIdentifier }) else {
            throw NSError(domain: "SnipGo", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "无法把录制边框排除在视频之外，请重新开始录制。"])
        }
        let others = content.windows.filter { $0.owningApplication?.processID == app.processID && $0.windowID != id }
        return SCContentFilter(display: display, excludingApplications: [app], exceptingWindows: others)
    }
}
