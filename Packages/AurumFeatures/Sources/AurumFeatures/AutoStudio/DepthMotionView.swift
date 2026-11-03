import SwiftUI
import AurumCore
import AurumDesign
import AurumRender

/// 3D Motion: a still photo given depth and a slow camera move, previewed
/// live and exported as a looping video.
struct DepthMotionView: View {
    @ObservedObject var app: AppModel
    @StateObject private var model: DepthMotionViewModel
    @State private var isPicking = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(app: AppModel) {
        self.app = app
        _model = StateObject(wrappedValue: DepthMotionViewModel(deps: app.deps, entitlement: { [weak app] in app?.entitlement ?? .free }))
    }

    var body: some View {
        VStack(spacing: 0) {
            AtelierHeader(title: String(localized: "3D Motion"), onClose: { app.closeFlow() })
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, Spacing.m)
                .animation(Motion.respectingReduceMotion(Motion.atelier), value: model.phase)
            controls
        }
        .background(
            ZStack {
                AurumColor.background
                AmbientGlow(intensity: 0.5)
            }
            .ignoresSafeArea()
        )
        .preferredColorScheme(.dark)
        .task(id: previewKey) { await model.runPreview(reduceMotion: reduceMotion) }
        .sheet(isPresented: $isPicking) {
            MediaPickerView(app: app, required: 1, title: String(localized: "Choose a photo")) { picked in
                isPicking = false
                Task { await model.setPhoto(picked) }
            } onCancel: {
                isPicking = false
            }
        }
        .sheet(isPresented: $model.isPaywallPresented) {
            PaywallView(app: app, trigger: "depthMotion") {
                model.isPaywallPresented = false
            }
        }
        .onAppear { if model.photo == nil { isPicking = true } }
    }

    /// Restarts the preview when it becomes ready, and (for the still preview
    /// under Reduce Motion) when the move changes.
    private var previewKey: String {
        let ready = model.phase == .ready || model.phase == .saved
        return reduceMotion ? "\(ready)-\(model.preset.rawValue)-\(model.intensity)" : "\(ready)"
    }

    @ViewBuilder
    private var preview: some View {
        switch model.phase {
        case .empty:
            Button { isPicking = true } label: {
                AtelierImage(image: nil, placeholder: String(localized: "Choose a photo to begin"))
            }
            .buttonStyle(.pressable)
        case .loading:
            VStack(spacing: Spacing.s) {
                GoldProgressRing(progress: nil, size: 40)
                Text("Finding depth…").aurumText(.caption, color: AurumColor.textSecondary)
            }
            .transition(.opacity)
        default:
            AtelierImage(image: model.frame)
                .accessibilityLabel(String(localized: "Preview of your photo with the \(model.preset.title) move"))
                .accessibilityAddTraits(.isImage)
                .overlay(alignment: .topLeading) {
                    if !model.usesRealDepth {
                        Text("Estimated depth").aurumText(.label, color: AurumColor.textSecondary)
                            .padding(.horizontal, Spacing.xs).padding(.vertical, 4)
                            .background(Capsule().fill(.black.opacity(0.45)))
                            .padding(Spacing.xs)
                    }
                }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.xs) {
                ForEach(DepthMotionPreset.allCases, id: \.self) { preset in
                    Chip(preset.title, isSelected: model.preset == preset, leadingIcon: preset.tier == .member ? .crown : nil) {
                        model.preset = preset
                        Haptics.detent()
                    }
                }
            }
            AurumSlider(value: $model.intensity, in: 0...1, label: String(localized: "Depth"))
            status
            HStack(spacing: Spacing.s) {
                Button("Change photo") { isPicking = true }
                    .buttonStyle(TextActionButtonStyle())
                Spacer()
                Button {
                    Task {
                        await model.export()
                        if model.phase == .saved { Haptics.success() }
                    }
                } label: {
                    Label { Text("Save video") } icon: { IconView(.download, size: 18) }
                }
                .buttonStyle(GoldButtonStyle(compact: true))
                .disabled(model.photo == nil || !(model.phase == .ready || model.phase == .saved))
                .accessibilityIdentifier("depthMotion.export")
            }
        }
        .padding(Spacing.m)
        .background(
            AurumColor.surface
                .overlay(alignment: .top) { Rectangle().fill(AurumColor.goldHairline).frame(height: 0.5) }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .exporting(let progress):
            HStack(spacing: Spacing.s) {
                GoldProgressRing(progress: progress, size: 26)
                Text("Rendering your video…").aurumText(.caption, color: AurumColor.textSecondary)
            }
            .transition(.aurumRise)
        case .saved:
            HStack(spacing: Spacing.xs) {
                DrawnCheckmark(size: 22)
                Text("Saved to Photos").aurumText(.caption, color: AurumColor.accent)
            }
            .transition(.aurumPop)
        case .failed(let message):
            Text(message).aurumText(.caption, color: AurumColor.textSecondary)
        default:
            if model.requiresMembership {
                HStack(spacing: Spacing.xs) {
                    CrownBadge(size: 14)
                    Text("\(model.preset.title) is a member move. Preview freely; membership is asked for when you save.")
                        .aurumText(.caption, color: AurumColor.textTertiary)
                }
            } else {
                Text(model.entitlement == .free ? String(localized: "A 4-second loop, with a small mark on free exports.") : String(localized: "A 4-second loop at full quality."))
                    .aurumText(.caption, color: AurumColor.textTertiary)
            }
        }
    }
}
