package com.aurum.core

import kotlinx.serialization.Serializable
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

// The rules behind AURUM's Auto Studio, ported from AurumCore/AutoStudio.swift.
// Every tool runs on the phone with bundled detection (faces, people) and
// classic pixel processing. Nothing is generated and nothing leaves the device.

/** A tool in the Auto Studio. */
@Serializable
enum class AutoFeature {
    /** Auto tone, white balance, straightening, red-eye fix, noise reduction and gentle sharpening. */
    enhance,
    /** Keeps the person sharp and blurs what is behind them. */
    portraitBlur,
    /** Keeps the person and puts a colour, gradient, blur or another photo behind them. */
    replaceBackground,
    /** A soft directional light on faces. */
    relight,
    /** The "Natural" skin retouch, placed by face detection. */
    retouch,
    /** Fills what the user brushed over from its surroundings. */
    removeObject,
    /** Curated portrait filters with a face-aware vignette and background blur. */
    portraitLooks;

    /**
     * Membership needed to keep the result. Retouch is a members' tool in the
     * Studio too; Portrait Looks has free and members' looks of its own.
     */
    val tier: Tier get() = if (this == retouch) Tier.member else Tier.free

    /** The user must brush over what to change. */
    val requiresMask: Boolean get() = this == removeObject

    /** The tool needs a person in the photo. */
    val requiresPerson: Boolean get() = this == portraitBlur || this == replaceBackground

    /** The tool needs at least one face. */
    val requiresFace: Boolean get() = this == retouch
}

/**
 * What the user brushed or outlined on the photo, in normalised coordinates
 * (origin top-left) of the photo.
 */
