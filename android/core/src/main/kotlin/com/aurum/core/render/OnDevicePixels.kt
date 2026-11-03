package com.aurum.core.render

import com.aurum.core.FaceGeometry
import com.aurum.core.FaceRetouch
import com.aurum.core.LookApplication
import com.aurum.core.LookCatalog
import com.aurum.core.LookRecipe
import com.aurum.core.NormalizedPoint
import com.aurum.core.NormalizedRect
import com.aurum.core.ObjectRemover
import com.aurum.core.PortraitLook
import com.aurum.core.RetouchSettings
import com.aurum.core.Straighten
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.math.tan

/**
 * The Auto Studio's processing on packed ARGB pixels, the counterpart of
 * AurumRender/OnDevice/OnDeviceImaging.swift. Detection (faces, person
 * matte) happens in the app with bundled ML Kit models; everything here is
 * classic pixel processing, so it runs anywhere and is unit tested.
 *
 * Every function returns a new array the size of the input; the input is
 * never changed. A person matte is one float (0...1) per pixel.
 */
object OnDevicePixels {

    /** What goes behind the person in [replaceBackground]. */
    sealed interface Background {
        /** Another photo, aspect-filled. */
        class Image(val pixels: IntArray, val width: Int, val height: Int) : Background
        data class Color(val argb: Int) : Background
        /** Top colour to bottom colour. */
        data class Gradient(val top: Int, val bottom: Int) : Background
        /** The photo's own background, heavily blurred (a "studio" look). */
        data class Blur(val radius: Double) : Background
    }

    /** Where the soft key light comes from in [relight]. */
    enum class LightDirection { front, left, right, above }

    /** The parts of Auto Enhance. Each can be switched off. */
    data class EnhanceOptions(
        val autoTone: Boolean = true,
        val whiteBalance: Boolean = true,
        val straighten: Boolean = true,
        val redEye: Boolean = true,
        val clarity: Boolean = true,
    ) {
        companion object {
            val all = EnhanceOptions()
            val none = EnhanceOptions(false, false, false, false, false)
        }
    }

    // MARK: Enhance

    /**
     * Auto Enhance: red-eye fix, grey-world white balance, auto tone, light
     * noise reduction and sharpening, and levelling of a tilted horizon
     * ([horizonDegrees], counter-clockwise positive).
     */
    fun enhance(px: IntArray, w: Int, h: Int, options: EnhanceOptions = EnhanceOptions.all, faces: List<FaceGeometry> = emptyList(), horizonDegrees: Double? = null): IntArray {
        var out = px.copyOf(w * h)
        if (options.redEye) out = fixRedEye(out, w, h, faces)
        if (options.whiteBalance) out = balanceWhite(out, w, h)
        if (options.autoTone) out = autoTone(out, w, h)
        if (options.clarity) out = clarity(out, w, h)
        if (options.straighten && horizonDegrees != null && Straighten.isWorthCorrecting(horizonDegrees)) {
            out = straighten(out, w, h, horizonDegrees)
        }
        return out
    }

    /**
     * Rotates by [degrees] clockwise on screen (removing a counter-clockwise
     * tilt) about the centre, scaled up just enough to leave no empty corners.
     */
    fun straighten(px: IntArray, w: Int, h: Int, degrees: Double): IntArray {
        if (degrees == 0.0 || w < 2 || h < 2) return px.copyOf(w * h)
        val t = Math.toRadians(degrees)
        val s = Straighten.coverScale(w.toDouble(), h.toDouble(), t)
        val ct = cos(t)
        val st = sin(t)
        val cx = w / 2.0
        val cy = h / 2.0
        val out = IntArray(w * h)
        for (y in 0 until h) {
            val dy = y + 0.5 - cy
            for (x in 0 until w) {
                val dx = x + 0.5 - cx
                val sx = cx + (dx * ct + dy * st) / s
                val sy = cy + (-dx * st + dy * ct) / s
                out[y * w + x] = ObjectRemover.bilinear(px, w, h, sx - 0.5, sy - 0.5)
            }
        }
        return out
    }

