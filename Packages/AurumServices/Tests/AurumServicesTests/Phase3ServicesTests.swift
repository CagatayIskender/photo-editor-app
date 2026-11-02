import XCTest
@testable import AurumServices
import AurumCore

final class Phase3ServicesTests: XCTestCase {
    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("aurum-p3-\(UUID().uuidString)", isDirectory: true)
    }

    func testDropsStoreKeepsTheStreak() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "aurum.p3.\(UUID().uuidString)"))
        let store = DropsStore(schedule: DropSchedule(drops: []), defaults: defaults)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day1 = Date(timeIntervalSince1970: 1_793_000_000)
        store.recordCreation(date: day1, calendar: calendar)
        store.recordCreation(date: day1.addingTimeInterval(86_400), calendar: calendar)
        let again = DropsStore(schedule: DropSchedule(drops: []), defaults: defaults)
        XCTAssertEqual(again.streak.current(at: day1.addingTimeInterval(86_400), calendar: calendar), 2)
    }

    func testCatalogUpdaterWithoutURLDoesNothing() async {
        let updater = CatalogUpdater(manifestURL: nil, appVersion: SemanticVersion(1), directory: tempDir())
        let configured = await updater.isConfigured
        XCTAssertFalse(configured)
        do {
            _ = try await updater.update()
            XCTFail("expected notConfigured")
        } catch {
            XCTAssertEqual(error as? CatalogUpdater.UpdateError, .notConfigured)
        }
    }

    func testSHA256Hex() {
        XCTAssertEqual(CatalogUpdater.sha256Hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
