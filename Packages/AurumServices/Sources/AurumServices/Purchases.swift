import Foundation
import StoreKit
import AurumCore

/// A membership plan as shown on the paywall.
public struct MembershipPlan: Identifiable, Equatable, Sendable {
    public enum Period: String, Sendable { case weekly, yearly }

    public let id: String
    public let period: Period
    /// Localised price from the App Store, for example "$39.99".
    public let displayPrice: String
    /// Localised price per week, used to compare plans.
    public let pricePerWeek: String?
    /// Free trial length in days, if the user is eligible.
    public let trialDays: Int?

    public init(id: String, period: Period, displayPrice: String, pricePerWeek: String?, trialDays: Int?) {
        self.id = id
        self.period = period
        self.displayPrice = displayPrice
        self.pricePerWeek = pricePerWeek
        self.trialDays = trialDays
    }
}

public enum PurchaseOutcome: Equatable, Sendable {
    case purchased
    case pending
    case cancelled
}

@MainActor
public protocol PurchaseService: AnyObject {
    var entitlement: Entitlement { get }
    /// Called whenever the entitlement changes, including at launch.
    var onEntitlementChange: ((Entitlement) -> Void)? { get set }
    func start() async
    func plans() async throws -> [MembershipPlan]
    func purchase(planID: String) async throws -> PurchaseOutcome
    func restore() async throws
}

/// StoreKit 2 implementation. Entitlement is derived from verified
/// transactions on device; server-side validation is added before launch
/// (see the architecture doc).
@MainActor
public final class StoreKitPurchaseService: PurchaseService {
    public private(set) var entitlement: Entitlement = .free
    public var onEntitlementChange: ((Entitlement) -> Void)?

    private let productIDs: [String]
    private var products: [String: Product] = [:]
    private var updatesTask: Task<Void, Never>?

    public init(weeklyID: String, yearlyID: String) {
        self.productIDs = [weeklyID, yearlyID]
    }

    public func start() async {
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update { await transaction.finish() }
                await self?.refreshEntitlement()
            }
        }
        await refreshEntitlement()
    }

    func refreshEntitlement() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, productIDs.contains(t.productID), t.revocationDate == nil {
                if let expiry = t.expirationDate, expiry < Date() { continue }
                active = true
            }
        }
        entitlement = active ? .member : .free
        onEntitlementChange?(entitlement)
    }

    public func plans() async throws -> [MembershipPlan] {
        let loaded = try await Product.products(for: productIDs)
        for p in loaded { products[p.id] = p }
        var result: [MembershipPlan] = []
        for p in loaded {
            guard let sub = p.subscription else { continue }
            let period: MembershipPlan.Period = sub.subscriptionPeriod.unit == .year ? .yearly : .weekly
            let weeks: Decimal = period == .yearly ? 52 : 1
            let perWeek = (p.price / weeks).formatted(p.priceFormatStyle)
            var trial: Int?
            if let intro = sub.introductoryOffer, intro.paymentMode == .freeTrial, await sub.isEligibleForIntroOffer {
                let unit = intro.period.unit
                trial = intro.period.value * (unit == .week ? 7 : unit == .month ? 30 : unit == .year ? 365 : 1)
            }
            result.append(MembershipPlan(id: p.id, period: period, displayPrice: p.displayPrice, pricePerWeek: perWeek, trialDays: trial))
        }
        return result.sorted { $0.period == .yearly && $1.period != .yearly }
    }

    public func purchase(planID: String) async throws -> PurchaseOutcome {
        if products[planID] == nil { _ = try await plans() }
        guard let product = products[planID] else { throw StoreKitError.unknown }
        switch try await product.purchase() {
        case .success(let verification):
            guard case .verified(let transaction) = verification else { throw StoreKitError.unknown }
            await transaction.finish()
            await refreshEntitlement()
            return .purchased
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    public func restore() async throws {
        try await AppStore.sync()
        await refreshEntitlement()
    }
}

/// A purchase service for previews, UI tests and the simulator without a StoreKit config.
@MainActor
public final class MockPurchaseService: PurchaseService {
    public private(set) var entitlement: Entitlement
    public var onEntitlementChange: ((Entitlement) -> Void)?

    public init(entitlement: Entitlement = .free) {
        self.entitlement = entitlement
    }

    public func start() async { onEntitlementChange?(entitlement) }

    public func plans() async throws -> [MembershipPlan] {
        [
            MembershipPlan(id: "yearly", period: .yearly, displayPrice: "$39.99", pricePerWeek: "$0.77", trialDays: 7),
            MembershipPlan(id: "weekly", period: .weekly, displayPrice: "$4.99", pricePerWeek: "$4.99", trialDays: nil)
        ]
    }

    public func purchase(planID: String) async throws -> PurchaseOutcome {
        entitlement = .member
        onEntitlementChange?(entitlement)
        return .purchased
    }

    public func restore() async throws {}
}
