import Foundation

// The rules behind AURUM's Auto Studio. Every tool runs on the iPhone with
// Apple's Vision detection (faces, people, horizon, scene labels) and classic
// Core Image processing. Nothing is generated and nothing leaves the device.
// Everything here is plain data and rules, so it can be tested on any platform.

/// A tool in the Auto Studio.
public enum AutoFeature: String, Codable, CaseIterable, Sendable {
    /// Auto tone, white balance, straightening, red-eye fix, noise reduction
    /// and gentle sharpening.
    case enhance
    /// Keeps the person sharp and blurs what is behind them.
    case portraitBlur
    /// Keeps the person and puts a colour, gradient, blur or another photo behind them.
    case replaceBackground
    /// A soft directional light on faces.
    case relight
    /// The "Natural" skin retouch, placed by face detection.
    case retouch
    /// Fills what the user brushed over from its surroundings.
    case removeObject
    /// Curated portrait filters with a face-aware vignette and background blur.
    case portraitLooks

    /// Membership needed to keep the result. Retouch is a members' tool in
    /// the Studio too, so it is one here; Portrait Looks has free and
    /// members' looks of its own (`PortraitLook.tier`). Everything else is free.
    /// As everywhere in AURUM, everything can be previewed freely; membership
    /// is asked for only when the result is kept.
    public var tier: Tier {
        self == .retouch ? .member : .free
    }

    /// The user must brush over what to change.
    public var requiresMask: Bool { self == .removeObject }

    /// The tool needs a person in the photo.
    public var requiresPerson: Bool { self == .portraitBlur || self == .replaceBackground }

    /// The tool needs at least one face.
    public var requiresFace: Bool { self == .retouch }
}

/// What the user brushed or outlined on the photo, in normalised coordinates
/// (origin top-left) of the photo.
public struct BrushMask: Codable, Equatable, Sendable {
    /// A brush stroke. `radius` is a fraction of the photo's shorter side.
    public struct Stroke: Codable, Equatable, Sendable {
        public var points: [NormalizedPoint]
        public var radius: Double
        /// Erases earlier strokes instead of painting.
        public var isEraser: Bool

        public init(points: [NormalizedPoint], radius: Double = 0.03, isEraser: Bool = false) {
            self.points = points
            self.radius = (0.001...0.5).clamp(radius)
            self.isEraser = isEraser
        }
    }

    /// Closed outlines (lasso). Each needs at least three points.
    public var polygons: [[NormalizedPoint]]
    public var strokes: [Stroke]

    public init(polygons: [[NormalizedPoint]] = [], strokes: [Stroke] = []) {
        self.polygons = polygons
        self.strokes = strokes
    }

    /// True when nothing would be painted: no usable outline and no painting stroke.
    public var isEmpty: Bool {
        !polygons.contains { $0.count >= 3 } && !strokes.contains { !$0.isEraser && !$0.points.isEmpty }
    }

    /// Every point lies inside the unit square.
    public var isInBounds: Bool {
        func inside(_ p: NormalizedPoint) -> Bool { (0.0...1.0).contains(p.x) && (0.0...1.0).contains(p.y) }
        return polygons.allSatisfy { $0.allSatisfy(inside) } && strokes.allSatisfy { $0.points.allSatisfy(inside) }
    }

