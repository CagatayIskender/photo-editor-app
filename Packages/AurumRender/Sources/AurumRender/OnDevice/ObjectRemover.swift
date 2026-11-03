import CoreImage
import AurumCore

/// Object Remove without generative models: the brushed area is filled from
/// its own surroundings by `Inpainter` (push-pull fill plus a matching
/// nearby patch for texture), then composited back through a feathered mask.
///
/// Only the region around the brushed area is processed, at full resolution
/// when it fits in `maxWorkingSide` and downscaled otherwise.
public enum ObjectRemover {
    /// Longest side, in pixels, of the region filled on the CPU.
    public static let maxWorkingSide = 1024

    public static func remove(_ mask: BrushMask, from image: CIImage, context: CIContext, maxWorkingSide: Int = ObjectRemover.maxWorkingSide) throws -> CIImage {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite, extent.width >= 2, extent.height >= 2 else { throw OnDeviceImaging.ImagingError.renderFailed }
        let imageWidth = Double(extent.width)
        let imageHeight = Double(extent.height)
        guard let painted = mask.paintedBounds(aspect: imageWidth / imageHeight) else { throw OnDeviceImaging.ImagingError.emptyMask }

        // The region: the painted box grown by its own size on every side, so
        // the patch search has room. Pixels, origin top-left.
        let region = workingRegion(painted: painted, imageWidth: imageWidth, imageHeight: imageHeight)
        let scale = min(1, Double(maxWorkingSide) / max(region.width, region.height))
        let bw = max(2, Int((region.width * scale).rounded(.down)))
        let bh = max(2, Int((region.height * scale).rounded(.down)))
        let sx = Double(bw) / region.width
        let sy = Double(bh) / region.height

        // Core Image works bottom-up: the region's lower-left corner.
        let ciRegionX = Double(extent.minX) + region.x
        let ciRegionY = Double(extent.minY) + imageHeight - region.y - region.height
        let toBuffer = CGAffineTransform(translationX: CGFloat(-ciRegionX), y: CGFloat(-ciRegionY))
            .concatenating(CGAffineTransform(scaleX: CGFloat(sx), y: CGFloat(sy)))
        let fromBuffer = toBuffer.inverted()

        let space = CGColorSpace(name: CGColorSpace.sRGB)
        var bytes = [UInt8](repeating: 0, count: bw * bh * 4)
        let local = image.clampedToExtent().transformed(by: toBuffer)
        context.render(local, toBitmap: &bytes, rowBytes: bw * 4, bounds: CGRect(x: 0, y: 0, width: bw, height: bh), format: .RGBA8, colorSpace: space)

        // The hole grows by two buffer pixels so the fill reaches past the brush edge.
        let imageW = imageWidth * sx
        let imageH = imageHeight * sy
        let originX = region.x * sx
        let originY = region.y * sy
        let hole = mask.coverage(width: bw, height: bh, imageWidth: imageW, imageHeight: imageH, originX: originX, originY: originY, grow: 2)
        guard hole.contains(where: { $0 > 0 }) else { throw OnDeviceImaging.ImagingError.emptyMask }

        let source = RGBAImageBuffer(rgba8: bytes, width: bw, height: bh)
        let filled = Inpainter.fill(source, mask: hole)
        let filledImage = CIImage(bitmapData: Data(filled.rgba8), bytesPerRow: bw * 4, size: CGSize(width: bw, height: bh), format: .RGBA8, colorSpace: space)

        // The composite mask: the brushed area grown by one pixel, feathered.
        let soft = mask.coverage(width: bw, height: bh, imageWidth: imageW, imageHeight: imageH, originX: originX, originY: originY, grow: 1)
        var maskBytes = [UInt8](repeating: 255, count: bw * bh * 4)
        for i in 0..<(bw * bh) {
            let v: UInt8 = soft[i] > 0 ? 255 : 0
            maskBytes[i * 4] = v
            maskBytes[i * 4 + 1] = v
            maskBytes[i * 4 + 2] = v
        }
        let hardMask = CIImage(bitmapData: Data(maskBytes), bytesPerRow: bw * 4, size: CGSize(width: bw, height: bh), format: .RGBA8, colorSpace: nil)
        let featheredMask = OnDeviceImaging.blur(hardMask, radius: 1.5)

        let placedFill = filledImage.transformed(by: fromBuffer)
        let placedMask = featheredMask.transformed(by: fromBuffer)
        return OnDeviceImaging.blend(placedFill, over: image, mask: placedMask).cropped(to: extent)
    }

    /// The painted box grown by its size (at least 32 px) on every side,
    /// clamped to the photo. Pixels, origin top-left.
    static func workingRegion(painted: NormalizedRect, imageWidth: Double, imageHeight: Double) -> (x: Double, y: Double, width: Double, height: Double) {
        let px = painted.x * imageWidth
        let py = painted.y * imageHeight
        let pw = painted.width * imageWidth
        let ph = painted.height * imageHeight
        let margin = max(32, max(pw, ph))
        let minX = max(0, (px - margin).rounded(.down))
        let minY = max(0, (py - margin).rounded(.down))
        let maxX = min(imageWidth, (px + pw + margin).rounded(.up))
        let maxY = min(imageHeight, (py + ph + margin).rounded(.up))
        return (minX, minY, max(1, maxX - minX), max(1, maxY - minY))
    }
}
