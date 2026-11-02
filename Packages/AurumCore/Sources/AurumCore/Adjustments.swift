import Foundation

/// The manual "Adjust" controls. Every value is normalised to -1...1, where 0
/// is neutral, unless noted. Renderers map these to real filter parameters,
/// so the same document renders the same way on iOS and Android.
public struct AdjustmentSet: Codable, Equatable, Sendable {
    public var exposure: Double = 0
    public var brightness: Double = 0
    public var contrast: Double = 0
    public var highlights: Double = 0
    public var shadows: Double = 0
    public var whites: Double = 0
    public var blacks: Double = 0
    public var saturation: Double = 0
    public var vibrance: Double = 0
    public var warmth: Double = 0
    public var tint: Double = 0
    /// 0...1
    public var sharpness: Double = 0
    public var clarity: Double = 0
    public var structure: Double = 0
    /// 0...1
    public var fade: Double = 0
    /// 0...1
    public var grain: Double = 0
    /// -1...1, negative lightens the corners
    public var vignette: Double = 0
    public var hsl: HSLAdjustments = HSLAdjustments()
    public var curves: ToneCurves = ToneCurves()
    public var splitToning: SplitToning = SplitToning()

    public init() {}

    /// The controls shown as single sliders in the Adjust sheet, in display order.
    public static let sliderControls: [AdjustmentControl] = AdjustmentControl.allCases

    public subscript(control: AdjustmentControl) -> Double {
        get {
            switch control {
            case .exposure: return exposure
            case .brightness: return brightness
            case .contrast: return contrast
            case .highlights: return highlights
            case .shadows: return shadows
            case .whites: return whites
            case .blacks: return blacks
            case .saturation: return saturation
            case .vibrance: return vibrance
            case .warmth: return warmth
            case .tint: return tint
            case .sharpness: return sharpness
            case .clarity: return clarity
            case .structure: return structure
            case .fade: return fade
            case .grain: return grain
            case .vignette: return vignette
            }
        }
        set {
            let v = control.range.clamp(newValue)
            switch control {
            case .exposure: exposure = v
            case .brightness: brightness = v
            case .contrast: contrast = v
            case .highlights: highlights = v
            case .shadows: shadows = v
            case .whites: whites = v
            case .blacks: blacks = v
            case .saturation: saturation = v
            case .vibrance: vibrance = v
            case .warmth: warmth = v
            case .tint: tint = v
            case .sharpness: sharpness = v
            case .clarity: clarity = v
            case .structure: structure = v
            case .fade: fade = v
            case .grain: grain = v
            case .vignette: vignette = v
            }
        }
    }

    /// True when no control differs from neutral, so the renderer can skip it.
    public var isNeutral: Bool { self == AdjustmentSet() }

    // Forward-compatible decoding: any key missing from older documents takes its default.
    enum CodingKeys: String, CodingKey {
        case exposure, brightness, contrast, highlights, shadows, whites, blacks
        case saturation, vibrance, warmth, tint, sharpness, clarity, structure
        case fade, grain, vignette, hsl, curves, splitToning
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d(_ key: CodingKeys) throws -> Double { try c.decodeIfPresent(Double.self, forKey: key) ?? 0 }
        exposure = try d(.exposure)
        brightness = try d(.brightness)
        contrast = try d(.contrast)
        highlights = try d(.highlights)
        shadows = try d(.shadows)
        whites = try d(.whites)
        blacks = try d(.blacks)
        saturation = try d(.saturation)
        vibrance = try d(.vibrance)
        warmth = try d(.warmth)
        tint = try d(.tint)
        sharpness = try d(.sharpness)
        clarity = try d(.clarity)
        structure = try d(.structure)
        fade = try d(.fade)
        grain = try d(.grain)
        vignette = try d(.vignette)
        hsl = try c.decodeIfPresent(HSLAdjustments.self, forKey: .hsl) ?? HSLAdjustments()
        curves = try c.decodeIfPresent(ToneCurves.self, forKey: .curves) ?? ToneCurves()
        splitToning = try c.decodeIfPresent(SplitToning.self, forKey: .splitToning) ?? SplitToning()
    }
}

/// One slider in the Adjust sheet.
public enum AdjustmentControl: String, CaseIterable, Codable, Sendable {
    case exposure, brightness, contrast, highlights, shadows, whites, blacks
    case saturation, vibrance, warmth, tint, sharpness, clarity, structure
    case fade, grain, vignette

    /// The allowed value range. Bipolar controls have a centre detent at 0.
    public var range: ClosedRange<Double> {
        switch self {
        case .sharpness, .fade, .grain: return 0...1
        default: return -1...1
        }
    }

    public var isBipolar: Bool { range.lowerBound < 0 }

    /// English display name. The app localises through its string catalogue
    /// using `"adjust.\(rawValue)"` as the key, with this as the fallback.
    public var displayName: String {
        switch self {
        case .exposure: return "Exposure"
        case .brightness: return "Brightness"
        case .contrast: return "Contrast"
        case .highlights: return "Highlights"
        case .shadows: return "Shadows"
        case .whites: return "Whites"
        case .blacks: return "Blacks"
        case .saturation: return "Saturation"
        case .vibrance: return "Vibrance"
        case .warmth: return "Warmth"
        case .tint: return "Tint"
        case .sharpness: return "Sharpness"
        case .clarity: return "Clarity"
        case .structure: return "Structure"
        case .fade: return "Fade"
        case .grain: return "Grain"
        case .vignette: return "Vignette"
        }
    }
}

/// Per-colour hue, saturation and luminance shifts, each -1...1.
public struct HSLAdjustments: Codable, Equatable, Sendable {
    public enum Band: String, CaseIterable, Codable, Sendable {
        case red, orange, yellow, green, aqua, blue, purple, magenta
    }

    public struct Shift: Codable, Equatable, Sendable {
        public var hue: Double = 0
        public var saturation: Double = 0
        public var luminance: Double = 0
        public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
            self.hue = hue
            self.saturation = saturation
            self.luminance = luminance
        }
    }

    /// Keyed by band raw value so the JSON is a plain object.
    public var shifts: [String: Shift] = [:]

    public init() {}

    public subscript(band: Band) -> Shift {
        get { shifts[band.rawValue] ?? Shift() }
        set { shifts[band.rawValue] = newValue == Shift() ? nil : newValue }
    }
}

/// A point on a tone curve, both coordinates 0...1.
public struct CurvePoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Tone curves for the composite and each channel. An empty array means identity.
public struct ToneCurves: Codable, Equatable, Sendable {
    public var master: [CurvePoint] = []
    public var red: [CurvePoint] = []
    public var green: [CurvePoint] = []
    public var blue: [CurvePoint] = []
    public init() {}

    public var isIdentity: Bool { master.isEmpty && red.isEmpty && green.isEmpty && blue.isEmpty }
}

/// Split toning: colour pushed into shadows and highlights.
public struct SplitToning: Codable, Equatable, Sendable {
    /// Hue in degrees 0..<360.
    public var shadowHue: Double = 0
    /// 0...1
    public var shadowSaturation: Double = 0
    public var highlightHue: Double = 0
    public var highlightSaturation: Double = 0
    /// -1 favours shadows, 1 favours highlights.
    public var balance: Double = 0
    public init() {}
}

extension ClosedRange where Bound == Double {
    /// Clamps a value into the range; NaN becomes the lower bound.
    public func clamp(_ value: Double) -> Double {
        guard !value.isNaN else { return lowerBound }
        return Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
