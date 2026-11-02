import Foundation

/// How an overlay mixes with the photo beneath it.
public enum BlendMode: String, Codable, CaseIterable, Sendable {
    case normal, screen, multiply, overlay, softLight, lighten, darken
}

/// Decorative treatment for a text overlay.
public enum TextStyle: String, Codable, CaseIterable, Sendable {
    case plain, outline, shadow, glow, gradient, box
}

public enum TextAlignment: String, Codable, Sendable {
    case leading, center, trailing
}

public struct TextOverlay: Codable, Equatable, Sendable {
    public var text: String
    /// A font ID from the app's font registry, for example "playfair.italic".
    public var fontID: String
    /// Point size at a 1080 px wide render; scaled proportionally at other sizes.
    public var size: Double
    public var colorHex: String
    public var style: TextStyle
    public var alignment: TextAlignment

    public init(text: String, fontID: String = "playfair.italic", size: Double = 64, colorHex: String = "#F4EFE6", style: TextStyle = .shadow, alignment: TextAlignment = .center) {
        self.text = text
        self.fontID = fontID
        self.size = size
        self.colorHex = colorHex
        self.style = style
        self.alignment = alignment
    }
}

public struct StickerOverlay: Codable, Equatable, Sendable {
    public var stickerID: String
    public var tier: Tier
    /// Optional recolour; nil keeps the sticker's own colours.
    public var tintHex: String?

    public init(stickerID: String, tier: Tier = .free, tintHex: String? = nil) {
        self.stickerID = stickerID
        self.tier = tier
        self.tintHex = tintHex
    }
}

/// Text or a sticker placed on the photo. Position is normalised to the crop
/// rectangle so it survives re-cropping and renders identically at any size.
public struct Overlay: Codable, Equatable, Identifiable, Sendable {
    public enum Content: Equatable, Sendable {
        case text(TextOverlay)
        case sticker(StickerOverlay)
    }

    public var id: UUID
    public var content: Content
    public var center: NormalizedPoint
    /// 1 is the default size; pinch changes it.
    public var scale: Double
    public var rotationDegrees: Double
    /// 0...1
    public var opacity: Double
    public var blendMode: BlendMode
    public var isHidden: Bool

    public init(id: UUID = UUID(), content: Content, center: NormalizedPoint = .center, scale: Double = 1, rotationDegrees: Double = 0, opacity: Double = 1, blendMode: BlendMode = .normal, isHidden: Bool = false) {
        self.id = id
        self.content = content
        self.center = center
        self.scale = scale
        self.rotationDegrees = rotationDegrees
        self.opacity = opacity
        self.blendMode = blendMode
        self.isHidden = isHidden
    }
}

extension Overlay.Content: Codable {
    enum CodingKeys: String, CodingKey { case type, text, sticker }
    enum Kind: String, Codable { case text, sticker }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .text: self = .text(try c.decode(TextOverlay.self, forKey: .text))
        case .sticker: self = .sticker(try c.decode(StickerOverlay.self, forKey: .sticker))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let t):
            try c.encode(Kind.text, forKey: .type)
            try c.encode(t, forKey: .text)
        case .sticker(let s):
            try c.encode(Kind.sticker, forKey: .type)
            try c.encode(s, forKey: .sticker)
        }
    }
}
