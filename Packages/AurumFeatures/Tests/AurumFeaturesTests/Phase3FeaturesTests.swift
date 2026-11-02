import XCTest
import CoreImage
@testable import AurumFeatures
import AurumCore
import AurumServices

/// A scripted AI server.
final class FakeAIBackend: AIBackend, @unchecked Sendable {
    var availability: AIProviderAvailability = .available
    var submitStatus: AIJobStatus
    var resultData = Data()
    private(set) var submitted: [AIJobRequest] = []

    init(submitStatus: AIJobStatus) {
        self.submitStatus = submitStatus
    }

    func submit(_ request: AIJobRequest) async throws -> AIJobStatus {
        submitted.append(request)
        return submitStatus
    }

    func status(of jobID: UUID) async throws -> AIJobStatus { submitStatus }
    func cancel(jobID: UUID) async throws {}
    func result(_ reference: String) async throws -> Data { resultData }

    static func jpeg() -> Data {
        let image = CIImage(color: CIColor(red: 0.6, green: 0.5, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        return CIContext().jpegRepresentation(of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:]) ?? Data()
    }
}

@MainActor
final class AIStudioViewModelTests: XCTestCase {
    let photo = PickedMedia(id: "sample-0", kind: .photo, pixelSize: PixelSize(width: 1600, height: 2000))

    func makeModel(backend: AIBackend? = nil, entitlement: Entitlement = .member, serverEnabled: Bool = true) throws -> AIStudioViewModel {
        var deps = AppDependencies.sample(catalog: try StudioViewModelTests.catalog(), entitlement: entitlement)
        if let backend { deps.ai = backend }
        return AIStudioViewModel(deps: deps, entitlement: { entitlement }, serverEnabled: serverEnabled)
    }

    func testOnDeviceFeaturesAreAlwaysAvailableAndServerOnesWaitForAServer() {
        XCTAssertEqual(AIStudioViewModel.mode(for: .enhance, serverAvailable: false), .onDevice)
        XCTAssertEqual(AIStudioViewModel.mode(for: .relight, serverAvailable: false), .onDevice)
        XCTAssertEqual(AIStudioViewModel.mode(for: .replaceBackground, serverAvailable: false), .onDevice)
        XCTAssertEqual(AIStudioViewModel.mode(for: .portrait, serverAvailable: false), .comingSoon)
        XCTAssertEqual(AIStudioViewModel.mode(for: .removeObject, serverAvailable: true), .server)
    }

    func testDefaultProviderIsUnavailableSoServerFeaturesAreComingSoon() throws {
        let model = try makeModel()
        XCTAssertFalse(model.isServerAvailable)
        XCTAssertEqual(model.mode(for: .avatar), .comingSoon)
    }

    func testRemoteSwitchOffKeepsServerFeaturesComingSoon() throws {
        let model = try makeModel(backend: FakeAIBackend(submitStatus: .queued), serverEnabled: false)
        XCTAssertEqual(model.mode(for: .portrait), .comingSoon)
    }

    func testMembersGetMonthlyCreditsOnce() throws {
        let model = try makeModel()
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        model.grantMonthlyCreditsIfMember(date: date)
        model.grantMonthlyCreditsIfMember(date: date)
        XCTAssertEqual(model.ledger.balance, CreditLedger.monthlyMemberGrant)
    }

    func testFreeUsersGetNoGrant() throws {
        let model = try makeModel(entitlement: .free)
        model.grantMonthlyCreditsIfMember()
        XCTAssertEqual(model.ledger.balance, 0)
    }

    func testUploadSizeStaysWithinTheFeatureLimit() {
        let size = AIStudioViewModel.uploadSize(PixelSize(width: 4000, height: 3000), maxPixels: 4_000_000)
        XCTAssertLessThanOrEqual(size.width * size.height, 4_000_000)
        XCTAssertEqual(Double(size.width) / Double(size.height), 4.0 / 3.0, accuracy: 0.01)
        XCTAssertEqual(AIStudioViewModel.uploadSize(PixelSize(width: 100, height: 100), maxPixels: 4_000_000), PixelSize(width: 100, height: 100))
    }

    func testBlockedPromptIsExplainedAndNeverSent() async throws {
        let backend = FakeAIBackend(submitStatus: .queued)
        let model = try makeModel(backend: backend)
        model.grantMonthlyCreditsIfMember()
        model.select(.replaceBackground)
        await model.setInputs([photo])
        model.prompt = "a garden full of bombs"
        XCTAssertNotNil(model.promptIssue)
        await model.generate()
        XCTAssertTrue(backend.submitted.isEmpty)
        XCTAssertEqual(model.ledger.balance, CreditLedger.monthlyMemberGrant)
    }

