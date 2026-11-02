package com.aurum.app.billing

import android.app.Activity
import android.content.Context
import com.android.billingclient.api.AcknowledgePurchaseParams
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.PurchasesUpdatedListener
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import com.android.billingclient.api.acknowledgePurchase
import com.android.billingclient.api.queryProductDetails
import com.android.billingclient.api.queryPurchasesAsync
import com.aurum.core.BrandConfig
import com.aurum.core.Entitlement
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.Period
import java.util.Currency

/**
 * Google Play Billing, used by release builds only. Product ids come from
 * Brand/brand.json (the same ids as the App Store products). Entitlement is
 * derived from the active, acknowledged subscriptions on this account.
 */
class PlayBillingMembershipStore(context: Context, private val brand: BrandConfig) : MembershipStore {
    private val _entitlement = MutableStateFlow(Entitlement.free)
    override val entitlement: StateFlow<Entitlement> = _entitlement

    private var pendingFlow: CompletableDeferred<Pair<BillingResult, List<Purchase>?>>? = null
    private val connectLock = Mutex()
    private val details = mutableMapOf<String, ProductDetails>()

    private val listener = PurchasesUpdatedListener { result, purchases ->
        pendingFlow?.complete(result to purchases)
    }

    private val client: BillingClient = BillingClient.newBuilder(context.applicationContext)
        .setListener(listener)
        .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())
        .build()

    private val productIds get() = listOf(brand.products.yearly, brand.products.weekly)

    private suspend fun connect(): Boolean = connectLock.withLock {
        if (client.isReady) return true
        val done = CompletableDeferred<Boolean>()
        client.startConnection(object : BillingClientStateListener {
            override fun onBillingSetupFinished(result: BillingResult) {
                done.complete(result.responseCode == BillingClient.BillingResponseCode.OK)
            }
            override fun onBillingServiceDisconnected() {
                done.complete(false)
            }
        })
        done.await()
    }

    override suspend fun refresh() {
        if (!connect()) return
        val result = client.queryPurchasesAsync(
            QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.SUBS).build(),
        )
        if (result.billingResult.responseCode != BillingClient.BillingResponseCode.OK) return
        handle(result.purchasesList)
    }

    /** Acknowledges new purchases and updates the entitlement. Returns true if membership is active. */
    private suspend fun handle(purchases: List<Purchase>): Boolean {
        var active = false
        for (purchase in purchases) {
            if (purchase.products.none { it in productIds }) continue
            if (purchase.purchaseState != Purchase.PurchaseState.PURCHASED) continue
            if (!purchase.isAcknowledged) {
                client.acknowledgePurchase(
                    AcknowledgePurchaseParams.newBuilder().setPurchaseToken(purchase.purchaseToken).build(),
                )
            }
            active = true
        }
        _entitlement.value = if (active) Entitlement.member else Entitlement.free
        return active
    }

    override suspend fun plans(): Result<List<MembershipPlan>> {
        if (!connect()) return Result.failure(IllegalStateException("Billing unavailable"))
        val params = QueryProductDetailsParams.newBuilder().setProductList(
            productIds.map {
                QueryProductDetailsParams.Product.newBuilder()
                    .setProductId(it)
                    .setProductType(BillingClient.ProductType.SUBS)
                    .build()
            },
        ).build()
        val result = client.queryProductDetails(params)
        if (result.billingResult.responseCode != BillingClient.BillingResponseCode.OK) {
            return Result.failure(IllegalStateException(result.billingResult.debugMessage))
        }
        val list = result.productDetailsList.orEmpty()
        list.forEach { details[it.productId] = it }
        return Result.success(list.mapNotNull(::plan).sortedBy { it.period != PlanPeriod.yearly })
    }

    private fun plan(product: ProductDetails): MembershipPlan? {
        val offer = bestOffer(product) ?: return null
        val phases = offer.pricingPhases.pricingPhaseList
        val paid = phases.lastOrNull { it.priceAmountMicros > 0 } ?: return null
        val trial = phases.firstOrNull { it.priceAmountMicros == 0L }?.let { days(it.billingPeriod) }
        val period = if (product.productId == brand.products.yearly) PlanPeriod.yearly else PlanPeriod.weekly
        val perWeek = if (period == PlanPeriod.yearly) {
            runCatching {
                val format = java.text.NumberFormat.getCurrencyInstance()
                format.currency = Currency.getInstance(paid.priceCurrencyCode)
                format.format(paid.priceAmountMicros / 1_000_000.0 / 52.0)
            }.getOrNull()
        } else null
        return MembershipPlan(product.productId, period, paid.formattedPrice, trial, perWeek)
    }

    /** Prefers an offer with a free trial the account is eligible for, then the base plan. */
    private fun bestOffer(product: ProductDetails): ProductDetails.SubscriptionOfferDetails? {
        val offers = product.subscriptionOfferDetails.orEmpty()
        return offers.firstOrNull { o -> o.pricingPhases.pricingPhaseList.any { it.priceAmountMicros == 0L } }
            ?: offers.firstOrNull { it.offerId == null }
            ?: offers.firstOrNull()
    }

    private fun days(iso: String): Int? = runCatching { Period.parse(iso).let { it.years * 365 + it.months * 30 + it.days } }.getOrNull()

    override suspend fun purchase(activity: Activity, plan: MembershipPlan): PurchaseOutcome {
        val product = details[plan.productId] ?: return PurchaseOutcome.Failed
        val offer = bestOffer(product) ?: return PurchaseOutcome.Failed
        val flowParams = BillingFlowParams.newBuilder().setProductDetailsParamsList(
            listOf(
                BillingFlowParams.ProductDetailsParams.newBuilder()
                    .setProductDetails(product)
                    .setOfferToken(offer.offerToken)
                    .build(),
            ),
        ).build()
        val deferred = CompletableDeferred<Pair<BillingResult, List<Purchase>?>>()
        pendingFlow = deferred
        val launch = client.launchBillingFlow(activity, flowParams)
        if (launch.responseCode != BillingClient.BillingResponseCode.OK) {
            pendingFlow = null
            return PurchaseOutcome.Failed
        }
        val (result, purchases) = deferred.await()
        pendingFlow = null
        return when (result.responseCode) {
            BillingClient.BillingResponseCode.OK -> {
                val list = purchases.orEmpty()
                when {
                    handle(list) -> PurchaseOutcome.Purchased
                    list.any { it.purchaseState == Purchase.PurchaseState.PENDING } -> PurchaseOutcome.Pending
                    else -> PurchaseOutcome.Failed
                }
            }
            BillingClient.BillingResponseCode.USER_CANCELED -> PurchaseOutcome.Cancelled
            BillingClient.BillingResponseCode.ITEM_ALREADY_OWNED -> { refresh(); PurchaseOutcome.Purchased }
            else -> PurchaseOutcome.Failed
        }
    }

    override suspend fun restore(): RestoreOutcome {
        if (!connect()) return RestoreOutcome.failed
        refresh()
        return if (_entitlement.value == Entitlement.member) RestoreOutcome.restored else RestoreOutcome.nothingFound
    }
}
