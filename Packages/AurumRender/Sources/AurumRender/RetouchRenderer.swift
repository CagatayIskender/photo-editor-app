import CoreImage
import CoreImage.CIFilterBuiltins
import AurumCore

/// Face-aware retouching, built as a Core Image recipe like the rest of the
/// filter graph.
///
/// Every adjustment is confined to a soft mask derived from the detected
/// face geometry, so nothing outside a face changes. The aim is a natural
/// result: full strength should still read as a good photo, not a filter.
///
/// Geometry arrives normalised with a top-left origin and is mapped into the
/// image's extent (bottom-left origin) here, so the same faces work on a
/// screen-size proxy and on the full-resolution export.
public enum RetouchRenderer {
    /// Applies the settings to every face. Returns the input unchanged (the
    /// same object) when there are no faces or the settings are neutral.
    public static func apply(_ settings: RetouchSettings, faces: [FaceGeometry], to image: CIImage) -> CIImage {
        guard !faces.isEmpty, !settings.isNeutral else { return image }
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { return image }

        var output = image
        for (index, face) in faces.enumerated() {
            let retouch = settings.settings(forFace: index)
            guard !retouch.isNeutral else { continue }
            let frame = FaceFrame(face: face, extent: extent)
            guard frame.rect.width >= 2, frame.rect.height >= 2 else { continue }
            // Tone first, while the masks still match the geometry; reshape last.
            output = retouchSkinAndFeatures(retouch, frame: frame, image: output)
            output = reshape(retouch, frame: frame, image: output)
        }
        return output.cropped(to: extent)
    }

    // MARK: Skin and features

    static func retouchSkinAndFeatures(_ r: FaceRetouch, frame f: FaceFrame, image input: CIImage) -> CIImage {
        var image = input
        let needsSkin = r.smoothing > 0 || r.blemishRemoval > 0
        let skin = needsSkin ? skinMask(f) : nil

        if r.blemishRemoval > 0, let skin {
            image = removeBlemishes(image, skin: skin, strength: r.blemishRemoval, extent: f.extent)
        }
        if r.smoothing > 0, let skin {
            image = smooth(image, skin: skin, strength: r.smoothing, frame: f)
        }
        if r.underEye > 0 {
            image = brightenUnderEyes(image, strength: r.underEye, frame: f)
        }
        if r.teethWhitening > 0 {
            image = whitenTeeth(image, strength: r.teethWhitening, frame: f)
        }
        if r.eyeBrightening > 0 {
            image = brightenEyes(image, strength: r.eyeBrightening, frame: f)
        }
        return image
    }

    /// The face oval, slightly inset, minus the eyes, eyebrows and lips.
    static func skinMask(_ f: FaceFrame) -> CIImage {
        // Vision's box runs from about the brows to the chin, so the oval is
        // nudged up to take in some forehead.
        let center = f.offset(CGPoint(x: f.rect.midX, y: f.rect.midY), up: f.rect.height * 0.06)
        var mask = ellipse(center: center, radiusX: f.rect.width * 0.46, radiusY: f.rect.height * 0.56, angle: f.roll, softness: 0.45)
        let holes: [(FaceGeometry.Region, CGFloat)] = [
            (.leftEye, 1.7), (.rightEye, 1.7),
            (.leftEyebrow, 1.3), (.rightEyebrow, 1.3),
            (.outerLips, 1.25)
        ]
        for (region, grow) in holes {
            guard let hole = regionEllipse(region, frame: f, grow: grow, softness: 0.6) else { continue }
            mask = multiply(mask, invert(hole))
        }
        return mask.cropped(to: f.extent)
    }

