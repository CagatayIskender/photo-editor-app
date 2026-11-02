package com.aurum.core

import kotlinx.serialization.Serializable

/**
 * Face-aware retouching settings. Kept so documents made on iOS round-trip
 * and the export gate treats them correctly; the Android renderer does not
 * draw retouching yet (see README).
 */
@Serializable
data class RetouchSettings(
    val global: FaceRetouch = FaceRetouch(),
    /** Per-face overrides keyed by face index in reading order. JSON keys are "0", "1"... */
    val perFace: Map<Int, FaceRetouch> = emptyMap(),
) {
    fun settings(forFace: Int): FaceRetouch = perFace[forFace] ?: global
    val isNeutral: Boolean get() = global.isNeutral && perFace.values.all { it.isNeutral }
}

@Serializable
data class FaceRetouch(
    val smoothing: Double = 0.0,
    val blemishRemoval: Double = 0.0,
    val underEye: Double = 0.0,
    val teethWhitening: Double = 0.0,
    val eyeBrightening: Double = 0.0,
    val jaw: Double = 0.0,
    val cheeks: Double = 0.0,
    val nose: Double = 0.0,
    val eyes: Double = 0.0,
    val lips: Double = 0.0,
    val forehead: Double = 0.0,
) {
    val isNeutral: Boolean get() = this == FaceRetouch()

    operator fun get(control: RetouchControl): Double = when (control) {
        RetouchControl.smoothing -> smoothing
        RetouchControl.blemishRemoval -> blemishRemoval
        RetouchControl.underEye -> underEye
        RetouchControl.teethWhitening -> teethWhitening
        RetouchControl.eyeBrightening -> eyeBrightening
        RetouchControl.jaw -> jaw
        RetouchControl.cheeks -> cheeks
        RetouchControl.nose -> nose
        RetouchControl.eyes -> eyes
        RetouchControl.lips -> lips
        RetouchControl.forehead -> forehead
    }

    fun with(control: RetouchControl, value: Double): FaceRetouch {
        val v = control.range.clamp(value)
        return when (control) {
            RetouchControl.smoothing -> copy(smoothing = v)
            RetouchControl.blemishRemoval -> copy(blemishRemoval = v)
            RetouchControl.underEye -> copy(underEye = v)
            RetouchControl.teethWhitening -> copy(teethWhitening = v)
            RetouchControl.eyeBrightening -> copy(eyeBrightening = v)
            RetouchControl.jaw -> copy(jaw = v)
            RetouchControl.cheeks -> copy(cheeks = v)
            RetouchControl.nose -> copy(nose = v)
            RetouchControl.eyes -> copy(eyes = v)
            RetouchControl.lips -> copy(lips = v)
            RetouchControl.forehead -> copy(forehead = v)
        }
    }

    companion object {
        /** The one-tap natural retouch. */
        val natural = FaceRetouch(smoothing = 0.35, blemishRemoval = 0.5, underEye = 0.3, teethWhitening = 0.2, eyeBrightening = 0.2)
    }
}

@Serializable
enum class RetouchControl {
    smoothing, blemishRemoval, underEye, teethWhitening, eyeBrightening, jaw, cheeks, nose, eyes, lips, forehead;

    val isReshape: Boolean get() = this in setOf(jaw, cheeks, nose, eyes, lips, forehead)
    val range: ClosedFloatingPointRange<Double> get() = if (isReshape) -1.0..1.0 else 0.0..1.0
}