@Serializable
data class BrushMask(
    /** Closed outlines (lasso). Each needs at least three points. */
    val polygons: List<List<NormalizedPoint>> = emptyList(),
    val strokes: List<Stroke> = emptyList(),
) {
    /** A brush stroke. [radius] is a fraction of the photo's shorter side. */
    @Serializable
    data class Stroke(
        val points: List<NormalizedPoint>,
        val radius: Double = 0.03,
        /** Erases earlier strokes instead of painting. */
        val isEraser: Boolean = false,
    ) {
        companion object {
            fun of(points: List<NormalizedPoint>, radius: Double = 0.03, isEraser: Boolean = false) =
                Stroke(points, (0.001..0.5).clamp(radius), isEraser)
        }
    }

    /** True when nothing would be painted: no usable outline and no painting stroke. */
    val isEmpty: Boolean
        get() = polygons.none { it.size >= 3 } && strokes.none { !it.isEraser && it.points.isNotEmpty() }

    /** Every point lies inside the unit square. */
    val isInBounds: Boolean
        get() {
            fun inside(p: NormalizedPoint) = p.x in 0.0..1.0 && p.y in 0.0..1.0
            return polygons.all { it.all(::inside) } && strokes.all { it.points.all(::inside) }
        }

    /**
     * The normalised box around everything painted (erasers ignored), with
     * stroke radii measured on a photo of [aspect] (width / height). Null when
     * nothing is painted.
     */
    fun paintedBounds(aspect: Double): NormalizedRect? {
        if (isEmpty) return null
        val a = if (aspect > 0) aspect else 1.0
        var minX = 1.0
        var minY = 1.0
        var maxX = 0.0
        var maxY = 0.0
        fun include(x: Double, y: Double) {
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
        }
        for (polygon in polygons) if (polygon.size >= 3) for (p in polygon) include(p.x, p.y)
        for (stroke in strokes) {
            if (stroke.isEraser) continue
            val rx = if (a >= 1) stroke.radius / a else stroke.radius
            val ry = if (a >= 1) stroke.radius else stroke.radius * a
            for (p in stroke.points) {
                include(p.x - rx, p.y - ry)
                include(p.x + rx, p.y + ry)
            }
        }
        minX = max(0.0, minX); minY = max(0.0, minY); maxX = min(1.0, maxX); maxY = min(1.0, maxY)
        if (maxX <= minX || maxY <= minY) return null
        return NormalizedRect(minX, minY, maxX - minX, maxY - minY)
    }

    /**
     * The mask as a [width] × [height] grid of 0 or 1, row 0 at the top.
     * Outlines are filled first, then strokes are painted (or erased) in
     * order. [grow] widens every stroke by that many pixels.
     */
    fun coverage(width: Int, height: Int, grow: Double = 0.0): FloatArray =
        coverage(width, height, width.toDouble(), height.toDouble(), 0.0, 0.0, grow)

    /**
     * Part of the mask as a grid: the whole photo is [imageWidth] ×
     * [imageHeight] pixels and the grid's top-left pixel sits at
     * ([originX], [originY]) in it.
     */
    fun coverage(width: Int, height: Int, imageWidth: Double, imageHeight: Double, originX: Double, originY: Double, grow: Double = 0.0): FloatArray {
        if (width <= 0 || height <= 0 || imageWidth <= 0 || imageHeight <= 0) return FloatArray(0)
        val out = FloatArray(width * height)
        for (polygon in polygons) {
            if (polygon.size < 3) continue
            val xs = DoubleArray(polygon.size) { polygon[it].x * imageWidth - originX }
            val ys = DoubleArray(polygon.size) { polygon[it].y * imageHeight - originY }
            for (y in 0 until height) {
                val cy = y + 0.5
                for (x in 0 until width) {
                    if (contains(xs, ys, x + 0.5, cy)) out[y * width + x] = 1f
                }
            }
        }
        val shortSide = min(imageWidth, imageHeight)
        for (stroke in strokes) {
            if (stroke.points.isEmpty()) continue
            val r = stroke.radius * shortSide + grow
            val value = if (stroke.isEraser) 0f else 1f
            val px = DoubleArray(stroke.points.size) { stroke.points[it].x * imageWidth - originX }
            val py = DoubleArray(stroke.points.size) { stroke.points[it].y * imageHeight - originY }
            if (px.size == 1) {
                paintSegment(out, width, height, px[0], py[0], px[0], py[0], r, value)
            } else {
                for (i in 0 until px.size - 1) paintSegment(out, width, height, px[i], py[i], px[i + 1], py[i + 1], r, value)
            }
        }
        return out
    }

    companion object {
        internal fun paintSegment(out: FloatArray, width: Int, height: Int, ax: Double, ay: Double, bx: Double, by: Double, r: Double, value: Float) {
            val minX = max(0, floor(min(ax, bx) - r).toInt())
            val maxX = min(width - 1, ceil(max(ax, bx) + r).toInt())
            val minY = max(0, floor(min(ay, by) - r).toInt())
            val maxY = min(height - 1, ceil(max(ay, by) + r).toInt())
            if (minX > maxX || minY > maxY) return
            val dx = bx - ax
            val dy = by - ay
            val lengthSquared = dx * dx + dy * dy
            val rr = r * r
            for (y in minY..maxY) {
                val py = y + 0.5
                for (x in minX..maxX) {
                    val px = x + 0.5
                    var t = 0.0
                    if (lengthSquared > 0) t = (((px - ax) * dx + (py - ay) * dy) / lengthSquared).coerceIn(0.0, 1.0)
                    val qx = ax + t * dx - px
                    val qy = ay + t * dy - py
                    if (qx * qx + qy * qy <= rr) out[y * width + x] = value
                }
            }
        }

        /** Even-odd point-in-polygon test. */
        internal fun contains(xs: DoubleArray, ys: DoubleArray, x: Double, y: Double): Boolean {
            var inside = false
            var j = xs.size - 1
            for (i in xs.indices) {
                if ((ys[i] > y) != (ys[j] > y)) {
                    val t = (y - ys[i]) / (ys[j] - ys[i])
                    val crossX = xs[i] + t * (xs[j] - xs[i])
                    if (x < crossX) inside = !inside
                }
                j = i
            }
            return inside
        }
    }
}

// MARK: - Straighten

/**
 * Levelling a tilted photo: rotate, then scale up just enough that the
 * rotated photo still covers the whole frame (no empty corners).
 */
object Straighten {
    /** Tilts smaller than this are left alone; larger ones are probably intentional. */
    const val minimumDegrees = 0.4
    const val maximumDegrees = 15.0

    fun isWorthCorrecting(degrees: Double): Boolean {
        val a = abs(degrees)
        return a >= minimumDegrees && a <= maximumDegrees
    }

