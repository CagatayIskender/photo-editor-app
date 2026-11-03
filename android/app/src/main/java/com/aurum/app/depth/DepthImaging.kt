package com.aurum.app.depth

import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Small CPU image operations for 3D Motion, on single float planes (masks,
 * depth) and packed ARGB pixels. They stand in for the Core Image filters the
 * iOS renderer uses: Gaussian blur (three box passes), morphology maximum and
 * bilinear resampling.
 */
internal object DepthImaging {

    /**
     * Approximates a Gaussian blur of standard deviation [radius] (Core Image's
     * blur radius) with three box passes. Edges are clamped, like
     * `clampedToExtent()` before a blur.
     */
    fun blur(plane: FloatArray, width: Int, height: Int, radius: Double) {
        if (radius < 0.5 || width <= 0 || height <= 0) return
        val box = boxRadius(radius)
        if (box < 1) return
        val tmp = FloatArray(plane.size)
        repeat(3) {
            boxHorizontal(plane, tmp, width, height, box)
            boxVertical(tmp, plane, width, height, box)
        }
    }

    /** The same blur on the colour channels of opaque ARGB pixels. Alpha is set to opaque. */
    fun blurArgb(pixels: IntArray, width: Int, height: Int, radius: Double) {
        if (radius < 0.5) return
        val n = width * height
        val r = FloatArray(n)
        val g = FloatArray(n)
        val b = FloatArray(n)
        for (i in 0 until n) {
            val c = pixels[i]
            r[i] = ((c shr 16) and 0xFF).toFloat()
            g[i] = ((c shr 8) and 0xFF).toFloat()
            b[i] = (c and 0xFF).toFloat()
        }
        blur(r, width, height, radius)
        blur(g, width, height, radius)
        blur(b, width, height, radius)
        for (i in 0 until n) {
            pixels[i] = (0xFF shl 24) or (channel(r[i]) shl 16) or (channel(g[i]) shl 8) or channel(b[i])
        }
    }

    /** Grows bright areas: the maximum over a (2r+1)² square, separable. */
    fun maximum(plane: FloatArray, width: Int, height: Int, radius: Int): FloatArray {
        if (radius < 1) return plane.copyOf()
        val tmp = FloatArray(plane.size)
        for (y in 0 until height) {
            val row = y * width
            for (x in 0 until width) {
                var m = 0f
                val lo = max(0, x - radius)
                val hi = min(width - 1, x + radius)
                for (k in lo..hi) { val v = plane[row + k]; if (v > m) m = v }
                tmp[row + x] = m
            }
        }
        val out = FloatArray(plane.size)
        for (x in 0 until width) {
            for (y in 0 until height) {
                var m = 0f
                val lo = max(0, y - radius)
                val hi = min(height - 1, y + radius)
                for (k in lo..hi) { val v = tmp[k * width + x]; if (v > m) m = v }
                out[y * width + x] = m
            }
        }
        return out
    }

    /** Bilinear resampling of a plane to a new size (pixel centres aligned). */
    fun resample(src: FloatArray, sw: Int, sh: Int, dw: Int, dh: Int): FloatArray {
        if (sw == dw && sh == dh) return src.copyOf()
        val out = FloatArray(dw * dh)
        val sx = sw.toFloat() / dw
        val sy = sh.toFloat() / dh
        for (y in 0 until dh) {
            val fy = ((y + 0.5f) * sy - 0.5f).coerceIn(0f, (sh - 1).toFloat())
            val y0 = floor(fy).toInt()
            val y1 = min(sh - 1, y0 + 1)
            val ty = fy - y0
            for (x in 0 until dw) {
                val fx = ((x + 0.5f) * sx - 0.5f).coerceIn(0f, (sw - 1).toFloat())
                val x0 = floor(fx).toInt()
                val x1 = min(sw - 1, x0 + 1)
                val tx = fx - x0
                val top = src[y0 * sw + x0] * (1 - tx) + src[y0 * sw + x1] * tx
                val bottom = src[y1 * sw + x0] * (1 - tx) + src[y1 * sw + x1] * tx
                out[y * dw + x] = top * (1 - ty) + bottom * ty
            }
        }
        return out
    }

    fun channel(v: Float): Int = v.roundToInt().coerceIn(0, 255)

    /** Box radius for one of three passes giving a Gaussian of standard deviation sigma. */
    private fun boxRadius(sigma: Double): Int {
        val ideal = sqrt(12.0 * sigma * sigma / 3.0 + 1.0)
        return ((ideal - 1.0) / 2.0).roundToInt()
    }

    private fun boxHorizontal(src: FloatArray, dst: FloatArray, width: Int, height: Int, r: Int) {
        val scale = 1f / (2 * r + 1)
        for (y in 0 until height) {
            val row = y * width
            var sum = 0f
            for (k in -r..r) sum += src[row + k.coerceIn(0, width - 1)]
            for (x in 0 until width) {
                dst[row + x] = sum * scale
                val add = src[row + min(width - 1, x + r + 1)]
                val remove = src[row + max(0, x - r)]
                sum += add - remove
            }
        }
    }

    private fun boxVertical(src: FloatArray, dst: FloatArray, width: Int, height: Int, r: Int) {
        val scale = 1f / (2 * r + 1)
        for (x in 0 until width) {
            var sum = 0f
            for (k in -r..r) sum += src[k.coerceIn(0, height - 1) * width + x]
            for (y in 0 until height) {
                dst[y * width + x] = sum * scale
                val add = src[min(height - 1, y + r + 1) * width + x]
                val remove = src[max(0, y - r) * width + x]
                sum += add - remove
            }
        }
    }
}
