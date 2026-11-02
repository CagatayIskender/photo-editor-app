import SwiftUI
import AurumCore
import AurumDesign
import AurumRender

/// Format, then Save or Share. If the edit uses member items, the sheet
/// lists them and offers two equal choices: join, or export without them.
struct ExportSheet: View {
    @StateObject private var model: ExportViewModel
    @ObservedObject var app: AppModel
    @Environment(\.dismiss) private var dismiss

    init(model: ExportViewModel, app: AppModel) {
        _model = StateObject(wrappedValue: model)
        self.app = app
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack {
                Text("Export").aurumText(.title)
                Spacer()
                IconButton(.close, label: "Close") { dismiss() }
            }
            content
        }
        .padding(Spacing.m)
        .background(AurumColor.surface.ignoresSafeArea())
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.isPaywallPresented) {
            PaywallView(app: app, trigger: "export") {
                model.isPaywallPresented = false
                model.membershipChanged(to: app.entitlement)
            }
        }
        .onChange(of: app.entitlement) { model.membershipChanged(to: $0) }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .rendering:
            HStack(spacing: Spacing.s) {
                ProgressView().tint(AurumColor.accent)
                Text("Finishing your photo…").aurumText(.body, color: AurumColor.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        case .saved:
            done(title: "Saved to Photos")
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
            switch model.decision {
            case .requiresMembership(let items): membershipChoice(items)
            case .allowed: exportControls
            }
        }
    }

    private var exportControls: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(spacing: Spacing.xs) {
                ForEach(RenderEngine.ExportFormat.allCases, id: \.self) { f in
                    Chip(f.fileExtension.uppercased(), isSelected: model.format == f) { model.format = f }
                }
            }
            HStack(spacing: Spacing.s) {
                Button {
                    Task { await model.export(toPhotos: true); if model.phase == .saved { Haptics.success() } }
                } label: {
                    Label { Text("Save") } icon: { IconView(.download, size: 18) }
                }
                .buttonStyle(GoldButtonStyle())
                .accessibilityIdentifier("export.save")
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
            Text("This edit uses member items").aurumText(.headline)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { item in
                    HStack(spacing: Spacing.xs) {
                        CrownBadge(size: 16)
                        Text(item.displayName).aurumText(.body)
                    }
                }
            }
            Button("Join \(app.deps.brand.membershipName)") { model.showPaywall() }
                .buttonStyle(GoldButtonStyle())
                .accessibilityIdentifier("export.join")
            Button("Export without them") { model.exportWithoutPremium() }
                .buttonStyle(GlassButtonStyle())
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("export.withoutPremium")
        }
    }

    private func done(title: String) -> some View {
        VStack(spacing: Spacing.s) {
            IconView(.check, size: 32).foregroundColor(AurumColor.accent)
            Text(title).aurumText(.headline)
            Button("Done") { dismiss() }.buttonStyle(GoldButtonStyle())
        }
        .frame(maxWidth: .infinity)
    }
}
