import XCTest
@testable import AurumCore

// MARK: - Inpainting

final class InpaintingTests: XCTestCase {
    /// A width × height buffer whose colour comes from `colour(x, y)`.
    func image(width: Int, height: Int, colour: (Int, Int) -> (Float, Float, Float)) -> RGBAImageBuffer {
        var pixels: [Float] = []
        pixels.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = colour(x, y)
                pixels.append(c.0)
                pixels.append(c.1)
                pixels.append(c.2)
                pixels.append(1)
            }
        }
        return RGBAImageBuffer(width: width, height: height, pixels: pixels)
    }

    /// 1 inside the square [from, to) on both axes, 0 elsewhere.
    func squareMask(width: Int, height: Int, from: Int, to: Int) -> [Float] {
        var mask = [Float](repeating: 0, count: width * height)
        for y in from..<to {
            for x in from..<to { mask[y * width + x] = 1 }
        }
        return mask
    }

    func testFlatRegionFillsToTheSurroundingColour() {
        let source = RGBAImageBuffer(width: 32, height: 32, red: 0.2, green: 0.4, blue: 0.6)
        let mask = squareMask(width: 32, height: 32, from: 10, to: 20)
        for useTexture in [true, false] {
            let filled = Inpainter.fill(source, mask: mask, useTexture: useTexture)
            for i in 0..<(32 * 32) {
                XCTAssertEqual(filled.pixels[i * 4], 0.2, accuracy: 1e-4)
                XCTAssertEqual(filled.pixels[i * 4 + 1], 0.4, accuracy: 1e-4)
                XCTAssertEqual(filled.pixels[i * 4 + 2], 0.6, accuracy: 1e-4)
            }
        }
    }

    func testStripedBackgroundRestoresTheStripes() {
        let stripes = image(width: 64, height: 64) { x, _ in x % 4 < 2 ? (0.9, 0.9, 0.9) : (0.1, 0.1, 0.1) }
        let mask = squareMask(width: 64, height: 64, from: 24, to: 40)
        // Wipe the hole so nothing of the original can leak through.
        var damaged = stripes
        for i in 0..<(64 * 64) where mask[i] > 0 {
            for k in 0..<3 { damaged.pixels[i * 4 + k] = 0.5 }
        }
        let filled = Inpainter.fill(damaged, mask: mask)
        let smooth = Inpainter.fill(damaged, mask: mask, useTexture: false)

        func error(_ result: RGBAImageBuffer) -> Float {
            var total: Float = 0
            var count: Float = 0
            for i in 0..<(64 * 64) where mask[i] > 0 {
                total += abs(result.pixels[i * 4] - stripes.pixels[i * 4])
                count += 1
            }
            return total / count
        }
        XCTAssertLessThan(error(filled), 0.05, "the patch should continue the stripes")
        XCTAssertLessThan(error(filled), error(smooth), "texture should beat a smooth fill on stripes")
        XCTAssertNotNil(Inpainter.bestPatchOffset(damaged, known: mask.map { $0 >= 0.5 ? 0 : 1 }))
    }

    func testPixelsOutsideTheMaskAreUntouched() {
        let source = image(width: 48, height: 40) { x, y in
            (Float(x * 7 % 13) / 13, Float(y * 5 % 11) / 11, Float((x + y) % 9) / 9)
        }
        let mask = squareMask(width: 48, height: 40, from: 12, to: 26)
        for useTexture in [true, false] {
            let filled = Inpainter.fill(source, mask: mask, useTexture: useTexture)
            for i in 0..<(48 * 40) where mask[i] == 0 {
                for k in 0..<4 {
                    XCTAssertEqual(filled.pixels[i * 4 + k], source.pixels[i * 4 + k])
                }
            }
            XCTAssertTrue(filled.pixels.allSatisfy { $0 >= 0 && $0 <= 1 })
        }
    }

    func testEmptyOrFullMaskReturnsTheImage() {
        let source = RGBAImageBuffer(width: 8, height: 8, red: 0.3, green: 0.3, blue: 0.3)
        XCTAssertEqual(Inpainter.fill(source, mask: [Float](repeating: 0, count: 64)), source)
        XCTAssertEqual(Inpainter.fill(source, mask: [Float](repeating: 1, count: 64)), source)
        XCTAssertEqual(Inpainter.fill(source, mask: []), source)
    }

    func testPushPullKeepsKnownValuesAndInterpolatesBetweenThem() {
        // A 5 × 1 row: 0 on the left, 1 on the right, unknown between.
        let values: [Float] = [0, 0, 0, 0, 1]
        let weights: [Float] = [1, 0, 0, 0, 1]
        let filled = Inpainter.pushPull(values, weights: weights, width: 5, height: 1, channels: 1)
        XCTAssertEqual(filled[0], 0)
        XCTAssertEqual(filled[4], 1)
        for i in 1...3 {
            XCTAssertGreaterThan(filled[i], 0)
            XCTAssertLessThan(filled[i], 1)
        }
    }

    func testCandidateOffsetsAreUniqueAndLeaveTheHole() {
        let offsets = Inpainter.candidateOffsets(holeWidth: 10, holeHeight: 6)
        XCTAssertEqual(Set(offsets).count, offsets.count)
        XCTAssertFalse(offsets.contains(Inpainter.Offset(dx: 0, dy: 0)))
        for o in offsets {
            XCTAssertTrue(abs(o.dx) > 10 || abs(o.dy) > 6, "\(o) would overlap the hole")
        }
    }

    func testRGBA8RoundTrip() {
        let bytes: [UInt8] = [0, 128, 255, 255, 10, 20, 30, 40]
        let buffer = RGBAImageBuffer(rgba8: bytes, width: 2, height: 1)
        XCTAssertEqual(buffer.rgba8, bytes)
    }
}

