package com.aurum.core

import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * Pure timing and gating logic behind the Android video renderer, ported
 * from the iOS `AurumVideoCompositor`, `VideoCompositionBuilder` and
 * `VideoExportViewModel`.
 *
 * Android renders a project as one sequence of media items (Media3), so a
 * clip that hands over to the next with a transition is cut where the next
 * clip starts; the transition then draws the outgoing clip's last frame under
 * the incoming one. Every item therefore starts exactly at the project's
 * clip start time, and the timeline (and every beat cut) keeps its timing.
 */
object VideoRenderPlan {

    data class Item(
        val kind: Kind,
        /** The clip index for [Kind.clip]; -1 for bookends. */
        val clipIndex: Int,
        /** Timeline start, seconds. */
        val start: Seconds,
        /** Length on the timeline, seconds. */
        val duration: Seconds,
        /**
         * Source range for a video clip, in file time. For a reversed clip it
         * is in the time of the reversed file (which runs backwards).
         */
        val sourceStart: Seconds = 0.0,
        val sourceEnd: Seconds = 0.0,
        val speed: Double = 1.0,
    ) {
        enum class Kind { intro, clip, outro }
    }

    /** A transition window: [clipIndex] comes in over the previous clip from [start] for [duration]. */
    data class TransitionWindow(
        val clipIndex: Int,
        val transition: Transition,
        val start: Seconds,
        val duration: Seconds,
        /** Local time in the outgoing clip when the window opens: its last frame on screen. */
        val outgoingLocal: Seconds,
    )

    fun items(project: VideoProject): List<Item> {
        val result = mutableListOf<Item>()
        project.intro?.let { result.add(Item(Item.Kind.intro, -1, 0.0, max(it.duration, MIN_ITEM))) }
        val starts = project.clipStartTimes
        project.clips.forEachIndexed { i, clip ->
            val start = starts[i]
            val end = if (i + 1 < starts.size) starts[i + 1] else start + clip.duration
            val length = max(end - start, MIN_ITEM)
            val item = when (clip.kind) {
                Clip.Kind.photo -> Item(Item.Kind.clip, i, start, length)
                Clip.Kind.video -> {
                    val sourceLength = min(length * clip.speed, clip.trimEnd - clip.trimStart)
                    val s = if (clip.isReversed) clip.sourceDuration - clip.trimEnd else clip.trimStart
                    Item(Item.Kind.clip, i, start, length, s, s + sourceLength, clip.speed)
                }
            }
            result.add(item)
        }
        project.outro?.let {
            result.add(Item(Item.Kind.outro, -1, project.duration - it.duration, max(it.duration, MIN_ITEM)))
        }
        return result
    }

    fun transitions(project: VideoProject): List<TransitionWindow> {
        val starts = project.clipStartTimes
        val result = mutableListOf<TransitionWindow>()
        for (i in 1 until project.clips.size) {
            val clip = project.clips[i]
            val previous = project.clips[i - 1]
            if (clip.transitionIn == Transition.Cut) continue
            val overlap = minOf(clip.transitionIn.duration, clip.duration / 2, previous.duration / 2)
            if (overlap <= 0) continue
            result.add(TransitionWindow(i, clip.transitionIn, starts[i], overlap, previous.duration - overlap))
        }
        return result
    }

    /** True when [t] is inside the intro or outro card, which the grade and effects skip. */
    fun isBookend(project: VideoProject, t: Seconds): Boolean {
        val intro = project.intro?.duration ?: 0.0
        if (project.intro != null && t < intro) return true
        val outro = project.outro ?: return false
        return t >= project.duration - outro.duration
    }

    /** Output size for an aspect, longest side [maxPixelSize], even dimensions (iOS `renderSize`). */
    fun renderSize(aspect: AspectPreset, maxPixelSize: Int): PixelSize {
        val ratio = aspect.ratio ?: (9.0 / 16.0)
        fun even(v: Double) = (swiftRound(v / 2) * 2).toInt()
        return if (ratio >= 1) PixelSize(even(maxPixelSize.toDouble()), even(maxPixelSize / ratio))
        else PixelSize(even(maxPixelSize * ratio), even(maxPixelSize.toDouble()))
    }

    private const val MIN_ITEM = 0.05
}

