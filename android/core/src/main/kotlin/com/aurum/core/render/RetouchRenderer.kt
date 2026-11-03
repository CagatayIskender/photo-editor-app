package com.aurum.core.render

import com.aurum.core.FaceGeometry
import com.aurum.core.FaceRetouch
import com.aurum.core.NormalizedPoint
import com.aurum.core.ObjectRemover
import com.aurum.core.RetouchSettings
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Face-aware retouching on packed ARGB pixels, ported from
 * AurumRender/RetouchRenderer.swift (a Core Image recipe there).
 *
 * Every adjustment is confined to a soft mask derived from the detected face
 * geometry, so nothing outside a face changes. Work happens in a region
 * around each face (the face box grown by half its size), so the cost
 * follows the face size, not the photo size.
 *
 * Geometry arrives normalised with a top-left origin, so faces found on a
 * screen-size proxy apply unchanged to the full-resolution export. Pixel
 * coordinates here are top-left too ("up" is negative y).
 */
object RetouchRenderer {

    /** Applies the settings to every face, in place. No faces or neutral settings change nothing. */
    fun apply(settings: RetouchSettings, faces: List<FaceGeometry>, img: ArgbImage) {
        if (faces.isEmpty() || settings.isNeutral || img.width < 2 || img.height < 2) return
        for ((index, face) in faces.withIndex()) {
            val retouch = settings.settings(index)
            if (retouch.isNeutral) continue
            applyFace(retouch, face, img)
        }
    }

    private fun applyFace(r: FaceRetouch, face: FaceGeometry, img: ArgbImage) {
        val b = face.bounds
        val fw = b.width * img.width
        val fh = b.height * img.height
        if (fw < 2 || fh < 2) return
        val margin = 0.5 * max(fw, fh)
        val x0 = (b.x * img.width - margin).toInt().coerceIn(0, img.width - 1)
        val y0 = (b.y * img.height - margin).toInt().coerceIn(0, img.height - 1)
        val x1 = kotlin.math.ceil(b.x * img.width + fw + margin).toInt().coerceIn(x0 + 1, img.width)
        val y1 = kotlin.math.ceil(b.y * img.height + fh + margin).toInt().coerceIn(y0 + 1, img.height)
        val rw = x1 - x0
        val rh = y1 - y0
        if (rw < 2 || rh < 2) return

        val roi = IntArray(rw * rh)
        for (y in 0 until rh) System.arraycopy(img.px, (y0 + y) * img.width + x0, roi, y * rw, rw)
        val region = Region(roi, rw, rh)
        val f = FaceFrame(face, img.width, img.height, x0.toDouble(), y0.toDouble())
        val imageScale = max(img.width, img.height) / 1080.0

        // Tone first, while the masks still match the geometry; reshape last.
        skinAndFeatures(r, f, region, imageScale)
        reshape(r, f, region)

        for (y in 0 until rh) System.arraycopy(region.px, y * rw, img.px, (y0 + y) * img.width + x0, rw)
    }

    /** A rectangle of pixels being retouched. */
    private class Region(var px: IntArray, val w: Int, val h: Int) {
        val size get() = w * h
    }

    // MARK: Skin and features

    private fun skinAndFeatures(r: FaceRetouch, f: FaceFrame, region: Region, imageScale: Double) {
        val needsSkin = r.smoothing > 0 || r.blemishRemoval > 0
        val skin = if (needsSkin) skinMask(f, region) else null
        if (r.blemishRemoval > 0 && skin != null) removeBlemishes(region, skin, r.blemishRemoval)
        if (r.smoothing > 0 && skin != null) smooth(region, skin, r.smoothing, f, imageScale)
        if (r.underEye > 0) brightenUnderEyes(region, r.underEye, f)
        if (r.teethWhitening > 0) whitenTeeth(region, r.teethWhitening, f)
        if (r.eyeBrightening > 0) brightenEyes(region, r.eyeBrightening, f)
    }

