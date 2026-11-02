import SwiftUI
import AurumCore
import AurumDesign
import AurumRender
import AurumServices

/// The AI Studio: every feature as a card with its credit cost shown up
/// front, the credit balance in the header, and recent jobs below.
struct AIStudioView: View {
    @ObservedObject var app: AppModel
    @StateObject private var model: AIStudioViewModel
    @State private var path: [AIFeature] = []
    @State private var hasAppeared = false
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
        _model = StateObject(wrappedValue: AIStudioViewModel(deps: app.deps, entitlement: { [weak app] in app?.entitlement ?? .free }, serverEnabled: app.config.aiStudioEnabled))
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    intro
                    LazyVGrid(columns: columns, spacing: Spacing.s) {
                        ForEach(Array(AIFeature.allCases.enumerated()), id: \.element) { index, feature in
                            Button {
                                model.select(feature)
                                path.append(feature)
                                Haptics.detent()
                            } label: {
                                AIFeatureCard(feature: feature, mode: model.mode(for: feature))
                            }
                            .buttonStyle(CreateTileButtonStyle())
                            .opacity(hasAppeared || reduceMotion ? 1 : 0)
                            .offset(y: hasAppeared || reduceMotion ? 0 : 12)
                            .animation(Motion.respectingReduceMotion(Motion.atelier.delay(Double(index) * 0.04)), value: hasAppeared)
                            .accessibilityIdentifier("ai.card.\(feature.rawValue)")
                        }
                        Button { app.openDepthMotion() } label: { motionCard }
                            .buttonStyle(CreateTileButtonStyle())
                            .accessibilityIdentifier("ai.card.depthMotion")
                    }
                    .padding(.horizontal, Spacing.m)
                    historySection
                }
                .padding(.vertical, Spacing.m)
            }
            .background(AurumColor.background.ignoresSafeArea())
            .navigationTitle("AI Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { app.closeFlow() }
                        .foregroundColor(AurumColor.textSecondary)
                }
                ToolbarItem(placement: .primaryAction) {
                    Text(model.balanceText)
                        .aurumText(.caption, color: AurumColor.accent)
                        .monospacedDigit()
                        .padding(.horizontal, Spacing.s)
                        .padding(.vertical, 6)
                        .overlay(Capsule().stroke(AurumColor.goldHairline, lineWidth: 1))
                        .accessibilityLabel(String(localized: "Balance, \(model.balanceText)"))
                }
            }
            .toolbarBackground(AurumColor.background, for: .navigationBar)
            .navigationDestination(for: AIFeature.self) { feature in
                AIFeatureView(model: model, app: app, feature: feature)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            model.grantMonthlyCreditsIfMember()
            hasAppeared = true
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Considered help, when you want it.").aurumText(.editorial)
            Text("Enhance, Background and Relight run on your iPhone for free. Other tools use credits and run on AURUM's servers; the cost is always shown first.")
                .aurumText(.caption, color: AurumColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Spacing.m)
    }

    private var motionCard: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            IconView(.threeD, size: 22).foregroundColor(AurumColor.accent).padding(.bottom, Spacing.xxs)
            Text("3D Motion").aurumText(.headline)
            Text("Depth and gentle movement for a still photo").aurumText(.caption, color: AurumColor.textTertiary).lineLimit(2)
            Spacer(minLength: 0)
            Text("On device").aurumText(.label, color: AurumColor.textSecondary)
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Radius.thumbnail).fill(AurumColor.surface))
        .overlay(RoundedRectangle(cornerRadius: Radius.thumbnail).stroke(AurumColor.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var historySection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Recent").aurumText(.headline)
            if model.history.records.isEmpty {
                Text("Jobs you start appear here, with their status and any refunds.")
                    .aurumText(.caption, color: AurumColor.textTertiary)
            } else {
                ForEach(model.history.records.prefix(12)) { record in
                    HStack(spacing: Spacing.s) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AIStudioViewModel.title(for: record.request.feature)).aurumText(.body)
                            Text(record.updatedAt, style: .relative).aurumText(.label, color: AurumColor.textTertiary)
                        }
                        Spacer()
                        Text(AIStudioViewModel.statusText(record.status)).aurumText(.caption, color: AurumColor.textSecondary)
                    }
                    .padding(.vertical, Spacing.xxs)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard case .succeeded = record.status, model.isServerAvailable else { return }
                        model.select(record.request.feature)
                        path = [record.request.feature]
                        Task { await model.reopen(record) }
                    }
                    .accessibilityElement(children: .combine)
                    Divider().overlay(AurumColor.hairline)
                }
            }
        }
        .padding(.horizontal, Spacing.m)
    }
}

/// A feature card: name, what it does, its cost, and how it runs.
struct AIFeatureCard: View {
    let feature: AIFeature
    let mode: AIFeatureMode

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack {
                IconView(icon, size: 22).foregroundColor(AurumColor.accent)
                Spacer()
                Text(AIStudioViewModel.costText(feature))
                    .aurumText(.label, color: AurumColor.accent)
            }
            .padding(.bottom, Spacing.xxs)
            Text(AIStudioViewModel.title(for: feature)).aurumText(.headline)
            Text(AIStudioViewModel.subtitle(for: feature))
                .aurumText(.caption, color: AurumColor.textTertiary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Text(modeText).aurumText(.label, color: mode == .comingSoon ? AurumColor.textTertiary : AurumColor.textSecondary)
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Radius.thumbnail).fill(AurumColor.surface))
        .overlay(RoundedRectangle(cornerRadius: Radius.thumbnail).stroke(AurumColor.hairline, lineWidth: 1))
        .opacity(mode == .comingSoon ? 0.75 : 1)
        .accessibilityElement(children: .combine)
    }

    private var icon: AurumIcon {
        switch feature {
        case .portrait, .avatar: return .retouch
        case .relight: return .sparkle
        case .removeObject: return .effects
        case .replaceBackground: return .layers
        case .enhance: return .adjust
        case .aiTransition: return .ai
        }
    }

    private var modeText: String {
        switch mode {
        case .onDevice: return String(localized: "On device · free preview")
        case .server: return String(localized: "Uses credits")
        case .comingSoon: return String(localized: "Coming soon")
        }
    }
}
