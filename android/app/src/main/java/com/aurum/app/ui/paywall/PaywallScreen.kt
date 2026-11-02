package com.aurum.app.ui.paywall

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.aurum.app.AppContainer
import com.aurum.app.billing.MembershipPlan
import com.aurum.app.billing.PlanPeriod
import com.aurum.app.billing.PurchaseOutcome
import com.aurum.app.billing.RestoreOutcome
import com.aurum.app.l10n.tr
import com.aurum.app.l10n.trDynamic
import com.aurum.app.ui.common.AurumIcons
import com.aurum.app.ui.common.GoldButton
import com.aurum.app.ui.common.IconAction
import com.aurum.app.ui.common.TextAction
import com.aurum.app.ui.theme.AurumType
import com.aurum.app.ui.theme.LocalPalette
import com.aurum.app.ui.theme.Spacing
import kotlinx.coroutines.launch

private enum class PaywallMessage { unavailable, unreachable, pending, failed, nothingFound, restoreFailed }

/**
 * Membership, shown only from the export flow. Prices, trials and the
 * purchase itself come from [com.aurum.app.billing.MembershipStore].
 */
@Composable
fun PaywallScreen(container: AppContainer, onClose: () -> Unit, onMember: () -> Unit) {
    val p = LocalPalette.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val config = container.config
    var plans by remember { mutableStateOf<List<MembershipPlan>?>(null) }
    var selected by remember { mutableStateOf<MembershipPlan?>(null) }
    var message by remember { mutableStateOf<PaywallMessage?>(null) }
    var busy by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        container.membership.plans()
            .onSuccess { list ->
                plans = list
                selected = list.firstOrNull { it.period.name == config.highlightedPlan } ?: list.firstOrNull()
                if (list.isEmpty()) message = PaywallMessage.unavailable
            }
            .onFailure {
                plans = emptyList()
                message = PaywallMessage.unreachable
            }
    }

    Box(Modifier.fillMaxSize().background(p.background).safeDrawingPadding()) {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = Spacing.l),
            verticalArrangement = Arrangement.spacedBy(Spacing.m),
        ) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                IconAction(AurumIcons.close, tr("Close"), onClose)
            }
            Text(trDynamic(config.paywallHeadline), style = AurumType.display, color = p.textPrimary)
            Column(verticalArrangement = Arrangement.spacedBy(Spacing.xs)) {
                for (benefit in config.paywallBenefits) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(AurumIcons.check, null, tint = p.accent, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.size(Spacing.xs))
                        Text(trDynamic(benefit), style = AurumType.body, color = p.textPrimary)
                    }
                }
            }

            val list = plans
            if (list == null) {
                Box(Modifier.fillMaxWidth().height(120.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = p.accent, strokeWidth = 2.dp)
                }
            } else {
                for (plan in list) PlanCard(plan, plan == selected) { selected = plan }
            }

            when (message) {
                PaywallMessage.unavailable -> Text(tr("Membership isn't available right now."), style = AurumType.caption, color = p.textSecondary)
                PaywallMessage.unreachable -> Text(tr("Couldn't reach Google Play. Check your connection and try again."), style = AurumType.caption, color = p.textSecondary)
                PaywallMessage.pending -> Text(tr("Your purchase is waiting for approval. We'll unlock membership as soon as it's approved."), style = AurumType.caption, color = p.textSecondary)
                PaywallMessage.failed -> Text(tr("The purchase didn't go through. You haven't been charged."), style = AurumType.caption, color = p.textSecondary)
                PaywallMessage.nothingFound -> Text(tr("No membership was found for this Google account."), style = AurumType.caption, color = p.textSecondary)
                PaywallMessage.restoreFailed -> Text(tr("Couldn't restore purchases. Please try again."), style = AurumType.caption, color = p.textSecondary)
                null -> Unit
            }

            val plan = selected
            val trial = plan?.trialDays?.takeIf { it > 0 }
            GoldButton(
                if (trial != null) tr("Start %lld-day free trial", trial) else tr("Continue"),
                enabled = plan != null,
                busy = busy,
                onClick = {
                    val activity = context.findActivity() ?: return@GoldButton
                    val chosen = plan ?: return@GoldButton
                    busy = true
                    message = null
                    scope.launch {
                        when (container.membership.purchase(activity, chosen)) {
                            PurchaseOutcome.Purchased -> onMember()
                            PurchaseOutcome.Pending -> message = PaywallMessage.pending
                            PurchaseOutcome.Cancelled -> Unit
                            PurchaseOutcome.Failed -> message = PaywallMessage.failed
                        }
                        busy = false
                    }
                },
            )
            if (plan != null) {
                val terms = when {
                    trial != null && plan.period == PlanPeriod.yearly -> tr("Free for %lld days, then %@ per year. Cancel anytime in Google Play.", trial, plan.displayPrice)
                    trial != null -> tr("Free for %lld days, then %@ per week. Cancel anytime in Google Play.", trial, plan.displayPrice)
                    plan.period == PlanPeriod.yearly -> tr("%@ per year. Renews automatically. Cancel anytime in Google Play.", plan.displayPrice)
                    else -> tr("%@ per week. Renews automatically. Cancel anytime in Google Play.", plan.displayPrice)
                }
                Text(terms, style = AurumType.caption, color = p.textTertiary, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
                TextAction(tr("Restore"), {
                    busy = true
                    message = null
                    scope.launch {
                        when (container.membership.restore()) {
                            RestoreOutcome.restored -> onMember()
                            RestoreOutcome.nothingFound -> message = PaywallMessage.nothingFound
                            RestoreOutcome.failed -> message = PaywallMessage.restoreFailed
                        }
                        busy = false
                    }
                }, color = p.textSecondary)
                TextAction(tr("Terms"), { context.openUrl(config.termsUrl) }, color = p.textSecondary)
                TextAction(tr("Privacy"), { context.openUrl(config.privacyUrl) }, color = p.textSecondary)
            }
            Spacer(Modifier.height(Spacing.l))
        }
    }
}

@Composable
private fun PlanCard(plan: MembershipPlan, isSelected: Boolean, onSelect: () -> Unit) {
    val p = LocalPalette.current
    val shape = RoundedCornerShape(14.dp)
    Row(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(p.surface)
            .border(if (isSelected) 2.dp else 1.dp, if (isSelected) p.accent else p.hairline, shape)
            .clickable(role = Role.RadioButton, onClick = onSelect)
            .semantics(mergeDescendants = true) { selected = isSelected }
            .padding(Spacing.m),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(if (plan.period == PlanPeriod.yearly) tr("Yearly") else tr("Weekly"), style = AurumType.headline, color = p.textPrimary)
            plan.trialDays?.takeIf { it > 0 }?.let {
                Text(tr("%lld-day free trial", it), style = AurumType.caption, color = p.accent)
            }
        }
        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                if (plan.period == PlanPeriod.yearly) tr("%@ / year", plan.displayPrice) else tr("%@ / week", plan.displayPrice),
                style = AurumType.headline, color = p.textPrimary,
            )
            plan.pricePerWeek?.let { Text(tr("%@ a week", it), style = AurumType.caption, color = p.textTertiary) }
        }
    }
}

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}

private fun Context.openUrl(url: String) {
    runCatching { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
}
