package com.aurum.app.imaging

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import com.aurum.core.EditDocument
import com.aurum.core.ExportDecision
import com.aurum.core.render.PixelRenderer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Renders a full edit and saves it to the photo library (Pictures/AURUM) as
 * JPEG, applying the export rules from [com.aurum.core.ExportGate]: free
 * exports are at most 2048 px on the long side with the watermark; members
 * export at full resolution, limited only by the memory this device gives us.
 */
class PhotoExporter(
    private val context: Context,
    private val renderer: PixelRenderer,
    private val painter: OverlayPainter,
    private val watermarkText: String,
) {
    class ExportFailed(message: String) : Exception(message)

    suspend fun export(document: EditDocument, source: Uri, decision: ExportDecision.Allowed): Uri = withContext(Dispatchers.Default) {
        val full = ImageLoader.size(context, source) ?: throw ExportFailed("unreadable source")
        val decodeLimit = decodeLongEdge(full.width, full.height, document, decision.maxPixelSize)
        val photo = ImageLoader.decode(context, source, decodeLimit) ?: throw ExportFailed("decode failed")
        var image = EditRendering.render(renderer, document, photo)
        if (image !== photo) photo.recycle()
        decision.maxPixelSize?.let { image = EditRendering.fitting(image, it) }

        val needsOverlay = decision.watermark || document.overlays.any { !it.isHidden }
        if (needsOverlay) {
            val canvasBitmap = if (image.isMutable) image else image.copy(Bitmap.Config.ARGB_8888, true).also { image.recycle() }
            painter.draw(
                Canvas(canvasBitmap), document.overlays,
                canvasBitmap.width.toFloat(), canvasBitmap.height.toFloat(),
                if (decision.watermark) watermarkText else null,
            )
            image = canvasBitmap
        }
        try {
            withContext(Dispatchers.IO) { save(image) }
        } finally {
            image.recycle()
        }
    }

    /**
     * How large to decode the photo. Free exports only need enough pixels for
     * a 2048 px result after the crop; member exports use full resolution
     * unless that would not fit in memory.
     */
    private fun decodeLongEdge(width: Int, height: Int, document: EditDocument, maxPixelSize: Int?): Int {
        val longest = max(width, height)
        var limit = longest
        if (maxPixelSize != null) {
            val r = document.crop.rect
            val fraction = min(r.width, r.height).coerceIn(0.05, 1.0)
            limit = min(longest, ceil(maxPixelSize / fraction).toInt())
        }
        // About 24 bytes per pixel at peak: source bitmap, pixel array, graded bitmap,
        // cropped copy and two float planes for blurs.
        val budget = Runtime.getRuntime().maxMemory() * 0.6
        val maxPixels = budget / 24.0
        val aspect = width.toDouble() / height
        val maxLongest = if (aspect >= 1) sqrt(maxPixels * aspect) else sqrt(maxPixels / aspect)
        return min(limit, maxLongest.toInt()).coerceAtLeast(256)
    }

    private fun fileName(): String =
        "AURUM_" + LocalDateTime.now().format(DateTimeFormatter.ofPattern("yyyyMMdd_HHmmss")) + ".jpg"

    private fun save(bitmap: Bitmap): Uri {
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, fileName())
            put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
        }
        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            values.put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/AURUM")
            values.put(MediaStore.Images.Media.IS_PENDING, 1)
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            // Android 8 and 9: needs WRITE_EXTERNAL_STORAGE, requested by the export sheet.
            @Suppress("DEPRECATION")
            val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "AURUM").apply { mkdirs() }
            @Suppress("DEPRECATION")
            values.put(MediaStore.Images.Media.DATA, File(dir, values.getAsString(MediaStore.Images.Media.DISPLAY_NAME)).absolutePath)
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        }
        val uri = resolver.insert(collection, values) ?: throw ExportFailed("insert failed")
        try {
            resolver.openOutputStream(uri)?.use { out ->
                if (!bitmap.compress(Bitmap.CompressFormat.JPEG, 92, out)) throw ExportFailed("encode failed")
            } ?: throw ExportFailed("no output stream")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                resolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
            }
            return uri
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
    }
}
