import Foundation

/// A seasonal drop: a limited-time bundle of looks, templates and stickers.
public struct Drop: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    /// Whole seconds, so drops round-trip exactly through JSON.
    public var startsAt: Date
    /// Exclusive: the drop has ended at this instant.
    public var endsAt: Date
    public var lookIDs: [String]
    public var templateIDs: [String]
    public var stickerIDs: [String]
    public var tier: Tier

    public init(id: String, title: String, startsAt: Date, endsAt: Date, lookIDs: [String] = [], templateIDs: [String] = [], stickerIDs: [String] = [], tier: Tier = .free) {
        self.id = id
        self.title = title
        self.startsAt = startsAt.wholeSeconds
        self.endsAt = endsAt.wholeSeconds
        self.lookIDs = lookIDs
        self.templateIDs = templateIDs
        self.stickerIDs = stickerIDs
        self.tier = tier
    }

    public func isActive(at date: Date) -> Bool { startsAt <= date && date < endsAt }
}

/// The drop calendar, delivered with the catalogue.
public struct DropSchedule: Codable, Equatable, Sendable {
    public var drops: [Drop]

    public init(drops: [Drop]) {
        self.drops = drops
    }

    public enum ValidationError: Error, Equatable {
        case duplicateID(String)
        case endsBeforeStart(String)
    }

    public func validate() throws {
        var seen = Set<String>()
        for drop in drops {
            guard seen.insert(drop.id).inserted else { throw ValidationError.duplicateID(drop.id) }
            guard drop.endsAt > drop.startsAt else { throw ValidationError.endsBeforeStart(drop.id) }
        }
    }

    /// Drops running at `date`, the most recently started first.
    public func active(at date: Date) -> [Drop] {
        drops.filter { $0.isActive(at: date) }
            .sorted { $0.startsAt != $1.startsAt ? $0.startsAt > $1.startsAt : $0.id < $1.id }
    }

    /// Drops that have not started by `date`, soonest first.
    public func upcoming(after date: Date) -> [Drop] {
        drops.filter { $0.startsAt > date }
            .sorted { $0.startsAt != $1.startsAt ? $0.startsAt < $1.startsAt : $0.id < $1.id }
    }

    /// Decodes and validates a schedule with ISO 8601 dates.
    public static func decode(from data: Data) throws -> DropSchedule {
        let schedule = try EditDocument.makeDecoder().decode(DropSchedule.self, from: data)
        try schedule.validate()
        return schedule
    }

    public func encoded() throws -> Data {
        try EditDocument.makeEncoder().encode(self)
    }
}

/// A calendar day, independent of time zone once recorded.
public struct DayStamp: Codable, Equatable, Hashable, Comparable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day `date` falls on in the calendar's time zone (Gregorian).
    public init(date: Date, calendar: Calendar) {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let c = gregorian.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// Days since a fixed epoch (proleptic Gregorian Julian Day Number).
    public var dayNumber: Int {
        let a = (14 - month) / 12
        let y = year + 4800 - a
        let m = month + 12 * a - 3
        return day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045
    }

    public static func < (lhs: DayStamp, rhs: DayStamp) -> Bool { lhs.dayNumber < rhs.dayNumber }
}

/// Consecutive days with at least one creation.
public struct Streak: Codable, Equatable, Sendable {
    public private(set) var lastDay: DayStamp?
    /// Length of the run ending on `lastDay`.
    public private(set) var length: Int
    public private(set) var best: Int

    public init() {
        self.lastDay = nil
        self.length = 0
        self.best = 0
    }

    /// Records a creation. Several on one day count once; a day missed
    /// starts a new run. Dates before the last recorded day are ignored.
    public mutating func record(date: Date, calendar: Calendar) {
        let today = DayStamp(date: date, calendar: calendar)
        guard let last = lastDay else {
            lastDay = today
            length = 1
            best = max(best, 1)
            return
        }
        let gap = today.dayNumber - last.dayNumber
        guard gap > 0 else { return }
        length = gap == 1 ? length + 1 : 1
        lastDay = today
        best = max(best, length)
    }

    /// The streak as shown at `date`: still alive if the last creation was
    /// today or yesterday, otherwise 0.
    public func current(at date: Date, calendar: Calendar) -> Int {
        guard let last = lastDay else { return 0 }
        let gap = DayStamp(date: date, calendar: calendar).dayNumber - last.dayNumber
        return gap <= 1 ? length : 0
    }

    /// True when the streak is alive but nothing has been created today yet.
    public func isAtRisk(at date: Date, calendar: Calendar) -> Bool {
        guard let last = lastDay, length > 0 else { return false }
        return DayStamp(date: date, calendar: calendar).dayNumber - last.dayNumber == 1
    }
}
