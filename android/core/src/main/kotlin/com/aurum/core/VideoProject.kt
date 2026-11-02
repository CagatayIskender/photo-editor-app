package com.aurum.core

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.time.Instant
import java.util.UUID
import kotlin.math.max
import kotlin.math.min

/** Time in seconds. */
typealias Seconds = Double

/** A video clip or a still photo on the timeline. */
@Serializable
data class Clip(
    @Serializable(with = UuidSerializer::class) val id: UUID = UUID.randomUUID(),
    val kind: Kind,
    val source: SourceAsset,
    /** Length of the source media (for photos, the still duration). */
    val sourceDuration: Seconds,
    val trimStart: Seconds = 0.0,
    val trimEnd: Seconds = sourceDuration,
    /** 0.25 (slow motion) to 4. */
    val speed: Double = 1.0,
    val isReversed: Boolean = false,
    /** 0...1 */
    val volume: Double = 1.0,
    /** Transition into this clip from the previous one. */
    val transitionIn: Transition = Transition.Cut,
) {
    @Serializable
    enum class Kind { video, photo }

    /** Length on the timeline, after trimming and speed. */
    val duration: Seconds get() = (trimEnd - trimStart) / speed

    /** Source time shown at [local] seconds into the clip. */
    fun sourceTime(local: Seconds): Seconds {
        val t = min(max(local, 0.0), duration) * speed
        return if (isReversed) trimEnd - t else trimStart + t
    }

    /** A copy trimmed to [start, end], keeping at least the minimum duration. */
    fun trimmed(start: Seconds, end: Seconds): Clip {
        val s = min(max(0.0, start), sourceDuration - MINIMUM_DURATION)
        val e = max(min(sourceDuration, end), s + MINIMUM_DURATION)
        return copy(trimStart = s, trimEnd = e)
    }

    fun withSpeed(value: Double): Clip = copy(speed = SPEED_RANGE.clamp(value))

    companion object {
        val SPEED_RANGE = 0.25..4.0
        const val MINIMUM_DURATION: Seconds = 0.2

        /** Normalising factory, equivalent to the Swift initialiser. */
        fun of(
            kind: Kind,
            source: SourceAsset,
            sourceDuration: Seconds,
            trimStart: Seconds = 0.0,
            trimEnd: Seconds? = null,
            speed: Double = 1.0,
            isReversed: Boolean = false,
            volume: Double = 1.0,
            transitionIn: Transition = Transition.Cut,
            id: UUID = UUID.randomUUID(),
        ): Clip {
            val duration = max(sourceDuration, MINIMUM_DURATION)
            return Clip(
                id = id, kind = kind, source = source, sourceDuration = duration,
                trimStart = max(0.0, trimStart),
                trimEnd = min(trimEnd ?: sourceDuration, duration),
                speed = SPEED_RANGE.clamp(speed), isReversed = isReversed,
                volume = (0.0..1.0).clamp(volume), transitionIn = transitionIn,
            )
        }

        fun photo(source: SourceAsset, duration: Seconds = 3.0) = of(Kind.photo, source, duration)
    }
}

/** How one clip hands over to the next: `{"type": "dissolve", "duration": 0.5}`. */
@Serializable(with = TransitionSerializer::class)
sealed interface Transition {
    val duration: Seconds

    object Cut : Transition {
        override val duration: Seconds get() = 0.0
        override fun toString() = "Cut"
    }
    data class Dissolve(override val duration: Seconds) : Transition
    data class DipToBlack(override val duration: Seconds) : Transition
    data class Slide(override val duration: Seconds) : Transition
    data class Zoom(override val duration: Seconds) : Transition
    data class Ai(val jobID: String?, override val duration: Seconds) : Transition
}

object TransitionSerializer : KSerializer<Transition> {
    override val descriptor: SerialDescriptor = buildClassSerialDescriptor("aurum.Transition")

    override fun serialize(encoder: Encoder, value: Transition) {
        val fields = linkedMapOf<String, JsonElement>()
        val tag = when (value) {
            Transition.Cut -> "cut"
            is Transition.Dissolve -> "dissolve"
            is Transition.DipToBlack -> "dipToBlack"
            is Transition.Slide -> "slide"
            is Transition.Zoom -> "zoom"
            is Transition.Ai -> "ai"
        }
        fields["type"] = JsonPrimitive(tag)
        if (value != Transition.Cut) fields["duration"] = JsonPrimitive(value.duration)
        if (value is Transition.Ai && value.jobID != null) fields["jobID"] = JsonPrimitive(value.jobID)
        encoder.asJson().encodeJsonElement(JsonObject(fields))
    }