// MARK: - Brush mask

final class BrushMaskTests: XCTestCase {
    func testEmptinessAndBounds() {
        let eraserOnly = BrushMask(strokes: [BrushMask.Stroke(points: [NormalizedPoint(x: 0.5, y: 0.5)], isEraser: true)])
        XCTAssertTrue(eraserOnly.isEmpty)
        let twoPointLasso = BrushMask(polygons: [[NormalizedPoint(x: 0.1, y: 0.1), NormalizedPoint(x: 0.2, y: 0.2)]])
        XCTAssertTrue(twoPointLasso.isEmpty)
        let lasso = BrushMask(polygons: [[NormalizedPoint(x: 0.1, y: 0.1), NormalizedPoint(x: 0.5, y: 0.1), NormalizedPoint(x: 0.3, y: 0.4)]])
        XCTAssertFalse(lasso.isEmpty)
        XCTAssertTrue(lasso.isInBounds)
        let outside = BrushMask(polygons: [[NormalizedPoint(x: 0.1, y: 0.1), NormalizedPoint(x: 1.5, y: 0.1), NormalizedPoint(x: 0.3, y: 0.4)]])
        XCTAssertFalse(outside.isInBounds)
    }

    func testCoverageRasterisesStrokesAndErasers() {
        let paint = BrushMask.Stroke(points: [NormalizedPoint(x: 0.25, y: 0.5), NormalizedPoint(x: 0.75, y: 0.5)], radius: 0.1)
        let erase = BrushMask.Stroke(points: [NormalizedPoint(x: 0.75, y: 0.5)], radius: 0.1, isEraser: true)
        let mask = BrushMask(strokes: [paint, erase])
        let grid = mask.coverage(width: 40, height: 20)
        XCTAssertEqual(grid.count, 800)
        XCTAssertEqual(grid[10 * 40 + 15], 1, "on the stroke")
        XCTAssertEqual(grid[0], 0, "far corner")
        XCTAssertEqual(grid[10 * 40 + 30], 0, "erased")
        let grown = BrushMask(strokes: [paint]).coverage(width: 40, height: 20, grow: 3)
        XCTAssertGreaterThan(grown.reduce(0, +), BrushMask(strokes: [paint]).coverage(width: 40, height: 20).reduce(0, +))
    }

