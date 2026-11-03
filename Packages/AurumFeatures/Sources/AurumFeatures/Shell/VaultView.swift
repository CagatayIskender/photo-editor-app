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
                    .aurumEntrance(0, distance: 8)
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
                    Chip(s.title, isSelected: section == s) {
                        withAnimation(Motion.respectingReduceMotion(Motion.velvet)) { section = s }
                    }
                }
            }
            .aurumEntrance(1, distance: 8)
            ScrollView {
                Group {
                    switch section {
                    case .drafts: drafts
                    case .presets: presets
                    }
                }
                .transition(.opacity)
                .id(section)
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.top, Spacing.m)
        .background(
            ZStack {
                AurumColor.background
                AmbientGlow(intensity: 0.45)
            }
            .ignoresSafeArea()
        )
        .task { await app.refreshVault() }
        .sheet(isPresented: $isPaywallPresented) {
            PaywallView(app: app, trigger: "vault") { isPaywallPresented = false }
        }
    }

    @ViewBuilder
    private var drafts: some View {
        if app.drafts.isEmpty {
            EmptyVaultMessage(icon: .vault, title: String(localized: "No drafts yet"), message: String(localized: "Edits you leave unfinished are kept here."))
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.m) {
                ForEach(Array(app.drafts.enumerated()), id: \.element.id) { index, draft in
                    Button { Task { await app.openDraft(id: draft.id) } } label: {
                        DraftTile(draft: draft, width: 104)
                    }
                    .buttonStyle(.pressable)
                    .aurumEntrance(min(index, 8), distance: 10)
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
            EmptyVaultMessage(icon: .sparkle, title: String(localized: "No presets yet"), message: String(localized: "Save an edit as a preset in the Studio to reuse it on any photo."))
        } else {
            VStack(spacing: 0) {
                ForEach(Array(app.presets.enumerated()), id: \.element.id) { index, preset in
                    PresetRow(preset: preset, app: app)
                        .aurumEntrance(min(index, 8), distance: 8)
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
    var icon: AurumIcon = .vault
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: Spacing.xs) {
            emblem
                .padding(.bottom, Spacing.s)
                .aurumEntrance(0)
            Text(title).aurumText(.editorial)
                .aurumEntrance(1, distance: 8)
            Text(message).aurumText(.body, color: AurumColor.textTertiary).multilineTextAlignment(.center)
                .aurumEntrance(2, distance: 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xxl)
    }

    /// An icon in two quiet rings, drawn from shapes.
    private var emblem: some View {
        ZStack {
            Circle().stroke(AurumColor.hairline, lineWidth: 1).frame(width: 104, height: 104)
            Circle().stroke(AurumColor.goldHairline, lineWidth: 1).frame(width: 76, height: 76)
            Circle().fill(AurumColor.accent.opacity(0.07)).frame(width: 76, height: 76)
            IconView(icon, size: 30).foregroundColor(AurumColor.accent)
        }
        .frame(width: 104, height: 104)
        .accessibilityHidden(true)
    }
}
