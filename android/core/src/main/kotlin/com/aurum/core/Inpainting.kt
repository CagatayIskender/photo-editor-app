package com.aurum.core

import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * A small RGBA image in floats (0...1), interleaved, row 0 at the top.
 * Used for the CPU part of Object Remove, on a downscaled region.
 */
class RGBAImageBuffer(val width: Int, val height: Int, val pixels: FloatArray) {
    init {
        require(width >= 0 && height >= 0 && pixels.size == width * height * 4) { "pixel count must be width × height × 4" }
    }

    fun copy(): RGBAImageBuffer = RGBAImageBuffer(width, height, pixels.copyOf())

    /** 8-bit RGBA bytes, rounded and clamped. */
    val rgba8: ByteArray
        get() = ByteArray(pixels.size) { i ->
            val c = min(max(pixels[i], 0f), 1f) * 255f
            swiftRoundF(c).toInt().toByte()
        }

    fun value(x: Int, y: Int, channel: Int): Float = pixels[(y * width + x) * 4 + channel]

    fun setValue(value: Float, x: Int, y: Int, channel: Int) {
        pixels[(y * width + x) * 4 + channel] = value
    }

    override fun equals(other: Any?): Boolean =
        other is RGBAImageBuffer && other.width == width && other.height == height && other.pixels.contentEquals(pixels)

    override fun hashCode(): Int = (width * 31 + height) * 31 + pixels.contentHashCode()

    companion object {
        /** A buffer filled with one colour. */
        fun filled(width: Int, height: Int, red: Float, green: Float, blue: Float, alpha: Float = 1f): RGBAImageBuffer {
            val p = FloatArray(width * height * 4)
            var i = 0
            while (i < p.size) {
                p[i] = red; p[i + 1] = green; p[i + 2] = blue; p[i + 3] = alpha
                i += 4
            }
            return RGBAImageBuffer(width, height, p)
        }

        /** From 8-bit RGBA bytes. */
        fun fromRgba8(bytes: ByteArray, width: Int, height: Int): RGBAImageBuffer {
            require(bytes.size == width * height * 4) { "byte count must be width × height × 4" }
            return RGBAImageBuffer(width, height, FloatArray(bytes.size) { (bytes[it].toInt() and 0xff) / 255f })
        }

        /** From packed ARGB ints (Android's `Bitmap.getPixels` layout). */
        fun fromArgb(argb: IntArray, width: Int, height: Int): RGBAImageBuffer {
            val p = FloatArray(width * height * 4)
            for (i in 0 until width * height) {
                val c = argb[i]
                p[i * 4] = ((c shr 16) and 0xff) / 255f
                p[i * 4 + 1] = ((c shr 8) and 0xff) / 255f
                p[i * 4 + 2] = (c and 0xff) / 255f
                p[i * 4 + 3] = ((c ushr 24) and 0xff) / 255f
            }
            return RGBAImageBuffer(width, height, p)
        }

        private fun swiftRoundF(v: Float): Float = if (v >= 0) kotlin.math.floor(v + 0.5f) else -kotlin.math.floor(-v + 0.5f)
    }

    /** Packed ARGB ints, rounded and clamped. */
    fun toArgb(): IntArray = IntArray(width * height) { i ->
        fun q(v: Float) = (min(max(v, 0f), 1f) * 255f + 0.5f).toInt()
        (q(pixels[i * 4 + 3]) shl 24) or (q(pixels[i * 4]) shl 16) or (q(pixels[i * 4 + 1]) shl 8) or q(pixels[i * 4 + 2])
    }
}

/**
 * Classic, non-generative inpainting for Object Remove, ported from
 * AurumCore/Inpainting.swift.
 *
 * 1. Push-pull fill: the hole is filled from its surroundings with a
 *    multi-scale pyramid.
 * 2. Texture from a nearby patch: several offsets around the hole's bounding
 *    box are tested; the one whose shifted copy matches the hole's border best
 *    is copied in, and the remaining border difference is spread across the
 *    hole with another push-pull pass so the patch blends in.
 *
 * Pixels outside the hole are never changed.
 */
