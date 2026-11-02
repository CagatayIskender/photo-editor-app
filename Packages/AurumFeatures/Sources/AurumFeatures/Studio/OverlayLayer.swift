import SwiftUI
import AurumCore
import AurumDesign
import AurumRender

/// Text and stickers drawn over the preview with the same layout rules as
/// `OverlayRasterizer`, so what the user arranges is what exports.
struct OverlayLayer: View {
    @ObservedObject var model: StudioViewModel
    let frame: CGRect

    /// Points per pixel of the 1080 px reference canvas.
    private var unit: CGFloat { frame.width / 1080 }

    var body: some View {
        ZStack {
            ForEach(model.document.overlays.filter { !$0.isHidden }) { overlay in
                OverlayItemView(overlay: overlay, unit: unit, frame: frame, isSelected: model.selectedOverlayID == overlay.id, model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct OverlayItemView: View {
    let overlay: Overlay
    let unit: CGFloat
    let frame: CGRect
    let isSelected: Bool
    @ObservedObject var model: StudioViewModel

    /// The overlay as it was when the current gesture began.
    @State private var gestureBase: Overlay?

    var body: some View {
        content
            .scaleEffect(overlay.scale)
            .rotationEffect(.degrees(overlay.rotationDegrees))
            .opacity(overlay.opacity)
            .blendMode(Self.blendMode(overlay.blendMode))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(AurumColor.accent, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .scaleEffect(overlay.scale)
                        .rotationEffect(.degrees(overlay.rotationDegrees))
                        .padding(-6)
                }
            }
            .position(x: frame.minX + overlay.center.x * frame.width, y: frame.minY + overlay.center.y * frame.height)
            .onTapGesture {
                model.selectedOverlayID = overlay.id
                if case .text = overlay.content, model.activeTool != .text { model.activeTool = .text }
                if case .sticker = overlay.content, model.activeTool != .stickers { model.activeTool = .stickers }
            }
            .gesture(manipulation, including: isSelected ? .all : .subviews)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityName)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(named: "Delete") {
                model.selectedOverlayID = overlay.id
                model.removeSelectedOverlay()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch overlay.content {
        case .text(let text): TextOverlayView(text: text, unit: unit)
        case .sticker(let sticker): StickerOverlayView(sticker: sticker, unit: unit)
        }
    }

    private var accessibilityName: String {
        switch overlay.content {
        case .text(let text): return "Text: \(text.text)"
        case .sticker(let sticker):
            let name = StickerDefinition.starterSet.first { $0.id == sticker.stickerID }?.name ?? "Sticker"
            return "Sticker: \(name)"
        }
    }

    /// Drag, pinch and rotate together; the whole gesture is one undo step.
    private var manipulation: some Gesture {
        let drag = DragGesture()
            .onChanged { value in
                let base = begin()
                var o = base
                o.center = NormalizedPoint(
                    x: (0.0...1.0).clamp(base.center.x + Double(value.translation.width / max(frame.width, 1))),
                    y: (0.0...1.0).clamp(base.center.y + Double(value.translation.height / max(frame.height, 1)))
                )
                o.scale = overlay.scale
                o.rotationDegrees = overlay.rotationDegrees
                model.updateOverlay(o)
            }
        let pinch = MagnificationGesture()
            .onChanged { value in
                var o = overlay
                o.scale = (0.1...8.0).clamp(begin().scale * Double(value))
                model.updateOverlay(o)
            }
        let rotate = RotationGesture()
            .onChanged { angle in
                var o = overlay
                o.rotationDegrees = begin().rotationDegrees + angle.degrees
                model.updateOverlay(o)
            }
        return drag.simultaneously(with: pinch.simultaneously(with: rotate))
            .onEnded { _ in
                gestureBase = nil
                model.endInteraction()
            }
    }

    private func begin() -> Overlay {
        if let gestureBase { return gestureBase }
        model.beginInteraction()
        gestureBase = overlay
        return overlay
    }

    static func blendMode(_ mode: AurumCore.BlendMode) -> SwiftUI.BlendMode {
        switch mode {
        case .normal: return .normal
        case .screen: return .screen
        case .multiply: return .multiply
        case .overlay: return .overlay
        case .softLight: return .softLight
        case .lighten: return .lighten
        case .darken: return .darken
        }
    }
}

struct TextOverlayView: View {
    let text: TextOverlay
    let unit: CGFloat

    var body: some View {
        let font = Font(OverlayRasterizer.uiFont(for: text.fontID, size: CGFloat(text.size) * unit) as CTFont)
        styled(
            Text(text.text)
                .font(font)
                .multilineTextAlignment(alignment)
                .frame(maxWidth: 1080 * 0.9 * unit)
                .fixedSize(horizontal: false, vertical: true)
        )
    }

    private var alignment: SwiftUI.TextAlignment {
        switch text.alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    @ViewBuilder
    private func styled(_ base: some View) -> some View {
        let color = Color(hex: text.colorHex)
        switch text.style {
        case .plain:
            base.foregroundColor(color)
        case .outline:
            base.foregroundColor(color)
                .shadow(color: .black, radius: 0, x: 1, y: 1)
                .shadow(color: .black, radius: 0, x: -1, y: -1)
        case .shadow:
            base.foregroundColor(color).shadow(color: .black.opacity(0.55), radius: 12 * unit, y: 2 * unit)
        case .glow:
            base.foregroundColor(color).shadow(color: Color(hex: "#F5E3BF").opacity(0.9), radius: 16 * unit)
        case .gradient:
            base.foregroundStyle(LinearGradient(colors: [Color(hex: "#F4EFE6"), Color(hex: "#C9A86A")], startPoint: .leading, endPoint: .trailing))
        case .box:
            base.foregroundColor(color)
                .padding(.horizontal, 16 * unit).padding(.vertical, 6 * unit)
                .background(RoundedRectangle(cornerRadius: 6 * unit).fill(Color(red: 0.04, green: 0.04, blue: 0.05).opacity(0.7)))
        }
    }
}

struct StickerOverlayView: View {
    let sticker: StickerOverlay
    let unit: CGFloat

    var body: some View {
        let width = 360 * unit
        if let image = UIImage(named: "sticker.\(sticker.stickerID)") {
            Image(uiImage: image)
                .renderingMode(sticker.tintHex == nil ? .original : .template)
                .resizable()
                .scaledToFit()
                .foregroundColor(sticker.tintHex.map(Color.init(hex:)))
                .frame(width: width)
        } else {
            // Artwork not yet in the asset catalogue: show a labelled placeholder.
            RoundedRectangle(cornerRadius: 8)
                .stroke(AurumColor.accent, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(width: width, height: width * 0.6)
                .overlay(Text(sticker.stickerID).font(.caption2).foregroundColor(AurumColor.accent))
        }
    }
}
