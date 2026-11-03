import XCTest
@testable import AurumCore

final class VideoProjectTests: XCTestCase {
    let asset = SourceAsset(localIdentifier: "v", pixelSize: PixelSize(width: 1920, height: 1080))

    func video(_ length: Seconds) -> Clip {
        Clip(kind: .video, source: asset, sourceDuration: length)
    }

    func testDurationAccountsForTrimSpeedAndTransitions() {
        var project = VideoProject()
        var a = video(10)
        a.trim(start: 2, end: 6)          // 4 s
        var b = video(8)
        b.setSpeed(2)                      // 4 s
        b.transitionIn = .dissolve(duration: 1)
        project.clips = [a, b]
        XCTAssertEqual(project.clipStartTimes, [0, 3])
        XCTAssertEqual(project.duration, 7, accuracy: 1e-9)
    }

    func testIntroAndOutroExtendTheTimeline() {
        var project = VideoProject(clips: [video(5)])
        project.intro = BookendEffect(presetID: "curtain", duration: 1.5)
        project.outro = BookendEffect(presetID: "seal", duration: 2)
        XCTAssertEqual(project.clipStartTimes, [1.5])
        XCTAssertEqual(project.duration, 8.5, accuracy: 1e-9)
    }

    func testSplitMakesTwoClipsThatPlayTheSameMedia() throws {
        var project = VideoProject(clips: [video(10)])
        XCTAssertTrue(project.split(at: 4))
        XCTAssertEqual(project.clips.count, 2)
        XCTAssertEqual(project.clips[0].trimEnd, 4, accuracy: 1e-9)
        XCTAssertEqual(project.clips[1].trimStart, 4, accuracy: 1e-9)
        XCTAssertEqual(project.duration, 10, accuracy: 1e-9)
        XCTAssertNotEqual(project.clips[0].id, project.clips[1].id)
    }

    func testSplitRespectsSpeedAndReverse() {
        var clip = video(10)
        clip.setSpeed(2)
        clip.isReversed = true
        var project = VideoProject(clips: [clip])
        XCTAssertTrue(project.split(at: 1))   // 1 s on the timeline = 2 s of source, from the end
        XCTAssertEqual(project.clips[0].trimStart, 8, accuracy: 1e-9)
        XCTAssertEqual(project.clips[1].trimEnd, 8, accuracy: 1e-9)
    }

    func testSplitTooCloseToAnEdgeIsRefused() {
        var project = VideoProject(clips: [video(10)])
        XCTAssertFalse(project.split(at: 0.05))
        XCTAssertFalse(project.split(at: 9.95))
        XCTAssertEqual(project.clips.count, 1)
    }

    func testTrimAndSpeedAreClamped() {
        var clip = video(5)
        clip.trim(start: 4.95, end: 2)
        XCTAssertGreaterThanOrEqual(clip.trimEnd - clip.trimStart, Clip.minimumDuration - 1e-9)
        XCTAssertLessThanOrEqual(clip.trimEnd, 5)
        clip.setSpeed(100)
        XCTAssertEqual(clip.speed, 4)
    }

