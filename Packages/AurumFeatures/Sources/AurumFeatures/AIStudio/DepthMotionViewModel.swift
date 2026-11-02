import CoreImage
import SwiftUI
import AurumCore
import AurumRender
import AurumServices

extension DepthMotionPreset {
    /// Dolly and Float are free; Orbit and Swing are members' moves. As with
    /// every member item, they can be previewed freely and membership is asked
    /// for only at export.
    public var tier: Tier {
        switch self {
        case .dolly, .float: return .free
        case .orbit, .swing: return .member
        }
    }

    public var title: String {
        switch self {
        case .orbit: return String(localized: "Orbit")
        case .dolly: return String(localized: "Dolly")
        case .swing: return String(localized: "Swing")
        case .float: return String(localized: "Float")
        }
    }
}

/// Drives 3D Motion: one photo, a camera move and its intensity, a live
/// looping preview, and export as a video to Photos.
@MainActor
public final class DepthMotionViewModel: ObservableObject {
    public enum Phase: Equatable {
        case empty
        case loading
        case ready
        case exporting(Double)
        case saved
        case failed(String)
    }

    @Published public private(set) var photo: PickedMedia?
    @Published public var preset: DepthMotionPreset = .dolly
    @Published public var intensity = 0.6
    @Published public private(set) var frame: CGImage?
    @Published public private(set) var phase: Phase = .empty
    @Published public private(set) var usesRealDepth = false
    @Published public var isPaywallPresented = false

    let deps: AppDependencies
    let currentEntitlement: () -> Entitlement
    let previewer = DepthMotionPreviewer()
    private var disparity: CIImage?

    /// Preview proxy size, loop length and export size.
    static let previewPixelSize: CGFloat = 900
    static let duration: Seconds = DepthMotion.defaultDuration
    static let exportLongestSide: CGFloat = 1920

    public init(deps: AppDependencies, entitlement: @escaping () -> Entitlement) {
        self.deps = deps
        self.currentEntitlement = entitlement
    }

    public var entitlement: Entitlement { currentEntitlement() }

    public var motion: DepthMotion { DepthMotion(preset: preset, intensity: intensity) }

    /// True when exporting the chosen move needs membership.
    public var requiresMembership: Bool {
        Self.requiresMembership(preset: preset, entitlement: entitlement)
    }

    public nonisolated static func requiresMembership(preset: DepthMotionPreset, entitlement: Entitlement) -> Bool {
        preset.tier == .member && entitlement == .free
    }

    // MARK: Loading

    public func setPhoto(_ picked: [PickedMedia]) async {
        guard let first = AtelierSupport.photosOnly(picked).first else { return }
        photo = first
        phase = .loading
        frame = nil
        do {
            let image = try await deps.photos.image(for: first.id, maxPixelSize: Self.previewPixelSize)
            disparity = await Self.embeddedDisparity(for: first.id, photos: deps.photos)
            usesRealDepth = await previewer.prepare(image: image, disparity: disparity)
            frame = await previewer.frame(motion: motion, at: 0, duration: Self.duration)
            phase = .ready
        } catch {
            phase = .failed(String(localized: "This photo couldn't be opened."))
        }
    }

    /// Portrait-mode depth, when the library can give the original file.
    static func embeddedDisparity(for id: String, photos: PhotoLibraryService) async -> CIImage? {
        guard let live = photos as? LivePhotoLibrary, let data = try? await live.originalData(for: id) else { return nil }
        return DepthEstimator.embeddedDisparity(in: data)
    }

    // MARK: Preview

    /// Renders the loop until cancelled. With Reduce Motion, renders one
    /// still frame that shows the depth without moving.
    public func runPreview(reduceMotion: Bool) async {
        guard phase == .ready || phase == .saved else { return }
        if reduceMotion {
            frame = await previewer.frame(motion: motion, at: Self.duration / 4, duration: Self.duration)
            return
        }
        let start = Date()
        while !Task.isCancelled {
            let t = Date().timeIntervalSince(start)
            if let next = await previewer.frame(motion: motion, at: t, duration: Self.duration) { frame = next }
            try? await Task.sleep(nanoseconds: 33_000_000)
        }
    }

    // MARK: Export

    public func export() async {
        guard let photo else { return }
        if requiresMembership {
            isPaywallPresented = true
            deps.analytics.track(.paywallViewed(trigger: "depthMotion"))
            return
        }
        phase = .exporting(0)
        deps.analytics.track(.exportStarted(format: "mp4"))
        let started = Date()
        let watermark = entitlement == .free ? deps.brand.watermarkText : nil
        do {
            let image = try await deps.photos.image(for: photo.id, maxPixelSize: Self.exportLongestSide)
            guard let depth = await previewer.depth else { throw DepthMotionExporter.ExportError.noPixelBuffer }
            let size = Self.exportSize(for: image.extent.size, longestSide: Self.exportLongestSide)
            let overlay = OverlayRasterizer.render([], canvasSize: size, watermark: watermark)
            let url = AtelierSupport.movieURL(prefix: "\(deps.brand.appName)-3D")
            try await DepthMotionExporter.export(image: image, depth: depth, motion: motion, duration: Self.duration, size: size, overlay: overlay, to: url) { [weak self] value in
                Task { @MainActor in
                    guard let self, case .exporting = self.phase else { return }
                    self.phase = .exporting(value)
                }
            }
            try await deps.photos.saveVideo(at: url)
            try? FileManager.default.removeItem(at: url)
            phase = .saved
            deps.drops.recordCreation()
            deps.analytics.track(.exportCompleted(format: "mp4", watermark: watermark != nil, seconds: Date().timeIntervalSince(started)))
        } catch PhotoLibraryError.notAuthorized {
            phase = .failed(String(localized: "AURUM needs permission to add videos. You can allow it in Settings."))
        } catch {
            phase = .failed(String(localized: "The export didn't finish. Please try again."))
        }
    }

    /// The photo's shape at `exportLongestSide`, in even pixels.
    nonisolated static func exportSize(for size: CGSize, longestSide: CGFloat = 1920) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: 1080, height: 1350) }
        let scale = min(1, longestSide / max(size.width, size.height))
        func even(_ v: CGFloat) -> CGFloat { max(2, (v * scale / 2).rounded(.down) * 2) }
        return CGSize(width: even(size.width), height: even(size.height))
    }

    /// Switches to a free move, for the paywall's alternative.
    public func useFreeMove() {
        preset = .dolly
        isPaywallPresented = false
    }

    public func reset() {
        if photo != nil { phase = .ready }
    }
}
