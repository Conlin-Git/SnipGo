import AppKit
import AVFoundation
import ScreenCaptureKit

/// 屏幕与音频回调共用同一串行队列。首个完整视频帧用于对齐鼠标轨迹。
private final class RecordingStreamOutput: NSObject, SCStreamOutput {
    private(set) var firstFrameTime: Double?

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, firstFrameTime == nil,
              let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                          as? [[SCStreamFrameInfo: Any]])?.first,
              let status = info[.status] as? Int, status == SCFrameStatus.complete.rawValue else { return }
        firstFrameTime = buffer.presentationTimeStamp.seconds
    }
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
    private var boundary: RecordingBoundary?
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private let streamOutput = RecordingStreamOutput()
    private var pointer: RecordingPointer?
    private var captureStartTime: Double = 0
    private(set) var isSaving = false
    private let outputQueue = DispatchQueue(label: "snipgo.record.samples")
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
                session.teardown()
                current = nil
                NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
                if !session.stopping { CaptureCoordinator.showError("无法开始录制", error) }
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

        guard !stopping else { finishUp(success: false); return }
        let outline = RecordingBoundary(screen: snapshot.screen, localRect: rect)
        boundary = outline
        outline.orderFrontRegardless()
        let filter = try await outline.captureFilter(for: snapshot.display)
        guard !stopping else { finishUp(success: false); return }
        let scale = snapshot.screen.backingScaleFactor
        let cfg = SCStreamConfiguration()
        if !isFullScreen {
            cfg.sourceRect = ScreenSnapshotter.sourceRect(forLocal: rect, screenHeight: snapshot.screen.frame.height)
        }
        cfg.width = max(2, Int((rect.width * scale).rounded()) & ~1)
        cfg.height = max(2, Int((rect.height * scale).rounded()) & ~1)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        if AppSettings.recordShowClicks {
            let region = rect.offsetBy(dx: snapshot.screen.frame.minX, dy: snapshot.screen.frame.minY)
            pointer = RecordingPointer(region: region, showsHand: AppSettings.recordShowCursor)
        }
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
        try s.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: outputQueue)
        if cfg.capturesAudio { try s.addStreamOutput(streamOutput, type: .audio, sampleHandlerQueue: outputQueue) }
        if useMic { try s.addStreamOutput(streamOutput, type: .microphone, sampleHandlerQueue: outputQueue) }

        let rc = SCRecordingOutputConfiguration()
        rc.outputURL = outputURL
        rc.outputFileType = .mp4
        rc.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: rc, delegate: self)
        try s.addRecordingOutput(output)
        recordingOutput = output
        stream = s

        captureStartTime = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        pointer?.start()
        try await s.startCapture()
        guard Self.current === self else { try? await s.stopCapture(); return }
        startDate = Date()
        if stopping { stopStream(s); return }
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
        // 启动期间按停止，由 begin() 在下一个异步边界收尾。
        guard startDate != nil, let s = stream else { return }
        stopStream(s)
    }

    private func stopStream(_ s: SCStream) {
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
        guard Self.current === self, !isSaving else { return }
        teardown()
        if success, let pointer {
            isSaving = true
            stopping = true
            tick()
            let firstFrame = outputQueue.sync { streamOutput.firstFrameTime } ?? captureStartTime
            Task {
                do {
                    try await pointer.finishVideo(at: outputURL, firstFrameTime: firstFrame)
                } catch {
                    CaptureCoordinator.showError("鼠标效果导出失败，已保留原始录屏", error)
                }
                complete(success: true)
            }
        } else {
            complete(success: success)
        }
    }

    private func complete(success: Bool) {
        Self.current = nil
        NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
        if success {
            ImageOutput.playCaptureSound()
            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
        }
    }

    private func teardown() {
        pointer?.stop()
        boundary?.orderOut(nil)
        boundary?.close()
        boundary = nil
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
