import AVFoundation
import XCTest
@testable import SnipGo

final class RecordingWriterTests: XCTestCase {
    func testResolutionFitsLandscapeAndPortraitWithoutUpscaling() {
        let landscape = CGSize(width: 5120, height: 2880)
        let portrait = CGSize(width: 2880, height: 5120)
        for (preset, width, height) in [(RecordingResolution.original, 5120, 2880), (.p2160, 3840, 2160),
                                        (.p1440, 2560, 1440), (.p1080, 1920, 1080), (.p720, 1280, 720)] {
            XCTAssertEqual(preset.outputSize(for: landscape), CGSize(width: width, height: height))
            XCTAssertEqual(preset.outputSize(for: portrait), CGSize(width: height, height: width))
            XCTAssertEqual(preset.outputSize(for: CGSize(width: 601, height: 301)), CGSize(width: 600, height: 300))
        }
        XCTAssertEqual(RecordingResolution.p1080.outputSize(for: CGSize(width: 3406, height: 2070)),
                       CGSize(width: 1778, height: 1080))
        XCTAssertEqual(RecordingResolution.p720.outputSize(for: CGSize(width: 1440, height: 1440)),
                       CGSize(width: 720, height: 720))
    }

    func testRecordingPreservesVariableFrameTimesAndStaticTail() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try RecordingWriter(url: url, width: 320, height: 160, fps: 60, color: .rec709,
                                           pointer: nil, systemAudio: false, microphone: false) { XCTFail($0.localizedDescription) }
        var image: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 320, 160, kCVPixelFormatType_32BGRA, nil, &image), kCVReturnSuccess)
        let buffer = try XCTUnwrap(image)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let start = CMClockGetTime(CMClockGetHostTimeClock())
        let ticks: [Int64] = [0, 10, 25, 45]
        recorder.queue.sync {
            for tick in ticks {
                recorder.appendScreen(buffer, at: start + CMTime(value: tick, timescale: 600))
            }
        }
        try await recorder.finish(at: start + CMTime(value: 2, timescale: 1))

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let (size, range) = try await track.load(.naturalSize, .timeRange)
        XCTAssertEqual(size, CGSize(width: 320, height: 160))
        XCTAssertEqual(range.duration.seconds, 2, accuracy: 0.002)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var times: [Int64] = []
        while let frame = output.copyNextSampleBuffer() {
            guard frame.numSamples > 0 else { continue }
            times.append(frame.presentationTimeStamp.convertScale(600, method: .roundHalfAwayFromZero).value)
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(Array(times.prefix(ticks.count)), ticks)
    }
}
