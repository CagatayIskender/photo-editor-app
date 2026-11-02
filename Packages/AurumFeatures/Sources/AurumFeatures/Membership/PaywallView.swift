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
            Text(Localized.dynamic(model.config.paywallHeadline)).aurumText(.display)
            VStack(alignment: .leading, spacing: Spacing.s) {
                ForEach(model.config.paywallBenefits, id: \.self) { benefit in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                        IconView(.check, size: 16).foregroundColor(AurumColor.accent)
                        Text(Localized.dynamic(benefit)).aurumText(.body)
                    }
                }
            }
            Spacer(minLength: 0)
            plans
            purchaseArea
        }
        .padding(Spacing.l)
        .background(AurumColor.background.ignoresSafeArea())
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

    @ViewBuilder
    private var plans: some View {
        switch model.state {
        case .loading:
            ProgressView().tint(AurumColor.accent).frame(maxWidth: .infinity)
        default:
            VStack(spacing: Spacing.s) {
                ForEach(model.plans) { plan in
                    planRow(plan)
                }
            }
        }
    }

    private func planRow(_ plan: MembershipPlan) -> some View {
        let isSelected = model.selectedPlanID == plan.id
        return Button { model.selectedPlanID = plan.id } label: {
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
            .background(RoundedRectangle(cornerRadius: Radius.card).fill(AurumColor.surface))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(isSelected ? AurumColor.accent : AurumColor.hairline, lineWidth: isSelected ? 1.5 : 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var purchaseArea: some View {
        VStack(spacing: Spacing.s) {
            if case .failed(let message) = model.state {
                Text(message).aurumText(.caption, color: AurumColor.textSecondary)
            }
            if model.state == .pending {
                Text("Your purchase is waiting for approval. We'll unlock membership as soon as it's approved.")
                    .aurumText(.caption, color: AurumColor.textSecondary)
            }
            Button {
                Task { await model.purchase() }
            } label: {
                if model.state == .purchasing { ProgressView().tint(AurumColor.onAccent) } else { Text(model.buttonTitle) }
            }
            .buttonStyle(GoldButtonStyle())
            .disabled(model.selectedPlan == nil || model.state == .purchasing)
            .accessibilityIdentifier("paywall.purchase")
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