    /// The normalised box around everything painted (erasers ignored), with
    /// stroke radii measured on a photo of `aspect` (width / height).
    /// Nil when nothing is painted.
    public func paintedBounds(aspect: Double) -> NormalizedRect? {
        guard !isEmpty else { return nil }
        let a = aspect > 0 ? aspect : 1
        var minX = 1.0, minY = 1.0, maxX = 0.0, maxY = 0.0
        func include(_ x: Double, _ y: Double) {
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
        for polygon in polygons where polygon.count >= 3 {
            for p in polygon { include(p.x, p.y) }
        }
        for stroke in strokes where !stroke.isEraser {
            // radius is a fraction of the shorter side.
            let rx = a >= 1 ? stroke.radius / a : stroke.radius
            let ry = a >= 1 ? stroke.radius : stroke.radius * a
            for p in stroke.points {
                include(p.x - rx, p.y - ry)
                include(p.x + rx, p.y + ry)
            }
        }
        minX = max(0, minX)
        minY = max(0, minY)
        maxX = min(1, maxX)
        maxY = min(1, maxY)
        guard maxX > minX, maxY > minY else { return nil }
        return NormalizedRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The mask as a `width` × `height` grid of 0 or 1, row 0 at the top.
    /// Outlines are filled first, then strokes are painted (or erased) in
    /// order. `grow` widens every stroke by that many pixels.
    public func coverage(width: Int, height: Int, grow: Double = 0) -> [Float] {
        coverage(width: width, height: height, imageWidth: Double(width), imageHeight: Double(height), originX: 0, originY: 0, grow: grow)
    }

    /// Part of the mask as a grid: the whole photo is `imageWidth` ×
    /// `imageHeight` pixels, and the grid's top-left pixel sits at
    /// (`originX`, `originY`) in it. Used to rasterise only the region
    /// around the brushed area.
    public func coverage(width: Int, height: Int, imageWidth: Double, imageHeight: Double, originX: Double, originY: Double, grow: Double = 0) -> [Float] {
        guard width > 0, height > 0, imageWidth > 0, imageHeight > 0 else { return [] }
        var out = [Float](repeating: 0, count: width * height)
        let w = imageWidth
        let h = imageHeight
        for polygon in polygons where polygon.count >= 3 {
            let pts = polygon.map { (x: $0.x * w - originX, y: $0.y * h - originY) }
            for y in 0..<height {
                let cy = Double(y) + 0.5
                for x in 0..<width {
                    let cx = Double(x) + 0.5
                    if Self.contains(pts, x: cx, y: cy) { out[y * width + x] = 1 }
                }
            }
        }
        let shortSide = min(w, h)
        for stroke in strokes where !stroke.points.isEmpty {
            let r = stroke.radius * shortSide + grow
            let value: Float = stroke.isEraser ? 0 : 1
            let pts = stroke.points.map { (x: $0.x * w - originX, y: $0.y * h - originY) }
            if pts.count == 1 {
                Self.paintSegment(&out, width: width, height: height, a: pts[0], b: pts[0], radius: r, value: value)
            } else {
                for i in 0..<(pts.count - 1) {
                    Self.paintSegment(&out, width: width, height: height, a: pts[i], b: pts[i + 1], radius: r, value: value)
                }
            }
        }
        return out
    }

    static func paintSegment(_ out: inout [Float], width: Int, height: Int, a: (x: Double, y: Double), b: (x: Double, y: Double), radius r: Double, value: Float) {
        let minX = max(0, Int((min(a.x, b.x) - r).rounded(.down)))
        let maxX = min(width - 1, Int((max(a.x, b.x) + r).rounded(.up)))
        let minY = max(0, Int((min(a.y, b.y) - r).rounded(.down)))
        let maxY = min(height - 1, Int((max(a.y, b.y) + r).rounded(.up)))
        guard minX <= maxX, minY <= maxY else { return }
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        let rr = r * r
        for y in minY...maxY {
            let py = Double(y) + 0.5
            for x in minX...maxX {
                let px = Double(x) + 0.5
                var t = 0.0
                if lengthSquared > 0 {
                    t = ((px - a.x) * dx + (py - a.y) * dy) / lengthSquared
                    t = min(max(t, 0), 1)
                }
                let qx = a.x + t * dx - px
                let qy = a.y + t * dy - py
                if qx * qx + qy * qy <= rr { out[y * width + x] = value }
            }
        }
    }

    /// Even-odd point-in-polygon test.
    static func contains(_ polygon: [(x: Double, y: Double)], x: Double, y: Double) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let pi = polygon[i]
            let pj = polygon[j]
            if (pi.y > y) != (pj.y > y) {
                let t = (y - pi.y) / (pj.y - pi.y)
                let crossX = pi.x + t * (pj.x - pi.x)
                if x < crossX { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}

// MARK: - Straighten

/// Levelling a tilted photo: rotate, then scale up just enough that the
/// rotated photo still covers the whole frame (no empty corners).
public enum Straighten {
    /// Tilts smaller than this are left alone; larger ones are probably intentional.
    public static let minimumDegrees = 0.4
    public static let maximumDegrees = 15.0

    /// True when a detected tilt is worth correcting.
    public static func isWorthCorrecting(degrees: Double) -> Bool {
        let a = abs(degrees)
        return a >= minimumDegrees && a <= maximumDegrees
    }

    /// The scale that makes a `width` × `height` image, rotated by `radians`
    /// about its centre, cover the original frame.
    public static func coverScale(width: Double, height: Double, radians: Double) -> Double {
        guard width > 0, height > 0 else { return 1 }
        let c = abs(cos(radians))
        let s = abs(sin(radians))
        let a = c + s * height / width
        let b = c + s * width / height
        return max(1, max(a, b))
    }
}

// MARK: - Portrait Looks

/// A curated portrait filter: colour from `params` (same meaning as a
/// catalogue look), a soft vignette centred on the faces and an optional
/// background blur behind the person.
public struct PortraitLook: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var tier: Tier
    public var params: LookParameters
    /// 0...1, darkens away from the faces.
    public var faceVignette: Double
    /// 0...1, blurs what is behind the person.
    public var backgroundBlur: Double

    public init(id: String, name: String, tier: Tier, params: LookParameters, faceVignette: Double = 0, backgroundBlur: Double = 0) {
        self.id = id
        self.name = name
        self.tier = tier
        self.params = params
        self.faceVignette = (0.0...1.0).clamp(faceVignette)
        self.backgroundBlur = (0.0...1.0).clamp(backgroundBlur)
    }

    public static let library: [PortraitLook] = [
        PortraitLook(id: "portrait.soft-studio", name: "Soft Studio", tier: .free, params: PortraitLook.makeParams { p in
            p.exposure = 0.05
            p.contrast = -0.08
            p.highlights = -0.2
            p.shadows = 0.15
            p.warmth = 0.06
            p.vibrance = 0.08
        }, faceVignette: 0.25, backgroundBlur: 0.25),
        PortraitLook(id: "portrait.window-light", name: "Window Light", tier: .free, params: PortraitLook.makeParams { p in
            p.exposure = 0.08
            p.contrast = 0.1
            p.shadows = 0.1
            p.warmth = -0.04
            p.saturation = -0.08
            p.fade = 0.08
        }, faceVignette: 0.45, backgroundBlur: 0),
        PortraitLook(id: "portrait.editorial", name: "Editorial", tier: .member, params: PortraitLook.makeParams { p in
            p.contrast = 0.22
            p.highlights = -0.25
            p.shadows = -0.05
            p.saturation = -0.15
            p.warmth = 0.04
            p.shadowsTint = [0.97, 1.0, 1.04]
        }, faceVignette: 0.5, backgroundBlur: 0.35),
        PortraitLook(id: "portrait.silver", name: "Silver", tier: .member, params: PortraitLook.makeParams { p in
            p.contrast = 0.25
            p.highlights = -0.15
            p.shadows = 0.1
            p.monochrome = true
            p.grain = 0.15
        }, faceVignette: 0.55, backgroundBlur: 0.2),
        PortraitLook(id: "portrait.golden", name: "Golden", tier: .member, params: PortraitLook.makeParams { p in
            p.exposure = 0.05
            p.warmth = 0.25
            p.vibrance = 0.12
            p.bloom = 0.2
            p.highlightsTint = [1.04, 1.0, 0.94]
        }, faceVignette: 0.35, backgroundBlur: 0.45),
        PortraitLook(id: "portrait.matte-film", name: "Matte Film", tier: .member, params: PortraitLook.makeParams { p in
            p.contrast = -0.05
            p.saturation = -0.1
            p.fade = 0.3
            p.grain = 0.25
            p.warmth = 0.08
        }, faceVignette: 0.3, backgroundBlur: 0.15)
    ]

    /// Builds look parameters from neutral, one setting per line.
    static func makeParams(_ build: (inout LookParameters) -> Void) -> LookParameters {
        var p = LookParameters()
        build(&p)
        return p
    }

    public static func look(id: String) -> PortraitLook? {
        library.first { $0.id == id }
    }
}

// MARK: - Auto-detect

/// One label from Vision's scene classification.
public struct SceneLabel: Codable, Equatable, Sendable {
    public var identifier: String
    /// 0...1
    public var confidence: Double

    public init(identifier: String, confidence: Double) {
        self.identifier = identifier
        self.confidence = confidence
    }
}

/// What the on-device analysis found in a photo. Filled by the render layer
/// from Vision; kept here so the ranking can be tested without Vision.
public struct SceneAnalysis: Equatable, Sendable {
    public var faces: [FaceGeometry]
    /// Average luminance (0...1) inside the face boxes, nil without faces.
    public var faceLuminance: Double?
    /// Average luminance of the whole photo, 0...1.
    public var luminance: Double
    /// Average red minus blue, about -1...1; positive is warm.
    public var warmth: Double
    /// Share of the frame covered by people, 0...1.
    public var personCoverage: Double
    /// The horizon's tilt in degrees, counter-clockwise positive, nil when none was found.
    public var horizonDegrees: Double?
    /// Core Image's red-eye analysis found eyes to correct.
    public var redEyeLikely: Bool
    /// Top scene labels, most confident first.
    public var labels: [SceneLabel]

    public init(faces: [FaceGeometry] = [], faceLuminance: Double? = nil, luminance: Double = 0.5, warmth: Double = 0, personCoverage: Double = 0, horizonDegrees: Double? = nil, redEyeLikely: Bool = false, labels: [SceneLabel] = []) {
        self.faces = faces
        self.faceLuminance = faceLuminance
        self.luminance = luminance
        self.warmth = warmth
        self.personCoverage = personCoverage
        self.horizonDegrees = horizonDegrees
        self.redEyeLikely = redEyeLikely
        self.labels = labels
    }

    /// True when any label (case-insensitive) is in `identifiers` with at least `minimumConfidence`.
    public func hasLabel(in identifiers: Set<String>, minimumConfidence: Double = 0.2) -> Bool {
        labels.contains { $0.confidence >= minimumConfidence && identifiers.contains($0.identifier.lowercased()) }
    }

    /// The largest face's share of the frame, 0 without faces.
    public var largestFaceArea: Double {
        faces.map { $0.bounds.width * $0.bounds.height }.max() ?? 0
    }
}

/// A one-tap fix offered after a photo is analysed.
public struct AutoSuggestion: Equatable, Identifiable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case fixRedEye, straighten, brightenFaces, blurBackground, balanceColour, smoothSkin, enhance
    }

    public var kind: Kind
    /// Higher is more useful for this photo, 0...1.
    public var score: Double
    /// For `straighten`: the tilt to remove, in degrees.
    public var degrees: Double?

    public var id: String { kind.rawValue }

    public init(kind: Kind, score: Double, degrees: Double? = nil) {
        self.kind = kind
        self.score = score
        self.degrees = degrees
    }

    /// The tool that carries the fix out.
    public var feature: AutoFeature {
        switch kind {
        case .fixRedEye, .straighten, .balanceColour, .enhance: return .enhance
        case .brightenFaces: return .relight
        case .blurBackground: return .portraitBlur
        case .smoothSkin: return .retouch
        }
    }
}

public enum AutoSuggestions {
    /// Scene labels that suggest a horizon worth levelling. Vision's
    /// taxonomy identifiers; unknown ones simply never match.
    public static let horizonLabels: Set<String> = [
        "sky", "sea", "ocean", "beach", "lake", "water", "water_body", "shore", "mountain",
        "landscape", "outdoor", "field", "sunset_sunrise", "horizon", "desert", "snow", "grass"
    ]
    /// Labels that suggest a portrait.
    public static let portraitLabels: Set<String> = [
        "people", "person", "portrait", "adult", "child", "baby", "selfie", "people_group", "wedding"
    ]