object Inpainter {
    /** Width, in pixels, of the known ring around the hole used to judge patches. */
    const val ringWidth = 3
    /** Patches whose border mismatch is above this are not used; the smooth fill stays. */
    const val maximumPatchCost = 0.03f

    /** Fills every pixel where [mask] ≥ 0.5. [mask] has one value per pixel. */
    fun fill(image: RGBAImageBuffer, mask: FloatArray, useTexture: Boolean = true): RGBAImageBuffer {
        val n = image.width * image.height
        if (n <= 0 || mask.size != n) return image
        val known = FloatArray(n) { 1f }
        var holeCount = 0
        for (i in 0 until n) if (mask[i] >= 0.5f) {
            known[i] = 0f
            holeCount++
        }
        if (holeCount == 0 || holeCount >= n) return image

        val result = image.copy()
        if (useTexture) {
            val offset = bestPatchOffset(image, known)
            if (offset != null) {
                val correction = borderCorrection(image, known, offset)
                for (y in 0 until image.height) for (x in 0 until image.width) {
                    val i = y * image.width + x
                    if (known[i] != 0f) continue
                    val si = (y + offset.dy) * image.width + (x + offset.dx)
                    for (k in 0 until 3) {
                        val v = image.pixels[si * 4 + k] + correction[i * 4 + k]
                        result.pixels[i * 4 + k] = min(max(v, 0f), 1f)
                    }
                    result.pixels[i * 4 + 3] = image.pixels[si * 4 + 3]
                }
                return result
            }
        }

        val smooth = pushPull(image.pixels, known, image.width, image.height, 4)
        for (i in 0 until n) if (known[i] == 0f) {
            for (k in 0 until 4) result.pixels[i * 4 + k] = min(max(smooth[i * 4 + k], 0f), 1f)
        }
        return result
    }

    // MARK: Push-pull

