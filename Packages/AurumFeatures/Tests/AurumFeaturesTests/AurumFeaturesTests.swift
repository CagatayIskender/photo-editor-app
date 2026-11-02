import XCTest
import CoreImage
@testable import AurumFeatures
import AurumCore
import AurumRender
import AurumServices

@MainActor
final class StudioViewModelTests: XCTestCase {
    static func catalog() throws -> LookCatalog {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try LookCatalog.decode(from: Data(contentsOf: root.appendingPathComponent("Looks/catalog.json")))
    }

    static func card() -> CIImage {
        CIImage(color: CIColor(red: 0.7, green: 0.5, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 80, height: 60))
    }

    func makeModel(isNew: Bool = true, entitlement: Entitlement = .free) throws -> (StudioViewModel, AppDependencies) {
        let deps = AppDependencies.sample(catalog: try Self.catalog(), entitlement: entitlement)
        let doc = EditDocument(source: SourceAsset(localIdentifier: "sample-0", pixelSize: PixelSize(width: 80, height: 60)))
        return (StudioViewModel(document: doc, isNew: isNew, deps: deps, entitlement: { entitlement }), deps)
    }

    func testNewPhotoOpensWithAFreeSuggestedLookThatIsNotAnUndoStep() async throws {
        let (model, deps) = try makeModel()
        await model.loaded(proxy: Self.card(), startingLook: nil, preset: nil)
        let look = try XCTUnwrap(model.activeLookRecipe)
        XCTAssertEqual(look.tier, .free)
        XCTAssertFalse(model.canUndo)
        XCTAssertEqual(deps.catalog.look(id: look.id)?.collection, model.selectedCollectionID)
    }

    func testQueuedLookWinsOverSuggestion() async throws {
        let (model, deps) = try makeModel()
        let chosen = try XCTUnwrap(deps.catalog.looks.last)
        await model.loaded(proxy: Self.card(), startingLook: chosen.id, preset: nil)
        XCTAssertEqual(model.activeLook?.lookID, chosen.id)
    }

    func testTappingTheActiveLookRemovesIt() async throws {
        let (model, deps) = try makeModel()
        await model.loaded(proxy: Self.card(), startingLook: deps.catalog.looks[0].id, preset: nil)
        model.selectLook(deps.catalog.looks[0].id)
        XCTAssertNil(model.activeLook)
        model.undo()
        XCTAssertEqual(model.activeLook?.lookID, deps.catalog.looks[0].id)
    }

    func testSwipeCyclesThroughNeighbours() async throws {
        let (model, deps) = try makeModel()
        let first = deps.catalog.looks[0]
        await model.loaded(proxy: Self.card(), startingLook: first.id, preset: nil)
        model.cycleLook(by: 1)
        XCTAssertEqual(model.activeLook?.lookID, deps.catalog.neighbour(of: first.id, offset: 1)?.id)
        model.cycleLook(by: -1)
        XCTAssertEqual(model.activeLook?.lookID, first.id)
    }

    func testSliderDragIsOneUndoStep() async throws {
        let (model, _) = try makeModel()
        await model.loaded(proxy: Self.card(), startingLook: nil, preset: nil)
        model.beginInteraction()
        for v in stride(from: 0.0, through: 0.5, by: 0.05) { model.setAdjustment(.exposure, v) }
        model.endInteraction()
        XCTAssertEqual(model.adjustment(.exposure), 0.5, accuracy: 1e-9)
        model.undo()
        XCTAssertEqual(model.adjustment(.exposure), 0)
        XCTAssertFalse(model.canUndo)
    }

    func testTextOverlayEditing() async throws {
        let (model, _) = try makeModel()
        await model.loaded(proxy: Self.card(), startingLook: nil, preset: nil)
        model.addText("Bonjour")
        model.updateSelectedText { $0.style = .glow }
        guard case .text(let text) = try XCTUnwrap(model.selectedOverlay).content else { return XCTFail("expected text") }
        XCTAssertEqual(text.text, "Bonjour")
        XCTAssertEqual(text.style, .glow)
        model.removeSelectedOverlay()
        XCTAssertTrue(model.document.overlays.isEmpty)
    }

