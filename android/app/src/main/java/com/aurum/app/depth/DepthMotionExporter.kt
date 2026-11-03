package com.aurum.app.depth

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.media.MediaMuxer
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import com.aurum.core.DepthMotion
import com.aurum.core.Seconds
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import java.nio.ByteBuffer
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.util.UUID
import kotlin.coroutines.coroutineContext
import kotlin.math.max
import kotlin.math.min

/**
 * Writes a looping 3D photo move as an H.264 MP4 and saves it to the video
 * library (Movies/AURUM), the counterpart of the iOS `DepthMotionExporter`.
 *
 * Frames are drawn with [DepthMotionRenderer] into a bitmap, converted to
 * YUV 4:2:0 and fed to a `MediaCodec` encoder with exact presentation times,
 * then muxed with `MediaMuxer`. Everything stays on the device.
 */
object DepthMotionExporter {
    class ExportFailed(message: String) : Exception(message)

    const val FRAME_RATE = 30

    /**
     * Renders [duration] seconds (clamped to 3...6) at [width] × [height]
     * (rounded to even pixels) and saves the video. [overlay], such as the
     * free watermark, is drawn on every frame. Returns the saved video.
     */
    suspend fun export(
        context: Context,
        renderer: DepthMotionRenderer,
        motion: DepthMotion,
        duration: Seconds,
        width: Int,
        height: Int,
        overlay: ((Canvas, Float, Float) -> Unit)?,
        progress: (Double) -> Unit,
    ): Uri = withContext(Dispatchers.Default) {
        val temp = File(context.cacheDir, "AURUM-3D-${UUID.randomUUID().toString().take(8)}.mp4")
        try {
            encode(renderer, motion, duration, width, height, overlay, temp, progress)
            withContext(Dispatchers.IO) { save(context, temp) }
        } finally {
            temp.delete()
        }
    }

