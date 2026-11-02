import SwiftUI
import AurumCore
import AurumDesign

/// Three short pages: the promise, choosing up to three aesthetics, and
/// photo access explained before the system prompt appears.
struct OnboardingView: View {
    @ObservedObject var app: AppModel
    @State private var page = 0
    @State private var vibes: [String] = []
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let maxVibes = 3

    var body: some View {
        ZStack {
            AurumColor.background.ignoresSafeArea()
            AmbientGlow(intensity: page == 0 ? 1.2 : 0.7)
                .ignoresSafeArea()
                .animation(Motion.respectingReduceMotion(Motion.velvet), value: page)
            content
        }
        .onAppear {
            guard !appeared else { return }
            appeared = true
        }
    }

    private var content: some View {
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
                .reveal(3, shown: appeared, reduceMotion: reduceMotion)
        }
    }

    /// True once the view has appeared and `target` is the visible page.
    private func isShown(_ target: Int) -> Bool { appeared && page == target }

    // MARK: Pages

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Spacer()
            Text("AURUM").aurumText(.label, color: AurumColor.accent)
                .reveal(0, shown: isShown(0), reduceMotion: reduceMotion)
            Text("Make every photo\nlook considered.").aurumText(.display)
                .reveal(1, shown: isShown(0), reduceMotion: reduceMotion)
            Text("Pick a photo, choose a look, export. Most edits take less than ten seconds.")
                .aurumText(.body, color: AurumColor.textSecondary)
                .reveal(2, shown: isShown(0), reduceMotion: reduceMotion)
            Spacer().frame(height: Spacing.xxl)
        }
        .padding(.horizontal, Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var aesthetics: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Spacer().frame(height: Spacing.xxl)
            Text("Choose your aesthetic").aurumText(.title)
                .reveal(0, shown: isShown(1), reduceMotion: reduceMotion)
            Text("Pick up to three. We'll start your edits from these.")
                .aurumText(.body, color: AurumColor.textSecondary)
                .reveal(1, shown: isShown(1), reduceMotion: reduceMotion)
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Spacing.s), GridItem(.flexible(), spacing: Spacing.s)], spacing: Spacing.s) {
                    ForEach(Array(app.catalog.collections.enumerated()), id: \.element.id) { index, collection in
                        vibeCard(collection)
                            .reveal(index + 2, shown: isShown(1), reduceMotion: reduceMotion)
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
                withAnimation(Motion.respectingReduceMotion(Motion.atelier)) { vibes.removeAll { $0 == collection.id } }
            } else if vibes.count < Self.maxVibes {
                withAnimation(Motion.respectingReduceMotion(Motion.atelier)) { vibes.append(collection.id) }
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
                        .transition(.aurumPop)
                }
            }
            .shadow(color: AurumColor.accent.opacity(isSelected ? 0.22 : 0), radius: 12, y: 4)
            .scaleEffect(isSelected ? 1.015 : 1)
            .animation(Motion.respectingReduceMotion(Motion.atelier), value: isSelected)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(collection.name)
        .accessibilityHint(collection.tagline)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Spacer()
            accessEmblem
                .reveal(0, shown: isShown(2), reduceMotion: reduceMotion)
            Text("Your photos stay yours").aurumText(.title)
                .reveal(1, shown: isShown(2), reduceMotion: reduceMotion)
            Text("AURUM edits on your iPhone, and your photos are never uploaded. You can choose to share only some photos.")
                .aurumText(.body, color: AurumColor.textSecondary)
                .reveal(2, shown: isShown(2), reduceMotion: reduceMotion)
            Spacer().frame(height: Spacing.xxl)
        }
        .padding(.horizontal, Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The camera icon inside two quiet concentric rings.
    private var accessEmblem: some View {
        ZStack {
            Circle().stroke(AurumColor.hairline, lineWidth: 1).frame(width: 112, height: 112)
            Circle().stroke(AurumColor.goldHairline, lineWidth: 1).frame(width: 84, height: 84)
            Circle().fill(AurumColor.accent.opacity(0.08)).frame(width: 84, height: 84)
            IconView(.camera, size: 36).foregroundColor(AurumColor.accent)
        }
        .frame(width: 112, height: 112)
        .accessibilityHidden(true)
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

    private var primaryTitle: String {
        switch page {
        case 0: return String(localized: "Begin")
        case 1: return vibes.isEmpty ? String(localized: "Skip for now") : String(localized: "Continue")
        default: return String(localized: "Allow photo access")
        }
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
            Text(primaryTitle)
                .contentTransition(.opacity)
                .animation(Motion.respectingReduceMotion(Motion.velvet), value: primaryTitle)
        }
        .buttonStyle(GoldButtonStyle())
        .accessibilityIdentifier("onboarding.primary")
    }
}

private extension View {
    /// Fades and lifts the view in when `shown` turns true, staggered by `index`.
    /// Hidden pages rest slightly dimmed so a swipe never reveals an empty page.
    func reveal(_ index: Int, shown: Bool, reduceMotion: Bool) -> some View {
        self
            .opacity(shown ? 1 : 0.25)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .animation(
                reduceMotion ? Animation.easeOut(duration: 0.2) : Motion.atelier.delay(0.06 + Double(min(index, 8)) * 0.05),
                value: shown
            )
    }
}
