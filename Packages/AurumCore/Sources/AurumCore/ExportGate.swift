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

    public var displayName: String {
        switch self {
        case .look(_, let name): return name
        case .sticker: return "Members' sticker"
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
            guard case .look(let l) = op.kind else { return false }
            return catalog.look(id: l.lookID)?.tier == .member
        }
        doc.overlays.removeAll { overlay in
            if case .sticker(let s) = overlay.content { return s.tier == .member }
            return false
        }
        return doc
    }
}
