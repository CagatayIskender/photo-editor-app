import XCTest
@testable import AurumCore

// MARK: - Helpers

private enum P3 {
    static let date = Date(timeIntervalSince1970: 1_800_000_000)

    static func id(_ n: Int) -> UUID {
        let digits = String(n)
        return UUID(uuidString: "00000000-0000-0000-0000-" + String(repeating: "0", count: 12 - digits.count) + digits)!
    }

    /// Gregorian calendar in a fixed UTC+3 zone (no daylight saving).
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 3 * 3600)!
        return c
    }

    static func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour, minute: minute))!
    }

    static func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let plain = try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(plain, value, file: file, line: line)
        let iso = try EditDocument.makeDecoder().decode(T.self, from: EditDocument.makeEncoder().encode(value))
        XCTAssertEqual(iso, value, file: file, line: line)
    }

    static func overlapArea(_ a: NormalizedRect, _ b: NormalizedRect) -> Double {
        let w = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
        let h = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
        return max(0, w) * max(0, h)
    }

    static func isInsideUnitSquare(_ r: NormalizedRect, tolerance: Double = 1e-9) -> Bool {
        r.x >= -tolerance && r.y >= -tolerance && r.width > 0 && r.height > 0
            && r.x + r.width <= 1 + tolerance && r.y + r.height <= 1 + tolerance
    }
}

// MARK: - Depth motion

final class DepthMotionTests: XCTestCase {
    func testLoopIsSeamless() {
        for preset in DepthMotionPreset.allCases {
            for intensity in [0.3, 1.0] {
                let motion = DepthMotion(preset: preset, intensity: intensity)
                let duration = 4.0
                XCTAssertEqual(motion.sample(at: 0, duration: duration), motion.sample(at: duration, duration: duration), "\(preset)")
                let start = motion.sample(at: 0, duration: duration)
                let end = motion.sample(at: duration - 1e-6, duration: duration)
                XCTAssertEqual(start.dx, end.dx, accuracy: 1e-6)
                XCTAssertEqual(start.dy, end.dy, accuracy: 1e-6)
                XCTAssertEqual(start.zoom, end.zoom, accuracy: 1e-6)
                XCTAssertEqual(start.focusDepth, end.focusDepth, accuracy: 1e-6)
                // Times wrap around.
                let a = motion.sample(at: 1.0, duration: duration)
                let b = motion.sample(at: 9.0, duration: duration)
                XCTAssertEqual(a.dx, b.dx, accuracy: 1e-12)
                XCTAssertEqual(a.zoom, b.zoom, accuracy: 1e-12)
            }
        }
    }

    func testSamplesStayInBoundsAndCoverTheFrame() {
        for preset in DepthMotionPreset.allCases {
            for intensity in [0.0, 0.5, 1.0] {
                let motion = DepthMotion(preset: preset, intensity: intensity, focusDepth: 0.9)
                let limit = DepthMotion.maxOffset * intensity + 1e-12
                var moved = false
                for step in 0...240 {
                    let s = motion.sample(at: Double(step) / 60, duration: 4)
                    XCTAssertLessThanOrEqual(abs(s.dx), limit)
                    XCTAssertLessThanOrEqual(abs(s.dy), limit)
                    XCTAssertGreaterThanOrEqual(s.zoom, 1)
                    XCTAssertLessThanOrEqual(s.zoom, 1 + DepthMotion.maxZoom + 1e-12)
                    XCTAssertGreaterThanOrEqual(s.zoom - 1 + 1e-12, 2 * max(abs(s.dx), abs(s.dy)))
                    XCTAssertTrue((0.0...1.0).contains(s.focusDepth))
                    if s != motion.sample(at: 0, duration: 4) { moved = true }
                }
                XCTAssertEqual(moved, intensity > 0, "\(preset) \(intensity)")
            }
        }
    }

