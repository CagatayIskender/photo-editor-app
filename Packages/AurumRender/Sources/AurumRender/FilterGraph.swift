import CoreImage
import CoreImage.CIFilterBuiltins
import AurumCore

/// Compiles an `EditDocument` into a Core Image filter chain.
///
/// Every function here is pure: given the same document and input image it
/// builds the same `CIImage` recipe. Nothing renders until a `CIContext`
/// asks for pixels, so compiling is cheap and runs on every slider tick.
///
/// Parameter mappings are first-pass values chosen by eye; a colourist should
/// tune them against reference images before launch.
public struct FilterGraph: Sendable {
    public let catalog: LookCatalog
    /// Seed for deterministic grain, normally derived from the document ID.
    public var grainSeed: UInt64

    public init(catalog: LookCatalog, grainSeed: UInt64 = 0) {
        self.catalog = catalog
        self.grainSeed = grainSeed
    }

    /// Applies every enabled operation and the crop. Overlays are not
    /// included: the preview draws them in SwiftUI and export composites them.
    public func apply(_ document: EditDocument, to source: CIImage) -> CIImage {
        var image = source
        let seed = grainSeed == 0 ? Self.seed(for: document.id) : grainSeed
        for op in document.operations where op.isEnabled {
            switch op.kind {
            case .look(let application):
                image = applyLook(application, to: image, seed: seed)
            case .adjust(let adjustments):
                image = applyAdjustments(adjustments, to: image, seed: seed)
            }
        }
        return applyCrop(document.crop, to: image)
    }

    /// Applies everything except the crop, for the crop tool's full-frame view.
    public func applyWithoutCrop(_ document: EditDocument, to source: CIImage) -> CIImage {
        var doc = document
        doc.crop = .identity
        return apply(doc, to: source)
    }

