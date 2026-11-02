import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Vision
import AurumCore

/// The Auto Studio's processing. Everything runs on the iPhone: Apple's
/// Vision framework finds people, faces and the horizon, and classic Core
/// Image filters do the rest. Nothing is generated and nothing is uploaded.
///
/// Every function takes and returns a `CIImage` with the same extent as the
/// input; nothing renders until a context asks for pixels (except where a
/// `CIContext` is passed in to measure the photo).
public enum OnDeviceImaging {
    public enum ImagingError: Error, Equatable {
        /// Vision found no person to keep or to light.
        case noPerson
        case segmentationFailed
        /// Object Remove was given nothing to remove.
        case emptyMask
        case renderFailed
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

    /// The parts of Auto Enhance. Each can be switched off.
    public struct EnhanceOptions: Equatable, Sendable {
        /// Exposure, contrast, shadows and vibrance from Core Image's own analysis.
        public var autoTone: Bool
        /// Neutralises a colour cast (grey-world balance, kept gentle).
        public var whiteBalance: Bool
        /// Levels a tilted horizon found by Vision.
        public var straighten: Bool
        /// Core Image's red-eye correction.
        public var redEye: Bool
        /// Light noise reduction and sharpening.
        public var clarity: Bool

        public init(autoTone: Bool = true, whiteBalance: Bool = true, straighten: Bool = true, redEye: Bool = true, clarity: Bool = true) {
            self.autoTone = autoTone
            self.whiteBalance = whiteBalance
            self.straighten = straighten
            self.redEye = redEye
            self.clarity = clarity
        }

        public static let all = EnhanceOptions()
        public static let none = EnhanceOptions(autoTone: false, whiteBalance: false, straighten: false, redEye: false, clarity: false)
    }

    // MARK: Segmentation

    /// A person matte the size of `image`: white where a person is, black
    /// elsewhere, with softened edges.
    public static func personMask(for image: CIImage, accurate: Bool = true) throws -> CIImage {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { throw ImagingError.segmentationFailed }
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = accurate ? .accurate : .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try handler.perform([request])
        guard let buffer = request.results?.first?.pixelBuffer else { throw ImagingError.segmentationFailed }

        var mask = gray(CIImage(cvPixelBuffer: buffer))
        let m = mask.extent
        guard m.width > 0, m.height > 0 else { throw ImagingError.segmentationFailed }
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
            let shortSide = Double(min(extent.width, extent.height))
            behind = blur(image, radius: max(1, radius) * shortSide / 1000).cropped(to: extent)
        }
        return blend(image, over: behind, mask: matte).cropped(to: extent)
    }

    // MARK: Portrait blur

    /// Keeps the person sharp and blurs the rest with `CIMaskedVariableBlur`,
    /// which blurs more where the (inverted) person matte is whiter.
    /// `amount` 0...1 sets the blur radius.
    public static func portraitBlur(_ image: CIImage, amount: Double, mask: CIImage? = nil) throws -> CIImage {
        let extent = image.extent
        let k = (0.0...1.0).clamp(amount)
        guard k > 0 else { return image }
        let matte = try mask ?? personMask(for: image)
        let invert = CIFilter.colorInvert()
        invert.inputImage = matte
        let background = (invert.outputImage ?? matte).clampedToExtent()
        let shortSide = Double(min(extent.width, extent.height))
        let f = CIFilter.maskedVariableBlur()
        f.inputImage = image.clampedToExtent()
        f.mask = background
        f.radius = Float(k * shortSide * 0.025)
        let blurred = (f.outputImage ?? image).cropped(to: extent)
        // Put the sharp person back on top so no halo creeps onto them.
        return blend(image, over: blurred, mask: matte).cropped(to: extent)
    }

    // MARK: Enhance

    /// Auto Enhance: red-eye fix, grey-world white balance, Core Image's auto
    /// tone, light noise reduction and sharpening, and levelling of a tilted
    /// horizon (`horizonDegrees`, counter-clockwise positive, from Vision).
    /// `strength` 0...1 blends the tone and colour with the original.
    public static func enhance(_ image: CIImage, options: EnhanceOptions = .all, horizonDegrees: Double? = nil, strength: Double = 1, context: CIContext) -> CIImage {
        let extent = image.extent
        var out = image

        if options.redEye {
            out = applyChain(out.autoAdjustmentFilters(options: [.enhance: false, .redEye: true]), to: out)
        }
        if options.whiteBalance {
            out = balanceWhite(out, context: context)
        }
        if options.autoTone {
            // CIFaceBalance warms or cools skin; it belongs with white balance.
            let filters = out.autoAdjustmentFilters(options: [.enhance: true, .redEye: false]).filter { filter in
                options.whiteBalance || filter.name != "CIFaceBalance"
            }
            out = applyChain(filters, to: out)
        }
        if options.clarity {
            let nr = CIFilter.noiseReduction()
            nr.inputImage = out
            nr.noiseLevel = 0.015
            nr.sharpness = 0.45
            out = nr.outputImage ?? out
            let sharpen = CIFilter.sharpenLuminance()
            sharpen.inputImage = out
            sharpen.sharpness = 0.35
            out = sharpen.outputImage ?? out
        }
        out = out.cropped(to: extent)

        let s = (0.0...1.0).clamp(strength)
        if s < 1 {
            let dissolve = CIFilter.dissolveTransition()
            dissolve.inputImage = image
            dissolve.targetImage = out
            dissolve.time = Float(s)
            out = (dissolve.outputImage ?? out).cropped(to: extent)
        }

        if options.straighten, let degrees = horizonDegrees, Straighten.isWorthCorrecting(degrees: degrees) {
            out = straighten(out, degrees: degrees)
        }
        return out
    }