    func testZeroIntensityIsStillAndSamplingIsDeterministic() {
        let still = DepthMotion(preset: .orbit, intensity: 0, focusDepth: 0.3).sample(at: 1.3, duration: 4)
        XCTAssertEqual(still.dx, 0)
        XCTAssertEqual(still.dy, 0)
        XCTAssertEqual(still.zoom, 1)
        XCTAssertEqual(still.focusDepth, 0.3)
        let m = DepthMotion(preset: .float, intensity: 0.8)
        XCTAssertEqual(m.sample(at: 2.2, duration: 5), m.sample(at: 2.2, duration: 5))
        XCTAssertEqual(m.sample(at: 2.2, duration: 0), m.sample(at: 0, duration: 5))
        XCTAssertEqual(DepthMotion(preset: .swing, intensity: 3).intensity, 1)
    }

    func testDepthMotionRoundTrips() throws {
        try P3.roundTrip(DepthMotion(preset: .dolly, intensity: 0.7, focusDepth: 0.25))
    }
}

// MARK: - Collage and carousel

final class CollageTests: XCTestCase {
    func testLibraryCoversTwoToSixPhotos() {
        let library = CollageLayout.library
        XCTAssertEqual(library.count, 12)
        XCTAssertEqual(Set(library.map(\.id)).count, library.count)
        for count in 2...6 {
            XCTAssertGreaterThanOrEqual(CollageLayout.layouts(forPhotoCount: count).count, 2, "\(count) photos")
        }
        XCTAssertTrue(library.contains { $0.tier == .member })
        XCTAssertTrue(library.contains { $0.tier == .free })
        XCTAssertEqual(CollageLayout.layout(id: "collage.quartet")?.photoCount, 4)
    }

    func testCellsAreInsideNonOverlappingAndTileTheCanvas() {
        for layout in CollageLayout.library {
            var area = 0.0
            for (i, cell) in layout.cells.enumerated() {
                XCTAssertTrue(P3.isInsideUnitSquare(cell), "\(layout.id) cell \(i)")
                area += cell.width * cell.height
                for other in layout.cells[(i + 1)...] {
                    XCTAssertLessThan(P3.overlapArea(cell, other), 1e-9, layout.id)
                }
            }
            XCTAssertEqual(area, 1, accuracy: 1e-9, layout.id)
        }
    }

    func testSpacingKeepsFramesApart() {
        for layout in CollageLayout.library {
            XCTAssertEqual(layout.frames(spacing: 0), layout.cells)
            let frames = layout.frames(spacing: 0.04)
            for (i, frame) in frames.enumerated() {
                XCTAssertTrue(P3.isInsideUnitSquare(frame), layout.id)
                XCTAssertGreaterThan(frame.x, 0)
                XCTAssertLessThan(frame.x + frame.width, 1)
                for other in frames[(i + 1)...] {
                    XCTAssertEqual(P3.overlapArea(frame, other), 0, layout.id)
                }
            }
        }
        // On a square canvas the outer border equals the spacing.
        let quartet = CollageLayout.layout(id: "collage.quartet")!
        XCTAssertEqual(quartet.frames(spacing: 0.04)[0].x, 0.04, accuracy: 1e-12)
        XCTAssertEqual(quartet.frames(spacing: 0.04)[1].x - (quartet.frames(spacing: 0.04)[0].x + quartet.frames(spacing: 0.04)[0].width), 0.04, accuracy: 1e-12)
    }