    private suspend fun encode(
        renderer: DepthMotionRenderer,
        motion: DepthMotion,
        duration: Seconds,
        requestedWidth: Int,
        requestedHeight: Int,
        overlay: ((Canvas, Float, Float) -> Unit)?,
        file: File,
        progress: (Double) -> Unit,
    ) {
        val length = min(max(duration, 3.0), 6.0)
        val (encoderName, format) = chooseEncoder(max(2, requestedWidth / 2 * 2), max(2, requestedHeight / 2 * 2))
        val width = format.getInteger(MediaFormat.KEY_WIDTH)
        val height = format.getInteger(MediaFormat.KEY_HEIGHT)
        val frames = (length * FRAME_RATE).toInt()

        val codec = MediaCodec.createByCodecName(encoderName)
        val muxer = try {
            MediaMuxer(file.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        } catch (e: Exception) {
            codec.release()
            throw e
        }
        var muxerStarted = false
        val frame = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        try {
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
            val canvas = Canvas(frame)
            val pixels = IntArray(width * height)
            val info = MediaCodec.BufferInfo()
            var track = -1
            var index = 0
            var inputDone = false
            var outputDone = false
            while (!outputDone) {
                coroutineContext.ensureActive()
                if (!inputDone) {
                    val input = codec.dequeueInputBuffer(10_000)
                    if (input >= 0) {
                        val pts = index * 1_000_000L / FRAME_RATE
                        if (index >= frames) {
                            codec.queueInputBuffer(input, 0, 0, pts, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            val t = index.toDouble() / FRAME_RATE
                            frame.eraseColor(android.graphics.Color.BLACK)
                            renderer.draw(canvas, width.toFloat(), height.toFloat(), motion, t, length)
                            overlay?.invoke(canvas, width.toFloat(), height.toFloat())
                            frame.getPixels(pixels, 0, width, 0, 0, width, height)
                            val size = writeFrame(codec, input, pixels, width, height)
                            codec.queueInputBuffer(input, 0, size, pts, 0)
                            index++
                            progress(index.toDouble() / frames)
                        }
                    }
                }
                drain@ while (true) {
                    val output = codec.dequeueOutputBuffer(info, if (inputDone) 10_000L else 0L)
                    when {
                        output == MediaCodec.INFO_TRY_AGAIN_LATER -> break@drain
                        output == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            if (muxerStarted) throw ExportFailed("format changed twice")
                            track = muxer.addTrack(codec.outputFormat)
                            muxer.start()
                            muxerStarted = true
                        }
                        output >= 0 -> {
                            val buffer = codec.getOutputBuffer(output) ?: throw ExportFailed("no output buffer")
                            if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) info.size = 0
                            if (info.size > 0) {
                                if (!muxerStarted) throw ExportFailed("muxer not started")
                                buffer.position(info.offset)
                                buffer.limit(info.offset + info.size)
                                muxer.writeSampleData(track, buffer, info)
                            }
                            codec.releaseOutputBuffer(output, false)
                            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                                outputDone = true
                                break@drain
                            }
                        }
                        else -> Unit // INFO_OUTPUT_BUFFERS_CHANGED: nothing to do with getOutputBuffer.
                    }
                }
            }
        } finally {
            runCatching { codec.stop() }
            codec.release()
            if (muxerStarted) runCatching { muxer.stop() }
            runCatching { muxer.release() }
            frame.recycle()
        }
        if (!muxerStarted) throw ExportFailed("nothing was encoded")
    }

    /** An H.264 encoder for the size, falling back to 16-pixel multiples for picky encoders. */
    private fun chooseEncoder(width: Int, height: Int): Pair<String, MediaFormat> {
        val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
        val candidates = listOf(width to height, (width / 16 * 16).coerceAtLeast(16) to (height / 16 * 16).coerceAtLeast(16))
        for ((w, h) in candidates.distinct()) {
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
                setInteger(MediaFormat.KEY_BIT_RATE, w * h * 6)
                setInteger(MediaFormat.KEY_FRAME_RATE, FRAME_RATE)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            }
            val name = list.findEncoderForFormat(format)
            if (name != null) return name to format
        }
        throw ExportFailed("no H.264 encoder for ${width}x$height")
    }

    /** Writes one frame as YUV 4:2:0 (BT.601, video range) into the codec's input. Returns the byte count. */
    private fun writeFrame(codec: MediaCodec, index: Int, argb: IntArray, width: Int, height: Int): Int {
        val image = codec.getInputImage(index)
        if (image != null) {
            val planes = image.planes
            writePlane(planes[0].buffer, planes[0].rowStride, planes[0].pixelStride, width, height) { x, y -> luma(argb[y * width + x]) }
            val cw = width / 2
            val ch = height / 2
            writePlane(planes[1].buffer, planes[1].rowStride, planes[1].pixelStride, cw, ch) { x, y -> chroma(argb, width, x, y, u = true) }
            writePlane(planes[2].buffer, planes[2].rowStride, planes[2].pixelStride, cw, ch) { x, y -> chroma(argb, width, x, y, u = false) }
            return width * height * 3 / 2
        }
        // No Image access: write the codec's reported layout (planar I420 or semi-planar NV12).
        val buffer = codec.getInputBuffer(index) ?: throw ExportFailed("no input buffer")
        buffer.clear()
        val color = runCatching { codec.inputFormat.getInteger(MediaFormat.KEY_COLOR_FORMAT) }.getOrDefault(MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar)
        val planar = color == MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar
        val ySize = width * height
        writePlane(buffer, width, 1, width, height) { x, y -> luma(argb[y * width + x]) }
        val cw = width / 2
        val ch = height / 2
        if (planar) {
            val u = buffer.duplicate().apply { position(ySize) }.slice()
            val v = buffer.duplicate().apply { position(ySize + cw * ch) }.slice()
            writePlane(u, cw, 1, cw, ch) { x, y -> chroma(argb, width, x, y, u = true) }
            writePlane(v, cw, 1, cw, ch) { x, y -> chroma(argb, width, x, y, u = false) }
        } else {
            val uv = buffer.duplicate().apply { position(ySize) }.slice()
            writePlane(uv, width, 2, cw, ch) { x, y -> chroma(argb, width, x, y, u = true) }
            val vv = buffer.duplicate().apply { position(ySize + 1) }.slice()
            writePlane(vv, width, 2, cw, ch) { x, y -> chroma(argb, width, x, y, u = false) }
        }
        return ySize * 3 / 2
    }

    private inline fun writePlane(buffer: ByteBuffer, rowStride: Int, pixelStride: Int, w: Int, h: Int, value: (Int, Int) -> Int) {
        if (pixelStride == 1) {
            val row = ByteArray(w)
            for (y in 0 until h) {
                for (x in 0 until w) row[x] = value(x, y).toByte()
                buffer.position(y * rowStride)
                buffer.put(row, 0, w)
            }
        } else {
            for (y in 0 until h) {
                val start = y * rowStride
                for (x in 0 until w) buffer.put(start + x * pixelStride, value(x, y).toByte())
            }
        }
    }

    private fun luma(c: Int): Int {
        val r = (c shr 16) and 0xFF
        val g = (c shr 8) and 0xFF
        val b = c and 0xFF
        return (((66 * r + 129 * g + 25 * b + 128) shr 8) + 16).coerceIn(0, 255)
    }

    /** U or V for the 2×2 block at chroma position (cx, cy), averaged. */
    private fun chroma(argb: IntArray, width: Int, cx: Int, cy: Int, u: Boolean): Int {
        val i = cy * 2 * width + cx * 2
        var r = 0
        var g = 0
        var b = 0
        for (k in intArrayOf(i, i + 1, i + width, i + width + 1)) {
            val c = argb[k]
            r += (c shr 16) and 0xFF
            g += (c shr 8) and 0xFF
            b += c and 0xFF
        }
        r /= 4; g /= 4; b /= 4
        val v = if (u) ((-38 * r - 74 * g + 112 * b + 128) shr 8) + 128 else ((112 * r - 94 * g - 18 * b + 128) shr 8) + 128
        return v.coerceIn(0, 255)
    }

    private fun fileName(): String =
        "AURUM_3D_" + LocalDateTime.now().format(DateTimeFormatter.ofPattern("yyyyMMdd_HHmmss")) + ".mp4"

    /** Copies the finished movie into Movies/AURUM. Android 8–9 need WRITE_EXTERNAL_STORAGE. */
    private fun save(context: Context, file: File): Uri {
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, fileName())
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
        }
        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            values.put(MediaStore.Video.Media.RELATIVE_PATH, Environment.DIRECTORY_MOVIES + "/AURUM")
            values.put(MediaStore.Video.Media.IS_PENDING, 1)
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            @Suppress("DEPRECATION")
            val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES), "AURUM").apply { mkdirs() }
            @Suppress("DEPRECATION")
            values.put(MediaStore.Video.Media.DATA, File(dir, values.getAsString(MediaStore.Video.Media.DISPLAY_NAME)).absolutePath)
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        }
        val uri = resolver.insert(collection, values) ?: throw ExportFailed("insert failed")
        try {
            resolver.openOutputStream(uri)?.use { out -> file.inputStream().use { it.copyTo(out) } }
                ?: throw ExportFailed("no output stream")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                resolver.update(uri, ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) }, null, null)
            }
            return uri
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
    }
}
