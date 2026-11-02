import CoreImage
import CoreImage.CIFilterBuiltins
import AurumCore

/// Renders animated video effects for one frame.
///
/// Each effect is sampled at the frame's time (`AnimatedEffect.sample(at:)`
/// is a pure function of time and seed) and every random choice here derives
/// from the time and seed too, so the preview and the export render exactly
/// the same frames. The output extent always equals the input extent.
public enum EffectRenderer {
    public static func apply(_ effects: [AnimatedEffect], at time: Double, to image: CIImage) -> CIImage {
        let extent = image.extent
        guard time.isFinite, !extent.isEmpty, !extent.isInfinite else { return image }
        var output = image
        var changed = false
        for effect in effects where effect.isActive(at: time) && effect.intensity > 0 {
            output = render(effect.sample(at: time), seed: effect.seed, time: time, to: output, extent: extent)
            changed = true
        }
        return changed ? output.cropped(to: extent) : image
    }

    /// Renders one sampled effect. Every stage is skipped at its neutral value.
    static func render(_ s: AnimatedEffect.Sample, seed: UInt64, time: Double, to image: CIImage, extent: CGRect) -> CIImage {
        var out = image
        if s.exposure != 1 {
            out = exposure(out, ev: log2(max(s.exposure, 0.01)))
        }
        if s.leak > 0 {
            out = lightLeak(out, amount: s.leak, position: s.leakPosition, extent: extent)
        }
        if s.glitter > 0 {
            out = glitter(out, amount: s.glitter, seed: seed, time: time, extent: extent)
        }
        if s.tracking > 0 {
            out = tracking(out, amount: s.tracking, seed: seed, time: time, extent: extent)
        }
        if s.offsetX != 0 || s.offsetY != 0 || s.zoom != 1 {
            out = camera(out, offsetX: s.offsetX, offsetY: s.offsetY, zoom: s.zoom, extent: extent)
        }
        return out.cropped(to: extent)
    }

    // MARK: Exposure

    static func exposure(_ image: CIImage, ev: Double) -> CIImage {
        guard ev != 0, ev.isFinite else { return image }
        let f = CIFilter.exposureAdjust()
        f.inputImage = image
        f.ev = Float(ev)
        return f.outputImage ?? image
    }

    // MARK: Light leak

    /// A warm amber core with a rose halo, centred on the top edge at
    /// `position` across the frame, screened over the image.
    static func lightLeak(_ image: CIImage, amount: Double, position: Double, extent: CGRect) -> CIImage {
        let alpha = CGFloat(min(amount, 1) * 0.6)
        let center = CGPoint(
            x: extent.minX + CGFloat(max(0, min(position, 1))) * extent.width,
            y: extent.maxY - extent.height * 0.04
        )
        let radius = extent.width * 0.8

        let rose = CIFilter.radialGradient()
        rose.center = center
        rose.radius0 = Float(radius * 0.15)
        rose.radius1 = Float(radius)
        rose.color0 = CIColor(red: 1, green: 0.42, blue: 0.5, alpha: alpha * 0.7)
        rose.color1 = CIColor(red: 1, green: 0.42, blue: 0.5, alpha: 0)

        let amber = CIFilter.radialGradient()
        amber.center = center
        amber.radius0 = 0
        amber.radius1 = Float(radius * 0.55)
        amber.color0 = CIColor(red: 1, green: 0.66, blue: 0.3, alpha: alpha)
        amber.color1 = CIColor(red: 1, green: 0.55, blue: 0.35, alpha: 0)

        guard let roseImage = rose.outputImage, let amberImage = amber.outputImage else { return image }
        let leak = amberImage.composited(over: roseImage).cropped(to: extent)
        return screen(leak, over: image)
    }

    // MARK: Glitter

