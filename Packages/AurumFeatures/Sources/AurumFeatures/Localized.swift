import SwiftUI
import AurumCore

/// Localises strings that come from AurumCore or remote config as plain
/// English values. The app's String Catalog holds each value as a key; a value
/// with no entry is shown as it is.
enum Localized {
    static func dynamic(_ value: String) -> String {
        String(localized: String.LocalizationValue(value))
    }
}

extension AdjustmentControl {
    /// `displayName` in the user's language.
    var localizedName: String { Localized.dynamic(displayName) }
}

extension PremiumItem {
    /// `displayName` in the user's language. Look names are brand content and stay as they are.
    var localizedName: String {
        switch self {
        case .look(_, let name): return name
        case .sticker: return String(localized: "Members' sticker")
        default: return Localized.dynamic(displayName)
        }
    }
}
