package com.aurum.core.render

import com.aurum.core.LookApplication
import com.aurum.core.LookCatalog

/**
 * A look's colour recipe baked into a small 3D lookup table, cheap enough to
 * grade a camera frame on every callback. Only the colour part of the look is
 * baked (exposure, tone, saturation, temperature, split tint, fade); the
 * spatial effects (bloom, light leak, vignette, grain) are left to the
 * captured photo in the Studio, which wears the same look.
 *
 * Unlike [Lut3D] this keeps no scratch state and allocates nothing per pixel,
 * so one table can be applied from a single analysis thread while another
 * thread swaps in a new table.
 */
class LiveLut private constructor(private val n: Int, private val data: FloatArray) {

    /** Grades packed ARGB [pixels] in place. Alpha is kept. */
    fun apply(pixels: IntArray, count: Int) {
        val m = (n - 1).toFloat()
        val inv = m / 255f
        val last = n - 2
        val sr = 3
        val sg = 3 * n
        val sb = 3 * n * n
        for (i in 0 until count) {
            val p = pixels[i]
            val fr = ((p shr 16) and 0xff) * inv
            val fg = ((p shr 8) and 0xff) * inv
            val fb = (p and 0xff) * inv
            var r0 = fr.toInt(); if (r0 > last) r0 = last
            var g0 = fg.toInt(); if (g0 > last) g0 = last
            var b0 = fb.toInt(); if (b0 > last) b0 = last
            val dr = fr - r0
            val dg = fg - g0
            val db = fb - b0
            val base = r0 * sr + g0 * sg + b0 * sb
            var packed = p and -0x1000000
            for (ch in 0 until 3) {
                val o = base + ch
                val c00 = data[o] + (data[o + sr] - data[o]) * dr
                val c10 = data[o + sg] + (data[o + sg + sr] - data[o + sg]) * dr
                val c01 = data[o + sb] + (data[o + sb + sr] - data[o + sb]) * dr
                val c11 = data[o + sb + sg] + (data[o + sb + sg + sr] - data[o + sb + sg]) * dr
                val c0 = c00 + (c10 - c00) * dg
                val c1 = c01 + (c11 - c01) * dg
                val v = c0 + (c1 - c0) * db
                val q = (v.coerceIn(0f, 1f) * 255f + 0.5f).toInt()
                packed = packed or (q shl (16 - 8 * ch))
            }
            pixels[i] = packed
        }
    }

    /** One colour through the table, components 0...1 (for tests). */
    fun lookup(r: Float, g: Float, b: Float): FloatArray {
        val px = intArrayOf(
            (0xff shl 24) or ((r.coerceIn(0f, 1f) * 255f + 0.5f).toInt() shl 16) or
                ((g.coerceIn(0f, 1f) * 255f + 0.5f).toInt() shl 8) or (b.coerceIn(0f, 1f) * 255f + 0.5f).toInt(),
        )
        apply(px, 1)
        return floatArrayOf(((px[0] shr 16) and 0xff) / 255f, ((px[0] shr 8) and 0xff) / 255f, (px[0] and 0xff) / 255f)
    }

    companion object {
        const val SIZE = 25

        /**
         * The colour part of [application] (look, intensity and Refine overrides)
         * as a table, or null when the look is unknown or has no effect.
         */
        fun forLook(renderer: PixelRenderer, catalog: LookCatalog, application: LookApplication): LiveLut? {
            if (application.intensity <= 0) return null
            val recipe = catalog.look(application.lookID) ?: return null
            val p = recipe.params.applying(application.refine)
            val t = application.intensity
            val data = FloatArray(SIZE * SIZE * SIZE * 3)
            val m = (SIZE - 1).toDouble()
            var k = 0
            for (bi in 0 until SIZE) for (gi in 0 until SIZE) for (ri in 0 until SIZE) {
                val r = ri / m
                val g = gi / m
                val b = bi / m
                val out = renderer.lookColour(p, r, g, b)
                data[k++] = (r + (out[0] - r) * t).toFloat()
                data[k++] = (g + (out[1] - g) * t).toFloat()
                data[k++] = (b + (out[2] - b) * t).toFloat()
            }
            return LiveLut(SIZE, data)
        }
    }
}
