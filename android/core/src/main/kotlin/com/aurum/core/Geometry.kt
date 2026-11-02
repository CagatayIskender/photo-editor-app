package com.aurum.core

import kotlinx.serialization.Serializable
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong

/** A point in normalised coordinates: (0, 0) top-left, (1, 1) bottom-right. */
@Serializable
data class NormalizedPoint(val x: Double, val y: Double) {
    companion object {
        val center = NormalizedPoint(0.5, 0.5)
    }
}

/** A rectangle in normalised coordinates of the source image. */
@Serializable
data class NormalizedRect(val x: Double, val y: Double, val width: Double, val height: Double) {
    /** Clamped inside the unit square with a minimum size, so a crop stays usable. */
    fun clamped(minimumSize: Double = 0.05): NormalizedRect {
        val w = min(max(width, minimumSize), 1.0)
        val h = min(max(height, minimumSize), 1.0)
        val cx = min(max(x, 0.0), 1 - w)
        val cy = min(max(y, 0.0), 1 - h)
        return NormalizedRect(cx, cy, w, h)
    }

    companion object {
        val full = NormalizedRect(0.0, 0.0, 1.0, 1.0)
    }
}

/** A pixel size of an image. */
@Serializable
data class PixelSize(val width: Int, val height: Int) {
    val aspectRatio: Double get() = if (height == 0) 1.0 else width.toDouble() / height.toDouble()

    /** Scales down, keeping the aspect ratio, so the longest side is at most [maxPixelSize]. */
    fun fitting(maxPixelSize: Int): PixelSize {
        val longest = max(width, height)
        if (longest <= maxPixelSize || longest <= 0) return this
        val scale = maxPixelSize.toDouble() / longest.toDouble()
        return PixelSize(
            max(1, swiftRound(width * scale).toInt()),
            max(1, swiftRound(height * scale).toInt()),
        )
    }
}

/** Swift's `.rounded()`: half away from zero (Kotlin's `round` is half-even). */
fun swiftRound(v: Double): Double = if (v >= 0) kotlin.math.floor(v + 0.5) else -kotlin.math.floor(-v + 0.5)

internal fun swiftRoundToInt(v: Double): Int = swiftRound(v).roundToLong().toInt()