    override fun deserialize(decoder: Decoder): Transition {
        val obj = decoder.asJson().requireObject()
        val d = obj.double("duration") ?: 0.5
        return when (obj.string("type")) {
            "cut" -> Transition.Cut
            "dissolve" -> Transition.Dissolve(d)
            "dipToBlack" -> Transition.DipToBlack(d)
            "slide" -> Transition.Slide(d)
            "zoom" -> Transition.Zoom(d)
            "ai" -> Transition.Ai(obj.string("jobID"), d)
            else -> throw SerializationException("Unknown transition ${obj["type"]}")
        }
    }
}

/** Simple in and out animations for layers. */
@Serializable
enum class LayerAnimation(val displayName: String) {
    none("None"), fade("Fade"), rise("Rise"), drop("Drop"), zoom("Zoom"), typewriter("Typewriter"), shimmer("Shimmer")
}

/** A text or sticker layer shown for part of a video. */
@Serializable
data class TimedLayer(
    val overlay: Overlay,
    val start: Seconds,
    val end: Seconds,
    val animationIn: LayerAnimation = LayerAnimation.fade,
    val animationOut: LayerAnimation = LayerAnimation.fade,
    val animationDuration: Seconds = 0.4,
) {
    val id: UUID get() = overlay.id

    fun isVisible(t: Seconds) = t >= start && t < end

    /** In (0→1) or out (1→0) animation progress at [t]; 1 when fully shown. */
    fun presence(t: Seconds): Double {
        if (!isVisible(t)) return 0.0
        val d = max(animationDuration, 0.001)
        val inP = if (animationIn == LayerAnimation.none) 1.0 else min(1.0, (t - start) / d)
        val outP = if (animationOut == LayerAnimation.none) 1.0 else min(1.0, (end - t) / d)
        return max(0.0, min(inP, outP))
    }

    companion object {
        fun of(overlay: Overlay, start: Seconds, end: Seconds, animationIn: LayerAnimation = LayerAnimation.fade, animationOut: LayerAnimation = LayerAnimation.fade, animationDuration: Seconds = 0.4) =
            TimedLayer(overlay, max(0.0, start), max(end, start + Clip.MINIMUM_DURATION), animationIn, animationOut, animationDuration)
    }
}

/** Background music for the whole video. */
@Serializable
data class MusicSelection(
    val source: MusicSource,
    val title: String,
    val startOffset: Seconds = 0.0,
    val volume: Double = 0.8,
    val fadeIn: Seconds = 0.5,
    val fadeOut: Seconds = 1.0,
    val beats: BeatGrid? = null,
) {
    /** Volume multiplier at video time [t], with fades over [total] seconds. */
    fun gain(t: Seconds, total: Seconds): Double {
        var g = volume
        if (fadeIn > 0 && t < fadeIn) g *= max(0.0, t / fadeIn)
        if (fadeOut > 0 && t > total - fadeOut) g *= max(0.0, (total - t) / fadeOut)
        return g
    }
}

/**
 * Swift's synthesised enum coding: `{"library": {"trackID": "t1"}}` or
 * `{"imported": {"fileName": "a.m4a"}}`.
 */
@Serializable(with = MusicSourceSerializer::class)
sealed interface MusicSource {
    data class Library(val trackID: String) : MusicSource
    data class Imported(val fileName: String) : MusicSource
}

object MusicSourceSerializer : KSerializer<MusicSource> {
    override val descriptor: SerialDescriptor = buildClassSerialDescriptor("aurum.MusicSource")

    override fun serialize(encoder: Encoder, value: MusicSource) {
        val obj = when (value) {
            is MusicSource.Library -> JsonObject(mapOf("library" to JsonObject(mapOf("trackID" to JsonPrimitive(value.trackID)))))
            is MusicSource.Imported -> JsonObject(mapOf("imported" to JsonObject(mapOf("fileName" to JsonPrimitive(value.fileName)))))
        }
        encoder.asJson().encodeJsonElement(obj)
    }

