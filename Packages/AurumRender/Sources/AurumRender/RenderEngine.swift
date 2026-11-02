import CoreImage
import Metal
import UIKit
import UniformTypeIdentifiers
import AurumCore

/// Owns the single Metal-backed `CIContext` and renders documents for the
/// preview, thumbnails and export.
///
/// The preview renders from a screen-size proxy and drops stale requests, so
/// dragging a slider only ever renders the latest value.
public actor RenderEngine {
    let context: CIContext
    public private(set) var graph: FilterGraph

    private let thumbnailCache = NSCache<NSString, CGImage>()

    public init(catalog: LookCatalog) {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [
                .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) as Any,
                .cacheIntermediates: false
            ])
        } else {
            context = CIContext(options: [.useSoftwareRenderer: false])
        }
        graph = FilterGraph(catalog: catalog)
        thumbnailCache.countLimit = 400
    }

    public func updateCatalog(_ catalog: LookCatalog) {
        graph = FilterGraph(catalog: catalog)
        thumbnailCache.removeAllObjects()
    }

    // MARK: Proxies

    /// Downscales a source image so its longest side is `maxPixelSize`.
    public nonisolated static func proxy(of image: CIImage, maxPixelSize: CGFloat) -> CIImage {
        let longest = max(image.extent.width, image.extent.height)
        guard longest > maxPixelSize, longest > 0 else { return image }
        let scale = maxPixelSize / longest
        let f = CIFilter(name: "CILanczosScaleTransform")!
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(scale, forKey: kCIInputScaleKey)
        f.setValue(1.0, forKey: kCIInputAspectRatioKey)
        return f.outputImage ?? image
    }

    // MARK: Preview

    /// Renders the document over a proxy. Callers coalesce requests (see
    /// `PreviewScheduler`) so only the latest document is ever rendered.
    public func renderPreview(_ document: EditDocument, proxy: CIImage, compareOriginal: Bool = false) -> CGImage? {
        let output = compareOriginal ? graph.apply(Self.cropOnly(document), to: proxy) : graph.apply(document, to: proxy)
        return context.createCGImage(output, from: output.extent)
    }

    /// The original photo with the crop applied, for hold-to-compare.
    static func cropOnly(_ document: EditDocument) -> EditDocument {
        var doc = document
        doc.operations = []
        return doc
    }

    // MARK: Thumbnails

    /// Renders one look over a small proxy of the user's photo, cached by asset and look.
    public func thumbnail(lookID: String, assetID: String, proxy: CIImage) -> CGImage? {
        let key = "\(assetID)|\(lookID)" as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        let application = LookApplication(lookID: lookID, intensity: 1)
        let image = graph.applyLook(application, to: proxy, seed: 7)
        guard let cg = context.createCGImage(image, from: proxy.extent) else { return nil }
        thumbnailCache.setObject(cg, forKey: key)
        return cg
    }

    public func clearThumbnails() {
        thumbnailCache.removeAllObjects()
    }

    // MARK: Export

    public enum ExportFormat: String, CaseIterable, Sendable {
        case jpeg, heic, png

        public var utType: UTType {
            switch self {
            case .jpeg: return .jpeg
            case .heic: return .heic
            case .png: return .png
            }
        }

        public var fileExtension: String {
            switch self {
            case .jpeg: return "jpg"
            case .heic: return "heic"
            case .png: return "png"
            }
        }
    }

    public struct ExportOptions: Sendable {
        public var format: ExportFormat
        /// nil exports at full resolution.
        public var maxPixelSize: Int?
        public var watermark: String?
        /// 0...1, for JPEG and HEIC.
        public var quality: Double

        public init(format: ExportFormat = .jpeg, maxPixelSize: Int? = nil, watermark: String? = nil, quality: Double = 0.92) {
            self.format = format
            self.maxPixelSize = maxPixelSize
            self.watermark = watermark
            self.quality = quality
        }
    }

    public enum ExportError: Error {
        case encodingFailed
    }

    /// Renders the full edit, overlays and watermark, and encodes it.
    public func export(_ document: EditDocument, source: CIImage, options: ExportOptions) throws -> Data {
        var image = graph.apply(document, to: source)
        if let max = options.maxPixelSize {
            image = Self.proxy(of: image, maxPixelSize: CGFloat(max))
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        let size = image.extent.size
        if let overlayImage = OverlayRasterizer.render(document.overlays, canvasSize: size, watermark: options.watermark) {
            image = overlayImage.composited(over: image)
        }

        let colorSpace = source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let quality = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: options.quality]
        let data: Data?
        switch options.format {
        case .jpeg: data = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: quality)
        case .heic: data = context.heifRepresentation(of: image, format: .RGBA8, colorSpace: colorSpace, options: quality)
        case .png: data = context.pngRepresentation(of: image, format: .RGBA8, colorSpace: colorSpace, options: [:])
        }
        guard let data else { throw ExportError.encodingFailed }
        return data
    }
}
