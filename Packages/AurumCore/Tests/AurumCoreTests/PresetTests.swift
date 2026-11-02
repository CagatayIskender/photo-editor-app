import XCTest
@testable import AurumCore

final class PresetTests: XCTestCase {
    private func samplePreset() -> Preset {
        var doc = TestSupport.document()
        doc.applyLook("film.a", intensity: 0.7)
        doc.stackLook("noir.a", intensity: 0.3)
        var a = AdjustmentSet()
        a.exposure = 0.1
        doc.adjustments = a
        return Preset(name: "Gallery night", from: doc)
    }

    func testLinkRoundTrip() throws {
        let preset = samplePreset()
        let codec = PresetLinkCodec()
        let url = try codec.link(for: preset)
        XCTAssertEqual(url.scheme, "aurum")
        XCTAssertEqual(url.host, "preset")
        XCTAssertFalse(url.absoluteString.contains("="), "base64url has no padding")
        let decoded = try codec.preset(from: url)
        XCTAssertEqual(decoded.name, "Gallery night")
        XCTAssertEqual(decoded.operations, preset.operations)
    }

    func testCustomSchemeFromBrandConfig() throws {
        let codec = PresetLinkCodec(scheme: "maison")
        let url = try codec.link(for: samplePreset())
        XCTAssertEqual(url.scheme, "maison")
        XCTAssertThrowsError(try PresetLinkCodec().preset(from: url)) { error in
            XCTAssertEqual(error as? PresetLinkCodec.LinkError, .wrongScheme)
        }
    }

    func testRejectsGarbage() {
        let codec = PresetLinkCodec()
        XCTAssertThrowsError(try codec.preset(from: URL(string: "aurum://preset/!!!")!))
        XCTAssertThrowsError(try codec.preset(from: URL(string: "aurum://preset/aGVsbG8")!)) { error in
            XCTAssertEqual(error as? PresetLinkCodec.LinkError, .invalidPayload)
        }
        XCTAssertThrowsError(try codec.preset(from: URL(string: "aurum://draft/abc")!)) { error in
            XCTAssertEqual(error as? PresetLinkCodec.LinkError, .notAPresetLink)
        }
    }

    func testApplyReplacesOperationsWithFreshIDs() {
        let preset = samplePreset()
        var target = TestSupport.document()
        target.applyLook("film.b")
        let once = preset.apply(to: target)
        let twice = preset.apply(to: target)
        XCTAssertEqual(once.lookApplications.map(\.lookID), ["film.a", "noir.a"])
        XCTAssertEqual(once.adjustments.exposure, 0.1)
        XCTAssertNotEqual(once.operations.map(\.id), twice.operations.map(\.id))
        XCTAssertEqual(once.source, target.source)
    }

    func testDisabledOperationsAreNotSaved() {
        var doc = TestSupport.document()
        doc.applyLook("film.a")
        doc.stackLook("film.b")
        doc.toggleOperation(id: doc.operations[1].id)
        XCTAssertEqual(Preset(name: "x", from: doc).operations.count, 1)
    }
}
