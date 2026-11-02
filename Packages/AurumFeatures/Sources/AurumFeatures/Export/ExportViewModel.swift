import CoreImage
import SwiftUI
import AurumCore
import AurumRender
import AurumServices

/// Drives the Export sheet. Export is the only place membership is asked for:
/// if the edit uses member looks or stickers, the sheet names them and offers
/// membership or an export without them. Nothing is hidden or pre-ticked.
@MainActor
public final class ExportViewModel: ObservableObject {
    public enum Phase: Equatable {
        case ready
        case rendering
        /// Saved to Photos.
        case saved
        /// Rendered to a file for the share sheet.
        case shareReady(URL)
        case failed(String)
    }

    @Published public var format: RenderEngine.ExportFormat = .jpeg
    @Published public private(set) var phase: Phase = .ready
    @Published public private(set) var entitlement: Entitlement
    @Published public var isPaywallPresented = false
    /// When true, member items are left out of this export.
    @Published public private(set) var withoutPremium = false

    public let original: EditDocument
    let deps: AppDependencies

    public init(document: EditDocument, deps: AppDependencies, entitlement: Entitlement) {
        self.original = document
        self.deps = deps
        self.entitlement = entitlement
    }

    /// The document that will actually be exported.
    public var document: EditDocument {
        withoutPremium ? ExportGate.strippingPremium(from: original, catalog: deps.catalog) : original
    }

    public var decision: ExportDecision {
        ExportGate.decision(for: document, entitlement: entitlement, catalog: deps.catalog)
    }

    public var premiumItems: [PremiumItem] {
        ExportGate.premiumItems(in: original, catalog: deps.catalog)
    }

    /// Render settings for a decision. Pure, so tests can check the rules.
    nonisolated static func options(for decision: ExportDecision, format: RenderEngine.ExportFormat, watermarkText: String) -> RenderEngine.ExportOptions? {
        guard case .allowed(let watermark, let maxPixelSize) = decision else { return nil }
        return RenderEngine.ExportOptions(format: format, maxPixelSize: maxPixelSize, watermark: watermark ? watermarkText : nil)
    }

    /// One line under the buttons that says exactly what the user will get.
    public var summary: String {
        switch decision {
        case .requiresMembership(let items):
            return items.count == 1 ? String(localized: "1 member item in this edit") : String(localized: "\(items.count) member items in this edit")
        case .allowed(let watermark, let maxPixelSize):
            if watermark, let maxPixelSize {
                return String(localized: "Free export: up to \(maxPixelSize) px with a small \(deps.brand.watermarkText) mark")
            }
            return String(localized: "Full resolution, no watermark")
        }
    }

    public func exportWithoutPremium() {
        withoutPremium = true
        deps.analytics.track(.exportedWithoutPremium)
    }

    public func showPaywall() {
        isPaywallPresented = true
        deps.analytics.track(.paywallViewed(trigger: "export"))
    }

    public func membershipChanged(to entitlement: Entitlement) {
        self.entitlement = entitlement
        if entitlement == .member { withoutPremium = false }
    }

    /// Renders the export and either saves it to Photos or prepares it for sharing.
    public func export(toPhotos: Bool) async {
        guard let options = Self.options(for: decision, format: format, watermarkText: deps.brand.watermarkText) else {
            showPaywall()
            return
        }
        phase = .rendering
        deps.analytics.track(.exportStarted(format: format.rawValue))
        let started = Date()
        do {
            // Load only the pixels needed: the free cap avoids decoding a 48 MP original.
            let longestNeeded = options.maxPixelSize.map { CGFloat($0) * 1.5 }
            let source = try await deps.photos.image(for: document.source.localIdentifier, maxPixelSize: longestNeeded)
            let data = try await deps.engine.export(document, source: source, options: options)
            if toPhotos {
                try await deps.photos.save(data, fileExtension: format.fileExtension)
                phase = .saved
                deps.analytics.track(.shared(destination: "photos"))
            } else {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(deps.brand.appName)-\(document.id.uuidString.prefix(8))")
                    .appendingPathExtension(format.fileExtension)
                try data.write(to: url, options: .atomic)
                phase = .shareReady(url)
            }
            deps.analytics.track(.exportCompleted(format: format.rawValue, watermark: options.watermark != nil, seconds: Date().timeIntervalSince(started)))
            deps.drops.recordCreation()
        } catch PhotoLibraryError.notAuthorized {
            phase = .failed(String(localized: "AURUM needs permission to add photos. You can allow it in Settings."))
        } catch {
            phase = .failed(String(localized: "The export didn't finish. Please try again."))
        }
    }

    public func reset() {
        phase = .ready
    }
}
