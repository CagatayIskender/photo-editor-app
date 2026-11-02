import Foundation

/// The photo an edit applies to. AURUM never copies the original; it keeps
/// the Photos library identifier and the pixel size at import time.
public struct SourceAsset: Codable, Equatable, Sendable {
    public var localIdentifier: String
    public var pixelSize: PixelSize

    public init(localIdentifier: String, pixelSize: PixelSize) {
        self.localIdentifier = localIdentifier
        self.pixelSize = pixelSize
    }
}

/// An applied look: which recipe, how strongly, and any Refine changes.
public struct LookApplication: Codable, Equatable, Sendable {
    public var lookID: String
    /// 0...1 blend between the input and the full recipe.
    public var intensity: Double
    public var refine: RefineOverrides

    public init(lookID: String, intensity: Double = 0.8, refine: RefineOverrides = RefineOverrides()) {
        self.lookID = lookID
        self.intensity = (0.0...1.0).clamp(intensity)
        self.refine = refine
    }
}

/// One step in the edit stack.
public struct EditOperation: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case look(LookApplication)
        case adjust(AdjustmentSet)
    }

    public var id: UUID
    public var isEnabled: Bool
    public var kind: Kind

    public init(id: UUID = UUID(), isEnabled: Bool = true, kind: Kind) {
        self.id = id
        self.isEnabled = isEnabled
        self.kind = kind
    }
}

extension EditOperation.Kind: Codable {
    enum CodingKeys: String, CodingKey { case type, look, adjust }
    enum Tag: String, Codable { case look, adjust }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Tag.self, forKey: .type) {
        case .look: self = .look(try c.decode(LookApplication.self, forKey: .look))
        case .adjust: self = .adjust(try c.decode(AdjustmentSet.self, forKey: .adjust))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .look(let l):
            try c.encode(Tag.look, forKey: .type)
            try c.encode(l, forKey: .look)
        case .adjust(let a):
            try c.encode(Tag.adjust, forKey: .type)
            try c.encode(a, forKey: .adjust)
        }
    }
}

/// Aspect ratio presets offered in the Crop sheet.
public enum AspectPreset: String, Codable, CaseIterable, Sendable {
    case free, original, story, portrait, square, landscape

    /// Width over height, or nil for free and original (resolved against the source).
    public var ratio: Double? {
        switch self {
        case .free, .original: return nil
        case .story: return 9.0 / 16.0
        case .portrait: return 4.0 / 5.0
        case .square: return 1
        case .landscape: return 16.0 / 9.0
        }
    }

    public var label: String {
        switch self {
        case .free: return "Free"
        case .original: return "Original"
        case .story: return "9:16"
        case .portrait: return "4:5"
        case .square: return "1:1"
        case .landscape: return "16:9"
        }
    }
}

/// Crop, rotation and flips. Applied after every look and adjustment.
public struct CropSpec: Codable, Equatable, Sendable {
    public var rect: NormalizedRect
    public var aspect: AspectPreset
    /// Number of 90° clockwise turns, 0...3.
    public var quarterTurns: Int
    /// Fine rotation, -45...45 degrees.
    public var straightenDegrees: Double
    public var flipHorizontal: Bool
    public var flipVertical: Bool

    public init(rect: NormalizedRect = .full, aspect: AspectPreset = .original, quarterTurns: Int = 0, straightenDegrees: Double = 0, flipHorizontal: Bool = false, flipVertical: Bool = false) {
        self.rect = rect
        self.aspect = aspect
        self.quarterTurns = ((quarterTurns % 4) + 4) % 4
        self.straightenDegrees = (-45.0...45.0).clamp(straightenDegrees)
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
    }

    public static let identity = CropSpec()
    public var isIdentity: Bool { self == .identity }

    /// The largest centred crop of the given aspect ratio that fits a source.
    public static func centred(aspect: AspectPreset, source: PixelSize) -> CropSpec {
        guard let target = aspect.ratio else { return CropSpec(aspect: aspect) }
        let sourceRatio = source.aspectRatio
        var rect = NormalizedRect.full
        if target < sourceRatio {
            rect.width = target / sourceRatio
            rect.x = (1 - rect.width) / 2
        } else {
            rect.height = sourceRatio / target
            rect.y = (1 - rect.height) / 2
        }
        return CropSpec(rect: rect, aspect: aspect)
    }

    /// Output size in pixels for a given source size.
    public func outputSize(for source: PixelSize) -> PixelSize {
        let w = Int((Double(source.width) * rect.width).rounded())
        let h = Int((Double(source.height) * rect.height).rounded())
        return quarterTurns % 2 == 0 ? PixelSize(width: w, height: h) : PixelSize(width: h, height: w)
    }
}

