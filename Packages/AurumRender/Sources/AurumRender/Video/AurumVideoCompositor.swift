import AVFoundation
import CoreImage
import AurumCore

/// Draws every video frame: clip frames (or stills with gentle motion),
/// transitions, the look stack, animated effects, timed layers, intro and
/// outro cards, and the free-tier watermark.
///
/// AVFoundation creates this class itself and calls it on its own queues, so
/// it holds no state beyond a CIContext and a small layer cache.
public final class AurumVideoCompositor: NSObject, AVVideoCompositing {
    private let context = CIContext(options: [.cacheIntermediates: false, .priorityRequestLow: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let layerCache = NSCache<NSString, CIImage>()

    public var sourcePixelBufferAttributes: [String: Any]? {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    public var requiredPixelBufferAttributesForRenderContext: [String: Any] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? AurumCompositionInstruction,
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "AurumVideoCompositor", code: 1))
            return
        }
        let t = request.compositionTime.seconds
        let image = Self.frame(at: t, instruction: instruction, sourceFrame: { request.sourceFrame(byTrackID: $0) }, layerCache: layerCache)
        context.render(image, to: output, bounds: CGRect(origin: .zero, size: instruction.renderSize), colorSpace: colorSpace)
        request.finish(withComposedVideoFrame: output)
    }

    public func cancelAllPendingVideoCompositionRequests() {}

    // MARK: Frame assembly

    /// Builds the frame at time t. Static and free of AVFoundation request
    /// types (frames come through `sourceFrame`) so it can be tested.
    static func frame(at t: Seconds, instruction: AurumCompositionInstruction, sourceFrame: (CMPersistentTrackID) -> CVPixelBuffer?, layerCache: NSCache<NSString, CIImage>? = nil) -> CIImage {
        let project = instruction.project
        let size = instruction.renderSize
        let canvas = CGRect(origin: .zero, size: size)
        let black = CIImage(color: .black).cropped(to: canvas)

        var image: CIImage
        let introLength = project.intro?.duration ?? 0
        let clipsEnd = project.duration - (project.outro?.duration ?? 0)
        if let intro = project.intro, t < introLength {
            image = BookendRenderer.render(intro, isIntro: true, progress: t / max(intro.duration, 0.01), size: size)
        } else if let outro = project.outro, t >= clipsEnd {
            image = BookendRenderer.render(outro, isIntro: false, progress: (t - clipsEnd) / max(outro.duration, 0.01), size: size)
        } else {
            image = clipsFrame(at: t, instruction: instruction, sourceFrame: sourceFrame) ?? black
            image = instruction.graph.apply(instruction.gradeDocument, to: image).cropped(to: canvas)
            image = EffectRenderer.apply(project.effects, at: t, to: image)
        }

        // Layers and watermark go on top of everything, including bookends.
        if let overlay = layers(at: t, project: project, size: size, watermark: instruction.watermark, cache: layerCache) {
            image = overlay.composited(over: image)
        }
        return image.composited(over: black).cropped(to: canvas)
    }

    /// The clip picture at t, blending into the next clip during a transition.
    static func clipsFrame(at t: Seconds, instruction: AurumCompositionInstruction, sourceFrame: (CMPersistentTrackID) -> CVPixelBuffer?) -> CIImage? {
        let project = instruction.project
        guard let (index, local) = project.clip(at: t) else { return nil }
        let clip = project.clips[index]
        guard let current = picture(of: clip, local: local, instruction: instruction, sourceFrame: sourceFrame) else { return nil }

        let transition = clip.transitionIn
        let overlap = transition.duration
        guard index > 0, overlap > 0, local < overlap else { return current }
        let previous = project.clips[index - 1]
        let previousLocal = previous.duration - (overlap - local)
        guard let outgoing = picture(of: previous, local: previousLocal, instruction: instruction, sourceFrame: sourceFrame) else { return current }
        let p = local / overlap
        return TransitionRenderer.blend(from: outgoing, to: current, progress: p, transition: transition, size: instruction.renderSize)
    }

    /// One clip's frame, filling the canvas (aspect fill), with still motion for photos.
    static func picture(of clip: Clip, local: Seconds, instruction: AurumCompositionInstruction, sourceFrame: (CMPersistentTrackID) -> CVPixelBuffer?) -> CIImage? {
        let size = instruction.renderSize
        switch instruction.sources[clip.id] {
        case .track(let id, let transform, let natural)?:
            guard let buffer = sourceFrame(id) else { return nil }
            var image = CIImage(cvPixelBuffer: buffer)
            // Apply the recording orientation, then move back to the origin.
            if !transform.isIdentity {
                image = image.transformed(by: transform)
                image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            }
            _ = natural
            return aspectFill(image, size: size, scale: 1, dx: 0, dy: 0)
        case .still(let still)?:
            let motion = StillMotion.pushIn
            let m = motion.transform(at: local / max(clip.duration, 0.01))
            return aspectFill(still, size: size, scale: m.scale, dx: m.dx, dy: m.dy)
        case nil:
            return nil
        }
    }

    static func aspectFill(_ image: CIImage, size: CGSize, scale extra: Double, dx: Double, dy: Double) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return image }
        let s = max(size.width / e.width, size.height / e.height) * CGFloat(extra)
        let w = e.width * s, h = e.height * s
        let tx = (size.width - w) / 2 + CGFloat(dx) * size.width
        let ty = (size.height - h) / 2 + CGFloat(dy) * size.height
        return image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
            .transformed(by: CGAffineTransform(translationX: tx, y: ty))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Timed layers at t, with their in/out animation, plus the watermark.
    static func layers(at t: Seconds, project: VideoProject, size: CGSize, watermark: String?, cache: NSCache<NSString, CIImage>?) -> CIImage? {
        var visible: [Overlay] = []
        var keyParts: [String] = []
        for layer in project.layers where layer.isVisible(at: t) && !layer.overlay.isHidden {
            let presence = layer.presence(at: t)
            var o = layer.overlay
            let entering = t - layer.start < layer.end - t
            let animation = entering ? layer.animationIn : layer.animationOut
            let eased = 1 - pow(1 - presence, 3)
            switch animation {
            case .none: break
            case .fade, .shimmer, .typewriter: o.opacity *= eased
            case .rise: o.opacity *= eased; o.center.y += (1 - eased) * 0.05
            case .drop: o.opacity *= eased; o.center.y -= (1 - eased) * 0.05
            case .zoom: o.opacity *= eased; o.scale *= 0.8 + 0.2 * eased
            }
            if animation == .typewriter, case .text(var text) = o.content, presence < 1 {
                let count = Int((Double(text.text.count) * presence).rounded(.up))
                text.text = String(text.text.prefix(count))
                o.content = .text(text)
                o.opacity = layer.overlay.opacity
            }
            visible.append(o)
            // Quantise for the cache key: fully shown layers reuse one image.
            keyParts.append("\(o.id.uuidString):\(Int(o.opacity * 100)):\(Int(o.center.y * 1000)):\(Int(o.scale * 100)):\(o.content)")
        }
        guard !visible.isEmpty || watermark != nil else { return nil }
        let key = (keyParts.joined(separator: "|") + "|\(watermark ?? "")|\(Int(size.width))") as NSString
        if let cached = cache?.object(forKey: key) { return cached }
        guard let image = OverlayRasterizer.render(visible, canvasSize: size, watermark: watermark) else { return nil }
        cache?.setObject(image, forKey: key)
        return image
    }
}