    func testPaintedBoundsAndRegionCoverage() {
        let stroke = BrushMask.Stroke(points: [NormalizedPoint(x: 0.5, y: 0.5)], radius: 0.1)
        let mask = BrushMask(strokes: [stroke])
        // A 2:1 photo: the radius is 0.1 of the height, so 0.05 of the width.
        let box = mask.paintedBounds(aspect: 2)
        XCTAssertNotNil(box)
        XCTAssertEqual(box?.x ?? 0, 0.45, accuracy: 1e-9)
        XCTAssertEqual(box?.width ?? 0, 0.1, accuracy: 1e-9)
        XCTAssertEqual(box?.y ?? 0, 0.4, accuracy: 1e-9)
        XCTAssertEqual(box?.height ?? 0, 0.2, accuracy: 1e-9)
        XCTAssertNil(BrushMask().paintedBounds(aspect: 1))

        // The region's grid matches the same pixels of the whole grid.
        let whole = mask.coverage(width: 80, height: 40)
        let part = mask.coverage(width: 20, height: 10, imageWidth: 80, imageHeight: 40, originX: 30, originY: 15)
        for y in 0..<10 {
            for x in 0..<20 {
                XCTAssertEqual(part[y * 20 + x], whole[(y + 15) * 80 + x + 30])
            }
        }
    }

    func testCoverageFillsOutlines() {
        let square = BrushMask(polygons: [[
            NormalizedPoint(x: 0.25, y: 0.25), NormalizedPoint(x: 0.75, y: 0.25),
            NormalizedPoint(x: 0.75, y: 0.75), NormalizedPoint(x: 0.25, y: 0.75)
        ]])
        let grid = square.coverage(width: 20, height: 20)
        XCTAssertEqual(grid[10 * 20 + 10], 1)
        XCTAssertEqual(grid[2 * 20 + 2], 0)
        XCTAssertEqual(grid.reduce(0, +), 100)
    }
}

// MARK: - Suggestions

final class AutoSuggestionTests: XCTestCase {
    let face = FaceGeometry(bounds: NormalizedRect(x: 0.4, y: 0.2, width: 0.25, height: 0.3))

    func testNothingDetectedStillOffersEnhance() {
        let ranked = AutoSuggestions.rank(SceneAnalysis())
        XCTAssertEqual(ranked.map(\.kind), [.enhance])
    }

    func testTiltedLandscapeLeadsWithStraighten() {
        let analysis = SceneAnalysis(luminance: 0.5, horizonDegrees: 2.3, labels: [SceneLabel(identifier: "sky", confidence: 0.8)])
        let ranked = AutoSuggestions.rank(analysis)
        XCTAssertEqual(ranked.first?.kind, .straighten)
        XCTAssertEqual(ranked.first?.degrees, 2.3)
        XCTAssertEqual(ranked.first?.feature, .enhance)
    }

    func testTinyOrHugeTiltsAreNotOffered() {
        for tilt in [0.1, -0.2, 30] {
            let ranked = AutoSuggestions.rank(SceneAnalysis(horizonDegrees: tilt))
            XCTAssertFalse(ranked.contains { $0.kind == .straighten }, "\(tilt)")
        }
    }

    func testDarkPortraitRanksFacesAndBackground() {
        let analysis = SceneAnalysis(faces: [face], faceLuminance: 0.2, luminance: 0.45, personCoverage: 0.35, labels: [SceneLabel(identifier: "people", confidence: 0.9)])
        let ranked = AutoSuggestions.rank(analysis)
        let kinds = ranked.map(\.kind)
        XCTAssertEqual(kinds.first, .brightenFaces)
        XCTAssertTrue(kinds.contains(.blurBackground))
        XCTAssertTrue(kinds.contains(.smoothSkin))
        XCTAssertLessThanOrEqual(ranked.count, 4)
        XCTAssertEqual(ranked.first?.feature, .relight)
    }