    func testProjectEditing() throws {
        let trio = CollageLayout.layout(id: "collage.salon")!
        var project = CollageProject(id: P3.id(1), layout: trio, spacing: 0.2, cornerRadius: -1, backgroundHex: "fa0")
        XCTAssertEqual(project.spacing, 0.05)
        XCTAssertEqual(project.cornerRadius, 0)
        XCTAssertEqual(project.backgroundHex, "#FFAA00")
        XCTAssertEqual(project.cells.count, 3)
        XCTAssertEqual(CollageProject.normalizedHex("#12ab9C"), "#12AB9C")
        XCTAssertNil(CollageProject.normalizedHex("#12ab9"))
        XCTAssertNil(CollageProject.normalizedHex("blue"))

        let a = SourceAsset(localIdentifier: "a", pixelSize: PixelSize(width: 10, height: 10))
        let b = SourceAsset(localIdentifier: "b", pixelSize: PixelSize(width: 10, height: 10))
        let c = SourceAsset(localIdentifier: "c", pixelSize: PixelSize(width: 10, height: 10))
        XCTAssertEqual(project.add(a), 0)
        XCTAssertEqual(project.add(b), 1)
        project.assign(CollageProject.Cell(source: c, zoom: 9, center: NormalizedPoint(x: -1, y: 0.4)), at: 2)
        XCTAssertEqual(project.cells[2]?.zoom, 4)
        XCTAssertEqual(project.cells[2]?.center, NormalizedPoint(x: 0, y: 0.4))
        XCTAssertTrue(project.isComplete)
        XCTAssertNil(project.add(a))
        project.swapCells(0, 2)
        XCTAssertEqual(project.cells.map { $0?.source.localIdentifier }, ["c", "b", "a"])
        try P3.roundTrip(project)

        project.setLayout(CollageLayout.layout(id: "collage.duet")!)
        XCTAssertEqual(project.cells.map { $0?.source.localIdentifier }, ["c", "b"])
        project.setLayout(CollageLayout.layout(id: "collage.quartet")!)
        XCTAssertEqual(project.cells.map { $0?.source.localIdentifier }, ["c", "b", nil, nil])
        XCTAssertEqual(project.filledCount, 2)
        XCTAssertFalse(project.isComplete)
        try P3.roundTrip(project)
    }

    func testCarouselPanelsTileExactly() {
        let cases: [(image: Double, count: Int, panel: Double)] = [
            (3, 3, 1), (4.0 / 3, 3, 4.0 / 5), (16.0 / 9, 5, 4.0 / 5), (21.0 / 9, 7, 1), (0.75, 2, 1), (2.7, 10, 9.0 / 16), (5, 2, 1), (4, 3, 4.0 / 5)
        ]
        for c in cases {
            let panels = Carousel.panels(for: c.image, count: c.count, panelAspect: c.panel)
            XCTAssertEqual(panels.count, c.count)
            for (i, p) in panels.enumerated() {
                XCTAssertTrue(P3.isInsideUnitSquare(p, tolerance: 1e-12))
                XCTAssertEqual(p.width * c.image / p.height, c.panel, accuracy: 1e-9)
                XCTAssertEqual(p.y, panels[0].y)
                XCTAssertEqual(p.height, panels[0].height)
                if i + 1 < panels.count {
                    XCTAssertEqual(p.x + p.width, panels[i + 1].x, "seam \(i) of \(c)")
                }
            }
            // The strip is centred and uses the full height or the full width.
            let left = panels[0].x
            let right = 1 - (panels[panels.count - 1].x + panels[panels.count - 1].width)
            XCTAssertEqual(left, right, accuracy: 1e-12)
            XCTAssertTrue(abs(panels[0].height - 1) < 1e-12 || abs(left) < 1e-12)
        }
        // A 3:1 panorama splits into three full squares.
        XCTAssertEqual(Carousel.panels(for: 3, count: 3, panelAspect: 1).map(\.x), [0, 1.0 / 3, 2.0 / 3])
        XCTAssertEqual(Carousel.panels(for: 3, count: 3, panelAspect: 1).last.map { $0.x + $0.width }, 1)
        XCTAssertTrue(Carousel.panels(for: 0, count: 3, panelAspect: 1).isEmpty)
        XCTAssertTrue(Carousel.panels(for: 2, count: 0, panelAspect: 1).isEmpty)
        XCTAssertEqual(Carousel.panels(for: 50, count: 100, panelAspect: 1).count, Carousel.maxPanels)
    }

