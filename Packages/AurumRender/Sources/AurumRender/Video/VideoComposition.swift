import AVFoundation
import CoreImage
import AurumCore

/// Supplies media to the video renderer. The app implements it with PhotoKit;
/// tests and previews use files.
public protocol VideoMediaSource: Sendable {
    /// The video for a library identifier.
    func videoAsset(for localIdentifier: String) async throws -> AVAsset
    /// A still image, longest side at most `maxPixelSize`.
    func image(for localIdentifier: String, maxPixelSize: CGFloat?) async throws -> CIImage
    /// A music file: a library track (downloaded and cached) or an imported file.
    func musicURL(for source: MusicSelection.Source) async throws -> URL
}

/// Everything AVFoundation needs to play or export a `VideoProject`.
public struct BuiltComposition {
    public let asset: AVMutableComposition
    public let videoComposition: AVMutableVideoComposition
    public let audioMix: AVMutableAudioMix
    public let renderSize: CGSize

    /// A player item for the Studio preview.
    public func playerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        return item
    }
}

public enum VideoCompositionError: Error {
    case emptyProject
    case missingVideoTrack(clipID: UUID)
}

/// Turns a `VideoProject` into an AVFoundation composition.
///
/// Video clips are laid on two alternating tracks (A/B roll) so a transition
/// can read both clips' frames at once. Photos have no track: the compositor
/// draws them from images loaded up front. Every frame is finished by
/// `AurumVideoCompositor`, which applies the same look stack, effects, layers
/// and watermark as photo export.
public enum VideoCompositionBuilder {
    static let timescale: CMTimeScale = 600

