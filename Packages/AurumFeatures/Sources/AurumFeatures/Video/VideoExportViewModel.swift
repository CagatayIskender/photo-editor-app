import Foundation
import SwiftUI
import AurumCore
import AurumRender
import AurumServices

/// Drives the video Export sheet, with the same honest rules as photo
/// export: everything can be previewed, and membership is asked for only
/// here, naming exactly which member items the video uses.
@MainActor
public final class VideoExportViewModel: ObservableObject {
    public enum Phase: Equatable {
        case ready
        /// Rendering, with progress 0...1.
        case rendering(Double)
        case saved
        case shareReady(URL)
        case failed(String)
    }

    @Published public private(set) var phase: Phase = .ready
    @Published public private(set) var entitlement: Entitlement
    @Published public var isPaywallPresented = false
    @Published public private(set) var withoutPremium = false

    public let original: VideoProject
    let deps: AppDependencies
    let media: VideoMediaSource

    public init(project: VideoProject, deps: AppDependencies, media: VideoMediaSource, entitlement: Entitlement) {
        self.original = project
        self.deps = deps
        self.media = media
        self.entitlement = entitlement
    }

    /// The project that will actually be exported.
    public var project: VideoProject {
        withoutPremium ? Self.strippingPremium(from: original, catalog: deps.catalog, bookends: deps.content.bookends) : original
    }

    public var decision: VideoExportDecision {
        var decision = ExportGate.videoDecision(for: project, entitlement: entitlement, catalog: deps.catalog, templates: deps.content.templates)
        if entitlement == .free {
            for item in Self.premiumBookends(in: project, bookends: deps.content.bookends) where !decision.premiumItems.contains(item) {
                decision.premiumItems.append(item)
            }
        }
        return decision
    }

    /// Member items in the edit as made, before any are left out.
    public var premiumItems: [PremiumItem] {
        ExportGate.premiumItems(in: original, catalog: deps.catalog, templates: deps.content.templates)
            + Self.premiumBookends(in: original, bookends: deps.content.bookends)
    }

    /// A member template is the edit itself, so it can't be left out.
    public var canExportWithoutPremium: Bool {
        !premiumItems.contains { if case .template = $0 { return !$0.isBookend } else { return false } }
    }

    /// Member intro and outro styles. `ExportGate` doesn't list bookends, so
    /// they are reported here, as a named item, under the template case.
    nonisolated static func premiumBookends(in project: VideoProject, bookends: [BookendPreset]) -> [PremiumItem] {
        [project.intro, project.outro].compactMap { effect -> PremiumItem? in
            guard let effect, let preset = bookends.first(where: { $0.id == effect.presetID }), preset.tier == .member else { return nil }
            return .template(id: PremiumItem.bookendPrefix + preset.id, name: preset.name)
        }
    }

    /// The same video with every member look, effect, sticker and bookend removed.
    nonisolated static func strippingPremium(from project: VideoProject, catalog: LookCatalog, bookends: [BookendPreset]) -> VideoProject {
        var p = project
        p.operations.removeAll { op in
            if case .look(let l) = op.kind { return catalog.look(id: l.lookID)?.tier == .member }
            return false
        }
        p.effects.removeAll { $0.tier == .member }
        p.layers.removeAll { layer in
            if case .sticker(let s) = layer.overlay.content { return s.tier == .member }
            return false
        }
        func isMember(_ effect: BookendEffect?) -> Bool {
            guard let effect else { return false }
            return bookends.first { $0.id == effect.presetID }?.tier == .member
        }
        if isMember(p.intro) { p.intro = nil }
        if isMember(p.outro) { p.outro = nil }
        return p
    }

    public var summary: String {
        let d = decision
        if d.requiresMembership {
            return d.premiumItems.count == 1 ? String(localized: "1 member item in this video") : String(localized: "\(d.premiumItems.count) member items in this video")
        }
        if d.watermark {
            return String(localized: "Free export: up to \(d.maxPixelSize) px with a small \(deps.brand.watermarkText) mark")
        }
        return String(localized: "Up to 4K, no watermark")
    }

    public func exportWithoutPremium() {
        withoutPremium = true
        deps.analytics.track(.exportedWithoutPremium)
    }

    public func showPaywall() {
        isPaywallPresented = true
        deps.analytics.track(.paywallViewed(trigger: "video_export"))
    }

    public func membershipChanged(to entitlement: Entitlement) {
        self.entitlement = entitlement
        if entitlement == .member { withoutPremium = false }
    }

    public var progress: Double {
        if case .rendering(let p) = phase { return p }
        return 0
    }

    /// Renders the movie, then saves it to Photos or prepares it for sharing.
    public func export(toPhotos: Bool) async {
        let d = decision
        guard !d.requiresMembership else {
            showPaywall()
            return
        }
        phase = .rendering(0)
        deps.analytics.track(.exportStarted(format: "mp4"))
        let started = Date()
        do {
            let watermark = d.watermark ? deps.brand.watermarkText : nil
            let built = try await VideoCompositionBuilder.build(project, media: media, catalog: deps.catalog, maxPixelSize: d.maxPixelSize, frameRate: 30, watermark: watermark)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(deps.brand.appName)-\(original.id.uuidString.prefix(8))")
                .appendingPathExtension("mp4")
            try await VideoExporter.export(built, to: url) { [weak self] value in
                guard let self, case .rendering = self.phase else { return }
                self.phase = .rendering(min(max(value, 0), 1))
            }
            if toPhotos {
                try await deps.photos.saveVideo(at: url)
                phase = .saved
                deps.analytics.track(.shared(destination: "photos"))
            } else {
                phase = .shareReady(url)
            }
            deps.analytics.track(.exportCompleted(format: "mp4", watermark: watermark != nil, seconds: Date().timeIntervalSince(started)))
        } catch PhotoLibraryError.notAuthorized {
            phase = .failed(String(localized: "AURUM needs permission to add videos. You can allow it in Settings."))
        } catch {
            phase = .failed(String(localized: "The export didn't finish. Please try again."))
        }
    }

    public func reset() {
        phase = .ready
    }
}

extension PremiumItem {
    /// Bookends travel as `.template` items with this ID prefix.
    static let bookendPrefix = "bookend."

    var isBookend: Bool {
        if case .template(let id, _) = self { return id.hasPrefix(Self.bookendPrefix) }
        return false
    }
}
