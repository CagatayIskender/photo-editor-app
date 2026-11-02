import SwiftUI
import AurumCore
import AurumDesign
import AurumServices

/// The user's own work: drafts to reopen and presets to reuse or share.
struct VaultView: View {
    @ObservedObject var app: AppModel
    @State private var section: VaultSection = .drafts
    @State private var isPaywallPresented = false

    enum VaultSection: String, CaseIterable {
        case drafts = "Drafts"
        case presets = "Presets"

        var title: String {
            switch self {
            case .drafts: return String(localized: "Drafts")
            case .presets: return String(localized: "Presets")
            }
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: Spacing.s)]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack {
                Text("Vault").aurumText(.title)
                Spacer()
                if app.entitlement == .free {
                    Button { isPaywallPresented = true } label: {
                        HStack(spacing: 4) { CrownBadge(size: 14); Text("Join") }
                    }
                    .buttonStyle(GlassButtonStyle())
                    .accessibilityLabel("Join \(app.deps.brand.membershipName)")
                }
            }
            HStack(spacing: Spacing.xs) {
                ForEach(VaultSection.allCases, id: \.self) { s in
                    Chip(s.title, isSelected: section == s) { section = s }
                }
            }
            ScrollView {
                switch section {
                case .drafts: drafts
                case .presets: presets
                }
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.top, Spacing.m)
        .background(AurumColor.background.ignoresSafeArea())
        .task { await app.refreshVault() }
        .sheet(isPresented: $isPaywallPresented) {
            PaywallView(app: app, trigger: "vault") { isPaywallPresented = false }
        }
    }

    @ViewBuilder
    private var drafts: some View {
        if app.drafts.isEmpty {
            EmptyVaultMessage(title: String(localized: "No drafts yet"), message: String(localized: "Edits you leave unfinished are kept here."))
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.m) {
                ForEach(app.drafts) { draft in
                    Button { Task { await app.openDraft(id: draft.id) } } label: {
                        DraftTile(draft: draft, width: 104)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) { Task { await app.deleteDraft(id: draft.id) } } label: {
                            Label("Delete draft", systemImage: "trash")
                        }
                    }
                    .accessibilityAction(named: "Delete draft") { Task { await app.deleteDraft(id: draft.id) } }
                }
            }
        }
    }

    @ViewBuilder
    private var presets: some View {
        if app.presets.isEmpty {
            EmptyVaultMessage(title: String(localized: "No presets yet"), message: String(localized: "Save an edit as a preset in the Studio to reuse it on any photo."))
        } else {
            VStack(spacing: 0) {
                ForEach(app.presets) { preset in
                    PresetRow(preset: preset, app: app)
                    Divider().overlay(AurumColor.hairline)
                }
            }
        }
    }
}

struct PresetRow: View {
    let preset: Preset
    @ObservedObject var app: AppModel

    private var shareURL: URL? {
        try? PresetLinkCodec(scheme: app.deps.brand.urlScheme).link(for: preset)
    }

    private var lookNames: String {
        let names = preset.operations.compactMap { op -> String? in
            if case .look(let l) = op.kind { return app.catalog.look(id: l.lookID)?.name }
            return nil
        }
        return names.isEmpty ? String(localized: "Adjustments only") : names.joined(separator: " + ")
    }

    var body: some View {
        HStack(spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name).aurumText(.headline)
                Text(lookNames).aurumText(.caption, color: AurumColor.textTertiary)
            }
            Spacer()
            if let shareURL {
                ShareLink(item: shareURL, subject: Text(preset.name), message: Text("A preset made in AURUM")) {
                    IconView(.share, size: 20).foregroundColor(AurumColor.textSecondary).frame(width: Size.touch, height: Size.touch)
                }
                .accessibilityLabel("Share \(preset.name)")
            }
            Button("Use") { app.usePreset(preset) }
                .buttonStyle(GoldButtonStyle(compact: true))
                .accessibilityLabel("Use \(preset.name) on a photo")
        }
        .padding(.vertical, Spacing.s)
        .contextMenu {
            Button(role: .destructive) { Task { await app.deletePreset(id: preset.id) } } label: {
                Label("Delete preset", systemImage: "trash")
            }
        }
    }
}

struct EmptyVaultMessage: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: Spacing.xs) {
            Text(title).aurumText(.editorial)
            Text(message).aurumText(.body, color: AurumColor.textTertiary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xxl)
    }
}
