package com.aurum.app.imaging

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import com.aurum.core.CropSpec
import com.aurum.core.EditDocument
import com.aurum.core.render.CropGeometry
import com.aurum.core.render.PixelRenderer

/**
 * The photo pipeline shared by the Studio preview and the export, in the iOS
 * order: looks and adjustments on the whole photo, then straighten, crop,
 * flips and quarter turns. Overlays are drawn afterwards by [OverlayPainter].
 */
object EditRendering {

    /** Looks and adjustments into a new bitmap, then the crop. */
    fun render(renderer: PixelRenderer, document: EditDocument, source: Bitmap, applyCrop: Boolean = true): Bitmap {
        val w = source.width
        val h = source.height
        val pixels = IntArray(w * h)
        source.getPixels(pixels, 0, w, 0, 0, w, h)
        renderer.renderInPlace(document, pixels, w, h)
        val graded = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        graded.setPixels(pixels, 0, w, 0, 0, w, h)
        if (!applyCrop || document.crop.isIdentity) return graded
        val cropped = crop(graded, document.crop)
        if (cropped !== graded) graded.recycle()
        return cropped
    }

    /** Matches iOS `applyCrop`. Core Image's y axis points up, so its counter-clockwise straighten is negated here. */
    fun crop(input: Bitmap, crop: CropSpec): Bitmap {
        if (crop.isIdentity) return input
        var image = input
        if (crop.straightenDegrees != 0.0) {
            val radians = Math.toRadians(crop.straightenDegrees)
            val scale = CropGeometry.straightenScale(image.width.toDouble(), image.height.toDouble(), radians).toFloat()
            val out = Bitmap.createBitmap(image.width, image.height, Bitmap.Config.ARGB_8888)
            val cx = image.width / 2f
            val cy = image.height / 2f
            val m = Matrix().apply {
                postTranslate(-cx, -cy)
                postScale(scale, scale)
                postRotate(-crop.straightenDegrees.toFloat())
                postTranslate(cx, cy)
            }
            Canvas(out).drawBitmap(image, m, Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG))
            image = out
        }
        val r = CropGeometry.pixelRect(crop, image.width, image.height)
        val m = Matrix()
        if (crop.flipHorizontal) m.postScale(-1f, 1f)
        if (crop.flipVertical) m.postScale(1f, -1f)
        if (crop.quarterTurns != 0) m.postRotate(90f * crop.quarterTurns)
        val out = Bitmap.createBitmap(image, r.left, r.top, maxOf(1, r.width), maxOf(1, r.height), m, true)
        if (image !== input && image !== out) image.recycle()
        return out
    }

    /** Scales so the longest side is at most [maxPixelSize]. */
    fun fitting(bitmap: Bitmap, maxPixelSize: Int): Bitmap {
        val longest = maxOf(bitmap.width, bitmap.height)
        if (longest <= maxPixelSize) return bitmap
        val scale = maxPixelSize.toDouble() / longest
        val w = maxOf(1, Math.round(bitmap.width * scale).toInt())
        val h = maxOf(1, Math.round(bitmap.height * scale).toInt())
        val out = Bitmap.createScaledBitmap(bitmap, w, h, true)
        if (out !== bitmap) bitmap.recycle()
        return out
    }
}
