import XCTest
import CoreImage
@testable import AurumRender
import AurumCore

final class FilterGraphTests: XCTestCase {
    let context = CIContext(options: [.workingColorSpace: NSNull()])

    let catalog = LookCatalog(
        collections: [LookCollection(id: "c", name: "C", tagline: "")],
        looks: [
            LookRecipe(id: "c.warm", name: "Warm", collection: "c", tier: .free, params: {
                var p = LookParameters()
                p.warmth = 0.6
                p.grain = 0.3
                return p
            }()),
            LookRecipe(id: "c.mono", name: "Mono", collection: "c", tier: .free, params: {
                var p = LookParameters()
                p.monochrome = true
                p.saturation = -1
                return p
            }())
        ]
    )

    /// A 64×48 gradient test card.
    func testCard() -> CIImage {
        let f = CIFilter(name: "CILinearGradient")!
        f.setValue(CIVector(x: 0, y: 0), forKey: "inputPoint0")
        f.setValue(CIVector(x: 64, y: 48), forKey: "inputPoint1")
        f.setValue(CIColor(red: 0.9, green: 0.3, blue: 0.2), forKey: "inputColor0")
        f.setValue(CIColor(red: 0.2, green: 0.4, blue: 0.9), forKey: "inputColor1")
        return f.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
    }

    func pixels(_ image: CIImage) -> [UInt8] {
        let w = Int(image.extent.width), h = Int(image.extent.height)
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        context.render(image, toBitmap: &buffer, rowBytes: w * 4, bounds: image.extent, format: .RGBA8, colorSpace: nil)
        return buffer
    }

    func document() -> EditDocument {
        EditDocument(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!, source: SourceAsset(localIdentifier: "x", pixelSize: PixelSize(width: 64, height: 48)))
    }

    func testPristineDocumentIsTheIdentity() {
        let graph = FilterGraph(catalog: catalog)
        let card = testCard()
        XCTAssertEqual(pixels(graph.apply(document(), to: card)), pixels(card))
    }

    func testZeroIntensityLookIsTheIdentity() {
        var doc = document()
        doc.applyLook("c.warm", intensity: 0)
        let card = testCard()
        XCTAssertEqual(pixels(FilterGraph(catalog: catalog).apply(doc, to: card)), pixels(card))
    }

    func testLookChangesPixelsAndKeepsSize() {
        var doc = document()
        doc.applyLook("c.warm", intensity: 1)
        let card = testCard()
        let out = FilterGraph(catalog: catalog).apply(doc, to: card)
        XCTAssertEqual(out.extent, card.extent)
        XCTAssertNotEqual(pixels(out), pixels(card))
    }

    func testRenderingIsDeterministic() {
        var doc = document()
        doc.applyLook("c.warm", intensity: 1)
        let graph = FilterGraph(catalog: catalog)
        XCTAssertEqual(pixels(graph.apply(doc, to: testCard())), pixels(graph.apply(doc, to: testCard())))
    }

    func testMonochromeLookRemovesColour() {
        var doc = document()
        doc.applyLook("c.mono", intensity: 1)
        let px = pixels(FilterGraph(catalog: catalog).apply(doc, to: testCard()))
        for i in stride(from: 0, to: px.count, by: 4 * 97) {
            XCTAssertLessThanOrEqual(abs(Int(px[i]) - Int(px[i + 2])), 2)
        }
    }

    func testCropProducesTheRequestedSize() {
        var doc = document()
        doc.crop = CropSpec.centred(aspect: .square, source: doc.source.pixelSize)
        let out = FilterGraph(catalog: catalog).apply(doc, to: testCard())
        XCTAssertEqual(out.extent.size, CGSize(width: 48, height: 48))
        XCTAssertEqual(out.extent.origin, .zero)
    }

    func testQuarterTurnSwapsDimensions() {
        var doc = document()
        doc.crop = CropSpec(quarterTurns: 1)
        let out = FilterGraph(catalog: catalog).apply(doc, to: testCard())
        XCTAssertEqual(out.extent.size, CGSize(width: 48, height: 64))
    }

    func testStraightenScaleCoversTheFrame() {
        XCTAssertEqual(FilterGraph.straightenScale(width: 100, height: 100, radians: 0), 1)
        XCTAssertGreaterThan(FilterGraph.straightenScale(width: 400, height: 300, radians: 0.1), 1)
    }

    func testUnknownLookIsIgnored() {
        var doc = document()
        doc.applyLook("missing.look", intensity: 1)
        let card = testCard()
        XCTAssertEqual(pixels(FilterGraph(catalog: catalog).apply(doc, to: card)), pixels(card))
    }

    func testOverlayRasterizerDrawsTheWatermark() throws {
        let image = try XCTUnwrap(OverlayRasterizer.render([], canvasSize: CGSize(width: 1080, height: 1350), watermark: "AURUM"))
        XCTAssertEqual(image.extent.size, CGSize(width: 1080, height: 1350))
        XCTAssertNil(OverlayRasterizer.render([], canvasSize: CGSize(width: 10, height: 10), watermark: nil))
    }
}
