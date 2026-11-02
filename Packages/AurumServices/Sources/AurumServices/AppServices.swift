import Foundation

// MARK: - Analytics

/// The product funnel from the spec: import → apply → export → share, plus
/// paywall conversion. Events carry no photo content and no personal data.
public enum AnalyticsEvent: Equatable, Sendable {
    case onboardingCompleted(vibes: [String])
    case photoImported(source: String)
    case lookApplied(lookID: String, premium: Bool)
    case toolOpened(tool: String)
    case exportStarted(format: String)
    case exportCompleted(format: String, watermark: Bool, seconds: Double)
    case shared(destination: String)
    case paywallViewed(trigger: String)
    case purchaseCompleted(planID: String)
    case exportedWithoutPremium

    public var name: String {
        switch self {
        case .onboardingCompleted: return "onboarding_completed"
        case .photoImported: return "photo_imported"
        case .lookApplied: return "look_applied"
        case .toolOpened: return "tool_opened"
        case .exportStarted: return "export_started"
        case .exportCompleted: return "export_completed"
        case .shared: return "shared"
        case .paywallViewed: return "paywall_viewed"
        case .purchaseCompleted: return "purchase_completed"
        case .exportedWithoutPremium: return "exported_without_premium"
        }
    }
}

public protocol Analytics: Sendable {
    func track(_ event: AnalyticsEvent)
}

/// Prints events in debug builds. Replace with a real provider later.
public struct ConsoleAnalytics: Analytics {
    public init() {}
    public func track(_ event: AnalyticsEvent) {
        #if DEBUG
        print("[analytics] \(event.name) \(event)")
        #endif
    }
}

/// Records events for tests.
public final class RecordingAnalytics: Analytics, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [AnalyticsEvent] = []
    public init() {}
    public var events: [AnalyticsEvent] { lock.lock(); defer { lock.unlock() }; return _events }
    public func track(_ event: AnalyticsEvent) { lock.lock(); _events.append(event); lock.unlock() }
}

// MARK: - Remote config

/// Copy and switches that can change without an app release.
public struct RemoteConfigValues: Codable, Equatable, Sendable {
    public var paywallHeadline: String
    public var paywallBenefits: [String]
    public var highlightedPlan: String
    public var salonHeroCollection: String

    public static let defaults = RemoteConfigValues(
        paywallHeadline: "The whole atelier, unlocked.",
        paywallBenefits: ["Every look, effect and sticker", "Full-resolution export, no watermark", "New collections every week"],
        highlightedPlan: "yearly",
        salonHeroCollection: "seasons"
    )
}

public protocol RemoteConfig: Sendable {
    func values() async -> RemoteConfigValues
}

/// Returns bundled defaults. A live provider (Firebase Remote Config or a
/// JSON file on the CDN) conforms to the same protocol.
public struct BundledRemoteConfig: RemoteConfig {
    let overrides: RemoteConfigValues?
    public init(overrides: RemoteConfigValues? = nil) { self.overrides = overrides }
    public func values() async -> RemoteConfigValues { overrides ?? .defaults }
}

// MARK: - Preferences

/// Small, per-device preferences kept in UserDefaults.
public final class Preferences: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    enum Key {
        static let onboarded = "aurum.onboarded"
        static let vibes = "aurum.vibes"
        static let favourites = "aurum.favouriteLooks"
        static let presets = "aurum.presets"
    }

    public var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.onboarded) }
        set { defaults.set(newValue, forKey: Key.onboarded) }
    }

    /// Collection IDs the user picked in "Choose your aesthetic".
    public var vibes: [String] {
        get { defaults.stringArray(forKey: Key.vibes) ?? [] }
        set { defaults.set(newValue, forKey: Key.vibes) }
    }

    public var favouriteLookIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.favourites) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: Key.favourites) }
    }

    public func toggleFavourite(_ lookID: String) {
        var f = favouriteLookIDs
        if f.contains(lookID) { f.remove(lookID) } else { f.insert(lookID) }
        favouriteLookIDs = f
    }
}