/** Timed layers at a moment, with their in and out animation (iOS `AurumVideoCompositor.layers`). */
object LayerAnimator {
    fun overlays(project: VideoProject, t: Seconds): List<Overlay> {
        val visible = mutableListOf<Overlay>()
        for (layer in project.layers) {
            if (!layer.isVisible(t) || layer.overlay.isHidden) continue
            val presence = layer.presence(t)
            var o = layer.overlay
            val entering = t - layer.start < layer.end - t
            val animation = if (entering) layer.animationIn else layer.animationOut
            val eased = 1 - (1 - presence).pow(3)
            o = when (animation) {
                LayerAnimation.none -> o
                LayerAnimation.fade, LayerAnimation.shimmer, LayerAnimation.typewriter -> o.copy(opacity = o.opacity * eased)
                LayerAnimation.rise -> o.copy(opacity = o.opacity * eased, center = o.center.copy(y = o.center.y + (1 - eased) * 0.05))
                LayerAnimation.drop -> o.copy(opacity = o.opacity * eased, center = o.center.copy(y = o.center.y - (1 - eased) * 0.05))
                LayerAnimation.zoom -> o.copy(opacity = o.opacity * eased, scale = o.scale * (0.8 + 0.2 * eased))
            }
            val content = o.content
            if (animation == LayerAnimation.typewriter && content is OverlayContent.Text && presence < 1) {
                val count = ceil(content.text.text.length * presence).toInt()
                o = o.copy(content = OverlayContent.Text(content.text.copy(text = content.text.text.take(count))), opacity = layer.overlay.opacity)
            }
            visible.add(o)
        }
        return visible
    }
}

/** Export rules for video, including member intro and outro styles (iOS `VideoExportViewModel`). */
object VideoExportRules {
    /** Bookends travel as [PremiumItem.Template] items with this id prefix. */
    const val BOOKEND_PREFIX = "bookend."

    fun premiumBookends(project: VideoProject, bookends: List<BookendPreset>): List<PremiumItem> =
        listOfNotNull(project.intro, project.outro).mapNotNull { effect ->
            val preset = bookends.firstOrNull { it.id == effect.presetID } ?: return@mapNotNull null
            if (preset.tier != Tier.member) null else PremiumItem.Template(BOOKEND_PREFIX + preset.id, preset.name)
        }

    fun isBookend(item: PremiumItem) = item is PremiumItem.Template && item.id.startsWith(BOOKEND_PREFIX)

    /** The same video with every member look, effect, sticker and bookend removed. */
    fun strippingPremium(project: VideoProject, catalog: LookCatalog, bookends: List<BookendPreset>): VideoProject {
        fun isMember(effect: BookendEffect?) = effect != null && bookends.firstOrNull { it.id == effect.presetID }?.tier == Tier.member
        return project.copy(
            operations = project.operations.filterNot { op ->
                val k = op.kind
                k is OperationKind.Look && catalog.look(k.look.lookID)?.tier == Tier.member
            },
            effects = project.effects.filterNot { it.tier == Tier.member },
            layers = project.layers.filterNot { (it.overlay.content as? OverlayContent.Sticker)?.sticker?.tier == Tier.member },
            intro = if (isMember(project.intro)) null else project.intro,
            outro = if (isMember(project.outro)) null else project.outro,
        )
    }

    fun decision(
        project: VideoProject,
        entitlement: Entitlement,
        catalog: LookCatalog,
        templates: List<TemplateDefinition>,
        bookends: List<BookendPreset>,
    ): ExportGate.VideoExportDecision {
        val d = ExportGate.videoDecision(project, entitlement, catalog, templates)
        if (entitlement != Entitlement.free) return d
        val items = d.premiumItems.toMutableList()
        for (item in premiumBookends(project, bookends)) if (item !in items) items.add(item)
        return d.copy(premiumItems = items)
    }

    /** Member items in the edit as made, before any are left out. */
    fun premiumItems(project: VideoProject, catalog: LookCatalog, templates: List<TemplateDefinition>, bookends: List<BookendPreset>): List<PremiumItem> =
        ExportGate.premiumItems(project, catalog, templates) + premiumBookends(project, bookends)

    /** A member template is the edit itself, so it can't be left out. */
    fun canExportWithoutPremium(items: List<PremiumItem>): Boolean = items.none { it is PremiumItem.Template && !isBookend(it) }

    /** Which effects are for members. The subtle ones are free. */
    fun tier(kind: AnimatedEffect.Kind): Tier = when (kind) {
        AnimatedEffect.Kind.flicker, AnimatedEffect.Kind.lightLeak, AnimatedEffect.Kind.shake -> Tier.free
        AnimatedEffect.Kind.glitter, AnimatedEffect.Kind.vhsTracking, AnimatedEffect.Kind.zoomPulse -> Tier.member
    }
}
