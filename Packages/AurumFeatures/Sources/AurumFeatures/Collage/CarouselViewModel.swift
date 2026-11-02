import CoreImage
import SwiftUI
import AurumCore
import AurumRender
import AurumServices

/// Panels a carousel can have.
let carouselPanelRange = 2...10

/// Drives the carousel splitter: one wide photo cut into 2–10 panels that
/// line up seamlessly when swiped, exported to Photos in order.
@MainActor
public final class CarouselViewModel: ObservableObject {
    public enum Phase: Equatable {
        case empty
        case loading
        case ready
        case exporting(done: Int, total: Int)
        case saved(Int)
        case failed(String)
    }

    /// Panel shapes offered: the common feed shapes.
    public static let aspects: [AspectPreset] = [.portrait, .square, .landscape]
    public static let countRange = carouselPanelRange

    @Published public private(set) var photo: PickedMedia?
    @Published public private(set) var count = 3
    @Published public var aspect: AspectPreset = .portrait { didSet { refreshPanels() } }
    @Published public private(set) var panels: [CGImage] = []
    @Published public private(set) var phase: Phase = .empty

    let deps: AppDependencies
    let currentEntitlement: () -> Entitlement
    private var proxy: CIImage?
    private var refreshTask: Task<Void, Never>?

    static let previewPixelSize: CGFloat = 1600
    /// Longest side of each exported panel for members.
    static let memberPanelSide: CGFloat = 2160

    public init(deps: AppDependencies, entitlement: @escaping () -> Entitlement) {
        self.deps = deps
        self.currentEntitlement = entitlement
    }

    public var entitlement: Entitlement { currentEntitlement() }

    public nonisolated static func clampCount(_ value: Int) -> Int {
        min(max(value, carouselPanelRange.lowerBound), carouselPanelRange.upperBound)
    }

    public var panelAspect: Double { aspect.ratio ?? 1 }

    /// Sets the number of panels, kept within `countRange`.
    public func setCount(_ value: Int) {
        let clamped = Self.clampCount(value)
        guard clamped != count else { return }
        count = clamped
        refreshPanels()
    }

    /// Panels as normalised rects of the photo, for the guide lines.
    public var panelRects: [NormalizedRect] {
        guard let photo else { return [] }
        return Carousel.panels(for: photo.pixelSize.aspectRatio, count: count, panelAspect: panelAspect)
    }

    // MARK: Photo

    public func setPhoto(_ picked: [PickedMedia]) async {
        guard let first = AtelierSupport.photosOnly(picked).first else { return }
        photo = first
        phase = .loading
        do {
            proxy = try await deps.photos.image(for: first.id, maxPixelSize: Self.previewPixelSize)
            phase = .ready
            refreshPanels()
        } catch {
            phase = .failed(String(localized: "This photo couldn't be opened."))
        }
    }

    /// Supplies an image directly, for tests and previews.
    func setProxy(_ image: CIImage, photo: PickedMedia) {
        self.photo = photo
        proxy = image
        phase = .ready
    }

    func refreshPanels() {
        guard let proxy else { return }
        refreshTask?.cancel()
        let count = self.count, aspect = panelAspect, engine = deps.engine
        refreshTask = Task {
            var images: [CGImage] = []
            for panel in CarouselRenderer.panels(proxy, count: count, panelAspect: aspect) {
                if Task.isCancelled { return }
                if let cg = await engine.cgImage(panel) { images.append(cg) }
            }
            if !Task.isCancelled { panels = images }
        }
    }

    // MARK: Export

    /// Free exports follow the photo rules (panels up to 2048 px); the small
    /// mark goes on the last panel only, so the swipe stays clean.
    public func export() async {
        guard let photo else { return }
        let isFree = entitlement == .free
        let panelSide = isFree ? CGFloat(ExportGate.freeMaxPixelSize) : Self.memberPanelSide
        let total = count
        phase = .exporting(done: 0, total: total)
        deps.analytics.track(.exportStarted(format: "jpeg"))
        let started = Date()
        do {
            // Enough pixels for every panel at full panel size, within reason.
            let needed = min(panelSide * CGFloat(max(total, 1)) * 1.1, 12_000)
            let image = try await deps.photos.image(for: photo.id, maxPixelSize: needed)
            let cuts = CarouselRenderer.panels(image, count: total, panelAspect: panelAspect)
            for (index, panel) in cuts.enumerated() {
                var scaled = RenderEngine.proxy(of: panel, maxPixelSize: panelSide)
                scaled = scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX, y: -scaled.extent.minY))
                let mark = isFree && index == cuts.count - 1 ? deps.brand.watermarkText : nil
                let data = try await deps.engine.encode(scaled, watermark: mark)
                try await deps.photos.save(data, fileExtension: "jpg")
                phase = .exporting(done: index + 1, total: total)
            }
            phase = .saved(cuts.count)
            deps.drops.recordCreation()
            deps.analytics.track(.exportCompleted(format: "jpeg", watermark: isFree, seconds: Date().timeIntervalSince(started)))
        } catch {
            phase = .failed(AtelierSupport.saveFailureMessage(error))
        }
    }
}
