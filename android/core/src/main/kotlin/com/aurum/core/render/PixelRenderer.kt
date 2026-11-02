package com.aurum.core.render

import com.aurum.core.AdjustmentSet
import com.aurum.core.ColorCube
import com.aurum.core.CropSpec
import com.aurum.core.EditDocument
import com.aurum.core.ImageStats
import com.aurum.core.LookApplication
import com.aurum.core.LookCatalog
import com.aurum.core.LookParameters
import com.aurum.core.NormalizedRect
import com.aurum.core.OperationKind
import java.util.UUID
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Renders the looks and adjustments of an [EditDocument] on packed ARGB
 * pixels (the layout of Android's `Bitmap.getPixels`), in place.
 *
 * It mirrors the iOS Core Image graph step by step: every colour-only step of
 * an operation is baked into one 33³ lookup table, then the spatial steps
 * (bloom, light leak, vignette, grain, clarity, sharpening) run per pixel.
 * Pure Kotlin, so the same code renders the Studio preview, the export and the
 * JVM unit tests. Where a Core Image filter has no public formula the maths
 * here is an approximation; see android/README.md.
 *
 * Memory: the buffer itself, one copy while a look is blended below full
 * intensity, and two float planes for blurs; no per-channel float planes.
 *
 * Crop and overlays are not applied here; the app does them with
 * `android.graphics` using [CropGeometry].
 */
class PixelRenderer(private val catalog: LookCatalog) {

    /** Renders every enabled look and adjustment into a copy of [pixels]. */
    fun render(document: EditDocument, pixels: IntArray, width: Int, height: Int, seed: Long = seed(document.id)): IntArray {
        val out = pixels.copyOf(width * height)
        renderInPlace(document, out, width, height, seed)
        return out
    }

    /** Renders every enabled look and adjustment, overwriting [pixels]. */
    fun renderInPlace(document: EditDocument, pixels: IntArray, width: Int, height: Int, seed: Long = seed(document.id)) {
        require(pixels.size >= width * height) { "pixel buffer too small" }
        val img = ArgbImage(pixels, width, height)
        for (op in document.operations) {
            if (!op.isEnabled) continue
            when (val k = op.kind) {
                is OperationKind.Look -> applyLook(k.look, img, seed)
                is OperationKind.Adjust -> applyAdjustments(k.adjust, img, seed + 1)
                // Face-aware retouching needs on-device face landmarks; not rendered on Android yet.
                is OperationKind.Retouch -> Unit
            }
        }
    }

    /** Renders a single look into a copy, for thumbnails. */
    fun renderLook(application: LookApplication, pixels: IntArray, width: Int, height: Int, seed: Long = 1L): IntArray {
        val out = pixels.copyOf(width * height)
        applyLook(application, ArgbImage(out, width, height), seed)
        return out
    }

    // MARK: Looks

    internal fun applyLook(application: LookApplication, img: ArgbImage, seed: Long) {
        if (application.intensity <= 0) return
        val recipe = catalog.look(application.lookID) ?: return
        val p = recipe.params.applying(application.refine)
        val input = if (application.intensity < 1) img.px.copyOf(img.size) else null

        Lut3D.build { r, g, b -> lookColour(p, r, g, b) }.apply(img.px, img.size)
        if (p.bloom > 0) bloom(img, p.bloom)
        if (p.lightLeak > 0) lightLeak(img, p.lightLeak)
        if (p.vignette > 0) vignette(img, p.vignette)
        if (p.grain > 0) grain(img, p.grain, p.grainSize, seed)

        if (input != null) img.mixFrom(input, application.intensity.toFloat())
    }

    /** The colour-only part of a look, in iOS order. */
    internal fun lookColour(p: LookParameters, r0: Double, g0: Double, b0: Double): DoubleArray {
        var c = doubleArrayOf(r0, g0, b0)
        c = ColorOps.exposure(c, p.exposure * 1.5)
        c = ColorOps.highlightsShadows(c, p.highlights, p.shadows)
        c = ColorOps.colorControls(c, 0.0, p.contrast, if (p.monochrome) -1.0 else p.saturation)
        if (p.vibrance != 0.0) c = ColorOps.vibrance(c, p.vibrance)
        c = ColorOps.temperature(c, p.warmth, p.tint)
        c = ColorOps.splitTint(c, p.shadowsTint, p.highlightsTint)
        if (p.fade > 0) c = ColorOps.toneCurve(c, p.fade * 0.18, -p.fade * 0.04)
        return c
    }

    // MARK: Adjustments

    internal fun applyAdjustments(a: AdjustmentSet, img: ArgbImage, seed: Long) {
        if (a.isNeutral) return
        Lut3D.build { r, g, b -> adjustColour(a, r, g, b) }.apply(img.px, img.size)
        val scale = scaleOf(img)
        if (a.clarity > 0) unsharp(img, 20 * scale, a.clarity * 0.6)
        if (a.structure > 0) unsharp(img, 2.5 * scale, a.structure * 0.9)
        if (a.sharpness > 0) unsharp(img, 1.5 * scale, a.sharpness * 0.8)
        if (a.vignette != 0.0) vignette(img, a.vignette)
        if (a.grain > 0) grain(img, a.grain, 1.0, seed)
    }

    internal fun adjustColour(a: AdjustmentSet, r0: Double, g0: Double, b0: Double): DoubleArray {
        var c = doubleArrayOf(r0, g0, b0)
        if (a.exposure != 0.0) c = ColorOps.exposure(c, a.exposure * 2)
        c = ColorOps.highlightsShadows(c, a.highlights, a.shadows)
        if (a.whites != 0.0 || a.blacks != 0.0 || a.fade != 0.0) {
            c = ColorOps.toneCurve(c, a.blacks * 0.1 + a.fade * 0.18, a.whites * 0.1)
        }
        c = ColorOps.colorControls(c, a.brightness, a.contrast, a.saturation)
        if (a.vibrance != 0.0) c = ColorOps.vibrance(c, a.vibrance)
        c = ColorOps.temperature(c, a.warmth, a.tint)
        ColorCube.transform(c[0], c[1], c[2], a)?.let { c = it }
        return c
    }

    // MARK: Spatial steps

    /** Glow from the brightest areas, screened back over the image (CIBloom: radius 12, intensity 0.8x). */
    internal fun bloom(img: ArgbImage, amount: Double) {
        val bright = FloatArray(img.size) { i -> max(0f, (img.luma(i) - 0.55f) / 0.45f) }
        val glow = Blur.gaussian(bright, img.width, img.height, 12 * scaleOf(img))
        val k = (amount * 0.8).toFloat()
        for (i in 0 until img.size) {
            val g = (glow[i] * k).coerceIn(0f, 1f)
            if (g <= 0f) continue
            img.set(i, 1 - (1 - img.r(i)) * (1 - g), 1 - (1 - img.g(i)) * (1 - g), 1 - (1 - img.b(i)) * (1 - g))
        }
    }

    /** A warm radial glow from the top-right corner, screened over the image. */
    internal fun lightLeak(img: ArgbImage, amount: Double) {
        val w = img.width
        val h = img.height
        val radius = max(w, h) * 0.75
        val a0 = min(amount, 1.0) * 0.75
        for (y in 0 until h) for (x in 0 until w) {
            val t = (hypot((w - x).toDouble(), y.toDouble()) / radius).coerceIn(0.0, 1.0)
            // Gradient from (1, .55, .25, a0) to (1, .4, .2, 0), premultiplied, then screened.
            val alpha = a0 * (1 - t)
            if (alpha <= 0) continue
            val lr = alpha.toFloat()
            val lg = ((0.55 - 0.15 * t) * alpha).toFloat()
            val lb = ((0.25 - 0.05 * t) * alpha).toFloat()
            val i = y * w + x
            img.set(i, 1 - (1 - img.r(i)) * (1 - lr), 1 - (1 - img.g(i)) * (1 - lg), 1 - (1 - img.b(i)) * (1 - lb))
        }
    }

    /**
     * CIVignetteEffect (radius 0.42 of the diagonal, falloff 0.6). Positive
     * amounts darken the corners; negative amounts lighten them.
     */
    internal fun vignette(img: ArgbImage, amount: Double) {
        val w = img.width
        val h = img.height
        val cx = w / 2.0
        val cy = h / 2.0
        val radius = hypot(w.toDouble(), h.toDouble()) * 0.42
        val inner = radius * (1 - 0.6)
        val outer = radius * (1 + 0.6)
        for (y in 0 until h) for (x in 0 until w) {
            val e = smoothstep(inner, outer, hypot(x + 0.5 - cx, y + 0.5 - cy))
            if (e <= 0) continue
            val i = y * w + x
            if (amount > 0) {
                val f = (1 - amount * e).toFloat().coerceAtLeast(0f)
                img.set(i, img.r(i) * f, img.g(i) * f, img.b(i) * f)
            } else {
                val f = (-amount * e).toFloat()
                img.set(i, img.r(i) + (1 - img.r(i)) * f, img.g(i) + (1 - img.g(i)) * f, img.b(i) + (1 - img.b(i)) * f)
            }
        }
    }

    /**
     * Film grain: seeded value noise anchored to the image and soft-light
     * blended, so the same edit gets the same grain at any size.
     */
    internal fun grain(img: ArgbImage, amount: Double, size: Double, seed: Long) {
        val w = img.width
        val h = img.height
        val cell = scaleOf(img) * size.coerceIn(0.5, 2.0)
        val k = (min(amount, 1.0) * 0.35).toFloat()
        val ox = Math.floorMod(seed, 4096L)
        val oy = Math.floorMod(seed ushr 12, 4096L)
        for (y in 0 until h) {
            val gy = (y / cell).toLong() + oy
            for (x in 0 until w) {
                val gx = (x / cell).toLong() + ox
                val m = 0.5f - k / 2 + k * hashNoise(gx, gy, seed)
                val i = y * w + x
                img.set(i, softLight(img.r(i), m), softLight(img.g(i), m), softLight(img.b(i), m))
            }
        }
    }

    /** Unsharp mask on luminance: adds back the difference from a blurred copy. */
    internal fun unsharp(img: ArgbImage, radius: Double, intensity: Double) {
        val luma = FloatArray(img.size) { img.luma(it) }
        val blurred = Blur.gaussian(luma, img.width, img.height, radius)
        val k = intensity.toFloat()
        for (i in 0 until img.size) {
            val d = (luma[i] - blurred[i]) * k
            img.set(i, img.r(i) + d, img.g(i) + d, img.b(i) + d)
        }
    }

    companion object {
        /** Radii are authored for a 1080 px image, as on iOS. */
        fun scaleOf(img: ArgbImage): Double = max(img.width, img.height) / 1080.0

        /** FNV-1a over the UUID bytes, the same seed iOS derives. */
        fun seed(id: UUID): Long {
            var hash = -0x340d631b7bdddcdbL // 0xcbf29ce484222325
            val bytes = ByteArray(16)
            for (i in 0 until 8) bytes[i] = (id.mostSignificantBits ushr (56 - 8 * i)).toByte()
            for (i in 0 until 8) bytes[8 + i] = (id.leastSignificantBits ushr (56 - 8 * i)).toByte()
            for (b in bytes) {
                hash = hash xor (b.toLong() and 0xff)
                hash *= 0x100000001b3L
            }
            return hash
        }

        internal fun smoothstep(e0: Double, e1: Double, x: Double): Double {
            val t = ((x - e0) / (e1 - e0)).coerceIn(0.0, 1.0)
            return t * t * (3 - 2 * t)
        }

        /** W3C soft-light. */
        internal fun softLight(b: Float, s: Float): Float {
            return if (s <= 0.5f) {
                b - (1 - 2 * s) * b * (1 - b)
            } else {
                val d = if (b <= 0.25f) ((16 * b - 12) * b + 4) * b else sqrt(b)
                b + (2 * s - 1) * (d - b)
            }
        }

        /** Uniform 0...1 noise per grain cell. */
        internal fun hashNoise(x: Long, y: Long, seed: Long): Float {
            var h = x * -0x61c8864680b583ebL xor (y * -0x40a7b892e31b1a47L) xor seed
            h = h xor (h ushr 31)
            h *= -0x40a7b892e31b1a47L
            h = h xor (h ushr 29)
            return ((h ushr 11).toDouble() / (1L shl 53).toDouble()).toFloat()
        }

        /** Average luminance, saturation and warmth, for [com.aurum.core.LookSuggestion]. */
        fun stats(pixels: IntArray, width: Int, height: Int): ImageStats {
            val n = width * height
            if (n == 0) return ImageStats(0.5, 0.3, 0.0)
            val step = max(1, n / 20_000)
            var sr = 0.0
            var sg = 0.0
            var sb = 0.0
            var ss = 0.0
            var count = 0
            var i = 0
            while (i < n) {
                val p = pixels[i]
                val r = ((p shr 16) and 0xff) / 255.0
                val g = ((p shr 8) and 0xff) / 255.0
                val b = (p and 0xff) / 255.0
                val mx = max(r, max(g, b))
                val mn = min(r, min(g, b))
                sr += r; sg += g; sb += b
                ss += if (mx > 0) (mx - mn) / mx else 0.0
                count++
                i += step
            }
            val r = sr / count
            val g = sg / count
            val b = sb / count
            return ImageStats(0.2126 * r + 0.7152 * g + 0.0722 * b, ss / count, r - b)
        }
    }
}

/** Per-colour maths for the steps Core Image runs as single filters. */
object ColorOps {
    private fun srgbToLinear(v: Double) = if (v <= 0.04045) v / 12.92 else ((v + 0.055) / 1.055).pow(2.4)
    private fun linearToSrgb(v: Double) = if (v <= 0.0031308) v * 12.92 else 1.055 * v.pow(1 / 2.4) - 0.055
    private fun clamp(v: Double) = v.coerceIn(0.0, 1.0)
    fun luma(c: DoubleArray) = 0.2125 * c[0] + 0.7154 * c[1] + 0.0721 * c[2]

    /** CIExposureAdjust: multiplies linear light by 2^ev. */
    fun exposure(c: DoubleArray, ev: Double): DoubleArray {
        if (ev == 0.0) return c
        val f = 2.0.pow(ev)
        return DoubleArray(3) { clamp(linearToSrgb(srgbToLinear(c[it]) * f)) }
    }

    /**
     * Approximates CIHighlightShadowAdjust globally (Core Image uses a local,
     * blurred mask): lifts shadows and recovers highlights by scaling colour
     * along luminance, then brightens whites for positive highlights.
     */
    fun highlightsShadows(c: DoubleArray, highlights: Double, shadows: Double): DoubleArray {
        if (highlights == 0.0 && shadows == 0.0) return c
        var out = c
        val l = luma(c)
        if (l > 0.0005) {
            var target = l
            if (shadows != 0.0) target += shadows * 0.8 * 0.35 * 4 * l * (1 - l) * (1 - l)
            if (highlights < 0) target -= (-highlights * 0.7) * 0.35 * 4 * l * l * (1 - l)
            target = clamp(target)
            val f = target / l
            out = DoubleArray(3) { clamp(c[it] * f) }
        }
        if (highlights > 0) out = toneCurve(out, 0.0, highlights * 0.06)
        return out
    }

    /** CIColorControls: saturation around luma, then brightness, then contrast about mid-grey. */
    fun colorControls(c: DoubleArray, brightness: Double, contrast: Double, saturation: Double): DoubleArray {
        if (brightness == 0.0 && contrast == 0.0 && saturation == 0.0) return c
        val s = max(0.0, 1 + saturation)
        val k = 1 + contrast * 0.45
        val b = brightness * 0.25
        val l = luma(c)
        return DoubleArray(3) { clamp(((l + (c[it] - l) * s) + b - 0.5) * k + 0.5) }
    }

    /** CIVibrance: saturates muted colours more than saturated ones. */
    fun vibrance(c: DoubleArray, amount: Double): DoubleArray {
        val mx = max(c[0], max(c[1], c[2]))
        val mn = min(c[0], min(c[1], c[2]))
        val sat = mx - mn
        val f = 1 + amount * (1 - sat)
        val l = luma(c)
        return DoubleArray(3) { clamp(l + (c[it] - l) * f) }
    }

    /**
     * Approximates CITemperatureAndTint (neutral 6500 + warmth*2500 K → 6500 K)
     * with channel gains: warmth pushes red up and blue down, positive tint
     * pushes towards magenta.
     */
    fun temperature(c: DoubleArray, warmth: Double, tint: Double): DoubleArray {
        if (warmth == 0.0 && tint == 0.0) return c
        val r = c[0] * (1 + 0.12 * warmth) * (1 + 0.03 * tint)
        val g = c[1] * (1 - 0.02 * warmth) * (1 - 0.07 * tint)
        val b = c[2] * (1 - 0.14 * warmth) * (1 + 0.03 * tint)
        return doubleArrayOf(clamp(r), clamp(g), clamp(b))
    }

    /** Multiplies shadows and highlights by separate RGB tints, blended by luminance. */
    fun splitTint(c: DoubleArray, shadows: List<Double>, highlights: List<Double>): DoubleArray {
        if (shadows.size != 3 || highlights.size != 3) return c
        if (shadows == listOf(1.0, 1.0, 1.0) && highlights == listOf(1.0, 1.0, 1.0)) return c
        val m = luma(c)
        return DoubleArray(3) { clamp(c[it] * highlights[it] * m + c[it] * shadows[it] * (1 - m)) }
    }

    /**
     * The iOS five-point tone curve (black lift, white level), evaluated
     * piecewise-linearly; Core Image fits a spline through the same points.
     */
    fun toneCurve(c: DoubleArray, blackLift: Double, whites: Double): DoubleArray {
        val lift = blackLift.coerceIn(-0.1, 0.4)
        val top = (1 + whites).coerceIn(0.6, 1.0)
        val bottom = max(0.0, lift)
        val xs = doubleArrayOf(if (lift < 0) -lift else 0.0, 0.25, 0.5, 0.75, if (whites > 0) 1 - whites else 1.0)
        val ys = doubleArrayOf(bottom, bottom + (top - bottom) * 0.25, bottom + (top - bottom) * 0.5, bottom + (top - bottom) * 0.75, top)
        return DoubleArray(3) { clamp(piecewise(xs, ys, c[it])) }
    }

    private fun piecewise(xs: DoubleArray, ys: DoubleArray, x: Double): Double {
        if (x <= xs[0]) return ys[0]
        for (i in 1 until xs.size) {
            if (x <= xs[i]) {
                val span = xs[i] - xs[i - 1]
                val t = if (span <= 0) 1.0 else (x - xs[i - 1]) / span
                return ys[i - 1] + (ys[i] - ys[i - 1]) * t
            }
        }
        return ys.last()
    }
}

/** A view of packed ARGB pixels with float accessors; alpha is kept as it is. */
class ArgbImage(val px: IntArray, val width: Int, val height: Int) {
    val size: Int get() = width * height

    fun r(i: Int): Float = ((px[i] shr 16) and 0xff) * INV
    fun g(i: Int): Float = ((px[i] shr 8) and 0xff) * INV
    fun b(i: Int): Float = (px[i] and 0xff) * INV
    fun luma(i: Int): Float = 0.2125f * r(i) + 0.7154f * g(i) + 0.0721f * b(i)

    fun set(i: Int, r: Float, g: Float, b: Float) {
        px[i] = (px[i] and -0x1000000) or (q(r) shl 16) or (q(g) shl 8) or q(b)
    }

    /** px = from + (px - from) * t, per channel. */
    fun mixFrom(from: IntArray, t: Float) {
        for (i in 0 until size) {
            val o = from[i]
            val or = ((o shr 16) and 0xff) * INV
            val og = ((o shr 8) and 0xff) * INV
            val ob = (o and 0xff) * INV
            set(i, or + (r(i) - or) * t, og + (g(i) - og) * t, ob + (b(i) - ob) * t)
        }
    }

    companion object {
        private const val INV = 1f / 255f
        internal fun q(v: Float): Int = (v.coerceIn(0f, 1f) * 255f + 0.5f).toInt()
    }
}

/** A 3D colour lookup table with trilinear interpolation. */
class Lut3D private constructor(private val n: Int, private val data: FloatArray) {
    fun apply(px: IntArray, count: Int) {
        val m = (n - 1).toFloat()
        val inv = 1f / 255f
        for (i in 0 until count) {
            val p = px[i]
            val fr = ((p shr 16) and 0xff) * inv * m
            val fg = ((p shr 8) and 0xff) * inv * m
            val fb = (p and 0xff) * inv * m
            val out = sample(fr, fg, fb)
            px[i] = (p and -0x1000000) or (ArgbImage.q(out[0]) shl 16) or (ArgbImage.q(out[1]) shl 8) or ArgbImage.q(out[2])
        }
    }

    private val scratch = FloatArray(3)

    /** Trilinear sample at lattice coordinates (0...n-1). Not thread-safe (shares a scratch array). */
    private fun sample(fr: Float, fg: Float, fb: Float): FloatArray {
        val r0 = min(fr.toInt(), n - 2)
        val g0 = min(fg.toInt(), n - 2)
        val b0 = min(fb.toInt(), n - 2)
        val dr = fr - r0
        val dg = fg - g0
        val db = fb - b0
        for (ch in 0 until 3) {
            fun at(ri: Int, gi: Int, bi: Int) = data[((bi * n + gi) * n + ri) * 3 + ch]
            val c00 = at(r0, g0, b0) * (1 - dr) + at(r0 + 1, g0, b0) * dr
            val c10 = at(r0, g0 + 1, b0) * (1 - dr) + at(r0 + 1, g0 + 1, b0) * dr
            val c01 = at(r0, g0, b0 + 1) * (1 - dr) + at(r0 + 1, g0, b0 + 1) * dr
            val c11 = at(r0, g0 + 1, b0 + 1) * (1 - dr) + at(r0 + 1, g0 + 1, b0 + 1) * dr
            val c0 = c00 * (1 - dg) + c10 * dg
            val c1 = c01 * (1 - dg) + c11 * dg
            scratch[ch] = c0 * (1 - db) + c1 * db
        }
        return scratch
    }

    /** Looks up one colour (for tests). */
    fun lookup(r: Float, g: Float, b: Float): FloatArray {
        val m = (n - 1).toFloat()
        return sample(r.coerceIn(0f, 1f) * m, g.coerceIn(0f, 1f) * m, b.coerceIn(0f, 1f) * m).copyOf()
    }

    companion object {
        const val SIZE = 33

        fun build(size: Int = SIZE, f: (Double, Double, Double) -> DoubleArray): Lut3D {
            val data = FloatArray(size * size * size * 3)
            val m = (size - 1).toDouble()
            var k = 0
            for (bi in 0 until size) for (gi in 0 until size) for (ri in 0 until size) {
                val out = f(ri / m, gi / m, bi / m)
                data[k++] = out[0].toFloat()
                data[k++] = out[1].toFloat()
                data[k++] = out[2].toFloat()
            }
            return Lut3D(size, data)
        }
    }
}

/** Separable box blurs, three passes approximating a Gaussian. */
object Blur {
    fun gaussian(src: FloatArray, w: Int, h: Int, sigma: Double): FloatArray {
        if (sigma < 0.5) return src.copyOf()
        // Box width for three passes approximating a Gaussian of this sigma.
        val boxRadius = max(1, ((sqrt(12 * sigma * sigma / 3 + 1) - 1) / 2).roundToInt())
        val a = src.copyOf()
        val tmp = FloatArray(src.size)
        repeat(3) {
            horizontal(a, tmp, w, h, boxRadius)
            vertical(tmp, a, w, h, boxRadius)
        }
        return a
    }

    private fun horizontal(src: FloatArray, dst: FloatArray, w: Int, h: Int, r: Int) {
        val norm = 1f / (2 * r + 1)
        for (y in 0 until h) {
            val row = y * w
            var acc = 0f
            for (k in -r..r) acc += src[row + k.coerceIn(0, w - 1)]
            for (x in 0 until w) {
                dst[row + x] = acc * norm
                acc += src[row + min(x + r + 1, w - 1)] - src[row + max(x - r, 0)]
            }
        }
    }

    private fun vertical(src: FloatArray, dst: FloatArray, w: Int, h: Int, r: Int) {
        val norm = 1f / (2 * r + 1)
        for (x in 0 until w) {
            var acc = 0f
            for (k in -r..r) acc += src[k.coerceIn(0, h - 1) * w + x]
            for (y in 0 until h) {
                dst[y * w + x] = acc * norm
                acc += src[min(y + r + 1, h - 1) * w + x] - src[max(y - r, 0) * w + x]
            }
        }
    }
}

/** Crop geometry shared by the preview and the export, matching iOS `applyCrop`. */
object CropGeometry {
    /** The zoom needed so a straightened image still fills its frame. */
    fun straightenScale(width: Double, height: Double, radians: Double): Double {
        val c = cos(abs(radians))
        val s = sin(abs(radians))
        val w = width * c + height * s
        val h = width * s + height * c
        return max(w / width, h / height)
    }

    /** The crop rectangle in source pixels (top-left origin), rounded outwards like CGRect.integral. */
    fun pixelRect(crop: CropSpec, width: Int, height: Int): IntRect {
        val r: NormalizedRect = crop.rect.clamped()
        val left = kotlin.math.floor(r.x * width).toInt()
        val top = kotlin.math.floor(r.y * height).toInt()
        val right = kotlin.math.ceil((r.x + r.width) * width - 1e-9).toInt()
        val bottom = kotlin.math.ceil((r.y + r.height) * height - 1e-9).toInt()
        return IntRect(left.coerceIn(0, width), top.coerceIn(0, height), right.coerceIn(0, width), bottom.coerceIn(0, height))
    }

    data class IntRect(val left: Int, val top: Int, val right: Int, val bottom: Int) {
        val width get() = right - left
        val height get() = bottom - top
    }
}