    /// Sparse champagne sparkles with a soft glow and a four-point star shine.
    /// The random field is offset by a hash of floor(time × 12), so the
    /// glitter changes twelve times a second and is identical for a given time.
    static func glitter(_ image: CIImage, amount: Double, seed: UInt64, time: Double, extent: CGRect) -> CIImage {
        guard let noise = CIFilter.randomGenerator().outputImage else { return image }
        let scale = CGFloat(max(1, FilterGraph.scale(of: image) * 1.5))
        let frame = Int64(floor(time * 12))
        let h = hash(frame, seed)
        let ox = CGFloat(h % 4096), oy = CGFloat((h >> 16) % 4096)
        let field = noise
            .transformed(by: CGAffineTransform(translationX: -ox, y: -oy))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)

        // Threshold the red channel to sparse points: (r - t) / (1 - t),
        // tinted champagne #F4E3BF, kept opaque so screening black adds nothing.
        let t = CGFloat(0.996 - 0.004 * min(amount, 1))
        let k = 1 / (1 - t)
        let champagne = (r: CGFloat(0xF4) / 255, g: CGFloat(0xE3) / 255, b: CGFloat(0xBF) / 255)
        let threshold = CIFilter.colorMatrix()
        threshold.inputImage = field
        threshold.rVector = CIVector(x: k * champagne.r, y: 0, z: 0, w: 0)
        threshold.gVector = CIVector(x: k * champagne.g, y: 0, z: 0, w: 0)
        threshold.bVector = CIVector(x: k * champagne.b, y: 0, z: 0, w: 0)
        threshold.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        threshold.biasVector = CIVector(x: -t * k * champagne.r, y: -t * k * champagne.g, z: -t * k * champagne.b, w: 0)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = threshold.outputImage
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        guard var points = clamp.outputImage?.cropped(to: extent) else { return image }

        let dilate = CIFilter.morphologyMaximum()
        dilate.inputImage = points
        dilate.radius = Float(max(1, scale * 0.6))
        points = (dilate.outputImage ?? points).cropped(to: extent)

        let glow = CIFilter.gaussianBlur()
        glow.inputImage = points
        glow.radius = Float(scale * 2)
        var sparkle = points
        if let g = glow.outputImage {
            sparkle = screen(gain(g.cropped(to: extent), 2), over: sparkle)
        }
        for angle in [Float(0), Float.pi / 2] {
            let streak = CIFilter.motionBlur()
            streak.inputImage = points
            streak.radius = Float(scale * 5)
            streak.angle = angle
            if let s = streak.outputImage {
                sparkle = screen(gain(s.cropped(to: extent), 3), over: sparkle)
            }
        }