    /**
     * Grey-world white balance: scales red, green and blue (in linear light)
     * so the photo's average is neutral, limited and softened so warm sunsets
     * stay warm.
     */
    fun balanceWhite(px: IntArray, w: Int, h: Int): IntArray {
        val n = w * h
        if (n == 0) return px.copyOf()
        val step = max(1, n / 40_000)
        val toLinear = DoubleArray(256) { srgbToLinear(it / 255.0) }
        var r = 0.0
        var g = 0.0
        var b = 0.0
        var count = 0
        var i = 0
        while (i < n) {
            val p = px[i]
            r += toLinear[(p shr 16) and 0xff]; g += toLinear[(p shr 8) and 0xff]; b += toLinear[p and 0xff]
            count++
            i += step
        }
        r = max(r / count, 1e-4); g = max(g / count, 1e-4); b = max(b / count, 1e-4)
        val mean = (r + g + b) / 3
        fun gain(c: Double): Double = 1 + 0.7 * ((0.8..1.25).clampD(mean / c) - 1)
        val tables = arrayOf(gain(r), gain(g), gain(b)).map { k ->
            IntArray(256) { v -> (linearToSrgb(toLinear[v] * k).coerceIn(0.0, 1.0) * 255 + 0.5).toInt() }
        }
        return mapChannels(px, n, tables[0], tables[1], tables[2])
    }

    /**
     * Automatic tone, standing in for Core Image's auto-enhance filters: a
     * gentle levels stretch from the luminance histogram, a midtone curve
     * towards a balanced exposure, a little shadow lift for dark photos and a
     * touch of vibrance.
     */
    fun autoTone(px: IntArray, w: Int, h: Int): IntArray {
        val n = w * h
        if (n == 0) return px.copyOf()
        val hist = IntArray(256)
        val step = max(1, n / 60_000)
        var count = 0
        var i = 0
        while (i < n) {
            val p = px[i]
            val l = (0.2126 * ((p shr 16) and 0xff) + 0.7152 * ((p shr 8) and 0xff) + 0.0722 * (p and 0xff)).toInt().coerceIn(0, 255)
            hist[l]++
            count++
            i += step
        }
        fun percentile(q: Double): Double {
            val target = q * count
            var acc = 0
            for (v in 0 until 256) {
                acc += hist[v]
                if (acc >= target) return v / 255.0
            }
            return 1.0
        }
        val black = min(percentile(0.005), 0.08)
        val white = max(percentile(0.995), 0.88)
        val range = max(0.2, white - black)
        val median = ((percentile(0.5) - black) / range).coerceIn(0.05, 0.95)
        // Pull the median halfway to 0.46 with a gamma curve, never by much.
        val fullGamma = ln(0.46) / ln(median)
        val gamma = (1 + (fullGamma - 1) * 0.5).coerceIn(0.78, 1.25)
        val shadowLift = if (percentile(0.1) < 0.06) 0.08 else 0.0
        val lut = Lut3D.build { r, g, b ->
            val c = DoubleArray(3)
            val src = doubleArrayOf(r, g, b)
            for (k in 0 until 3) {
                var v = ((src[k] - black) / range).coerceIn(0.0, 1.0)
                v = v.pow(gamma)
                v += shadowLift * 4 * v * (1 - v) * (1 - v)
                c[k] = v.coerceIn(0.0, 1.0)
            }
            ColorOps.vibrance(c, 0.12)
        }
        val out = px.copyOf(n)
        lut.apply(out, n)
        return out
    }

    /** Light noise reduction and luminance sharpening. */
    fun clarity(px: IntArray, w: Int, h: Int): IntArray {
        val n = w * h
        val img = ArgbImage(px.copyOf(n), w, h)
        val scale = max(w, h) / 1080.0
        val luma = FloatArray(n) { img.luma(it) }
        val soft = Blur.gaussian(luma, w, h, max(0.8, 0.8 * scale))
        val detail = Blur.gaussian(luma, w, h, max(1.0, 1.5 * scale))
        for (i in 0 until n) {
            val l = luma[i]
            // Smooth tiny differences (noise), keep real edges.
            val noise = l - soft[i]
            val nr = if (abs(noise) < 0.02f) -noise * 0.45f else 0f
            val sharpen = (l - detail[i]) * 0.35f
            val d = nr + sharpen
            if (d == 0f) continue
            img.set(i, img.r(i) + d, img.g(i) + d, img.b(i) + d)
        }
        return img.px
    }

