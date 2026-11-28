import AVFoundation

enum RecordingAudio {
    /// 播放器通常只播放第一条音轨。混合系统声音和麦克风后，原样封装已编码的视频。
    static func mixTracks(in url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.count > 1 else { return }
        let audio = AVMutableComposition()
        var parameters: [AVAudioMixInputParameters] = []
        for track in tracks {
            let dest = try await add(track, to: audio)
            let input = AVMutableAudioMixInputParameters(track: dest)
            input.setVolume(1, at: .zero)
            parameters.append(input)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        let base = url.deletingLastPathComponent().appendingPathComponent(".snipgo-" + UUID().uuidString)
        let mergedAudio = base.appendingPathExtension("m4a")
        let mergedMovie = base.appendingPathExtension("mp4")
        defer {
            try? FileManager.default.removeItem(at: mergedAudio)
            try? FileManager.default.removeItem(at: mergedMovie)
        }
        guard let encoder = AVAssetExportSession(asset: audio, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecordingWriter.error("无法创建混音文件。")
        }
        encoder.audioMix = mix
        try await encoder.export(to: mergedAudio, as: .m4a)
        let mux = AVMutableComposition()
        let soundAsset = AVURLAsset(url: mergedAudio)
        defer { withExtendedLifetime((asset, soundAsset)) {} }
        guard let video = try await asset.loadTracks(withMediaType: .video).first,
              let sound = try await soundAsset.loadTracks(withMediaType: .audio).first else {
            throw RecordingWriter.error("混音时未找到视频或音轨。")
        }
        _ = try await add(video, to: mux)
        _ = try await add(sound, to: mux)
        guard let passthrough = AVAssetExportSession(asset: mux, presetName: AVAssetExportPresetPassthrough) else {
            throw RecordingWriter.error("无法封装混音后的视频。")
        }
        try await passthrough.export(to: mergedMovie, as: .mp4)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: mergedMovie)
    }

    private static func add(_ track: AVAssetTrack, to composition: AVMutableComposition) async throws -> AVMutableCompositionTrack {
        let range = try await track.load(.timeRange)
        guard let dest = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RecordingWriter.error("无法创建媒体轨道。")
        }
        try dest.insertTimeRange(range, of: track, at: range.start)
        return dest
    }
}