    func testPremiumLayoutGatesExport() {
        let free = CollageProject(layout: CollageLayout.layout(id: "collage.duet")!)
        let premiumLayout = CollageLayout.library.first { $0.tier == .member }!
        let premium = CollageProject(layout: premiumLayout)
        XCTAssertEqual(ExportGate.collageDecision(for: free, entitlement: .free), .allowed(watermark: true, maxPixelSize: ExportGate.freeMaxPixelSize))
        XCTAssertEqual(
            ExportGate.collageDecision(for: premium, entitlement: .free),
            .requiresMembership([.collageLayout(id: premiumLayout.id, name: premiumLayout.name)])
        )
        XCTAssertEqual(ExportGate.collageDecision(for: premium, entitlement: .member), .allowed(watermark: false, maxPixelSize: nil))
        XCTAssertEqual(PremiumItem.collageLayout(id: "x", name: "Vitrine").displayName, "Vitrine")
    }
}

// MARK: - Drops and streaks

final class DropsTests: XCTestCase {
    func schedule() -> DropSchedule {
        DropSchedule(drops: [
            Drop(id: "winter", title: "Winter Gala", startsAt: P3.day(2026, 12, 1, hour: 0), endsAt: P3.day(2027, 1, 1, hour: 0), lookIDs: ["gala.1"], tier: .member),
            Drop(id: "holiday", title: "Holiday Lights", startsAt: P3.day(2026, 12, 20, hour: 0), endsAt: P3.day(2026, 12, 27, hour: 0), stickerIDs: ["lights"]),
            Drop(id: "spring", title: "First Bloom", startsAt: P3.day(2027, 3, 1, hour: 0), endsAt: P3.day(2027, 4, 1, hour: 0), templateIDs: ["bloom"]),
            Drop(id: "newyear", title: "Midnight", startsAt: P3.day(2027, 1, 1, hour: 0), endsAt: P3.day(2027, 1, 8, hour: 0))
        ])
    }

    func testActiveAndUpcoming() throws {
        let s = schedule()
        XCTAssertNoThrow(try s.validate())
        XCTAssertEqual(s.active(at: P3.day(2026, 12, 22)).map(\.id), ["holiday", "winter"])
        XCTAssertEqual(s.active(at: P3.day(2026, 11, 2)).map(\.id), [])
        // endsAt is exclusive and startsAt inclusive.
        XCTAssertEqual(s.active(at: P3.day(2027, 1, 1, hour: 0)).map(\.id), ["newyear"])
        XCTAssertEqual(s.upcoming(after: P3.day(2026, 12, 22)).map(\.id), ["newyear", "spring"])
        XCTAssertEqual(s.upcoming(after: P3.day(2027, 3, 1, hour: 0)).map(\.id), [])
    }

    func testScheduleValidationAndRoundTrip() throws {
        XCTAssertEqual(Drop(id: "x", title: "x", startsAt: Date(timeIntervalSince1970: 10.9), endsAt: Date(timeIntervalSince1970: 20)).startsAt.timeIntervalSince1970, 10)
        let clean = schedule()
        XCTAssertEqual(try DropSchedule.decode(from: clean.encoded()), clean)
        try P3.roundTrip(clean)

        var dup = clean
        dup.drops.append(clean.drops[0])
        XCTAssertThrowsError(try dup.validate()) { XCTAssertEqual($0 as? DropSchedule.ValidationError, .duplicateID("winter")) }
        let backwards = DropSchedule(drops: [Drop(id: "b", title: "b", startsAt: P3.date, endsAt: P3.date)])
        XCTAssertThrowsError(try backwards.validate()) { XCTAssertEqual($0 as? DropSchedule.ValidationError, .endsBeforeStart("b")) }
    }

