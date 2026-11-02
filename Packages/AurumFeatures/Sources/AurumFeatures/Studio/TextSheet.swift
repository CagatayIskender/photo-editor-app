import SwiftUI
import AurumCore
import AurumDesign
import AurumRender

/// Adds and styles text. With no text selected it offers "Add text";
/// with one selected it edits the words, font, style and colour.
struct TextSheet: View {
    @ObservedObject var model: StudioViewModel
    @FocusState private var isEditingWords: Bool

    static let palette = ["#F4EFE6", "#C9A86A", "#0B0B0C", "#B9A28A", "#8C2F39", "#3D5A6C"]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let overlay = model.selectedOverlay, case .text(let text) = overlay.content {
                editor(text)
            } else {
                Button {
                    model.addText()
                    isEditingWords = true
                } label: {
                    Label { Text("Add text") } icon: { IconView(.text, size: 18) }
                }
                .buttonStyle(GoldButtonStyle(compact: true))
                .padding(.horizontal, Spacing.m)
                Text("Tap text on the photo to edit it. Drag, pinch and rotate to place it.")
                    .aurumText(.caption, color: AurumColor.textTertiary)
                    .padding(.horizontal, Spacing.m)
            }
        }
        .padding(.bottom, Spacing.s)
    }

    @ViewBuilder
    private func editor(_ text: TextOverlay) -> some View {
        HStack(spacing: Spacing.xs) {
            TextField("Your words", text: Binding(
                get: { text.text },
                set: { value in model.updateSelectedText { $0.text = value } }
            ), axis: .vertical)
            .lineLimit(1...3)
            .focused($isEditingWords)
            .font(AurumTextStyle.body.font)
            .foregroundColor(AurumColor.textPrimary)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs)
            .background(RoundedRectangle(cornerRadius: Radius.chip).fill(AurumColor.surfaceRaised))
            IconButton(.close, label: String(localized: "Delete text")) { model.removeSelectedOverlay() }
        }
        .padding(.horizontal, Spacing.m)

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xs) {
                ForEach(OverlayFont.all) { font in
                    Button { model.updateSelectedText { $0.fontID = font.id } } label: {
                        Text("Aa")
                            .font(Font(OverlayRasterizer.uiFont(for: font.id, size: 20) as CTFont))
                            .foregroundColor(text.fontID == font.id ? AurumColor.onAccent : AurumColor.textPrimary)
                            .frame(width: 52, height: 40)
                            .background(RoundedRectangle(cornerRadius: Radius.chip).fill(text.fontID == font.id ? AurumColor.accent : AurumColor.surfaceRaised))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Font \(font.displayName)")
                    .accessibilityAddTraits(text.fontID == font.id ? .isSelected : [])
                }
            }
            .padding(.horizontal, Spacing.m)
        }

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xs) {
                ForEach(TextStyle.allCases, id: \.self) { style in
                    Chip(Self.name(of: style), isSelected: text.style == style) {
                        model.updateSelectedText { $0.style = style }
                    }
                }
                Divider().frame(height: 24).overlay(AurumColor.hairline)
                ForEach(Self.palette, id: \.self) { hex in
                    Button { model.updateSelectedText { $0.colorHex = hex } } label: {
                        Circle().fill(Color(hex: hex))
                            .frame(width: 28, height: 28)
                            .overlay(Circle().stroke(text.colorHex == hex ? AurumColor.accent : AurumColor.hairline, lineWidth: text.colorHex == hex ? 2 : 1))
                            .frame(width: Size.touch, height: Size.touch)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Colour \(hex)")
                    .accessibilityAddTraits(text.colorHex == hex ? .isSelected : [])
                }
            }
            .padding(.horizontal, Spacing.m)
        }
    }

    static func name(of style: TextStyle) -> String {
        switch style {
        case .plain: return String(localized: "Plain")
        case .outline: return String(localized: "Outline")
        case .shadow: return String(localized: "Shadow")
        case .glow: return String(localized: "Glow")
        case .gradient: return String(localized: "Gilded")
        case .box: return String(localized: "Label")
        }
    }
}

