package com.aurum.app.billing

import android.app.Activity
import com.aurum.app.data.Prefs
import com.aurum.core.Entitlement
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Simulated purchases for debug builds. Nothing is sent to Google Play; the
 * membership is remembered on the device so the export rules can be tried
 * both ways. Clear app data to become a free user again.
 */
class FakeMembershipStore(private val prefs: Prefs) : MembershipStore {
    private val _entitlement = MutableStateFlow(if (prefs.debugMember) Entitlement.member else Entitlement.free)
    override val entitlement: StateFlow<Entitlement> = _entitlement

    override suspend fun refresh() {
        _entitlement.value = if (prefs.debugMember) Entitlement.member else Entitlement.free
    }

    override suspend fun plans(): Result<List<MembershipPlan>> {
        delay(250)
        return Result.success(
            listOf(
                MembershipPlan("debug.yearly", PlanPeriod.yearly, "49.99 (test)", trialDays = 3, pricePerWeek = "0.96 (test)"),
                MembershipPlan("debug.weekly", PlanPeriod.weekly, "5.99 (test)", trialDays = null, pricePerWeek = null),
            ),
        )
    }

    override suspend fun purchase(activity: Activity, plan: MembershipPlan): PurchaseOutcome {
        delay(600)
        prefs.debugMember = true
        _entitlement.value = Entitlement.member
        return PurchaseOutcome.Purchased
    }

    override suspend fun restore(): RestoreOutcome {
        delay(400)
        refresh()
        return if (prefs.debugMember) RestoreOutcome.restored else RestoreOutcome.nothingFound
    }
}
