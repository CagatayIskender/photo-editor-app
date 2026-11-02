import SwiftUI
import AurumCore
import AurumServices

/// Drives the membership paywall. Rules that keep it honest:
/// - It is only shown when the user asks to export member items, or taps "Join".
/// - Prices come from the App Store, with the billed amount shown first.
/// - The close button is visible from the first frame, and restore is always offered.
@MainActor
public final class PaywallViewModel: ObservableObject {
    public enum State: Equatable {
        case loading
        case ready
        case purchasing
        case purchased
        case pending
        case failed(String)
    }

    @Published public private(set) var plans: [MembershipPlan] = []
    @Published public var selectedPlanID: String?
    @Published public private(set) var state: State = .loading

    let purchases: PurchaseService
    let analytics: Analytics
    public let config: RemoteConfigValues
    let trigger: String

    public init(purchases: PurchaseService, analytics: Analytics, config: RemoteConfigValues, trigger: String) {
        self.purchases = purchases
        self.analytics = analytics
        self.config = config
        self.trigger = trigger
    }

    public func load() async {
        do {
            plans = try await purchases.plans()
            selectedPlanID = plans.first { $0.period.rawValue == config.highlightedPlan }?.id ?? plans.first?.id
            state = plans.isEmpty ? .failed("Membership isn't available right now.") : .ready
        } catch {
            state = .failed("Couldn't reach the App Store. Check your connection and try again.")
        }
    }

    public var selectedPlan: MembershipPlan? {
        plans.first { $0.id == selectedPlanID }
    }

    /// Exactly what tapping the button will do, shown under it.
    public var termsLine: String {
        guard let plan = selectedPlan else { return "" }
        let period = plan.period == .yearly ? "year" : "week"
        if let days = plan.trialDays, days > 0 {
            return "Free for \(days) days, then \(plan.displayPrice) per \(period). Cancel anytime in Settings."
        }
        return "\(plan.displayPrice) per \(period). Renews automatically. Cancel anytime in Settings."
    }

    public var buttonTitle: String {
        if let days = selectedPlan?.trialDays, days > 0 { return "Start \(days)-day free trial" }
        return "Join"
    }

    public func purchase() async {
        guard let id = selectedPlanID else { return }
        state = .purchasing
        do {
            switch try await purchases.purchase(planID: id) {
            case .purchased:
                state = .purchased
                analytics.track(.purchaseCompleted(planID: id))
            case .pending:
                state = .pending
            case .cancelled:
                state = .ready
            }
        } catch {
            state = .failed("The purchase didn't go through. You haven't been charged.")
        }
    }

    public func restore() async {
        state = .purchasing
        do {
            try await purchases.restore()
            state = purchases.entitlement == .member ? .purchased : .failed("No membership was found for this Apple ID.")
        } catch {
            state = .failed("Couldn't restore purchases. Please try again.")
        }
    }
}
