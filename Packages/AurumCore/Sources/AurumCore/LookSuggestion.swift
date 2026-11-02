import Foundation

/// Simple statistics about a photo, measured on device by the renderer.
public struct ImageStats: Equatable, Sendable {
    /// Average luminance, 0...1.
    public var luminance: Double
    /// Average saturation, 0...1.
    public var saturation: Double
    /// Red minus blue of the average colour, -1...1. Positive is warm.
    public var warmth: Double

    public init(luminance: Double, saturation: Double, warmth: Double) {
        self.luminance = luminance
        self.saturation = saturation
        self.warmth = warmth
    }
}

/// Picks the look shown when a photo first opens in the Studio.
///
/// Phase 1 uses transparent rules rather than a model: prefer the user's
/// chosen aesthetics, then match the photo's mood. Only free looks are
/// suggested, so the first export never hits the paywall.
public enum LookSuggestion {
    public static func suggest(for stats: ImageStats, vibes: [String], catalog: LookCatalog) -> LookRecipe? {
        let free = catalog.looks.filter { $0.tier == .free }
        guard !free.isEmpty else { return nil }

        let moodCollection: String
        if stats.saturation < 0.08 {
            moodCollection = "noir"
        } else if stats.luminance < 0.3 {
            moodCollection = "nocturne"
        } else if stats.luminance > 0.7 {
            moodCollection = "haze"
        } else if stats.warmth > 0.08 {
            moodCollection = "film-analog"
        } else if stats.saturation > 0.45 {
            moodCollection = "riviera"
        } else {
            moodCollection = "cinematic"
        }

        // A vibe the user chose wins, unless the photo is black and white.
        let preferred: [String]
        if moodCollection == "noir" {
            preferred = ["noir"]
        } else if vibes.contains(moodCollection) {
            preferred = [moodCollection]
        } else {
            preferred = vibes + [moodCollection]
        }
        for collection in preferred {
            if let look = free.first(where: { $0.collection == collection }) { return look }
        }
        return free.first
    }
}
