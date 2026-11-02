import SwiftUI
import AurumCore
import AurumDesign
import AurumRender
import AurumServices

/// The Auto Studio: one photo, suggested one-tap fixes found on the iPhone,
/// and every tool as a card. Nothing is generated or uploaded.
struct AutoStudioView: View {
    @ObservedObject var app: AppModel
    @StateObject private var model: AutoStudioViewModel
    @State private var path: [AutoFeature] = []
    @State private var hasAppeared = false
    @State private var isPicking = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Fixed columns on a phone; on iPad as many as the width allows.
    private var columns: [GridItem] {
        if horizontalSizeClass == .regular {
            return [GridItem(.adaptive(minimum: 200), spacing: Spacing.s)]
        }
        return [GridItem(.flexible(), spacing: Spacing.s), GridItem(.flexible(), spacing: Spacing.s)]
    }

    init(app: AppModel) {
        self.app = app
        _model = StateObject(wrappedValue: AutoStudioViewModel(deps: app.deps, entitlement: { [weak app] in app?.entitlement ?? .free }))
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    intro
                    photoSection
                    suggestionSection
                    LazyVGrid(columns: columns, spacing: Spacing.s) {
                        ForEach(Array(AutoFeature.allCases.enumerated()), id: \.element) { index, feature in
                            Button {
                                model.select(feature)
                                path.append(feature)
                                Haptics.detent()
                            } label: {
                                AutoFeatureCard(feature: feature)
                            }
                            .buttonStyle(CreateTileButtonStyle())
                            .opacity(hasAppeared || reduceMotion ? 1 : 0)
                            .offset(y: hasAppeared || reduceMotion ? 0 : 12)
                            .animation(Motion.respectingReduceMotion(Motion.atelier.delay(Double(index) * 0.04)), value: hasAppeared)
                            .accessibilityIdentifier("auto.card.\(feature.rawValue)")
                        }
                        Button { app.openDepthMotion() } label: { motionCard }
                            .buttonStyle(CreateTileButtonStyle())
                            .accessibilityIdentifier("auto.card.depthMotion")
                    }
                    .padding(.horizontal, Spacing.m)
                }
                .padding(.vertical, Spacing.m)
            }
            .background(AurumColor.background.ignoresSafeArea())
            .navigationTitle("Auto Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { app.closeFlow() }
                        .foregroundColor(AurumColor.textSecondary)
                }
            }
            .toolbarBackground(AurumColor.background, for: .navigationBar)
            .navigationDestination(for: AutoFeature.self) { feature in
                AutoFeatureView(model: model, app: app, feature: feature)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isPicking) {
            MediaPickerView(app: app, required: 1, title: String(localized: "Choose a photo")) { picked in
                isPicking = false
                Task { await model.setPhoto(picked) }
            } onCancel: {
                isPicking = false
            }
        }
        .onAppear { hasAppeared = true }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Quick fixes, made on your iPhone.").aurumText(.editorial)
            Text("Open a photo and AURUM looks for faces, people, the horizon and the light, then suggests fixes. Everything runs on your iPhone with classic photo processing; nothing is uploaded.")
                .aurumText(.caption, color: AurumColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Spacing.m)
    }

    @ViewBuilder
    private var photoSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let preview = model.sourcePreview {
                AtelierImage(image: preview)
                    .frame(maxWidth: .infinity)
                    .frame(height: 240)
                    .accessibilityLabel(String(localized: "Your photo"))
                    .accessibilityAddTraits(.isImage)
                Button(String(localized: "Change photo")) { isPicking = true }
                    .buttonStyle(TextActionButtonStyle())
                    .disabled(model.isBusy)
            } else {
                Button { isPicking = true } label: {
                    AtelierImage(image: nil, placeholder: String(localized: "Choose a photo to begin"))
                        .frame(height: 160)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("auto.choosePhoto")
            }
            if case .failed(let message) = model.phase, model.sourcePreview == nil {
                Text(message).aurumText(.caption, color: AurumColor.textSecondary)
            }
        }
        .padding(.horizontal, Spacing.m)
    }

    @ViewBuilder
    private var suggestionSection: some View {
        if model.isAnalysing {
            HStack(spacing: Spacing.s) {
                ProgressView().tint(AurumColor.accent)
                Text("Looking at your photo…").aurumText(.caption, color: AurumColor.textSecondary)
            }
            .padding(.horizontal, Spacing.m)
        } else if !model.suggestions.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Suggested for this photo").aurumText(.label, color: AurumColor.textTertiary)
                    .padding(.horizontal, Spacing.m)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.xs) {
                        ForEach(model.suggestions) { suggestion in
                            Chip(AutoStudioViewModel.title(for: suggestion), isSelected: false, leadingIcon: suggestion.feature.tier == .member ? .crown : nil) {
                                Haptics.detent()
                                path = [suggestion.feature]
                                Task { await model.apply(suggestion) }
                            }
                            .accessibilityIdentifier("auto.suggestion.\(suggestion.kind.rawValue)")
                        }
                    }
                    .padding(.horizontal, Spacing.m)
                }
            }
        }
    }

    private var motionCard: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            IconView(.threeD, size: 22).foregroundColor(AurumColor.accent).padding(.bottom, Spacing.xxs)
            Text("3D Motion").aurumText(.headline)
            Text("Depth and gentle movement for a still photo").aurumText(.caption, color: AurumColor.textTertiary).lineLimit(2)
            Spacer(minLength: 0)
            Text("On your iPhone").aurumText(.label, color: AurumColor.textSecondary)
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Radius.thumbnail).fill(AurumColor.surface))
        .overlay(RoundedRectangle(cornerRadius: Radius.thumbnail).stroke(AurumColor.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// A tool card: name, what it does, and whether keeping the result needs membership.
struct AutoFeatureCard: View {
    let feature: AutoFeature

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack {
                IconView(Self.icon(for: feature), size: 22).foregroundColor(AurumColor.accent)
                Spacer()
                if feature.tier == .member {
                    IconView(.crown, size: 16)
                        .foregroundColor(AurumColor.accent)
                        .accessibilityLabel(String(localized: "Members"))
                }
            }
            .padding(.bottom, Spacing.xxs)
            Text(AutoStudioViewModel.title(for: feature)).aurumText(.headline)
            Text(AutoStudioViewModel.subtitle(for: feature))
                .aurumText(.caption, color: AurumColor.textTertiary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Text(footer).aurumText(.label, color: AurumColor.textSecondary)
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Radius.thumbnail).fill(AurumColor.surface))
        .overlay(RoundedRectangle(cornerRadius: Radius.thumbnail).stroke(AurumColor.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    static func icon(for feature: AutoFeature) -> AurumIcon {
        switch feature {
        case .enhance: return .wand
        case .portraitBlur: return .camera
        case .replaceBackground: return .layers
        case .relight: return .sparkle
        case .retouch: return .retouch
        case .removeObject: return .effects
        case .portraitLooks: return .looks
        }
    }

    private var footer: String {
        if feature.tier == .member { return String(localized: "Free preview · members keep") }
        if feature == .portraitLooks { return String(localized: "Free and members' looks") }
        return String(localized: "Free · on your iPhone")
    }
}
