import XCTest
import CoreImage
import CoreImage.CIFilterBuiltins
@testable import AurumRender
import AurumCore

final class OnDeviceImagingTests: XCTestCase {
    let context = CIContext(options: [.workingColorSpace: NSNull()])
    let size = CGRect(x: 0, y: 0, width: 64, height: 48)
    let flat = CIColor(red: 0.6, green: 0.5, blue: 0.4)

    /// The average colour inside `rect`, 0...1.
    func average(_ image: CIImage, in rect: CGRect) -> [Double] {
        let f = CIFilter.areaAverage()
        f.inputImage = image
        f.extent = rect
        var px = [UInt8](repeating: 0, count: 4)
        let out = f.outputImage!
        context.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: out.extent.minX, y: out.extent.minY, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return px.prefix(3).map { Double($0) / 255 }
    }

    func testObjectRemoveFillsADotFromItsSurroundings() throws {
        // A black dot in the upper half (Core Image is bottom-up), so a flipped
        // mask would miss it.
        let dotRect = CGRect(x: 28, y: 32, width: 8, height: 8)
        let photo = CIImage(color: CIColor.black).cropped(to: dotRect)
            .composited(over: CIImage(color: flat).cropped(to: size))
        // The dot's centre in normalised top-left coordinates: (0.5, 0.25).
        let mask = BrushMask(strokes: [BrushMask.Stroke(points: [NormalizedPoint(x: 0.5, y: 0.25)], radius: 0.15)])
        let result = try ObjectRemover.remove(mask, from: photo, context: context)
        XCTAssertEqual(result.extent, size)
        let inside = average(result, in: dotRect)
        XCTAssertEqual(inside[0], 0.6, accuracy: 0.06)
        XCTAssertEqual(inside[1], 0.5, accuracy: 0.06)
        XCTAssertEqual(inside[2], 0.4, accuracy: 0.06)
        let far = average(result, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        XCTAssertEqual(far[0], 0.6, accuracy: 0.02)
    }

    func testObjectRemoveRefusesAnEmptyMask() {
        let photo = CIImage(color: flat).cropped(to: size)
        XCTAssertThrowsError(try ObjectRemover.remove(BrushMask(), from: photo, context: context))
    }

    func testWorkingRegionStaysInsideThePhoto() {
        let region = ObjectRemover.workingRegion(painted: NormalizedRect(x: 0.9, y: 0, width: 0.1, height: 0.1), imageWidth: 1000, imageHeight: 500)
        XCTAssertGreaterThanOrEqual(region.x, 0)
        XCTAssertGreaterThanOrEqual(region.y, 0)
        XCTAssertLessThanOrEqual(region.x + region.width, 1000)
        XCTAssertLessThanOrEqual(region.y + region.height, 500)
        XCTAssertLessThanOrEqual(region.x, 900)
    }

    func testToolsKeepTheExtent() {
        let photo = CIImage(color: flat).cropped(to: size)
        XCTAssertEqual(OnDeviceImaging.straighten(photo, degrees: 3).extent, size)
        XCTAssertEqual(OnDeviceImaging.enhance(photo, context: context).extent, size)
        let look = PortraitLook.library[0]
        XCTAssertEqual(OnDeviceImaging.portraitLook(photo, look: look, faces: [], personMask: nil).extent, size)
        let matte = CIImage(color: CIColor.white).cropped(to: size)
        XCTAssertEqual(try OnDeviceImaging.portraitBlur(photo, amount: 0.5, mask: matte).extent, size)
    }

    func testWhiteBalancePullsACastTowardsNeutral() {
        let warm = CIImage(color: CIColor(red: 0.7, green: 0.5, blue: 0.3)).cropped(to: size)
        let balanced = average(OnDeviceImaging.balanceWhite(warm, context: context), in: size)
        XCTAssertLessThan(balanced[0] - balanced[2], 0.4)
    }
}
