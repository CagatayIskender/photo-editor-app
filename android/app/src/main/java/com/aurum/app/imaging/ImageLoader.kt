package com.aurum.app.imaging

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.net.Uri
import androidx.annotation.RequiresApi
import android.os.Build
import androidx.exifinterface.media.ExifInterface
import com.aurum.core.PixelSize
import kotlin.math.max
import kotlin.math.roundToInt

/** Decodes photos upright (EXIF orientation applied) as software ARGB_8888 bitmaps. */
object ImageLoader {

    /** The photo's upright size in pixels, without decoding it. */
    fun size(context: Context, uri: Uri): PixelSize? {
        val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        // decodeStream returns null when it only reads bounds, so only a missing stream means failure.
        val stream = context.contentResolver.openInputStream(uri) ?: return null
        stream.use { BitmapFactory.decodeStream(it, null, opts) }
        if (opts.outWidth <= 0 || opts.outHeight <= 0) return null
        val turned = orientation(context, uri).let { it.rotation % 180 != 0 }
        return if (turned) PixelSize(opts.outHeight, opts.outWidth) else PixelSize(opts.outWidth, opts.outHeight)
    }

    /** Decodes with the longest side at most [maxPixelSize] (never upscaled). */
    fun decode(context: Context, uri: Uri, maxPixelSize: Int): Bitmap? = runCatching {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) decodeModern(context, uri, maxPixelSize) else decodeLegacy(context, uri, maxPixelSize)
    }.getOrNull()

    @RequiresApi(Build.VERSION_CODES.P)
    private fun decodeModern(context: Context, uri: Uri, maxPixelSize: Int): Bitmap {
        val source = ImageDecoder.createSource(context.contentResolver, uri)
        val bitmap = ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            decoder.isMutableRequired = false
            val w = info.size.width
            val h = info.size.height
            val longest = max(w, h)
            if (longest > maxPixelSize) {
                val scale = maxPixelSize.toDouble() / longest
                decoder.setTargetSize(max(1, (w * scale).roundToInt()), max(1, (h * scale).roundToInt()))
            }
        }
        return ensureArgb(bitmap)
    }

    private fun decodeLegacy(context: Context, uri: Uri, maxPixelSize: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxPixelSize) sample *= 2
        val opts = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val raw = context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, opts) } ?: return null
        val o = orientation(context, uri)
        val longest = max(raw.width, raw.height)
        val scale = if (longest > maxPixelSize) maxPixelSize.toFloat() / longest else 1f
        if (o.rotation == 0 && !o.mirror && scale == 1f) return raw
        val m = Matrix().apply {
            postScale(if (o.mirror) -scale else scale, scale)
            postRotate(o.rotation.toFloat())
        }
        val out = Bitmap.createBitmap(raw, 0, 0, raw.width, raw.height, m, true)
        if (out !== raw) raw.recycle()
        return ensureArgb(out)
    }

    private data class Orientation(val rotation: Int, val mirror: Boolean)

    private fun orientation(context: Context, uri: Uri): Orientation = runCatching {
        context.contentResolver.openInputStream(uri)?.use { stream ->
            when (ExifInterface(stream).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
                ExifInterface.ORIENTATION_ROTATE_90 -> Orientation(90, false)
                ExifInterface.ORIENTATION_ROTATE_180 -> Orientation(180, false)
                ExifInterface.ORIENTATION_ROTATE_270 -> Orientation(270, false)
                ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> Orientation(0, true)
                ExifInterface.ORIENTATION_FLIP_VERTICAL -> Orientation(180, true)
                ExifInterface.ORIENTATION_TRANSPOSE -> Orientation(90, true)
                ExifInterface.ORIENTATION_TRANSVERSE -> Orientation(270, true)
                else -> Orientation(0, false)
            }
        }
    }.getOrNull() ?: Orientation(0, false)

    private fun ensureArgb(bitmap: Bitmap): Bitmap {
        if (bitmap.config == Bitmap.Config.ARGB_8888) return bitmap
        val copy = bitmap.copy(Bitmap.Config.ARGB_8888, false)
        bitmap.recycle()
        return copy
    }
}
