package com.aurum.core

import kotlinx.serialization.Serializable

/**
 * The manual Adjust controls. Values are normalised to -1...1 with 0 neutral,
 * unless noted. Missing keys decode as neutral, as on iOS.
 */
@Serializable
data class AdjustmentSet(
    val exposure: Double = 0.0,
    val brightness: Double = 0.0,
    val contrast: Double = 0.0,
    val highlights: Double = 0.0,
    val shadows: Double = 0.0,
    val whites: Double = 0.0,
    val blacks: Double = 0.0,
    val saturation: Double = 0.0,
    val vibrance: Double = 0.0,
    val warmth: Double = 0.0,
    val tint: Double = 0.0,
    /** 0...1 */
    val sharpness: Double = 0.0,
    val clarity: Double = 0.0,
    val structure: Double = 0.0,
    /** 0...1 */
    val fade: Double = 0.0,
    /** 0...1 */
    val grain: Double = 0.0,
    /** -1...1, negative lightens the corners. */
    val vignette: Double = 0.0,
    val hsl: HSLAdjustments = HSLAdjustments(),
    val curves: ToneCurves = ToneCurves(),
    val splitToning: SplitToning = SplitToning(),
) {
    val isNeutral: Boolean get() = this == AdjustmentSet()

    operator fun get(control: AdjustmentControl): Double = when (control) {
        AdjustmentControl.exposure -> exposure
        AdjustmentControl.brightness -> brightness
        AdjustmentControl.contrast -> contrast
        AdjustmentControl.highlights -> highlights
        AdjustmentControl.shadows -> shadows
        AdjustmentControl.whites -> whites
        AdjustmentControl.blacks -> blacks
        AdjustmentControl.saturation -> saturation
        AdjustmentControl.vibrance -> vibrance
        AdjustmentControl.warmth -> warmth
        AdjustmentControl.tint -> tint
        AdjustmentControl.sharpness -> sharpness
        AdjustmentControl.clarity -> clarity
        AdjustmentControl.structure -> structure
        AdjustmentControl.fade -> fade
        AdjustmentControl.grain -> grain
        AdjustmentControl.vignette -> vignette
    }

    /** A copy with one control set, clamped to its range (NaN becomes the lower bound). */
    fun with(control: AdjustmentControl, value: Double): AdjustmentSet {
        val v = control.range.clamp(value)
        return when (control) {
            AdjustmentControl.exposure -> copy(exposure = v)
            AdjustmentControl.brightness -> copy(brightness = v)
            AdjustmentControl.contrast -> copy(contrast = v)
            AdjustmentControl.highlights -> copy(highlights = v)
            AdjustmentControl.shadows -> copy(shadows = v)
            AdjustmentControl.whites -> copy(whites = v)
            AdjustmentControl.blacks -> copy(blacks = v)
            AdjustmentControl.saturation -> copy(saturation = v)
            AdjustmentControl.vibrance -> copy(vibrance = v)
            AdjustmentControl.warmth -> copy(warmth = v)
            AdjustmentControl.tint -> copy(tint = v)
            AdjustmentControl.sharpness -> copy(sharpness = v)
            AdjustmentControl.clarity -> copy(clarity = v)
            AdjustmentControl.structure -> copy(structure = v)
            AdjustmentControl.fade -> copy(fade = v)
            AdjustmentControl.grain -> copy(grain = v)
            AdjustmentControl.vignette -> copy(vignette = v)
        }
    }
}

/** One slider in the Adjust sheet, in display order. */
@Serializable
enum class AdjustmentControl(val displayName: String) {
    exposure("Exposure"), brightness("Brightness"), contrast("Contrast"), highlights("Highlights"),
    shadows("Shadows"), whites("Whites"), blacks("Blacks"), saturation("Saturation"),
    vibrance("Vibrance"), warmth("Warmth"), tint("Tint"), sharpness("Sharpness"),
    clarity("Clarity"), structure("Structure"), fade("Fade"), grain("Grain"), vignette("Vignette");

    val range: ClosedFloatingPointRange<Double>
        get() = when (this) {
            sharpness, fade, grain -> 0.0..1.0
            else -> -1.0..1.0
        }

    val isBipolar: Boolean get() = range.start < 0
}

/** Per-colour hue, saturation and luminance shifts, each -1...1. */
@Serializable
data class HSLAdjustments(
    /** Keyed by band raw value so the JSON is a plain object. */
    val shifts: Map<String, Shift> = emptyMap(),
) {
    @Serializable
    enum class Band { red, orange, yellow, green, aqua, blue, purple, magenta }

    @Serializable
    data class Shift(val hue: Double = 0.0, val saturation: Double = 0.0, val luminance: Double = 0.0)

    operator fun get(band: Band): Shift = shifts[band.name] ?: Shift()

    fun with(band: Band, shift: Shift): HSLAdjustments {
        val next = shifts.toMutableMap()
        if (shift == Shift()) next.remove(band.name) else next[band.name] = shift
        return HSLAdjustments(next)
    }
}

/** A point on a tone curve, both coordinates 0...1. */
@Serializable
data class CurvePoint(val x: Double, val y: Double)

/** Tone curves; an empty list means identity. */
@Serializable
data class ToneCurves(
    val master: List<CurvePoint> = emptyList(),
    val red: List<CurvePoint> = emptyList(),
    val green: List<CurvePoint> = emptyList(),
    val blue: List<CurvePoint> = emptyList(),
) {
    val isIdentity: Boolean get() = master.isEmpty() && red.isEmpty() && green.isEmpty() && blue.isEmpty()
}

/** Colour pushed into shadows and highlights. */
@Serializable
data class SplitToning(
    /** Degrees 0..<360. */
    val shadowHue: Double = 0.0,
    /** 0...1 */
    val shadowSaturation: Double = 0.0,
    val highlightHue: Double = 0.0,
    val highlightSaturation: Double = 0.0,
    /** -1 favours shadows, 1 favours highlights. */
    val balance: Double = 0.0,
)
