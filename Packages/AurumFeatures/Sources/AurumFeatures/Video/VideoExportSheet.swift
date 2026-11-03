import SwiftUI
import AurumCore
import AurumDesign

/// Save or Share a finished video. If it uses member items, the sheet lists
/// them and offers two equal choices: join, or export without them.
struct VideoExportSheet: View {
    @StateObject private var model: VideoExportViewModel
    @ObservedObject var app: AppModel
    @Environment(\.dismiss) private var dismiss

    init(model: VideoExportViewModel, app: AppModel) {
        _model = StateObject(wrappedValue: model)
        self.app = app
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack {
                Text("Export video").aurumText(.title)
                Spacer()
                IconButton(.close, label: String(localized: "Close")) { dismiss() }
                    .disabled(isRendering)
            }
            content
        }
        .animation(Motion.respectingReduceMotion(Motion.atelier), value: phaseKey)
        .padding(Spacing.m)
        .formSheetWidth()
        .background(AurumColor.surface.ignoresSafeArea())
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isRendering)
        .sheet(isPresented: $model.isPaywallPresented) {
            PaywallView(app: app, trigger: "video_export") {
                model.isPaywallPresented = false
                model.membershipChanged(to: app.entitlement)
            }
        }
        .onChange(of: app.entitlement) { model.membershipChanged(to: $0) }
    }

    /// Changes when the phase kind changes (not on every progress tick).
    private var phaseKey: Int {
        switch model.phase {
        case .ready: return 0
        case .rendering: return 1
        case .saved: return 2
        case .shareReady: return 3
        case .failed: return 4
        }
    }

    private var isRendering: Bool {
        if case .rendering = model.phase { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .rendering(let progress):
            VStack(spacing: Spacing.s) {
                GoldProgressRing(progress: progress, size: 64)
                    .accessibilityLabel("Export progress")
                Text("Finishing your video…").aurumText(.body, color: AurumColor.textSecondary)
                Text(verbatim: "\(Int((progress * 100).rounded()))%")
                    .aurumText(.caption, color: AurumColor.textTertiary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .transition(.opacity)
        case .saved:
            VStack(spacing: Spacing.s) {
                DrawnCheckmark(size: 56)
                Text("Saved to Photos").aurumText(.headline)
                Button("Done") { dismiss() }.buttonStyle(GoldButtonStyle())
            }
            .frame(maxWidth: .infinity)
            .transition(.aurumPop)
        case .shareReady(let url):
            VStack(spacing: Spacing.s) {
                ShareLink(item: url) {
                    Label { Text("Share") } icon: { IconView(.share, size: 18) }
                }
                .buttonStyle(GoldButtonStyle())
                Button("Done") { dismiss() }.buttonStyle(TextActionButtonStyle())
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(message).aurumText(.body, color: AurumColor.textSecondary)
                Button("Try again") { model.reset() }.buttonStyle(GoldButtonStyle())
            }
        case .ready:
            if model.decision.requiresMembership {
                membershipChoice(model.decision.premiumItems)
            } else {
                exportControls
            }
        }
    }

    private var exportControls: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(spacing: Spacing.s) {
                Button {
                    Task { await model.export(toPhotos: true); if model.phase == .saved { Haptics.success() } }
                } label: {
                    Label { Text("Save") } icon: { IconView(.download, size: 18) }
                }
                .buttonStyle(GoldButtonStyle())
                .accessibilityIdentifier("videoExport.save")
                Button {
                    Task { await model.export(toPhotos: false) }
                } label: {
                    Label { Text("Share") } icon: { IconView(.share, size: 18) }
                }
                .buttonStyle(GlassButtonStyle())
            }
            HStack(spacing: Spacing.xs) {
                Text(model.summary).aurumText(.caption, color: AurumColor.textTertiary)
                if model.entitlement == .free {
                    Button("Remove mark") { model.showPaywall() }
                        .buttonStyle(TextActionButtonStyle())
                }
            }
        }
    }

    private func membershipChoice(_ items: [PremiumItem]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("This video uses member items").aurumText(.headline)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { item in
                    HStack(spacing: Spacing.xs) {
                        CrownBadge(size: 16)
                        Text(item.localizedName).aurumText(.body)
                    }
                }
            }
            Button("Join \(app.deps.brand.membershipName)") { model.showPaywall() }
                .buttonStyle(GoldButtonStyle())
                .accessibilityIdentifier("videoExport.join")
            if model.canExportWithoutPremium {
                Button("Export without them") { model.exportWithoutPremium() }
                    .buttonStyle(GlassButtonStyle())
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("videoExport.withoutPremium")
            } else {
                Text("This template is for members, so it can't be exported without membership.")
                    .aurumText(.caption, color: AurumColor.textTertiary)
            }
        }
    }
}