    // MARK: Red eye

    /** The box around an eye's landmark points, grown so the pupil is inside. */
    fun eyeBox(points: List<NormalizedPoint>): NormalizedRect {
        val minX = points.minOf { it.x }
        val maxX = points.maxOf { it.x }
        val minY = points.minOf { it.y }
        val maxY = points.maxOf { it.y }
        val w = maxX - minX
        val pad = w * 0.2
        val hh = max(maxY - minY, w * 0.5)
        val cy = (minY + maxY) / 2
        return NormalizedRect(minX - pad, cy - hh / 2 - pad, w + pad * 2, hh + pad * 2)
    }

    private fun isRedPupil(p: Int): Boolean {
        val r = (p shr 16) and 0xff
        val g = (p shr 8) and 0xff
        val b = p and 0xff
        return r > 80 && r > 1.7 * max(g, b) && r - max(g, b) > 45
    }

    private fun eyeRects(faces: List<FaceGeometry>, w: Int, h: Int): List<IntArray> {
        val out = mutableListOf<IntArray>()
        for (face in faces) for (region in listOf(FaceGeometry.Region.leftEye, FaceGeometry.Region.rightEye)) {
            val pts = face.regions[region]
            if (pts.isNullOrEmpty()) continue
            val box = eyeBox(pts)
            val x0 = (box.x * w).toInt().coerceIn(0, w)
            val y0 = (box.y * h).toInt().coerceIn(0, h)
            val x1 = kotlin.math.ceil((box.x + box.width) * w).toInt().coerceIn(0, w)
            val y1 = kotlin.math.ceil((box.y + box.height) * h).toInt().coerceIn(0, h)
            if (x1 - x0 >= 1 && y1 - y0 >= 1) out.add(intArrayOf(x0, y0, x1, y1))
        }
        return out
    }

    /** Darkens red pupils inside the eye boxes. */
    fun fixRedEye(px: IntArray, w: Int, h: Int, faces: List<FaceGeometry>): IntArray {
        val out = px.copyOf(w * h)
        for (r in eyeRects(faces, w, h)) {
            for (y in r[1] until r[3]) for (x in r[0] until r[2]) {
                val i = y * w + x
                val p = out[i]
                if (!isRedPupil(p)) continue
                val g = (p shr 8) and 0xff
                val b = p and 0xff
                val v = ((g + b) / 2 * 0.85).toInt().coerceIn(0, 255)
                out[i] = (p and -0x1000000) or (v shl 16) or (min(g, 255) shl 8) or b
            }
        }
        return out
    }

    /** True when the red-eye fix changes the eyes noticeably (average change above 0.04 in an eye box). */
    fun hasRedEye(px: IntArray, w: Int, h: Int, faces: List<FaceGeometry>): Boolean {
        for (r in eyeRects(faces, w, h)) {
            var change = 0.0
            var count = 0
            for (y in r[1] until r[3]) for (x in r[0] until r[2]) {
                val p = px[y * w + x]
                count++
                if (isRedPupil(p)) {
                    val red = (p shr 16) and 0xff
                    val g = (p shr 8) and 0xff
                    val b = p and 0xff
                    change += (red - (g + b) / 2 * 0.85) / 255.0
                }
            }
            if (count > 0 && change / count > 0.04) return true
        }
        return false
    }

    // MARK: Portrait blur and background

    /**
     * Keeps the person sharp and blurs the rest. The blur is weighted by the
     * background, so the person's colours never smear into it; then the sharp
     * person goes back on top. [amount] 0...1 sets the radius.
     */
    fun portraitBlur(px: IntArray, w: Int, h: Int, amount: Double, matte: FloatArray): IntArray {
        val k = amount.coerceIn(0.0, 1.0)
        if (k <= 0) return px.copyOf(w * h)
        val sigma = k * min(w, h) * 0.025
        val blurred = backgroundBlur(px, w, h, matte, sigma)
        return blend(px, blurred, matte)
    }