    /// Texture-preserving smoothing: a blur through the skin mask, then a
    /// little of the original fine detail added back so skin keeps its pores.
    static func smooth(_ image: CIImage, skin: CIImage, strength: Double, frame f: FaceFrame) -> CIImage {
        let extent = f.extent
        // About 0.6% of the image width for a face a quarter of the frame wide.
        let sigma = max(0.5, f.rect.width * 0.024 * CGFloat(strength))
        let blurred = gaussianBlur(image, radius: sigma, extent: extent)
        let weight = scaled(skin, by: 0.75 * strength)
        let smoothed = blend(blurred, over: image, mask: weight)

        // detail = original - blur(original, 1.5). Encoded around mid-grey so
        // no intermediate goes negative, then applied with linear light:
        // base + 2 * d - 1 = base + 0.35 * (original - fine).
        let fineRadius = CGFloat(max(1, 1.5 * FilterGraph.scale(of: image)))
        let fine = gaussianBlur(image, radius: fineRadius, extent: extent)
        let a = colorMatrix(image, scale: 0.35, bias: 0.325)
        let b = colorMatrix(fine, scale: -0.35, bias: 0.675)
        let dissolve = CIFilter.dissolveTransition()
        dissolve.inputImage = a
        dissolve.targetImage = b
        dissolve.time = 0.5
        guard let detail = dissolve.outputImage else { return smoothed.cropped(to: extent) }

        let linearLight = CIFilter.linearLightBlendMode()
        linearLight.inputImage = detail
        linearLight.backgroundImage = smoothed
        guard let textured = linearLight.outputImage else { return smoothed.cropped(to: extent) }
        return blend(textured, over: smoothed, mask: weight).cropped(to: extent)
    }

    /// A double 3×3 median removes small spots without moving edges.
    static func removeBlemishes(_ image: CIImage, skin: CIImage, strength: Double, extent: CGRect) -> CIImage {
        var cleaned = image.clampedToExtent()
        for _ in 0..<2 {
            guard let median = CIFilter(name: "CIMedianFilter") else { return image }
            median.setValue(cleaned, forKey: kCIInputImageKey)
            guard let out = median.outputImage else { return image }
            cleaned = out
        }
        return blend(cleaned.cropped(to: extent), over: image, mask: scaled(skin, by: 0.6 * strength)).cropped(to: extent)
    }

    static func brightenUnderEyes(_ image: CIImage, strength: Double, frame f: FaceFrame) -> CIImage {
        var mask: CIImage?
        for eye in [FaceGeometry.Region.leftEye, .rightEye] {
            guard let box = f.box(eye) else { continue }
            let eyeHeight = max(box.height, box.width * 0.35)
            // Centred about 0.6 eye-heights below the lower lid.
            let center = f.offset(CGPoint(x: box.midX, y: box.midY), up: -eyeHeight * 1.1)
            let e = ellipse(center: center, radiusX: box.width * 0.55, radiusY: eyeHeight * 0.5, angle: f.roll, softness: 0.7)
            mask = mask.map { maximum($0, e) } ?? e
        }
        guard let mask else { return image }
        var adjusted = exposure(image, ev: 0.35 * strength)
        adjusted = colorControls(adjusted, saturation: 1 - 0.15 * strength)
        return blend(adjusted, over: image, mask: mask.cropped(to: f.extent)).cropped(to: f.extent)
    }

    static func whitenTeeth(_ image: CIImage, strength: Double, frame f: FaceFrame) -> CIImage {
        guard let mask = regionEllipse(.innerLips, frame: f, grow: 1.0, softness: 0.5, minimumAspect: 0.15) else { return image }
        var adjusted = colorControls(image, saturation: 1 - 0.6 * strength)
        adjusted = exposure(adjusted, ev: 0.25 * strength)
        return blend(adjusted, over: image, mask: mask.cropped(to: f.extent)).cropped(to: f.extent)
    }

    static func brightenEyes(_ image: CIImage, strength: Double, frame f: FaceFrame) -> CIImage {
        var mask: CIImage?
        for eye in [FaceGeometry.Region.leftEye, .rightEye] {
            guard let e = regionEllipse(eye, frame: f, grow: 1.1, softness: 0.5) else { continue }
            mask = mask.map { maximum($0, e) } ?? e
        }
        guard let mask else { return image }
        var adjusted = exposure(image, ev: 0.3 * strength)
        let v = CIFilter.vibrance()
        v.inputImage = adjusted
        v.amount = Float(0.3 * strength)
        adjusted = v.outputImage ?? adjusted
        return blend(adjusted, over: image, mask: mask.cropped(to: f.extent)).cropped(to: f.extent)
    }