    func testSucceededJobChargesOnceAndShowsTheResult() async throws {
        let backend = FakeAIBackend(submitStatus: .succeeded(resultRefs: ["/v1/jobs/x/results/0"]))
        backend.resultData = FakeAIBackend.jpeg()
        let model = try makeModel(backend: backend)
        model.grantMonthlyCreditsIfMember()
        model.select(.enhance)
        await model.setInputs([photo])
        XCTAssertNil(model.generateIssue)
        await model.generate()
        XCTAssertEqual(backend.submitted.count, 1)
        XCTAssertEqual(model.ledger.balance, CreditLedger.monthlyMemberGrant - AIFeature.enhance.creditCost)
        XCTAssertEqual(model.phase, .result)
        XCTAssertNotNil(model.resultPreview)
        XCTAssertEqual(model.history.records.first?.status, .succeeded(resultRefs: ["/v1/jobs/x/results/0"]))
    }

    func testFailedJobIsRefunded() async throws {
        let backend = FakeAIBackend(submitStatus: .failed(reason: "busy"))
        let model = try makeModel(backend: backend)
        model.grantMonthlyCreditsIfMember()
        model.select(.enhance)
        await model.setInputs([photo])
        await model.generate()
        XCTAssertEqual(model.ledger.balance, CreditLedger.monthlyMemberGrant)
        if case .failed = model.phase {} else { XCTFail("expected a failure message") }
    }

    func testNotEnoughCreditsIsExplainedBeforeRunning() async throws {
        let backend = FakeAIBackend(submitStatus: .queued)
        let model = try makeModel(backend: backend, entitlement: .free)
        model.select(.portrait)
        await model.setInputs([photo])
        XCTAssertNotNil(model.generateIssue)
        await model.generate()
        XCTAssertTrue(backend.submitted.isEmpty)
    }

    func testValidationMessages() {
        XCTAssertNil(AIStudioViewModel.message(for: []))
        XCTAssertNotNil(AIStudioViewModel.message(for: [.maskRequired]))
        XCTAssertNotNil(AIStudioViewModel.message(for: [.wrongInputCount(expected: 2, actual: 1)]))
    }
}

final class AIMaskEditorTests: XCTestCase {
    func testStrokesAreClampedRecordedAndUndone() {
        var editor = AIMaskEditor()
        editor.extend(to: NormalizedPoint(x: -0.2, y: 0.5))
        editor.extend(to: NormalizedPoint(x: 0.5, y: 1.4))
        editor.endStroke()
        XCTAssertTrue(editor.hasPaint)
        XCTAssertTrue(editor.mask.isInBounds)
        XCTAssertEqual(editor.mask.strokes.first?.points.first, NormalizedPoint(x: 0, y: 0.5))
        editor.undo()
        XCTAssertFalse(editor.hasPaint)
    }

    func testEraserOnlyMaskIsEmpty() {
        var editor = AIMaskEditor()
        editor.isEraser = true
        editor.extend(to: NormalizedPoint(x: 0.5, y: 0.5))
        editor.endStroke()
        XCTAssertFalse(editor.hasPaint)
        XCTAssertTrue(editor.canUndo)
    }

    func testEndingWithoutPointsAddsNothing() {
        var editor = AIMaskEditor()
        editor.endStroke()
        XCTAssertFalse(editor.canUndo)
    }
}

final class CollageGeometryTests: XCTestCase {
    func testImageAlwaysCoversTheCell() {
        let cell = CGSize(width: 100, height: 200)
        let image = CGSize(width: 400, height: 300)
        for center in [NormalizedPoint(x: 0, y: 0), .center, NormalizedPoint(x: 1, y: 1)] {
            let frame = CollageCellGeometry.imageFrame(cell: cell, image: image, zoom: 1.5, center: center)
            XCTAssertLessThanOrEqual(frame.minX, 0.0001)
            XCTAssertLessThanOrEqual(frame.minY, 0.0001)
            XCTAssertGreaterThanOrEqual(frame.maxX, cell.width - 0.0001)
            XCTAssertGreaterThanOrEqual(frame.maxY, cell.height - 0.0001)
        }
    }

    func testPanningRightMovesTheCentreLeft() {
        let cell = CGSize(width: 100, height: 100)
        let image = CGSize(width: 400, height: 200)
        let moved = CollageCellGeometry.panned(.center, by: CGSize(width: 20, height: 0), cell: cell, image: image, zoom: 1)
        XCTAssertLessThan(moved.x, 0.5)
        XCTAssertEqual(moved.y, 0.5, accuracy: 1e-9)
    }
}

@MainActor
final class CollageViewModelTests: XCTestCase {
    func makeModel(entitlement: Entitlement = .free, layoutID: String = "collage.quartet") throws -> CollageViewModel {
        let deps = AppDependencies.sample(catalog: try StudioViewModelTests.catalog(), entitlement: entitlement)
        return CollageViewModel(deps: deps, entitlement: { entitlement }, layout: CollageLayout.layout(id: layoutID))
    }