    /** A blur of what is behind the person: weighted by (1 - matte). */
    internal fun backgroundBlur(px: IntArray, w: Int, h: Int, matte: FloatArray, sigma: Double): IntArray {
        val n = w * h
        val planes = Planes.of(px, n)
        val weight = FloatArray(n) { 1f - matte[it].coerceIn(0f, 1f) }
        val wBlur = Blur.gaussian(weight, w, h, sigma)
        val plain = planes.blurred(w, h, sigma)
        val weighted = Array(3) { ch ->
            val c = planes.c[ch]
            Blur.gaussian(FloatArray(n) { c[it] * weight[it] }, w, h, sigma)
        }
        val out = IntArray(n)
        for (i in 0 until n) {
            val ww = wBlur[i]
            var p = px[i] and -0x1000000
            for (ch in 0 until 3) {
                val v = if (ww > 0.05f) weighted[ch][i] / ww else plain.c[ch][i]
                p = p or (ArgbImage.q(v) shl (16 - 8 * ch))
            }
            out[i] = p
        }
        return out
    }

    /** Keeps the person and puts [background] behind them. */
    fun replaceBackground(px: IntArray, w: Int, h: Int, background: Background, matte: FloatArray): IntArray {
        val n = w * h
        val behind: IntArray = when (background) {
            is Background.Color -> IntArray(n) { background.argb or -0x1000000 }
            is Background.Gradient -> IntArray(n).also { out ->
                for (y in 0 until h) {
                    val t = if (h <= 1) 0f else y / (h - 1f)
                    val c = ObjectRemover.mix(background.top or -0x1000000, background.bottom or -0x1000000, t)
                    out.fill(c, y * w, y * w + w)
                }
            }
            is Background.Blur -> backgroundBlur(px, w, h, matte, max(1.0, background.radius) * min(w, h) / 1000.0)
            is Background.Image -> aspectFill(background.pixels, background.width, background.height, w, h)
        }
        return blend(px, behind, matte)
    }

    /** Scales and centres an image so it covers [w] × [h] completely. */
    fun aspectFill(src: IntArray, sw: Int, sh: Int, w: Int, h: Int): IntArray {
        val out = IntArray(w * h)
        if (sw <= 0 || sh <= 0) return out
        val s = max(w.toDouble() / sw, h.toDouble() / sh)
        val ox = (sw * s - w) / 2
        val oy = (sh * s - h) / 2
        for (y in 0 until h) {
            val fy = (y + 0.5 + oy) / s - 0.5
            for (x in 0 until w) {
                out[y * w + x] = ObjectRemover.bilinear(src, sw, sh, (x + 0.5 + ox) / s - 0.5, fy) or -0x1000000
            }
        }
        return out
    }

    // MARK: Relight

    /**
     * A soft, warm key light on each face, coming from [direction], kept on
     * the person by [matte] when there is one. With no faces, the light falls
     * on the upper middle of the frame.
     */
    fun relight(px: IntArray, w: Int, h: Int, faces: List<FaceGeometry>, direction: LightDirection, intensity: Double, matte: FloatArray?): IntArray {
        val k = intensity.coerceIn(0.0, 1.0)
        val n = w * h
        if (k <= 0 || n == 0) return px.copyOf(n)
        // The lit version: brighter and a little warmer.
        val lit = px.copyOf(n)
        Lut3D.build { r, g, b -> ColorOps.temperature(ColorOps.exposure(doubleArrayOf(r, g, b), 0.9 * k), 0.36 * k, 0.0) }.apply(lit, n)

        val shortSide = min(w, h).toDouble()
        val spots: List<DoubleArray> = if (faces.isEmpty()) {
            listOf(doubleArrayOf(w / 2.0, h * 0.4, shortSide * 0.35))
        } else {
            faces.map { f ->
                val b = f.bounds
                val size = max(b.width * w, b.height * h)
                doubleArrayOf((b.x + b.width / 2) * w, (b.y + b.height / 2) * h, max(size, shortSide * 0.08))
            }
        }
        val light = FloatArray(n)
        for (spot in spots) {
            var cx = spot[0]
            var cy = spot[1]
            val size = spot[2]
            when (direction) {
                LightDirection.front -> Unit
                LightDirection.left -> cx -= size * 0.6
                LightDirection.right -> cx += size * 0.6
                LightDirection.above -> cy -= size * 0.6
            }
            radial(light, w, h, cx, cy, size * 0.25, size * 1.6, max = true)
        }
        if (matte != null) for (i in 0 until n) light[i] *= matte[i]
        return blend(lit, px, light)
    }

