import CoreImage
import SwiftUI
import AurumCore
import AurumRender
import AurumServices

/// Where a photo sits inside a collage cell. Shared by the on-screen editor
/// and (in Core Image's flipped form) by `CollageRenderer`, so what the user
/// frames is what exports.
enum CollageCellGeometry {
    /// Scale from image pixels to cell points.
    static func scale(cell: CGSize, image: CGSize, zoom: Double) -> CGFloat {
        guard image.width > 0, image.height > 0 else { return 1 }
        return max(cell.width / image.width, cell.height / image.height) * CGFloat(max(1, zoom))
    }

    /// The centre clamped so the image always covers the cell.
    static func clampedCenter(_ center: NormalizedPoint, cell: CGSize, image: CGSize, zoom: Double) -> NormalizedPoint {
        let s = scale(cell: cell, image: image, zoom: zoom)
        guard image.width > 0, image.height > 0, s > 0 else { return center }
        let hx = Double(cell.width / s / image.width / 2)
        let hy = Double(cell.height / s / image.height / 2)
        return NormalizedPoint(x: min(max(center.x, hx), 1 - hx), y: min(max(center.y, hy), 1 - hy))
    }

    /// The image's frame in cell coordinates (top-left origin).
    static func imageFrame(cell: CGSize, image: CGSize, zoom: Double, center: NormalizedPoint) -> CGRect {
        let s = scale(cell: cell, image: image, zoom: zoom)
        let c = clampedCenter(center, cell: cell, image: image, zoom: zoom)
        let size = CGSize(width: image.width * s, height: image.height * s)
        return CGRect(x: cell.width / 2 - CGFloat(c.x) * size.width, y: cell.height / 2 - CGFloat(c.y) * size.height, width: size.width, height: size.height)
    }

    /// The centre after dragging the photo by `translation` points.
    static func panned(_ center: NormalizedPoint, by translation: CGSize, cell: CGSize, image: CGSize, zoom: Double) -> NormalizedPoint {
        let s = scale(cell: cell, image: image, zoom: zoom)
        guard image.width > 0, image.height > 0, s > 0 else { return center }
        let moved = NormalizedPoint(
            x: center.x - Double(translation.width / (image.width * s)),
            y: center.y - Double(translation.height / (image.height * s))
        )
        return clampedCenter(moved, cell: cell, image: image, zoom: zoom)
    }
}

/// Drives the collage editor: layout, photos per cell, swapping, per-cell
/// framing, spacing, corners and background, then export.
@MainActor
public final class CollageViewModel: ObservableObject {
    public enum Phase: Equatable {
        case editing
        case exporting
        case saved
        case failed(String)
    }

    @Published public private(set) var project: CollageProject
    @Published public private(set) var thumbnails: [String: UIImage] = [:]
    @Published public var selectedCell: Int?
    @Published public private(set) var phase: Phase = .editing
    @Published public var isPaywallPresented = false

    let deps: AppDependencies
    let currentEntitlement: () -> Entitlement
    private var adjustStart: CollageProject.Cell?

    /// Background colours offered under the canvas.
    public static let backgrounds = ["#0B0B0C", "#F4EFE6", "#E9D9BC", "#F2DEDB", "#3A3F44", "#FFFFFF"]
    /// Longest side of a member export; free exports use `ExportGate.freeMaxPixelSize`.
    static let memberLongestSide: CGFloat = 4096

    public init(deps: AppDependencies, entitlement: @escaping () -> Entitlement, layout: CollageLayout? = nil) {
        self.deps = deps
        self.currentEntitlement = entitlement
        let start = layout ?? CollageLayout.library.first { $0.tier == .free } ?? CollageLayout.library[0]
        self.project = CollageProject(layout: start)
    }

    public var entitlement: Entitlement { currentEntitlement() }
    public var layouts: [CollageLayout] { CollageLayout.library }

    // MARK: Layout and photos

    public func setLayout(_ layout: CollageLayout) {
        project.setLayout(layout)
        selectedCell = nil
        phase = .editing
    }

    /// Fills empty cells with picked photos, in picking order.
    public func add(_ picked: [PickedMedia]) {
        for item in AtelierSupport.photosOnly(picked) {
            guard project.add(item.source) != nil else { break }
            loadThumbnail(item.id)
        }
        phase = .editing
    }

