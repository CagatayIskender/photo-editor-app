package com.aurum.app

import android.app.Application
import android.content.Context
import com.aurum.app.billing.FakeMembershipStore
import com.aurum.app.billing.MembershipStore
import com.aurum.app.billing.PlayBillingMembershipStore
import com.aurum.app.data.DraftStore
import com.aurum.app.data.Prefs
import com.aurum.app.data.PresetStore
import com.aurum.core.BrandConfig
import com.aurum.core.ContentCatalogs
import com.aurum.core.DropSchedule
import com.aurum.core.LookCatalog
import com.aurum.core.render.PixelRenderer

class AurumApplication : Application() {
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = AppContainer(this)
    }
}

/** App-wide dependencies, built once from the shared catalogues in assets/. */
class AppContainer(context: Context) {
    private val app = context.applicationContext

    val catalog: LookCatalog = LookCatalog.decode(asset("looks/catalog.json"))
    val brand: BrandConfig = BrandConfig.decode(asset("brand/brand.json"))
    val drops: DropSchedule = ContentCatalogs.drops(asset("content/drops.json"))
    val renderer = PixelRenderer(catalog)

    val prefs = Prefs(app)
    val drafts = DraftStore(app, catalog)
    val presets = PresetStore(app)

    /**
     * Debug builds never talk to Google Play: purchases are simulated so the
     * paywall and export rules can be tried end to end.
     */
    val membership: MembershipStore =
        if (BuildConfig.DEBUG) FakeMembershipStore(prefs) else PlayBillingMembershipStore(app, brand)

    /** Copy that can change without a release; bundled defaults, as on iOS. */
    val config = RemoteConfigValues()

    private fun asset(path: String): String = app.assets.open(path).bufferedReader(Charsets.UTF_8).use { it.readText() }
}

data class RemoteConfigValues(
    val paywallHeadline: String = "The whole atelier, unlocked.",
    val paywallBenefits: List<String> = listOf(
        "Every look, effect and sticker",
        "Full-resolution export, no watermark",
        "New collections every week",
    ),
    val highlightedPlan: String = "yearly",
    val salonHeroCollection: String = "seasons",
    val termsUrl: String = "https://aurum.app/terms",
    val privacyUrl: String = "https://aurum.app/privacy",
)

val Context.container: AppContainer get() = (applicationContext as AurumApplication).container
