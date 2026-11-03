package com.aurum.app.collage

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.graphics.RectF
import com.aurum.core.Carousel
import com.aurum.core.CollageCellGeometry
import com.aurum.core.CollageLayout
import com.aurum.core.CollageProject
import com.aurum.core.NormalizedRect
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Renders a [CollageProject] with the Android canvas. Layout rects are
 * normalised with a top-left origin, as everywhere in AURUM, so no flipping is
 * needed here. Photos are placed with [CollageCellGeometry], the same maths the
 * on-screen editor uses, so what the user frames is what exports.
 */
object CollageRenderer {

    /** Canvas size for a layout, with the longest side [longestSide] pixels. */
    fun canvasSize(layout: CollageLayout, longestSide: Int): Pair<Int, Int> {
        val r = layout.canvasRatio
        return if (r >= 1) {
            longestSide to max(1, (longestSide / r).roundToInt())
        } else {
            max(1, (longestSide * r).roundToInt()) to longestSide
        }
    }

    /** "#RRGGBB" as an opaque ARGB colour; black if the text isn't a colour. */
    fun color(hex: String): Int {
        val normalized = CollageProject.normalizedHex(hex) ?: return Color.BLACK
        return Color.parseColor(normalized)
    }

    /** A normalised, top-left rect in canvas pixels, rounded outwards to whole pixels. */
    fun pixelRect(r: NormalizedRect, width: Int, height: Int): Rect = Rect(
        Math.round((r.x * width).toFloat()),
        Math.round((r.y * height).toFloat()),
        Math.round(((r.x + r.width) * width).toFloat()),
        Math.round(((r.y + r.height) * height).toFloat()),
    )

    /**
     * The collage at [width] x [height]. [imageFor] returns the decoded photo
     * for a cell index (or null to leave the background showing); each bitmap is
     * recycled as soon as it has been drawn so only one photo is in memory at a time.
     */
    fun render(project: CollageProject, width: Int, height: Int, imageFor: (Int) -> Bitmap?): Bitmap {
        val output = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        canvas.drawColor(color(project.backgroundHex))
        val radius = (project.cornerRadius * min(width, height)).toFloat()
        val photoPaint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG or Paint.DITHER_FLAG)
        val maskPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.BLACK
            xfermode = PorterDuffXfermode(PorterDuff.Mode.CLEAR)
        }
        project.frames.forEachIndexed { index, frame ->
            val cell = project.cells.getOrNull(index) ?: return@forEachIndexed
            val rect = pixelRect(frame, width, height)
            if (rect.width() < 1 || rect.height() < 1) return@forEachIndexed
            val image = imageFor(index) ?: return@forEachIndexed
            try {
                val place = CollageCellGeometry.imageFrame(
                    rect.width().toDouble(), rect.height().toDouble(),
                    image.width.toDouble(), image.height.toDouble(),
                    cell.zoom, cell.center,
                )
                val dest = RectF(
                    (rect.left + place.x).toFloat(), (rect.top + place.y).toFloat(),
                    (rect.left + place.maxX).toFloat(), (rect.top + place.maxY).toFloat(),
                )
                val bounds = RectF(rect)
                val corner = min(radius, min(rect.width(), rect.height()) / 2f)
                val save = canvas.saveLayer(bounds, null)
                canvas.clipRect(bounds)
                canvas.drawBitmap(image, null, dest, photoPaint)
                if (corner > 0.5f) {
                    // Clear everything outside the rounded rect, anti-aliased, inside this layer only.
                    val outside = Path().apply {
                        addRoundRect(bounds, corner, corner, Path.Direction.CW)
                        fillType = Path.FillType.INVERSE_EVEN_ODD
                    }
                    canvas.drawPath(outside, maskPaint)
                }
                canvas.restoreToCount(save)
            } finally {
                image.recycle()
            }
        }
        return output
    }
}

/** Cuts one wide photo into carousel panels. */
object CarouselRenderer {

    /**
     * Pixel rects (in [imageWidth] x [imageHeight]) of [count] panels of
     * [panelAspect] (width / height), left to right. Neighbouring rects share
     * edges exactly, so the panels line up seamlessly when swiped.
     */
    fun panelRects(imageWidth: Int, imageHeight: Int, count: Int, panelAspect: Double): List<Rect> {
        if (imageWidth <= 0 || imageHeight <= 0) return emptyList()
        val rects = Carousel.panels(imageWidth.toDouble() / imageHeight, count, panelAspect)
        return rects.map { r ->
            Rect(
                Math.round((r.x * imageWidth).toFloat()).coerceIn(0, imageWidth),
                Math.round((r.y * imageHeight).toFloat()).coerceIn(0, imageHeight),
                Math.round(((r.x + r.width) * imageWidth).toFloat()).coerceIn(0, imageWidth),
                Math.round(((r.y + r.height) * imageHeight).toFloat()).coerceIn(0, imageHeight),
            )
        }.filter { it.width() > 0 && it.height() > 0 }
    }

    /** Panel [rect] of [source] as its own bitmap, scaled so its longest side is at most [maxSide] (never upscaled). */
    fun cut(source: Bitmap, rect: Rect, maxSide: Int): Bitmap {
        val longest = max(rect.width(), rect.height())
        val scale = if (longest > maxSide) maxSide.toFloat() / longest else 1f
        val w = max(1, (rect.width() * scale).roundToInt())
        val h = max(1, (rect.height() * scale).roundToInt())
        val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        Canvas(out).drawBitmap(source, rect, Rect(0, 0, w, h), Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG))
        return out
    }
}