    /**
     * Fills values where [weights] is below 1 from the weighted values around
     * them. [values] holds [channels] floats per pixel; pixels with weight 1
     * come back unchanged.
     */
    fun pushPull(values: FloatArray, weights: FloatArray, width: Int, height: Int, channels: Int): FloatArray {
        val n = width * height
        if (n <= 0 || weights.size != n || values.size != n * channels) return values

        val premultiplied = FloatArray(n * channels)
        for (i in 0 until n) {
            val w = weights[i]
            for (k in 0 until channels) premultiplied[i * channels + k] = values[i * channels + k] * w
        }
        val colourLevels = mutableListOf(premultiplied)
        val weightLevels = mutableListOf(weights)
        val sizesW = mutableListOf(width)
        val sizesH = mutableListOf(height)

        // Pull: average known values down until one pixel remains.
        while (sizesW.last() > 1 || sizesH.last() > 1) {
            val fw = sizesW.last()
            val fh = sizesH.last()
            val fineColour = colourLevels.last()
            val fineWeight = weightLevels.last()
            val cw = (fw + 1) / 2
            val ch = (fh + 1) / 2
            val colour = FloatArray(cw * ch * channels)
            val weight = FloatArray(cw * ch)
            for (y in 0 until ch) for (x in 0 until cw) {
                val o = y * cw + x
                var sum = 0f
                for (dy in 0 until 2) {
                    val sy = 2 * y + dy
                    if (sy >= fh) continue
                    for (dx in 0 until 2) {
                        val sx = 2 * x + dx
                        if (sx >= fw) continue
                        val si = sy * fw + sx
                        sum += fineWeight[si]
                        for (k in 0 until channels) colour[o * channels + k] += fineColour[si * channels + k]
                    }
                }
                if (sum > 0) {
                    val w = min(1f, sum)
                    val scale = w / sum
                    for (k in 0 until channels) colour[o * channels + k] *= scale
                    weight[o] = w
                }
            }
            colourLevels.add(colour)
            weightLevels.add(weight)
            sizesW.add(cw)
            sizesH.add(ch)
        }

        val top = colourLevels.size - 1
        var filled = colourLevels[top].copyOf()
        val topWeights = weightLevels[top]
        for (i in topWeights.indices) {
            val w = topWeights[i]
            for (k in 0 until channels) filled[i * channels + k] = if (w > 0) filled[i * channels + k] / w else 0f
        }

        // Push: blend the coarser, complete level into what each finer level lacks.
        var level = top - 1
        while (level >= 0) {
            val fw = sizesW[level]
            val fh = sizesH[level]
            val cw = sizesW[level + 1]
            val chh = sizesH[level + 1]
            val fineColour = colourLevels[level]
            val fineWeight = weightLevels[level]
            val out = FloatArray(fw * fh * channels)
            for (y in 0 until fh) {
                val fy = max(0f, min((chh - 1).toFloat(), (y + 0.5f) / 2 - 0.5f))
                val y0 = fy.toInt()
                val y1 = min(y0 + 1, chh - 1)
                val ty = fy - y0
                for (x in 0 until fw) {
                    val i = y * fw + x
                    val w = fineWeight[i]
                    if (w >= 1) {
                        for (k in 0 until channels) out[i * channels + k] = fineColour[i * channels + k]
                        continue
                    }
                    val fx = max(0f, min((cw - 1).toFloat(), (x + 0.5f) / 2 - 0.5f))
                    val x0 = fx.toInt()
                    val x1 = min(x0 + 1, cw - 1)
                    val tx = fx - x0
                    val i00 = (y0 * cw + x0) * channels
                    val i10 = (y0 * cw + x1) * channels
                    val i01 = (y1 * cw + x0) * channels
                    val i11 = (y1 * cw + x1) * channels
                    val missing = 1 - w
                    for (k in 0 until channels) {
                        val upper = filled[i00 + k] + (filled[i10 + k] - filled[i00 + k]) * tx
                        val lower = filled[i01 + k] + (filled[i11 + k] - filled[i01 + k]) * tx
                        val sample = upper + (lower - upper) * ty
                        out[i * channels + k] = fineColour[i * channels + k] + missing * sample
                    }
                }
            }
            filled = out
            level--
        }
        return filled
    }

    // MARK: Patch search

    /** A shift, in pixels, from a hole pixel to the pixel copied into it. */
    data class Offset(val dx: Int, val dy: Int)

    private class Box(val minX: Int, val minY: Int, val maxX: Int, val maxY: Int)