    /** The scale that makes a [width] × [height] image, rotated by [radians] about its centre, cover the original frame. */
    fun coverScale(width: Double, height: Double, radians: Double): Double {
        if (width <= 0 || height <= 0) return 1.0
        val c = abs(cos(radians))
        val s = abs(sin(radians))
        val a = c + s * height / width
        val b = c + s * width / height
        return max(1.0, max(a, b))
    }
}

// MARK: - Portrait Looks

/**
 * A curated portrait filter: colour from [params] (same meaning as a
 * catalogue look), a soft vignette centred on the faces and an optional
 * background blur behind the person.
 */
@Serializable
data class PortraitLook(
    val id: String,
    val name: String,
    val tier: Tier,
    val params: LookParameters,
    /** 0...1, darkens away from the faces. */
    val faceVignette: Double = 0.0,
    /** 0...1, blurs what is behind the person. */
    val backgroundBlur: Double = 0.0,
) {
    companion object {
        fun of(id: String, name: String, tier: Tier, params: LookParameters, faceVignette: Double = 0.0, backgroundBlur: Double = 0.0) =
            PortraitLook(id, name, tier, params, (0.0..1.0).clamp(faceVignette), (0.0..1.0).clamp(backgroundBlur))

        val library: List<PortraitLook> = listOf(
            of("portrait.soft-studio", "Soft Studio", Tier.free,
                LookParameters(exposure = 0.05, contrast = -0.08, highlights = -0.2, shadows = 0.15, warmth = 0.06, vibrance = 0.08),
                faceVignette = 0.25, backgroundBlur = 0.25),
            of("portrait.window-light", "Window Light", Tier.free,
                LookParameters(exposure = 0.08, contrast = 0.1, shadows = 0.1, warmth = -0.04, saturation = -0.08, fade = 0.08),
                faceVignette = 0.45, backgroundBlur = 0.0),
            of("portrait.editorial", "Editorial", Tier.member,
                LookParameters(contrast = 0.22, highlights = -0.25, shadows = -0.05, saturation = -0.15, warmth = 0.04, shadowsTint = listOf(0.97, 1.0, 1.04)),
                faceVignette = 0.5, backgroundBlur = 0.35),
            of("portrait.silver", "Silver", Tier.member,
                LookParameters(contrast = 0.25, highlights = -0.15, shadows = 0.1, monochrome = true, grain = 0.15),
                faceVignette = 0.55, backgroundBlur = 0.2),
            of("portrait.golden", "Golden", Tier.member,
                LookParameters(exposure = 0.05, warmth = 0.25, vibrance = 0.12, bloom = 0.2, highlightsTint = listOf(1.04, 1.0, 0.94)),
                faceVignette = 0.35, backgroundBlur = 0.45),
            of("portrait.matte-film", "Matte Film", Tier.member,
                LookParameters(contrast = -0.05, saturation = -0.1, fade = 0.3, grain = 0.25, warmth = 0.08),
                faceVignette = 0.3, backgroundBlur = 0.15),
        )

        fun look(id: String): PortraitLook? = library.firstOrNull { it.id == id }
    }
}

// MARK: - Auto-detect

/** One scene label. */
@Serializable
data class SceneLabel(val identifier: String, /** 0...1 */ val confidence: Double)

/**
 * What the on-device analysis found in a photo. Filled by the app from the
 * detectors and pixel statistics; kept here so the ranking can be tested.
 */
data class SceneAnalysis(
    val faces: List<FaceGeometry> = emptyList(),
    /** Average luminance (0...1) inside the face boxes, null without faces. */
    val faceLuminance: Double? = null,
    /** Average luminance of the whole photo, 0...1. */
    val luminance: Double = 0.5,
    /** Average red minus blue, about -1...1; positive is warm. */
    val warmth: Double = 0.0,
    /** Share of the frame covered by people, 0...1. */
    val personCoverage: Double = 0.0,
    /** The horizon's tilt in degrees, counter-clockwise positive, null when none was found. */
    val horizonDegrees: Double? = null,
    /** Red eyes worth correcting were found. */
    val redEyeLikely: Boolean = false,
    /** Top scene labels, most confident first. */
    val labels: List<SceneLabel> = emptyList(),
) {
    /** True when any label (case-insensitive) is in [identifiers] with at least [minimumConfidence]. */
    fun hasLabel(identifiers: Set<String>, minimumConfidence: Double = 0.2): Boolean =
        labels.any { it.confidence >= minimumConfidence && it.identifier.lowercase() in identifiers }

    /** The largest face's share of the frame, 0 without faces. */
    val largestFaceArea: Double get() = faces.maxOfOrNull { it.bounds.width * it.bounds.height } ?: 0.0
}