    // MARK: Portrait Looks

    /** A portrait look: its colour recipe, a background blur behind the person and a vignette centred on the faces. */
    fun portraitLook(px: IntArray, w: Int, h: Int, look: PortraitLook, faces: List<FaceGeometry>, matte: FloatArray?, intensity: Double = 1.0, seed: Long = 1L): IntArray {
        val k = intensity.coerceIn(0.0, 1.0)
        val recipe = LookRecipe(look.id, look.name, "portrait", look.tier, params = look.params)
        val renderer = PixelRenderer(LookCatalog(collections = emptyList(), looks = listOf(recipe)))
        var out = renderer.renderLook(LookApplication.of(look.id, k), px, w, h, seed)
        if (look.backgroundBlur > 0 && matte != null) out = portraitBlur(out, w, h, look.backgroundBlur * k, matte)
        if (look.faceVignette > 0) out = faceVignette(out, w, h, faces, look.faceVignette * k)
        return out
    }

    /** Darkens away from the faces (or the frame's upper middle without faces). */
    fun faceVignette(px: IntArray, w: Int, h: Int, faces: List<FaceGeometry>, amount: Double): IntArray {
        val n = w * h
        if (amount <= 0 || n == 0) return px.copyOf(n)
        var cx = w / 2.0
        var cy = h * 0.4
        var faceSize = min(w, h) * 0.3
        if (faces.isNotEmpty()) {
            var sx = 0.0
            var sy = 0.0
            var size = 0.0
            for (f in faces) {
                val b = f.bounds
                sx += b.x + b.width / 2
                sy += b.y + b.height / 2
                size = max(size, max(b.width * w, b.height * h))
            }
            cx = sx / faces.size * w
            cy = sy / faces.size * h
            faceSize = max(size, min(w, h) * 0.12)
        }
        val dark = px.copyOf(n)
        Lut3D.build { r, g, b -> ColorOps.exposure(doubleArrayOf(r, g, b), -1.4 * amount) }.apply(dark, n)
        val light = FloatArray(n)
        radial(light, w, h, cx, cy, faceSize * 0.9, max(w, h) * 0.75, max = false)
        return blend(px, dark, light)
    }

    // MARK: Retouch

    /** The "Natural" skin retouch on every face, at [strength] 0...1. */
    fun naturalRetouch(px: IntArray, w: Int, h: Int, faces: List<FaceGeometry>, strength: Double): IntArray {
        val out = px.copyOf(w * h)
        RetouchRenderer.apply(RetouchSettings(FaceRetouch.natural.scaled(strength)), faces, ArgbImage(out, w, h))
        return out
    }

    // MARK: Analysis

    /** Average luminance (sRGB, 0...1) inside a normalised rect, or null when it is empty. */
    fun averageLuminance(px: IntArray, w: Int, h: Int, rect: NormalizedRect): Double? {
        val x0 = (rect.x * w).toInt().coerceIn(0, w)
        val y0 = (rect.y * h).toInt().coerceIn(0, h)
        val x1 = kotlin.math.ceil((rect.x + rect.width) * w).toInt().coerceIn(0, w)
        val y1 = kotlin.math.ceil((rect.y + rect.height) * h).toInt().coerceIn(0, h)
        if (x1 <= x0 || y1 <= y0) return null
        val step = max(1, ((x1 - x0) * (y1 - y0)) / 20_000)
        var sum = 0.0
        var count = 0
        var k = 0
        for (y in y0 until y1) for (x in x0 until x1) {
            if (k++ % step != 0) continue
            val p = px[y * w + x]
            sum += (0.2126 * ((p shr 16) and 0xff) + 0.7152 * ((p shr 8) and 0xff) + 0.0722 * (p and 0xff)) / 255.0
            count++
        }
        return if (count == 0) null else sum / count
    }

