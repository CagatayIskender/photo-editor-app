package com.aurum.core

import kotlinx.serialization.Serializable
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * Camera moves for 3D photo motion: the renderer splits the photo into depth
 * layers and moves a virtual camera through them.
 */
@Serializable
enum class DepthMotionPreset {
    /** The camera circles the subject. */
    orbit,
    /** Moves in and back out, with the focus following. */
    dolly,
    /** Sways side to side. */
    swing,
    /** A slow figure of eight, like a drifting balloon. */
    float;

    /**
     * Dolly and Float are free; Orbit and Swing are members' moves. As with
     * every member item, they can be previewed freely and membership is asked
     * for only at export.
     */
    val tier: Tier
        get() = when (this) {
            dolly, float -> Tier.free
            orbit, swing -> Tier.member
        }

    /** English title; also the localisation key. */
    val title: String
        get() = when (this) {
            orbit -> "Orbit"
            dolly -> "Dolly"
            swing -> "Swing"
            float -> "Float"
        }
}

/**
 * A looping 3D photo move. Samples are deterministic and the loop is
 * seamless: the sample at t = 0 equals the sample at t = duration.
 *
 * Build one with [of], which clamps like the Swift initialiser; decoding keeps
 * the stored values, as Swift's synthesised `Codable` does.
 */
@Serializable
data class DepthMotion(
    val preset: DepthMotionPreset,
    /** 0...1 scales every amplitude. */
    val intensity: Double = 0.6,
    /** Depth the focus rests at, 0...1. */
    val focusDepth: Double = 0.4,
) {
    /** The camera at one instant. */
    data class Sample(
        /** Camera offset, normalised to the frame. */
        val dx: Double,
        val dy: Double,
        /** Scale, always at least 1 and large enough to hide the frame edges for the current offset. */
        val zoom: Double,
        /** 0 is nearest, 1 farthest. */
        val focusDepth: Double,
    )

    /**
     * The camera at time [t] of a loop lasting [duration]. Times outside
     * 0...duration wrap around.
     */
    fun sample(t: Seconds, duration: Seconds = DEFAULT_DURATION): Sample {
        val unit = 0.0..1.0
        val a = unit.clamp(intensity)
        val base = unit.clamp(focusDepth)
        var phase = 0.0
        if (duration > 0 && t.isFinite()) {
            val cycles = t / duration
            phase = cycles - floor(cycles)
        }
        val theta = 2 * PI * phase
        val m = MAX_OFFSET * a
        // Zoom needed so an offset of m never shows the frame edge.
        val cover = 2 * m
        // 0 at the loop start, 1 halfway, back to 0 at the end.
        val wave = (1 - cos(theta)) / 2

        var dx = 0.0
        var dy = 0.0
        var zoom = 1 + cover
        var focus = base
        when (preset) {
            DepthMotionPreset.orbit -> {
                dx = m * sin(theta)
                dy = m * (cos(theta) - 1) / 2
                focus = base
            }
            DepthMotionPreset.dolly -> {
                zoom = 1 + cover + (MAX_ZOOM - 2 * MAX_OFFSET) * a * wave
                focus = base + MAX_FOCUS_SHIFT * a * wave
            }
            DepthMotionPreset.swing -> {
                dx = m * sin(theta)
                focus = base - MAX_FOCUS_SHIFT * a * 0.5 * wave
            }
            DepthMotionPreset.float -> {
                dx = 0.6 * m * sin(theta)
                dy = 0.5 * m * sin(2 * theta)
                zoom = 1 + cover + 0.02 * a * wave
            }
        }
        // `+ 0.0` turns -0.0 into 0.0, so samples compare equal the way Swift's == does.
        return Sample(dx + 0.0, dy + 0.0, zoom + 0.0, unit.clamp(focus) + 0.0)
    }

    companion object {
        /** Largest camera offset at intensity 1, as a fraction of the frame. */
        const val MAX_OFFSET = 0.03
        /** Largest zoom above 1 at intensity 1. */
        const val MAX_ZOOM = 0.12
        /** Largest change of the focus depth at intensity 1. */
        const val MAX_FOCUS_SHIFT = 0.15
        const val DEFAULT_DURATION: Seconds = 4.0

        /** Longest side of an exported 3D Motion video. */
        const val EXPORT_LONGEST_SIDE = 1920

        /** The Swift initialiser: intensity and focus clamped to 0...1. */
        fun of(preset: DepthMotionPreset, intensity: Double = 0.6, focusDepth: Double = 0.4) =
            DepthMotion(preset, (0.0..1.0).clamp(intensity), (0.0..1.0).clamp(focusDepth))

        /** True when exporting [preset] needs membership. */
        fun requiresMembership(preset: DepthMotionPreset, entitlement: Entitlement): Boolean =
            preset.tier == Tier.member && entitlement == Entitlement.free

        /** The photo's shape at [longestSide], in even pixels (never upscaled). */
        fun exportSize(width: Int, height: Int, longestSide: Int = EXPORT_LONGEST_SIDE): PixelSize {
            if (width <= 0 || height <= 0) return PixelSize(1080, 1350)
            val scale = min(1.0, longestSide.toDouble() / max(width, height))
            fun even(v: Int): Int = max(2, (floor(v * scale / 2) * 2).toInt())
            return PixelSize(even(width), even(height))
        }
    }
}
