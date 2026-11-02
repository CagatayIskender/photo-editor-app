package com.aurum.core

import kotlinx.serialization.Serializable
import java.util.UUID
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.sin

/**
 * An effect whose strength changes over time on video. [sample] is a pure
 * function of time and seed, bit-for-bit the same maths as iOS.
 */
@Serializable
data class AnimatedEffect(
    @Serializable(with = UuidSerializer::class) val id: UUID = UUID.randomUUID(),
    val kind: Kind,
    /** 0...1 */
    val intensity: Double = 0.6,
    /** Cycles per second. */
    val rate: Double = 1.0,
    val start: Seconds = 0.0,
    /** null means until the end. */
    val end: Seconds? = null,
    val seed: ULong = 1uL,
    val tier: Tier = Tier.free,
) {
    @Serializable
    enum class Kind(val displayName: String) {
        flicker("Flicker"), lightLeak("Light Leak"), glitter("Glitter"), vhsTracking("Tape Tracking"), shake("Handheld"), zoomPulse("Pulse")
    }

    data class Sample(
        val exposure: Double = 1.0,
        val leak: Double = 0.0,
        val leakPosition: Double = 0.5,
        val glitter: Double = 0.0,
        val tracking: Double = 0.0,
        val offsetX: Double = 0.0,
        val offsetY: Double = 0.0,
        val zoom: Double = 1.0,
    )

    fun isActive(t: Seconds) = t >= start && (end?.let { t < it } ?: true)

    fun sample(t: Seconds): Sample {
        if (!isActive(t) || intensity <= 0) return Sample()
        val local = t - start
        val k = intensity
        return when (kind) {
            Kind.flicker -> {
                val wave = sin(local * rate * 2 * PI * 3.1) * 0.5 + sin(local * rate * 2 * PI * 7.3) * 0.3
                Sample(exposure = 1 + k * 0.12 * (wave + 0.4 * noise(local * 24, seed)))
            }
            Kind.lightLeak -> {
                val phase = local * rate * 0.25
                Sample(leak = k * (0.55 + 0.45 * sin(phase * 2 * PI)), leakPosition = 0.5 + 0.45 * sin(phase * 2 * PI * 0.7 + 1.3))
            }
            Kind.glitter -> Sample(glitter = k * (0.6 + 0.4 * abs(sin(local * rate * 2 * PI))))
            Kind.vhsTracking -> {
                val burst = max(0.0, noise(local * rate * 0.8, seed) - 0.3) / 0.7
                Sample(tracking = k * burst)
            }
            Kind.shake -> Sample(
                offsetX = k * 0.012 * noise(local * rate * 6, seed),
                offsetY = k * 0.012 * noise(local * rate * 6, seed + 7uL),
                zoom = 1 + k * 0.03,
            )
            Kind.zoomPulse -> {
                val beat = (local * rate).rem(1.0)
                Sample(zoom = 1 + k * 0.06 * exp(-beat * 6))
            }
        }
    }

    companion object {
        fun of(kind: Kind, intensity: Double = 0.6, rate: Double = 1.0, start: Seconds = 0.0, end: Seconds? = null, seed: ULong = 1uL, tier: Tier = Tier.free, id: UUID = UUID.randomUUID()) =
            AnimatedEffect(id, kind, (0.0..1.0).clamp(intensity), max(0.05, rate), max(0.0, start), end, seed, tier)

        /** Smooth value noise in -1...1, deterministic for a seed. */
        fun noise(x: Double, seed: ULong): Double {
            val i = floor(x)
            val f = x - i
            val a = hash(i.toLong(), seed)
            val b = hash(i.toLong() + 1, seed)
            val u = f * f * (3 - 2 * f)
            return a + (b - a) * u
        }

        internal fun hash(n: Long, seed: ULong): Double {
            var h = (n.toULong() * 0x9E3779B97F4A7C15uL) xor seed
            h = h xor (h shr 31)
            h *= 0xBF58476D1CE4E5B9uL
            h = h xor (h shr 29)
            return (h % 2_000_001uL).toDouble() / 1_000_000 - 1
        }
    }
}

/** A royalty-free track in the music catalogue (the bundled catalogue is empty). */
@Serializable
data class MusicTrack(
    val id: String,
    val title: String,
    val artist: String,
    val mood: String,
    val duration: Seconds,
    val beats: BeatGrid,
    val tier: Tier,
    val path: String,
    val licence: String,
)