    func testClipLookup() {
        let project = VideoProject(clips: [video(3), video(2)])
        XCTAssertEqual(project.clip(at: 1)?.index, 0)
        XCTAssertEqual(project.clip(at: 3.5)?.index, 1)
        XCTAssertEqual(project.clip(at: 3.5)?.local ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertNil(project.clip(at: 6))
    }

    func testReorder() {
        let a = video(1), b = video(2), c = video(3)
        var project = VideoProject(clips: [a, b, c])
        project.moveClip(from: 2, to: 0)
        XCTAssertEqual(project.clips.map(\.id), [c.id, a.id, b.id])
    }

    func testRoundTripThroughJSON() throws {
        var project = VideoProject(clips: [video(4), .photo(asset)])
        project.clips[1].transitionIn = .zoom(duration: 0.8)
        project.layers = [TimedLayer(overlay: Overlay(content: .text(TextOverlay(text: "Hi"))), start: 1, end: 3, animationIn: .rise)]
        project.music = MusicSelection(source: .library(trackID: "t1"), title: "Velvet", beats: BeatGrid(bpm: 96))
        project.effects = [AnimatedEffect(kind: .lightLeak)]
        let decoded = try VideoProject.decode(from: project.encoded())
        XCTAssertEqual(decoded, project)
    }

    func testLegacyGeneratedTransitionReadsAsDissolve() throws {
        let json = Data(#"{"type":"ai","duration":0.8,"jobID":"job-1"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(Transition.self, from: json), .dissolve(duration: 0.8))
    }

    func testLayerPresenceFadesInAndOut() {
        let layer = TimedLayer(overlay: Overlay(content: .text(TextOverlay(text: "x"))), start: 1, end: 3, animationDuration: 0.5)
        XCTAssertEqual(layer.presence(at: 0.5), 0)
        XCTAssertEqual(layer.presence(at: 1.25), 0.5, accuracy: 1e-9)
        XCTAssertEqual(layer.presence(at: 2), 1)
        XCTAssertEqual(layer.presence(at: 2.75), 0.5, accuracy: 1e-9)
    }

    func testMusicFades() {
        let music = MusicSelection(source: .imported(fileName: "a.m4a"), title: "A", volume: 1, fadeIn: 1, fadeOut: 2)
        XCTAssertEqual(music.gain(at: 0.5, total: 10), 0.5, accuracy: 1e-9)
        XCTAssertEqual(music.gain(at: 5, total: 10), 1)
        XCTAssertEqual(music.gain(at: 9, total: 10), 0.5, accuracy: 1e-9)
    }

    func testUndoableCoalescesTransactions() {
        var history = Undoable(VideoProject(clips: [video(4)]))
        var p = history.current
        for v in [1.5, 2.0, 3.0] {
            p.clips[0].setSpeed(v)
            history.update(p)
        }
        history.commit(p)
        XCTAssertEqual(history.current.clips[0].speed, 3)
        history.undo()
        XCTAssertEqual(history.current.clips[0].speed, 1)
        XCTAssertFalse(history.canUndo)
        history.redo()
        XCTAssertEqual(history.current.clips[0].speed, 3)
    }
}

final class TemplateTests: XCTestCase {
    let photo = TemplateMedia(source: SourceAsset(localIdentifier: "p", pixelSize: PixelSize(width: 100, height: 100)), kind: .photo)

    func testBeatGrid() {
        let grid = BeatGrid(bpm: 120, offset: 0.25)
        XCTAssertEqual(grid.beatLength, 0.5)
        XCTAssertEqual(grid.beats(from: 0, to: 2), [0.25, 0.75, 1.25, 1.75])
        XCTAssertEqual(grid.quantize(1.1), 1.25, accuracy: 1e-9)
    }

    func testCutsLandOnTheBeat() throws {
        let template = TemplateDefinition(id: "t", name: "T", tagline: "", tier: .free, slots: [
            TemplateSlot(beats: 2), TemplateSlot(beats: 4, transition: .dissolve(duration: 0.25)), TemplateSlot(beats: 2)
        ], bpm: 120)
        let project = try TemplateBuilder.build(template, media: [photo, photo, photo])
        // Each slot ends on a beat: 1 s, 3 s, 4 s.
        let starts = project.clipStartTimes
        XCTAssertEqual(starts[1] + project.clips[1].transitionIn.duration, 1, accuracy: 1e-9)
        XCTAssertEqual(starts[2], 3, accuracy: 1e-9)
        XCTAssertEqual(project.duration, 4, accuracy: 1e-9)
    }

    func testMediaCyclesWhenThereAreFewerItemsThanSlots() throws {
        let a = photo
        let b = TemplateMedia(source: SourceAsset(localIdentifier: "b", pixelSize: PixelSize(width: 1, height: 1)), kind: .photo)
        let template = TemplateDefinition(id: "t", name: "T", tagline: "", tier: .free, slots: Array(repeating: TemplateSlot(beats: 1), count: 5))
        let project = try TemplateBuilder.build(template, media: [a, b])
        XCTAssertEqual(project.clips.map(\.source.localIdentifier), ["p", "b", "p", "b", "p"])
    }

    func testShortVideoIsSlowedToFillItsSlot() throws {
        let short = TemplateMedia(source: SourceAsset(localIdentifier: "v", pixelSize: PixelSize(width: 1, height: 1)), kind: .video, duration: 1)
        let template = TemplateDefinition(id: "t", name: "T", tagline: "", tier: .free, slots: [TemplateSlot(beats: 4)], bpm: 120)
        let project = try TemplateBuilder.build(template, media: [short])
        XCTAssertEqual(project.clips[0].speed, 0.5, accuracy: 1e-9)
        XCTAssertEqual(project.duration, 2, accuracy: 1e-9)
    }

    func testLongVideoUsesItsMiddle() throws {
        let long = TemplateMedia(source: SourceAsset(localIdentifier: "v", pixelSize: PixelSize(width: 1, height: 1)), kind: .video, duration: 10)
        let template = TemplateDefinition(id: "t", name: "T", tagline: "", tier: .free, slots: [TemplateSlot(beats: 4)], bpm: 120)
        let clip = try TemplateBuilder.build(template, media: [long]).clips[0]
        XCTAssertEqual(clip.trimStart, 4, accuracy: 1e-9)
        XCTAssertEqual(clip.trimEnd, 6, accuracy: 1e-9)
    }

    func testNoMediaIsAnError() {
        let template = TemplateDefinition(id: "t", name: "T", tagline: "", tier: .free, slots: [TemplateSlot(beats: 1)])
        XCTAssertThrowsError(try TemplateBuilder.build(template, media: []))
    }

    func testShippedTemplatesAreValid() throws {
        let url = TestSupport.repoRoot.appendingPathComponent("Content/templates.json")
        let templates = try JSONDecoder().decode([TemplateDefinition].self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(templates.count, 12)
        XCTAssertEqual(Set(templates.map(\.id)).count, templates.count)
        let catalog = try TestSupport.shippedCatalog()
        for t in templates {
            XCTAssertFalse(t.slots.isEmpty, t.id)
            if let look = t.lookID { XCTAssertNotNil(catalog.look(id: look), "\(t.id) uses unknown look \(look)") }
        }
    }
}

final class AnimatedEffectTests: XCTestCase {
    func testSamplesAreDeterministic() {
        for kind in AnimatedEffect.Kind.allCases {
            let e = AnimatedEffect(kind: kind, seed: 42)
            XCTAssertEqual(e.sample(at: 1.234), e.sample(at: 1.234), kind.rawValue)
        }
    }

    func testInactiveEffectIsNeutral() {
        let e = AnimatedEffect(kind: .shake, start: 2, end: 4)
        XCTAssertEqual(e.sample(at: 1), AnimatedEffect.Sample())
        XCTAssertEqual(e.sample(at: 5), AnimatedEffect.Sample())
        XCTAssertNotEqual(e.sample(at: 3), AnimatedEffect.Sample())
    }

    func testValuesStayInSensibleRanges() {
        for kind in AnimatedEffect.Kind.allCases {
            let e = AnimatedEffect(kind: kind, intensity: 1, rate: 2, seed: 7)
            for i in 0..<500 {
                let s = e.sample(at: Double(i) / 30)
                XCTAssert((0.7...1.3).contains(s.exposure), "\(kind) exposure \(s.exposure)")
                XCTAssert((0...1).contains(s.leak) && (0...1).contains(s.glitter) && (0...1).contains(s.tracking), "\(kind)")
                XCTAssert(abs(s.offsetX) <= 0.02 && abs(s.offsetY) <= 0.02, "\(kind)")
                XCTAssert((1...1.1).contains(s.zoom), "\(kind) zoom \(s.zoom)")
            }
        }
    }

    func testNoiseIsBounded() {
        for i in 0..<1000 {
            let n = AnimatedEffect.noise(Double(i) * 0.37, seed: 3)
            XCTAssert((-1...1).contains(n))
        }
    }
}

final class RetouchTests: XCTestCase {
    func testRetouchSitsAtTheBottomOfTheStack() {
        var doc = TestSupport.document()
        doc.applyLook("film-analog.linen")
        var r = RetouchSettings()
        r.global.smoothing = 0.4
        doc.retouch = r
        guard case .retouch = doc.operations.first?.kind else { return XCTFail("retouch should be first") }
        XCTAssertEqual(doc.retouch.global.smoothing, 0.4)
        XCTAssertFalse(doc.isPristine)
    }

    func testNeutralRetouchAddsNothing() {
        var doc = TestSupport.document()
        doc.retouch = RetouchSettings()
        XCTAssertTrue(doc.operations.isEmpty)
    }

    func testReshapeIsClampedToItsRange() {
        var face = FaceRetouch()
        face[.jaw] = -3
        face[.smoothing] = 2
        XCTAssertEqual(face.jaw, -1)
        XCTAssertEqual(face.smoothing, 1)
    }

    func testPerFaceOverrides() {
        var settings = RetouchSettings(global: .natural)
        var custom = FaceRetouch()
        custom.eyes = 0.3
        settings.perFace[1] = custom
        XCTAssertEqual(settings.settings(forFace: 0), .natural)
        XCTAssertEqual(settings.settings(forFace: 1).eyes, 0.3)
    }

    func testRetouchIsAMemberFeatureAndCanBeStripped() throws {
        let catalog = try TestSupport.shippedCatalog()
        var doc = TestSupport.document()
        doc.retouch = RetouchSettings(global: .natural)
        XCTAssertEqual(ExportGate.decision(for: doc, entitlement: .free, catalog: catalog), .requiresMembership([.retouch]))
        XCTAssertTrue(ExportGate.strippingPremium(from: doc, catalog: catalog).operations.isEmpty)
    }

    func testRetouchRoundTrip() throws {
        var doc = TestSupport.document()
        var settings = RetouchSettings(global: .natural)
        settings.perFace[2] = FaceRetouch()
        doc.retouch = settings
        XCTAssertEqual(try EditDocument.decode(from: doc.encoded()).retouch, settings)
    }

    func testFacesSortInReadingOrder() {
        let right = FaceGeometry(bounds: NormalizedRect(x: 0.6, y: 0.1, width: 0.2, height: 0.2))
        let left = FaceGeometry(bounds: NormalizedRect(x: 0.1, y: 0.12, width: 0.2, height: 0.2))
        let below = FaceGeometry(bounds: NormalizedRect(x: 0.05, y: 0.6, width: 0.2, height: 0.2))
        XCTAssertEqual(FaceGeometry.readingOrder([below, right, left]), [left, right, below])
    }
}

final class VideoExportGateTests: XCTestCase {
    func testFreeVideoIsWatermarkedAt1080AndMembersGet4K() throws {
        let catalog = try TestSupport.shippedCatalog()
        var project = VideoProject()
        project.effects = [AnimatedEffect(kind: .glitter, tier: .member)]
        let free = ExportGate.videoDecision(for: project, entitlement: .free, catalog: catalog)
        XCTAssertTrue(free.watermark)
        XCTAssertEqual(free.maxPixelSize, 1920)
        XCTAssertEqual(free.premiumItems, [.effect(kind: "glitter")])
        let member = ExportGate.videoDecision(for: project, entitlement: .member, catalog: catalog)
        XCTAssertFalse(member.requiresMembership)
        XCTAssertEqual(member.maxPixelSize, 3840)
        XCTAssertEqual(member.maxFrameRate, 60)
    }
}

final class BeatDetectorTests: XCTestCase {
    /// A click track: short decaying noise bursts on every beat.
    func clicks(bpm: Double, offset: Double, seconds: Double, sampleRate: Double = 8000) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(seconds * sampleRate))
        var rng: UInt64 = 12345
        var t = offset
        while t < seconds {
            let start = Int(t * sampleRate)
            for i in 0..<Int(0.03 * sampleRate) where start + i < samples.count {
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                let noise = Float(Int64(bitPattern: rng >> 11) % 2000) / 1000 - 1
                samples[start + i] = noise * Float(exp(-Double(i) / (0.008 * sampleRate)))
            }
            t += 60 / bpm
        }
        return samples
    }

    func testFindsTempoAndPhaseOfAClickTrack() throws {
        for (bpm, offset) in [(120.0, 0.2), (96.0, 0.05), (140.0, 0.3)] {
            let grid = try XCTUnwrap(BeatDetector.detect(samples: clicks(bpm: bpm, offset: offset, seconds: 12), sampleRate: 8000))
            XCTAssertEqual(grid.bpm, bpm, accuracy: bpm * 0.02, "bpm \(bpm)")
            // The detected offset must land on a beat (within 20 ms).
            let phaseError = abs(grid.quantize(offset) - offset)
            XCTAssertLessThan(phaseError, 0.02, "bpm \(bpm)")
            let beatError = (grid.offset - offset).truncatingRemainder(dividingBy: 60 / bpm)
            XCTAssertLessThan(min(abs(beatError), 60 / bpm - abs(beatError)), 0.02, "bpm \(bpm)")
        }
    }

    func testSilenceAndShortAudioGiveNoGrid() {
        XCTAssertNil(BeatDetector.detect(samples: [Float](repeating: 0, count: 80000), sampleRate: 8000))
        XCTAssertNil(BeatDetector.detect(samples: [0.1, 0.2], sampleRate: 8000))
    }
}