    /// Puts a photo in one cell, replacing what was there.
    public func replace(cell index: Int, with picked: [PickedMedia]) {
        guard let item = AtelierSupport.photosOnly(picked).first else { return }
        project.assign(CollageProject.Cell(source: item.source), at: index)
        loadThumbnail(item.id)
        selectedCell = nil
    }

    public func clear(cell index: Int) {
        project.assign(nil, at: index)
        selectedCell = nil
    }

    /// Tapping a cell selects it; tapping another while one is selected swaps them.
    /// Returns true when the tap swapped two cells.
    @discardableResult
    public func tap(cell index: Int) -> Bool {
        if let selected = selectedCell {
            if selected == index {
                selectedCell = nil
                return false
            }
            project.swapCells(selected, index)
            selectedCell = nil
            return true
        }
        selectedCell = index
        return false
    }

    public var emptyCellCount: Int { project.cells.filter { $0 == nil }.count }

    func loadThumbnail(_ id: String) {
        guard thumbnails[id] == nil else { return }
        Task {
            if let image = await deps.photos.thumbnail(for: id, side: 600) { thumbnails[id] = image }
        }
    }

    // MARK: Framing

    public func beginAdjusting(cell index: Int) {
        guard adjustStart == nil, project.cells.indices.contains(index) else { return }
        adjustStart = project.cells[index]
    }

    /// Pans and zooms a cell's photo relative to where the gesture began.
    public func adjust(cell index: Int, translation: CGSize, magnification: CGFloat, cellSize: CGSize) {
        guard let start = adjustStart, project.cells.indices.contains(index) else { return }
        let image = CGSize(width: start.source.pixelSize.width, height: start.source.pixelSize.height)
        let zoom = (1.0...4.0).clamp(start.zoom * Double(magnification))
        let center = CollageCellGeometry.panned(start.center, by: translation, cell: cellSize, image: image, zoom: zoom)
        project.assign(CollageProject.Cell(source: start.source, zoom: zoom, center: center), at: index)
    }

    public func endAdjusting() {
        adjustStart = nil
    }

    public var spacing: Double {
        get { project.spacing }
        set { project.spacing = CollageProject.spacingRange.clamp(newValue) }
    }

    public var cornerRadius: Double {
        get { project.cornerRadius }
        set { project.cornerRadius = CollageProject.cornerRadiusRange.clamp(newValue) }
    }

    public func setBackground(_ hex: String) {
        project.backgroundHex = CollageProject.normalizedHex(hex) ?? project.backgroundHex
    }

    // MARK: Export

    public var decision: ExportDecision {
        ExportGate.collageDecision(for: project, entitlement: entitlement)
    }

    public var canExport: Bool { project.filledCount > 0 && phase != .exporting }

    /// Membership is asked for here and only here, when the layout is a member's.
    public func export() async {
        guard case .allowed(let watermark, let maxPixelSize) = decision else {
            isPaywallPresented = true
            deps.analytics.track(.paywallViewed(trigger: "collage"))
            return
        }
        phase = .exporting
        deps.analytics.track(.exportStarted(format: "jpeg"))
        let started = Date()
        let longest = maxPixelSize.map { CGFloat($0) } ?? Self.memberLongestSide
        let canvas = CollageRenderer.canvasSize(for: project.layout, longestSide: longest)
        do {
            var images: [CIImage?] = []
            for cell in project.cells {
                if let cell {
                    images.append(try await deps.photos.image(for: cell.source.localIdentifier, maxPixelSize: longest))
                } else {
                    images.append(nil)
                }
            }
            let output = CollageRenderer.render(project, images: images, canvasSize: canvas)
            let data = try await deps.engine.encode(output, watermark: watermark ? deps.brand.watermarkText : nil)
            try await deps.photos.save(data, fileExtension: "jpg")
            phase = .saved
            deps.drops.recordCreation()
            deps.analytics.track(.exportCompleted(format: "jpeg", watermark: watermark, seconds: Date().timeIntervalSince(started)))
        } catch {
            phase = .failed(AtelierSupport.saveFailureMessage(error))
        }
    }

    /// The paywall's alternative: the closest free layout for the same photos.
    public func useFreeLayout() {
        let count = project.layout.photoCount
        if let free = CollageLayout.layouts(forPhotoCount: count).first(where: { $0.tier == .free })
            ?? CollageLayout.library.first(where: { $0.tier == .free }) {
            setLayout(free)
        }
        isPaywallPresented = false
    }

    public func resetPhase() { phase = .editing }
}
