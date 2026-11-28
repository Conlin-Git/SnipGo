import AppKit
import AVFoundation
import ScreenCaptureKit

extension Notification.Name {
    static let recordingStateChanged = Notification.Name("SnipGo.recordingStateChanged")
}

@MainActor
final class RecordingSession: NSObject, SCStreamDelegate {
    static private(set) var current: RecordingSession?

    static var isRecording: Bool { current != nil }

    private let snapshot: ScreenSnapshot
    private let rect: CGRect          // 屏幕本地坐标
    private let outputURL: URL
    private var boundary: RecordingBoundary?
    private var stream: SCStream?
    private let rawURL: URL
    private var recorder: RecordingWriter?
    private var mixAudio = false
    private var streamEnded = false
    private var stopError: Error?
    private var stopTime: CMTime?
    private(set) var isSaving = false
    private var timer: Timer?
    private(set) var startDate: Date?
    private var stopping = false

    static func start(snapshot: ScreenSnapshot, rect: CGRect) {
        guard current == nil else { return }
        let session = RecordingSession(snapshot: snapshot, rect: rect)
        current = session
        NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
        Task { @MainActor in
            do {
                try await session.begin()
            } catch {
                guard current === session else { return }
                session.recorder?.cancel()
                try? FileManager.default.removeItem(at: session.rawURL)
                session.hideBoundary()
                current = nil
                NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
                if let reason = session.stopError { CaptureCoordinator.showError("无法开始录制", reason) }
                else if !session.stopping { CaptureCoordinator.showError("无法开始录制", error) }
            }
        }
    }

    static func stopCurrent() {
        current?.stop()
    }

    private init(snapshot: ScreenSnapshot, rect: CGRect) {
        self.snapshot = snapshot
        self.rect = rect
        self.outputURL = ImageOutput.uniqueURL(ext: "mp4")
        self.rawURL = outputURL.deletingLastPathComponent().appendingPathComponent(".snipgo-\(UUID().uuidString).mp4")
        super.init()
    }

    var elapsed: TimeInterval { startDate.map { Date().timeIntervalSince($0) } ?? 0 }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    private var isFullScreen: Bool {
        let b = CGRect(origin: .zero, size: snapshot.screen.frame.size)
        return abs(rect.width - b.width) < 1 && abs(rect.height - b.height) < 1
    }

    private func begin() async throws {
        var useMic = AppSettings.recordMicrophone
        if useMic, !(await Permissions.ensureMicrophone()) {
            useMic = false
        }

        guard !stopping else { complete(saved: false); return }
        let outline = RecordingBoundary(screen: snapshot.screen, localRect: rect)
        boundary = outline
        outline.orderFrontRegardless()
        let filter = try await outline.captureFilter(for: snapshot.display)
        guard !stopping else { complete(saved: false); return }
        let scale = filter.pointPixelScale > 0 ? CGFloat(filter.pointPixelScale) : snapshot.screen.backingScaleFactor
        let refresh = snapshot.screen.maximumFramesPerSecond
        let fps = refresh > 0 ? min(60, refresh) : 60
        let cfg = SCStreamConfiguration()
        if !isFullScreen {
            cfg.sourceRect = ScreenSnapshotter.sourceRect(forLocal: rect, screenHeight: snapshot.screen.frame.height)
        }
        let size = AppSettings.recordResolution.outputSize(for: CGSize(width: rect.width * scale, height: rect.height * scale))
        cfg.width = Int(size.width)
        cfg.height = Int(size.height)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        var pointer: RecordingPointer?
        if AppSettings.recordShowClicks {
            let region = rect.offsetBy(dx: snapshot.screen.frame.minX, dy: snapshot.screen.frame.minY)
            pointer = RecordingPointer(region: region, showsHand: AppSettings.recordShowCursor)
        }
        let color: RecordingColor = snapshot.screen.colorSpace?.cgColorSpace?.isWideGamutRGB == true ? .displayP3 : .rec709
        cfg.colorSpaceName = color.name
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = pointer == nil && AppSettings.recordShowCursor
        cfg.showMouseClicks = false
        cfg.queueDepth = 6
        cfg.captureResolution = .best
        cfg.capturesAudio = AppSettings.recordSystemAudio
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        cfg.captureMicrophone = useMic

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        let recorder = try RecordingWriter(url: rawURL, width: cfg.width, height: cfg.height, fps: fps, color: color,
                                           pointer: pointer, systemAudio: cfg.capturesAudio, microphone: useMic) { [weak self] error in
            Task { @MainActor in self?.requestStop(error: error) }
        }
        self.recorder = recorder
        mixAudio = cfg.capturesAudio && useMic
        try s.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.queue)
        if cfg.capturesAudio { try s.addStreamOutput(recorder, type: .audio, sampleHandlerQueue: recorder.queue) }
        if useMic { try s.addStreamOutput(recorder, type: .microphone, sampleHandlerQueue: recorder.queue) }
        stream = s
        try await s.startCapture()
        guard Self.current === self else { try? await s.stopCapture(); return }
        startDate = Date()
        if stopping { finishRecording(); return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    private func tick() {
        NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
    }

    func stop() { requestStop(error: nil) }

    private func requestStop(error: Error?) {
        guard Self.current === self, !isSaving else { return }
        if let error { stopError = error }
        if stopTime == nil { stopTime = CMClockGetTime(CMClockGetHostTimeClock()) }
        stopping = true
        timer?.invalidate()
        timer = nil
        if startDate != nil { finishRecording() }
    }

    private func finishRecording() {
        guard !isSaving, let stream, let recorder else { return }
        isSaving = true
        tick()
        let end = stopTime ?? CMClockGetTime(CMClockGetHostTimeClock())
        Task {
            if !streamEnded {
                do { try await stream.stopCapture() } catch { stopError = stopError ?? error }
            }
            hideBoundary()
            do {
                try await recorder.finish(at: end)
            } catch {
                try? FileManager.default.removeItem(at: rawURL)
                complete(saved: false)
                CaptureCoordinator.showError("无法完成录屏", error)
                return
            }
            var mixError: Error?
            if mixAudio {
                do { try await RecordingAudio.mixTracks(in: rawURL) } catch { mixError = error }
            }
            do {
                try FileManager.default.moveItem(at: rawURL, to: outputURL)
                complete(saved: true)
                if let error = mixError { CaptureCoordinator.showError("混音失败，已保存独立音轨", error) }
                else if let error = stopError { CaptureCoordinator.showError("录制中断，已保存收到的画面", error) }
            } catch {
                complete(saved: false)
                CaptureCoordinator.showError("录屏已保留在 \(rawURL.path)", error)
            }
        }
    }

    private func hideBoundary() {
        boundary?.orderOut(nil)
        boundary?.close()
        boundary = nil
    }

    private func complete(saved: Bool) {
        guard Self.current === self else { return }
        hideBoundary()
        timer?.invalidate()
        stream = nil
        recorder = nil
        Self.current = nil
        NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
        if saved {
            ImageOutput.playCaptureSound()
            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.streamEnded = true
            self.requestStop(error: error)
        }
    }
}
