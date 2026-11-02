import XCTest
@testable import AurumServices
import AurumCore

final class Phase3ServicesTests: XCTestCase {
    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("aurum-p3-\(UUID().uuidString)", isDirectory: true)
    }

    func testProviderWithoutHTTPSBaseURLIsUnavailable() async {
        let none = RemoteAIProvider(baseURL: nil, inputLoader: { _, _ in Data() })
        XCTAssertEqual(none.availability, .unavailable)
        let plain = RemoteAIProvider(baseURL: URL(string: "http://example.com"), inputLoader: { _, _ in Data() })
        XCTAssertEqual(plain.availability, .unavailable)
        let secure = RemoteAIProvider(baseURL: URL(string: "https://example.com/aurum"), inputLoader: { _, _ in Data() })
        XCTAssertEqual(secure.availability, .available)
        do {
            _ = try await none.status(of: UUID())
            XCTFail("expected unavailable")
        } catch {
            XCTAssertEqual(error as? AIServiceError, .unavailable)
        }
    }

    func testResultReferencesResolveSafely() throws {
        let base = try XCTUnwrap(URL(string: "https://example.com/aurum"))
        XCTAssertEqual(RemoteAIProvider.resolve("/v1/jobs/a/results/0", base: base)?.absoluteString, "https://example.com/aurum/v1/jobs/a/results/0")
        XCTAssertEqual(RemoteAIProvider.resolve("https://cdn.example.com/r.jpg", base: base)?.absoluteString, "https://cdn.example.com/r.jpg")
        XCTAssertNil(RemoteAIProvider.resolve("http://cdn.example.com/r.jpg", base: base))
        XCTAssertNil(RemoteAIProvider.resolve("../secrets", base: base))
    }

    func testCreditStorePersistsLedgerAndHistory() {
        let dir = tempDir()
        let store = CreditStore(directory: dir)
        store.updateLedger { (ledger: inout CreditLedger) -> Bool in ledger.grantMonthly(period: "2026-11", date: Date()) }
        let request = AIJobRequest(feature: .enhance, inputs: [SourceAsset(localIdentifier: "a", pixelSize: PixelSize(width: 10, height: 10))])
        store.updateHistory { (history: inout AIJobHistory) -> Void in history.add(request, date: Date()) }
        let reopened = CreditStore(directory: dir)
        XCTAssertEqual(reopened.ledger.balance, CreditLedger.monthlyMemberGrant)
        XCTAssertEqual(reopened.history.records.first?.id, request.id)
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