/** A one-tap fix offered after a photo is analysed. */
data class AutoSuggestion(
    val kind: Kind,
    /** Higher is more useful for this photo, 0...1. */
    val score: Double,
    /** For [Kind.straighten]: the tilt to remove, in degrees. */
    val degrees: Double? = null,
) {
    enum class Kind { fixRedEye, straighten, brightenFaces, blurBackground, balanceColour, smoothSkin, enhance }

    val id: String get() = kind.name

    /** The tool that carries the fix out. */
    val feature: AutoFeature
        get() = when (kind) {
            Kind.fixRedEye, Kind.straighten, Kind.balanceColour, Kind.enhance -> AutoFeature.enhance
            Kind.brightenFaces -> AutoFeature.relight
            Kind.blurBackground -> AutoFeature.portraitBlur
            Kind.smoothSkin -> AutoFeature.retouch
        }
}

object AutoSuggestions {
    /** Scene labels that suggest a horizon worth levelling. */
    val horizonLabels: Set<String> = setOf(
        "sky", "sea", "ocean", "beach", "lake", "water", "water_body", "shore", "mountain",
        "landscape", "outdoor", "field", "sunset_sunrise", "horizon", "desert", "snow", "grass",
    )

    /** Labels that suggest a portrait. */
    val portraitLabels: Set<String> = setOf(
        "people", "person", "portrait", "adult", "child", "baby", "selfie", "people_group", "wedding",
    )

    /** Fixes worth offering for this photo, most useful first, at most [limit]. Never empty. */
    fun rank(analysis: SceneAnalysis, limit: Int = 4): List<AutoSuggestion> {
        val out = mutableListOf<AutoSuggestion>()

        if (analysis.redEyeLikely && analysis.faces.isNotEmpty()) {
            out.add(AutoSuggestion(AutoSuggestion.Kind.fixRedEye, 0.95))
        }

        val tilt = analysis.horizonDegrees
        if (tilt != null && Straighten.isWorthCorrecting(tilt)) {
            var score = 0.6 + min(abs(tilt), 5.0) / 5 * 0.25
            if (analysis.hasLabel(horizonLabels)) score += 0.1
            out.add(AutoSuggestion(AutoSuggestion.Kind.straighten, min(score, 0.94), tilt))
        }

        val faceLum = analysis.faceLuminance
        if (faceLum != null && analysis.faces.isNotEmpty() && faceLum < 0.42) {
            val score = 0.55 + (0.42 - faceLum) * 1.2
            out.add(AutoSuggestion(AutoSuggestion.Kind.brightenFaces, min(score, 0.9)))
        }

        val coverage = analysis.personCoverage
        if (coverage >= 0.06 && coverage <= 0.75) {
            var score = 0.5
            if (analysis.hasLabel(portraitLabels) || analysis.faces.isNotEmpty()) score += 0.15
            // Mid-sized subjects benefit most; a person filling the frame leaves little to blur.
            if (coverage >= 0.12 && coverage <= 0.55) score += 0.1
            out.add(AutoSuggestion(AutoSuggestion.Kind.blurBackground, score))
        }

        val cast = abs(analysis.warmth)
        if (cast > 0.12) {
            out.add(AutoSuggestion(AutoSuggestion.Kind.balanceColour, 0.4 + min(cast - 0.12, 0.3)))
        }

        if (analysis.largestFaceArea >= 0.03) {
            out.add(AutoSuggestion(AutoSuggestion.Kind.smoothSkin, 0.45))
        }

        val lum = analysis.luminance
        val needsTone = lum < 0.32 || lum > 0.78
        out.add(AutoSuggestion(AutoSuggestion.Kind.enhance, if (needsTone) 0.7 else 0.3))

        out.sortWith { a, b ->
            if (a.score != b.score) b.score.compareTo(a.score) else a.kind.ordinal.compareTo(b.kind.ordinal)
        }
        return out.take(max(1, limit))
    }
}