    // MARK: Reshape

    /// Gentle local warps with CIBumpDistortion: negative values pinch
    /// (slim or shrink), positive values bulge (enlarge).
    static func reshape(_ r: FaceRetouch, frame f: FaceFrame, image input: CIImage) -> CIImage {
        var image = input
        let w = f.rect.width
        let faceCenter = CGPoint(x: f.rect.midX, y: f.rect.midY)

        if r.jaw != 0 {
            // Centres sit just inside the lower contour, so pinching pulls the
            // jawline in towards the face.
            for p in jawPoints(f) {
                let c = lerp(p, faceCenter, 0.25)
                image = bump(image, center: c, radius: w * 0.28, amount: r.jaw, extent: f.extent)
            }
        }
        if r.cheeks != 0 {
            for c in cheekPoints(f) {
                image = bump(image, center: c, radius: w * 0.2, amount: r.cheeks, extent: f.extent)
            }
        }
        if r.nose != 0 {
            if let box = f.box(.nose) {
                let radius = max(max(box.width, box.height) * 0.7, w * 0.1)
                image = bump(image, center: CGPoint(x: box.midX, y: box.midY), radius: radius, amount: r.nose, extent: f.extent)
            } else {
                let c = CGPoint(x: f.rect.midX, y: f.rect.minY + f.rect.height * 0.45)
                image = bump(image, center: c, radius: w * 0.16, amount: r.nose, extent: f.extent)
            }
        }
        if r.eyes != 0 {
            for eye in [FaceGeometry.Region.leftEye, .rightEye] {
                guard let box = f.box(eye) else { continue }
                let radius = max(box.width * 0.9, w * 0.1)
                image = bump(image, center: CGPoint(x: box.midX, y: box.midY), radius: radius, amount: r.eyes, extent: f.extent)
            }
        }
        if r.lips != 0 {
            if let box = f.box(.outerLips) {
                let radius = max(box.width * 0.65, w * 0.1)
                image = bump(image, center: CGPoint(x: box.midX, y: box.midY), radius: radius, amount: r.lips, extent: f.extent)
            } else {
                let c = CGPoint(x: f.rect.midX, y: f.rect.minY + f.rect.height * 0.22)
                image = bump(image, center: c, radius: w * 0.2, amount: r.lips, extent: f.extent)
            }
        }
        if r.forehead != 0 {
            let brows = [f.box(.leftEyebrow), f.box(.rightEyebrow)].compactMap { $0 }
            let base: CGPoint
            if brows.isEmpty {
                base = CGPoint(x: f.rect.midX, y: f.rect.maxY - f.rect.height * 0.05)
            } else {
                let x = brows.map(\.midX).reduce(0, +) / CGFloat(brows.count)
                let y = brows.map(\.midY).reduce(0, +) / CGFloat(brows.count)
                base = CGPoint(x: x, y: y)
            }
            let c = f.offset(base, up: f.rect.height * 0.15)
            image = bump(image, center: c, radius: w * 0.3, amount: r.forehead, extent: f.extent)
        }
        return image
    }

    /// Two points on the lower face contour, about a fifth of the way in from
    /// each end (Vision's contour runs ear to ear around the chin).
    static func jawPoints(_ f: FaceFrame) -> [CGPoint] {
        if let contour = f.points(.faceContour), contour.count >= 5 {
            let last = contour.count - 1
            let i = Int((Double(last) * 0.2).rounded())
            let j = Int((Double(last) * 0.8).rounded())
            return [contour[i], contour[j]]
        }
        let y = f.rect.minY + f.rect.height * 0.25
        return [CGPoint(x: f.rect.minX + f.rect.width * 0.18, y: y), CGPoint(x: f.rect.maxX - f.rect.width * 0.18, y: y)]
    }

