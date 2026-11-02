import AVFoundation
import AurumCore

/// Exports a built composition to a movie file.
public enum VideoExporter {
    public enum ExportError: Error {
        case cannotCreateSession
        case failed(Error?)
        case cancelled
    }

    /// Picks the export preset for the output size: HEVC for 4K, H.264 otherwise
    /// for the widest sharing compatibility.
    static func preset(for size: CGSize) -> String {
        max(size.width, size.height) > 1920 ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
    }

    /// Writes the video and reports progress (0...1) on the main actor.
    public static func export(_ built: BuiltComposition, to url: URL, progress: @escaping @MainActor (Double) -> Void = { _ in }) async throws {
        try? FileManager.default.removeItem(at: url)
        guard let session = AVAssetExportSession(asset: built.asset, presetName: preset(for: built.renderSize)) else {
            throw ExportError.cannotCreateSession
        }
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        session.outputURL = url
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        let poll = Task {
            while !Task.isCancelled {
                let value = Double(session.progress)
                await progress(value)
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        await session.export()
        poll.cancel()
        switch session.status {
        case .completed:
            await progress(1)
        case .cancelled:
            throw ExportError.cancelled
        default:
            throw ExportError.failed(session.error)
        }
    }
}

/// Reversed copies of videos, made once and cached in Caches/Reversed.
///
/// AVFoundation can't play a track backwards inside a composition, so a
/// reversed clip is rendered to a file frame by frame (video only; reversed
/// clips are muted, as in most editors).
public actor ReversedVideoCache {
    public static let shared = ReversedVideoCache()
    private var inFlight: [String: Task<AVAsset, Error>] = [:]

    public enum ReverseError: Error { case noVideoTrack, writerFailed }

    func directory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Reversed", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public func reversed(_ asset: AVAsset, key: String) async throws -> AVAsset {
        let safeKey = key.replacingOccurrences(of: "/", with: "_")
        let url = directory().appendingPathComponent("\(safeKey).mov")
        if FileManager.default.fileExists(atPath: url.path) { return AVURLAsset(url: url) }
        if let task = inFlight[safeKey] { return try await task.value }
        let task = Task { try await Self.writeReversed(asset, to: url) }
        inFlight[safeKey] = task
        defer { inFlight[safeKey] = nil }
        return try await task.value
    }

    /// Reads every frame, then writes them in reverse order with the original timing.
    static func writeReversed(_ asset: AVAsset, to url: URL) async throws -> AVAsset {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ReverseError.noVideoTrack }
        let (size, transform, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.startReading()

        // Phone clips are short; holding their frames is acceptable for Phase 2.
        // Longer clips should be reversed in segments (see the architecture doc).
        var samples: [CMSampleBuffer] = []
        while let sample = output.copyNextSampleBuffer() { samples.append(sample) }
        guard !samples.isEmpty else { throw ReverseError.noVideoTrack }

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height
        ])
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(rate, 1).rounded()))
        var time = CMTime.zero
        for sample in samples.reversed() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            adaptor.append(buffer, withPresentationTime: time)
            time = CMTimeAdd(time, frameDuration)
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw ReverseError.writerFailed }
        return AVURLAsset(url: url)
    }
}
