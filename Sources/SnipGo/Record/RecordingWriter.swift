import AVFoundation
import CoreImage
import ScreenCaptureKit
import VideoToolbox

enum RecordingColor {
    case rec709, displayP3

    var name: CFString { self == .displayP3 ? CGColorSpace.displayP3 : CGColorSpace.itur_709 }
    var videoProperties: [String: String] {
        [
            AVVideoColorPrimariesKey: self == .displayP3 ? AVVideoColorPrimaries_P3_D65 : AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: self == .displayP3 ? AVVideoTransferFunction_IEC_sRGB : AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]
    }
}

/// SCStream 的三个回调与静态桌面的指针更新共用一条串行队列。
final class RecordingWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "snipgo.record.writer", qos: .userInitiated)
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let pixels: AVAssetWriterInputPixelBufferAdaptor
    private let audio: [SCStreamOutputType: AVAssetWriterInput]
    private let pointer: RecordingPointer?
    private let onError: (Error) -> Void
    private let frameInterval: CMTime
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace: CGColorSpace
    private var firstTime: CMTime?
    private var lastTime: CMTime?
    private var lastScreen: CVPixelBuffer?
    private var screenStatus: SCFrameStatus = .started
    private var lastPointer = RecordingPointer.State()
    private var pointerTimer: DispatchSourceTimer?
    private var failure: Error?
    private var closing = false

    init(url: URL, width: Int, height: Int, fps: Int, color: RecordingColor, pointer: RecordingPointer?,
         systemAudio: Bool, microphone: Bool, onError: @escaping (Error) -> Void) throws {
        colorSpace = CGColorSpace(name: color.name)!
        self.pointer = pointer
        self.onError = onError
        frameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let codec: AVVideoCodecType = max(width, height) > 4096 || width * height > 4096 * 2304 ? .hevc : .h264
        var compression: [String: Any] = [
            AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoAllowFrameReorderingKey: false
        ]
        var supported: CFDictionary?
        let codecType = codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
        let status = VTCopySupportedPropertyDictionaryForEncoder(width: Int32(width), height: Int32(height),
                         codecType: codecType, encoderSpecification: nil, encoderIDOut: nil, supportedPropertiesOut: &supported)
        if status == noErr, (supported as NSDictionary?)?[kVTCompressionPropertyKey_Quality] != nil {
            // 以系统录屏样片校准质量，编码器按每帧的内容分配数据。
            compression[kVTCompressionPropertyKey_Quality as String] = 0.86
        } else {
            // 部分编码器只支持平均码率，按输出像素数给出兼容目标。
            compression[AVVideoAverageBitRateKey] = max(1_500_000, Int(Double(width * height) * min(Double(fps), 37.6) * 0.29))
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: color.videoProperties
        ]
        video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = true
        video.mediaTimeScale = 60_000
        pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        guard writer.canAdd(video) else { throw Self.error("编码器不支持当前录制尺寸。") }
        writer.add(video)
        var inputs: [SCStreamOutputType: AVAssetWriterInput] = [:]
        for (type, enabled) in [(SCStreamOutputType.audio, systemAudio), (.microphone, microphone)] where enabled {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: type == .microphone ? 1 : 2, AVEncoderBitRateKey: type == .microphone ? 96_000 : 192_000
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw Self.error("无法添加录音轨道。") }
            writer.add(input)
            inputs[type] = input
        }
        audio = inputs
        super.init()
        guard writer.startWriting() else { throw writer.error ?? Self.error("无法创建视频文件。") }
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: "SnipGo.Recording", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !closing, failure == nil, sample.isValid, sample.dataReadiness == .ready else { return }
        if type != .screen {
            appendAudio(sample, type: type)
            return
        }
        guard let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                          as? [[SCStreamFrameInfo: Any]])?.first, let raw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return }
        switch status {
        case .complete, .started:
            guard let buffer = sample.imageBuffer else { return }
            screenStatus = status
            appendScreen(buffer, at: sample.presentationTimeStamp)
        case .blank:
            guard screenStatus != .blank, let lastScreen else { return }
            screenStatus = .blank
            var blank: CVPixelBuffer?
            guard let pool = pixels.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &blank) == kCVReturnSuccess, let blank else {
                fail(Self.error("无法分配黑屏画面。"))
                return
            }
            let bounds = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(lastScreen), height: CVPixelBufferGetHeight(lastScreen))
            context.render(CIImage(color: .black), to: blank, bounds: bounds, colorSpace: colorSpace)
            self.lastScreen = blank
            append(blank, at: sample.presentationTimeStamp, state: .init())
        case .suspended, .stopped:
            screenStatus = status
        default:
            break
        }
    }

    func appendAudio(_ sample: CMSampleBuffer, type: SCStreamOutputType) {
        guard !closing, failure == nil, let firstTime, sample.presentationTimeStamp >= firstTime,
              let input = audio[type] else { return }
        if input.isReadyForMoreMediaData, !input.append(sample) { fail() }
        else if writer.status == .failed { fail() }
    }

    func appendScreen(_ buffer: CVPixelBuffer, at time: CMTime) {
        guard !closing, failure == nil else { return }
        if firstTime == nil {
            writer.startSession(atSourceTime: time)
            firstTime = time
            if pointer != nil { startPointerTimer() }
        }
        lastScreen = buffer
        append(buffer, at: time, state: pointer?.sample() ?? .init())
    }

    private func startPointerTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + frameInterval.seconds, repeating: frameInterval.seconds)
        timer.setEventHandler { [weak self] in
            guard let self, !closing, failure == nil, screenStatus == .complete || screenStatus == .started,
                  let lastScreen, let lastTime, let pointer else { return }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            // 屏幕有连续新帧时沿用采集时间戳；静止时只为鼠标的变化补帧。
            guard (now - lastTime).seconds >= frameInterval.seconds * 1.5 else { return }
            let state = pointer.sample()
            if state != lastPointer { append(lastScreen, at: now, state: state) }
        }
        pointerTimer = timer
        timer.resume()
    }

    private func append(_ buffer: CVPixelBuffer, at time: CMTime, state: RecordingPointer.State) {
        guard video.isReadyForMoreMediaData else {
            if writer.status == .failed { fail() }
            return
        }
        let stamp = max(time, lastTime.map { $0 + CMTime(value: 1, timescale: 60_000) } ?? time)
        var result = buffer
        if let pointer, state.position != nil {
            var output: CVPixelBuffer?
            guard let pool = pixels.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess,
                  let output else { fail(Self.error("无法分配视频帧。")); return }
            let image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: colorSpace])
            CVBufferPropagateAttachments(buffer, output)
            context.render(pointer.frame(image, state: state), to: output, bounds: image.extent, colorSpace: colorSpace)
            result = output
        }
        guard pixels.append(result, withPresentationTime: stamp) else { fail(); return }
        lastTime = stamp
        lastPointer = state
    }

    private func fail(_ error: Error? = nil) {
        guard failure == nil else { return }
        let reason = error ?? writer.error ?? Self.error("视频编码失败。")
        failure = reason
        onError(reason)
    }

    func cancel() {
        queue.sync {
            self.closing = true
            self.pointerTimer?.cancel()
            if self.writer.status == .writing { self.writer.cancelWriting() }
            self.lastScreen = nil
        }
    }

    func finish(at stop: CMTime) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                closing = true
                pointerTimer?.cancel()
                guard failure == nil, let lastTime, let lastScreen else {
                    if writer.status == .writing { writer.cancelWriting() }
                    done.resume(throwing: failure ?? Self.error("未收到可保存的屏幕帧。"))
                    return
                }
                let end = max(stop, lastTime + frameInterval)
                // 一个静止画面可以持续几分钟，让最后一个画面确实覆盖到停止时刻。
                if (end - lastTime).seconds > frameInterval.seconds * 2 {
                    append(lastScreen, at: end - frameInterval, state: lastPointer)
                }
                self.lastScreen = nil
                guard writer.status == .writing else { done.resume(throwing: writer.error ?? Self.error("录屏写入失败。")); return }
                writer.endSession(atSourceTime: end)
                video.markAsFinished()
                audio.values.forEach { $0.markAsFinished() }
                writer.finishWriting { [writer] in
                    if writer.status == .completed { done.resume() }
                    else { done.resume(throwing: writer.error ?? Self.error("无法完成视频文件。")) }
                }
            }
        }
    }
}
