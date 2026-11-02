import XCTest
@testable import AurumCore

final class ColorCubeTests: XCTestCase {
    func testNeutralAdjustmentsNeedNoCube() {
        XCTAssertNil(ColorCube.make(for: AdjustmentSet()))
    }

    func testCubeHasTheExpectedSize() throws {
        var a = AdjustmentSet()
        a.curves.master = [CurvePoint(x: 0.5, y: 0.6)]
        let cube = try XCTUnwrap(ColorCube.make(for: a, dimension: 8))
        XCTAssertEqual(cube.count, 8 * 8 * 8 * 4)
        XCTAssertTrue(cube.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    func testCurveBrightensMidtonesButKeepsEnds() throws {
        var a = AdjustmentSet()
        a.curves.master = [CurvePoint(x: 0.5, y: 0.7)]
        let dim = 3
        let cube = try XCTUnwrap(ColorCube.make(for: a, dimension: dim))
        func entry(_ r: Int, _ g: Int, _ b: Int) -> [Float] {
            let i = ((b * dim + g) * dim + r) * 4
            return Array(cube[i..<i + 3])
        }
        XCTAssertEqual(entry(0, 0, 0), [0, 0, 0])
        XCTAssertEqual(entry(2, 2, 2), [1, 1, 1])
        XCTAssertEqual(entry(1, 1, 1)[0], 0.7, accuracy: 0.001)
    }

    func testHSLRoundTrip() {
        for (r, g, b) in [(0.8, 0.2, 0.1), (0.1, 0.6, 0.9), (0.5, 0.5, 0.5), (0.95, 0.9, 0.2)] {
            let (h, s, l) = ColorCube.hslFrom(r, g, b)
            let back = ColorCube.rgb(hue: h, saturation: s, lightness: l)
            XCTAssertEqual(back.0, r, accuracy: 1e-9)
            XCTAssertEqual(back.1, g, accuracy: 1e-9)
            XCTAssertEqual(back.2, b, accuracy: 1e-9)
        }
    }

    func testBlueSaturationOnlyTouchesBlues() {
        var hsl = HSLAdjustments()
        hsl[.blue] = .init(saturation: -1)
        let blue = ColorCube.applyHSL(0.1, 0.3, 0.9, hsl)
        let (_, sBlue, _) = ColorCube.hslFrom(blue.0, blue.1, blue.2)
        XCTAssertLessThan(sBlue, 0.1, "blue should be nearly grey")

        let red = ColorCube.applyHSL(0.9, 0.1, 0.1, hsl)
        XCTAssertEqual(red.0, 0.9, accuracy: 1e-9)
        XCTAssertEqual(red.1, 0.1, accuracy: 1e-9)
    }

    func testBandWeightsWrapAroundRed() {
        XCTAssertEqual(ColorCube.weight(hue: 350, centre: 0), 1 - 10.0 / 45, accuracy: 1e-9)
        XCTAssertEqual(ColorCube.weight(hue: 180, centre: 0), 0)
    }

    func testSplitToningWarmsHighlightsAndCoolsShadows() throws {
        var a = AdjustmentSet()
        a.splitToning.shadowHue = 220
        a.splitToning.shadowSaturation = 1
        a.splitToning.highlightHue = 35
        a.splitToning.highlightSaturation = 1
        let dim = 3
        let cube = try XCTUnwrap(ColorCube.make(for: a, dimension: dim))
        func entry(_ i: Int) -> [Float] { let k = ((i * dim + i) * dim + i) * 4; return Array(cube[k..<k + 3]) }
        let dark = entry(0), light = entry(2)
        XCTAssertGreaterThan(dark[2], dark[0], "shadows lean blue")
        XCTAssertGreaterThanOrEqual(light[0], light[2], "highlights lean warm")
    }
}
