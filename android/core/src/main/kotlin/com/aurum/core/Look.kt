package com.aurum.core

import kotlinx.serialization.Serializable

/** Whether an item is free or needs membership to export. */
@Serializable
enum class Tier { free, member }

/**
 * The parameters a look recipe sets, in the same normalised ranges as
 * [AdjustmentSet]. Missing keys take their neutral default.
 */
@Serializable
data class LookParameters(
    val exposure: Double = 0.0,
    val contrast: Double = 0.0,
    val highlights: Double = 0.0,
    val shadows: Double = 0.0,
    val saturation: Double = 0.0,
    val vibrance: Double = 0.0,
    val warmth: Double = 0.0,
    val tint: Double = 0.0,
    /** 0...1, lifts the black point. */
    val fade: Double = 0.0,
    /** 0...1 */
    val grain: Double = 0.0,
    /** 0.5...2, relative grain size. */
    val grainSize: Double = 1.0,
    /** 0...1, darkens corners. */
    val vignette: Double = 0.0,
    /** 0...1, warm light leak. */
    val lightLeak: Double = 0.0,
    /** 0...1, highlight glow. */
    val bloom: Double = 0.0,
    /** Linear RGB multipliers mixed into shadows and highlights; [1, 1, 1] is neutral. */
    val shadowsTint: List<Double> = listOf(1.0, 1.0, 1.0),
    val highlightsTint: List<Double> = listOf(1.0, 1.0, 1.0),
    val monochrome: Boolean = false,
) {
    /** Applies the user's Refine overrides on top of the recipe. */
    fun applying(refine: RefineOverrides): LookParameters = copy(
        grain = refine.grain?.let { (0.0..1.0).clamp(it) } ?: grain,
        fade = refine.fade?.let { (0.0..1.0).clamp(it) } ?: fade,
        vignette = refine.vignette?.let { (0.0..1.0).clamp(it) } ?: vignette,
        lightLeak = refine.lightLeak?.let { (0.0..1.0).clamp(it) } ?: lightLeak,
        tint = refine.tint?.let { (-1.0..1.0).clamp(it) } ?: tint,
    )
}

/** Refine controls on an applied look. `null` keeps the recipe value. */
@Serializable
data class RefineOverrides(
    val grain: Double? = null,
    val fade: Double? = null,
    val vignette: Double? = null,
    val lightLeak: Double? = null,
    val tint: Double? = null,
) {
    val isEmpty: Boolean get() = this == RefineOverrides()
}

/** A look recipe from the catalogue. */
@Serializable
data class LookRecipe(
    val id: String,
    val name: String,
    val collection: String,
    val tier: Tier,
    val tags: List<String> = emptyList(),
    /** Optional `.cube` LUT resource name. No shipped look uses one yet. */
    val lut: String? = null,
    val params: LookParameters,
    /** Two hex colours for a placeholder thumbnail. */
    val swatch: List<String> = listOf("#888888", "#222222"),
)

/** A curated group of looks. */
@Serializable
data class LookCollection(val id: String, val name: String, val tagline: String)
