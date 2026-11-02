import XCTest
@testable import AurumFeatures
import AurumCore
import AurumServices

/// Editing operations only: `buildsPreview: false` keeps AVFoundation out.
@MainActor
final class VideoEditorViewModelTests: XCTestCase {
    func makeModel(clips: [Clip]? = nil, entitlement: Entitlement = .free) throws -> (VideoEditorViewModel, AppDependencies) {
        let deps = AppDependencies.sample(catalog: try StudioViewModelTests.catalog(), entitlement: entitlement)
        var project = VideoProject()
        let source = SourceAsset(localIdentifier: "sample-0", pixelSize: PixelSize(width: 1080, height: 1920))
        for clip in clips ?? [
            Clip(kind: .video, source: source, sourceDuration: 6),
            Clip(kind: .video, source: source, sourceDuration: 4),
            Clip.photo(source, duration: 3)
        ] {
            project.append(clip)
        }
        let model = VideoEditorViewModel(project: project, deps: deps, entitlement: { entitlement }, buildsPreview: false)
        return (model, deps)
    }

    func testStartsWithFirstClipSelectedAndNothingToUndo() throws {
        let (model, _) = try makeModel()
        XCTAssertEqual(model.selectedClipID, model.project.clips.first?.id)
        XCTAssertFalse(model.canUndo)
        XCTAssertEqual(model.duration, 13, accuracy: 1e-9)
    }

    func testSplitAtPlayheadIsOneUndoStep() throws {
        let (model, _) = try makeModel()
        model.seek(to: 2)
        XCTAssertTrue(model.splitAtPlayhead())
        XCTAssertEqual(model.project.clips.count, 4)
        XCTAssertEqual(model.project.clips[0].duration, 2, accuracy: 1e-9)
        XCTAssertEqual(model.project.clips[1].duration, 4, accuracy: 1e-9)
        XCTAssertEqual(model.duration, 13, accuracy: 1e-9)
        model.undo()
        XCTAssertEqual(model.project.clips.count, 3)
        model.redo()
        XCTAssertEqual(model.project.clips.count, 4)
    }

    func testSplitTooCloseToAnEdgeDoesNothing() throws {
        let (model, _) = try makeModel()
        model.seek(to: 0.05)
        XCTAssertFalse(model.splitAtPlayhead())
        XCTAssertFalse(model.canUndo)
    }

    func testTrimDragIsOneUndoStep() throws {
        let (model, _) = try makeModel()
        model.beginInteraction()
        for end in stride(from: 6.0, through: 3.0, by: -0.5) { model.trimSelected(start: 1, end: end) }
        model.endInteraction()
        XCTAssertEqual(model.project.clips[0].trimStart, 1, accuracy: 1e-9)
        XCTAssertEqual(model.project.clips[0].trimEnd, 3, accuracy: 1e-9)
        model.undo()
        XCTAssertEqual(model.project.clips[0].trimEnd, 6, accuracy: 1e-9)
        XCTAssertFalse(model.canUndo)
    }

    func testSpeedReverseAndVolumeApplyToSelectedClip() throws {
        let (model, _) = try makeModel()
        model.setSpeed(2)
        model.toggleReverse()
        model.setVolume(0.25)
        let clip = try XCTUnwrap(model.selectedClip)
        XCTAssertEqual(clip.speed, 2)
        XCTAssertTrue(clip.isReversed)
        XCTAssertEqual(clip.volume, 0.25, accuracy: 1e-9)
        XCTAssertEqual(clip.duration, 3, accuracy: 1e-9)
    }

    func testPhotosCannotBeReversed() throws {
        let (model, _) = try makeModel()
        model.selectClip(model.project.clips[2].id)
        model.toggleReverse()
        XCTAssertFalse(model.project.clips[2].isReversed)
        XCTAssertFalse(model.isToolAvailable(.reverse))
    }