    private fun holeBounds(known: FloatArray, width: Int, height: Int): Box? {
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for (y in 0 until height) for (x in 0 until width) {
            if (known[y * width + x] == 0f) {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return if (maxX < 0) null else Box(minX, minY, maxX, maxY)
    }

    /** Known pixels within [ringWidth] of the hole (by chessboard distance). */
    internal fun ring(known: FloatArray, width: Int, height: Int): IntArray {
        val inRing = BooleanArray(width * height)
        val r = ringWidth
        for (y in 0 until height) for (x in 0 until width) {
            if (known[y * width + x] != 0f) continue
            val left = x > 0 && known[y * width + x - 1] != 0f
            val right = x < width - 1 && known[y * width + x + 1] != 0f
            val up = y > 0 && known[(y - 1) * width + x] != 0f
            val down = y < height - 1 && known[(y + 1) * width + x] != 0f
            if (!(left || right || up || down)) continue
            for (ny in max(0, y - r)..min(height - 1, y + r)) for (nx in max(0, x - r)..min(width - 1, x + r)) {
                if (known[ny * width + nx] != 0f) inRing[ny * width + nx] = true
            }
        }
        var count = 0
        for (b in inRing) if (b) count++
        val out = IntArray(count)
        var j = 0
        for (i in inRing.indices) if (inRing[i]) out[j++] = i
        return out
    }

    /**
     * Offsets to try: in eight directions around the hole's bounding box, at
     * several distances, plus a finer sweep straight left, right, up and down
     * (which finds the period of stripes and tiles).
     */
    fun candidateOffsets(holeWidth: Int, holeHeight: Int): List<Offset> {
        val gap = ringWidth + 1
        val baseX = holeWidth + gap
        val baseY = holeHeight + gap
        val seen = HashSet<Offset>()
        val out = mutableListOf<Offset>()
        fun add(o: Offset) {
            if ((o.dx != 0 || o.dy != 0) && seen.add(o)) out.add(o)
        }
        val directions = listOf(1 to 0, -1 to 0, 0 to 1, 0 to -1, 1 to 1, -1 to 1, 1 to -1, -1 to -1)
        val multipliers = doubleArrayOf(1.0, 1.15, 1.3, 1.5, 1.75, 2.0)
        for ((sx, sy) in directions) for (m in multipliers) {
            val dx = swiftRound(baseX * m).toInt() * sx
            val dy = swiftRound(baseY * m).toInt() * sy
            add(Offset(dx, dy))
        }
        val stepX = max(1, baseX / 16)
        val stepY = max(1, baseY / 16)
        var d = baseX
        while (d <= baseX * 2) {
            add(Offset(d, 0)); add(Offset(-d, 0))
            d += stepX
        }
        d = baseY
        while (d <= baseY * 2) {
            add(Offset(0, d)); add(Offset(0, -d))
            d += stepY
        }
        return out
    }

    /**
     * How badly the copy shifted by [offset] fits the hole's border: the
     * spread of the colour difference around the ring, plus a smaller penalty
     * for its average. Null when the copy would leave the image or read from the hole.
     */
    fun patchCost(image: RGBAImageBuffer, known: FloatArray, ring: IntArray, offset: Offset): Float? {
        val w = image.width
        val h = image.height
        var count = 0f
        val sum = FloatArray(3)
        val sumSquares = FloatArray(3)
        for (i in ring) {
            val x = i % w + offset.dx
            val y = i / w + offset.dy
            if (x < 0 || y < 0 || x >= w || y >= h) continue
            val si = y * w + x
            if (known[si] == 0f) continue
            for (k in 0 until 3) {
                val diff = image.pixels[i * 4 + k] - image.pixels[si * 4 + k]
                sum[k] += diff
                sumSquares[k] += diff * diff
            }
            count += 1
        }
        if (count <= 0 || count < ring.size / 2f) return null
        var cost = 0f
        for (k in 0 until 3) {
            val mean = sum[k] / count
            val variance = max(0f, sumSquares[k] / count - mean * mean)
            cost += variance + 0.25f * mean * mean
        }
        return cost / 3
    }

    /** The offset whose copy fits the hole best, or null when none fits within [maximumPatchCost]. */
    fun bestPatchOffset(image: RGBAImageBuffer, known: FloatArray): Offset? {
        val w = image.width
        val h = image.height
        val box = holeBounds(known, w, h) ?: return null
        val ringPixels = ring(known, w, h)
        if (ringPixels.isEmpty()) return null
        val holeWidth = box.maxX - box.minX + 1
        val holeHeight = box.maxY - box.minY + 1
        val holePixels = ArrayList<Int>()
        for (y in box.minY..box.maxY) for (x in box.minX..box.maxX) if (known[y * w + x] == 0f) holePixels.add(y * w + x)

        var best: Offset? = null
        var bestCost = maximumPatchCost
        for (offset in candidateOffsets(holeWidth, holeHeight)) {
            val minX = box.minX + offset.dx
            val maxX = box.maxX + offset.dx
            val minY = box.minY + offset.dy
            val maxY = box.maxY + offset.dy
            if (minX < 0 || minY < 0 || maxX >= w || maxY >= h) continue
            var readsHole = false
            for (i in holePixels) {
                if (known[i + offset.dy * w + offset.dx] == 0f) {
                    readsHole = true
                    break
                }
            }
            if (readsHole) continue
            val cost = patchCost(image, known, ringPixels, offset) ?: continue
            if (cost < bestCost || (cost == bestCost && best == null)) {
                bestCost = cost
                best = offset
            }
        }
        return best
    }

    /** The colour difference between the border and the shifted copy's border, spread across the hole. */
    internal fun borderCorrection(image: RGBAImageBuffer, known: FloatArray, offset: Offset): FloatArray {
        val w = image.width
        val h = image.height
        val n = w * h
        val values = FloatArray(n * 4)
        val weights = FloatArray(n)
        for (i in ring(known, w, h)) {
            val x = i % w + offset.dx
            val y = i / w + offset.dy
            if (x < 0 || y < 0 || x >= w || y >= h) continue
            val si = y * w + x
            if (known[si] == 0f) continue
            for (k in 0 until 3) values[i * 4 + k] = image.pixels[i * 4 + k] - image.pixels[si * 4 + k]
            weights[i] = 1f
        }
        return pushPull(values, weights, w, h, 4)
    }
}

/**
 * Object Remove on packed ARGB pixels: the brushed area is filled from its
 * own surroundings by [Inpainter], then composited back through a feathered
 * mask. Only the region around the brushed area is processed, at full
 * resolution when it fits in [maxWorkingSide] and downscaled otherwise.
 * Port of AurumRender/OnDevice/ObjectRemover.swift.
 */
object ObjectRemover {
    const val maxWorkingSide = 1024

    class EmptyMask : Exception("nothing to remove")

    /** Returns a new pixel array with the brushed area removed. */
    fun remove(mask: BrushMask, pixels: IntArray, width: Int, height: Int, maxWorkingSide: Int = ObjectRemover.maxWorkingSide): IntArray {
        require(width >= 2 && height >= 2 && pixels.size >= width * height) { "image too small" }
        val imageWidth = width.toDouble()
        val imageHeight = height.toDouble()
        val painted = mask.paintedBounds(imageWidth / imageHeight) ?: throw EmptyMask()

        val region = workingRegion(painted, imageWidth, imageHeight)
        val scale = min(1.0, maxWorkingSide / max(region[2], region[3]))
        val bw = max(2, kotlin.math.floor(region[2] * scale).toInt())
        val bh = max(2, kotlin.math.floor(region[3] * scale).toInt())
        val sx = bw / region[2]
        val sy = bh / region[3]

        // Sample the region into the buffer (bilinear, edge-clamped).
        val local = IntArray(bw * bh)
        for (y in 0 until bh) {
            val fy = region[1] + (y + 0.5) / sy - 0.5
            for (x in 0 until bw) {
                val fx = region[0] + (x + 0.5) / sx - 0.5
                local[y * bw + x] = bilinear(pixels, width, height, fx, fy)
            }
        }

        val imageW = imageWidth * sx
        val imageH = imageHeight * sy
        val originX = region[0] * sx
        val originY = region[1] * sy
        val hole = mask.coverage(bw, bh, imageW, imageH, originX, originY, grow = 2.0)
        if (hole.none { it > 0 }) throw EmptyMask()

        val filled = Inpainter.fill(RGBAImageBuffer.fromArgb(local, bw, bh), hole).toArgb()

        // The composite mask: the brushed area grown by one pixel, feathered.
        val soft = mask.coverage(bw, bh, imageW, imageH, originX, originY, grow = 1.0)
        val feathered = com.aurum.core.render.Blur.gaussian(soft, bw, bh, 1.5)

        val out = pixels.copyOf(width * height)
        val x0 = kotlin.math.floor(region[0]).toInt().coerceIn(0, width - 1)
        val y0 = kotlin.math.floor(region[1]).toInt().coerceIn(0, height - 1)
        val x1 = kotlin.math.ceil(region[0] + region[2]).toInt().coerceIn(1, width)
        val y1 = kotlin.math.ceil(region[1] + region[3]).toInt().coerceIn(1, height)
        for (y in y0 until y1) {
            val by = (y + 0.5 - region[1]) * sy - 0.5
            for (x in x0 until x1) {
                val bx = (x + 0.5 - region[0]) * sx - 0.5
                val m = bilinearPlane(feathered, bw, bh, bx, by)
                if (m <= 0.002f) continue
                val f = bilinear(filled, bw, bh, bx, by)
                val i = y * width + x
                out[i] = mix(pixels[i], f, m.coerceAtMost(1f))
            }
        }
        return out
    }

    /** The painted box grown by its size (at least 32 px) on every side, clamped. [x, y, width, height] in pixels, top-left origin. */
    fun workingRegion(painted: NormalizedRect, imageWidth: Double, imageHeight: Double): DoubleArray {
        val px = painted.x * imageWidth
        val py = painted.y * imageHeight
        val pw = painted.width * imageWidth
        val ph = painted.height * imageHeight
        val margin = max(32.0, max(pw, ph))
        val minX = max(0.0, kotlin.math.floor(px - margin))
        val minY = max(0.0, kotlin.math.floor(py - margin))
        val maxX = min(imageWidth, kotlin.math.ceil(px + pw + margin))
        val maxY = min(imageHeight, kotlin.math.ceil(py + ph + margin))
        return doubleArrayOf(minX, minY, max(1.0, maxX - minX), max(1.0, maxY - minY))
    }

    internal fun bilinear(px: IntArray, w: Int, h: Int, fx: Double, fy: Double): Int {
        val cx = fx.coerceIn(0.0, (w - 1).toDouble())
        val cy = fy.coerceIn(0.0, (h - 1).toDouble())
        val x0 = cx.toInt()
        val y0 = cy.toInt()
        val x1 = min(x0 + 1, w - 1)
        val y1 = min(y0 + 1, h - 1)
        val tx = (cx - x0).toFloat()
        val ty = (cy - y0).toFloat()
        val a = px[y0 * w + x0]
        val b = px[y0 * w + x1]
        val c = px[y1 * w + x0]
        val d = px[y1 * w + x1]
        var out = 0
        for (shift in intArrayOf(24, 16, 8, 0)) {
            val va = (a ushr shift) and 0xff
            val vb = (b ushr shift) and 0xff
            val vc = (c ushr shift) and 0xff
            val vd = (d ushr shift) and 0xff
            val top = va + (vb - va) * tx
            val bottom = vc + (vd - vc) * tx
            val v = (top + (bottom - top) * ty).roundToInt().coerceIn(0, 255)
            out = out or (v shl shift)
        }
        return out
    }

    internal fun bilinearPlane(p: FloatArray, w: Int, h: Int, fx: Double, fy: Double): Float {
        if (fx < -1 || fy < -1 || fx > w || fy > h) return 0f
        val cx = fx.coerceIn(0.0, (w - 1).toDouble())
        val cy = fy.coerceIn(0.0, (h - 1).toDouble())
        val x0 = cx.toInt()
        val y0 = cy.toInt()
        val x1 = min(x0 + 1, w - 1)
        val y1 = min(y0 + 1, h - 1)
        val tx = (cx - x0).toFloat()
        val ty = (cy - y0).toFloat()
        val top = p[y0 * w + x0] + (p[y0 * w + x1] - p[y0 * w + x0]) * tx
        val bottom = p[y1 * w + x0] + (p[y1 * w + x1] - p[y1 * w + x0]) * tx
        return top + (bottom - top) * ty
    }

    /** a + (b - a) * t per RGB channel; alpha from a. */
    internal fun mix(a: Int, b: Int, t: Float): Int {
        fun ch(shift: Int): Int {
            val va = (a shr shift) and 0xff
            val vb = (b shr shift) and 0xff
            return (va + (vb - va) * t + 0.5f).toInt().coerceIn(0, 255)
        }
        return (a and -0x1000000) or (ch(16) shl 16) or (ch(8) shl 8) or ch(0)
    }
}
