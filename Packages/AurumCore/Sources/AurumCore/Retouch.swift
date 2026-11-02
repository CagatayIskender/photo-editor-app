import Foundation

/// Face-aware retouching. Values are strengths in 0...1, except the reshape
/// controls, which are -1...1 (shrink to enlarge). Defaults are neutral, and
/// the suggested values (`natural`) are deliberately subtle.
public struct RetouchSettings: Codable, Equatable, Sendable {
    /// Applied to every detected face unless a face has its own entry.
    public var global: FaceRetouch
    /// Per-face overrides for group photos, keyed by face index in reading
    /// order (left to right, top to bottom) as found by the face detector.
    public var perFace: [Int: FaceRetouch]

    public init(global: FaceRetouch = FaceRetouch(), perFace: [Int: FaceRetouch] = [:]) {
        self.global = global
        self.perFace = perFace
    }

    public func settings(forFace index: Int) -> FaceRetouch {
        perFace[index] ?? global
    }

    public var isNeutral: Bool {
        global.isNeutral && perFace.values.allSatisfy(\.isNeutral)
    }
}

public struct FaceRetouch: Codable, Equatable, Sendable {
    // Skin
    public var smoothing: Double = 0
    public var blemishRemoval: Double = 0
    public var underEye: Double = 0
    // Features
    public var teethWhitening: Double = 0
    public var eyeBrightening: Double = 0
    // Reshape, -1...1
    public var jaw: Double = 0
    public var cheeks: Double = 0
    public var nose: Double = 0
    public var eyes: Double = 0
    public var lips: Double = 0
    public var forehead: Double = 0

    public init() {}

    /// The one-tap "natural" retouch: light smoothing and brightening, no reshaping.
    public static let natural: FaceRetouch = {
        var r = FaceRetouch()
        r.smoothing = 0.35
        r.blemishRemoval = 0.5
        r.underEye = 0.3
        r.teethWhitening = 0.2
        r.eyeBrightening = 0.2
        return r
    }()

    public var isNeutral: Bool { self == FaceRetouch() }

    /// Every control multiplied by `amount` (0...1), for a strength slider
    /// over a preset such as `natural`.
    public func scaled(by amount: Double) -> FaceRetouch {
        let k = (0.0...1.0).clamp(amount)
        var r = self
        for control in RetouchControl.allCases {
            r[control] = self[control] * k
        }
        return r
    }

    public subscript(control: RetouchControl) -> Double {
        get {
            switch control {
            case .smoothing: return smoothing
            case .blemishRemoval: return blemishRemoval
            case .underEye: return underEye
            case .teethWhitening: return teethWhitening
            case .eyeBrightening: return eyeBrightening
            case .jaw: return jaw
            case .cheeks: return cheeks
            case .nose: return nose
            case .eyes: return eyes
            case .lips: return lips
            case .forehead: return forehead
            }
        }
        set {
            let v = control.range.clamp(newValue)
            switch control {
            case .smoothing: smoothing = v
            case .blemishRemoval: blemishRemoval = v
            case .underEye: underEye = v
            case .teethWhitening: teethWhitening = v
            case .eyeBrightening: eyeBrightening = v
            case .jaw: jaw = v
            case .cheeks: cheeks = v
            case .nose: nose = v
            case .eyes: eyes = v
            case .lips: lips = v
            case .forehead: forehead = v
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case smoothing, blemishRemoval, underEye, teethWhitening, eyeBrightening
        case jaw, cheeks, nose, eyes, lips, forehead
    }

    /// Missing keys decode as neutral, so new controls never break old drafts.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v(_ k: CodingKeys) throws -> Double { try c.decodeIfPresent(Double.self, forKey: k) ?? 0 }
        smoothing = try v(.smoothing)
        blemishRemoval = try v(.blemishRemoval)
        underEye = try v(.underEye)
        teethWhitening = try v(.teethWhitening)
        eyeBrightening = try v(.eyeBrightening)
        jaw = try v(.jaw)
        cheeks = try v(.cheeks)
        nose = try v(.nose)
        eyes = try v(.eyes)
        lips = try v(.lips)
        forehead = try v(.forehead)
    }
}

public enum RetouchControl: String, CaseIterable, Codable, Sendable {
    case smoothing, blemishRemoval, underEye, teethWhitening, eyeBrightening
    case jaw, cheeks, nose, eyes, lips, forehead

    public var isReshape: Bool {
        switch self {
        case .jaw, .cheeks, .nose, .eyes, .lips, .forehead: return true
        default: return false
        }
    }

    public var range: ClosedRange<Double> { isReshape ? -1.0...1.0 : 0.0...1.0 }

    public var displayName: String {
        switch self {
        case .smoothing: return "Smooth skin"
        case .blemishRemoval: return "Blemishes"
        case .underEye: return "Under-eye"
        case .teethWhitening: return "Teeth"
        case .eyeBrightening: return "Bright eyes"
        case .jaw: return "Jaw"
        case .cheeks: return "Cheeks"
        case .nose: return "Nose"
        case .eyes: return "Eyes"
        case .lips: return "Lips"
        case .forehead: return "Forehead"
        }
    }
}

/// A detected face in normalised image coordinates (origin top-left), as
/// produced by the on-device face detector. Kept in Core so render code and
/// tests can work with faces without importing Vision.
public struct FaceGeometry: Codable, Equatable, Sendable {
    public enum Region: String, Codable, CaseIterable, Sendable {
        case faceContour, leftEye, rightEye, leftEyebrow, rightEyebrow, nose, outerLips, innerLips
    }

    public var bounds: NormalizedRect
    public var regions: [Region: [NormalizedPoint]]

    public init(bounds: NormalizedRect, regions: [Region: [NormalizedPoint]] = [:]) {
        self.bounds = bounds
        self.regions = regions
    }

    /// The centre of a region's points, or nil if the detector didn't find it.
    public func center(of region: Region) -> NormalizedPoint? {
        guard let pts = regions[region], !pts.isEmpty else { return nil }
        let x = pts.map(\.x).reduce(0, +) / Double(pts.count)
        let y = pts.map(\.y).reduce(0, +) / Double(pts.count)
        return NormalizedPoint(x: x, y: y)
    }

    /// Sorts faces left to right, then top to bottom, so per-face settings
    /// keep pointing at the same person between detections.
    public static func readingOrder(_ faces: [FaceGeometry]) -> [FaceGeometry] {
        faces.sorted { a, b in
            let rowA = (a.bounds.y / max(a.bounds.height, 0.01)).rounded()
            let rowB = (b.bounds.y / max(b.bounds.height, 0.01)).rounded()
            return rowA == rowB ? a.bounds.x < b.bounds.x : rowA < rowB
        }
    }
}
