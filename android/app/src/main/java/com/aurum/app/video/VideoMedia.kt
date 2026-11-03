package com.aurum.app.video

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.provider.OpenableColumns
import com.aurum.app.imaging.ImageLoader
import com.aurum.core.AspectPreset
import com.aurum.core.BookendPreset
import com.aurum.core.Clip
import com.aurum.core.ContentCatalogs
import com.aurum.core.MusicSource
import com.aurum.core.MusicTrack
import com.aurum.core.PixelSize
import com.aurum.core.SourceAsset
import com.aurum.core.TemplateDefinition
import com.aurum.core.TemplateMedia
import com.aurum.core.VideoProject
import java.io.File
import java.util.UUID

/** The template, bookend and music catalogues from assets/content (shared with iOS). */
class VideoContent private constructor(context: Context) {
    val templates: List<TemplateDefinition> = read(context, "content/templates.json")?.let(ContentCatalogs::templates).orEmpty()
    val bookends: List<BookendPreset> = read(context, "content/bookends.json")?.let(ContentCatalogs::bookends).orEmpty()
    /** Licensed music isn't bundled yet, so this is empty; imported songs fill the gap, as on iOS. */
    val music: List<MusicTrack> = read(context, "content/music.json")?.let(ContentCatalogs::music).orEmpty()

    companion object {
        @Volatile private var shared: VideoContent? = null

        fun get(context: Context): VideoContent =
            shared ?: synchronized(this) { shared ?: VideoContent(context.applicationContext).also { shared = it } }

        private fun read(context: Context, path: String): String? = runCatching {
            context.assets.open(path).bufferedReader(Charsets.UTF_8).use { it.readText() }
        }.getOrNull()
    }
}

/** A photo or video picked for a video or template (iOS `PickedMedia`). */
data class PickedMedia(
    val uri: Uri,
    val kind: Clip.Kind,
    val pixelSize: PixelSize,
    /** Video length in seconds; 0 for photos. */
    val duration: Double = 0.0,
) {
    val source: SourceAsset get() = SourceAsset(uri.toString(), pixelSize)

    /** The clip this item becomes on a plain timeline. */
    val clip: Clip
        get() = when (kind) {
            Clip.Kind.photo -> Clip.photo(source)
            Clip.Kind.video -> Clip.of(Clip.Kind.video, source, duration)
        }

    val templateMedia: TemplateMedia get() = TemplateMedia(source, kind, duration)
}

/** Reads what the renderer needs to know about picked media, without decoding it. */
object MediaProbe {
    fun probe(context: Context, uri: Uri): PickedMedia? {
        val type = context.contentResolver.getType(uri).orEmpty()
        return if (type.startsWith("video/")) probeVideo(context, uri) else {
            val size = ImageLoader.size(context, uri) ?: return probeVideo(context, uri)
            PickedMedia(uri, Clip.Kind.photo, size)
        }
    }

    private fun probeVideo(context: Context, uri: Uri): PickedMedia? = runCatching {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(context, uri)
            val ms = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: return null
            val w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: return null
            val h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: return null
            val rotation = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            val size = if (rotation % 180 != 0) PixelSize(h, w) else PixelSize(w, h)
            PickedMedia(uri, Clip.Kind.video, size, ms / 1000.0)
        } finally {
            r.release()
        }
    }.getOrNull()

    /** True when the file has an audio track. */
    fun hasAudio(context: Context, uri: Uri): Boolean = runCatching {
        val e = MediaExtractor()
        try {
            e.setDataSource(context, uri, null)
            (0 until e.trackCount).any { e.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true }
        } finally {
            e.release()
        }
    }.getOrDefault(false)

    /** A plain timeline of the picked items, in picking order (iOS `MediaPickerView.project(from:)`). */
    fun project(picked: List<PickedMedia>): VideoProject {
        var project = VideoProject()
        for (item in picked) project = project.append(item.clip)
        // Match the first item's shape so a landscape clip isn't cropped to a story.
        val first = picked.firstOrNull()
        if (first != null && first.pixelSize.aspectRatio > 1.2) project = project.copy(aspect = AspectPreset.landscape)
        return project
    }

    /** A small frame for the timeline: the photo, or the video's frame at [atSeconds]. */
    fun thumbnail(context: Context, clip: Clip, side: Int): Bitmap? {
        val uri = Uri.parse(clip.source.localIdentifier)
        return when (clip.kind) {
            Clip.Kind.photo -> ImageLoader.decode(context, uri, side * 2)
            Clip.Kind.video -> frame(context, uri, clip.sourceTime(0.0), side * 2)
        }
    }

    /** A video frame at [seconds], rotated upright by the retriever, longest side about [maxSide]. */
    fun frame(context: Context, uri: Uri, seconds: Double, maxSide: Int, exact: Boolean = false): Bitmap? = runCatching {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(context, uri)
            val us = (seconds * 1_000_000).toLong().coerceAtLeast(0)
            val option = if (exact) MediaMetadataRetriever.OPTION_CLOSEST else MediaMetadataRetriever.OPTION_CLOSEST_SYNC
            val frame = r.getFrameAtTime(us, option) ?: return null
            val longest = maxOf(frame.width, frame.height)
            if (longest <= maxSide) frame else {
                val s = maxSide.toFloat() / longest
                Bitmap.createScaledBitmap(frame, (frame.width * s).toInt().coerceAtLeast(1), (frame.height * s).toInt().coerceAtLeast(1), true)
                    .also { if (it !== frame) frame.recycle() }
            }
        } finally {
            r.release()
        }
    }.getOrNull()
}

/**
 * Songs the user imported, copied into the app's files (iOS keeps them in
 * Documents/Music), and the file behind a [MusicSource].
 */
object MusicLibrary {
    fun directory(context: Context): File = File(context.filesDir, "Music").apply { mkdirs() }

    /** Imported songs, newest first. */
    fun importedSongs(context: Context): List<File> =
        directory(context).listFiles()?.filter { it.isFile && !it.name.startsWith(".") }?.sortedByDescending { it.lastModified() }.orEmpty()

    /** Copies a picked audio file in and returns its file name. */
    fun importSong(context: Context, uri: Uri): String {
        val resolver = context.contentResolver
        val display = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        } ?: "Song.m4a"
        val safe = display.replace(Regex("[/\\\\:*?\"<>|]"), "_").ifBlank { "Song.m4a" }
        val dir = directory(context)
        var destination = File(dir, safe)
        if (destination.exists()) {
            val stem = safe.substringBeforeLast('.', safe)
            val ext = safe.substringAfterLast('.', "")
            destination = File(dir, "$stem-${UUID.randomUUID().toString().take(4).uppercase()}" + if (ext.isEmpty()) "" else ".$ext")
        }
        resolver.openInputStream(uri)?.use { input ->
            destination.outputStream().use { input.copyTo(it) }
        } ?: throw IllegalStateException("unreadable song")
        return destination.name
    }

    /** The file to play, or null when it's missing (a library track not shipped yet). */
    fun file(context: Context, source: MusicSource, tracks: List<MusicTrack>): File? = when (source) {
        is MusicSource.Imported -> File(directory(context), source.fileName).takeIf { it.exists() }
        is MusicSource.Library -> tracks.firstOrNull { it.id == source.trackID }?.let { track ->
            val name = track.path.substringAfterLast('/')
            listOf(File(context.filesDir, "Music/Library/$name"), File(context.cacheDir, "Music/$name")).firstOrNull { it.exists() }
        }
    }
}
