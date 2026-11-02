import XCTest
import CoreImage
@testable import AurumFeatures
import AurumCore
import AurumRender
import AurumServices

@MainActor
final class AutoStudioViewModelTests: XCTestCase {
    func makeModel(entitlement: Entitlement = .free) throws -> AutoStudioViewModel {
        let deps = AppDependencies.sample(catalog: try StudioViewModelTests.catalog(), entitlement: entitlement)
        return AutoStudioViewModel(deps: deps, entitlement: { entitlement })
    }

    /// A small warm photo with a gentle gradient, so the auto tools have something to measure.
    func samplePhoto() -> CIImage {
        let g = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0),
            "inputPoint1": CIVector(x: 0, y: 96),
            "inputColor0": CIColor(red: 0.5, green: 0.35, blue: 0.2),
            "inputColor1": CIColor(red: 0.8, green: 0.6, blue: 0.4)
        ])
        return (g?.outputImage ?? CIImage(color: .gray)).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 96))
    }

    func testMembershipIsAskedOnlyForMembersToolsAndLooks() {
        XCTAssertTrue(AutoStudioViewModel.requiresMembership(feature: .retouch, lookID: nil, entitlement: .free))
        XCTAssertFalse(AutoStudioViewModel.requiresMembership(feature: .retouch, lookID: nil, entitlement: .member))
        XCTAssertFalse(AutoStudioViewModel.requiresMembership(feature: .enhance, lookID: nil, entitlement: .free))
        XCTAssertFalse(AutoStudioViewModel.requiresMembership(feature: .removeObject, lookID: nil, entitlement: .free))
        XCTAssertFalse(AutoStudioViewModel.requiresMembership(feature: .portraitLooks, lookID: "portrait.soft-studio", entitlement: .free))
        XCTAssertTrue(AutoStudioViewModel.requiresMembership(feature: .portraitLooks, lookID: "portrait.silver", entitlement: .free))
    }

    func testSuggestionsSwitchOnTheMatchingEnhanceParts() {
        let straighten = AutoStudioViewModel.enhanceOptions(for: .straighten)
        XCTAssertEqual(straighten?.straighten, true)
        XCTAssertEqual(straighten?.autoTone, false)
        XCTAssertEqual(AutoStudioViewModel.enhanceOptions(for: .fixRedEye)?.redEye, true)
        XCTAssertEqual(AutoStudioViewModel.enhanceOptions(for: .enhance), .all)
        XCTAssertNil(AutoStudioViewModel.enhanceOptions(for: .blurBackground))
        let straightenTitle = AutoStudioViewModel.title(for: AutoSuggestion(kind: .straighten, score: 1, degrees: -2.34))
        XCTAssertTrue(straightenTitle.contains("2") && straightenTitle.contains("3") && !straightenTitle.contains("-"))
    }

    func testRunIssueExplainsWhatIsMissing() throws {
        let model = try makeModel()
        XCTAssertNotNil(model.runIssue)
        model.setSourceImage(samplePhoto())
        model.select(.enhance)
        XCTAssertNil(model.runIssue)
        model.select(.removeObject)
        XCTAssertNotNil(model.runIssue)
        model.maskEditor.extend(to: AurumCore.NormalizedPoint(x: 0.5, y: 0.5))
        model.maskEditor.endStroke()
        XCTAssertNil(model.runIssue)
        model.select(.replaceBackground)
        model.background = .photo
        XCTAssertNotNil(model.runIssue, "a photo background needs a photo")
    }

    func testEnhanceRunsOnDeviceAndShowsAFreeResult() async throws {
        let model = try makeModel()
        model.setSourceImage(samplePhoto())
        model.select(.enhance)
        await model.run()
        XCTAssertEqual(model.phase, .result)
        XCTAssertNotNil(model.resultPreview)
        XCTAssertEqual(model.resultTier, .free)
        XCTAssertFalse(model.resultRequiresMembership)
    }

    func testRemoveObjectFillsTheBrushedArea() async throws {
        let model = try makeModel()
        model.setSourceImage(samplePhoto())
        model.select(.removeObject)
        model.maskEditor.extend(to: AurumCore.NormalizedPoint(x: 0.4, y: 0.5))
        model.maskEditor.extend(to: AurumCore.NormalizedPoint(x: 0.6, y: 0.5))
        model.maskEditor.endStroke()
        await model.run()
        XCTAssertEqual(model.phase, .result)
    }

    func testRetouchWithoutAFaceExplains() async throws {
        let model = try makeModel()
        model.setSourceImage(samplePhoto())
        model.select(.retouch)
        await model.run()
        if case .failed = model.phase {} else { XCTFail("expected a gentle failure message") }
    }

    func testKeepingAMembersLookAsksForMembershipFirst() async throws {
        let model = try makeModel(entitlement: .free)
        let app = AppModel(deps: model.deps)
        model.setSourceImage(samplePhoto())
        model.select(.portraitLooks)
        model.portraitLookID = "portrait.silver"
        await model.run()
        XCTAssertEqual(model.phase, .result)
        XCTAssertTrue(model.resultRequiresMembership)
        await model.openResultInStudio(app: app)
        XCTAssertTrue(model.isPaywallPresented)
        XCTAssertNil(app.studio)
    }
}

final class BrushMaskEditorTests: XCTestCase {
    func testStrokesAreClampedRecordedAndUndone() {
        var editor = BrushMaskEditor()
        editor.extend(to: AurumCore.NormalizedPoint(x: -0.2, y: 0.5))
        editor.extend(to: AurumCore.NormalizedPoint(x: 0.5, y: 1.4))
        editor.endStroke()
        XCTAssertTrue(editor.hasPaint)
        XCTAssertTrue(editor.mask.isInBounds)
        XCTAssertEqual(editor.mask.strokes.first?.points.first, AurumCore.NormalizedPoint(x: 0, y: 0.5))
        editor.undo()
        XCTAssertFalse(editor.hasPaint)
    }

    func testEraserOnlyMaskIsEmpty() {
        var editor = BrushMaskEditor()
        editor.isEraser = true
        editor.extend(to: AurumCore.NormalizedPoint(x: 0.5, y: 0.5))
        editor.endStroke()
        XCTAssertFalse(editor.hasPaint)
        XCTAssertTrue(editor.canUndo)
    }

    func testEndingWithoutPointsAddsNothing() {
        var editor = BrushMaskEditor()
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