    /** The face oval, slightly inset, minus the eyes, eyebrows and lips. */
    private fun skinMask(f: FaceFrame, region: Region): FloatArray {
        // The face box runs from about the brows to the chin, so the oval is nudged up to take in some forehead.
        val c = f.offset(f.midX, f.midY, f.height * 0.06)
        val mask = FloatArray(region.size)
        ellipse(mask, region.w, region.h, c[0], c[1], f.width * 0.46, f.height * 0.56, f.roll, 0.45, Combine.replace)
        val holes = listOf(
            FaceGeometry.Region.leftEye to 1.7, FaceGeometry.Region.rightEye to 1.7,
            FaceGeometry.Region.leftEyebrow to 1.3, FaceGeometry.Region.rightEyebrow to 1.3,
            FaceGeometry.Region.outerLips to 1.25,
        )
        for ((reg, grow) in holes) regionEllipse(mask, region, reg, f, grow, 0.6, Combine.subtract)
        return mask
    }

    /** Texture-preserving smoothing: a blur through the skin mask, then a little of the fine detail added back. */
    private fun smooth(region: Region, skin: FloatArray, strength: Double, f: FaceFrame, imageScale: Double) {
        val sigma = max(0.5, f.width * 0.024 * strength)
        val planes = Planes.of(region.px, region.size)
        val blurred = planes.blurred(region.w, region.h, sigma)
        val fine = planes.blurred(region.w, region.h, max(1.0, 1.5 * imageScale))
        val k = (0.75 * strength).toFloat()
        for (i in 0 until region.size) {
            val m = skin[i] * k
            if (m <= 0f) continue
            val p = region.px[i]
            var out = p and -0x1000000
            for (ch in 0 until 3) {
                val o = planes.c[ch][i]
                val smoothed = o + (blurred.c[ch][i] - o) * m
                val textured = smoothed + 0.35f * (o - fine.c[ch][i])
                val v = smoothed + (textured - smoothed) * m
                out = out or (ArgbImage.q(v) shl (16 - 8 * ch))
            }
            region.px[i] = out
        }
    }

    /** A double 3×3 median removes small spots without moving edges. */
    private fun removeBlemishes(region: Region, skin: FloatArray, strength: Double) {
        val cleaned = median3(median3(region.px, region.w, region.h), region.w, region.h)
        mixInto(region.px, cleaned, skin, (0.6 * strength).toFloat())
    }

    private fun brightenUnderEyes(region: Region, strength: Double, f: FaceFrame) {
        val mask = FloatArray(region.size)
        var any = false
        for (eye in listOf(FaceGeometry.Region.leftEye, FaceGeometry.Region.rightEye)) {
            val box = f.box(eye) ?: continue
            val eyeHeight = max(box[3], box[2] * 0.35)
            // Centred about 0.6 eye-heights below the lower lid.
            val c = f.offset(box[0] + box[2] / 2, box[1] + box[3] / 2, -eyeHeight * 1.1)
            ellipse(mask, region.w, region.h, c[0], c[1], box[2] * 0.55, eyeHeight * 0.5, f.roll, 0.7, Combine.max)
            any = true
        }
        if (!any) return
        val lut = Lut3D.build { r, g, b ->
            ColorOps.colorControls(ColorOps.exposure(doubleArrayOf(r, g, b), 0.35 * strength), 0.0, 0.0, -0.15 * strength)
        }
        adjustThrough(region, lut, mask)
    }

    private fun whitenTeeth(region: Region, strength: Double, f: FaceFrame) {
        val mask = FloatArray(region.size)
        if (!regionEllipse(mask, region, FaceGeometry.Region.innerLips, f, 1.0, 0.5, Combine.max, minimumAspect = 0.15)) return
        val lut = Lut3D.build { r, g, b ->
            ColorOps.exposure(ColorOps.colorControls(doubleArrayOf(r, g, b), 0.0, 0.0, -0.6 * strength), 0.25 * strength)
        }
        adjustThrough(region, lut, mask)
    }

    private fun brightenEyes(region: Region, strength: Double, f: FaceFrame) {
        val mask = FloatArray(region.size)
        var any = false
        for (eye in listOf(FaceGeometry.Region.leftEye, FaceGeometry.Region.rightEye)) {
            if (regionEllipse(mask, region, eye, f, 1.1, 0.5, Combine.max)) any = true
        }
        if (!any) return
        val lut = Lut3D.build { r, g, b ->
            ColorOps.vibrance(ColorOps.exposure(doubleArrayOf(r, g, b), 0.3 * strength), 0.3 * strength)
        }
        adjustThrough(region, lut, mask)
    }

