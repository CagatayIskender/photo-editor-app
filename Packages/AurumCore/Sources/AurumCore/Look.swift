import Foundation

/// Whether an item is free or needs AURUM Membership to export.
public enum Tier: String, Codable, Sendable {
    case free
    case member
}

/// The parameters a look recipe sets. Values use the same normalised ranges
/// as `AdjustmentSet`. Missing keys in JSON take their neutral default, so new
/// parameters can be added without touching existing recipes.
public struct LookParameters: Codable, Equatable, Sendable {
    public var exposure: Double = 0
    public var contrast: Double = 0
    public var highlights: Double = 0
    public var shadows: Double = 0
    public var saturation: Double = 0
    public var vibrance: Double = 0
    public var warmth: Double = 0
    public var tint: Double = 0
    /// 0...1, lifts the black point for a matte finish.
    public var fade: Double = 0
    /// 0...1
    public var grain: Double = 0
    /// 0.5...2, relative grain size.
    public var grainSize: Double = 1
    /// 0...1, darkens corners.
    public var vignette: Double = 0
    /// 0...1, warm light leak strength.
    public var lightLeak: Double = 0
    /// 0...1, highlight glow.
    public var bloom: Double = 0
    /// Linear RGB multipliers mixed into shadows and highlights; [1, 1, 1] is neutral.
    public var shadowsTint: [Double] = [1, 1, 1]
    public var highlightsTint: [Double] = [1, 1, 1]
    /// Renders in black and white before toning.
    public var monochrome: Bool = false

    public init() {}

    enum CodingKeys: String, CodingKey {
        case exposure, contrast, highlights, shadows, saturation, vibrance, warmth, tint
        case fade, grain, grainSize, vignette, lightLeak, bloom, shadowsTint, highlightsTint, monochrome
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d(_ k: CodingKeys, _ fallback: Double = 0) throws -> Double {
            try c.decodeIfPresent(Double.self, forKey: k) ?? fallback
        }
        exposure = try d(.exposure)
        contrast = try d(.contrast)
        highlights = try d(.highlights)
        shadows = try d(.shadows)
        saturation = try d(.saturation)
        vibrance = try d(.vibrance)
        warmth = try d(.warmth)
        tint = try d(.tint)
        fade = try d(.fade)
        grain = try d(.grain)
        grainSize = try d(.grainSize, 1)
        vignette = try d(.vignette)
        lightLeak = try d(.lightLeak)
        bloom = try d(.bloom)
        shadowsTint = try c.decodeIfPresent([Double].self, forKey: .shadowsTint) ?? [1, 1, 1]
        highlightsTint = try c.decodeIfPresent([Double].self, forKey: .highlightsTint) ?? [1, 1, 1]
        monochrome = try c.decodeIfPresent(Bool.self, forKey: .monochrome) ?? false
    }

    /// Applies the user's Refine overrides on top of the recipe.
    public func applying(_ refine: RefineOverrides) -> LookParameters {
        var p = self
        if let v = refine.grain { p.grain = (0.0...1.0).clamp(v) }
        if let v = refine.fade { p.fade = (0.0...1.0).clamp(v) }
        if let v = refine.vignette { p.vignette = (0.0...1.0).clamp(v) }
        if let v = refine.lightLeak { p.lightLeak = (0.0...1.0).clamp(v) }
        if let v = refine.tint { p.tint = (-1.0...1.0).clamp(v) }
        return p
    }
}

/// The Refine controls a user can change on an applied look. `nil` keeps the recipe value.
public struct RefineOverrides: Codable, Equatable, Sendable {
    public var grain: Double?
    public var fade: Double?
    public var vignette: Double?
    public var lightLeak: Double?
    public var tint: Double?

    public init(grain: Double? = nil, fade: Double? = nil, vignette: Double? = nil, lightLeak: Double? = nil, tint: Double? = nil) {
        self.grain = grain
        self.fade = fade
        self.vignette = vignette
        self.lightLeak = lightLeak
        self.tint = tint
    }

    public var isEmpty: Bool { self == RefineOverrides() }
}

/// A look recipe from the catalogue.
public struct LookRecipe: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var collection: String
    public var tier: Tier
    public var tags: [String]
    /// Optional `.cube` LUT resource name, applied before the parameters.
    public var lut: String?
    public var params: LookParameters
    /// Two colours (hex) used to draw a placeholder thumbnail before the real one renders.
    public var swatch: [String]

    public init(id: String, name: String, collection: String, tier: Tier, tags: [String] = [], lut: String? = nil, params: LookParameters, swatch: [String] = ["#888888", "#222222"]) {
        self.id = id
        self.name = name
        self.collection = collection
        self.tier = tier
        self.tags = tags
        self.lut = lut
        self.params = params
        self.swatch = swatch
    }
}

/// A curated group of looks, shown as chips in the Looks sheet and as cards in the Salon.
public struct LookCollection: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// A one-line editorial description for the Salon.
    public var tagline: String

    public init(id: String, name: String, tagline: String) {
        self.id = id
        self.name = name
        self.tagline = tagline
    }
}