    /**
     * How much the top of the frame looks like open sky (bright, blue-leaning
     * and smooth), 0...1. Stands in for a scene classifier's "sky" label.
     */
    fun skyConfidence(px: IntArray, w: Int, h: Int): Double {
        val rows = max(1, h / 4)
        val step = max(1, (w * rows) / 10_000)
        var r = 0.0
        var g = 0.0
        var b = 0.0
        var lumSq = 0.0
        var count = 0
        var k = 0
        for (y in 0 until rows) for (x in 0 until w) {
            if (k++ % step != 0) continue
            val p = px[y * w + x]
            val rr = ((p shr 16) and 0xff) / 255.0
            val gg = ((p shr 8) and 0xff) / 255.0
            val bb = (p and 0xff) / 255.0
            r += rr; g += gg; b += bb
            val l = 0.2126 * rr + 0.7152 * gg + 0.0722 * bb
            lumSq += l * l
            count++
        }
        if (count == 0) return 0.0
        r /= count; g /= count; b /= count
        val lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        val spread = sqrt(max(0.0, lumSq / count - lum * lum))
        val blueness = ((b - r) / 0.25).coerceIn(0.0, 1.0)
        val brightness = ((lum - 0.35) / 0.3).coerceIn(0.0, 1.0)
        val smoothness = (1 - spread / 0.2).coerceIn(0.0, 1.0)
        return blueness * brightness * smoothness
    }

    /**
     * Finds a long, nearly level straight edge (a horizon) and returns its tilt
     * in degrees, counter-clockwise positive, or null when there is none. A
     * Hough transform over edges within ±15° of level, on a small copy.
     */
    fun horizonDegrees(px: IntArray, w: Int, h: Int): Double? {
        if (w < 16 || h < 16) return null
        val side = 320
        val s = min(1.0, side.toDouble() / max(w, h))
        val sw = max(16, (w * s).toInt())
        val sh = max(16, (h * s).toInt())
        val luma = FloatArray(sw * sh)
        for (y in 0 until sh) for (x in 0 until sw) {
            val p = ObjectRemover.bilinear(px, w, h, (x + 0.5) * w / sw - 0.5, (y + 0.5) * h / sh - 0.5)
            luma[y * sw + x] = (0.2126f * ((p shr 16) and 0xff) + 0.7152f * ((p shr 8) and 0xff) + 0.0722f * (p and 0xff)) / 255f
        }
        val smooth = Blur.gaussian(luma, sw, sh, 1.0)
        val maxTan = tan(Math.toRadians(20.0))
        val edgesX = ArrayList<Int>()
        val edgesY = ArrayList<Int>()
        for (y in 1 until sh - 1) for (x in 1 until sw - 1) {
            fun l(dx: Int, dy: Int) = smooth[(y + dy) * sw + x + dx]
            val gx = (l(1, -1) + 2 * l(1, 0) + l(1, 1)) - (l(-1, -1) + 2 * l(-1, 0) + l(-1, 1))
            val gy = (l(-1, 1) + 2 * l(0, 1) + l(1, 1)) - (l(-1, -1) + 2 * l(0, -1) + l(1, -1))
            val mag = hypot(gx, gy)
            if (mag < 0.25f) continue
            if (abs(gx) > abs(gy) * maxTan) continue
            edgesX.add(x)
            edgesY.add(y)
        }
        if (edgesX.size < sw / 2) return null
        val angleStep = 0.25
        val angles = DoubleArray(121) { -15.0 + it * angleStep }
        val diag = hypot(sw.toDouble(), sh.toDouble())
        val rhoBins = (2 * diag).toInt() + 2
        val acc = IntArray(angles.size * rhoBins)
        for (a in angles.indices) {
            val t = Math.toRadians(angles[a])
            val ct = cos(t)
            val st = sin(t)
            for (e in edgesX.indices) {
                // rho for a line through (x, y) with slope angle t (y down).
                val rho = edgesY[e] * ct - edgesX[e] * st
                val bin = (rho + diag).toInt()
                acc[a * rhoBins + bin]++
            }
        }
        var best = -1
        var bestVotes = 0
        for (i in acc.indices) {
            // Count a line together with its two neighbouring rho bins, as an edge may straddle them.
            val rb = i % rhoBins
            var v = acc[i]
            if (rb > 0) v += acc[i - 1]
            if (rb < rhoBins - 1) v += acc[i + 1]
            if (v > bestVotes) {
                bestVotes = v
                best = i
            }
        }
        // The line must run across most of the frame.
        if (best < 0 || bestVotes < sw * 0.6) return null
        val slope = angles[best / rhoBins]
        // A line rising to the right has a negative slope angle (y points down): that is a counter-clockwise tilt.
        val degrees = -slope
        return if (abs(degrees) < 1e-9) 0.0 else degrees
    }

