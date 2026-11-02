import Foundation

/// A font offered in the Text tool. Fonts must be licensed for app embedding;
/// Phase 1 ships families under the SIL Open Font License.
public struct OverlayFont: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    /// PostScript name of the bundled font file.
    public var postScriptName: String
    /// Used when the font file is missing: "serif" or "sans".
    public var fallbackDesign: String
    public var isItalic: Bool

    public init(id: String, displayName: String, postScriptName: String, fallbackDesign: String, isItalic: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.postScriptName = postScriptName
        self.fallbackDesign = fallbackDesign
        self.isItalic = isItalic
    }

    public static let all: [OverlayFont] = [
        OverlayFont(id: "playfair.italic", displayName: "Playfair", postScriptName: "PlayfairDisplay-Italic", fallbackDesign: "serif", isItalic: true),
        OverlayFont(id: "playfair", displayName: "Playfair Roman", postScriptName: "PlayfairDisplay-Medium", fallbackDesign: "serif"),
        OverlayFont(id: "cormorant.italic", displayName: "Cormorant", postScriptName: "CormorantGaramond-MediumItalic", fallbackDesign: "serif", isItalic: true),
        OverlayFont(id: "italiana", displayName: "Italiana", postScriptName: "Italiana-Regular", fallbackDesign: "serif"),
        OverlayFont(id: "bodoni", displayName: "Bodoni", postScriptName: "BodoniModa-Medium", fallbackDesign: "serif"),
        OverlayFont(id: "inter", displayName: "Inter", postScriptName: "Inter-Medium", fallbackDesign: "sans")
    ]

    public static func font(id: String) -> OverlayFont {
        all.first { $0.id == id } ?? all[0]
    }
}

/// A sticker in the Stickers tool. Artwork lives in the app's asset catalogue
/// as `sticker.<id>`; all stickers are drawn in-house.
public struct StickerDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var category: String
    public var tier: Tier

    public init(id: String, name: String, category: String, tier: Tier) {
        self.id = id
        self.name = name
        self.category = category
        self.tier = tier
    }

    public var assetName: String { "sticker.\(id)" }

    public static let categories = ["Ornaments", "Frames", "Celestial", "Notes", "Seasonal"]

    /// Phase 1 starter set. Artwork to be supplied by design.
    public static let starterSet: [StickerDefinition] = [
        .init(id: "sparkle", name: "Sparkle", category: "Ornaments", tier: .free),
        .init(id: "laurel", name: "Laurel", category: "Ornaments", tier: .free),
        .init(id: "bow", name: "Bow", category: "Ornaments", tier: .free),
        .init(id: "heart-line", name: "Heart", category: "Ornaments", tier: .free),
        .init(id: "pearls", name: "Pearl String", category: "Ornaments", tier: .member),
        .init(id: "monogram", name: "Monogram", category: "Ornaments", tier: .member),
        .init(id: "oval-frame", name: "Oval Frame", category: "Frames", tier: .free),
        .init(id: "gallery-frame", name: "Gallery Frame", category: "Frames", tier: .member),
        .init(id: "crescent", name: "Crescent", category: "Celestial", tier: .free),
        .init(id: "sunburst", name: "Sunburst", category: "Celestial", tier: .free),
        .init(id: "constellation", name: "Constellation", category: "Celestial", tier: .member),
        .init(id: "envelope", name: "Envelope", category: "Notes", tier: .free),
        .init(id: "wax-seal", name: "Wax Seal", category: "Notes", tier: .member),
        .init(id: "snowflake", name: "Snowflake", category: "Seasonal", tier: .free),
        .init(id: "holly", name: "Holly", category: "Seasonal", tier: .member)
    ]
}
