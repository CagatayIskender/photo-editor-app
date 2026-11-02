import CoreImage
import AurumCore

extension RenderEngine {
    /// Measures average luminance, per-pixel saturation and warmth.
    ///
    /// Renders the image down to 16×16 and averages on the CPU. Per-pixel
    /// saturation matters: a colourful photo can still have a grey average,
    /// and should not be mistaken for black and white.
    public func stats(of image: CIImage) -> ImageStats {
        let side: CGFloat = 16
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return ImageStats(luminance: 0.5, saturation: 0.3, warmth: 0) }
        let small = image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: side / e.width, y: side / e.height))
        var px = [UInt8](repeating: 0, count: Int(side * side) * 4)
        context.render(small, toBitmap: &px, rowBytes: Int(side) * 4, bounds: CGRect(x: 0, y: 0, width: side, height: side), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return Self.stats(fromRGBA: px)
    }

    /// Pure helper, separated for testing.
    nonisolated static func stats(fromRGBA px: [UInt8]) -> ImageStats {
        var lum = 0.0, sat = 0.0, warm = 0.0
        let count = px.count / 4
        guard count > 0 else { return ImageStats(luminance: 0.5, saturation: 0.3, warmth: 0) }
        for i in 0..<count {
            let r = Double(px[i * 4]) / 255, g = Double(px[i * 4 + 1]) / 255, b = Double(px[i * 4 + 2]) / 255
            let maxC = max(r, g, b), minC = min(r, g, b)
            lum += 0.2126 * r + 0.7152 * g + 0.0722 * b
            sat += maxC == 0 ? 0 : (maxC - minC) / maxC
            warm += r - b
        }
        let n = Double(count)
        return ImageStats(luminance: lum / n, saturation: sat / n, warmth: warm / n)
    }
}
