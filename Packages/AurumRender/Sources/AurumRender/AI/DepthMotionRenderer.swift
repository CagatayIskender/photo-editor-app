import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Metal
import AurumCore

/// A depth map the size of its photo: white is near, black is far.
public struct DepthMap: @unchecked Sendable {
    public let image: CIImage
    /// True when the depth was guessed from the person matte rather than read
    /// from the photo (Portrait mode and dual-camera photos carry real depth).
    public let isEstimated: Bool

    public init(image: CIImage, isEstimated: Bool) {
        self.image = image
        self.isEstimated = isEstimated
    }
}

/// Finds depth for a 3D photo move.
public enum DepthEstimator {
    /// The disparity a Portrait or dual-camera photo carries, upright, or nil.
    public static func embeddedDisparity(in data: Data) -> CIImage? {
        CIImage(data: data, options: [.auxiliaryDisparity: true, .applyOrientationProperty: true])
    }

    public static func embeddedDisparity(at url: URL) -> CIImage? {
        CIImage(contentsOf: url, options: [.auxiliaryDisparity: true, .applyOrientationProperty: true])
    }

    /// Real depth when `disparity` is given and matches the photo's shape,
    /// otherwise a pseudo-depth: the person near, the rest far, with the lower
    /// part of the frame (usually the ground) a little nearer than the top.
    public static func depth(for image: CIImage, disparity: CIImage?, context: CIContext) -> DepthMap {
        let extent = image.extent
        if let disparity, let normalized = normalize(disparity, to: extent, context: context) {
            return DepthMap(image: normalized, isEstimated: false)
        }
        let shortSide = min(extent.width, extent.height)
        // Ground plane: 0.35 at the bottom fading to 0 at the top.
        let ground = CIFilter.linearGradient()
        ground.point0 = CGPoint(x: extent.midX, y: extent.minY)
        ground.point1 = CGPoint(x: extent.midX, y: extent.minY + extent.height * 0.7)
        ground.color0 = CIColor(red: 0.35, green: 0.35, blue: 0.35)
        ground.color1 = CIColor(red: 0, green: 0, blue: 0)
        var depth = (ground.outputImage ?? CIImage(color: .black)).cropped(to: extent)
        if let person = try? OnDeviceAI.personMask(for: image, accurate: false) {
            let maxed = CIFilter.maximumCompositing()
            maxed.inputImage = person
            maxed.backgroundImage = depth
            depth = maxed.outputImage ?? depth
        }
        // Soft edges keep the layers from tearing at the outline.
        return DepthMap(image: OnDeviceAI.blur(depth, radius: Double(shortSide) * 0.01), isEstimated: true)
    }

    /// Scales disparity to 0...1 and to the photo's extent. Nil when the map
    /// doesn't match the photo's aspect (for example a cropped edit) or is flat.
    static func normalize(_ disparity: CIImage, to extent: CGRect, context: CIContext) -> CIImage? {
        let d = OnDeviceAI.gray(disparity)
        let e = d.extent
        guard e.width > 0, e.height > 0, extent.height > 0, !e.isInfinite else { return nil }
        let ratioA = e.width / e.height, ratioB = extent.width / extent.height
        guard abs(ratioA - ratioB) / ratioB < 0.04 else { return nil }

        func sample(_ name: String) -> Float? {
            guard let f = CIFilter(name: name) else { return nil }
            f.setValue(d, forKey: kCIInputImageKey)
            f.setValue(CIVector(cgRect: e), forKey: kCIInputExtentKey)
            guard let out = f.outputImage else { return nil }
            var px = [Float](repeating: 0, count: 4)
            let pixel = CGRect(x: out.extent.minX, y: out.extent.minY, width: 1, height: 1)
            context.render(out, toBitmap: &px, rowBytes: 16, bounds: pixel, format: .RGBAf, colorSpace: nil)
            return px[0]
        }
        guard let lo = sample("CIAreaMinimum"), let hi = sample("CIAreaMaximum"), hi - lo > 1e-4 else { return nil }
        let scale = CGFloat(1 / (hi - lo))
        let bias = CGFloat(-lo) * scale
        let m = CIFilter.colorMatrix()
        m.inputImage = d
        m.rVector = CIVector(x: scale, y: 0, z: 0, w: 0)
        m.gVector = CIVector(x: 0, y: scale, z: 0, w: 0)
        m.bVector = CIVector(x: 0, y: 0, z: scale, w: 0)
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        m.biasVector = CIVector(x: bias, y: bias, z: bias, w: 0)
        let normalized = (m.outputImage ?? d)
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: extent.width / e.width, y: extent.height / e.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        return normalized.cropped(to: extent)
    }
}

