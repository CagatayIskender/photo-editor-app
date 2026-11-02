import SwiftUI
import AurumCore
import AurumDesign
import AurumServices

/// The membership paywall. Close is visible from the start, the billed price
/// is the largest number on each plan, and the line under the button says
/// exactly what will be charged and when.
struct PaywallView: View {
    @StateObject private var model: PaywallViewModel
    @ObservedObject var app: AppModel
    let onClose: () -> Void

    init(app: AppModel, trigger: String, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: PaywallViewModel(purchases: app.deps.purchases, analytics: app.deps.analytics, config: app.config, trigger: trigger))
        self.app = app
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            HStack {
                CrownBadge(size: 28)
                Spacer()
                IconButton(.close, label: String(localized: "Close"), action: onClose)
                    .accessibilityIdentifier("paywall.close")
            }
            .aurumEntrance(0, distance: 8)
            Text(Localized.dynamic(model.config.paywallHeadline)).aurumText(.display)
                .aurumEntrance(1)
            benefits
            Spacer(minLength: 0)
            plans.aurumEntrance(5)
            purchaseArea.aurumEntrance(6)
        }
        .padding(Spacing.l)
        .formSheetWidth()
        .background(
            ZStack {
                AurumColor.background
                AmbientGlow(intensity: 1.1)
            }
            .ignoresSafeArea()
        )
        .preferredColorScheme(.dark)
        .task { await model.load() }
        .onChange(of: model.state) { state in
            if state == .purchased {
                app.membershipDidChange()
                Haptics.success()
                onClose()
            }
        }
    }

    private var benefits: some View {
        let list = Array(model.config.paywallBenefits.enumerated())
        return VStack(alignment: .leading, spacing: Spacing.s) {
            ForEach(list, id: \.element) { index, benefit in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    IconView(.check, size: 16).foregroundColor(AurumColor.accent)
                    Text(Localized.dynamic(benefit)).aurumText(.body)
                }
                .aurumEntrance(index + 2, distance: 8)
            }
        }
    }

    @ViewBuilder
    private var plans: some View {
        switch model.state {
        case .loading:
            VStack(spacing: Spacing.s) {
                SkeletonBlock(cornerRadius: Radius.card).frame(height: 68)
                SkeletonBlock(cornerRadius: Radius.card).frame(height: 68)
            }
            .transition(.opacity)
        default:
            VStack(spacing: Spacing.s) {
                ForEach(model.plans) { plan in
                    planRow(plan)
                }
            }
            .transition(.opacity)
        }
    }

    private func planRow(_ plan: MembershipPlan) -> some View {
        let isSelected = model.selectedPlanID == plan.id
        return Button {
            guard model.selectedPlanID != plan.id else { return }
            withAnimation(Motion.respectingReduceMotion(Motion.atelier)) { model.selectedPlanID = plan.id }
            Haptics.detent()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.period == .yearly ? String(localized: "Yearly") : String(localized: "Weekly")).aurumText(.headline)
                    if let days = plan.trialDays, days > 0 {
                        Text("\(days)-day free trial").aurumText(.caption, color: AurumColor.accent)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(plan.period == .yearly ? String(localized: "\(plan.displayPrice) / year") : String(localized: "\(plan.displayPrice) / week")).aurumText(.headline)
                    if plan.period == .yearly, let perWeek = plan.pricePerWeek {
                        Text("\(perWeek) a week").aurumText(.caption, color: AurumColor.textTertiary)
                    }
                }
            }
            .padding(Spacing.m)
            .background(
                RoundedRectangle(cornerRadius: Radius.card)
                    .fill(LinearGradient(
                        colors: [isSelected ? AurumColor.accent.opacity(0.10) : AurumColor.surfaceRaised, AurumColor.surface],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
            )
            .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(isSelected ? AurumColor.accent : AurumColor.hairline, lineWidth: isSelected ? 1.5 : 0.5))
            .shadow(color: AurumColor.accent.opacity(isSelected ? 0.18 : 0), radius: 14, y: 4)
            .scaleEffect(isSelected ? 1.01 : 1)
            .animation(Motion.respectingReduceMotion(Motion.atelier), value: isSelected)
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var purchaseArea: some View {
        VStack(spacing: Spacing.s) {
            if case .failed(let message) = model.state {
                Text(message).aurumText(.caption, color: AurumColor.textSecondary)
                    .transition(.aurumRise)
            }
            if model.state == .pending {
                Text("Your purchase is waiting for approval. We'll unlock membership as soon as it's approved.")
                    .aurumText(.caption, color: AurumColor.textSecondary)
                    .transition(.aurumRise)
            }
            Button {
                Task { await model.purchase() }
            } label: {
                if model.state == .purchasing { ProgressView().tint(AurumColor.onAccent) } else { Text(model.buttonTitle) }
            }
            .buttonStyle(GoldSheenButtonStyle())
            .disabled(model.selectedPlan == nil || model.state == .purchasing)
            .accessibilityIdentifier("paywall.purchase")
            .animation(Motion.respectingReduceMotion(Motion.velvet), value: model.state == .purchasing)
            Text(model.termsLine)
                .aurumText(.caption, color: AurumColor.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            // Placeholder URLs: replace with the real terms and privacy pages before release.
            HStack(spacing: Spacing.l) {
                Button("Restore") { Task { await model.restore() } }
                Link("Terms", destination: URL(string: "https://aurum.app/terms")!)
                Link("Privacy", destination: URL(string: "https://aurum.app/privacy")!)
            }
            .buttonStyle(TextActionButtonStyle())
            .font(AurumTextStyle.caption.font)
            .foregroundColor(AurumColor.textSecondary)
        }
    }
}
