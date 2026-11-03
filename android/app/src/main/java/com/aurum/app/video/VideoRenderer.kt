package com.aurum.app.video

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.media3.common.C
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.SpeedProvider
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.FrameDropEffect
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.Presentation
import androidx.media3.effect.SpeedChangeEffect
import androidx.media3.effect.TextureOverlay
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import com.aurum.app.imaging.ImageLoader
import com.aurum.app.imaging.OverlayPainter
import com.aurum.core.Clip
import com.aurum.core.LookCatalog
import com.aurum.core.PixelSize
import com.aurum.core.StillMotion
import com.aurum.core.VideoProject
import com.aurum.core.VideoRenderPlan
import com.aurum.core.render.VideoGrade
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.coroutineScope
import java.io.File
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.util.UUID
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong

/**
 * Renders a [VideoProject] to an MP4 with Media3 Transformer, the Android
 * counterpart of iOS `VideoCompositionBuilder` + `AurumVideoCompositor` +
 * `VideoExporter`. The same renderer makes the editor's preview (smaller, no
 * mark, layers drawn live by the editor) and the export.
 *
 * One sequence carries the picture and clip sound: intro card, clips (photos
 * as still images, videos trimmed, sped up or slowed down, reversed from a
 * cached reversed copy) and outro card. Music is a second, audio-only
 * sequence with its fades. Every frame then goes through [AurumFrameEffect]
 * (motion, transitions, grade, animated effects) and [FrameOverlay] (cards,
 * layers, watermark).
 */
@UnstableApi
class VideoRenderer(private val context: Context, private val catalog: LookCatalog, private val content: VideoContent) {

    class RenderFailed(message: String, cause: Throwable? = null) : Exception(message, cause)

    data class Settings(
        /** Longest side of the output. */
        val maxPixelSize: Int,
        val frameRate: Int = 30,
        val watermark: String? = null,
        /** False for the preview, where the editor draws layers itself so typing shows at once. */
        val drawLayers: Boolean = true,
        val brandName: String = "AURUM",
    )

    suspend fun render(project: VideoProject, settings: Settings, output: File, onProgress: (Float) -> Unit = {}): File {
        if (project.clips.isEmpty()) throw RenderFailed("empty project")
        val work = File(context.cacheDir, "VideoBuild/" + UUID.randomUUID().toString()).apply { mkdirs() }
        try {
            val composition = withContext(Dispatchers.Default) { buildComposition(project, settings, work) }
            output.parentFile?.mkdirs()
            output.delete()
            withContext(Dispatchers.Main) { runTransformer(composition, output, max(settings.maxPixelSize, 1), onProgress) }
            return output
        } finally {
            withContext(Dispatchers.IO) { work.deleteRecursively() }
        }
    }

    // ---------------------------------------------------------------- composition

    private suspend fun buildComposition(project: VideoProject, settings: Settings, work: File): Composition {
        val size = VideoRenderPlan.renderSize(project.aspect, settings.maxPixelSize)
        val items = VideoRenderPlan.items(project)
        val stills = HashMap<Int, Bitmap>()
        val edited = ArrayList<EditedMediaItem>()
        var black: File? = null

        for (item in items) {
            when (item.kind) {
                VideoRenderPlan.Item.Kind.intro, VideoRenderPlan.Item.Kind.outro -> {
                    val file = black ?: File(work, "black.jpg").also {
                        writeJpeg(Bitmap.createBitmap(16, 16, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.BLACK) }, it)
                        black = it
                    }
                    edited.add(imageItem(file, item.duration, settings.frameRate))
                }
                VideoRenderPlan.Item.Kind.clip -> {
                    val clip = project.clips[item.clipIndex]
                    when (clip.kind) {
                        Clip.Kind.photo -> {
                            val still = still(clip, size) ?: throw RenderFailed("photo unreadable")
                            stills[item.clipIndex] = still
                            val file = File(work, "still-${item.clipIndex}.jpg")
                            writeJpeg(still, file, recycle = false)
                            edited.add(imageItem(file, item.duration, settings.frameRate))
                        }
                        Clip.Kind.video -> edited.add(videoItem(project, clip, item))
                    }
                }
            }
        }

        // The outgoing clip's last frame for each transition.
        val outgoing = HashMap<Int, File>()
        for (w in VideoRenderPlan.transitions(project)) {
            val previous = project.clips[w.clipIndex - 1]
            val frame: Bitmap? = when (previous.kind) {
                Clip.Kind.photo -> stills[w.clipIndex - 1]?.let { zoomed(it, StillMotion.pushIn.transform(w.outgoingLocal / max(previous.duration, 0.01)).first) }
                Clip.Kind.video -> MediaProbe.frame(context, Uri.parse(previous.source.localIdentifier), previous.sourceTime(w.outgoingLocal), max(size.width, size.height), exact = true)
                    ?.let { fill(it, size, recycleSource = true) }
            }
            if (frame != null) {
                val file = File(work, "out-${w.clipIndex}.jpg")
                writeJpeg(frame, file)
                outgoing[w.clipIndex] = file
            }
        }
        stills.values.forEach { it.recycle() }