    /// Midpoints between each eye and the mouth corner on the same side.
    static func cheekPoints(_ f: FaceFrame) -> [CGPoint] {
        let eyes = [f.center(.leftEye), f.center(.rightEye)].compactMap { $0 }.sorted { $0.x < $1.x }
        let lips = f.points(.outerLips) ?? []
        if eyes.count == 2, let leftCorner = lips.min(by: { $0.x < $1.x }), let rightCorner = lips.max(by: { $0.x < $1.x }) {
            return [lerp(eyes[0], leftCorner, 0.5), lerp(eyes[1], rightCorner, 0.5)]
        }
        let y = f.rect.minY + f.rect.height * 0.42
        return [CGPoint(x: f.rect.minX + f.rect.width * 0.25, y: y), CGPoint(x: f.rect.maxX - f.rect.width * 0.25, y: y)]
    }

    static func bump(_ image: CIImage, center: CGPoint, radius: CGFloat, amount: Double, extent: CGRect) -> CIImage {
        guard amount != 0, radius > 1 else { return image }
        let f = CIFilter.bumpDistortion()
        f.inputImage = image
        f.center = center
        f.radius = Float(radius)
        f.scale = Float(max(-1, min(amount, 1)) * 0.25)
        return (f.outputImage ?? image).cropped(to: extent)
    }

    // MARK: Masks

    /// A soft elliptical mask: white in the centre fading to black at the
    /// edge, opaque everywhere, so masks can be multiplied and inverted.
    /// `softness` is the fraction of the radius that fades.
    static func ellipse(center: CGPoint, radiusX: CGFloat, radiusY: CGFloat, angle: CGFloat = 0, softness: CGFloat = 0.5) -> CIImage {
        let base: CGFloat = 100
        let g = CIFilter.radialGradient()
        g.center = .zero
        g.radius0 = Float(base * (1 - max(0, min(softness, 1))))
        g.radius1 = Float(base)
        g.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        g.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let gradient = g.outputImage else { return CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)) }
        let t = CGAffineTransform(scaleX: max(radiusX, 0.5) / base, y: max(radiusY, 0.5) / base)
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        return gradient.transformed(by: t)
    }

    /// An ellipse around a landmark region's points, grown by `grow`.
    static func regionEllipse(_ region: FaceGeometry.Region, frame f: FaceFrame, grow: CGFloat, softness: CGFloat, minimumAspect: CGFloat = 0.45) -> CIImage? {
        guard let box = f.box(region) else { return nil }
        let minimum = f.rect.width * 0.02
        let rx = max(box.width / 2 * grow, minimum)
        let ry = max(box.height / 2 * grow, rx * minimumAspect, minimum * 0.5)
        return ellipse(center: CGPoint(x: box.midX, y: box.midY), radiusX: rx, radiusY: ry, angle: f.roll, softness: softness)
    }

    static func multiply(_ a: CIImage, _ b: CIImage) -> CIImage {
        let f = CIFilter.multiplyCompositing()
        f.inputImage = a
        f.backgroundImage = b
        return f.outputImage ?? a
    }

    static func maximum(_ a: CIImage, _ b: CIImage) -> CIImage {
        let f = CIFilter.maximumCompositing()
        f.inputImage = a
        f.backgroundImage = b
        return f.outputImage ?? a
    }

    static func invert(_ image: CIImage) -> CIImage {
        let f = CIFilter.colorInvert()
        f.inputImage = image
        return f.outputImage ?? image
    }

    /// Scales a greyscale mask's value, keeping it opaque.
    static func scaled(_ mask: CIImage, by k: Double) -> CIImage {
        colorMatrix(mask, scale: k, bias: 0)
    }

    // MARK: Building blocks

    /// rgb' = rgb * scale + bias, alpha unchanged.
    static func colorMatrix(_ image: CIImage, scale: Double, bias: Double) -> CIImage {
        let k = CGFloat(scale), c = CGFloat(bias)
        let f = CIFilter.colorMatrix()
        f.inputImage = image
        f.rVector = CIVector(x: k, y: 0, z: 0, w: 0)
        f.gVector = CIVector(x: 0, y: k, z: 0, w: 0)
        f.bVector = CIVector(x: 0, y: 0, z: k, w: 0)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        f.biasVector = CIVector(x: c, y: c, z: c, w: 0)
        return f.outputImage ?? image
    }

    static func blend(_ foreground: CIImage, over background: CIImage, mask: CIImage) -> CIImage {
        let f = CIFilter.blendWithMask()
        f.inputImage = foreground
        f.backgroundImage = background
        f.maskImage = mask
        return f.outputImage ?? background
    }

    static func gaussianBlur(_ image: CIImage, radius: CGFloat, extent: CGRect) -> CIImage {
        let f = CIFilter.gaussianBlur()
        f.inputImage = image.clampedToExtent()
        f.radius = Float(radius)
        return (f.outputImage ?? image).cropped(to: extent)
    }

    static func exposure(_ image: CIImage, ev: Double) -> CIImage {
        guard ev != 0 else { return image }
        let f = CIFilter.exposureAdjust()
        f.inputImage = image
        f.ev = Float(ev)
        return f.outputImage ?? image
    }

    static func colorControls(_ image: CIImage, saturation: Double) -> CIImage {
        let f = CIFilter.colorControls()
        f.inputImage = image
        f.saturation = Float(max(0, saturation))
        f.brightness = 0
        f.contrast = 1
        return f.outputImage ?? image
    }

    static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}

