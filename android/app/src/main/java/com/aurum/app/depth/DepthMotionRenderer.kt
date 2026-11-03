package com.aurum.app.depth

import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Shader
import com.aurum.core.DepthMotion
import com.aurum.core.Seconds
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Renders a 3D photo move, ported from the iOS `DepthMotionRenderer`: the
 * photo is split into a near layer and a far layer by depth, and each moves by
 * a different amount as the virtual camera follows a [DepthMotion.Sample]
 * (parallax). Where the near layer uncovers the background, the gap is filled
 * with a heavily blurred copy of the surroundings rather than a hard edge.
 *
 * The layers are prepared once ([prepare], off the main thread); [draw] then
 * only draws two or three transformed bitmap shaders, so it is cheap enough to
 * run every frame on a hardware canvas (the Compose preview) or a bitmap
 * canvas (the MP4 export). Edges clamp, like `clampedToExtent()`.
 *
 * One instance must be drawn from one thread at a time.
 */
class DepthMotionRenderer private constructor(
    val width: Int,
    val height: Int,
    /** The photo with the near matte as alpha. */
    private val nearLayer: Bitmap,
    /** The photo with the near subject softly painted out. */
    private val farLayer: Bitmap,
    /** [farLayer] blurred at [maxFarBlur], cross-faded in as the focus moves away from it. */
    private val farBlurred: Bitmap?,
    private val maxFarBlur: Double,
    /** The depth used, for preparing a larger renderer at export. */
    val depth: DepthMap,
) {
    private val shortSide = min(width, height).toDouble()
    private val matrix = Matrix()
    private val nearPaint = shaderPaint(nearLayer)
    private val farPaint = shaderPaint(farLayer)
    private val farBlurPaint = farBlurred?.let(::shaderPaint)

    /** Draws one frame of the move filling [outWidth] × [outHeight] (aspect fill, centred). */
    fun draw(canvas: Canvas, outWidth: Float, outHeight: Float, sample: DepthMotion.Sample) {
        val focus = sample.focusDepth
        drawLayer(canvas, farPaint, FAR_DEPTH, sample, outWidth, outHeight)
        // A touch of blur on the far layer when the focus is away from it.
        val farBlur = max(0.0, FAR_DEPTH - focus - 0.3) * shortSide * 0.006
        if (farBlurPaint != null && farBlur > 0.5 && maxFarBlur > 0) {
            farBlurPaint.alpha = (255 * (farBlur / maxFarBlur).coerceIn(0.0, 1.0)).roundToInt()
            drawLayer(canvas, farBlurPaint, FAR_DEPTH, sample, outWidth, outHeight)
        }
        drawLayer(canvas, nearPaint, NEAR_DEPTH, sample, outWidth, outHeight)
    }

    /** The move at time [t] of a loop lasting [duration]. */
    fun draw(canvas: Canvas, outWidth: Float, outHeight: Float, motion: DepthMotion, t: Seconds, duration: Seconds) =
        draw(canvas, outWidth, outHeight, motion.sample(t, duration))

    /**
     * Zooms about the centre and shifts by the camera offset scaled by the
     * layer's distance from the focus, then maps the photo onto the output.
     * DepthMotion's dy points up (Core Image), so it is subtracted here.
     */
    private fun drawLayer(canvas: Canvas, paint: Paint, depth: Double, s: DepthMotion.Sample, outW: Float, outH: Float) {
        val focus = s.focusDepth
        val parallax = (focus - depth) * PARALLAX_GAIN
        val dx = (s.dx * parallax * width).toFloat()
        val dy = (s.dy * parallax * height).toFloat()
        // Near layers grow a little faster with zoom, which reads as depth too.
        val nearness = max(0.0, focus - depth)
        val zoom = (1.0 + (s.zoom - 1.0) * (1.0 + nearness)).toFloat()
        val fill = max(outW / width, outH / height)
        val cx = width / 2f
        val cy = height / 2f
        matrix.reset()
        matrix.postTranslate(-cx, -cy)
        matrix.postScale(zoom * fill, zoom * fill)
        matrix.postTranslate(outW / 2f - dx * fill, outH / 2f - dy * fill)
        paint.shader.setLocalMatrix(matrix)
        canvas.drawRect(0f, 0f, outW, outH, paint)
    }

    companion object {
        /** How strongly a layer's depth difference from the focus turns into movement. */
        const val PARALLAX_GAIN = 2.4
        /** Depth of the near and far layers, 0 nearest, 1 farthest (DepthMotion's convention). */
        const val NEAR_DEPTH = 0.15
        const val FAR_DEPTH = 0.85

        /** Masks and the fill blur are computed at most this large, then stretched; they are soft anyway. */
        private const val MASK_LONGEST_SIDE = 720

        private fun shaderPaint(bitmap: Bitmap) = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG).apply {
            isFilterBitmap = true
            shader = BitmapShader(bitmap, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
        }

        /**
         * Prepares the layers for [image] (an opaque ARGB_8888 bitmap) with
         * [depth], which may be smaller (from the preview proxy): it is stretched
         * over the photo. Blocking and memory-heavy: call it off the main thread.
         * [image] is not kept or recycled.
         */
        fun prepare(image: Bitmap, depth: DepthMap): DepthMotionRenderer {
            val w = image.width
            val h = image.height
            val short = min(w, h).toDouble()

            // Masks at a proxy size.
            val proxyScale = min(1.0, MASK_LONGEST_SIDE.toDouble() / max(w, h))
            val pw = max(1, (w * proxyScale).roundToInt())
            val ph = max(1, (h * proxyScale).roundToInt())
            val proxyShort = min(pw, ph).toDouble()
            val d = DepthImaging.resample(depth.values, depth.width, depth.height, pw, ph)
            // Soft threshold around the middle: near = clamp((d - 0.5) * 4 + 0.5).
            val near = FloatArray(d.size) { ((d[it] - 0.5f) * 4f + 0.5f).coerceIn(0f, 1f) }
            // Grow the matte a little and fill under it with a heavy blur of the
            // surroundings, so moving the subject never reveals a copy of itself.
            val grown = DepthImaging.maximum(near, pw, ph, (proxyShort * 0.025).roundToInt())
            DepthImaging.blur(grown, pw, ph, proxyShort * 0.01)
            val nearFull = DepthImaging.resample(near, pw, ph, w, h)
            val grownFull = DepthImaging.resample(grown, pw, ph, w, h)

            val base = IntArray(w * h)
            image.getPixels(base, 0, w, 0, 0, w, h)

            // Heavy blur of the photo (radius 5% of the short side), at a quarter size.
            val fillScale = 0.25
            val fw = max(1, (w * fillScale).roundToInt())
            val fh = max(1, (h * fillScale).roundToInt())
            val small = Bitmap.createScaledBitmap(image, fw, fh, true)
            val smallPixels = IntArray(fw * fh)
            small.getPixels(smallPixels, 0, fw, 0, 0, fw, fh)
            if (small !== image) small.recycle()
            DepthImaging.blurArgb(smallPixels, fw, fh, short * 0.05 * fillScale)
            val smallBlurred = Bitmap.createBitmap(smallPixels, fw, fh, Bitmap.Config.ARGB_8888)
            val fillBitmap = Bitmap.createScaledBitmap(smallBlurred, w, h, true)
            smallBlurred.recycle()
            val fill = IntArray(w * h)
            fillBitmap.getPixels(fill, 0, w, 0, 0, w, h)
            fillBitmap.recycle()

            // Far layer: the fill blended over the photo through the grown matte.
            val far = IntArray(w * h)
            for (i in far.indices) far[i] = mix(base[i], fill[i], grownFull[i])
            // Near layer: the photo with the near matte as alpha (unpremultiplied ints).
            for (i in base.indices) {
                val a = DepthImaging.channel(nearFull[i] * 255f)
                base[i] = (a shl 24) or (base[i] and 0x00FFFFFF)
            }
            val nearLayer = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888).apply { setPixels(base, 0, w, 0, 0, w, h) }
            val farLayer = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888).apply { setPixels(far, 0, w, 0, 0, w, h) }

            // The strongest far blur any move can ask for (focus at 0).
            val maxFarBlur = (FAR_DEPTH - 0.3) * short * 0.006
            val farBlurred = if (maxFarBlur > 0.5) {
                DepthImaging.blurArgb(far, w, h, maxFarBlur)
                Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888).apply { setPixels(far, 0, w, 0, 0, w, h) }
            } else null

            return DepthMotionRenderer(w, h, nearLayer, farLayer, farBlurred, maxFarBlur, depth)
        }

        private fun mix(a: Int, b: Int, t: Float): Int {
            if (t <= 0f) return a or (0xFF shl 24)
            if (t >= 1f) return b or (0xFF shl 24)
            val u = 1f - t
            val r = ((a shr 16) and 0xFF) * u + ((b shr 16) and 0xFF) * t
            val g = ((a shr 8) and 0xFF) * u + ((b shr 8) and 0xFF) * t
            val bl = (a and 0xFF) * u + (b and 0xFF) * t
            return (0xFF shl 24) or (DepthImaging.channel(r) shl 16) or (DepthImaging.channel(g) shl 8) or DepthImaging.channel(bl)
        }
    }
}