/// Clip-to-clip transitions.
enum TransitionRenderer {
    static func blend(from a: CIImage, to b: CIImage, progress p: Double, transition: Transition, size: CGSize) -> CIImage {
        let p = (0.0...1.0).clamp(p)
        let canvas = CGRect(origin: .zero, size: size)
        switch transition {
        case .cut:
            return b
        case .dissolve:
            return dissolve(a, b, p)
        case .dipToBlack:
            let black = CIImage(color: .black).cropped(to: canvas)
            return p < 0.5 ? dissolve(a, black, p * 2) : dissolve(black, b, (p - 0.5) * 2)
        case .slide:
            let eased = p * p * (3 - 2 * p)
            let offset = CGFloat(eased) * size.width
            let outgoing = a.transformed(by: CGAffineTransform(translationX: -offset, y: 0))
            let incoming = b.transformed(by: CGAffineTransform(translationX: size.width - offset, y: 0))
            return incoming.composited(over: outgoing).cropped(to: canvas)
        case .zoom:
            let s = 1 + 0.25 * CGFloat(p)
            let zoomed = a.transformed(by: CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2))
                .transformed(by: CGAffineTransform(scaleX: s, y: s))
                .transformed(by: CGAffineTransform(translationX: size.width / 2, y: size.height / 2))
                .cropped(to: canvas)
            return dissolve(zoomed, b, p)
        }
    }

    static func dissolve(_ a: CIImage, _ b: CIImage, _ t: Double) -> CIImage {
        let f = CIFilter(name: "CIDissolveTransition")!
        f.setValue(a, forKey: kCIInputImageKey)
        f.setValue(b, forKey: kCIInputTargetImageKey)
        f.setValue(t, forKey: kCIInputTimeKey)
        return f.outputImage ?? b
    }
}

