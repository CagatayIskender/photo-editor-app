import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Vision
import AurumCore

/// The AI Studio features that run entirely on the iPhone: background
/// replacement from Vision's person segmentation, a one-tap enhance, and a
/// soft portrait relight. Nothing here leaves the device, so these work for
/// every member and free user as a preview.
///
/// Every function takes and returns a `CIImage` with the same extent as the
/// input; nothing renders until a context asks for pixels.
public enum OnDeviceAI {
    public enum AIError: Error, Equatable {
        /// Vision found no person to keep or to light.
        case noPerson
        case segmentationFailed
    }

    /// What goes behind the person in `replaceBackground`.
    public enum Background {
        case image(CIImage)
        case color(CIColor)
        /// Top colour to bottom colour.
        case gradient(top: CIColor, bottom: CIColor)
        /// The photo's own background, heavily blurred (a "studio" look).
        case blur(radius: Double)
    }

    /// Where the soft key light comes from in `relight`.
    public enum LightDirection: String, CaseIterable, Sendable {
        case front, left, right, above
    }

    // MARK: Segmentation

    /// A person matte the size of `image`: white where a person is, black
    /// elsewhere, with softened edges. Throws `noPerson` if the matte is empty.
    public static func personMask(for image: CIImage, accurate: Bool = true) throws -> CIImage {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { throw AIError.segmentationFailed }
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = accurate ? .accurate : .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try handler.perform([request])
        guard let buffer = request.results?.first?.pixelBuffer else { throw AIError.segmentationFailed }

        var mask = gray(CIImage(cvPixelBuffer: buffer))
        let m = mask.extent
        guard m.width > 0, m.height > 0 else { throw AIError.segmentationFailed }
        mask = mask
            .transformed(by: CGAffineTransform(translationX: -m.minX, y: -m.minY))
            .transformed(by: CGAffineTransform(scaleX: extent.width / m.width, y: extent.height / m.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        // A small blur hides the matte's upscaling steps along hair and shoulders.
        let feather = max(1, min(extent.width, extent.height) * 0.003)
        return blur(mask, radius: feather).cropped(to: extent)
    }

    // MARK: Background

    /// Keeps the person and puts `background` behind them.
    public static func replaceBackground(_ image: CIImage, background: Background, mask: CIImage? = nil) throws -> CIImage {
        let extent = image.extent
        let matte = try mask ?? personMask(for: image)
        let behind: CIImage
        switch background {
        case .image(let other):
            behind = aspectFill(other, to: extent)
        case .color(let color):
            behind = CIImage(color: color).cropped(to: extent)
        case .gradient(let top, let bottom):
            let g = CIFilter.linearGradient()
            g.point0 = CGPoint(x: extent.midX, y: extent.maxY)
            g.point1 = CGPoint(x: extent.midX, y: extent.minY)
            g.color0 = top
            g.color1 = bottom
            behind = (g.outputImage ?? CIImage(color: bottom)).cropped(to: extent)
        case .blur(let radius):
            behind = blur(image, radius: max(1, radius) * Double(min(extent.width, extent.height)) / 1000).cropped(to: extent)
        }
        return blend(image, over: behind, mask: matte).cropped(to: extent)
    }

    // MARK: Enhance

    /// Auto exposure and colour (Core Image's own analysis), gentle noise
    /// reduction and a light luminance sharpen. `strength` 0...1 blends with
    /// the original.
    public static func enhance(_ image: CIImage, strength: Double = 1) -> CIImage {
        let extent = image.extent
        var out = image
        for filter in image.autoAdjustmentFilters(options: [.redEye: false]) {
            filter.setValue(out, forKey: kCIInputImageKey)
            out = filter.outputImage ?? out
        }
        let nr = CIFilter.noiseReduction()
        nr.inputImage = out
        nr.noiseLevel = 0.015
        nr.sharpness = 0.45
        out = nr.outputImage ?? out
        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = out
        sharpen.sharpness = 0.35
        out = (sharpen.outputImage ?? out).cropped(to: extent)
        let s = (0.0...1.0).clamp(strength)
        guard s < 1 else { return out }
        let dissolve = CIFilter.dissolveTransition()
        dissolve.inputImage = image
        dissolve.targetImage = out
        dissolve.time = Float(s)
        return (dissolve.outputImage ?? out).cropped(to: extent)
    }

    // MARK: Relight

    /// A soft, warm key light on each face, coming from `direction`, kept on
    /// the person by the segmentation matte so the background stays as it was.
    /// With no faces, the light falls on the middle of the person (or the frame).
    public static func relight(_ image: CIImage, faces: [FaceGeometry], direction: LightDirection, intensity: Double, mask: CIImage? = nil) -> CIImage {
        let extent = image.extent
        let k = (0.0...1.0).clamp(intensity)
        guard k > 0, !extent.isEmpty else { return image }

        // The lit version: brighter and a little warmer.
        let exposure = CIFilter.exposureAdjust()
        exposure.inputImage = image
        exposure.ev = Float(0.9 * k)
        let warm = CIFilter.temperatureAndTint()
        warm.inputImage = exposure.outputImage ?? image
        warm.neutral = CIVector(x: 6500, y: 0)
        warm.targetNeutral = CIVector(x: 6500 - 900 * k, y: 0)
        let lit = (warm.outputImage ?? image).cropped(to: extent)

        // One radial pool of light per face, offset toward the light.
        let shortSide = min(extent.width, extent.height)
        let spots: [(CGPoint, CGFloat)] = faces.isEmpty
            ? [(CGPoint(x: extent.midX, y: extent.minY + extent.height * 0.6), shortSide * 0.35)]
            : faces.map { face in
                let b = face.bounds
                let size = CGFloat(max(b.width * Double(extent.width), b.height * Double(extent.height)))
                let center = CGPoint(
                    x: extent.minX + CGFloat(b.x + b.width / 2) * extent.width,
                    y: extent.minY + CGFloat(1 - (b.y + b.height / 2)) * extent.height
                )
                return (center, max(size, shortSide * 0.08))
            }
        var light = CIImage(color: .black).cropped(to: extent)
        for (center, size) in spots {
            var c = center
            switch direction {
            case .front: break
            case .left: c.x -= size * 0.6
            case .right: c.x += size * 0.6
            case .above: c.y += size * 0.6
            }
            let g = CIFilter.radialGradient()
            g.center = c
            g.radius0 = Float(size * 0.25)
            g.radius1 = Float(size * 1.6)
            g.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
            g.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
            if let pool = g.outputImage?.cropped(to: extent) {
                let lighten = CIFilter.lightenBlendMode()
                lighten.inputImage = pool
                lighten.backgroundImage = light
                light = lighten.outputImage ?? light
            }
        }
        // Keep the light on the person when a matte is available.
        let personMatte = mask ?? (try? personMask(for: image, accurate: false))
        if let personMatte {
            let multiply = CIFilter.multiplyCompositing()
            multiply.inputImage = light
            multiply.backgroundImage = personMatte
            light = multiply.outputImage ?? light
        }
        return blend(lit, over: image, mask: light.cropped(to: extent)).cropped(to: extent)
    }

    // MARK: Building blocks

    /// Copies the first channel into r, g and b, so single-channel mattes
    /// (OneComponent8, disparity) behave the same whichever way Core Image reads them.
    static func gray(_ image: CIImage) -> CIImage {
        let f = CIFilter.colorMatrix()
        f.inputImage = image
        f.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        f.gVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        f.bVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        f.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return f.outputImage ?? image
    }

    static func blur(_ image: CIImage, radius: Double) -> CIImage {
        let extent = image.extent
        let f = CIFilter.gaussianBlur()
        f.inputImage = image.clampedToExtent()
        f.radius = Float(max(0, radius))
        return (f.outputImage ?? image).cropped(to: extent)
    }

    /// `foreground` where the mask is white, `background` where it is black.
    static func blend(_ foreground: CIImage, over background: CIImage, mask: CIImage) -> CIImage {
        let f = CIFilter.blendWithMask()
        f.inputImage = foreground
        f.backgroundImage = background
        f.maskImage = mask
        return f.outputImage ?? foreground
    }

    /// Scales and centres `image` so it covers `rect` completely.
    static func aspectFill(_ image: CIImage, to rect: CGRect) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0, !e.isInfinite else { return image.cropped(to: rect) }
        let s = max(rect.width / e.width, rect.height / e.height)
        let t = CGAffineTransform(translationX: -e.midX, y: -e.midY)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))
        return image.clampedToExtent().transformed(by: t).cropped(to: rect)
    }
}