    /// Fixes worth offering for this photo, most useful first, at most `limit`.
    /// "Enhance" is always a candidate, so the list is never empty.
    public static func rank(_ analysis: SceneAnalysis, limit: Int = 4) -> [AutoSuggestion] {
        var out: [AutoSuggestion] = []

        if analysis.redEyeLikely, !analysis.faces.isEmpty {
            out.append(AutoSuggestion(kind: .fixRedEye, score: 0.95))
        }

        if let tilt = analysis.horizonDegrees, Straighten.isWorthCorrecting(degrees: tilt) {
            var score = 0.6 + min(abs(tilt), 5) / 5 * 0.25
            if analysis.hasLabel(in: horizonLabels) { score += 0.1 }
            out.append(AutoSuggestion(kind: .straighten, score: min(score, 0.94), degrees: tilt))
        }

        if let faceLum = analysis.faceLuminance, !analysis.faces.isEmpty, faceLum < 0.42 {
            let score = 0.55 + (0.42 - faceLum) * 1.2
            out.append(AutoSuggestion(kind: .brightenFaces, score: min(score, 0.9)))
        }

        let coverage = analysis.personCoverage
        if coverage >= 0.06, coverage <= 0.75 {
            var score = 0.5
            if analysis.hasLabel(in: portraitLabels) || !analysis.faces.isEmpty { score += 0.15 }
            // Mid-sized subjects benefit most; a person filling the frame leaves little to blur.
            if coverage >= 0.12, coverage <= 0.55 { score += 0.1 }
            out.append(AutoSuggestion(kind: .blurBackground, score: score))
        }

        let cast = abs(analysis.warmth)
        if cast > 0.12 {
            let score = 0.4 + min(cast - 0.12, 0.3)
            out.append(AutoSuggestion(kind: .balanceColour, score: score))
        }

        if analysis.largestFaceArea >= 0.03 {
            out.append(AutoSuggestion(kind: .smoothSkin, score: 0.45))
        }

        let lum = analysis.luminance
        let needsTone = lum < 0.32 || lum > 0.78
        out.append(AutoSuggestion(kind: .enhance, score: needsTone ? 0.7 : 0.3))

        let order = AutoSuggestion.Kind.allCases
        out.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let ia = order.firstIndex(of: a.kind) ?? 0
            let ib = order.firstIndex(of: b.kind) ?? 0
            return ia < ib
        }
        return Array(out.prefix(max(1, limit)))
    }
}