/// Intro and outro cards. Each preset maps to one of a few elegant moves on
/// an onyx card with the project's title (or the brand monogram).
enum BookendRenderer {
    static func render(_ bookend: BookendEffect, isIntro: Bool, progress: Double, size: CGSize) -> CIImage {
        let canvas = CGRect(origin: .zero, size: size)
        let p = (0.0...1.0).clamp(progress)
        let onyx = CIImage(color: CIColor(red: 0.043, green: 0.043, blue: 0.047)).cropped(to: canvas)
        // Fade the card in at the start of an outro and out at the end of an intro.
        let alpha = isIntro ? min(1, (1 - p) * 4) : min(1, p * 4)
        let title = bookend.title ?? (isIntro ? "" : "AURUM")
        var card = onyx
        if !title.isEmpty, let text = titleImage(title, size: size, presetID: bookend.presetID, progress: p) {
            card = text.composited(over: card)
        }
        if let rule = goldRule(size: size, progress: isIntro ? p : 1 - p) {
            card = rule.composited(over: card)
        }
        let f = CIFilter(name: "CIColorMatrix")!
        f.setValue(card, forKey: kCIInputImageKey)
        f.setValue(CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha)), forKey: "inputAVector")
        return (f.outputImage ?? card).cropped(to: canvas)
    }

    /// A thin champagne line that draws across the card.
    static func goldRule(size: CGSize, progress: Double) -> CIImage? {
        let width = size.width * 0.4 * CGFloat(min(1, progress * 1.5))
        guard width > 1 else { return nil }
        let rect = CGRect(x: (size.width - width) / 2, y: size.height * 0.44, width: width, height: max(1, size.width / 540))
        return CIImage(color: CIColor(red: 0.788, green: 0.659, blue: 0.416)).cropped(to: rect)
    }

    static func titleImage(_ title: String, size: CGSize, presetID: String, progress: Double) -> CIImage? {
        var text = TextOverlay(text: title, fontID: "playfair.italic", size: 88, colorHex: "#F4EFE6", style: .plain)
        if presetID == "spotlight" || presetID == "fireworks" { text.style = .glow }
        let rise = (1 - min(1, progress * 2)) * 0.02
        let overlay = Overlay(content: .text(text), center: NormalizedPoint(x: 0.5, y: 0.5 + rise))
        return OverlayRasterizer.render([overlay], canvasSize: size, watermark: nil)
    }
}
