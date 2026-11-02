import Foundation

/// What the current user is entitled to.
public enum Entitlement: String, Codable, Sendable {
    case free
    case member
}

/// A premium item used in an edit, listed on the paywall so the user knows why it appeared.
public enum PremiumItem: Equatable, Hashable, Sendable {
    case look(id: String, name: String)
    case sticker(id: String)
    case retouch
    case effect(kind: String)
    case template(id: String, name: String)
    case collageLayout(id: String, name: String)

    public var displayName: String {
        switch self {
        case .look(_, let name): return name
        case .sticker: return "Members' sticker"
        case .retouch: return "Retouch"
        case .effect(let kind): return AnimatedEffect.Kind(rawValue: kind)?.displayName ?? "Effect"
        case .template(_, let name): return name
        case .collageLayout(_, let name): return name
        }
    }
}

public enum ExportDecision: Equatable, Sendable {
    /// Export can go ahead. `maxPixelSize` nil means full resolution.
    case allowed(watermark: Bool, maxPixelSize: Int?)
    /// The edit uses premium items; show the paywall, which also offers
    /// exporting without them.
    case requiresMembership([PremiumItem])
}

/// The membership rules, kept free of StoreKit so they are easy to test.
///
/// Users may preview everything. The paywall appears only when exporting an
/// edit that uses premium items, never before.
public enum ExportGate {
    public static let freeMaxPixelSize = 2048

    public static func premiumItems(in document: EditDocument, catalog: LookCatalog) -> [PremiumItem] {
        var items: [PremiumItem] = []
        for op in document.operations where op.isEnabled {
            guard case .look(let application) = op.kind, application.intensity > 0 else { continue }
            if let recipe = catalog.look(id: application.lookID), recipe.tier == .member {
                let item = PremiumItem.look(id: recipe.id, name: recipe.name)
                if !items.contains(item) { items.append(item) }
            }
        }
        let usesRetouch = document.operations.contains { op in
            if case .retouch(let r) = op.kind { return op.isEnabled && !r.isNeutral }
            return false
        }
        if usesRetouch { items.append(.retouch) }
        for overlay in document.overlays where !overlay.isHidden {
            if case .sticker(let s) = overlay.content, s.tier == .member {
                let item = PremiumItem.sticker(id: s.stickerID)
                if !items.contains(item) { items.append(item) }
            }
        }
        return items
    }

    public static func decision(for document: EditDocument, entitlement: Entitlement, catalog: LookCatalog) -> ExportDecision {
        switch entitlement {
        case .member:
            return .allowed(watermark: false, maxPixelSize: nil)
        case .free:
            let items = premiumItems(in: document, catalog: catalog)
            return items.isEmpty
                ? .allowed(watermark: true, maxPixelSize: freeMaxPixelSize)
                : .requiresMembership(items)
        }
    }

    /// The same edit with every premium item removed, for "Export without premium".
    public static func strippingPremium(from document: EditDocument, catalog: LookCatalog) -> EditDocument {
        var doc = document
        doc.operations.removeAll { op in
            switch op.kind {
            case .look(let l): return catalog.look(id: l.lookID)?.tier == .member
            case .retouch: return true
            case .adjust: return false
            }
        }
        doc.overlays.removeAll { overlay in
            if case .sticker(let s) = overlay.content { return s.tier == .member }
            return false
        }
        return doc
    }
}

/// Video export settings the user is entitled to.
public struct VideoExportDecision: Equatable, Sendable {
    public var premiumItems: [PremiumItem]
    public var watermark: Bool
    /// Longest side in pixels: 1920 free, 3840 (4K) for members.
    public var maxPixelSize: Int
    public var maxFrameRate: Int

    public var requiresMembership: Bool { !premiumItems.isEmpty }
}

extension ExportGate {
    public static let freeVideoMaxPixelSize = 1920
    public static let memberVideoMaxPixelSize = 3840

    public static func premiumItems(in project: VideoProject, catalog: LookCatalog, templates: [TemplateDefinition] = []) -> [PremiumItem] {
        var items: [PremiumItem] = []
        func add(_ item: PremiumItem) { if !items.contains(item) { items.append(item) } }
        for op in project.operations where op.isEnabled {
            if case .look(let l) = op.kind, l.intensity > 0, let recipe = catalog.look(id: l.lookID), recipe.tier == .member {
                add(.look(id: recipe.id, name: recipe.name))
            }
        }
        for effect in project.effects where effect.tier == .member && effect.intensity > 0 {
            add(.effect(kind: effect.kind.rawValue))
        }
        if let id = project.templateID, let t = templates.first(where: { $0.id == id }), t.tier == .member {
            add(.template(id: t.id, name: t.name))
        }
        for layer in project.layers where !layer.overlay.isHidden {
            if case .sticker(let s) = layer.overlay.content, s.tier == .member { add(.sticker(id: s.stickerID)) }
        }
        return items
    }

    public static func videoDecision(for project: VideoProject, entitlement: Entitlement, catalog: LookCatalog, templates: [TemplateDefinition] = []) -> VideoExportDecision {
        switch entitlement {
        case .member:
            return VideoExportDecision(premiumItems: [], watermark: false, maxPixelSize: memberVideoMaxPixelSize, maxFrameRate: 60)
        case .free:
            return VideoExportDecision(premiumItems: premiumItems(in: project, catalog: catalog, templates: templates), watermark: true, maxPixelSize: freeVideoMaxPixelSize, maxFrameRate: 30)
        }
    }
}

extension ExportGate {
    /// Premium items in a collage: currently only a members' layout.
    public static func premiumItems(in collage: CollageProject) -> [PremiumItem] {
        collage.layout.tier == .member ? [.collageLayout(id: collage.layout.id, name: collage.layout.name)] : []
    }

    public static func collageDecision(for collage: CollageProject, entitlement: Entitlement) -> ExportDecision {
        switch entitlement {
        case .member:
            return .allowed(watermark: false, maxPixelSize: nil)
        case .free:
            let items = premiumItems(in: collage)
            return items.isEmpty
                ? .allowed(watermark: true, maxPixelSize: freeMaxPixelSize)
                : .requiresMembership(items)
        }
    }
}
