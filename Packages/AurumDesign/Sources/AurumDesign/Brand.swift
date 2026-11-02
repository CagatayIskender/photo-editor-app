import Foundation

/// Everything that names or prices the brand. Values come from `brand.json`
/// in the app bundle; the defaults here match it so previews work without a bundle.
///
/// To rename the app, edit `Brand/brand.json` (and the display name in project.yml).
public struct Brand: Codable, Equatable, Sendable {
    public struct Products: Codable, Equatable, Sendable {
        public var weekly: String
        public var yearly: String
        public var credits20: String
        public var credits100: String
    }

    public struct Colors: Codable, Equatable, Sendable {
        public var onyx: String
        public var graphite: String
        public var graphiteRaised: String
        public var hairline: String
        public var ivory: String
        public var ivoryDim: String
        public var stone: String
        public var champagne: String
        public var ivoryThemeBackground: String
        public var ivoryThemeText: String
        public var ivoryThemeAccent: String
    }

    public struct Fonts: Codable, Equatable, Sendable {
        public var display: String
        public var displayItalic: String
        public var text: String
        public var textMedium: String
        public var textSemibold: String
    }

    public var appName: String
    public var membershipName: String
    public var watermarkText: String
    public var urlScheme: String
    public var products: Products
    public var colors: Colors
    public var fonts: Fonts
    public var freeExportMaxPixelSize: Int

    public static let `default` = Brand(
        appName: "AURUM",
        membershipName: "AURUM Membership",
        watermarkText: "AURUM",
        urlScheme: "aurum",
        products: Products(weekly: "aurum.membership.weekly", yearly: "aurum.membership.yearly", credits20: "aurum.credits.20", credits100: "aurum.credits.100"),
        colors: Colors(onyx: "#0B0B0C", graphite: "#161618", graphiteRaised: "#222226", hairline: "#2E2E33", ivory: "#F4EFE6", ivoryDim: "#B9B2A6", stone: "#8E887E", champagne: "#C9A86A", ivoryThemeBackground: "#F4EFE6", ivoryThemeText: "#1A1918", ivoryThemeAccent: "#7A5C22"),
        fonts: Fonts(display: "PlayfairDisplay-Medium", displayItalic: "PlayfairDisplay-Italic", text: "Inter-Regular", textMedium: "Inter-Medium", textSemibold: "Inter-SemiBold"),
        freeExportMaxPixelSize: 2048
    )

    /// The active brand. Set once at launch from `Brand.load(from:)`.
    public nonisolated(unsafe) static var current: Brand = .default

    /// Loads `brand.json` from a bundle, falling back to the defaults.
    public static func load(from bundle: Bundle) -> Brand {
        guard let url = bundle.url(forResource: "brand", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let brand = try? JSONDecoder().decode(Brand.self, from: data) else {
            return .default
        }
        return brand
    }
}