    func testStreakCountsConsecutiveCalendarDays() throws {
        let cal = P3.calendar
        var streak = Streak()
        XCTAssertEqual(streak.current(at: P3.day(2026, 12, 30), calendar: cal), 0)
        streak.record(date: P3.day(2026, 12, 30, hour: 9), calendar: cal)
        streak.record(date: P3.day(2026, 12, 30, hour: 22), calendar: cal)   // same day counts once
        XCTAssertEqual(streak.length, 1)
        streak.record(date: P3.day(2026, 12, 31, hour: 23, minute: 59), calendar: cal)
        streak.record(date: P3.day(2027, 1, 1, hour: 0, minute: 1), calendar: cal)  // across the new year
        XCTAssertEqual(streak.current(at: P3.day(2027, 1, 1), calendar: cal), 3)
        XCTAssertFalse(streak.isAtRisk(at: P3.day(2027, 1, 1), calendar: cal))
        // Still alive the next day until something is made.
        XCTAssertEqual(streak.current(at: P3.day(2027, 1, 2, hour: 23), calendar: cal), 3)
        XCTAssertTrue(streak.isAtRisk(at: P3.day(2027, 1, 2), calendar: cal))
        // A missed day resets.
        XCTAssertEqual(streak.current(at: P3.day(2027, 1, 3, hour: 0), calendar: cal), 0)
        streak.record(date: P3.day(2027, 1, 3), calendar: cal)
        XCTAssertEqual(streak.length, 1)
        XCTAssertEqual(streak.best, 3)
        // Old dates are ignored.
        streak.record(date: P3.day(2026, 6, 1), calendar: cal)
        XCTAssertEqual(streak.lastDay, DayStamp(year: 2027, month: 1, day: 3))
        try P3.roundTrip(streak)
    }

    func testStreakUsesTheCalendarTimeZone() {
        // 22:30 UTC on 28 Feb 2028 is already 29 Feb (leap day) at UTC+3.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let lateUTC = utc.date(from: DateComponents(year: 2028, month: 2, day: 28, hour: 22, minute: 30))!
        XCTAssertEqual(DayStamp(date: lateUTC, calendar: utc), DayStamp(year: 2028, month: 2, day: 28))
        XCTAssertEqual(DayStamp(date: lateUTC, calendar: P3.calendar), DayStamp(year: 2028, month: 2, day: 29))

        var streak = Streak()
        streak.record(date: P3.day(2028, 2, 28), calendar: P3.calendar)
        streak.record(date: lateUTC, calendar: P3.calendar)
        streak.record(date: P3.day(2028, 3, 1), calendar: P3.calendar)
        XCTAssertEqual(streak.length, 3)
        XCTAssertEqual(DayStamp(year: 2028, month: 3, day: 1).dayNumber - DayStamp(year: 2028, month: 2, day: 28).dayNumber, 2)
        XCTAssertEqual(DayStamp(year: 2027, month: 3, day: 1).dayNumber - DayStamp(year: 2027, month: 2, day: 28).dayNumber, 1)
        XCTAssertLessThan(DayStamp(year: 2026, month: 12, day: 31), DayStamp(year: 2027, month: 1, day: 1))
    }
}

// MARK: - Catalog manifest

final class CatalogManifestTests: XCTestCase {
    let sha = String(repeating: "ab", count: 32)

    func pack(_ id: String, _ version: String, minApp: String = "1.0") -> CatalogPack {
        CatalogPack(id: id, version: SemanticVersion(version)!, itemCount: 12, sha256: sha, url: "https://cdn.example.com/\(id).zip", minAppVersion: SemanticVersion(minApp)!)
    }

