import SwiftUI
import AurumCore
import AurumDesign

/// Three short pages: the promise, choosing up to three aesthetics, and
/// photo access explained before the system prompt appears.
struct OnboardingView: View {
    @ObservedObject var app: AppModel
    @State private var page = 0
    @State private var vibes: [String] = []

    static let maxVibes = 3

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcome.tag(0)
                aesthetics.tag(1)
                access.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            pageDots.padding(.bottom, Spacing.l)
            primaryButton
                .padding(.horizontal, Spacing.l)
                .padding(.bottom, Spacing.m)
        }
        .background(AurumColor.background.ignoresSafeArea())
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Spacer()
            Text("AURUM").aurumText(.label, color: AurumColor.accent)
            Text("Make every photo\nlook considered.").aurumText(.display)
            Text("Pick a photo, choose a look, export. Most edits take less than ten seconds.")
                .aurumText(.body, color: AurumColor.textSecondary)
            Spacer().frame(height: Spacing.xxl)
        }
        .padding(.horizontal, Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var aesthetics: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Spacer().frame(height: Spacing.xxl)
            Text("Choose your aesthetic").aurumText(.title)
            Text("Pick up to three. We'll start your edits from these.")
                .aurumText(.body, color: AurumColor.textSecondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Spacing.s), GridItem(.flexible(), spacing: Spacing.s)], spacing: Spacing.s) {
                    ForEach(app.catalog.collections) { collection in
                        vibeCard(collection)
                    }
                }
                .padding(.vertical, Spacing.xs)
            }
        }
        .padding(.horizontal, Spacing.l)
    }

    private func vibeCard(_ collection: LookCollection) -> some View {
        let isSelected = vibes.contains(collection.id)
        let swatch = app.catalog.looks(in: collection.id).first?.swatch.map(Color.init(hex:)) ?? [AurumColor.surface]
        return Button {
            if isSelected {
                vibes.removeAll { $0 == collection.id }
            } else if vibes.count < Self.maxVibes {
                vibes.append(collection.id)
            } else {
                Haptics.warning()
                return
            }
            Haptics.detent()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Spacer()
                Text(collection.name).aurumText(.editorial)
                Text(collection.tagline).aurumText(.caption, color: AurumColor.textSecondary).lineLimit(2)
            }
            .padding(Spacing.s)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            .background(
                LinearGradient(colors: swatch, startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom))
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.thumbnail))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.thumbnail)
                    .stroke(isSelected ? AurumColor.accent : AurumColor.hairline, lineWidth: isSelected ? 1.5 : 0.5)
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    IconView(.check, size: 16).foregroundColor(AurumColor.onAccent)
                        .padding(5).background(Circle().fill(AurumColor.accent)).padding(Spacing.xs)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(collection.name)
        .accessibilityHint(collection.tagline)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Spacer()
            IconView(.camera, size: 40).foregroundColor(AurumColor.accent)
            Text("Your photos stay yours").aurumText(.title)
            Text("AURUM edits on your iPhone. Photos are never uploaded unless you use an AI tool, and it always asks first. You can choose to share only some photos.")
                .aurumText(.body, color: AurumColor.textSecondary)
            Spacer().frame(height: Spacing.xxl)
        }
        .padding(.horizontal, Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Controls

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(i == page ? AurumColor.accent : AurumColor.hairline)
                    .frame(width: i == page ? 18 : 6, height: 6)
            }
        }
        .animation(Motion.respectingReduceMotion(Motion.velvet), value: page)
        .accessibilityElement()
        .accessibilityLabel("Page \(page + 1) of 3")
    }

    private var primaryButton: some View {
        Button {
            switch page {
            case 0, 1:
                withAnimation(Motion.respectingReduceMotion(Motion.atelier)) { page += 1 }
            default:
                Task {
                    _ = await app.deps.photos.requestAccess()
                    app.completeOnboarding(vibes: vibes)
                }
            }
        } label: {
            Text(page == 0 ? "Begin" : page == 1 ? (vibes.isEmpty ? "Skip for now" : "Continue") : "Allow photo access")
        }
        .buttonStyle(GoldButtonStyle())
        .accessibilityIdentifier("onboarding.primary")
    }
}