    // MARK: Mattes

    /** Resizes a matte (bilinear) and softens its edge by [featherFraction] of the shorter side. */
    fun resizeMatte(matte: FloatArray, mw: Int, mh: Int, w: Int, h: Int, featherFraction: Double = 0.003): FloatArray {
        val out = FloatArray(w * h)
        for (y in 0 until h) {
            val fy = (y + 0.5) * mh / h - 0.5
            for (x in 0 until w) {
                out[y * w + x] = ObjectRemover.bilinearPlane(matte, mw, mh, (x + 0.5) * mw / w - 0.5, fy).coerceIn(0f, 1f)
            }
        }
        val feather = max(1.0, min(w, h) * featherFraction)
        return Blur.gaussian(out, w, h, feather)
    }

    /** The share of the frame a matte covers, 0...1. */
    fun coverage(matte: FloatArray): Double = if (matte.isEmpty()) 0.0 else matte.sumOf { it.toDouble() } / matte.size

    // MARK: Building blocks

    /** foreground where the mask is 1, background where it is 0. */
    fun blend(foreground: IntArray, background: IntArray, mask: FloatArray): IntArray =
        IntArray(foreground.size) { i -> ObjectRemover.mix(background[i], foreground[i], mask[i].coerceIn(0f, 1f)) }

    /** A linear radial falloff: 1 inside [r0], 0 beyond [r1]; combined by max or written. */
    private fun radial(mask: FloatArray, w: Int, h: Int, cx: Double, cy: Double, r0: Double, r1: Double, max: Boolean) {
        val span = max(1e-6, r1 - r0)
        for (y in 0 until h) {
            val dy = y + 0.5 - cy
            for (x in 0 until w) {
                val d = hypot(x + 0.5 - cx, dy)
                val v = (1 - ((d - r0) / span)).coerceIn(0.0, 1.0).toFloat()
                val i = y * w + x
                mask[i] = if (max) max(mask[i], v) else v
            }
        }
    }

    private fun mapChannels(px: IntArray, n: Int, r: IntArray, g: IntArray, b: IntArray): IntArray = IntArray(n) { i ->
        val p = px[i]
        (p and -0x1000000) or (r[(p shr 16) and 0xff] shl 16) or (g[(p shr 8) and 0xff] shl 8) or b[p and 0xff]
    }

    private fun srgbToLinear(v: Double) = if (v <= 0.04045) v / 12.92 else ((v + 0.055) / 1.055).pow(2.4)
    private fun linearToSrgb(v: Double) = if (v <= 0.0031308) v * 12.92 else 1.055 * v.pow(1 / 2.4) - 0.055
    private fun ClosedFloatingPointRange<Double>.clampD(v: Double) = v.coerceIn(start, endInclusive)
}