    func testMoveAndDeleteKeepTheFirstClipWithoutATransition() throws {
        let (model, _) = try makeModel()
        model.selectClip(model.project.clips[1].id)
        model.setTransition(.dissolve)
        XCTAssertEqual(model.project.clips[1].transitionIn, .dissolve(duration: TransitionChoice.defaultDuration))
        let first = model.project.clips[0].id
        model.selectClip(first)
        model.deleteSelectedClip()
        XCTAssertEqual(model.project.clips.count, 2)
        XCTAssertEqual(model.project.clips[0].transitionIn, .cut)
        XCTAssertFalse(model.project.clips.contains { $0.id == first })
        XCTAssertNotNil(model.selectedClipID)

        let last = model.project.clips[1].id
        model.selectClip(last)
        model.moveSelectedClip(by: -1)
        XCTAssertEqual(model.project.clips[0].id, last)
    }

    func testTheLastClipCannotBeDeleted() throws {
        let source = SourceAsset(localIdentifier: "sample-0", pixelSize: PixelSize(width: 10, height: 10))
        let (model, _) = try makeModel(clips: [Clip.photo(source)])
        XCTAssertFalse(model.canDeleteClip)
        model.deleteSelectedClip()
        XCTAssertEqual(model.project.clips.count, 1)
    }

    func testFirstClipHasNoTransition() throws {
        let (model, _) = try makeModel()
        model.setTransition(.zoom)
        XCTAssertEqual(model.project.clips[0].transitionIn, .cut)
        XCTAssertFalse(model.canUndo)
    }

    func testLookGradesTheWholeVideoAndTappingAgainRemovesIt() throws {
        let (model, deps) = try makeModel()
        let look = try XCTUnwrap(deps.catalog.looks.first)
        model.selectLook(look.id)
        XCTAssertEqual(model.activeLook?.lookID, look.id)
        model.setLookIntensity(0.4)
        XCTAssertEqual(model.activeLook?.intensity ?? 0, 0.4, accuracy: 1e-9)
        model.selectLook(look.id)
        XCTAssertNil(model.activeLook)
        XCTAssertTrue(model.project.operations.isEmpty)
    }

    func testTextLayerStartsAtThePlayhead() throws {
        let (model, _) = try makeModel()
        model.seek(to: 4)
        model.addText("Bonsoir")
        let layer = try XCTUnwrap(model.selectedLayer)
        XCTAssertEqual(layer.start, 4, accuracy: 1e-9)
        XCTAssertEqual(layer.end, 7, accuracy: 1e-9)
        model.updateSelectedLayer { $0.animationIn = .typewriter }
        model.updateSelectedText { $0.text = "Bonne nuit" }
        let updated = try XCTUnwrap(model.selectedLayer)
        XCTAssertEqual(updated.animationIn, .typewriter)
        guard case .text(let text) = updated.overlay.content else { return XCTFail("expected text") }
        XCTAssertEqual(text.text, "Bonne nuit")
        model.removeSelectedLayer()
        XCTAssertTrue(model.project.layers.isEmpty)
    }

    func testIntroShiftsTheClips() throws {
        let (model, _) = try makeModel()
        let preset = BookendPreset(id: "curtain", name: "Curtain", kind: .intro, duration: 1.5, tier: .free)
        model.setIntro(preset)
        XCTAssertEqual(model.project.intro?.presetID, "curtain")
        XCTAssertEqual(model.project.clipStartTimes.first ?? 0, 1.5, accuracy: 1e-9)
        model.setBookendTitle("Summer", intro: true)
        XCTAssertEqual(model.project.intro?.title, "Summer")
        model.setIntro(nil)
        XCTAssertNil(model.project.intro)
    }

    func testEffectsToggle() throws {
        let (model, _) = try makeModel()
        model.toggleEffect(.glitter)
        XCTAssertEqual(model.effect(of: .glitter)?.tier, .member)
        model.setEffectIntensity(0.3)
        XCTAssertEqual(model.effect(of: .glitter)?.intensity ?? 0, 0.3, accuracy: 1e-9)
        model.toggleEffect(.glitter)
        XCTAssertNil(model.effect(of: .glitter))
    }