    static func seed(for id: UUID) -> UInt64 {
        // FNV-1a over the UUID bytes: stable across launches, unlike hashValue.
        var hash: UInt64 = 0xcbf29ce484222325
        withUnsafeBytes(of: id.uuid) { bytes in
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= 0x100000001b3
            }
        }
        return hash
    }

    // MARK: Looks

    func applyLook(_ application: LookApplication, to input: CIImage, seed: UInt64) -> CIImage {
        guard application.intensity > 0, let recipe = catalog.look(id: application.lookID) else { return input }
        let p = recipe.params.applying(application.refine)
        var image = input

        image = exposure(image, ev: p.exposure * 1.5)
        image = highlightsShadows(image, highlights: p.highlights, shadows: p.shadows)
        image = colorControls(image, brightness: 0, contrast: p.contrast, saturation: p.monochrome ? -1 : p.saturation)
        if p.vibrance != 0 { image = vibrance(image, amount: p.vibrance) }
        image = temperature(image, warmth: p.warmth, tint: p.tint)
        image = splitTint(image, shadows: p.shadowsTint, highlights: p.highlightsTint)
        if p.fade > 0 { image = toneCurve(image, blackLift: p.fade * 0.18, whites: -p.fade * 0.04) }
        if p.bloom > 0 { image = bloom(image, amount: p.bloom) }
        if p.lightLeak > 0 { image = lightLeak(image, amount: p.lightLeak) }
        if p.vignette > 0 { image = vignette(image, amount: p.vignette) }
        if p.grain > 0 { image = grain(image, amount: p.grain, size: p.grainSize, seed: seed) }

        image = image.cropped(to: input.extent)
        return mix(from: input, to: image, amount: application.intensity)
    }

    // MARK: Adjustments

    func applyAdjustments(_ a: AdjustmentSet, to input: CIImage, seed: UInt64) -> CIImage {
        guard !a.isNeutral else { return input }
        var image = input
        if a.exposure != 0 { image = exposure(image, ev: a.exposure * 2) }
        image = highlightsShadows(image, highlights: a.highlights, shadows: a.shadows)
        if a.whites != 0 || a.blacks != 0 || a.fade != 0 {
            image = toneCurve(image, blackLift: a.blacks * 0.1 + a.fade * 0.18, whites: a.whites * 0.1)
        }
        image = colorControls(image, brightness: a.brightness, contrast: a.contrast, saturation: a.saturation)
        if a.vibrance != 0 { image = vibrance(image, amount: a.vibrance) }
        image = temperature(image, warmth: a.warmth, tint: a.tint)
        if let cube = ColorCube.make(for: a, dimension: 32) {
            image = colorCube(image, data: cube, dimension: 32)
        }
        if a.clarity > 0 { image = unsharp(image, radius: 20, intensity: a.clarity * 0.6) }
        if a.structure > 0 { image = unsharp(image, radius: 2.5, intensity: a.structure * 0.9) }
        if a.sharpness > 0 { image = sharpen(image, amount: a.sharpness) }
        if a.vignette > 0 { image = vignette(image, amount: a.vignette) }
        if a.vignette < 0 { image = vignette(image, amount: a.vignette) }
        if a.grain > 0 { image = grain(image, amount: a.grain, size: 1, seed: seed &+ 1) }
        return image.cropped(to: input.extent)
    }

    // MARK: Crop

    func applyCrop(_ crop: CropSpec, to input: CIImage) -> CIImage {
        guard !crop.isIdentity else { return input }
        let e = input.extent
        var image = input

        if crop.straightenDegrees != 0 {
            // Rotate about the centre and scale up just enough to hide the corners.
            let radians = crop.straightenDegrees * .pi / 180
            let scale = Self.straightenScale(width: e.width, height: e.height, radians: abs(radians))
            let t = CGAffineTransform(translationX: e.midX, y: e.midY)
                .rotated(by: CGFloat(radians))
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: -e.midX, y: -e.midY)
            image = image.transformed(by: t).cropped(to: e)
        }

        // Normalised rects use a top-left origin; Core Image uses bottom-left.
        let r = crop.rect.clamped()
        let pixelRect = CGRect(
            x: e.minX + r.x * e.width,
            y: e.minY + (1 - r.y - r.height) * e.height,
            width: r.width * e.width,
            height: r.height * e.height
        ).integral
        image = image.cropped(to: pixelRect)

        if crop.flipHorizontal { image = image.oriented(.upMirrored) }
        if crop.flipVertical { image = image.oriented(.downMirrored) }
        switch crop.quarterTurns {
        case 1: image = image.oriented(.right)
        case 2: image = image.oriented(.down)
        case 3: image = image.oriented(.left)
        default: break
        }
        // Move the result back to the origin so later compositing is simple.
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    /// The zoom needed so a rotated image still fills its original frame.
    static func straightenScale(width: CGFloat, height: CGFloat, radians: Double) -> CGFloat {
        let c = CGFloat(cos(radians)), s = CGFloat(sin(radians))
        let w = width * c + height * s
        let h = width * s + height * c
        return max(w / width, h / height)
    }

    // MARK: Building blocks

    func exposure(_ image: CIImage, ev: Double) -> CIImage {
        guard ev != 0 else { return image }
        let f = CIFilter.exposureAdjust()
        f.inputImage = image
        f.ev = Float(ev)
        return f.outputImage ?? image
    }

    func highlightsShadows(_ image: CIImage, highlights: Double, shadows: Double) -> CIImage {
        guard highlights != 0 || shadows != 0 else { return image }
        let f = CIFilter.highlightShadowAdjust()
        f.inputImage = image
        // highlightAmount: 1 is neutral, lower recovers highlights.
        f.highlightAmount = Float(1 + min(highlights, 0) * 0.7)
        f.shadowAmount = Float(shadows * 0.8)
        var out = f.outputImage ?? image
        if highlights > 0 { out = toneCurve(out, blackLift: 0, whites: highlights * 0.06) }
        return out
    }

    func colorControls(_ image: CIImage, brightness: Double, contrast: Double, saturation: Double) -> CIImage {
        guard brightness != 0 || contrast != 0 || saturation != 0 else { return image }
        let f = CIFilter.colorControls()
        f.inputImage = image
        f.brightness = Float(brightness * 0.25)
        f.contrast = Float(1 + contrast * 0.45)
        f.saturation = Float(max(0, 1 + saturation))
        return f.outputImage ?? image
    }

    func vibrance(_ image: CIImage, amount: Double) -> CIImage {
        let f = CIFilter.vibrance()
        f.inputImage = image
        f.amount = Float(amount)
        return f.outputImage ?? image
    }

    func temperature(_ image: CIImage, warmth: Double, tint: Double) -> CIImage {
        guard warmth != 0 || tint != 0 else { return image }
        let f = CIFilter.temperatureAndTint()
        f.inputImage = image
        // Raising the assumed source white point warms the result.
        f.neutral = CIVector(x: CGFloat(6500 + warmth * 2500), y: CGFloat(tint * 60))
        f.targetNeutral = CIVector(x: 6500, y: 0)
        return f.outputImage ?? image
    }

    func toneCurve(_ image: CIImage, blackLift: Double, whites: Double) -> CIImage {
        let f = CIFilter.toneCurve()
        f.inputImage = image
        let lift = CGFloat(max(-0.1, min(blackLift, 0.4)))
        let top = CGFloat(max(0.6, min(1 + whites, 1)))
        let bottom = max(0, lift)
        f.point0 = CGPoint(x: lift < 0 ? -lift : 0, y: bottom)
        f.point1 = CGPoint(x: 0.25, y: bottom + (top - bottom) * 0.25)
        f.point2 = CGPoint(x: 0.5, y: bottom + (top - bottom) * 0.5)
        f.point3 = CGPoint(x: 0.75, y: bottom + (top - bottom) * 0.75)
        f.point4 = CGPoint(x: whites > 0 ? 1 - CGFloat(whites) : 1, y: top)
        return f.outputImage ?? image
    }

    /// Multiplies shadows and highlights by separate RGB tints, blended by luminance.
    func splitTint(_ image: CIImage, shadows: [Double], highlights: [Double]) -> CIImage {
        guard shadows.count == 3, highlights.count == 3, shadows != [1, 1, 1] || highlights != [1, 1, 1] else { return image }
        func tinted(_ t: [Double]) -> CIImage {
            let f = CIFilter.colorMatrix()
            f.inputImage = image
            f.rVector = CIVector(x: CGFloat(t[0]), y: 0, z: 0, w: 0)
            f.gVector = CIVector(x: 0, y: CGFloat(t[1]), z: 0, w: 0)
            f.bVector = CIVector(x: 0, y: 0, z: CGFloat(t[2]), w: 0)
            return f.outputImage ?? image
        }
        let mask = CIFilter.colorControls()
        mask.inputImage = image
        mask.saturation = 0
        let blend = CIFilter.blendWithMask()
        blend.inputImage = tinted(highlights)
        blend.backgroundImage = tinted(shadows)
        blend.maskImage = mask.outputImage
        return blend.outputImage ?? image
    }

    func colorCube(_ image: CIImage, data: [Float], dimension: Int) -> CIImage {
        let f = CIFilter.colorCubeWithColorSpace()
        f.inputImage = image
        f.cubeDimension = Float(dimension)
        f.cubeData = data.withUnsafeBufferPointer { Data(buffer: $0) }
        if let sRGB = CGColorSpace(name: CGColorSpace.sRGB) { f.colorSpace = sRGB }
        return f.outputImage ?? image
    }

    func unsharp(_ image: CIImage, radius: Double, intensity: Double) -> CIImage {
        let f = CIFilter.unsharpMask()
        f.inputImage = image
        f.radius = Float(radius * Self.scale(of: image))
        f.intensity = Float(intensity)
        return f.outputImage ?? image
    }

    func sharpen(_ image: CIImage, amount: Double) -> CIImage {
        let f = CIFilter.sharpenLuminance()
        f.inputImage = image
        f.sharpness = Float(amount * 0.8)
        f.radius = Float(1.5 * Self.scale(of: image))
        return f.outputImage ?? image
    }

    func bloom(_ image: CIImage, amount: Double) -> CIImage {
        let f = CIFilter.bloom()
        f.inputImage = image
        f.radius = Float(12 * Self.scale(of: image))
        f.intensity = Float(amount * 0.8)
        return (f.outputImage ?? image).cropped(to: image.extent)
    }

    /// Positive amounts darken the corners; negative amounts lighten them.
    func vignette(_ image: CIImage, amount: Double) -> CIImage {
        let e = image.extent
        let f = CIFilter.vignetteEffect()
        f.inputImage = image
        f.center = CGPoint(x: e.midX, y: e.midY)
        f.radius = Float(hypot(e.width, e.height) * 0.42)
        f.intensity = Float(amount)
        f.falloff = 0.6
        return f.outputImage ?? image
    }

    /// A warm radial glow from the top-right corner, screened over the image.
    func lightLeak(_ image: CIImage, amount: Double) -> CIImage {
        let e = image.extent
        let g = CIFilter.radialGradient()
        g.center = CGPoint(x: e.maxX, y: e.maxY)
        g.radius0 = 0
        g.radius1 = Float(max(e.width, e.height) * 0.75)
        g.color0 = CIColor(red: 1, green: 0.55, blue: 0.25, alpha: CGFloat(min(amount, 1) * 0.75))
        g.color1 = CIColor(red: 1, green: 0.4, blue: 0.2, alpha: 0)
        guard let leak = g.outputImage?.cropped(to: e) else { return image }
        let screen = CIFilter.screenBlendMode()
        screen.inputImage = leak
        screen.backgroundImage = image
        return screen.outputImage ?? image
    }

    /// Film grain: seeded monochrome noise, soft-light blended. The noise is
    /// anchored to the image, so the same edit gets the same grain at any size.
    func grain(_ image: CIImage, amount: Double, size: Double, seed: UInt64) -> CIImage {
        let e = image.extent
        let scale = Self.scale(of: image) * max(0.5, min(size, 2))
        let offsetX = CGFloat(seed % 4096), offsetY = CGFloat((seed >> 12) % 4096)
        guard let noise = CIFilter.randomGenerator().outputImage else { return image }
        let positioned = noise
            .transformed(by: CGAffineTransform(translationX: -offsetX, y: -offsetY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
            .cropped(to: e)
        let mono = CIFilter.colorMatrix()
        mono.inputImage = positioned
        let k = CGFloat(min(amount, 1) * 0.35)
        // Use the red channel as luminance noise, centred on mid-grey.
        mono.rVector = CIVector(x: k, y: 0, z: 0, w: 0)
        mono.gVector = CIVector(x: k, y: 0, z: 0, w: 0)
        mono.bVector = CIVector(x: k, y: 0, z: 0, w: 0)
        mono.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        mono.biasVector = CIVector(x: 0.5 - k / 2, y: 0.5 - k / 2, z: 0.5 - k / 2, w: 0)
        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = mono.outputImage
        blend.backgroundImage = image
        return blend.outputImage ?? image
    }

    /// Blends `to` over `from` by `amount` (0 shows `from`).
    func mix(from: CIImage, to: CIImage, amount: Double) -> CIImage {
        guard amount < 1 else { return to }
        let f = CIFilter.dissolveTransition()
        f.inputImage = from
        f.targetImage = to
        f.time = Float(max(0, amount))
        return f.outputImage ?? to
    }

    /// Converts radii authored for a 1080 px image to this image's size, so a
    /// proxy and the full-size export look the same.
    static func scale(of image: CIImage) -> Double {
        Double(max(image.extent.width, image.extent.height)) / 1080
    }
}