    func picked(_ n: Int) -> [PickedMedia] {
        (0..<n).map { PickedMedia(id: "sample-\($0)", kind: .photo, pixelSize: PixelSize(width: 1600, height: 2000)) }
    }

    func testAddingFillsCellsInOrderAndIgnoresVideos() throws {
        let model = try makeModel()
        var items = picked(2)
        items.append(PickedMedia(id: "clip", kind: .video, pixelSize: PixelSize(width: 1080, height: 1920), duration: 3))
        model.add(items)
        XCTAssertEqual(model.project.filledCount, 2)
        XCTAssertEqual(model.project.cells[0]?.source.localIdentifier, "sample-0")
        XCTAssertEqual(model.emptyCellCount, 2)
    }

    func testTappingTwoCellsSwapsThem() throws {
        let model = try makeModel()
        model.add(picked(2))
        XCTAssertFalse(model.tap(cell: 0))
        XCTAssertEqual(model.selectedCell, 0)
        XCTAssertTrue(model.tap(cell: 1))
        XCTAssertNil(model.selectedCell)
        XCTAssertEqual(model.project.cells[0]?.source.localIdentifier, "sample-1")
    }

    func testMemberLayoutAsksForMembershipOnlyAtExport() throws {
        let model = try makeModel(layoutID: "collage.marquee")
        model.add(picked(3))
        guard case .requiresMembership = model.decision else { return XCTFail("member layout should need membership") }
        model.useFreeLayout()
        XCTAssertEqual(model.project.layout.tier, .free)
        XCTAssertEqual(model.project.layout.photoCount, 3)
        XCTAssertEqual(model.project.filledCount, 3)
        guard case .allowed(let watermark, _) = model.decision else { return XCTFail("free layout should export") }
        XCTAssertTrue(watermark)
    }

    func testFramingAdjustsZoomFromTheGestureStart() throws {
        let model = try makeModel()
        model.add(picked(1))
        model.beginAdjusting(cell: 0)
        model.adjust(cell: 0, translation: .zero, magnification: 2, cellSize: CGSize(width: 100, height: 100))
        model.adjust(cell: 0, translation: .zero, magnification: 2, cellSize: CGSize(width: 100, height: 100))
        model.endAdjusting()
        XCTAssertEqual(model.project.cells[0]?.zoom ?? 0, 2, accuracy: 1e-9)
    }
}

@MainActor
final class Phase3SmallLogicTests: XCTestCase {
    func testMemberMovesNeedMembershipOnlyForFreeUsers() {
        XCTAssertTrue(DepthMotionViewModel.requiresMembership(preset: .orbit, entitlement: .free))
        XCTAssertFalse(DepthMotionViewModel.requiresMembership(preset: .orbit, entitlement: .member))
        XCTAssertFalse(DepthMotionViewModel.requiresMembership(preset: .dolly, entitlement: .free))
    }

    func testExportSizeIsEvenAndCapped() {
        let size = DepthMotionViewModel.exportSize(for: CGSize(width: 4033, height: 3025))
        XCTAssertLessThanOrEqual(max(size.width, size.height), DepthMotionViewModel.exportLongestSide)
        XCTAssertEqual(size.width.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertEqual(size.height.truncatingRemainder(dividingBy: 2), 0)
    }

    func testCarouselCountIsClamped() {
        XCTAssertEqual(CarouselViewModel.clampCount(1), 2)
        XCTAssertEqual(CarouselViewModel.clampCount(12), 10)
        XCTAssertEqual(CarouselViewModel.clampCount(5), 5)
    }

    func testDropsSummaryShowsTheActiveDropAndALiveStreak() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
        }
        let schedule = DropSchedule(drops: [
            Drop(id: "a", title: "A", startsAt: day(2026, 10, 1), endsAt: day(2026, 12, 1), lookIDs: ["x", "y"], stickerIDs: ["s"]),
            Drop(id: "b", title: "B", startsAt: day(2026, 12, 1), endsAt: day(2027, 1, 1))
        ])
        var streak = Streak()
        streak.record(date: day(2026, 11, 1), calendar: calendar)
        streak.record(date: day(2026, 11, 2), calendar: calendar)
        let summary = DropsSummary(schedule: schedule, streak: streak, date: day(2026, 11, 3), calendar: calendar)
        XCTAssertEqual(summary.active?.id, "a")
        XCTAssertEqual(summary.upcoming.map(\.id), ["b"])
        XCTAssertEqual(summary.streak, 2)
        XCTAssertTrue(summary.streakAtRisk)
        XCTAssertNotNil(summary.streakText)
        XCTAssertEqual(DropsSummary.contents(of: schedule.drops[0]), "2 looks · 1 sticker")
    }

    func testBundledDropScheduleIsValid() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Content/drops.json"))
        let schedule = try DropSchedule.decode(from: data)
        XCTAssertEqual(schedule.drops.count, 3)
    }
}