        let layer = gain(sparkle.cropped(to: extent), min(amount, 1) * 0.8)
        return screen(layer, over: image)
    }

    // MARK: Tape tracking

    /// VHS tracking: two or three horizontal bands slip sideways, and the
    /// red and blue channels separate slightly. Band positions change 24
    /// times a second and derive from the time and seed.
    static func tracking(_ image: CIImage, amount: Double, seed: UInt64, time: Double, extent: CGRect) -> CIImage {
        let a = min(amount, 1)
        let frame = Int64(floor(time * 24))
        var out = image

        let bands = 2 + Int(hash(frame, seed &+ 3) % 2)
        for i in 0..<bands {
            let salt = seed &+ UInt64(i) &* 0x632BE59BD9B4E019
            let u1 = unit(hash(frame, salt &+ 11))
            let u2 = unit(hash(frame, salt &+ 23))
            let u3 = unit(hash(frame, salt &+ 37))
            let bandHeight = extent.height * CGFloat(0.02 + 0.07 * u2)
            let y = extent.minY + CGFloat(u1) * (extent.height - bandHeight)
            let direction: CGFloat = i % 2 == 0 ? 1 : -1
            let dx = extent.width * CGFloat(a * (0.015 + 0.035 * u3)) * direction
            let band = CGRect(x: extent.minX, y: y, width: extent.width, height: bandHeight)
            let shifted = out.clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: dx, y: 0))
                .cropped(to: band)
            out = shifted.composited(over: out)
        }

        // Chromatic offset: ±amount × 4 px at 1080 px, scaled with the image.
        let shift = CGFloat(a * 4 * FilterGraph.scale(of: image))
        if shift > 0.01 {
            let source = out.clampedToExtent()
            let red = channel(source, 0).transformed(by: CGAffineTransform(translationX: shift, y: 0))
            let green = channel(source, 1)
            let blue = channel(source, 2).transformed(by: CGAffineTransform(translationX: -shift, y: 0))
            out = maximum(maximum(red, green), blue)
        }
        return out.cropped(to: extent)
    }

    /// Keeps one colour channel (0 red, 1 green, 2 blue), zeroing the others.
    static func channel(_ image: CIImage, _ index: Int) -> CIImage {
        let f = CIFilter.colorMatrix()
        f.inputImage = image
        f.rVector = CIVector(x: index == 0 ? 1 : 0, y: 0, z: 0, w: 0)
        f.gVector = CIVector(x: 0, y: index == 1 ? 1 : 0, z: 0, w: 0)
        f.bVector = CIVector(x: 0, y: 0, z: index == 2 ? 1 : 0, w: 0)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        f.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return f.outputImage ?? image
    }

    // MARK: Camera

    /// Zooms about the centre, then shifts by the offset (normalised, y down).
    /// The zoom is raised so the shifted frame never shows an empty edge.
    static func camera(_ image: CIImage, offsetX: Double, offsetY: Double, zoom: Double, extent: CGRect) -> CIImage {
        let minimumZoom = 1 + max(abs(offsetX), abs(offsetY)) * 2
        let z = CGFloat(max(zoom, minimumZoom, 1))
        let t = CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
            .concatenating(CGAffineTransform(scaleX: z, y: z))
            .concatenating(CGAffineTransform(
                translationX: extent.midX + CGFloat(offsetX) * extent.width,
                y: extent.midY - CGFloat(offsetY) * extent.height
            ))
        // Clamping first keeps edge pixels opaque when the zoom exactly covers
        // the offset and linear sampling would otherwise reach past the edge.
        return image.clampedToExtent().transformed(by: t).cropped(to: extent)
    }

    // MARK: Building blocks

    static func screen(_ layer: CIImage, over background: CIImage) -> CIImage {
        let f = CIFilter.screenBlendMode()
        f.inputImage = layer
        f.backgroundImage = background
        return f.outputImage ?? background
    }

    static func maximum(_ a: CIImage, _ b: CIImage) -> CIImage {
        let f = CIFilter.maximumCompositing()
        f.inputImage = a
        f.backgroundImage = b
        return f.outputImage ?? a
    }

    /// Multiplies rgb by `k`, leaving alpha alone.
    static func gain(_ image: CIImage, _ k: Double) -> CIImage {
        let v = CGFloat(k)
        let f = CIFilter.colorMatrix()
        f.inputImage = image
        f.rVector = CIVector(x: v, y: 0, z: 0, w: 0)
        f.gVector = CIVector(x: 0, y: v, z: 0, w: 0)
        f.bVector = CIVector(x: 0, y: 0, z: v, w: 0)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        f.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return f.outputImage ?? image
    }

    /// SplitMix64-style hash of a frame number and seed.
    static func hash(_ n: Int64, _ seed: UInt64) -> UInt64 {
        var h = (UInt64(bitPattern: n) &* 0x9E3779B97F4A7C15) ^ seed
        h ^= h >> 31
        h &*= 0xBF58476D1CE4E5B9
        h ^= h >> 29
        h &*= 0x94D049BB133111EB
        h ^= h >> 32
        return h
    }

    /// A hash mapped to 0..<1.
    static func unit(_ h: UInt64) -> Double {
        Double(h >> 11) / Double(UInt64(1) << 53)
    }
}
