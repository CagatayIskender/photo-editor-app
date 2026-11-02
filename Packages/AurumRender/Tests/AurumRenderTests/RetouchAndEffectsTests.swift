import XCTest
import CoreImage
import CoreImage.CIFilterBuiltins
@testable import AurumRender
import AurumCore

final class RetouchAndEffectsTests: XCTestCase {
    let context = CIContext(options: [.workingColorSpace: NSNull()])
    let size = CGRect(x: 0, y: 0, width: 64, height: 48)

    /// A 64×48 gradient test card.
    func testCard() -> CIImage {
        let f = CIFilter(name: "CILinearGradient")!
        f.setValue(CIVector(x: 0, y: 0), forKey: "inputPoint0")
        f.setValue(CIVector(x: 64, y: 48), forKey: "inputPoint1")
        f.setValue(CIColor(red: 0.9, green: 0.3, blue: 0.2), forKey: "inputColor0")
        f.setValue(CIColor(red: 0.2, green: 0.4, blue: 0.9), forKey: "inputColor1")
        return f.outputImage!.cropped(to: size)
    }

    /// The gradient with a fine checkerboard over it, so blurring has
    /// texture to remove (a blur leaves a linear gradient unchanged).
    func texturedCard() -> CIImage {
        let checker = CIFilter.checkerboardGenerator()
        checker.center = .zero
        checker.width = 2
        checker.sharpness = 1
        checker.color0 = CIColor(red: 0.25, green: 0.25, blue: 0.25, alpha: 1)
        checker.color1 = CIColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1)
        let blend = CIFilter.overlayBlendMode()
        blend.inputImage = checker.outputImage!.cropped(to: size)
        blend.backgroundImage = testCard()
        return blend.outputImage!.cropped(to: size)
    }

    func pixels(_ image: CIImage) -> [UInt8] {
        let w = Int(size.width), h = Int(size.height)
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        context.render(image, toBitmap: &buffer, rowBytes: w * 4, bounds: size, format: .RGBA8, colorSpace: nil)
        return buffer
    }

    /// One face in the middle of the frame, with no landmarks.
    let face = FaceGeometry(bounds: NormalizedRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6))

    func smoothing(_ amount: Double) -> RetouchSettings {
        var r = FaceRetouch()
        r.smoothing = amount
        return RetouchSettings(global: r)
    }

    // MARK: Retouch

    func testNeutralRetouchReturnsTheInput() {
        let card = texturedCard()
        let out = RetouchRenderer.apply(RetouchSettings(), faces: [face], to: card)
        XCTAssertTrue(out === card)
        XCTAssertEqual(pixels(out), pixels(card))
    }

    func testRetouchWithoutFacesReturnsTheInput() {
        let card = texturedCard()
        let out = RetouchRenderer.apply(smoothing(1), faces: [], to: card)
        XCTAssertTrue(out === card)
        XCTAssertEqual(pixels(out), pixels(card))
    }

    func testSmoothingChangesTheFaceAndNotTheCorner() {
        let card = texturedCard()
        let out = RetouchRenderer.apply(smoothing(1), faces: [face], to: card)
        XCTAssertEqual(out.extent, card.extent)
        let before = pixels(card), after = pixels(out)

        // The centre 8×8 block lies well inside the face oval.
        var changed = 0
        for y in 20..<28 {
            for x in 28..<36 {
                let i = (y * 64 + x) * 4
                for c in 0..<3 where abs(Int(before[i + c]) - Int(after[i + c])) > 2 { changed += 1 }
            }
        }
        XCTAssertGreaterThan(changed, 0)

        // Corners are outside the mask.
        for (x, y) in [(0, 0), (63, 0), (0, 47), (63, 47)] {
            let i = (y * 64 + x) * 4
            for c in 0..<4 {
                XCTAssertLessThanOrEqual(abs(Int(before[i + c]) - Int(after[i + c])), 1)
            }
        }
    }

    func testFilterGraphAppliesRetouchOnlyWithFaces() {
        let catalog = LookCatalog(collections: [], looks: [])
        var doc = EditDocument(id: UUID(), source: SourceAsset(localIdentifier: "x", pixelSize: PixelSize(width: 64, height: 48)))
        doc.retouch = smoothing(1)
        let card = texturedCard()
        var graph = FilterGraph(catalog: catalog)
        XCTAssertEqual(pixels(graph.apply(doc, to: card)), pixels(card))
        graph.faces = [face]
        XCTAssertNotEqual(pixels(graph.apply(doc, to: card)), pixels(card))
        XCTAssertTrue(RenderEngine.needsFaces(doc))
    }

    // MARK: Effects

    func allEffects() -> [AnimatedEffect] {
        AnimatedEffect.Kind.allCases.map { AnimatedEffect(kind: $0, intensity: 1, seed: 42) }
    }

    func testEveryEffectKeepsTheExtent() {
        let card = testCard()
        for effect in allEffects() {
            let out = EffectRenderer.apply([effect], at: 0.5, to: card)
            XCTAssertEqual(out.extent, card.extent, "\(effect.kind)")
        }
        XCTAssertEqual(EffectRenderer.apply(allEffects(), at: 0.5, to: card).extent, card.extent)
    }

    func testEffectsAreDeterministic() {
        for effect in allEffects() {
            let a = pixels(EffectRenderer.apply([effect], at: 0.5, to: testCard()))
            let b = pixels(EffectRenderer.apply([effect], at: 0.5, to: testCard()))
            XCTAssertEqual(a, b, "\(effect.kind)")
        }
    }

    func testInactiveEffectLeavesPixelsUnchanged() {
        let card = testCard()
        let later = AnimatedEffect(kind: .glitter, intensity: 1, start: 10)
        let ended = AnimatedEffect(kind: .lightLeak, intensity: 1, start: 0, end: 0.2)
        let out = EffectRenderer.apply([later, ended], at: 0.5, to: card)
        XCTAssertEqual(pixels(out), pixels(card))
    }

    func testCameraZoomCoversTheOffset() {
        let card = testCard()
        let out = EffectRenderer.camera(card, offsetX: 0.05, offsetY: -0.05, zoom: 1, extent: card.extent)
        XCTAssertEqual(out.extent, card.extent)
        // No transparent edge pixels.
        let px = pixels(out)
        for i in stride(from: 3, to: px.count, by: 4) { XCTAssertEqual(px[i], 255) }
    }
}
