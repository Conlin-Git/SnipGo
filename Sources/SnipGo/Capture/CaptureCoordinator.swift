import AppKit
import ScreenCaptureKit

/// 截图 / 录屏选区流程的调度中心
@MainActor
final class CaptureCoordinator: SelectionViewDelegate {
    static let shared = CaptureCoordinator()

    private(set) var isActive = false
    private var overlays: [OverlayWindow] = []
    private var contents: [OverlayContentView] = []
    private var activeView: SelectionView?
    private var previousApp: NSRunningApplication?
    private var scrollSession: ScrollCaptureSession?
    private var mode: CaptureMode = .screenshot

    func start(mode: CaptureMode) {
        guard !isActive else { return }
        guard Permissions.ensureScreenCapture() else { return }
        isActive = true
        self.mode = mode
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front

        Task { @MainActor in
            do {
                let snapshots = try await ScreenSnapshotter.captureAll()
                guard !snapshots.isEmpty else { throw NSError(domain: "SnipGo", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有可用的显示器"]) }
                self.present(snapshots)
            } catch {
                self.isActive = false
                Self.showError("截屏失败", error)
            }
        }
    }

    private func present(_ snapshots: [ScreenSnapshot]) {
        let mouse = NSEvent.mouseLocation
        var keyWindow: OverlayWindow?
        for snap in snapshots {
            let w = OverlayWindow(screen: snap.screen)
            let content = OverlayContentView(snapshot: snap, mode: mode)
            content.selectionView.delegate = self
            w.contentView = content
            overlays.append(w)
            contents.append(content)
            w.orderFrontRegardless()
            if snap.screen.frame.contains(mouse) { keyWindow = w }
        }
        NSApp.activate(ignoringOtherApps: true)
        let kw = keyWindow ?? overlays.first
        kw?.makeKeyAndOrderFront(nil)
        if let v = (kw?.contentView as? OverlayContentView)?.selectionView {
            kw?.makeFirstResponder(v)
        }
        NSCursor.crosshair.set()

        // 录屏：QuickTime 风格，直接预选上次（或默认）区域并显示底部控制条
        if mode == .record, let w = kw, let v = (w.contentView as? OverlayContentView)?.selectionView {
            let key = ScreenSnapshotter.displayID(of: v.snapshot.screen) ?? 0
            selectionViewDidBegin(v)
            v.preselect(Self.lastRecordRegions[key] ?? SelectionView.defaultRegion(in: v.bounds))
        }
    }

    /// 本次运行内记住每块屏幕上次的录制区域
    private static var lastRecordRegions: [CGDirectDisplayID: CGRect] = [:]

    func cancel() {
        scrollSession?.cancel()
        scrollSession = nil
        finish()
    }

    private func finish() {
        overlays.forEach { $0.orderOut(nil) }
        overlays.forEach { $0.close() }
        overlays.removeAll()
        contents.removeAll()
        activeView = nil
        isActive = false
        NSCursor.arrow.set()
        restoreFocus()
    }

    func restoreFocus() {
        let otherVisible = NSApp.windows.contains { $0.isVisible && !($0 is OverlayWindow) && !($0 is FloatingPanel) && $0.className != "NSStatusBarWindow" }
        if !otherVisible {
            if let app = previousApp { app.activate() } else { NSApp.hide(nil) }
        }
        previousApp = nil
    }

    // MARK: - SelectionViewDelegate

    func selectionViewShouldBegin(_ view: SelectionView) -> Bool {
        activeView == nil || activeView === view
    }

    func selectionViewDidBegin(_ view: SelectionView) {
        activeView = view
        for c in contents where c.selectionView !== view { c.selectionView.isPassive = true }
        if let w = view.window, !w.isKeyWindow {
            w.makeKeyAndOrderFront(nil)
        }
        view.window?.makeFirstResponder(view)
    }

    func selectionView(_ view: SelectionView, perform command: ToolbarCommand) {
        if let session = scrollSession {
            switch command {
            case .copy: session.finish(.copy)
            case .save: session.finish(.save)
            case .pin: session.finish(.pin)
            case .cancel: cancel()
            default: break
            }
            return
        }
        switch command {
        case .cancel:
            cancel()
        case .copy:
            guard let img = view.renderResult() else { return }
            ImageOutput.copyToPasteboard(img, pointSize: view.selection?.size)
            ImageOutput.playCaptureSound()
            finish()
        case .save:
            guard let img = view.renderResult() else { return }
            if ImageOutput.save(img) == nil {
                Self.showError("保存失败", NSError(domain: "SnipGo", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法写入 \(AppSettings.saveDirectory.path)"]))
                return
            }
            ImageOutput.playCaptureSound()
            finish()
        case .pin:
            guard let img = view.renderResult(), let sel = view.selection else { return }
            let global = sel.offsetBy(dx: view.snapshot.screen.frame.minX, dy: view.snapshot.screen.frame.minY)
            finish()
            PinManager.pin(img, frame: global, pointSize: sel.size)
        case .scroll:
            startScroll(view)
        case .startRecord:
            startRecording(view)
        default:
            break
        }
    }

    // MARK: - 长图

    private func startScroll(_ view: SelectionView) {
        guard let sel = view.selection, sel.height >= 40, sel.width >= 40 else { NSSound.beep(); return }
        for c in contents {
            c.showFrozenImage(false)
            c.selectionView.enterScrollingMode()
        }
        overlays.forEach { $0.ignoresMouseEvents = true }
        let session = ScrollCaptureSession(snapshot: view.snapshot, selection: sel)
        session.onFinish = { [weak self] image, action in
            guard let self else { return }
            self.scrollSession = nil
            if let image {
                let pointSize = NSSize(width: CGFloat(image.width) / view.snapshot.screen.backingScaleFactor,
                                       height: CGFloat(image.height) / view.snapshot.screen.backingScaleFactor)
                switch action {
                case .copy:
                    ImageOutput.copyToPasteboard(image, pointSize: pointSize)
                    ImageOutput.playCaptureSound()
                case .save:
                    if let url = ImageOutput.save(image) {
                        ImageOutput.playCaptureSound()
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                case .pin:
                    let global = sel.offsetBy(dx: view.snapshot.screen.frame.minX, dy: view.snapshot.screen.frame.minY)
                    self.finish()
                    PinManager.pin(image, frame: global, pointSize: pointSize)
                    return
                case .cancel:
                    break
                }
            }
            self.finish()
        }
        scrollSession = session
        session.start()
    }

    // MARK: - 录屏

    private func startRecording(_ view: SelectionView) {
        guard let sel = view.selection else { return }
        let snapshot = view.snapshot
        if !view.recordFullScreen, let id = ScreenSnapshotter.displayID(of: snapshot.screen) {
            Self.lastRecordRegions[id] = sel
        }
        finish()
        RecordingSession.start(snapshot: snapshot, rect: sel)
    }

    static func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