/// A complete, serialisable edit. This is the single source of truth for the
/// Studio, drafts, presets and export.
public struct EditDocument: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var source: SourceAsset
    /// Applied in order, first to last.
    public var operations: [EditOperation]
    public var crop: CropSpec
    /// Drawn above the photo, first to last.
    public var overlays: [Overlay]
    public var createdAt: Date
    public var modifiedAt: Date

    public init(id: UUID = UUID(), source: SourceAsset, operations: [EditOperation] = [], crop: CropSpec = .identity, overlays: [Overlay] = [], createdAt: Date = Date(), modifiedAt: Date? = nil) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.source = source
        self.operations = operations
        self.crop = crop
        self.overlays = overlays
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
    }

    // MARK: Looks

    /// Looks in stack order.
    public var lookApplications: [LookApplication] {
        operations.compactMap { op -> LookApplication? in
            if case .look(let l) = op.kind { return l }
            return nil
        }
    }

    /// The look the Looks sheet edits: the topmost look operation.
    public var activeLookIndex: Int? {
        operations.lastIndex { if case .look = $0.kind { return true } else { return false } }
    }

    /// Replaces the topmost look, or adds one below the adjustments if there is none.
    /// This is what tapping a thumbnail does; stacking uses `stackLook`.
    public mutating func applyLook(_ lookID: String, intensity: Double = 0.8) {
        let application = LookApplication(lookID: lookID, intensity: intensity)
        if let i = activeLookIndex {
            operations[i].kind = .look(application)
            operations[i].isEnabled = true
        } else {
            operations.insert(EditOperation(kind: .look(application)), at: adjustIndex ?? operations.endIndex)
        }
    }

    /// Adds another look on top of the existing ones (below the adjustments).
    public mutating func stackLook(_ lookID: String, intensity: Double = 0.8) {
        let op = EditOperation(kind: .look(LookApplication(lookID: lookID, intensity: intensity)))
        operations.insert(op, at: adjustIndex ?? operations.endIndex)
    }

    public mutating func setActiveLookIntensity(_ value: Double) {
        guard let i = activeLookIndex, case .look(var l) = operations[i].kind else { return }
        l.intensity = (0.0...1.0).clamp(value)
        operations[i].kind = .look(l)
    }

    public mutating func setActiveLookRefine(_ refine: RefineOverrides) {
        guard let i = activeLookIndex, case .look(var l) = operations[i].kind else { return }
        l.refine = refine
        operations[i].kind = .look(l)
    }

    public mutating func removeOperation(id: UUID) {
        operations.removeAll { $0.id == id }
    }

    public mutating func toggleOperation(id: UUID) {
        guard let i = operations.firstIndex(where: { $0.id == id }) else { return }
        operations[i].isEnabled.toggle()
    }

    public mutating func moveOperation(from source: Int, to destination: Int) {
        guard operations.indices.contains(source) else { return }
        let op = operations.remove(at: source)
        operations.insert(op, at: min(max(destination, 0), operations.count))
    }

    // MARK: Adjustments

    var adjustIndex: Int? {
        operations.firstIndex { if case .adjust = $0.kind { return true } else { return false } }
    }

    /// The single adjustments operation; neutral if none exists yet.
    public var adjustments: AdjustmentSet {
        get {
            guard let i = adjustIndex, case .adjust(let a) = operations[i].kind else { return AdjustmentSet() }
            return a
        }
        set {
            if let i = adjustIndex {
                operations[i].kind = .adjust(newValue)
            } else if !newValue.isNeutral {
                operations.append(EditOperation(kind: .adjust(newValue)))
            }
        }
    }

    // MARK: Overlays

    public mutating func addOverlay(_ overlay: Overlay) {
        overlays.append(overlay)
    }

    public mutating func updateOverlay(_ overlay: Overlay) {
        guard let i = overlays.firstIndex(where: { $0.id == overlay.id }) else { return }
        overlays[i] = overlay
    }

    public mutating func removeOverlay(id: UUID) {
        overlays.removeAll { $0.id == id }
    }

    /// True when nothing has been changed from the original photo.
    public var isPristine: Bool {
        operations.allSatisfy { op in
            guard op.isEnabled else { return true }
            switch op.kind {
            case .look(let l): return l.intensity == 0
            case .adjust(let a): return a.isNeutral
            }
        } && crop.isIdentity && overlays.isEmpty
    }

    // MARK: Serialisation

    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public func encoded() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    /// Decodes a document from any supported schema version, migrating it to the current one.
    public static func decode(from data: Data) throws -> EditDocument {
        try DocumentMigrator.decode(data)
    }
}
