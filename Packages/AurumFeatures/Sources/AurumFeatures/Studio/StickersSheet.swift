import SwiftUI
import AurumCore
import AurumDesign

/// The in-house sticker set by category. Member stickers carry a crown and
/// can be placed freely; membership is only asked for at export.
struct StickersSheet: View {
    @ObservedObject var model: StudioViewModel
    let entitlement: Entitlement
    @State private var category = StickerDefinition.categories[0]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.xs) {
                    ForEach(StickerDefinition.categories, id: \.self) { c in
                        Chip(c, isSelected: c == category) { category = c }
                    }
                    if model.selectedOverlay.map(Self.isSticker) == true {
                        Button("Remove") { model.removeSelectedOverlay() }
                            .buttonStyle(TextActionButtonStyle())
                    }
                }
                .padding(.horizontal, Spacing.m)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.s) {
                    ForEach(StickerDefinition.starterSet.filter { $0.category == category }) { sticker in
                        Button {
                            model.addSticker(sticker)
                            Haptics.apply()
                        } label: {
                            StickerOverlayView(sticker: StickerOverlay(stickerID: sticker.id, tier: sticker.tier), unit: 72.0 / 360.0)
                                .frame(width: 72, height: 72)
                                .background(RoundedRectangle(cornerRadius: Radius.thumbnail).fill(AurumColor.surfaceRaised))
                                .overlay(alignment: .topTrailing) {
                                    if sticker.tier == .member && entitlement == .free { CrownBadge(size: 16).padding(4) }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(sticker.tier == .member ? "\(sticker.name), members only" : sticker.name)
                    }
                }
                .padding(.horizontal, Spacing.m)
            }
        }
        .padding(.bottom, Spacing.s)
    }

    static func isSticker(_ overlay: Overlay) -> Bool {
        if case .sticker = overlay.content { return true }
        return false
    }
}