    func testSemanticVersionParsingAndOrder() {
        XCTAssertEqual(SemanticVersion("1.2.3"), SemanticVersion(1, 2, 3))
        XCTAssertEqual(SemanticVersion("v2.0"), SemanticVersion(2))
        XCTAssertEqual(SemanticVersion("3"), SemanticVersion(3, 0, 0))
        XCTAssertEqual(SemanticVersion("1.2.3-beta.1+77"), SemanticVersion(1, 2, 3))
        for bad in ["", "1..2", "a.b", "1.2.3.4", "1.-2", "1.2.x"] {
            XCTAssertNil(SemanticVersion(bad), bad)
        }
        XCTAssertLessThan(SemanticVersion("1.9.9")!, SemanticVersion("1.10.0")!)
        XCTAssertLessThan(SemanticVersion("0.9")!, SemanticVersion("1")!)
        XCTAssertEqual(SemanticVersion.compare("2.0.0", "2"), .orderedSame)
        XCTAssertEqual(SemanticVersion.compare("2.1", "2.0.9"), .orderedDescending)
        XCTAssertEqual(SemanticVersion.compare("junk", "0.0.1"), .orderedAscending)
        XCTAssertEqual(SemanticVersion(1, 4, 0).description, "1.4.0")
    }

    func testManifestDecodesValidatesAndRoundTrips() throws {
        let json = """
        {"version": 3, "packs": [
          {"id": "looks.winter", "version": "1.2.0", "itemCount": 24, "sha256": "\(sha.uppercased())",
           "url": "https://cdn.example.com/winter.zip", "minAppVersion": "1.1"}
        ]}
        """
        let manifest = try CatalogManifest.decode(from: Data(json.utf8))
        XCTAssertEqual(manifest.packs[0].version, SemanticVersion(1, 2, 0))
        XCTAssertEqual(manifest.packs[0].sha256.lowercased(), sha)
        try P3.roundTrip(manifest)
        let encoded = String(decoding: try JSONEncoder().encode([SemanticVersion(1, 2, 0)]), as: UTF8.self)
        XCTAssertEqual(encoded, #"["1.2.0"]"#)

        XCTAssertThrowsError(try CatalogManifest(packs: [pack("a", "1"), pack("a", "2")]).validate())
        var badSha = pack("a", "1"); badSha.sha256 = "xyz"
        XCTAssertThrowsError(try CatalogManifest(packs: [badSha]).validate()) {
            XCTAssertEqual($0 as? CatalogManifest.ValidationError, .badChecksum("a"))
        }
        var http = pack("a", "1"); http.url = "http://cdn.example.com/a.zip"
        XCTAssertThrowsError(try CatalogManifest(packs: [http]).validate()) {
            XCTAssertEqual($0 as? CatalogManifest.ValidationError, .insecureURL("a"))
        }
        XCTAssertThrowsError(try JSONDecoder().decode([SemanticVersion].self, from: Data(#"["one"]"#.utf8)))
    }

    func testDiffDownloadsChangesAndRemovesUnlisted() {
        let manifest = CatalogManifest(packs: [
            pack("a", "1.0.0"), pack("b", "1.1.0"), pack("c", "1.0.0"), pack("future", "1.0.0", minApp: "9.0"), pack("rollback", "1.0.0")
        ])
        let installed = [
            InstalledPack(id: "a", version: SemanticVersion(1)),
            InstalledPack(id: "b", version: SemanticVersion(1)),
            InstalledPack(id: "rollback", version: SemanticVersion(1, 1)),
            InstalledPack(id: "zeta", version: SemanticVersion(1)),
            InstalledPack(id: "old", version: SemanticVersion(1))
        ]
        let diff = manifest.diff(installed: installed, appVersion: SemanticVersion(2))
        XCTAssertEqual(diff.download.map(\.id), ["b", "c", "rollback"])
        XCTAssertEqual(diff.remove, ["old", "zeta"])
        XCTAssertEqual(manifest.diff(installed: installed).download.map(\.id), ["b", "c", "future", "rollback"])

        // An installed pack that now needs a newer app is kept, not removed.
        let kept = manifest.diff(installed: [InstalledPack(id: "future", version: SemanticVersion(0, 9))], appVersion: SemanticVersion(2))
        XCTAssertEqual(kept.remove, [])
        XCTAssertFalse(kept.download.contains { $0.id == "future" })

        let synced = manifest.diff(installed: manifest.packs.map { InstalledPack(id: $0.id, version: $0.version) })
        XCTAssertTrue(synced.isEmpty)
    }
}
