import CoreImage
import CoreImage.CIFilterBuiltins
import AurumCore

/// Renders a `CollageProject` with Core Image. Layout rects are normalised
/// with a top-left origin (as everywhere in Aurum); Core Image is bottom-left,
/// so every rect is flipped here and nowhere else.
public enum CollageRenderer {
    /// Canvas size for a layout, with the longest side `longestSide` pixels.
    public static func canvasSize(for layout: CollageLayout, longestSide: CGFloat) -> CGSize {
        let r = CGFloat(layout.canvasRatio)
        return r >= 1
            ? CGSize(width: longestSide.rounded(), height: (longestSide / r).rounded())
            : CGSize(width: (longestSide * r).rounded(), height: longestSide.rounded())
    }

    /// The collage at `canvasSize`. `images` lines up with `project.cells`;
    /// a missing image leaves its cell showing the background.
    public static func render(_ project: CollageProject, images: [CIImage?], canvasSize: CGSize) -> CIImage {
        let canvas = CGRect(origin: .zero, size: canvasSize)
        var output = CIImage(color: color(hex: project.backgroundHex)).cropped(to: canvas)
        let radius = CGFloat(project.cornerRadius) * min(canvasSize.width, canvasSize.height)
        for (index, frame) in project.frames.enumerated() {
            guard project.cells.indices.contains(index), let cell = project.cells[index],
                  images.indices.contains(index), let image = images[index] else { continue }
            let rect = ciRect(frame, in: canvasSize)
            guard rect.width >= 1, rect.height >= 1 else { continue }
            var placed = place(image, in: rect, zoom: cell.zoom, center: cell.center)
            if radius > 0.5, let mask = roundedMask(rect, radius: min(radius, min(rect.width, rect.height) / 2)) {
                let clip = CIFilter.sourceInCompositing()
                clip.inputImage = placed
                clip.backgroundImage = mask
                placed = clip.outputImage ?? placed
            }
            output = placed.composited(over: output)
        }
        return output.cropped(to: canvas)
    }

    /// A normalised, top-left rect in canvas pixels with Core Image's bottom-left origin.
    static func ciRect(_ r: NormalizedRect, in size: CGSize) -> CGRect {
        CGRect(
            x: CGFloat(r.x) * size.width,
            y: CGFloat(1 - r.y - r.height) * size.height,
            width: CGFloat(r.width) * size.width,
            height: CGFloat(r.height) * size.height
        ).integral
    }

    /// Fills `rect` with the image at `zoom` (1 = aspect fill), centred on
    /// `center` (normalised image coordinates, top-left origin). The centre is
    /// clamped so the cell is always covered.
    static func place(_ image: CIImage, in rect: CGRect, zoom: Double, center: NormalizedPoint) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0, !e.isInfinite else { return image.cropped(to: rect) }
        let s = max(rect.width / e.width, rect.height / e.height) * CGFloat(max(1, zoom))
        let halfW = rect.width / s / 2, halfH = rect.height / s / 2
        // In image pixels, bottom-left origin.
        let px = min(max(CGFloat(center.x) * e.width, halfW), e.width - halfW)
        let py = min(max(CGFloat(1 - center.y) * e.height, halfH), e.height - halfH)
        let t = CGAffineTransform(translationX: -e.minX - px, y: -e.minY - py)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))
        return image.clampedToExtent().transformed(by: t).cropped(to: rect)
    }

    /// A white rounded rectangle, or nil if the generator is unavailable
    /// (the cell is then drawn with square corners).
    static func roundedMask(_ rect: CGRect, radius: CGFloat) -> CIImage? {
        guard let f = CIFilter(name: "CIRoundedRectangleGenerator") else { return nil }
        f.setValue(CIVector(cgRect: rect), forKey: "inputExtent")
        f.setValue(radius, forKey: "inputRadius")
        f.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor")
        return f.outputImage?.cropped(to: rect)
    }

    /// "#RRGGBB" as an sRGB colour; black if the text isn't a colour.
    public static func color(hex: String) -> CIColor {
        guard let normalized = CollageProject.normalizedHex(hex),
              let value = UInt32(normalized.dropFirst(), radix: 16) else { return CIColor(red: 0, green: 0, blue: 0) }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        return CIColor(red: r, green: g, blue: b, alpha: 1, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) ?? CIColor(red: r, green: g, blue: b)
    }
}

/// Cuts one wide photo into carousel panels.
public enum CarouselRenderer {
    /// `count` panels of `panelAspect` (width / height), left to right, each
    /// moved to the origin so it can be encoded on its own.
    public static func panels(_ image: CIImage, count: Int, panelAspect: Double) -> [CIImage] {
        let e = image.extent
        guard e.width > 0, e.height > 0, !e.isInfinite else { return [] }
        let rects = Carousel.panels(for: Double(e.width / e.height), count: count, panelAspect: panelAspect)
        return rects.map { r in
            let rect = CGRect(
                x: e.minX + CGFloat(r.x) * e.width,
                y: e.minY + CGFloat(1 - r.y - r.height) * e.height,
                width: CGFloat(r.width) * e.width,
                height: CGFloat(r.height) * e.height
            ).integral.intersection(e)
            return image.cropped(to: rect)
                .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        }
    }
}

extension RenderEngine {
    /// Encodes any rendered image, with an optional watermark, using the
    /// engine's shared context. Used by collages, carousels and Auto Studio results.
    public func encode(_ image: CIImage, format: ExportFormat = .jpeg, watermark: String? = nil, quality: Double = 0.92) throws -> Data {
        var output = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if let mark = OverlayRasterizer.render([], canvasSize: output.extent.size, watermark: watermark) {
            output = mark.composited(over: output)
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let options = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        let data: Data?
        switch format {
        case .jpeg: data = context.jpegRepresentation(of: output, colorSpace: colorSpace, options: options)
        case .heic: data = context.heifRepresentation(of: output, format: .RGBA8, colorSpace: colorSpace, options: options)
        case .png: data = context.pngRepresentation(of: output, format: .RGBA8, colorSpace: colorSpace, options: [:])
        }
        guard let data else { throw ExportError.encodingFailed }
        return data
    }

    /// Renders any image to a `CGImage` for display.
    public func cgImage(_ image: CIImage) -> CGImage? {
        let e = image.extent
        guard !e.isEmpty, !e.isInfinite else { return nil }
        return context.createCGImage(image, from: e)
    }
}
