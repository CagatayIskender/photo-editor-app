import Foundation

/// Beat times for a music track, from on-device beat detection or the
/// library's metadata. Used to cut template slots on the beat.
public struct BeatGrid: Codable, Equatable, Sendable {
    public var bpm: Double
    /// Time of the first downbeat in the track.
    public var offset: Seconds

    public init(bpm: Double, offset: Seconds = 0) {
        self.bpm = min(max(bpm, 40), 220)
        self.offset = max(0, offset)
    }

    public var beatLength: Seconds { 60 / bpm }

    /// Beat times from `start` (track time) until `end`.
    public func beats(from start: Seconds, to end: Seconds) -> [Seconds] {
        guard end > start else { return [] }
        let first = max(0, ((start - offset) / beatLength).rounded(.up))
        var result: [Seconds] = []
        var n = first
        while true {
            let t = offset + n * beatLength
            if t >= end { break }
            result.append(t)
            n += 1
        }
        return result
    }

    /// The nearest beat to t.
    public func quantize(_ t: Seconds) -> Seconds {
        offset + ((t - offset) / beatLength).rounded() * beatLength
    }
}

/// One slot in a template: a photo or clip shown for a number of beats.
public struct TemplateSlot: Codable, Equatable, Sendable {
    public var beats: Int
    public var transition: Transition
    /// Optional look applied to this slot only (a slot-level grade).
    public var lookID: String?
    /// Push-in, drift... applied to stills so they don't sit flat.
    public var motion: StillMotion

    public init(beats: Int, transition: Transition = .cut, lookID: String? = nil, motion: StillMotion = .pushIn) {
        self.beats = max(1, beats)
        self.transition = transition
        self.lookID = lookID
        self.motion = motion
    }
}

/// Gentle camera moves for still photos in video (Ken Burns style).
public enum StillMotion: String, Codable, CaseIterable, Sendable {
    case none, pushIn, pullOut, driftLeft, driftRight

    /// Scale and normalised offset at progress p (0...1) through the slot.
    public func transform(at p: Double) -> (scale: Double, dx: Double, dy: Double) {
        let p = (0.0...1.0).clamp(p)
        switch self {
        case .none: return (1, 0, 0)
        case .pushIn: return (1 + 0.08 * p, 0, 0)
        case .pullOut: return (1.08 - 0.08 * p, 0, 0)
        case .driftLeft: return (1.06, 0.03 - 0.06 * p, 0)
        case .driftRight: return (1.06, -0.03 + 0.06 * p, 0)
        }
    }
}

/// A one-tap video template: pick media, and AURUM builds the edit on the beat.
public struct TemplateDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var tagline: String
    public var tier: Tier
    public var aspect: AspectPreset
    public var slots: [TemplateSlot]
    /// Default music; the user can swap it.
    public var musicTrackID: String?
    /// Tempo the slots were designed for; used when the track has no beat grid.
    public var bpm: Double
    public var lookID: String?
    public var effects: [AnimatedEffect]
    public var intro: BookendEffect?
    public var outro: BookendEffect?

    public init(id: String, name: String, tagline: String, tier: Tier, aspect: AspectPreset = .story, slots: [TemplateSlot], musicTrackID: String? = nil, bpm: Double = 100, lookID: String? = nil, effects: [AnimatedEffect] = [], intro: BookendEffect? = nil, outro: BookendEffect? = nil) {
        self.id = id
        self.name = name
        self.tagline = tagline
        self.tier = tier
        self.aspect = aspect
        self.slots = slots
        self.musicTrackID = musicTrackID
        self.bpm = bpm
        self.lookID = lookID
        self.effects = effects
        self.intro = intro
        self.outro = outro
    }

    /// How many photos or clips the template asks for.
    public var mediaCount: Int { slots.count }
}

/// A photo or video the user picked for a template.
public struct TemplateMedia: Equatable, Sendable {
    public var source: SourceAsset
    public var kind: Clip.Kind
    /// Video length; ignored for photos.
    public var duration: Seconds

    public init(source: SourceAsset, kind: Clip.Kind, duration: Seconds = 0) {
        self.source = source
        self.kind = kind
        self.duration = duration
    }
}

public enum TemplateBuilder {
    public enum BuildError: Error, Equatable {
        case noMedia
    }

    /// Builds a project: each slot gets the next media item (cycling if there
    /// are fewer items than slots), lasting exactly its beats so every cut
    /// lands on the beat. Videos use their middle section, which is usually
    /// the best part of a phone clip.
    public static func build(_ template: TemplateDefinition, media: [TemplateMedia], music: MusicSelection? = nil) throws -> VideoProject {
        guard !media.isEmpty else { throw BuildError.noMedia }
        let grid = music?.beats ?? BeatGrid(bpm: template.bpm)
        var project = VideoProject(aspect: template.aspect, templateID: template.id)
        project.music = music
        project.intro = template.intro
        project.outro = template.outro
        project.effects = template.effects
        if let look = template.lookID {
            project.operations = [EditOperation(kind: .look(LookApplication(lookID: look)))]
        }

        for (i, slot) in template.slots.enumerated() {
            let item = media[i % media.count]
            let length = Double(slot.beats) * grid.beatLength
            // The overlap of a transition is added back so the cut still lands on the beat.
            let overlap = i == 0 ? 0 : slot.transition.duration
            let wanted = length + overlap
            var clip: Clip
            switch item.kind {
            case .photo:
                clip = Clip(kind: .photo, source: item.source, sourceDuration: wanted)
            case .video:
                let available = max(item.duration, Clip.minimumDuration)
                if available >= wanted {
                    let start = (available - wanted) / 2
                    clip = Clip(kind: .video, source: item.source, sourceDuration: available, trimStart: start, trimEnd: start + wanted)
                } else {
                    // Too short: slow it down to fill the slot, down to quarter speed.
                    clip = Clip(kind: .video, source: item.source, sourceDuration: available)
                    clip.setSpeed(available / wanted)
                }
            }
            clip.transitionIn = i == 0 ? .cut : slot.transition
            project.clips.append(clip)
        }
        return project
    }
}
