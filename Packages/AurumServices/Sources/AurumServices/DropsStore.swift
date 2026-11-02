import Foundation
import AurumCore

/// The seasonal drop calendar (from `drops.json` in the bundle) and the
/// user's creation streak (in UserDefaults).
public final class DropsStore: @unchecked Sendable {
    public let schedule: DropSchedule
    private let defaults: UserDefaults
    private let lock = NSLock()

    static let streakKey = "aurum.streak"

    public init(schedule: DropSchedule, defaults: UserDefaults = .standard) {
        self.schedule = schedule
        self.defaults = defaults
    }

    /// Loads `drops.json` from a bundle. A missing or invalid file gives an
    /// empty calendar rather than a crash.
    public convenience init(bundle: Bundle, defaults: UserDefaults = .standard) {
        self.init(schedule: Self.loadSchedule(from: bundle), defaults: defaults)
    }

    public static func loadSchedule(from bundle: Bundle) -> DropSchedule {
        guard let url = bundle.url(forResource: "drops", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let schedule = try? DropSchedule.decode(from: data) else { return DropSchedule(drops: []) }
        return schedule
    }

    public var streak: Streak {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: Self.streakKey),
              let streak = try? JSONDecoder().decode(Streak.self, from: data) else { return Streak() }
        return streak
    }

    /// Records a finished creation (an export) for today.
    public func recordCreation(date: Date = Date(), calendar: Calendar = .current) {
        var s = streak
        s.record(date: date, calendar: calendar)
        lock.lock(); defer { lock.unlock() }
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: Self.streakKey) }
    }

    public func active(at date: Date = Date()) -> [Drop] { schedule.active(at: date) }
    public func upcoming(after date: Date = Date()) -> [Drop] { schedule.upcoming(after: date) }
}