    func testCropAspectKeepsRotation() async throws {
        let (model, _) = try makeModel()
        await model.loaded(proxy: Self.card(), startingLook: nil, preset: nil)
        model.rotateQuarterTurn()
        model.setAspect(.square)
        XCTAssertEqual(model.document.crop.quarterTurns, 1)
        XCTAssertEqual(model.document.crop.aspect, .square)
    }

    func testUntouchedNewPhotoIsNotSavedAsDraft() async throws {
        let (model, deps) = try makeModel()
        await model.loaded(proxy: Self.card(), startingLook: nil, preset: nil)
        await model.saveDraft()
        let empty = await deps.drafts.list()
        XCTAssertTrue(empty.isEmpty)
        model.setAdjustment(.contrast, 0.2)
        await model.saveDraft()
        let saved = await deps.drafts.list()
        XCTAssertEqual(saved.count, 1)
    }
}

@MainActor
final class ExportViewModelTests: XCTestCase {
    func document(with lookID: String) -> EditDocument {
        var doc = EditDocument(source: SourceAsset(localIdentifier: "sample-0", pixelSize: PixelSize(width: 80, height: 60)))
        doc.applyLook(lookID)
        return doc
    }

    func testFreeExportIsWatermarkedAndCapped() {
        let options = ExportViewModel.options(for: .allowed(watermark: true, maxPixelSize: 2048), format: .jpeg, watermarkText: "AURUM")
        XCTAssertEqual(options?.watermark, "AURUM")
        XCTAssertEqual(options?.maxPixelSize, 2048)
        XCTAssertNil(ExportViewModel.options(for: .requiresMembership([]), format: .jpeg, watermarkText: "AURUM"))
    }

    func testMemberLookAsksForMembershipOrExportWithout() throws {
        let catalog = try StudioViewModelTests.catalog()
        let member = try XCTUnwrap(catalog.looks.first { $0.tier == .member })
        let deps = AppDependencies.sample(catalog: catalog)
        let model = ExportViewModel(document: document(with: member.id), deps: deps, entitlement: .free)
        guard case .requiresMembership(let items) = model.decision else { return XCTFail("expected paywall") }
        XCTAssertEqual(items, [.look(id: member.id, name: member.name)])
        model.exportWithoutPremium()
        XCTAssertEqual(model.decision, .allowed(watermark: true, maxPixelSize: ExportGate.freeMaxPixelSize))
        model.membershipChanged(to: .member)
        XCTAssertEqual(model.decision, .allowed(watermark: false, maxPixelSize: nil))
    }

    func testSaveToPhotosWritesData() async throws {
        let catalog = try StudioViewModelTests.catalog()
        let deps = AppDependencies.sample(catalog: catalog)
        let free = try XCTUnwrap(catalog.looks.first { $0.tier == .free })
        let model = ExportViewModel(document: document(with: free.id), deps: deps, entitlement: .free)
        await model.export(toPhotos: true)
        XCTAssertEqual(model.phase, .saved)
        XCTAssertEqual((deps.photos as? SamplePhotoLibrary)?.saved.count, 1)
    }
}

@MainActor
final class PaywallViewModelTests: XCTestCase {
    func testHighlightedPlanIsPreselectedAndTermsAreExplicit() async {
        let model = PaywallViewModel(purchases: MockPurchaseService(), analytics: RecordingAnalytics(), config: .defaults, trigger: "test")
        await model.load()
        XCTAssertEqual(model.selectedPlan?.period, .yearly)
        XCTAssertEqual(model.termsLine, "Free for 7 days, then $39.99 per year. Cancel anytime in Settings.")
        XCTAssertEqual(model.buttonTitle, "Start 7-day free trial")
    }

    func testPurchaseCompletes() async {
        let purchases = MockPurchaseService()
        let analytics = RecordingAnalytics()
        let model = PaywallViewModel(purchases: purchases, analytics: analytics, config: .defaults, trigger: "test")
        await model.load()
        await model.purchase()
        XCTAssertEqual(model.state, .purchased)
        XCTAssertEqual(purchases.entitlement, .member)
        XCTAssertEqual(analytics.events.last, .purchaseCompleted(planID: "yearly"))
    }
}
