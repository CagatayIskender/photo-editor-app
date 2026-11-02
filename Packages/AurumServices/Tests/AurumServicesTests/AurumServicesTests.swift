import XCTest
@testable import AurumServices
import AurumCore

final class AurumServicesTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func document() -> EditDocument {
        var doc = EditDocument(source: SourceAsset(localIdentifier: "a", pixelSize: PixelSize(width: 10, height: 10)))
        doc.applyLook("c.linen")
        return doc
    }

    private let catalog = LookCatalog(
        collections: [LookCollection(id: "c", name: "C", tagline: "")],
        looks: [LookRecipe(id: "c.linen", name: "Linen", collection: "c", tier: .free, params: LookParameters())]
    )

    func testDraftRoundTripAndListing() async throws {
        let store = FileDraftStore(directory: tempDir, catalog: catalog)
        let doc = document()
        try await store.save(doc, thumbnailJPEG: Data([0xFF, 0xD8]))
        let loaded = try await store.load(id: doc.id)
        XCTAssertEqual(loaded.operations, doc.operations)
        let list = await store.list()
        XCTAssertEqual(list.map(\.id), [doc.id])
        XCTAssertEqual(list.first?.title, "Linen")
        XCTAssertNotNil(list.first?.thumbnailURL)
        try await store.delete(id: doc.id)
        let afterDelete = await store.list()
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testDraftListIgnoresCorruptFiles() async throws {
        try Data("not json".utf8).write(to: tempDir.appendingPathComponent("broken.json"))
        let store = FileDraftStore(directory: tempDir)
        let list = await store.list()
        XCTAssertTrue(list.isEmpty)
    }

    func testPresetStorePersists() async throws {
        let url = tempDir.appendingPathComponent("presets.json")
        let store = PresetStore(fileURL: url)
        try await store.add(Preset(name: "Gallery", from: document()))
        let reopened = PresetStore(fileURL: url)
        let all = await reopened.all()
        XCTAssertEqual(all.map(\.name), ["Gallery"])
    }

    func testPreferences() {
        let defaults = UserDefaults(suiteName: "aurum.tests.\(UUID().uuidString)")!
        let prefs = Preferences(defaults: defaults)
        XCTAssertFalse(prefs.hasCompletedOnboarding)
        prefs.vibes = ["film-analog", "noir", "haze"]
        prefs.toggleFavourite("c.linen")
        XCTAssertEqual(prefs.favouriteLookIDs, ["c.linen"])
        prefs.toggleFavourite("c.linen")
        XCTAssertTrue(prefs.favouriteLookIDs.isEmpty)
        XCTAssertEqual(Preferences(defaults: defaults).vibes, ["film-analog", "noir", "haze"])
    }

    @MainActor
    func testMockPurchaseUnlocksMembership() async throws {
        let service = MockPurchaseService()
        var seen: [Entitlement] = []
        service.onEntitlementChange = { seen.append($0) }
        let outcome = try await service.purchase(planID: "yearly")
        XCTAssertEqual(outcome, .purchased)
        XCTAssertEqual(service.entitlement, .member)
        XCTAssertEqual(seen, [.member])
    }

    func testSampleLibraryProvidesImages() async throws {
        let library = SamplePhotoLibrary()
        let items = await library.recentPhotos(limit: 5)
        XCTAssertEqual(items.count, 5)
        let image = try await library.image(for: items[0].id, maxPixelSize: 500)
        XCTAssertEqual(max(image.extent.width, image.extent.height), 500, accuracy: 1)
    }
}
