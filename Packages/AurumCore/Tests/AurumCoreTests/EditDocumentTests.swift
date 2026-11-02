import XCTest
@testable import AurumCore

final class EditDocumentTests: XCTestCase {
    func testNewDocumentIsPristine() {
        XCTAssertTrue(TestSupport.document().isPristine)
    }

    func testApplyLookReplacesTheActiveLook() {
        var doc = TestSupport.document()
        doc.applyLook("film.a")
        doc.applyLook("film.b")
        XCTAssertEqual(doc.lookApplications.map(\.lookID), ["film.b"])
        XCTAssertFalse(doc.isPristine)
    }

    func testStackLookAddsALayer() {
        var doc = TestSupport.document()
        doc.applyLook("film.a")
        doc.stackLook("noir.a")
        XCTAssertEqual(doc.lookApplications.map(\.lookID), ["film.a", "noir.a"])
    }

    func testLooksStayBelowAdjustments() {
        var doc = TestSupport.document()
        var adjust = AdjustmentSet()
        adjust.exposure = 0.3
        doc.adjustments = adjust
        doc.applyLook("film.a")
        doc.stackLook("film.b")
        guard case .adjust = doc.operations.last?.kind else {
            return XCTFail("adjustments should stay on top of the stack")
        }
        XCTAssertEqual(doc.lookApplications.map(\.lookID), ["film.a", "film.b"])
    }

    func testNeutralAdjustmentsDoNotAddAnOperation() {
        var doc = TestSupport.document()
        doc.adjustments = AdjustmentSet()
        XCTAssertTrue(doc.operations.isEmpty)
    }

    func testIntensityIsClamped() {
        var doc = TestSupport.document()
        doc.applyLook("film.a")
        doc.setActiveLookIntensity(1.7)
        XCTAssertEqual(doc.lookApplications.first?.intensity, 1)
        doc.setActiveLookIntensity(-2)
        XCTAssertEqual(doc.lookApplications.first?.intensity, 0)
        XCTAssertTrue(doc.isPristine, "a look at zero intensity changes nothing")
    }

    func testToggleAndMoveOperations() {
        var doc = TestSupport.document()
        doc.applyLook("film.a")
        doc.stackLook("noir.a")
        let first = doc.operations[0].id
        doc.toggleOperation(id: first)
        XCTAssertFalse(doc.operations[0].isEnabled)
        doc.moveOperation(from: 0, to: 2)
        XCTAssertEqual(doc.operations.last?.id, first)
    }

    func testAdjustmentSubscriptClampsToTheControlRange() {
        var a = AdjustmentSet()
        a[.grain] = -0.5
        XCTAssertEqual(a.grain, 0, "grain is 0...1")
        a[.exposure] = 4
        XCTAssertEqual(a.exposure, 1)
        a[.exposure] = .nan
        XCTAssertEqual(a.exposure, -1)
    }

    func testRoundTripThroughJSON() throws {
        var doc = TestSupport.document()
        doc.applyLook("film.b", intensity: 0.6)
        doc.setActiveLookRefine(RefineOverrides(grain: 0.5))
        var a = AdjustmentSet()
        a.warmth = 0.2
        a.hsl[.blue] = .init(hue: 0.1, saturation: -0.3, luminance: 0)
        doc.adjustments = a
        doc.crop = .centred(aspect: .square, source: doc.source.pixelSize)
        doc.addOverlay(Overlay(content: .text(TextOverlay(text: "Hello"))))
        doc.addOverlay(Overlay(content: .sticker(StickerOverlay(stickerID: "sparkle"))))

        let decoded = try EditDocument.decode(from: doc.encoded())
        XCTAssertEqual(decoded, doc)
    }

    func testDecodesTheVersionOneFixture() throws {
        let doc = try EditDocument.decode(from: TestSupport.fixture("document_v1"))
        XCTAssertEqual(doc.lookApplications.first?.lookID, "film-analog.linen")
        XCTAssertEqual(doc.lookApplications.first?.refine.grain, 0.4)
        XCTAssertEqual(doc.adjustments.exposure, 0.2)
        XCTAssertEqual(doc.adjustments.contrast, 0, "missing keys take their default")
        XCTAssertEqual(doc.crop.aspect, .portrait)
        XCTAssertEqual(doc.overlays.count, 1)
    }

    func testRefusesDocumentsFromTheFuture() throws {
        var object = try JSONSerialization.jsonObject(with: TestSupport.fixture("document_v1")) as! [String: Any]
        object["schemaVersion"] = 99
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try EditDocument.decode(from: data)) { error in
            XCTAssertEqual(error as? DocumentMigrator.MigrationError, .newerThanSupported(99))
        }
    }

    func testCentredCropMatchesTheAspect() {
        let source = PixelSize(width: 4000, height: 3000)
        let square = CropSpec.centred(aspect: .square, source: source)
        XCTAssertEqual(square.outputSize(for: source), PixelSize(width: 3000, height: 3000))
        let story = CropSpec.centred(aspect: .story, source: source)
        let size = story.outputSize(for: source)
        XCTAssertEqual(Double(size.width) / Double(size.height), 9.0 / 16.0, accuracy: 0.01)
        let wide = CropSpec.centred(aspect: .landscape, source: source)
        XCTAssertEqual(wide.rect.width, 1)
        XCTAssertEqual(wide.outputSize(for: source).width, 4000)
    }

    func testQuarterTurnsSwapOutputSize() {
        let crop = CropSpec(quarterTurns: 5)
        XCTAssertEqual(crop.quarterTurns, 1)
        XCTAssertEqual(crop.outputSize(for: PixelSize(width: 400, height: 300)), PixelSize(width: 300, height: 400))
    }

    func testFittingKeepsAspectRatio() {
        let size = PixelSize(width: 4032, height: 3024).fitting(maxPixelSize: 2048)
        XCTAssertEqual(size, PixelSize(width: 2048, height: 1536))
        XCTAssertEqual(PixelSize(width: 100, height: 50).fitting(maxPixelSize: 2048), PixelSize(width: 100, height: 50))
    }

    func testClampedRectStaysInside() {
        let r = NormalizedRect(x: 0.9, y: -0.2, width: 0.5, height: 0.01).clamped()
        XCTAssertEqual(r.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(r.y, 0)
        XCTAssertEqual(r.height, 0.05)
    }
}