    public static func time(_ seconds: Seconds) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: timescale)
    }

    /// Output size for the project's aspect, with the longest side at most `maxPixelSize`.
    public static func renderSize(for aspect: AspectPreset, maxPixelSize: Int) -> CGSize {
        let ratio = aspect.ratio ?? 9.0 / 16.0
        let longest = CGFloat(maxPixelSize)
        // Even dimensions keep H.264/HEVC encoders happy.
        func even(_ v: CGFloat) -> CGFloat { (v / 2).rounded() * 2 }
        return ratio >= 1
            ? CGSize(width: even(longest), height: even(longest / CGFloat(ratio)))
            : CGSize(width: even(longest * CGFloat(ratio)), height: even(longest))
    }

    public static func build(_ project: VideoProject, media: VideoMediaSource, catalog: LookCatalog, maxPixelSize: Int, frameRate: Int = 30, watermark: String? = nil) async throws -> BuiltComposition {
        guard !project.clips.isEmpty else { throw VideoCompositionError.emptyProject }
        let renderSize = Self.renderSize(for: project.aspect, maxPixelSize: maxPixelSize)
        let composition = AVMutableComposition()
        let videoTracks = [
            composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
            composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        ].compactMap { $0 }
        let audioTracks = [
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        ].compactMap { $0 }

        var sources: [UUID: AurumCompositionInstruction.ClipSource] = [:]
        var audioParameters: [AVMutableAudioMixInputParameters] = audioTracks.map { AVMutableAudioMixInputParameters(track: $0) }
        let starts = project.clipStartTimes
        var videoCount = 0

        for (index, clip) in project.clips.enumerated() {
            let at = time(starts[index])
            switch clip.kind {
            case .photo:
                let image = try await media.image(for: clip.source.localIdentifier, maxPixelSize: max(renderSize.width, renderSize.height) * 1.15)
                sources[clip.id] = .still(image)
            case .video:
                var asset = try await media.videoAsset(for: clip.source.localIdentifier)
                if clip.isReversed {
                    asset = try await ReversedVideoCache.shared.reversed(asset, key: clip.source.localIdentifier)
                }
                guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                    throw VideoCompositionError.missingVideoTrack(clipID: clip.id)
                }
                let track = videoTracks[videoCount % videoTracks.count]
                // A reversed file runs backwards, so the trim maps from the end.
                let trimStart = clip.isReversed ? clip.sourceDuration - clip.trimEnd : clip.trimStart
                let range = CMTimeRange(start: time(trimStart), duration: time(clip.trimEnd - clip.trimStart))
                try track.insertTimeRange(range, of: sourceVideo, at: at)
                if clip.speed != 1 {
                    track.scaleTimeRange(CMTimeRange(start: at, duration: range.duration), toDuration: time(clip.duration))
                }
                let (transform, natural) = try await sourceVideo.load(.preferredTransform, .naturalSize)
                sources[clip.id] = .track(id: track.trackID, transform: transform, naturalSize: natural)

                if clip.volume > 0, !clip.isReversed,
                   let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                    let aIndex = videoCount % audioTracks.count
                    try audioTracks[aIndex].insertTimeRange(range, of: sourceAudio, at: at)
                    if clip.speed != 1 {
                        audioTracks[aIndex].scaleTimeRange(CMTimeRange(start: at, duration: range.duration), toDuration: time(clip.duration))
                    }
                    let params = audioParameters[aIndex]
                    let fade = min(clip.transitionIn.duration, clip.duration / 2)
                    if fade > 0 {
                        params.setVolumeRamp(fromStartVolume: 0, toEndVolume: Float(clip.volume), timeRange: CMTimeRange(start: at, duration: time(fade)))
                    } else {
                        params.setVolume(Float(clip.volume), at: at)
                    }
                }
                videoCount += 1
            }
        }

        // Music under everything, with fades.
        if let music = project.music {
            let url = try await media.musicURL(for: music.source)
            let musicAsset = AVURLAsset(url: url)
            if let musicTrack = try await musicAsset.loadTracks(withMediaType: .audio).first,
               let compTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let musicDuration = try await musicAsset.load(.duration).seconds
                let length = min(project.duration, max(0, musicDuration - music.startOffset))
                if length > 0 {
                    try compTrack.insertTimeRange(CMTimeRange(start: time(music.startOffset), duration: time(length)), of: musicTrack, at: .zero)
                    let params = AVMutableAudioMixInputParameters(track: compTrack)
                    let total = project.duration
                    // Sample the fade curve; AVFoundation ramps linearly between points.
                    let step = 0.25
                    var t = 0.0
                    while t < length {
                        let next = min(t + step, length)
                        params.setVolumeRamp(fromStartVolume: Float(music.gain(at: t, total: total)), toEndVolume: Float(music.gain(at: next, total: total)), timeRange: CMTimeRange(start: time(t), duration: time(next - t)))
                        t = next
                    }
                    audioParameters.append(params)
                }
            }
        }

        let instruction = AurumCompositionInstruction(
            project: project,
            sources: sources,
            catalog: catalog,
            renderSize: renderSize,
            watermark: watermark,
            timeRange: CMTimeRange(start: .zero, duration: time(project.duration)),
            trackIDs: videoTracks.map(\.trackID)
        )
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = AurumVideoCompositor.self
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        videoComposition.instructions = [instruction]

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = audioParameters
        return BuiltComposition(asset: composition, videoComposition: videoComposition, audioMix: audioMix, renderSize: renderSize)
    }
}

/// The single instruction covering the whole timeline. It carries the project
/// so the compositor can draw any frame from it.
public final class AurumCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    public enum ClipSource {
        case track(id: CMPersistentTrackID, transform: CGAffineTransform, naturalSize: CGSize)
        case still(CIImage)
    }

    public let project: VideoProject
    public let sources: [UUID: ClipSource]
    public let graph: FilterGraph
    public let gradeDocument: EditDocument
    public let renderSize: CGSize
    public let watermark: String?

    public let timeRange: CMTimeRange
    public let enablePostProcessing = false
    public let containsTweening = true
    public let requiredSourceTrackIDs: [NSValue]?
    public let passthroughTrackID = kCMPersistentTrackID_Invalid

    init(project: VideoProject, sources: [UUID: ClipSource], catalog: LookCatalog, renderSize: CGSize, watermark: String?, timeRange: CMTimeRange, trackIDs: [CMPersistentTrackID]) {
        self.project = project
        self.sources = sources
        self.graph = FilterGraph(catalog: catalog)
        // The look stack graded over every frame, reusing the photo pipeline.
        self.gradeDocument = EditDocument(
            id: project.id,
            source: SourceAsset(localIdentifier: "video", pixelSize: PixelSize(width: Int(renderSize.width), height: Int(renderSize.height))),
            operations: project.operations
        )
        self.renderSize = renderSize
        self.watermark = watermark
        self.timeRange = timeRange
        self.requiredSourceTrackIDs = trackIDs.map { NSNumber(value: $0) }
        super.init()
    }
}
