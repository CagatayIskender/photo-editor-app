package com.aurum.core

/** Simple statistics about a photo, measured on device. */
data class ImageStats(
    /** Average luminance, 0...1. */
    val luminance: Double,
    /** Average saturation, 0...1. */
    val saturation: Double,
    /** Red minus blue of the average colour, -1...1. Positive is warm. */
    val warmth: Double,
)

/**
 * Picks the look shown when a photo first opens: the user's aesthetics first,
 * then the photo's mood. Only free looks, so a first export never hits the paywall.
 */
object LookSuggestion {
    fun suggest(stats: ImageStats, vibes: List<String>, catalog: LookCatalog): LookRecipe? {
        val free = catalog.looks.filter { it.tier == Tier.free }
        if (free.isEmpty()) return null
        val mood = when {
            stats.saturation < 0.08 -> "noir"
            stats.luminance < 0.3 -> "nocturne"
            stats.luminance > 0.7 -> "haze"
            stats.warmth > 0.08 -> "film-analog"
            stats.saturation > 0.45 -> "riviera"
            else -> "cinematic"
        }
        val preferred = when {
            mood == "noir" -> listOf("noir")
            mood in vibes -> listOf(mood)
            else -> vibes + mood
        }
        for (collection in preferred) free.firstOrNull { it.collection == collection }?.let { return it }
        return free.first()
    }
}
