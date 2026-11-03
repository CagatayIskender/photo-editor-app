package com.aurum.core

import kotlinx.serialization.Serializable

/**
 * Face-aware retouching settings. Rendered by [com.aurum.core.render.RetouchRenderer]
 * with faces found on the device.
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

    /**
     * Every control multiplied by [amount] (0...1), for a strength slider
     * over a preset such as [natural].
     */
    fun scaled(amount: Double): FaceRetouch {
        val k = (0.0..1.0).clamp(amount)
        var r = this
        for (control in RetouchControl.entries) r = r.with(control, this[control] * k)
        return r
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

    val displayName: String
        get() = when (this) {
            smoothing -> "Smooth skin"
            blemishRemoval -> "Blemishes"
            underEye -> "Under-eye"
            teethWhitening -> "Teeth"
            eyeBrightening -> "Bright eyes"
            jaw -> "Jaw"
            cheeks -> "Cheeks"
            nose -> "Nose"
            eyes -> "Eyes"
            lips -> "Lips"
            forehead -> "Forehead"
        }
}

/**
 * A detected face in normalised image coordinates (origin top-left), as
 * produced by the on-device face detector. Kept in core so render code and
 * tests can work with faces without the detector.
 */
data class FaceGeometry(
    val bounds: NormalizedRect,
    val regions: Map<Region, List<NormalizedPoint>> = emptyMap(),
) {
    enum class Region { faceContour, leftEye, rightEye, leftEyebrow, rightEyebrow, nose, outerLips, innerLips }

    /** The centre of a region's points, or null if the detector didn't find it. */
    fun center(region: Region): NormalizedPoint? {
        val pts = regions[region]
        if (pts.isNullOrEmpty()) return null
        return NormalizedPoint(pts.sumOf { it.x } / pts.size, pts.sumOf { it.y } / pts.size)
    }

    companion object {
        /**
         * Sorts faces left to right, then top to bottom, so per-face settings
         * keep pointing at the same person between detections.
         */
        fun readingOrder(faces: List<FaceGeometry>): List<FaceGeometry> = faces.sortedWith { a, b ->
            val rowA = swiftRound(a.bounds.y / maxOf(a.bounds.height, 0.01))
            val rowB = swiftRound(b.bounds.y / maxOf(b.bounds.height, 0.01))
            if (rowA == rowB) a.bounds.x.compareTo(b.bounds.x) else rowA.compareTo(rowB)
        }
    }
}