    /** Applies [lut] where [mask] is white. */
    private fun adjustThrough(region: Region, lut: Lut3D, mask: FloatArray) {
        val adjusted = region.px.copyOf()
        lut.apply(adjusted, region.size)
        mixInto(region.px, adjusted, mask, 1f)
    }

    // MARK: Reshape

    /** Gentle local warps: negative values pinch (slim or shrink), positive values bulge (enlarge). */
    private fun reshape(r: FaceRetouch, f: FaceFrame, region: Region) {
        val w = f.width
        if (r.jaw != 0.0) {
            for (p in jawPoints(f)) {
                val cx = p[0] + (f.midX - p[0]) * 0.25
                val cy = p[1] + (f.midY - p[1]) * 0.25
                bump(region, cx, cy, w * 0.28, r.jaw)
            }
        }
        if (r.cheeks != 0.0) for (c in cheekPoints(f)) bump(region, c[0], c[1], w * 0.2, r.cheeks)
        if (r.nose != 0.0) {
            val box = f.box(FaceGeometry.Region.nose)
            if (box != null) {
                bump(region, box[0] + box[2] / 2, box[1] + box[3] / 2, max(max(box[2], box[3]) * 0.7, w * 0.1), r.nose)
            } else {
                bump(region, f.midX, f.top + f.height * 0.55, w * 0.16, r.nose)
            }
        }
        if (r.eyes != 0.0) {
            for (eye in listOf(FaceGeometry.Region.leftEye, FaceGeometry.Region.rightEye)) {
                val box = f.box(eye) ?: continue
                bump(region, box[0] + box[2] / 2, box[1] + box[3] / 2, max(box[2] * 0.9, w * 0.1), r.eyes)
            }
        }
        if (r.lips != 0.0) {
            val box = f.box(FaceGeometry.Region.outerLips)
            if (box != null) {
                bump(region, box[0] + box[2] / 2, box[1] + box[3] / 2, max(box[2] * 0.65, w * 0.1), r.lips)
            } else {
                bump(region, f.midX, f.top + f.height * 0.78, w * 0.2, r.lips)
            }
        }
        if (r.forehead != 0.0) {
            val brows = listOfNotNull(f.box(FaceGeometry.Region.leftEyebrow), f.box(FaceGeometry.Region.rightEyebrow))
            val bx: Double
            val by: Double
            if (brows.isEmpty()) {
                bx = f.midX
                by = f.top + f.height * 0.05
            } else {
                bx = brows.sumOf { it[0] + it[2] / 2 } / brows.size
                by = brows.sumOf { it[1] + it[3] / 2 } / brows.size
            }
            val c = f.offset(bx, by, f.height * 0.15)
            bump(region, c[0], c[1], w * 0.3, r.forehead)
        }
    }

    /** Two points on the lower face contour, about a fifth of the way in from each end (the contour runs ear to ear around the chin). */
    private fun jawPoints(f: FaceFrame): List<DoubleArray> {
        val contour = f.points(FaceGeometry.Region.faceContour)
        if (contour != null && contour.size >= 5) {
            val last = contour.size - 1
            val i = com.aurum.core.swiftRound(last * 0.2).toInt()
            val j = com.aurum.core.swiftRound(last * 0.8).toInt()
            return listOf(contour[i], contour[j])
        }
        val y = f.top + f.height * 0.75
        return listOf(doubleArrayOf(f.left + f.width * 0.18, y), doubleArrayOf(f.left + f.width * 0.82, y))
    }

    /** Midpoints between each eye and the mouth corner on the same side. */
    private fun cheekPoints(f: FaceFrame): List<DoubleArray> {
        val eyes = listOfNotNull(f.center(FaceGeometry.Region.leftEye), f.center(FaceGeometry.Region.rightEye)).sortedBy { it[0] }
        val lips = f.points(FaceGeometry.Region.outerLips).orEmpty()
        val leftCorner = lips.minByOrNull { it[0] }
        val rightCorner = lips.maxByOrNull { it[0] }
        if (eyes.size == 2 && leftCorner != null && rightCorner != null) {
            return listOf(
                doubleArrayOf((eyes[0][0] + leftCorner[0]) / 2, (eyes[0][1] + leftCorner[1]) / 2),
                doubleArrayOf((eyes[1][0] + rightCorner[0]) / 2, (eyes[1][1] + rightCorner[1]) / 2),
            )
        }
        val y = f.top + f.height * 0.58
        return listOf(doubleArrayOf(f.left + f.width * 0.25, y), doubleArrayOf(f.left + f.width * 0.75, y))
    }

