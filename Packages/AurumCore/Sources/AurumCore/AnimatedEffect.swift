import Foundation

/// An effect whose strength changes over time on video: flicker, drifting
/// light leaks, glitter, VHS tracking, camera shake and zoom pulses.
///
/// `sample(at:)` is a pure function of time and the effect's seed, so the
/// preview and the export show exactly the same frames.
public struct AnimatedEffect: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case flicker, lightLeak, glitter, vhsTracking, shake, zoomPulse

        public var displayName: String {
            switch self {
            case .flicker: return "Flicker"
            case .lightLeak: return "Light Leak"
            case .glitter: return "Glitter"
            case .vhsTracking: return "Tape Tracking"
            case .shake: return "Handheld"
            case .zoomPulse: return "Pulse"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    /// 0...1
    public var intensity: Double
    /// Cycles per second for periodic effects.
    public var rate: Double
    public var start: Seconds
    /// nil means until the end.
    public var end: Seconds?
    public var seed: UInt64
    public var tier: Tier

    public init(id: UUID = UUID(), kind: Kind, intensity: Double = 0.6, rate: Double = 1, start: Seconds = 0, end: Seconds? = nil, seed: UInt64 = 1, tier: Tier = .free) {
        self.id = id
        self.kind = kind
        self.intensity = (0.0...1.0).clamp(intensity)
        self.rate = max(0.05, rate)
        self.start = max(0, start)
        self.end = end
        self.seed = seed
        self.tier = tier
    }

    /// The effect's parameters at a moment.
    public struct Sample: Equatable, Sendable {
        /// Brightness multiplier around 1 (flicker).
        public var exposure: Double = 1
        /// Light-leak strength and its horizontal position, 0...1.
        public var leak: Double = 0
        public var leakPosition: Double = 0.5
        /// Glitter density, 0...1.
        public var glitter: Double = 0
        /// VHS line offset strength, 0...1.
        public var tracking: Double = 0
        /// Camera offset in normalised units and extra zoom.
        public var offsetX: Double = 0
        public var offsetY: Double = 0
        public var zoom: Double = 1

        public init() {}
    }

    public func isActive(at t: Seconds) -> Bool {
        t >= start && (end.map { t < $0 } ?? true)
    }

    public func sample(at t: Seconds) -> Sample {
        var s = Sample()
        guard isActive(at: t), intensity > 0 else { return s }
        let local = t - start
        let k = intensity
        switch kind {
        case .flicker:
            // Two incommensurate sines plus a little noise read as projector flicker.
            let wave = sin(local * rate * 2 * .pi * 3.1) * 0.5 + sin(local * rate * 2 * .pi * 7.3) * 0.3
            s.exposure = 1 + k * 0.12 * (wave + 0.4 * Self.noise(local * 24, seed: seed))
        case .lightLeak:
            let phase = local * rate * 0.25
            s.leak = k * (0.55 + 0.45 * sin(phase * 2 * .pi))
            s.leakPosition = 0.5 + 0.45 * sin(phase * 2 * .pi * 0.7 + 1.3)
        case .glitter:
            s.glitter = k * (0.6 + 0.4 * abs(sin(local * rate * 2 * .pi)))
        case .vhsTracking:
            // Mostly calm with occasional bursts.
            let burst = max(0, Self.noise(local * rate * 0.8, seed: seed) - 0.3) / 0.7
            s.tracking = k * burst
        case .shake:
            s.offsetX = k * 0.012 * Self.noise(local * rate * 6, seed: seed)
            s.offsetY = k * 0.012 * Self.noise(local * rate * 6, seed: seed &+ 7)
            s.zoom = 1 + k * 0.03
        case .zoomPulse:
            let beat = (local * rate).truncatingRemainder(dividingBy: 1)
            s.zoom = 1 + k * 0.06 * exp(-beat * 6)
        }
        return s
    }

    /// Smooth value noise in -1...1, deterministic for a seed.
    static func noise(_ x: Double, seed: UInt64) -> Double {
        let i = floor(x)
        let f = x - i
        let a = hash(Int64(i), seed), b = hash(Int64(i) + 1, seed)
        let u = f * f * (3 - 2 * f)
        return a + (b - a) * u
    }

    static func hash(_ n: Int64, _ seed: UInt64) -> Double {
        var h = UInt64(bitPattern: n) &* 0x9E3779B97F4A7C15 ^ seed
        h ^= h >> 31
        h &*= 0xBF58476D1CE4E5B9
        h ^= h >> 29
        return Double(h % 2_000_001) / 1_000_000 - 1
    }
}

/// Royalty-free music: the catalogue lists tracks served from the CDN.
/// Tracks must be licensed before launch; the bundled catalogue is empty.
public struct MusicTrack: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var artist: String
    public var mood: String
    public var duration: Seconds
    public var beats: BeatGrid
    public var tier: Tier
    /// Path on the CDN, relative to the content base URL.
    public var path: String
    /// Licence reference for the audit trail.
    public var licence: String

    public init(id: String, title: String, artist: String, mood: String, duration: Seconds, beats: BeatGrid, tier: Tier, path: String, licence: String) {
        self.id = id
        self.title = title
        self.artist = artist
        self.mood = mood
        self.duration = duration
        self.beats = beats
        self.tier = tier
        self.path = path
        self.licence = licence
    }
}