    /// Rotates by `-degrees` about the centre and scales up just enough to
    /// leave no empty corners, keeping the extent.
    public static func straighten(_ image: CIImage, degrees: Double) -> CIImage {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite, degrees != 0 else { return image }
        let radians = -degrees * Double.pi / 180
        let scale = CGFloat(Straighten.coverScale(width: Double(extent.width), height: Double(extent.height), radians: radians))
        let t = CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(radians)))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: extent.midX, y: extent.midY))
        return image.clampedToExtent().transformed(by: t).cropped(to: extent)
    }

    /// Grey-world white balance: scales red, green and blue so the photo's
    /// average is neutral, limited and softened so warm sunsets stay warm.
    public static func balanceWhite(_ image: CIImage, context: CIContext) -> CIImage {
        guard let avg = averageLinear(image, in: image.extent, context: context) else { return image }
        let r = max(Double(avg[0]), 1e-4)
        let g = max(Double(avg[1]), 1e-4)
        let b = max(Double(avg[2]), 1e-4)
        let mean = (r + g + b) / 3
        func gain(_ c: Double) -> CGFloat {
            let full = (0.8...1.25).clamp(mean / c)
            return CGFloat(1 + 0.7 * (full - 1))
        }
        let m = CIFilter.colorMatrix()
        m.inputImage = image
        m.rVector = CIVector(x: gain(r), y: 0, z: 0, w: 0)
        m.gVector = CIVector(x: 0, y: gain(g), z: 0, w: 0)
        m.bVector = CIVector(x: 0, y: 0, z: gain(b), w: 0)
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        m.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return (m.outputImage ?? image).cropped(to: image.extent)
    }

    // MARK: Retouch

    /// The "Natural" skin retouch on every detected face, at `strength` 0...1.
    public static func naturalRetouch(_ image: CIImage, faces: [FaceGeometry], strength: Double) -> CIImage {
        let settings = RetouchSettings(global: FaceRetouch.natural.scaled(by: strength))
        return RetouchRenderer.apply(settings, faces: faces, to: image).cropped(to: image.extent)
    }

    // MARK: Portrait Looks

    /// A portrait look: its colour recipe, a vignette centred on the faces,
    /// and (when a person matte is given) a background blur.
    public static func portraitLook(_ image: CIImage, look: PortraitLook, faces: [FaceGeometry], personMask: CIImage?, intensity: Double = 1) -> CIImage {
        let extent = image.extent
        let k = (0.0...1.0).clamp(intensity)
        let recipe = LookRecipe(id: look.id, name: look.name, collection: "portrait", tier: look.tier, params: look.params)
        let graph = FilterGraph(catalog: LookCatalog(collections: [], looks: [recipe]))
        var out = graph.applyLook(LookApplication(lookID: look.id, intensity: k), to: image, seed: 1)
        if look.backgroundBlur > 0, let personMask {
            out = (try? portraitBlur(out, amount: look.backgroundBlur * k, mask: personMask)) ?? out
        }
        if look.faceVignette > 0 {
            out = faceVignette(out, faces: faces, amount: look.faceVignette * k)
        }
        return out.cropped(to: extent)
    }

    /// Darkens away from the faces (or the frame's upper middle without faces).
    static func faceVignette(_ image: CIImage, faces: [FaceGeometry], amount: Double) -> CIImage {
        let extent = image.extent
        guard amount > 0, !extent.isEmpty else { return image }
        var center = CGPoint(x: extent.midX, y: extent.minY + extent.height * 0.6)
        var faceSize = min(extent.width, extent.height) * 0.3
        if !faces.isEmpty {
            var sx = 0.0, sy = 0.0, size = 0.0
            for face in faces {
                let b = face.bounds
                sx += b.x + b.width / 2
                sy += b.y + b.height / 2
                size = max(size, max(b.width * Double(extent.width), b.height * Double(extent.height)))
            }
            let n = Double(faces.count)
            center = CGPoint(x: extent.minX + CGFloat(sx / n) * extent.width,
                             y: extent.minY + CGFloat(1 - sy / n) * extent.height)
            faceSize = max(CGFloat(size), min(extent.width, extent.height) * 0.12)
        }
        let darker = CIFilter.exposureAdjust()
        darker.inputImage = image
        darker.ev = Float(-1.4 * amount)
        let dark = (darker.outputImage ?? image).cropped(to: extent)
        let g = CIFilter.radialGradient()
        g.center = center
        g.radius0 = Float(faceSize * 0.9)
        g.radius1 = Float(max(extent.width, extent.height) * 0.75)
        g.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        g.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let light = g.outputImage?.cropped(to: extent) else { return image }
        return blend(image, over: dark, mask: light).cropped(to: extent)
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

    /// Runs filters one after another.
    static func applyChain(_ filters: [CIFilter], to image: CIImage) -> CIImage {
        var out = image
        for filter in filters {
            filter.setValue(out, forKey: kCIInputImageKey)
            out = filter.outputImage ?? out
        }
        return out
    }

    /// The average colour inside `rect`, in Core Image's linear working
    /// space (r, g, b, a), or nil if it can't be measured.
    static func averageLinear(_ image: CIImage, in rect: CGRect, context: CIContext) -> [Float]? {
        let r = rect.intersection(image.extent)
        guard !r.isEmpty, !r.isInfinite else { return nil }
        let f = CIFilter.areaAverage()
        f.inputImage = image
        f.extent = r
        guard let out = f.outputImage else { return nil }
        var px = [Float](repeating: 0, count: 4)
        let pixel = CGRect(x: out.extent.minX, y: out.extent.minY, width: 1, height: 1)
        context.render(out, toBitmap: &px, rowBytes: 16, bounds: pixel, format: .RGBAf, colorSpace: nil)
        return px
    }

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
