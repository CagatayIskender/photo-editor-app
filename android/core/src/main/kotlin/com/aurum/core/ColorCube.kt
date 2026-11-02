package com.aurum.core

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Bakes HSL shifts, tone curves and split toning into a 3D lookup table.
 * A line-for-line port of the iOS `ColorCube`.
 */
object ColorCube {
    /**
     * RGBA float data, red fastest then green then blue, or null when the
     * adjustments need no cube.
     */
    fun make(adjustments: AdjustmentSet, dimension: Int = 32): FloatArray? {
        val hsl = adjustments.hsl
        val curves = adjustments.curves
        val split = adjustments.splitToning
        val hasSplit = split.shadowSaturation > 0 || split.highlightSaturation > 0
        if (hsl.shifts.isEmpty() && curves.isIdentity && !hasSplit) return null

        val data = FloatArray(dimension * dimension * dimension * 4)
        var k = 0
        val maxIndex = (dimension - 1).toDouble()
        for (bi in 0 until dimension) for (gi in 0 until dimension) for (ri in 0 until dimension) {
            val out = transform(ri / maxIndex, gi / maxIndex, bi / maxIndex, adjustments) ?: doubleArrayOf(ri / maxIndex, gi / maxIndex, bi / maxIndex)
            data[k++] = out[0].toFloat()
            data[k++] = out[1].toFloat()
            data[k++] = out[2].toFloat()
            data[k++] = 1f
        }
        return data
    }

    /** The cube's colour transform for one colour, or null if it would be identity. */
    fun transform(r0: Double, g0: Double, b0: Double, adjustments: AdjustmentSet): DoubleArray? {
        val hsl = adjustments.hsl
        val curves = adjustments.curves
        val split = adjustments.splitToning
        val hasSplit = split.shadowSaturation > 0 || split.highlightSaturation > 0
        if (hsl.shifts.isEmpty() && curves.isIdentity && !hasSplit) return null
        var r = r0
        var g = g0
        var b = b0
        if (hsl.shifts.isNotEmpty()) {
            val o = applyHSL(r, g, b, hsl)
            r = o[0]; g = o[1]; b = o[2]
        }
        if (!curves.isIdentity) {
            val master = ToneCurveSampler(curves.master)
            r = ToneCurveSampler(curves.red).value(master.value(r))
            g = ToneCurveSampler(curves.green).value(master.value(g))
            b = ToneCurveSampler(curves.blue).value(master.value(b))
        }
        if (hasSplit) {
            val shadowRGB = rgb(split.shadowHue, 1.0, 0.5)
            val highlightRGB = rgb(split.highlightHue, 1.0, 0.5)
            val luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            val pivot = 0.5 + split.balance * 0.25
            val sw = max(0.0, 1 - luma / max(pivot, 0.01)) * split.shadowSaturation * 0.5
            val hw = max(0.0, (luma - pivot) / max(1 - pivot, 0.01)) * split.highlightSaturation * 0.5
            r += (shadowRGB[0] - 0.5) * sw + (highlightRGB[0] - 0.5) * hw
            g += (shadowRGB[1] - 0.5) * sw + (highlightRGB[1] - 0.5) * hw
            b += (shadowRGB[2] - 0.5) * sw + (highlightRGB[2] - 0.5) * hw
        }
        return doubleArrayOf(clamp01(r), clamp01(g), clamp01(b))
    }

    /** Centre hue (degrees) of each band. */
    private val bandCentres = listOf(
        HSLAdjustments.Band.red to 0.0, HSLAdjustments.Band.orange to 30.0, HSLAdjustments.Band.yellow to 60.0,
        HSLAdjustments.Band.green to 120.0, HSLAdjustments.Band.aqua to 180.0, HSLAdjustments.Band.blue to 225.0,
        HSLAdjustments.Band.purple to 270.0, HSLAdjustments.Band.magenta to 315.0,
    )

    /** 1 at the band centre, 0 at 45° away. */
    fun weight(hue: Double, centre: Double): Double {
        var d = abs(hue - centre).rem(360.0)
        if (d > 180) d = 360 - d
        return max(0.0, 1 - d / 45)
    }

    fun applyHSL(r: Double, g: Double, b: Double, hsl: HSLAdjustments): DoubleArray {
        val hslv = hslFrom(r, g, b)
        var h = hslv[0]
        var s = hslv[1]
        var l = hslv[2]
        if (s <= 0.0001) return doubleArrayOf(r, g, b)
        var dh = 0.0
        var ds = 0.0
        var dl = 0.0
        for ((band, centre) in bandCentres) {
            val w = weight(h, centre)
            if (w <= 0) continue
            val shift = hsl[band]
            dh += shift.hue * w * 30
            ds += shift.saturation * w
            dl += shift.luminance * w * 0.3
        }
        h = (h + dh).rem(360.0)
        if (h < 0) h += 360
        s = clamp01(s * (1 + ds))
        l = clamp01(l + dl * s)
        return rgb(h, s, l)
    }

    fun hslFrom(r: Double, g: Double, b: Double): DoubleArray {
        val maxV = max(r, max(g, b))
        val minV = min(r, min(g, b))
        val l = (maxV + minV) / 2
        val d = maxV - minV
        if (d <= 0) return doubleArrayOf(0.0, 0.0, l)
        val s = if (l > 0.5) d / (2 - maxV - minV) else d / (maxV + minV)
        var h = when (maxV) {
            r -> (g - b) / d + (if (g < b) 6 else 0)
            g -> (b - r) / d + 2
            else -> (r - g) / d + 4
        }
        h *= 60
        return doubleArrayOf(h, s, l)
    }

    fun rgb(hue: Double, s: Double, l: Double): DoubleArray {
        if (s <= 0) return doubleArrayOf(l, l, l)
        val q = if (l < 0.5) l * (1 + s) else l + s - l * s
        val p = 2 * l - q
        val h = hue / 360
        fun channel(t0: Double): Double {
            var t = t0
            if (t < 0) t += 1
            if (t > 1) t -= 1
            if (t < 1.0 / 6) return p + (q - p) * 6 * t
            if (t < 0.5) return q
            if (t < 2.0 / 3) return p + (q - p) * (2.0 / 3 - t) * 6
            return p
        }
        return doubleArrayOf(channel(h + 1.0 / 3), channel(h), channel(h - 1.0 / 3))
    }

    fun clamp01(v: Double) = min(max(v, 0.0), 1.0)
}

/** Monotone piecewise-linear tone curve with implicit (0,0) and (1,1) ends. */
class ToneCurveSampler(points: List<CurvePoint>) {
    val points: List<CurvePoint>

    init {
        val pts = points.map { CurvePoint(ColorCube.clamp01(it.x), ColorCube.clamp01(it.y)) }.toMutableList()
        if (pts.none { it.x == 0.0 }) pts.add(CurvePoint(0.0, 0.0))
        if (pts.none { it.x == 1.0 }) pts.add(CurvePoint(1.0, 1.0))
        this.points = pts.sortedBy { it.x }
    }

    fun value(x: Double): Double {
        if (points.size <= 2 && points.first().y == 0.0 && points.last().y == 1.0) return x
        val upper = points.indexOfFirst { it.x >= x }
        if (upper < 0) return points.last().y
        if (upper == 0) return points[0].y
        val a = points[upper - 1]
        val b = points[upper]
        val t = if (b.x == a.x) 0.0 else (x - a.x) / (b.x - a.x)
        return a.y + (b.y - a.y) * t
    }
}
