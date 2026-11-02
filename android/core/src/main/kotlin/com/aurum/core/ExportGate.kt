package com.aurum.core

/** What the current user is entitled to. */
enum class Entitlement { free, member }

/** A premium item used in an edit, listed on the paywall. */
sealed interface PremiumItem {
    val displayName: String

    data class Look(val id: String, val name: String) : PremiumItem {
        override val displayName get() = name
    }
    data class Sticker(val id: String) : PremiumItem {
        override val displayName get() = "Members' sticker"
    }
    object Retouch : PremiumItem {
        override val displayName get() = "Retouch"
        override fun toString() = "Retouch"
    }
    data class Effect(val kind: String) : PremiumItem {
        override val displayName get() = AnimatedEffect.Kind.entries.firstOrNull { it.name == kind }?.displayName ?: "Effect"
    }
    data class Template(val id: String, val name: String) : PremiumItem {
        override val displayName get() = name
    }
    data class CollageLayoutItem(val id: String, val name: String) : PremiumItem {
        override val displayName get() = name
    }
}

sealed interface ExportDecision {
    /** Export can go ahead; `maxPixelSize` null means full resolution. */
    data class Allowed(val watermark: Boolean, val maxPixelSize: Int?) : ExportDecision
    /** The edit uses premium items: show the paywall, which also offers exporting without them. */
    data class RequiresMembership(val items: List<PremiumItem>) : ExportDecision
}

/**
 * Membership rules, free of any store API. Everything can be previewed; the
 * paywall appears only when exporting an edit that uses premium items.
 */
object ExportGate {
    const val FREE_MAX_PIXEL_SIZE = 2048
    const val FREE_VIDEO_MAX_PIXEL_SIZE = 1920
    const val MEMBER_VIDEO_MAX_PIXEL_SIZE = 3840

    fun premiumItems(document: EditDocument, catalog: LookCatalog): List<PremiumItem> {
        val items = mutableListOf<PremiumItem>()
        for (op in document.operations) {
            if (!op.isEnabled) continue
            val look = (op.kind as? OperationKind.Look)?.look ?: continue
            if (look.intensity <= 0) continue
            val recipe = catalog.look(look.lookID)
            if (recipe != null && recipe.tier == Tier.member) {
                val item = PremiumItem.Look(recipe.id, recipe.name)
                if (item !in items) items.add(item)
            }
        }
        val usesRetouch = document.operations.any { op ->
            val k = op.kind
            k is OperationKind.Retouch && op.isEnabled && !k.retouch.isNeutral
        }
        if (usesRetouch) items.add(PremiumItem.Retouch)
        for (overlay in document.overlays) {
            if (overlay.isHidden) continue
            val sticker = (overlay.content as? OverlayContent.Sticker)?.sticker ?: continue
            if (sticker.tier == Tier.member) {
                val item = PremiumItem.Sticker(sticker.stickerID)
                if (item !in items) items.add(item)
            }
        }
        return items
    }

    fun decision(document: EditDocument, entitlement: Entitlement, catalog: LookCatalog): ExportDecision = when (entitlement) {
        Entitlement.member -> ExportDecision.Allowed(watermark = false, maxPixelSize = null)
        Entitlement.free -> {
            val items = premiumItems(document, catalog)
            if (items.isEmpty()) ExportDecision.Allowed(watermark = true, maxPixelSize = FREE_MAX_PIXEL_SIZE)
            else ExportDecision.RequiresMembership(items)
        }
    }

    /** The same edit with every premium item removed ("Export without them"). */
    fun strippingPremium(document: EditDocument, catalog: LookCatalog): EditDocument = document.copy(
        operations = document.operations.filterNot { op ->
            when (val k = op.kind) {
                is OperationKind.Look -> catalog.look(k.look.lookID)?.tier == Tier.member
                is OperationKind.Retouch -> true
                is OperationKind.Adjust -> false
            }
        },
        overlays = document.overlays.filterNot { o ->
            (o.content as? OverlayContent.Sticker)?.sticker?.tier == Tier.member
        },
    )

    // Video

    data class VideoExportDecision(
        val premiumItems: List<PremiumItem>,
        val watermark: Boolean,
        /** Longest side: 1920 free, 3840 (4K) for members. */
        val maxPixelSize: Int,
        val maxFrameRate: Int,
    ) {
        val requiresMembership: Boolean get() = premiumItems.isNotEmpty()
    }

    fun premiumItems(project: VideoProject, catalog: LookCatalog, templates: List<TemplateDefinition> = emptyList()): List<PremiumItem> {
        val items = mutableListOf<PremiumItem>()
        fun add(item: PremiumItem) { if (item !in items) items.add(item) }
        for (op in project.operations) {
            if (!op.isEnabled) continue
            val l = (op.kind as? OperationKind.Look)?.look ?: continue
            val recipe = catalog.look(l.lookID)
            if (l.intensity > 0 && recipe != null && recipe.tier == Tier.member) add(PremiumItem.Look(recipe.id, recipe.name))
        }
        for (effect in project.effects) {
            if (effect.tier == Tier.member && effect.intensity > 0) add(PremiumItem.Effect(effect.kind.name))
        }
        project.templateID?.let { id ->
            templates.firstOrNull { it.id == id }?.takeIf { it.tier == Tier.member }?.let { add(PremiumItem.Template(it.id, it.name)) }
        }
        for (layer in project.layers) {
            if (layer.overlay.isHidden) continue
            val s = (layer.overlay.content as? OverlayContent.Sticker)?.sticker ?: continue
            if (s.tier == Tier.member) add(PremiumItem.Sticker(s.stickerID))
        }
        return items
    }

    fun videoDecision(project: VideoProject, entitlement: Entitlement, catalog: LookCatalog, templates: List<TemplateDefinition> = emptyList()) =
        when (entitlement) {
            Entitlement.member -> VideoExportDecision(emptyList(), false, MEMBER_VIDEO_MAX_PIXEL_SIZE, 60)
            Entitlement.free -> VideoExportDecision(premiumItems(project, catalog, templates), true, FREE_VIDEO_MAX_PIXEL_SIZE, 30)
        }

    // Collage

    fun premiumItems(collage: CollageProject): List<PremiumItem> =
        if (collage.layout.tier == Tier.member) listOf(PremiumItem.CollageLayoutItem(collage.layout.id, collage.layout.name)) else emptyList()

    fun collageDecision(collage: CollageProject, entitlement: Entitlement): ExportDecision = when (entitlement) {
        Entitlement.member -> ExportDecision.Allowed(false, null)
        Entitlement.free -> premiumItems(collage).let {
            if (it.isEmpty()) ExportDecision.Allowed(true, FREE_MAX_PIXEL_SIZE) else ExportDecision.RequiresMembership(it)
        }
    }
}