/// Renders a 3D photo move: the photo is split into a near layer and a far
/// layer by depth, and each moves by a different amount as the virtual camera
/// follows a `DepthMotion` sample (parallax). Where the near layer uncovers
/// the background, the gap is filled with a blurred, clamped copy of the
/// surroundings rather than a hard edge.
public struct DepthMotionRenderer: @unchecked Sendable {
    public let image: CIImage
    public let depth: DepthMap
    /// Near-layer matte (white = near), prepared once.
    let nearMask: CIImage
    /// The far layer with the near subject softly painted out.
    let farLayer: CIImage

    /// How strongly a layer's depth difference from the focus turns into movement.
    static let parallaxGain: Double = 2.4
    /// Depth of the near and far layers, 0 nearest, 1 farthest (DepthMotion's convention).
    static let nearDepth = 0.15
    static let farDepth = 0.85

    public init(image: CIImage, depth: DepthMap) {
        let extent = image.extent
        let origin = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        let base = image.transformed(by: origin)
        // The depth may come from a smaller proxy: stretch it over the photo.
        let de = depth.image.extent
        var depthImage = depth.image
        if de.width > 0, de.height > 0, !de.isInfinite {
            depthImage = depthImage
                .transformed(by: CGAffineTransform(translationX: -de.minX, y: -de.minY))
                .transformed(by: CGAffineTransform(scaleX: extent.width / de.width, y: extent.height / de.height))
                .cropped(to: CGRect(origin: .zero, size: extent.size))
        }
        self.image = base
        self.depth = DepthMap(image: depthImage, isEstimated: depth.isEstimated)
        let rect = base.extent
        let shortSide = Double(min(rect.width, rect.height))

        // Soft threshold around the middle: near = clamp((d - 0.5) * 4 + 0.5).
        let threshold = CIFilter.colorMatrix()
        threshold.inputImage = depthImage
        threshold.rVector = CIVector(x: 4, y: 0, z: 0, w: 0)
        threshold.gVector = CIVector(x: 0, y: 4, z: 0, w: 0)
        threshold.bVector = CIVector(x: 0, y: 0, z: 4, w: 0)
        threshold.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        threshold.biasVector = CIVector(x: -1.5, y: -1.5, z: -1.5, w: 0)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = threshold.outputImage ?? depthImage
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        let near = (clamp.outputImage ?? depthImage).cropped(to: rect)
        self.nearMask = near

        // Grow the matte a little and fill under it with a heavy blur of the
        // surroundings, so moving the subject never reveals a copy of itself.
        let grow = CIFilter.morphologyMaximum()
        grow.inputImage = near.clampedToExtent()
        grow.radius = Float(shortSide * 0.025)
        let grown = OnDeviceAI.blur((grow.outputImage ?? near).cropped(to: rect), radius: shortSide * 0.01)
        let fill = OnDeviceAI.blur(base, radius: shortSide * 0.05)
        self.farLayer = OnDeviceAI.blend(fill, over: base, mask: grown).cropped(to: rect)
    }

    /// One frame of the move, the size of the photo.
    public func frame(_ sample: DepthMotion.Sample) -> CIImage {
        let rect = image.extent
        let far = layer(farLayer, depth: Self.farDepth, sample: sample, focus: sample.focusDepth)
        let nearMoved = layer(image, depth: Self.nearDepth, sample: sample, focus: sample.focusDepth)
        let maskMoved = layer(nearMask, depth: Self.nearDepth, sample: sample, focus: sample.focusDepth)
        // A touch of blur on whichever layer is away from the focus.
        let farBlur = max(0, Self.farDepth - sample.focusDepth - 0.3) * Double(min(rect.width, rect.height)) * 0.006
        let farFinal = farBlur > 0.5 ? OnDeviceAI.blur(far, radius: farBlur) : far
        return OnDeviceAI.blend(nearMoved, over: farFinal, mask: maskMoved).cropped(to: rect)
    }