    /** CIBumpDistortion: inside [radius], samples move towards (bulge) or away from (pinch) the centre. */
    private fun bump(region: Region, cx: Double, cy: Double, radius: Double, amount: Double) {
        if (amount == 0.0 || radius <= 1) return
        val scale = max(-1.0, min(amount, 1.0)) * 0.25
        val src = region.px
        val out = src.copyOf()
        val minX = max(0, (cx - radius).toInt())
        val maxX = min(region.w - 1, kotlin.math.ceil(cx + radius).toInt())
        val minY = max(0, (cy - radius).toInt())
        val maxY = min(region.h - 1, kotlin.math.ceil(cy + radius).toInt())
        if (minX > maxX || minY > maxY) return
        for (y in minY..maxY) {
            val dy = y + 0.5 - cy
            for (x in minX..maxX) {
                val dx = x + 0.5 - cx
                val d = sqrt(dx * dx + dy * dy)
                if (d >= radius) continue
                var percent = 1 - ((radius - d) / radius) * scale
                percent *= percent
                out[y * region.w + x] = ObjectRemover.bilinear(src, region.w, region.h, cx + dx * percent - 0.5, cy + dy * percent - 0.5)
            }
        }
        region.px = out
    }

    // MARK: Masks

    internal enum class Combine { replace, max, subtract }

    /**
     * A soft elliptical mask written into [mask]: 1 in the centre fading to 0
     * at the edge. [softness] is the fraction of the radius that fades.
     */
    internal fun ellipse(mask: FloatArray, w: Int, h: Int, cx: Double, cy: Double, radiusX: Double, radiusY: Double, angle: Double, softness: Double, combine: Combine) {
        val rx = max(radiusX, 0.5)
        val ry = max(radiusY, 0.5)
        val r0 = 1 - softness.coerceIn(0.0, 1.0)
        val reach = max(rx, ry)
        val minX = max(0, (cx - reach).toInt())
        val maxX = min(w - 1, kotlin.math.ceil(cx + reach).toInt())
        val minY = max(0, (cy - reach).toInt())
        val maxY = min(h - 1, kotlin.math.ceil(cy + reach).toInt())
        val ca = cos(angle)
        val sa = sin(angle)
        if (combine == Combine.replace) mask.fill(0f)
        if (minX > maxX || minY > maxY) return
        for (y in minY..maxY) {
            val dy = y + 0.5 - cy
            for (x in minX..maxX) {
                val dx = x + 0.5 - cx
                val u = (dx * ca + dy * sa) / rx
                val v = (-dx * sa + dy * ca) / ry
                val d = sqrt(u * u + v * v)
                val value = when {
                    d <= r0 -> 1f
                    d >= 1 -> 0f
                    else -> (1 - (d - r0) / (1 - r0)).toFloat()
                }
                if (value <= 0f) continue
                val i = y * w + x
                mask[i] = when (combine) {
                    Combine.replace -> value
                    Combine.max -> max(mask[i], value)
                    Combine.subtract -> mask[i] * (1 - value)
                }
            }
        }
    }

    /** An ellipse around a landmark region's points, grown by [grow]. False when the region wasn't found. */
    private fun regionEllipse(
        mask: FloatArray, region: Region, reg: FaceGeometry.Region, f: FaceFrame,
        grow: Double, softness: Double, combine: Combine, minimumAspect: Double = 0.45,
    ): Boolean {
        val box = f.box(reg) ?: return false
        val minimum = f.width * 0.02
        val rx = max(box[2] / 2 * grow, minimum)
        val ry = maxOf(box[3] / 2 * grow, rx * minimumAspect, minimum * 0.5)
        ellipse(mask, region.w, region.h, box[0] + box[2] / 2, box[1] + box[3] / 2, rx, ry, f.roll, softness, combine)
        return true
    }

    // MARK: Building blocks

