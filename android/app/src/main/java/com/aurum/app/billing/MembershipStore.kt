package com.aurum.app.billing

import android.app.Activity
import com.aurum.core.Entitlement
import kotlinx.coroutines.flow.StateFlow

enum class PlanPeriod { weekly, yearly }

/** A membership plan as shown on the paywall, with store-formatted prices. */
data class MembershipPlan(
    val productId: String,
    val period: PlanPeriod,
    val displayPrice: String,
    /** Free-trial length in days, or null when the plan has no trial. */
    val trialDays: Int?,
    /** "€0.96"-style weekly equivalent for yearly plans, when the store gives a price in micros. */
    val pricePerWeek: String?,
)

sealed interface PurchaseOutcome {
    data object Purchased : PurchaseOutcome
    /** Waiting for approval, for example a family purchase request or a cash payment. */
    data object Pending : PurchaseOutcome
    data object Cancelled : PurchaseOutcome
    data object Failed : PurchaseOutcome
}

enum class RestoreOutcome { restored, nothingFound, failed }

/**
 * Membership and purchases. The UI depends only on this interface: debug
 * builds use [FakeMembershipStore], release builds [PlayBillingMembershipStore].
 */
interface MembershipStore {
    val entitlement: StateFlow<Entitlement>

    /** Connects and refreshes the entitlement; safe to call more than once. */
    suspend fun refresh()

    /** The plans on sale. Empty when the store is unreachable or membership is unavailable. */
    suspend fun plans(): Result<List<MembershipPlan>>

    suspend fun purchase(activity: Activity, plan: MembershipPlan): PurchaseOutcome

    suspend fun restore(): RestoreOutcome
}
