package com.aurum.app.video

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Rect
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.net.Uri
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import java.security.MessageDigest
import kotlin.coroutines.coroutineContext
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Reversed copies of videos, made once and kept in the cache (iOS
 * `ReversedVideoCache`). Media3 can't play a track backwards, so the frames
 * are read from the end with MediaMetadataRetriever and encoded again, video
 * only: reversed clips play without sound, as on iOS.
 */
object ReversedVideoCache {
    private val lock = Mutex()
    private const val MAX_SIDE = 1920
    private const val FRAME_RATE = 30

    suspend fun reversed(context: Context, uri: Uri): File = lock.withLock {
        val dir = File(context.cacheDir, "Reversed").apply { mkdirs() }
        val out = File(dir, key(uri.toString()) + ".mp4")
        if (out.exists() && out.length() > 0) return out
        val partial = File(dir, out.name + ".part")
        try {
            render(context, uri, partial)
            if (!partial.renameTo(out)) throw IllegalStateException("rename failed")
        } finally {
            partial.delete()
        }
        out
    }

    private fun key(id: String): String =
        MessageDigest.getInstance("SHA-1").digest(id.toByteArray()).joinToString("") { "%02x".format(it) }.take(24)

    private suspend fun render(context: Context, uri: Uri, out: File) {
        val retriever = MediaMetadataRetriever()
        var encoder: MediaCodec? = null
        var muxer: MediaMuxer? = null
        try {
            retriever.setDataSource(context, uri)
            val durationUs = (retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L) * 1000
            if (durationUs <= 0) throw IllegalStateException("no duration")
            val first = retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC) ?: throw IllegalStateException("no frame")
            val scale = min(1f, MAX_SIDE.toFloat() / max(first.width, first.height))
            val w = ((first.width * scale) / 2).roundToInt() * 2
            val h = ((first.height * scale) / 2).roundToInt() * 2
            first.recycle()

            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, (w * h * FRAME_RATE * 0.2).toInt().coerceAtLeast(2_000_000))
                setInteger(MediaFormat.KEY_FRAME_RATE, FRAME_RATE)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            }
            val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            encoder = codec
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val surface = codec.createInputSurface()
            codec.start()
            val mux = MediaMuxer(out.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            muxer = mux

            val frameUs = 1_000_000L / FRAME_RATE
            val count = max(1, (durationUs / frameUs).toInt())
            val info = MediaCodec.BufferInfo()
            var track = -1
            var written = 0
            val dst = Rect(0, 0, w, h)

            fun drain(endOfStream: Boolean) {
                while (true) {
                    val index = codec.dequeueOutputBuffer(info, if (endOfStream) 10_000 else 0)
                    if (index == MediaCodec.INFO_TRY_AGAIN_LATER) {
                        if (!endOfStream) return
                        continue
                    }
                    if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        track = mux.addTrack(codec.outputFormat)
                        mux.start()
                        continue
                    }
                    if (index < 0) continue
                    val buffer = codec.getOutputBuffer(index)
                    val isConfig = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                    if (buffer != null && info.size > 0 && !isConfig && track >= 0) {
                        // Frames were drawn in order; give them even timestamps (the surface clock isn't ours).
                        info.presentationTimeUs = written * frameUs
                        written += 1
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        mux.writeSampleData(track, buffer, info)
                    }
                    codec.releaseOutputBuffer(index, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                }
            }

            for (i in count - 1 downTo 0) {
                coroutineContext.ensureActive()
                val time = min(durationUs - 1, i * frameUs)
                val frame: Bitmap = retriever.getFrameAtTime(time, MediaMetadataRetriever.OPTION_CLOSEST) ?: continue
                val canvas = surface.lockHardwareCanvas()
                canvas.drawBitmap(frame, null, dst, null)
                surface.unlockCanvasAndPost(canvas)
                frame.recycle()
                drain(false)
            }
            codec.signalEndOfInputStream()
            drain(true)
            surface.release()
        } finally {
            runCatching { encoder?.stop() }
            runCatching { encoder?.release() }
            runCatching { muxer?.stop() }
            runCatching { muxer?.release() }
            retriever.release()
        }
    }
}