    /** dst = dst + (src - dst) * mask * k, per RGB channel. */
    private fun mixInto(dst: IntArray, src: IntArray, mask: FloatArray, k: Float) {
        for (i in dst.indices) {
            val m = mask[i] * k
            if (m <= 0f) continue
            dst[i] = ObjectRemover.mix(dst[i], src[i], min(m, 1f))
        }
    }

    /** Per-channel 3×3 median, edges clamped. */
    internal fun median3(px: IntArray, w: Int, h: Int): IntArray {
        val out = IntArray(px.size)
        val r = IntArray(9)
        val g = IntArray(9)
        val b = IntArray(9)
        for (y in 0 until h) for (x in 0 until w) {
            var k = 0
            for (dy in -1..1) {
                val sy = (y + dy).coerceIn(0, h - 1)
                for (dx in -1..1) {
                    val p = px[sy * w + (x + dx).coerceIn(0, w - 1)]
                    r[k] = (p shr 16) and 0xff
                    g[k] = (p shr 8) and 0xff
                    b[k] = p and 0xff
                    k++
                }
            }
            r.sort(); g.sort(); b.sort()
            out[y * w + x] = (px[y * w + x] and -0x1000000) or (r[4] shl 16) or (g[4] shl 8) or b[4]
        }
        return out
    }
}

/** Three float planes (r, g, b, 0...1) of packed ARGB pixels. */
internal class Planes(val c: Array<FloatArray>) {
    fun blurred(w: Int, h: Int, sigma: Double): Planes = Planes(Array(3) { Blur.gaussian(c[it], w, h, sigma) })

    companion object {
        fun of(px: IntArray, n: Int): Planes {
            val r = FloatArray(n)
            val g = FloatArray(n)
            val b = FloatArray(n)
            for (i in 0 until n) {
                val p = px[i]
                r[i] = ((p shr 16) and 0xff) / 255f
                g[i] = ((p shr 8) and 0xff) / 255f
                b[i] = (p and 0xff) / 255f
            }
            return Planes(arrayOf(r, g, b))
        }
    }
}

/**
 * A face mapped into a pixel region (top-left origin). [originX], [originY]
 * are the region's top-left corner in the image.
 */
internal class FaceFrame(val face: FaceGeometry, private val imageWidth: Int, private val imageHeight: Int, private val originX: Double, private val originY: Double) {
    val left = face.bounds.x * imageWidth - originX
    val top = face.bounds.y * imageHeight - originY
    val width = face.bounds.width * imageWidth
    val height = face.bounds.height * imageHeight
    val midX get() = left + width / 2
    val midY get() = top + height / 2

    /** The head's roll from the eye line, in radians (clockwise on screen, since y points down). */
    val roll: Double = run {
        val l = face.center(FaceGeometry.Region.leftEye)
        val r = face.center(FaceGeometry.Region.rightEye)
        if (l == null || r == null) return@run 0.0
        val a = map(l)
        val b = map(r)
        val (lp, rp) = if (a[0] <= b[0]) a to b else b to a
        val angle = atan2(rp[1] - lp[1], rp[0] - lp[0])
        // Ignore implausible values from a bad detection.
        if (abs(angle) < Math.PI / 4) angle else 0.0
    }

    fun map(p: NormalizedPoint) = doubleArrayOf(p.x * imageWidth - originX, p.y * imageHeight - originY)

    fun points(region: FaceGeometry.Region): List<DoubleArray>? {
        val pts = face.regions[region]
        if (pts.isNullOrEmpty()) return null
        return pts.map(::map)
    }

    fun center(region: FaceGeometry.Region): DoubleArray? = face.center(region)?.let(::map)

    /** The bounding box of a region's points: [x, y, width, height] in pixels. */
    fun box(region: FaceGeometry.Region): DoubleArray? {
        val pts = points(region) ?: return null
        val minX = pts.minOf { it[0] }
        val maxX = pts.maxOf { it[0] }
        val minY = pts.minOf { it[1] }
        val maxY = pts.maxOf { it[1] }
        return doubleArrayOf(minX, minY, maxX - minX, maxY - minY)
    }

    /** Moves a point along the face's up axis (negative moves down), following the roll. */
    fun offset(x: Double, y: Double, up: Double) = doubleArrayOf(x + sin(roll) * up, y - cos(roll) * up)
}
