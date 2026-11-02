import XCTest
@testable import AurumCore

final class ExportGateTests: XCTestCase {
    let catalog = TestSupport.smallCatalog

    func testFreeEditExportsWithWatermarkAtLimitedSize() {
        var doc = TestSupport.document()
        doc.applyLook("film.a")
        XCTAssertEqual(
            ExportGate.decision(for: doc, entitlement: .free, catalog: catalog),
            .allowed(watermark: true, maxPixelSize: 2048)
        )
    }

    func testPremiumLookNeedsMembershipOnFreeTier() {
        var doc = TestSupport.document()
        doc.applyLook("film.b")
        XCTAssertEqual(
            ExportGate.decision(for: doc, entitlement: .free, catalog: catalog),
            .requiresMembership([.look(id: "film.b", name: "Bravo")])
        )
    }

    func testMembersExportEverythingCleanAtFullSize() {
        var doc = TestSupport.document()
        doc.applyLook("film.b")
        doc.addOverlay(Overlay(content: .sticker(StickerOverlay(stickerID: "pearls", tier: .member))))
        XCTAssertEqual(
            ExportGate.decision(for: doc, entitlement: .member, catalog: catalog),
            .allowed(watermark: false, maxPixelSize: nil)
        )
    }

    func testDisabledOrZeroIntensityPremiumLooksDoNotCount() {
        var doc = TestSupport.document()
        doc.applyLook("film.b")
        doc.setActiveLookIntensity(0)
        XCTAssertTrue(ExportGate.premiumItems(in: doc, catalog: catalog).isEmpty)
        doc.setActiveLookIntensity(0.5)
        doc.toggleOperation(id: doc.operations[0].id)
        XCTAssertTrue(ExportGate.premiumItems(in: doc, catalog: catalog).isEmpty)
    }

    func testPremiumStickersAndHiddenOverlays() {
        var doc = TestSupport.document()
        var sticker = Overlay(content: .sticker(StickerOverlay(stickerID: "pearls", tier: .member)))
        doc.addOverlay(sticker)
        XCTAssertEqual(ExportGate.premiumItems(in: doc, catalog: catalog), [.sticker(id: "pearls")])
        sticker.isHidden = true
        doc.updateOverlay(sticker)
        XCTAssertTrue(ExportGate.premiumItems(in: doc, catalog: catalog).isEmpty)
    }

    func testDuplicatesAreListedOnce() {
        var doc = TestSupport.document()
        doc.applyLook("film.b")
        doc.stackLook("film.b")
        XCTAssertEqual(ExportGate.premiumItems(in: doc, catalog: catalog).count, 1)
    }

    func testStrippingPremiumLeavesAFreeEdit() {
        var doc = TestSupport.document()
        doc.applyLook("film.a")
        doc.stackLook("film.b")
        doc.addOverlay(Overlay(content: .sticker(StickerOverlay(stickerID: "pearls", tier: .member))))
        doc.addOverlay(Overlay(content: .text(TextOverlay(text: "Hi"))))
        let stripped = ExportGate.strippingPremium(from: doc, catalog: catalog)
        XCTAssertEqual(stripped.lookApplications.map(\.lookID), ["film.a"])
        XCTAssertEqual(stripped.overlays.count, 1)
        XCTAssertEqual(
            ExportGate.decision(for: stripped, entitlement: .free, catalog: catalog),
            .allowed(watermark: true, maxPixelSize: 2048)
        )
    }
}
