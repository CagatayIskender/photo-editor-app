package com.aurum.core

import kotlinx.serialization.Serializable
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/** Beat times for a track, used to cut template slots on the beat. */
@Serializable
data class BeatGrid(val bpm: Double, val offset: Seconds = 0.0) {
    val beatLength: Seconds get() = 60 / bpm

    /** Beat times from [start] (track time) until [end]. */
    fun beats(start: Seconds, end: Seconds): List<Seconds> {
        if (end <= start) return emptyList()
        var n = max(0.0, ceil((start - offset) / beatLength))
        val result = mutableListOf<Seconds>()
        while (true) {
            val t = offset + n * beatLength
            if (t >= end) break
            result.add(t)
            n += 1
        }
        return result
    }

    /** The nearest beat to [t]. */
    fun quantize(t: Seconds): Seconds = offset + swiftRound((t - offset) / beatLength) * beatLength

    companion object {
        fun of(bpm: Double, offset: Seconds = 0.0) = BeatGrid(min(max(bpm, 40.0), 220.0), max(0.0, offset))
    }
}

/** One slot in a template: a photo or clip for a number of beats. */
@Serializable
data class TemplateSlot(
    val beats: Int,
    val transition: Transition = Transition.Cut,
    val lookID: String? = null,
    val motion: StillMotion = StillMotion.pushIn,
)

/** Gentle camera moves for stills. */
@Serializable
enum class StillMotion {
    none, pushIn, pullOut, driftLeft, driftRight;

    /** Scale and normalised offset at progress p (0...1). */
    fun transform(p: Double): Triple<Double, Double, Double> {
        val q = (0.0..1.0).clamp(p)
        return when (this) {
            none -> Triple(1.0, 0.0, 0.0)
            pushIn -> Triple(1 + 0.08 * q, 0.0, 0.0)
            pullOut -> Triple(1.08 - 0.08 * q, 0.0, 0.0)
            driftLeft -> Triple(1.06, 0.03 - 0.06 * q, 0.0)
            driftRight -> Triple(1.06, -0.03 + 0.06 * q, 0.0)
        }
    }
}

/** A one-tap video template, from Content/templates.json. */
@Serializable
data class TemplateDefinition(
    val id: String,
    val name: String,
    val tagline: String,
    val tier: Tier,
    val aspect: AspectPreset = AspectPreset.story,
    val slots: List<TemplateSlot>,
    val musicTrackID: String? = null,
    val bpm: Double = 100.0,
    val lookID: String? = null,
    val effects: List<AnimatedEffect> = emptyList(),
    val intro: BookendEffect? = null,
    val outro: BookendEffect? = null,
) {
    val mediaCount: Int get() = slots.size
}

/** A photo or video picked for a template. */
data class TemplateMedia(val source: SourceAsset, val kind: Clip.Kind, val duration: Seconds = 0.0)

object TemplateBuilder {
    class NoMedia : Exception("No media")

    /**
     * Each slot gets the next media item (cycling), lasting exactly its beats
     * so every cut lands on the beat. Videos use their middle section; short
     * ones are slowed down, to quarter speed at most.
     */
    fun build(template: TemplateDefinition, media: List<TemplateMedia>, music: MusicSelection? = null): VideoProject {
        if (media.isEmpty()) throw NoMedia()
        val grid = music?.beats ?: BeatGrid.of(template.bpm)
        val clips = template.slots.mapIndexed { i, slot ->
            val item = media[i % media.size]
            val length = slot.beats * grid.beatLength
            val overlap = if (i == 0) 0.0 else slot.transition.duration
            val wanted = length + overlap
            val clip = when (item.kind) {
                Clip.Kind.photo -> Clip.of(Clip.Kind.photo, item.source, wanted)
                Clip.Kind.video -> {
                    val available = max(item.duration, Clip.MINIMUM_DURATION)
                    if (available >= wanted) {
                        val start = (available - wanted) / 2
                        Clip.of(Clip.Kind.video, item.source, available, trimStart = start, trimEnd = start + wanted)
                    } else {
                        Clip.of(Clip.Kind.video, item.source, available).withSpeed(available / wanted)
                    }
                }
            }
            clip.copy(transitionIn = if (i == 0) Transition.Cut else slot.transition)
        }
        return VideoProject(
            clips = clips,
            operations = template.lookID?.let { listOf(EditOperation(kind = OperationKind.Look(LookApplication.of(it)))) } ?: emptyList(),
            effects = template.effects,
            aspect = template.aspect,
            music = music,
            intro = template.intro,
            outro = template.outro,
            templateID = template.id,
        )
    }
}

/** An intro or outro style, from Content/bookends.json. */
@Serializable
data class BookendPreset(val id: String, val name: String, val kind: Kind, val duration: Seconds, val tier: Tier) {
    @Serializable
    enum class Kind { intro, outro }
}
