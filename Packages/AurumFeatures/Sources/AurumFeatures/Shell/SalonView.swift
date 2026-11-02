import SwiftUI
import AurumCore
import AurumDesign
import AurumServices

/// The home tab: a featured collection, the user's drafts to continue, and
/// every collection as a row of looks. Tapping a look opens the picker with
/// that look queued, so the photo opens already wearing it.
struct SalonView: View {
    @ObservedObject var app: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                header
                hero
                createRow
                AtelierCreateRow(app: app)
                DropsSection(app: app)
                if !app.drafts.isEmpty { continueRow }
                ForEach(orderedCollections) { collection in
                    collectionRow(collection)
                }
            }
            .padding(.bottom, Spacing.xl)
        }
        .background(AurumColor.background.ignoresSafeArea())
    }

    /// The user's chosen aesthetics first, then the rest in catalogue order.
    private var orderedCollections: [LookCollection] {
        let vibes = app.deps.preferences.vibes
        let chosen = vibes.compactMap { id in app.catalog.collections.first { $0.id == id } }
        return chosen + app.catalog.collections.filter { !vibes.contains($0.id) }
    }

    private var header: some View {
        HStack {
            Text("Salon").aurumText(.title)
            Spacer()
            if app.entitlement == .member {
                HStack(spacing: 4) {
                    CrownBadge(size: 16)
                    Text("Member").aurumText(.label, color: AurumColor.accent)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.top, Spacing.m)
    }

    private var hero: some View {
        let collection = app.catalog.collections.first { $0.id == app.config.salonHeroCollection } ?? app.catalog.collections.first
        let looks = collection.map { app.catalog.looks(in: $0.id) } ?? []
        let swatch = looks.first?.swatch.map(Color.init(hex:)) ?? [AurumColor.surface, AurumColor.surfaceRaised]
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            Spacer()
            Text("FEATURED COLLECTION").aurumText(.label, color: AurumColor.accent)
            Text(collection?.name ?? "").aurumText(.display)
            Text(collection?.tagline ?? "").aurumText(.body, color: AurumColor.textSecondary)
            Button("Start editing") { app.startCreating(withLook: looks.first?.id) }
                .buttonStyle(GoldButtonStyle(compact: true))
                .padding(.top, Spacing.xs)
                .accessibilityIdentifier("salon.start")
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, minHeight: 320, alignment: .leading)
        .background(
            LinearGradient(colors: swatch, startPoint: .topTrailing, endPoint: .bottomLeading)
                .overlay(LinearGradient(colors: [.clear, AurumColor.background.opacity(0.9)], startPoint: .top, endPoint: .bottom))
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .padding(.horizontal, Spacing.m)
    }

    /// Video, templates and the camera, next to photo editing.
    private var createRow: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Create").aurumText(.headline).padding(.horizontal, Spacing.m)
            HStack(spacing: Spacing.s) {
                CreateTile(icon: .layers, title: String(localized: "Video"), subtitle: String(localized: "Clips and photos")) {
                    app.startVideo()
                }
                .accessibilityIdentifier("salon.video")
                CreateTile(icon: .sparkle, title: String(localized: "Templates"), subtitle: String(localized: "Cut to the beat")) {
                    app.openTemplates()
                }
                .accessibilityIdentifier("salon.templates")
                CreateTile(icon: .camera, title: String(localized: "Camera"), subtitle: String(localized: "Shoot in a look")) {
                    app.openCamera()
                }
                .accessibilityIdentifier("salon.camera")
            }
            .padding(.horizontal, Spacing.m)
        }
    }

    private var continueRow: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Continue").aurumText(.headline).padding(.horizontal, Spacing.m)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.s) {
                    ForEach(app.drafts.prefix(10)) { draft in
                        Button { Task { await app.openDraft(id: draft.id) } } label: {
                            DraftTile(draft: draft, width: 104)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Spacing.m)
            }
        }
    }

    private func collectionRow(_ collection: LookCollection) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(collection.name).aurumText(.editorial)
                Text(collection.tagline).aurumText(.caption, color: AurumColor.textTertiary)
            }
            .padding(.horizontal, Spacing.m)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.s) {
                    ForEach(app.catalog.looks(in: collection.id)) { look in
                        Button { app.startCreating(withLook: look.id) } label: {
                            LookThumbnail(name: look.name, image: nil, swatch: look.swatch.map(Color.init(hex:)), isSelected: false, isPremium: look.tier == .member)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Pick a photo to edit with this look")
                    }
                }
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, 3)
            }
        }
    }
}

/// A saved draft's thumbnail and title.
struct DraftTile: View {
    let draft: DraftSummary
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let url = draft.thumbnailURL, let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    AurumColor.surfaceRaised
                }
            }
            .frame(width: width, height: width * 1.25)
            .clipShape(RoundedRectangle(cornerRadius: Radius.thumbnail))
            Text(draft.title).aurumText(.caption).lineLimit(1)
            Text(draft.modifiedAt, style: .relative).aurumText(.label, color: AurumColor.textTertiary)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Draft, \(draft.title)")
        .accessibilityAddTraits(.isButton)
    }
}

/// A Salon entry into a create flow: icon, name and a short line.
struct CreateTile: View {
    let icon: AurumIcon
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.detent()
            action()
        } label: {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                IconView(icon, size: 22)
                    .foregroundColor(AurumColor.accent)
                    .padding(.bottom, Spacing.xs)
                Text(title).aurumText(.headline)
                Text(subtitle).aurumText(.caption, color: AurumColor.textTertiary).lineLimit(2)
            }
            .padding(Spacing.s)
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Radius.thumbnail).fill(AurumColor.surface))
            .overlay(RoundedRectangle(cornerRadius: Radius.thumbnail).stroke(AurumColor.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Radius.thumbnail))
        }
        .buttonStyle(CreateTileButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// A gentle press: the tile settles slightly, without motion when reduced.
struct CreateTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Motion.respectingReduceMotion(Motion.velvet), value: configuration.isPressed)
    }
}