    func testRedEyeComesFirstWhenFound() {
        let analysis = SceneAnalysis(faces: [face], faceLuminance: 0.2, luminance: 0.2, personCoverage: 0.3, horizonDegrees: 3, redEyeLikely: true)
        XCTAssertEqual(AutoSuggestions.rank(analysis).first?.kind, .fixRedEye)
        // Red eye without a face is not offered.
        let noFace = SceneAnalysis(redEyeLikely: true)
        XCTAssertFalse(AutoSuggestions.rank(noFace).contains { $0.kind == .fixRedEye })
    }

    func testColourCastAndDarknessAreSuggested() {
        let analysis = SceneAnalysis(luminance: 0.2, warmth: 0.3)
        let kinds = AutoSuggestions.rank(analysis).map(\.kind)
        XCTAssertEqual(kinds, [.enhance, .balanceColour])
    }

    func testRankingIsSortedAndLimited() {
        let analysis = SceneAnalysis(faces: [face], faceLuminance: 0.3, luminance: 0.2, warmth: -0.3, personCoverage: 0.3, horizonDegrees: 4, redEyeLikely: true)
        let all = AutoSuggestions.rank(analysis, limit: 10)
        XCTAssertEqual(all.count, AutoSuggestion.Kind.allCases.count)
        XCTAssertEqual(all.map(\.score), all.map(\.score).sorted(by: >))
        XCTAssertEqual(AutoSuggestions.rank(analysis, limit: 2).count, 2)
        XCTAssertEqual(AutoSuggestions.rank(analysis, limit: 0).count, 1)
    }
}

// MARK: - Tools, straighten, looks and retouch

final class AutoStudioRulesTests: XCTestCase {
    func testOnlyRetouchIsAMembersTool() {
        XCTAssertEqual(AutoFeature.allCases.filter { $0.tier == .member }, [.retouch])
        XCTAssertEqual(AutoFeature.allCases.filter(\.requiresMask), [.removeObject])
    }

    func testStraightenCoverScale() {
        XCTAssertEqual(Straighten.coverScale(width: 400, height: 300, radians: 0), 1, accuracy: 1e-12)
        let angle = 3.0 * Double.pi / 180
        let k = Straighten.coverScale(width: 400, height: 300, radians: angle)
        XCTAssertGreaterThan(k, 1)
        // The frame's corners, rotated back, must land inside the scaled photo.
        for (cx, cy) in [(200.0, 150.0), (-200.0, 150.0), (200.0, -150.0), (-200.0, -150.0)] {
            let x = cx * cos(angle) + cy * sin(angle)
            let y = -cx * sin(angle) + cy * cos(angle)
            XCTAssertLessThanOrEqual(abs(x), 200 * k + 1e-9)
            XCTAssertLessThanOrEqual(abs(y), 150 * k + 1e-9)
        }
        XCTAssertEqual(Straighten.coverScale(width: 400, height: 300, radians: -angle), k, accuracy: 1e-12)
        XCTAssertTrue(Straighten.isWorthCorrecting(degrees: -2.3))
        XCTAssertFalse(Straighten.isWorthCorrecting(degrees: 0.2))
    }

    func testPortraitLooksAreUniqueWithFreeAndMemberLooks() {
        let ids = PortraitLook.library.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(PortraitLook.library.contains { $0.tier == .free })
        XCTAssertTrue(PortraitLook.library.contains { $0.tier == .member })
        XCTAssertEqual(PortraitLook.look(id: "portrait.silver")?.params.monochrome, true)
        XCTAssertNil(PortraitLook.look(id: "missing"))
    }

    func testNaturalRetouchScales() {
        XCTAssertTrue(FaceRetouch.natural.scaled(by: 0).isNeutral)
        XCTAssertEqual(FaceRetouch.natural.scaled(by: 1), FaceRetouch.natural)
        XCTAssertEqual(FaceRetouch.natural.scaled(by: 0.5).smoothing, FaceRetouch.natural.smoothing / 2, accuracy: 1e-12)
        XCTAssertEqual(FaceRetouch.natural.scaled(by: 4), FaceRetouch.natural)
    }
}
