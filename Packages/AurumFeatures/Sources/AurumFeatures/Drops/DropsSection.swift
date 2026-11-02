import SwiftUI
import AurumCore
import AurumDesign
import AurumServices

/// What the Salon shows about drops and the streak at a given moment. Pure,
/// so tests can check it without the UI.
struct DropsSummary: Equatable {
    var active: Drop?
    var upcoming: [Drop]
    var streak: Int
    var streakAtRisk: Bool

    init(schedule: DropSchedule, streak: Streak, date: Date, calendar: Calendar, upcomingLimit: Int = 2) {
        active = schedule.active(at: date).first
        upcoming = Array(schedule.upcoming(after: date).prefix(upcomingLimit))
        self.streak = streak.current(at: date, calendar: calendar)
        streakAtRisk = streak.isAtRisk(at: date, calendar: calendar)
    }

    var isEmpty: Bool { active == nil && upcoming.isEmpty && streak == 0 }

    /// "4 looks · 2 templates · 3 stickers", leaving out empty kinds.
    static func contents(of drop: Drop) -> String {
        var parts: [String] = []
        if !drop.lookIDs.isEmpty {
            parts.append(drop.lookIDs.count == 1 ? String(localized: "1 look") : String(localized: "\(drop.lookIDs.count) looks"))
        }
        if !drop.templateIDs.isEmpty {
            parts.append(drop.templateIDs.count == 1 ? String(localized: "1 template") : String(localized: "\(drop.templateIDs.count) templates"))
        }
        if !drop.stickerIDs.isEmpty {
            parts.append(drop.stickerIDs.count == 1 ? String(localized: "1 sticker") : String(localized: "\(drop.stickerIDs.count) stickers"))
        }
        return parts.joined(separator: " · ")
    }

    /// A quiet line about the streak, or nil when there is none.
    var streakText: String? {
        guard streak > 0 else { return nil }
        if streakAtRisk {
            return streak == 1
                ? String(localized: "Create something today to keep your streak.")
                : String(localized: "Create something today to keep your \(streak)-day streak.")
        }
        return streak == 1 ? String(localized: "1 day of creating") : String(localized: "\(streak) days in a row")
    }

    /// The last day a drop is available (its end is exclusive).
    static func lastDay(of drop: Drop) -> Date { drop.endsAt.addingTimeInterval(-1) }
}

/// The Salon's drops section: the drop running now, what's next, and a
/// quiet streak line.
struct DropsSection: View {
    @ObservedObject var app: AppModel

    var body: some View {
        let summary = DropsSummary(schedule: app.deps.drops.schedule, streak: app.deps.drops.streak, date: Date(), calendar: .current)
        if !summary.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Drops").aurumText(.headline)
                    Spacer()
                    if let streak = summary.streakText {
                        HStack(spacing: 4) {
                            IconView(.sparkle, size: 12).foregroundColor(AurumColor.accent)
                            Text(streak).aurumText(.caption, color: AurumColor.textTertiary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.horizontal, Spacing.m)
                if let drop = summary.active {
                    activeCard(drop)
                }
                ForEach(summary.upcoming) { drop in
                    upcomingRow(drop)
                }
            }
        }
    }

    private func activeCard(_ drop: Drop) -> some View {
        let looks = drop.lookIDs.compactMap { app.catalog.look(id: $0) }
        let until = DropsSummary.lastDay(of: drop).formatted(.dateTime.day().month(.wide))
        return VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.xs) {
                Text("NOW SHOWING").aurumText(.label, color: AurumColor.accent)
                if drop.tier == .member { CrownBadge(size: 14) }
            }
            Text(Localized.dynamic(drop.title)).aurumText(.title)
            Text(String(localized: "Until \(until)") + " · " + DropsSummary.contents(of: drop))
                .aurumText(.caption, color: AurumColor.textSecondary)
            if !looks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.s) {
                        ForEach(looks) { look in
                            Button { app.startCreating(withLook: look.id) } label: {
                                LookThumbnail(name: look.name, image: nil, swatch: look.swatch.map(Color.init(hex:)), isSelected: false, isPremium: look.tier == .member)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Pick a photo to edit with this look")
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
            if !drop.templateIDs.isEmpty {
                Button("See the templates") { app.openTemplates() }
                    .buttonStyle(TextActionButtonStyle())
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(AurumColor.surface))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(AurumColor.goldHairline, lineWidth: 1))
        .padding(.horizontal, Spacing.m)
    }

    private func upcomingRow(_ drop: Drop) -> some View {
        let starts = drop.startsAt.formatted(.dateTime.day().month(.wide))
        return HStack(spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Localized.dynamic(drop.title)).aurumText(.editorial)
                Text(DropsSummary.contents(of: drop)).aurumText(.caption, color: AurumColor.textTertiary)
            }
            Spacer()
            Text(String(localized: "From \(starts)")).aurumText(.caption, color: AurumColor.textSecondary)
        }
        .padding(.horizontal, Spacing.m)
        .accessibilityElement(children: .combine)
    }
}