    func testMemberEffectAsksForMembershipOnlyAtExport() throws {
        let (model, _) = try makeModel()
        model.toggleEffect(.flicker)
        XCTAssertFalse(model.makeExportModel().decision.requiresMembership)
        model.toggleEffect(.vhsTracking)
        let export = model.makeExportModel()
        XCTAssertTrue(export.decision.requiresMembership)
        XCTAssertTrue(export.canExportWithoutPremium)
        export.exportWithoutPremium()
        XCTAssertFalse(export.decision.requiresMembership)
        XCTAssertEqual(export.project.effects.map(\.kind), [.flicker])
        XCTAssertEqual(export.decision.maxPixelSize, ExportGate.freeVideoMaxPixelSize)
    }

    func testMemberBookendIsNamedAtExport() throws {
        let (model, deps) = try makeModel()
        model.setIntro(BookendPreset(id: "spotlight", name: "Spotlight", kind: .intro, duration: 1.5, tier: .member))
        let bookends = [BookendPreset(id: "spotlight", name: "Spotlight", kind: .intro, duration: 1.5, tier: .member)]
        let items = VideoExportViewModel.premiumBookends(in: model.project, bookends: bookends)
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].isBookend)
        let stripped = VideoExportViewModel.strippingPremium(from: model.project, catalog: deps.catalog, bookends: bookends)
        XCTAssertNil(stripped.intro)
    }

    func testMembersExportWithoutAsking() throws {
        let (model, _) = try makeModel(entitlement: .member)
        model.toggleEffect(.glitter)
        let decision = model.makeExportModel().decision
        XCTAssertFalse(decision.requiresMembership)
        XCTAssertFalse(decision.watermark)
    }

    func testPickedMediaBecomesATimelineInPickingOrder() {
        let picked = [
            PickedMedia(id: "v1", kind: .video, pixelSize: PixelSize(width: 1080, height: 1920), duration: 5),
            PickedMedia(id: "p1", kind: .photo, pixelSize: PixelSize(width: 1000, height: 1250))
        ]
        let project = MediaPickerView.project(from: picked)
        XCTAssertEqual(project.clips.map(\.kind), [.video, .photo])
        XCTAssertEqual(project.clips[0].duration, 5, accuracy: 1e-9)
        XCTAssertEqual(project.aspect, .story)
    }

    func testTemplateBuildsFromPickedMedia() throws {
        let deps = AppDependencies.sample(catalog: try StudioViewModelTests.catalog())
        let templates = TemplatesViewModel(deps: deps)
        let template = TemplateDefinition(id: "t", name: "T", tagline: "", tier: .free, slots: [TemplateSlot(beats: 4), TemplateSlot(beats: 2, transition: .dissolve(duration: 0.25))], bpm: 120)
        let picked = [PickedMedia(id: "p1", kind: .photo, pixelSize: PixelSize(width: 10, height: 10))]
        let project = try XCTUnwrap(templates.build(template, media: picked))
        XCTAssertEqual(project.clips.count, 2)
        XCTAssertEqual(project.templateID, "t")
        XCTAssertNil(templates.build(template, media: []))
        XCTAssertNotNil(templates.failure)
    }
}

@MainActor
final class RetouchToolTests: XCTestCase {
    func testRetouchIsOneOperationAndAMemberItem() throws {
        let deps = AppDependencies.sample(catalog: try StudioViewModelTests.catalog())
        let doc = EditDocument(source: SourceAsset(localIdentifier: "sample-0", pixelSize: PixelSize(width: 80, height: 60)))
        let model = StudioViewModel(document: doc, isNew: false, deps: deps, entitlement: { .free })
        model.setRetouch(.smoothing, 0.5)
        model.setRetouch(.jaw, -0.3)
        XCTAssertEqual(model.retouchValue(.smoothing), 0.5, accuracy: 1e-9)
        XCTAssertEqual(model.retouchValue(.jaw), -0.3, accuracy: 1e-9)
        XCTAssertEqual(model.document.operations.filter { if case .retouch = $0.kind { return true } else { return false } }.count, 1)
        XCTAssertTrue(model.makeExportModel().premiumItems.contains(.retouch))
        model.resetRetouch()
        XCTAssertTrue(model.retouch.isNeutral)
        model.applyNaturalRetouch()
        XCTAssertEqual(model.retouch.global, .natural)
        XCTAssertTrue(StudioTool.retouch.isPremium)
    }
}