/// A face mapped into an image's extent, in Core Image coordinates
/// (bottom-left origin, pixels).
struct FaceFrame {
    let face: FaceGeometry
    let extent: CGRect
    /// The face bounds in pixels.
    let rect: CGRect
    /// The head's roll from the eye line, in radians (counter-clockwise).
    let roll: CGFloat

    init(face: FaceGeometry, extent: CGRect) {
        self.face = face
        self.extent = extent
        let b = face.bounds
        rect = CGRect(
            x: extent.minX + CGFloat(b.x) * extent.width,
            y: extent.maxY - CGFloat(b.y + b.height) * extent.height,
            width: CGFloat(b.width) * extent.width,
            height: CGFloat(b.height) * extent.height
        )
        var roll: CGFloat = 0
        if let l = face.center(of: .leftEye), let r = face.center(of: .rightEye) {
            let a = Self.map(l, in: extent), b = Self.map(r, in: extent)
            let (left, right) = a.x <= b.x ? (a, b) : (b, a)
            let angle = atan2(right.y - left.y, right.x - left.x)
            // Ignore implausible values from a bad detection.
            if abs(angle) < .pi / 4 { roll = angle }
        }
        self.roll = roll
    }

    /// y_ci = extent.maxY - y * extent.height
    static func map(_ p: NormalizedPoint, in extent: CGRect) -> CGPoint {
        CGPoint(x: extent.minX + CGFloat(p.x) * extent.width, y: extent.maxY - CGFloat(p.y) * extent.height)
    }

    func point(_ p: NormalizedPoint) -> CGPoint {
        Self.map(p, in: extent)
    }

    func points(_ region: FaceGeometry.Region) -> [CGPoint]? {
        guard let pts = face.regions[region], !pts.isEmpty else { return nil }
        return pts.map(point)
    }

    func center(_ region: FaceGeometry.Region) -> CGPoint? {
        face.center(of: region).map(point)
    }

    /// The bounding box of a region's points, in pixels.
    func box(_ region: FaceGeometry.Region) -> CGRect? {
        guard let pts = points(region) else { return nil }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Moves a point along the face's up axis (negative moves down), following the roll.
    func offset(_ p: CGPoint, up distance: CGFloat) -> CGPoint {
        CGPoint(x: p.x - sin(roll) * distance, y: p.y + cos(roll) * distance)
    }
}