    /// The move at time `t` of a loop lasting `duration`.
    public func frame(motion: DepthMotion, at t: Seconds, duration: Seconds) -> CIImage {
        frame(motion.sample(at: t, duration: duration))
    }

    /// Zooms about the centre and shifts by the camera offset scaled by the
    /// layer's distance from the focus. Edges are filled by clamping.
    func layer(_ layer: CIImage, depth: Double, sample: DepthMotion.Sample, focus: Double) -> CIImage {
        let rect = image.extent
        let parallax = (focus - depth) * Self.parallaxGain
        let dx = CGFloat(sample.dx * parallax) * rect.width
        let dy = CGFloat(sample.dy * parallax) * rect.height
        // Near layers grow a little faster with zoom, which reads as depth too.
        let nearness: Double = max(0.0, focus - depth)
        let zoomAmount: Double = (sample.zoom - 1.0) * (1.0 + nearness)
        let zoom = CGFloat(1.0 + zoomAmount)
        let t = CGAffineTransform(translationX: -rect.midX, y: -rect.midY)
            .concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
            .concatenating(CGAffineTransform(translationX: rect.midX - dx, y: rect.midY + dy))
        return layer.clampedToExtent().transformed(by: t).cropped(to: rect)
    }
}

/// Writes a looping 3D photo move as an H.264 MP4.
public enum DepthMotionExporter {
    public enum ExportError: Error {
        case cannotCreateWriter
        case noPixelBuffer
        case writerFailed(Error?)
    }

    public static let frameRate: Int32 = 30

    /// Renders `duration` seconds (clamped to 3...6) at `size` (aspect fill,
    /// rounded to even pixels) and writes them to `url`. `overlay`, such as the
    /// free watermark, is composited on every frame.
    public static func export(image: CIImage, depth: DepthMap, motion: DepthMotion, duration: Seconds, size: CGSize, overlay: CIImage? = nil, to url: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let width = max(2, Int(size.width) / 2 * 2)
        let height = max(2, Int(size.height) / 2 * 2)
        let length = min(max(duration, 3), 6)
        let renderer = DepthMotionRenderer(image: image, depth: depth)
        let context: CIContext = {
            if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device) }
            return CIContext()
        }()

        try? FileManager.default.removeItem(at: url)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mp4) } catch { throw ExportError.cannotCreateWriter }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * 6,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ] as [String: Any]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ])
        guard writer.canAdd(input) else { throw ExportError.cannotCreateWriter }
        writer.add(input)
        guard writer.startWriting() else { throw ExportError.writerFailed(writer.error) }
        writer.startSession(atSourceTime: .zero)

        let outRect = CGRect(x: 0, y: 0, width: width, height: height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        let frames = Int(length * Double(frameRate))
        for index in 0..<frames {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw ExportError.noPixelBuffer }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw ExportError.noPixelBuffer }

            let t = Double(index) / Double(frameRate)
            var frame = OnDeviceAI.aspectFill(renderer.frame(motion: motion, at: t, duration: length), to: outRect)
            if let overlay { frame = overlay.composited(over: frame) }
            context.render(frame, to: buffer, bounds: outRect, colorSpace: colorSpace)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: frameRate))
            progress(Double(index + 1) / Double(frames))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw ExportError.writerFailed(writer.error) }
    }
}

/// Renders preview frames of a move to `CGImage`s, off the main thread.
public actor DepthMotionPreviewer {
    private let context: CIContext
    private var renderer: DepthMotionRenderer?

    public init() {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: true])
        } else {
            context = CIContext()
        }
    }

    /// Estimates depth for a preview-size image and prepares the layers.
    /// Returns whether real (embedded) depth was used.
    @discardableResult
    public func prepare(image: CIImage, disparity: CIImage?) -> Bool {
        let depth = DepthEstimator.depth(for: image, disparity: disparity, context: context)
        renderer = DepthMotionRenderer(image: image, depth: depth)
        return !depth.isEstimated
    }

    /// The depth map used, for export at a larger size.
    public var depth: DepthMap? { renderer?.depth }

    public func frame(motion: DepthMotion, at t: Seconds, duration: Seconds) -> CGImage? {
        guard let renderer else { return nil }
        let image = renderer.frame(motion: motion, at: t, duration: duration)
        return context.createCGImage(image, from: image.extent)
    }
}