        val sequences = mutableListOf(EditedMediaItemSequence(edited))
        musicSequence(project)?.let { sequences.add(it) }

        val painter = OverlayPainter(context)
        val videoEffects = mutableListOf<Effect>(
            Presentation.createForWidthAndHeight(size.width, size.height, Presentation.LAYOUT_SCALE_TO_FIT_WITH_CROP),
            AurumFrameEffect(project, VideoGrade.of(project.operations, catalog), outgoing),
        )
        val shown = if (settings.drawLayers) project else project.copy(layers = emptyList())
        if (FrameOverlay.isNeeded(shown, settings.watermark, drawBookends = true)) {
            val overlay = FrameOverlay(shown, size.width, size.height, painter, BookendPainter(painter, settings.brandName), settings.watermark)
            videoEffects.add(OverlayEffect(listOf<TextureOverlay>(overlay)))
        }
        return Composition.Builder(sequences)
            .setEffects(Effects(emptyList(), videoEffects))
            .experimentalSetForceAudioTrack(true)
            .setHdrMode(Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL)
            .build()
    }

    private fun imageItem(file: File, seconds: Double, frameRate: Int): EditedMediaItem {
        val media = MediaItem.Builder()
            .setUri(Uri.fromFile(file))
            .setMimeType(MimeTypes.IMAGE_JPEG)
            .setImageDurationMs(max(1L, (seconds * 1000).roundToLong()))
            .build()
        return EditedMediaItem.Builder(media).setFrameRate(frameRate).build()
    }

    private suspend fun videoItem(project: VideoProject, clip: Clip, item: VideoRenderPlan.Item): EditedMediaItem {
        val original = Uri.parse(clip.source.localIdentifier)
        val uri = if (clip.isReversed) Uri.fromFile(ReversedVideoCache.reversed(context, original)) else original
        val clipping = MediaItem.ClippingConfiguration.Builder()
            .setStartPositionMs((item.sourceStart * 1000).roundToLong().coerceAtLeast(0))
            .setEndPositionMs((item.sourceEnd * 1000).roundToLong().coerceAtLeast(1))
            .build()
        val media = MediaItem.Builder().setUri(uri).setClippingConfiguration(clipping).build()
        // Reversed clips play without sound, as on iOS.
        val keepAudio = clip.volume > 0 && !clip.isReversed && MediaProbe.hasAudio(context, original)
        val audio = mutableListOf<AudioProcessor>()
        val video = mutableListOf<Effect>()
        if (clip.speed != 1.0) {
            val speed = clip.speed.toFloat()
            val provider = object : SpeedProvider {
                override fun getSpeed(timeUs: Long): Float = speed
                override fun getNextSpeedChangeTimeUs(timeUs: Long): Long = C.TIME_UNSET
            }
            if (keepAudio) {
                val pair = Effects.createExperimentalSpeedChangingEffect(provider)
                audio.add(pair.first)
                video.add(pair.second)
            } else {
                video.add(SpeedChangeEffect(speed))
            }
        }
        video.add(FrameDropEffect.createDefaultFrameDropEffect(30f))
        if (keepAudio) {
            val volume = clip.volume.toFloat()
            val index = project.clips.indexOfFirst { it.id == clip.id }
            val fade = if (index > 0) min(clip.transitionIn.duration, clip.duration / 2) else 0.0
            audio.add(GainAudioProcessor { t -> if (fade > 0 && t < fade) (volume * t / fade).toFloat() else volume })
        }
        return EditedMediaItem.Builder(media)
            .setRemoveAudio(!keepAudio)
            .setEffects(Effects(audio, video))
            .build()
    }

    /** Music under everything, from the start, with its fades (iOS inserts it at zero). */
    private fun musicSequence(project: VideoProject): EditedMediaItemSequence? {
        val music = project.music ?: return null
        val file = MusicLibrary.file(context, music.source, content.music) ?: return null
        val musicDuration = runCatching {
            val r = MediaMetadataRetriever()
            try {
                r.setDataSource(file.absolutePath)
                (r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L) / 1000.0
            } finally {
                r.release()
            }
        }.getOrDefault(0.0)
        val total = project.duration
        val length = min(total, max(0.0, musicDuration - music.startOffset))
        if (length <= 0.05) return null
        val clipping = MediaItem.ClippingConfiguration.Builder()
            .setStartPositionMs((music.startOffset * 1000).roundToLong())
            .setEndPositionMs(((music.startOffset + length) * 1000).roundToLong())
            .build()
        val media = MediaItem.Builder().setUri(Uri.fromFile(file)).setClippingConfiguration(clipping).build()
        val gain = GainAudioProcessor { t -> music.gain(t, total).toFloat() }
        val item = EditedMediaItem.Builder(media)
            .setRemoveVideo(true)
            .setEffects(Effects(listOf<AudioProcessor>(gain), emptyList()))
            .build()
        return EditedMediaItemSequence(listOf(item))
    }

    // ---------------------------------------------------------------- pictures

    /** The photo filling the frame (aspect fill), upright. */
    private fun still(clip: Clip, size: PixelSize): Bitmap? {
        val decoded = ImageLoader.decode(context, Uri.parse(clip.source.localIdentifier), (max(size.width, size.height) * 1.15).toInt()) ?: return null
        return fill(decoded, size, recycleSource = true)
    }

    private fun fill(source: Bitmap, size: PixelSize, recycleSource: Boolean): Bitmap {
        val out = Bitmap.createBitmap(size.width, size.height, Bitmap.Config.ARGB_8888)
        val s = max(size.width.toFloat() / source.width, size.height.toFloat() / source.height)
        val w = source.width * s
        val h = source.height * s
        Canvas(out).apply {
            drawColor(Color.BLACK)
            drawBitmap(source, null, RectF((size.width - w) / 2, (size.height - h) / 2, (size.width + w) / 2, (size.height + h) / 2), Paint(Paint.FILTER_BITMAP_FLAG))
        }
        if (recycleSource && source !== out) source.recycle()
        return out
    }

    /** [still] zoomed about its centre by [scale] (the push-in at a moment). */
    private fun zoomed(still: Bitmap, scale: Double): Bitmap {
        val out = Bitmap.createBitmap(still.width, still.height, Bitmap.Config.ARGB_8888)
        val w = (still.width * scale).toFloat()
        val h = (still.height * scale).toFloat()
        Canvas(out).drawBitmap(still, null, RectF((still.width - w) / 2, (still.height - h) / 2, (still.width + w) / 2, (still.height + h) / 2), Paint(Paint.FILTER_BITMAP_FLAG))
        return out
    }

    private fun writeJpeg(bitmap: Bitmap, file: File, recycle: Boolean = true) {
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 92, it) }
        if (recycle) bitmap.recycle()
    }

    // ---------------------------------------------------------------- export

    private suspend fun runTransformer(composition: Composition, output: File, maxPixelSize: Int, onProgress: (Float) -> Unit) = coroutineScope {
        val main = Handler(Looper.getMainLooper())
        var finished: ((Throwable?) -> Unit)? = null
        val listener = object : Transformer.Listener {
            override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                finished?.invoke(null)
            }

            override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                finished?.invoke(RenderFailed("export failed", exportException))
            }
        }
        // HEVC for 4K, H.264 otherwise for the widest sharing compatibility (as iOS).
        val transformer = Transformer.Builder(context)
            .setVideoMimeType(if (maxPixelSize > 1920) MimeTypes.VIDEO_H265 else MimeTypes.VIDEO_H264)
            .setAudioMimeType(MimeTypes.AUDIO_AAC)
            .addListener(listener)
            .build()
        val holder = ProgressHolder()
        val poll = launch {
            while (isActive) {
                delay(150)
                if (transformer.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) onProgress(holder.progress / 100f)
            }
        }
        try {
            suspendCancellableCoroutine<Unit> { cont ->
                finished = { error ->
                    if (cont.isActive) {
                        if (error == null) cont.resume(Unit) else cont.resumeWithException(error)
                    }
                }
                cont.invokeOnCancellation { main.post { runCatching { transformer.cancel() } } }
                transformer.start(composition, output.absolutePath)
            }
        } finally {
            poll.cancel()
        }
        onProgress(1f)
    }

    companion object {
        /** Copies a finished movie into Movies/AURUM. Android 8–9 need WRITE_EXTERNAL_STORAGE. */
        fun saveToMovies(context: Context, file: File): Uri {
            val resolver = context.contentResolver
            val name = "AURUM_" + LocalDateTime.now().format(DateTimeFormatter.ofPattern("yyyyMMdd_HHmmss")) + ".mp4"
            val values = ContentValues().apply {
                put(MediaStore.Video.Media.DISPLAY_NAME, name)
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
                values.put(MediaStore.Video.Media.DATA, File(dir, name).absolutePath)
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI
            }
            val uri = resolver.insert(collection, values) ?: throw RenderFailed("insert failed")
            try {
                resolver.openOutputStream(uri)?.use { out -> file.inputStream().use { it.copyTo(out) } } ?: throw RenderFailed("no output stream")
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
}
