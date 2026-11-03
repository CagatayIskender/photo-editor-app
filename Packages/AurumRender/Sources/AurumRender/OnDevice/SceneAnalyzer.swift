import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import AurumCore

/// Looks at a photo once, on device, to suggest one-tap fixes: faces and
/// their brightness, how much of the frame people fill, the horizon's tilt,
/// a colour cast, red eyes and Vision's scene labels.
public enum SceneAnalyzer {
    public struct Result: @unchecked Sendable {
        public var analysis: SceneAnalysis
        /// The person matte at the photo's size, reused by the tools that need it.
        public var personMask: CIImage?
    }

    /// Longest side Vision's horizon and scene requests look at.
    static let visionSide: CGFloat = 1024

    public static func analyze(_ image: CIImage, context: CIContext) -> Result {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { return Result(analysis: SceneAnalysis(), personMask: nil) }

        var analysis = SceneAnalysis()

        // Horizon and scene labels, on a smaller copy.
        let small = downscaled(image, longestSide: visionSide)
        let horizon = VNDetectHorizonRequest()
        let classify = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(ciImage: small, options: [:])
        try? handler.perform([horizon, classify])
        if let observation = horizon.results?.first {
            analysis.horizonDegrees = Double(observation.angle) * 180 / Double.pi
        }
        let observations = (classify.results ?? []).filter { $0.confidence >= 0.1 }
        let sorted = observations.sorted { $0.confidence > $1.confidence }
        analysis.labels = sorted.prefix(5).map { SceneLabel(identifier: $0.identifier, confidence: Double($0.confidence)) }

        // Faces, and how bright they are.
        let faces = (try? FaceDetector.detect(in: image)) ?? []
        analysis.faces = faces
        if !faces.isEmpty {
            var total = 0.0
            var count = 0.0
            for face in faces {
                if let avg = averageSRGB(image, in: rect(for: face.bounds, in: extent), context: context) {
                    total += luminance(avg)
                    count += 1
                }
            }
            if count > 0 { analysis.faceLuminance = total / count }
            analysis.redEyeLikely = hasRedEye(image, faces: faces, context: context)
        }

        // People.
        let mask = try? OnDeviceImaging.personMask(for: image, accurate: false)
        if let mask, let avg = averageSRGB(mask, in: extent, context: context) {
            analysis.personCoverage = avg[0]
        }

        // Overall brightness and warmth.
        let stats = overallStats(image, context: context)
        analysis.luminance = stats.luminance
        analysis.warmth = stats.warmth

        return Result(analysis: analysis, personMask: mask)
    }

    /// True when Core Image's red-eye correction changes the eyes noticeably.
    static func hasRedEye(_ image: CIImage, faces: [FaceGeometry], context: CIContext) -> Bool {
        let filters = image.autoAdjustmentFilters(options: [.enhance: false, .redEye: true])
        guard !filters.isEmpty else { return false }
        let corrected = OnDeviceImaging.applyChain(filters, to: image)
        let difference = CIFilter.differenceBlendMode()
        difference.inputImage = corrected
        difference.backgroundImage = image
        guard let diff = difference.outputImage else { return false }
        let extent = image.extent
        for face in faces {
            for region in [FaceGeometry.Region.leftEye, FaceGeometry.Region.rightEye] {
                guard let points = face.regions[region], !points.isEmpty else { continue }
                let box = eyeBox(points)
                guard let avg = averageSRGB(diff, in: rect(for: box, in: extent), context: context) else { continue }
                if max(avg[0], max(avg[1], avg[2])) > 0.04 { return true }
            }
        }
        return false
    }

    /// The box around an eye's landmark points, grown so the pupil is inside.
    static func eyeBox(_ points: [AurumCore.NormalizedPoint]) -> AurumCore.NormalizedRect {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let minX = xs.min() ?? 0
        let maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0
        let maxY = ys.max() ?? 0
        let w = maxX - minX
        let pad = w * 0.2
        let h = max(maxY - minY, w * 0.5)
        let cy = (minY + maxY) / 2
        return AurumCore.NormalizedRect(x: minX - pad, y: cy - h / 2 - pad, width: w + pad * 2, height: h + pad * 2)
    }

    /// A normalised (top-left origin) rect in Core Image coordinates.
    static func rect(for r: AurumCore.NormalizedRect, in extent: CGRect) -> CGRect {
        let x = extent.minX + CGFloat(r.x) * extent.width
        let y = extent.minY + CGFloat(1 - r.y - r.height) * extent.height
        return CGRect(x: x, y: y, width: CGFloat(r.width) * extent.width, height: CGFloat(r.height) * extent.height)
    }

    /// Average r, g, b (0...1, sRGB-encoded) inside `rect`.
    static func averageSRGB(_ image: CIImage, in rect: CGRect, context: CIContext) -> [Double]? {
        let r = rect.intersection(image.extent)
        guard !r.isEmpty, !r.isInfinite, r.width >= 1, r.height >= 1 else { return nil }
        let f = CIFilter.areaAverage()
        f.inputImage = image
        f.extent = r
        guard let out = f.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        let pixel = CGRect(x: out.extent.minX, y: out.extent.minY, width: 1, height: 1)
        context.render(out, toBitmap: &px, rowBytes: 4, bounds: pixel, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return [Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255]
    }

    static func luminance(_ rgb: [Double]) -> Double {
        0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
    }

    /// Luminance and warmth from a 16 × 16 thumbnail (the same measure the
    /// Studio uses to suggest looks).
    static func overallStats(_ image: CIImage, context: CIContext) -> ImageStats {
        let side: CGFloat = 16
        let e = image.extent
        let small = image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: side / e.width, y: side / e.height))
        var px = [UInt8](repeating: 0, count: Int(side * side) * 4)
        context.render(small, toBitmap: &px, rowBytes: Int(side) * 4, bounds: CGRect(x: 0, y: 0, width: side, height: side), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return RenderEngine.stats(fromRGBA: px)
    }

    static func downscaled(_ image: CIImage, longestSide: CGFloat) -> CIImage {
        let e = image.extent
        let longest = max(e.width, e.height)
        guard longest > longestSide else { return image }
        let s = longestSide / longest
        return image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
    }
}
