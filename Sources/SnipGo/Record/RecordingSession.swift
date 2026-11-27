import AppKit
import AVFoundation
import ScreenCaptureKit

/// 空输出：让 SCStream 有对应类型的接收者，避免丢帧日志
final class NullStreamOutput: NSObject, SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
}

extension Notification.Name {
    static let recordingStateChanged = Notification.Name("SnipGo.recordingStateChanged")
}

@MainActor
final class RecordingSession: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    static private(set) var current: RecordingSession?

    static var isRecording: Bool { current != nil }

    private let snapshot: ScreenSnapshot
    private let rect: CGRect          // 屏幕本地坐标
    private let outputURL: URL
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private let nullOutput = NullStreamOutput()
    private let outputQueue = DispatchQueue(label: "snipgo.record.null")
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
                session.teardown()
                current = nil
                NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
                CaptureCoordinator.showError("无法开始录制", error)
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

        // QuickTime 风格：录制中不显示边框和浮窗，通过菜单栏停止按钮结束
        // 录制中本应用没有遮挡窗口；钉图属于屏幕内容，一并录入
        let filter = SCContentFilter(display: snapshot.display, excludingWindows: [])
        let scale = snapshot.screen.backingScaleFactor
        let cfg = SCStreamConfiguration()
        if !isFullScreen {
            cfg.sourceRect = ScreenSnapshotter.sourceRect(forLocal: rect, screenHeight: snapshot.screen.frame.height)
        }
        // H.264 要求偶数尺寸
        cfg.width = max(2, Int((rect.width * scale).rounded()) & ~1)
        cfg.height = max(2, Int((rect.height * scale).rounded()) & ~1)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.showsCursor = AppSettings.recordShowCursor
        cfg.queueDepth = 6
        cfg.captureResolution = .best
        cfg.capturesAudio = AppSettings.recordSystemAudio
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        cfg.captureMicrophone = useMic

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(nullOutput, type: .screen, sampleHandlerQueue: outputQueue)
        if cfg.capturesAudio { try s.addStreamOutput(nullOutput, type: .audio, sampleHandlerQueue: outputQueue) }
        if useMic { try s.addStreamOutput(nullOutput, type: .microphone, sampleHandlerQueue: outputQueue) }

        let rc = SCRecordingOutputConfiguration()
        rc.outputURL = outputURL
        rc.outputFileType = .mp4
        rc.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: rc, delegate: self)
        try s.addRecordingOutput(output)
        recordingOutput = output
        stream = s

        try await s.startCapture()
        startDate = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    private func tick() {
        NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
    }

    func stop() {
        guard !stopping else { return }
        stopping = true
        timer?.invalidate()
        timer = nil
        guard let s = stream else {
            teardown()
            finishUp(success: false)
            return
        }
        Task { @MainActor in
            do {
                try await s.stopCapture()
            } catch {
                // stopCapture 失败时仍尝试收尾
            }
            // recordingOutputDidFinishRecording 会回调；保险起见延迟兜底
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Self.current === self { self.finishUp(success: FileManager.default.fileExists(atPath: self.outputURL.path)) }
        }
    }

    private func finishUp(success: Bool) {
        guard Self.current === self else { return }
        teardown()
        Self.current = nil
        NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
        if success {
            ImageOutput.playCaptureSound()
            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
        }
    }

    private func teardown() {
        timer?.invalidate()
        timer = nil
        stream = nil
        recordingOutput = nil
    }

    // MARK: - SCRecordingOutputDelegate

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.finishUp(success: true) }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            let wasStopping = self.stopping
            self.finishUp(success: false)
            if !wasStopping { CaptureCoordinator.showError("录制失败", error) }
        }
    }

    // MARK: - SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            if !self.stopping {
                self.stopping = true
                self.finishUp(success: FileManager.default.fileExists(atPath: self.outputURL.path))
                CaptureCoordinator.showError("录制已停止", error)
            }
        }
    }
}
