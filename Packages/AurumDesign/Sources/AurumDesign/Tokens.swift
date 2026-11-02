import SwiftUI
import UIKit

// MARK: - Colour

extension Color {
    /// Creates a colour from "#RRGGBB" or "#RRGGBBAA". Invalid input gives magenta,
    /// which is loud on purpose so a typo in brand.json is noticed.
    public init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        guard (s.count == 6 || s.count == 8), Scanner(string: s).scanHexInt64(&value) else {
            self = Color(.sRGB, red: 1, green: 0, blue: 1, opacity: 1)
            return
        }
        let hasAlpha = s.count == 8
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

/// Semantic colours. Text colours meet 4.5:1 on `background` and `surface`.
public enum AurumColor {
    private static var c: Brand.Colors { Brand.current.colors }

    /// Deep onyx, the app background.
    public static var background: Color { Color(hex: c.onyx) }
    /// Graphite, for sheets and the tab bar.
    public static var surface: Color { Color(hex: c.graphite) }
    /// Raised graphite, for cards and selected segments.
    public static var surfaceRaised: Color { Color(hex: c.graphiteRaised) }
    /// Neutral 1 pt borders.
    public static var hairline: Color { Color(hex: c.hairline) }
    /// Warm ivory primary text, 17.2:1 on onyx.
    public static var textPrimary: Color { Color(hex: c.ivory) }
    /// 9.4:1 on onyx.
    public static var textSecondary: Color { Color(hex: c.ivoryDim) }
    /// 5.6:1 on onyx. The lowest-contrast text allowed.
    public static var textTertiary: Color { Color(hex: c.stone) }
    /// Champagne gold. Only for the primary action and premium states.
    public static var accent: Color { Color(hex: c.champagne) }
    /// Gold hairline used on sheet tops and the membership card.
    public static var goldHairline: Color { accent.opacity(0.35) }
    /// Text and icons placed on the gold accent.
    public static var onAccent: Color { Color(hex: c.onyx) }
}

// MARK: - Spacing, radius, size

public enum Spacing {
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let s: CGFloat = 12
    public static let m: CGFloat = 16
    public static let l: CGFloat = 24
    public static let xl: CGFloat = 32
    public static let xxl: CGFloat = 48
    public static let xxxl: CGFloat = 64
}

public enum Radius {
    public static let chip: CGFloat = 8
    public static let thumbnail: CGFloat = 14
    public static let card: CGFloat = 20
    public static let sheet: CGFloat = 28
}

public enum Size {
    /// Minimum touch target.
    public static let touch: CGFloat = 44
    public static let primaryButtonHeight: CGFloat = 54
    public static let toolRailHeight: CGFloat = 84
    public static let iconStroke: CGFloat = 1.25
}

// MARK: - Motion

public enum Motion {
    /// "Atelier spring": slow and weighted. Sheets, cards, thumbnails.
    public static let atelier = Animation.spring(response: 0.55, dampingFraction: 0.86)
    /// "Velvet fade": compare and look swaps.
    public static let velvet = Animation.easeOut(duration: 0.35)
    /// Shimmer sweep duration for premium items.
    public static let shimmerDuration: Double = 2.4

    /// Returns `animation`, or nil when the user has asked for reduced motion.
    public static func respectingReduceMotion(_ animation: Animation) -> Animation? {
        UIAccessibility.isReduceMotionEnabled ? nil : animation
    }
}

// MARK: - Typography

/// Type styles. Every style scales with Dynamic Type.
public enum AurumTextStyle: CaseIterable {
    case display, title, editorial, headline, body, caption, label

    var size: CGFloat {
        switch self {
        case .display: return 36
        case .title: return 26
        case .editorial: return 20
        case .headline: return 17
        case .body: return 15
        case .caption: return 13
        case .label: return 11
        }
    }

    var relativeTo: Font.TextStyle {
        switch self {
        case .display: return .largeTitle
        case .title: return .title
        case .editorial: return .title3
        case .headline: return .headline
        case .body: return .body
        case .caption: return .footnote
        case .label: return .caption2
        }
    }

    /// Letter spacing in points. Small caps labels get generous tracking.
    public var tracking: CGFloat {
        switch self {
        case .label: return 2
        case .display: return 0.7
        default: return 0
        }
    }

    var fontName: String {
        let f = Brand.current.fonts
        switch self {
        case .display, .title: return f.display
        case .editorial: return f.displayItalic
        case .headline: return f.textSemibold
        case .body, .caption: return f.text
        case .label: return f.textMedium
        }
    }

    var isSerif: Bool { self == .display || self == .title || self == .editorial }

    public var font: Font {
        if UIFont(name: fontName, size: size) != nil {
            return .custom(fontName, size: size, relativeTo: relativeTo)
        }
        // Fallback when the licensed font files are not bundled.
        let base = Font.system(relativeTo, design: isSerif ? .serif : .default)
        return self == .editorial ? base.italic() : base
    }
}

extension View {
    /// Applies an AURUM text style, including tracking and uppercase for labels.
    public func aurumText(_ style: AurumTextStyle, color: Color = AurumColor.textPrimary) -> some View {
        self
            .font(style.font)
            .tracking(style.tracking)
            .textCase(style == .label ? .uppercase : nil)
            .foregroundColor(color)
    }
}