    override fun deserialize(decoder: Decoder): MusicSource {
        val obj = decoder.asJson().requireObject()
        (obj["library"] as? JsonObject)?.let { return MusicSource.Library(it.string("trackID") ?: missing("trackID")) }
        (obj["imported"] as? JsonObject)?.let { return MusicSource.Imported(it.string("fileName") ?: missing("fileName")) }
        throw SerializationException("Unknown music source")
    }
}

/** Animated opening or closing card. */
@Serializable
data class BookendEffect(val presetID: String, val duration: Seconds = 1.5, val title: String? = null)

/** A video edit: clips, one graded look stack, timed layers, music, bookends. */
@Serializable
data class VideoProject(
    val schemaVersion: Int = CURRENT_SCHEMA_VERSION,
    @Serializable(with = UuidSerializer::class) val id: UUID = UUID.randomUUID(),
    val clips: List<Clip> = emptyList(),
    val operations: List<EditOperation> = emptyList(),
    val effects: List<AnimatedEffect> = emptyList(),
    val aspect: AspectPreset = AspectPreset.story,
    val layers: List<TimedLayer> = emptyList(),
    val music: MusicSelection? = null,
    val intro: BookendEffect? = null,
    val outro: BookendEffect? = null,
    val templateID: String? = null,
    @Serializable(with = InstantSerializer::class) val createdAt: Instant = Instant.now().wholeSeconds,
    @Serializable(with = InstantSerializer::class) val modifiedAt: Instant = createdAt,
) {
    /** Where each clip starts; a transition overlaps the incoming clip with the previous one. */
    val clipStartTimes: List<Seconds>
        get() {
            val starts = ArrayList<Seconds>(clips.size)
            var t = intro?.duration ?: 0.0
            clips.forEachIndexed { i, clip ->
                if (i > 0) t -= minOf(clip.transitionIn.duration, clip.duration / 2, clips[i - 1].duration / 2)
                starts.add(t)
                t += clip.duration
            }
            return starts
        }

    /** Total length including intro and outro. */
    val duration: Seconds
        get() {
            val lastStart = clipStartTimes.lastOrNull()
            val last = clips.lastOrNull()
            if (lastStart == null || last == null) return (intro?.duration ?: 0.0) + (outro?.duration ?: 0.0)
            return lastStart + last.duration + (outro?.duration ?: 0.0)
        }

    /** The clip on screen at [t] (the incoming one during a transition) and the local time in it. */
    fun clipAt(t: Seconds): Pair<Int, Seconds>? {
        val starts = clipStartTimes
        for (i in clips.indices.reversed()) {
            if (t >= starts[i]) {
                val local = t - starts[i]
                return if (local < clips[i].duration) i to local else null
            }
        }
        return null
    }

    fun append(clip: Clip) = copy(clips = clips + clip)

    fun moveClip(from: Int, to: Int): VideoProject {
        if (from !in clips.indices) return this
        val list = clips.toMutableList()
        val clip = list.removeAt(from)
        list.add(min(max(to, 0), list.size), clip)
        return copy(clips = list)
    }

    fun removeClip(id: UUID) = copy(clips = clips.filter { it.id != id })

    /** Splits the clip under [t] in two, or returns null if [t] is too close to an end. */
    fun split(t: Seconds): VideoProject? {
        val (index, local) = clipAt(t) ?: return null
        val clip = clips[index]
        if (local < Clip.MINIMUM_DURATION || clip.duration - local < Clip.MINIMUM_DURATION) return null
        val cut = clip.sourceTime(local)
        val first: Clip
        val second: Clip
        if (clip.isReversed) {
            first = clip.copy(trimStart = cut)
            second = clip.copy(id = UUID.randomUUID(), transitionIn = Transition.Cut, trimEnd = cut)
        } else {
            first = clip.copy(trimEnd = cut)
            second = clip.copy(id = UUID.randomUUID(), transitionIn = Transition.Cut, trimStart = cut)
        }
        val list = clips.toMutableList()
        list[index] = first
        list.add(index + 1, second)
        return copy(clips = list)
    }

    fun updateClip(id: UUID, change: (Clip) -> Clip) = copy(clips = clips.map { if (it.id == id) change(it) else it })

    fun encoded(): String = AurumJson.encodeCanonical(serializer(), this)

    companion object {
        const val CURRENT_SCHEMA_VERSION = 1
        fun decode(json: String): VideoProject = AurumJson.format.decodeFromString(serializer(), json)
    }
}
