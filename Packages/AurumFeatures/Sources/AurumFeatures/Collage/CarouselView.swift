import SwiftUI
import AurumCore
import AurumDesign
import AurumRender

/// Carousel: one wide photo, cut into panels that swipe as one image.
struct CarouselView: View {
    @ObservedObject var app: AppModel
    @StateObject private var model: CarouselViewModel
    @State private var isPicking = false

    init(app: AppModel) {
        self.app = app
        _model = StateObject(wrappedValue: CarouselViewModel(deps: app.deps, entitlement: { [weak app] in app?.entitlement ?? .free }))
    }

    var body: some View {
        VStack(spacing: 0) {
            AtelierHeader(title: String(localized: "Carousel"), onClose: { app.closeFlow() }) {
                Button("Save all") {
                    Task {
                        await model.export()
                        if case .saved = model.phase { Haptics.success() }
                    }
                }
                .buttonStyle(GoldButtonStyle(compact: true))
                .disabled(!canExport)
                .accessibilityIdentifier("carousel.export")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    source
                    panelStrip
                    statusLine
                }
                .padding(Spacing.m)
            }
            controls
        }
        .background(AurumColor.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isPicking) {
            MediaPickerView(app: app, required: 1, title: String(localized: "Choose a wide photo")) { picked in
                isPicking = false
                Task { await model.setPhoto(picked) }
            } onCancel: {
                isPicking = false
            }
        }
        .onAppear { if model.photo == nil { isPicking = true } }
    }

    private var canExport: Bool {
        switch model.phase {
        case .ready, .saved, .failed: return model.photo != nil
        default: return false
        }
    }

    /// The whole photo with the cut lines.
    @ViewBuilder
    private var source: some View {
        if model.photo == nil {
            Button { isPicking = true } label: {
                AtelierImage(image: nil, placeholder: String(localized: "Choose a wide photo to begin"))
                    .frame(height: 220)
            }
            .buttonStyle(.plain)
        } else if model.phase == .loading {
            ProgressView().tint(AurumColor.accent).frame(maxWidth: .infinity, minHeight: 160)
        }
    }

    private var panelStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(model.panels.enumerated()), id: \.offset) { index, panel in
                    Image(decorative: panel, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 300)
                        .overlay(alignment: .bottomLeading) {
                            Text(verbatim: "\(index + 1)/\(model.panels.count)")
                                .aurumText(.label, color: AurumColor.textPrimary)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Capsule().fill(.black.opacity(0.45)))
                                .padding(6)
                        }
                        .accessibilityLabel(String(localized: "Panel \(index + 1) of \(model.panels.count)"))
                        .accessibilityAddTraits(.isImage)
                }
            }
        }
        .animation(Motion.respectingReduceMotion(Motion.velvet), value: model.panels.count)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.phase {
        case .exporting(let done, let total):
            HStack(spacing: Spacing.s) {
                ProgressView(value: Double(done), total: Double(max(total, 1))).tint(AurumColor.accent)
                Text("Saving \(done) of \(total)…").aurumText(.caption, color: AurumColor.textSecondary)
            }
        case .saved(let n):
            Text("\(n) panels saved to Photos, in order.").aurumText(.caption, color: AurumColor.accent)
        case .failed(let message):
            Text(message).aurumText(.caption, color: AurumColor.textSecondary)
        default:
            if model.photo != nil {
                Text(model.entitlement == .free
                     ? String(localized: "Post the panels in order and they swipe as one photo. Free exports carry a small mark on the last panel.")
                     : String(localized: "Post the panels in order and they swipe as one photo."))
                    .aurumText(.caption, color: AurumColor.textTertiary)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Text("Panels").aurumText(.label, color: AurumColor.textTertiary)
                Spacer()
                Stepper(value: Binding(get: { model.count }, set: { model.setCount($0); Haptics.detent() }), in: CarouselViewModel.countRange) {
                    Text(verbatim: "\(model.count)").aurumText(.headline).monospacedDigit()
                }
                .fixedSize()
                .accessibilityLabel(String(localized: "Panels"))
                .accessibilityValue(Text(verbatim: "\(model.count)"))
            }
            HStack(spacing: Spacing.xs) {
                ForEach(CarouselViewModel.aspects, id: \.self) { aspect in
                    Chip(aspect.label, isSelected: model.aspect == aspect) { model.aspect = aspect }
                }
                Spacer()
                Button("Change photo") { isPicking = true }.buttonStyle(TextActionButtonStyle())
            }
        }
        .padding(Spacing.m)
        .background(
            AurumColor.surface
                .overlay(alignment: .top) { Rectangle().fill(AurumColor.goldHairline).frame(height: 0.5) }
                .ignoresSafeArea(edges: .bottom)
        )
    }
}
