package com.aurum.app.ui.video

import android.content.Context
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import com.aurum.app.AppContainer
import com.aurum.app.video.VideoContent
import com.aurum.app.video.VideoRenderer
import com.aurum.core.AnimatedEffect
import com.aurum.core.AspectPreset
import com.aurum.core.BookendEffect
import com.aurum.core.BookendPreset
import com.aurum.core.Clip
import com.aurum.core.EditOperation
import com.aurum.core.LookApplication
import com.aurum.core.MusicSelection
import com.aurum.core.MusicSource
import com.aurum.core.MusicTrack
import com.aurum.core.OperationKind
import com.aurum.core.Overlay
import com.aurum.core.OverlayContent
import com.aurum.core.LayerAnimation
import com.aurum.core.Seconds
import com.aurum.core.TextOverlay
import com.aurum.core.TimedLayer
import com.aurum.core.Transition
import com.aurum.core.Undoable
import com.aurum.core.VideoExportRules
import com.aurum.core.VideoProject
import com.aurum.core.wholeSeconds
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.File
import java.time.Instant
import java.util.UUID
import kotlin.math.max
import kotlin.math.min
import kotlin.random.Random

/** The tools on the video editor's rail, in rail order. Split and Reverse act at once; the others open a sheet. */
enum class VideoTool(val titleKey: String) {
    trim("Trim"), split("Split"), speed("Speed"), reverse("Reverse"), volume("Volume"), transition("Transition"),
    music("Music"), text("Text"), effects("Effects"), look("Look"), bookends("Intro/Outro"), aspect("Aspect");

    val isAction: Boolean get() = this == split || this == reverse
    val needsClip: Boolean get() = this in setOf(trim, split, speed, reverse, volume, transition)
}

/** The transitions offered in the editor. */
enum class TransitionChoice(val titleKey: String) {
    cut("Cut"), dissolve("Dissolve"), dipToBlack("Dip to black"), slide("Slide"), zoom("Zoom");

    fun transition(duration: Seconds = DEFAULT_DURATION): Transition = when (this) {
        cut -> Transition.Cut
        dissolve -> Transition.Dissolve(duration)
        dipToBlack -> Transition.DipToBlack(duration)
        slide -> Transition.Slide(duration)
        zoom -> Transition.Zoom(duration)
    }

    companion object {
        const val DEFAULT_DURATION: Seconds = 0.5
        fun of(t: Transition) = when (t) {
            Transition.Cut -> cut
            is Transition.Dissolve -> dissolve
            is Transition.DipToBlack -> dipToBlack
            is Transition.Slide -> slide
            is Transition.Zoom -> zoom
        }
    }
}

/**
 * All editing state for one video (iOS `VideoEditorViewModel`). Every change
 * goes through an [Undoable], so undo covers clips, music, layers and grade.
 *
 * The preview is rendered with the export pipeline at a small size a moment
 * after the last edit (so a run of quick changes costs one render) and
 * played by ExoPlayer; the old preview keeps playing while the new one
 * renders. Text and sticker layers are drawn live over the player by the
 * screen, so typing shows at once. Continuous gestures call
 * [beginInteraction], any number of edits, then [endInteraction].
 */
@UnstableApi
class VideoEditorModel(context: Context, val container: AppContainer, initial: VideoProject) {
    private val app = context.applicationContext
    val content = VideoContent.get(app)
    val catalog = container.catalog
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val renderer = VideoRenderer(app, catalog, content)
    private val history = Undoable(initial)

    var project by mutableStateOf(initial)
        private set

    /** The project as it was last exported; closing without changes since then needs no warning. */
    var lastSavedProject: VideoProject? = null
    var canUndo by mutableStateOf(false)
        private set
    var canRedo by mutableStateOf(false)
        private set
    var activeTool by mutableStateOf<VideoTool?>(null)
    var selectedClipID by mutableStateOf(initial.clips.firstOrNull()?.id)
    var selectedLayerID by mutableStateOf<UUID?>(null)
    var selectedEffectID by mutableStateOf<UUID?>(null)
    var playhead by mutableStateOf(0.0)
        private set
    var isPlaying by mutableStateOf(false)
        private set
    var isBuilding by mutableStateOf(false)
        private set
    var hasPreview by mutableStateOf(false)
        private set
    var previewFailed by mutableStateOf(false)
        private set
    var isExportPresented by mutableStateOf(false)

    val player: ExoPlayer = ExoPlayer.Builder(app).build()

    private var isInteracting = false
    private var rebuildJob: Job? = null
    private var tickJob: Job? = null
    private var builtKey: VideoProject? = null
    private var previewFile: File? = null
    private var previewCounter = 0
    private var isClosed = false

    val duration: Seconds get() = project.duration

    init {
        player.repeatMode = Player.REPEAT_MODE_OFF
        player.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                if (playbackState == Player.STATE_ENDED) {
                    this@VideoEditorModel.isPlaying = false
                    tickJob?.cancel()
                    playhead = max(0.0, project.duration - 0.01)
                }
            }
        })
        scheduleRebuild(immediately = true)
    }

    // ---------------------------------------------------------------- editing

    /** Applies a change as one undo step (or as part of the open interaction). */
    fun edit(change: (VideoProject) -> VideoProject) {
        val p = change(project)
        if (p == project) return
        val stamped = p.copy(modifiedAt = Instant.now().wholeSeconds)
        if (isInteracting) history.update(stamped) else history.commit(stamped)
        projectDidChange()
    }

    fun beginInteraction() {
        if (isInteracting) return
        isInteracting = true
        history.beginTransaction()
    }

    fun endInteraction() {
        if (!isInteracting) return
        isInteracting = false
        history.commit(history.current)
        projectDidChange()
    }

    fun undo() {
        history.undo() ?: return
        projectDidChange()
    }

    fun redo() {
        history.redo() ?: return
        projectDidChange()
    }

    private fun projectDidChange() {
        project = history.current
        canUndo = history.canUndo
        canRedo = history.canRedo
        if (selectedClipID != null && project.clips.none { it.id == selectedClipID }) selectedClipID = project.clips.firstOrNull()?.id
        if (selectedLayerID != null && project.layers.none { it.id == selectedLayerID }) selectedLayerID = null
        if (selectedEffectID != null && project.effects.none { it.id == selectedEffectID }) selectedEffectID = null
        playhead = min(playhead, max(0.0, project.duration - 0.01))
        scheduleRebuild()
    }

    // ---------------------------------------------------------------- clips

    val selectedClip: Clip? get() = selectedClipID?.let { id -> project.clips.firstOrNull { it.id == id } }
    val selectedClipIndex: Int? get() = selectedClipID?.let { id -> project.clips.indexOfFirst { it.id == id }.takeIf { it >= 0 } }

    /** Sets the selected clip's in and out points, in source seconds. */
    fun trimSelected(start: Seconds, end: Seconds) {
        val id = selectedClipID ?: return
        edit { it.updateClip(id) { c -> c.trimmed(start, end) } }
    }

    /** Sets a photo's length on the timeline. */
    fun setPhotoLength(value: Seconds) {
        val id = selectedClipID ?: return
        edit { it.updateClip(id) { c -> c.copy(sourceDuration = max(value, Clip.MINIMUM_DURATION)).trimmed(0.0, value) } }
    }

    /** Cuts the clip under the playhead in two. Returns false when the playhead is too close to either end. */
    fun splitAtPlayhead(): Boolean {
        val p = project.split(playhead) ?: return false
        p.clipAt(playhead)?.let { (index, _) -> selectedClipID = p.clips[index].id }
        edit { p }
        return true
    }

    fun moveSelectedClip(offset: Int) {
        val index = selectedClipIndex ?: return
        val destination = index + offset
        if (destination !in project.clips.indices) return
        edit { it.moveClip(index, destination) }
    }

    /** Deletes the selected clip. The last clip can't be deleted; a video needs one. */
    fun deleteSelectedClip() {
        val id = selectedClipID ?: return
        if (project.clips.size <= 1) return
        val index = selectedClipIndex ?: 0
        edit { p ->
            val removed = p.removeClip(id)
            // The new first clip never starts with a transition.
            if (removed.clips.isEmpty()) removed
            else removed.copy(clips = listOf(removed.clips[0].copy(transitionIn = Transition.Cut)) + removed.clips.drop(1))
        }
        selectedClipID = project.clips[min(index, project.clips.size - 1)].id
    }

    val canDeleteClip: Boolean get() = selectedClipID != null && project.clips.size > 1

    fun setSpeed(speed: Double) {
        val id = selectedClipID ?: return
        edit { it.updateClip(id) { c -> c.withSpeed(speed) } }
    }

    /** Reverses the selected video clip. Photos have nothing to reverse. */
    fun toggleReverse() {
        val clip = selectedClip ?: return
        if (clip.kind != Clip.Kind.video) return
        edit { it.updateClip(clip.id) { c -> c.copy(isReversed = !c.isReversed) } }
    }

    fun setVolume(volume: Double) {
        val id = selectedClipID ?: return
        edit { it.updateClip(id) { c -> c.copy(volume = volume.coerceIn(0.0, 1.0)) } }
    }

    /** Sets the transition into the selected clip. The first clip has none. */
    fun setTransition(choice: TransitionChoice) {
        val index = selectedClipIndex ?: return
        if (index <= 0) return
        val id = project.clips[index].id
        edit { it.updateClip(id) { c -> c.copy(transitionIn = choice.transition()) } }
    }

    fun setAspect(aspect: AspectPreset) = edit { it.copy(aspect = aspect) }

    // ---------------------------------------------------------------- music

    fun setMusic(music: MusicSelection?) = edit { it.copy(music = music) }

    fun useLibraryTrack(track: MusicTrack) =
        setMusic(MusicSelection(MusicSource.Library(track.id), track.title, volume = project.music?.volume ?: 0.8, beats = track.beats))

    fun useImportedSong(fileName: String, beats: com.aurum.core.BeatGrid?) =
        setMusic(MusicSelection(MusicSource.Imported(fileName), fileName.substringBeforeLast('.', fileName), volume = project.music?.volume ?: 0.8, beats = beats))

    fun setMusicVolume(volume: Double) = edit { p -> p.music?.let { p.copy(music = it.copy(volume = volume.coerceIn(0.0, 1.0))) } ?: p }

    // ---------------------------------------------------------------- intro and outro

    val introPresets: List<BookendPreset> get() = content.bookends.filter { it.kind == BookendPreset.Kind.intro }
    val outroPresets: List<BookendPreset> get() = content.bookends.filter { it.kind == BookendPreset.Kind.outro }

    fun setIntro(preset: BookendPreset?) = edit { p -> p.copy(intro = preset?.let { BookendEffect(it.id, it.duration, p.intro?.title) }) }
    fun setOutro(preset: BookendPreset?) = edit { p -> p.copy(outro = preset?.let { BookendEffect(it.id, it.duration, p.outro?.title) }) }

    fun setBookendTitle(title: String, intro: Boolean) {
        val value = title.ifEmpty { null }
        edit { p -> if (intro) p.copy(intro = p.intro?.copy(title = value)) else p.copy(outro = p.outro?.copy(title = value)) }
    }

    // ---------------------------------------------------------------- text layers

    val selectedLayer: TimedLayer? get() = selectedLayerID?.let { id -> project.layers.firstOrNull { it.id == id } }

    /** Adds a text layer at the playhead, shown for three seconds. */
    fun addText(text: String): UUID {
        val start = min(playhead, max(0.0, duration - Clip.MINIMUM_DURATION))
        val end = min(start + 3, max(duration, start + Clip.MINIMUM_DURATION))
        val layer = TimedLayer.of(Overlay(content = OverlayContent.Text(TextOverlay(text = text))), start, end, LayerAnimation.rise, LayerAnimation.fade)
        edit { it.copy(layers = it.layers + layer) }
        selectedLayerID = layer.id
        return layer.id
    }

    fun updateSelectedLayer(change: (TimedLayer) -> TimedLayer) {
        val id = selectedLayerID ?: return
        edit { p -> p.copy(layers = p.layers.map { if (it.id == id) change(it) else it }) }
    }

    fun updateSelectedText(change: (TextOverlay) -> TextOverlay) = updateSelectedLayer { layer ->
        val c = layer.overlay.content as? OverlayContent.Text ?: return@updateSelectedLayer layer
        layer.copy(overlay = layer.overlay.copy(content = OverlayContent.Text(change(c.text))))
    }

    /** Starts or ends the selected layer at the playhead. */
    fun setSelectedLayerBound(isStart: Boolean) {
        val t = playhead
        updateSelectedLayer { layer ->
            if (isStart) layer.copy(start = min(t, layer.end - Clip.MINIMUM_DURATION))
            else layer.copy(end = max(t, layer.start + Clip.MINIMUM_DURATION))
        }
    }

    fun removeSelectedLayer() {
        val id = selectedLayerID ?: return
        edit { p -> p.copy(layers = p.layers.filter { it.id != id }) }
        selectedLayerID = null
    }

    // ---------------------------------------------------------------- animated effects

    fun effectOf(kind: AnimatedEffect.Kind): AnimatedEffect? = project.effects.firstOrNull { it.kind == kind }

    /** Adds an effect over the whole video, or removes it if it is already on. */
    fun toggleEffect(kind: AnimatedEffect.Kind) {
        effectOf(kind)?.let { removeEffect(it.id); return }
        val effect = AnimatedEffect.of(kind, seed = Random.nextLong(1, 0xFFFFFFFFL).toULong(), tier = VideoExportRules.tier(kind))
        edit { it.copy(effects = it.effects + effect) }
        selectedEffectID = effect.id
    }

    fun removeEffect(id: UUID) {
        edit { p -> p.copy(effects = p.effects.filter { it.id != id }) }
        if (selectedEffectID == id) selectedEffectID = null
    }

    fun setEffectIntensity(value: Double) {
        val id = selectedEffectID ?: return
        edit { p -> p.copy(effects = p.effects.map { if (it.id == id) it.copy(intensity = value.coerceIn(0.0, 1.0)) else it }) }
    }

    // ---------------------------------------------------------------- look

    val activeLook: LookApplication?
        get() = project.operations.lastOrNull { it.kind is OperationKind.Look }?.let { (it.kind as OperationKind.Look).look }

    /** Grades the whole video with a look. Tapping the active look removes it. */
    fun selectLook(lookID: String) {
        val current = activeLook
        if (current?.lookID == lookID) {
            edit { p -> p.copy(operations = p.operations.filterNot { it.kind is OperationKind.Look }) }
            return
        }
        val intensity = current?.intensity ?: 0.8
        edit { p ->
            p.copy(operations = listOf(EditOperation(kind = OperationKind.Look(LookApplication.of(lookID, intensity)))) + p.operations.filterNot { it.kind is OperationKind.Look })
        }
    }

    fun setLookIntensity(value: Double) = edit { p ->
        val i = p.operations.indexOfLast { it.kind is OperationKind.Look }
        if (i < 0) p else {
            val op = p.operations[i]
            val look = (op.kind as OperationKind.Look).look
            p.copy(operations = p.operations.toMutableList().also { it[i] = op.copy(kind = OperationKind.Look(look.copy(intensity = value.coerceIn(0.0, 1.0)))) })
        }
    }

    // ---------------------------------------------------------------- tools

    /** Returns false when an action tool couldn't act (split too close to an end). */
    fun toolTapped(tool: VideoTool): Boolean {
        when (tool) {
            VideoTool.split -> {
                activeTool = null
                return splitAtPlayhead()
            }
            VideoTool.reverse -> {
                activeTool = null
                toggleReverse()
            }
            else -> {
                activeTool = if (activeTool == tool) null else tool
                if (tool != VideoTool.text) selectedLayerID = null
            }
        }
        return true
    }

    fun isToolAvailable(tool: VideoTool): Boolean = when (tool) {
        VideoTool.reverse -> selectedClip?.kind == Clip.Kind.video
        VideoTool.split -> project.clipAt(playhead) != null
        else -> !tool.needsClip || selectedClip != null
    }

    // ---------------------------------------------------------------- playback

    fun togglePlay() {
        if (!hasPreview) return
        if (isPlaying) {
            player.pause()
            isPlaying = false
            tickJob?.cancel()
        } else {
            if (playhead >= duration - 0.05) seek(0.0)
            player.play()
            isPlaying = true
            startTicking()
        }
    }

    private fun startTicking() {
        tickJob?.cancel()
        tickJob = scope.launch {
            while (isActive && isPlaying) {
                playhead = (player.currentPosition / 1000.0).coerceIn(0.0, max(0.0, duration - 0.01))
                delay(33)
            }
        }
    }

    /** Moves the playhead, pausing playback while scrubbing. */
    fun seek(t: Seconds) {
        val clamped = t.coerceIn(0.0, max(0.0, duration - 0.01))
        playhead = clamped
        if (isPlaying) {
            player.pause()
            isPlaying = false
            tickJob?.cancel()
        }
        if (hasPreview) player.seekTo((clamped * 1000).toLong())
    }

    /** Selects whichever clip is under the playhead. */
    fun selectClipAtPlayhead() {
        project.clipAt(playhead)?.let { (index, _) -> selectedClipID = project.clips[index].id }
    }

    // ---------------------------------------------------------------- preview

    private fun scheduleRebuild(immediately: Boolean = false) {
        if (isClosed) return
        // Layers are drawn live, so they never need a new preview.
        val key = project.copy(layers = emptyList(), modifiedAt = project.createdAt)
        if (key == builtKey && !previewFailed) return
        rebuildJob?.cancel()
        rebuildJob = scope.launch {
            if (!immediately) delay(REBUILD_DELAY_MS)
            rebuild(key)
        }
    }

    private suspend fun rebuild(key: VideoProject) {
        if (key.clips.isEmpty()) return
        isBuilding = true
        try {
            val dir = File(app.cacheDir, "VideoPreview").apply { mkdirs() }
            previewCounter += 1
            val file = File(dir, "preview-${previewCounter % 2}.mp4")
            renderer.render(key, VideoRenderer.Settings(maxPixelSize = PREVIEW_PIXEL_SIZE, drawLayers = false, brandName = container.brand.appName), file)
            if (isClosed) return
            val wasPlaying = isPlaying
            player.setMediaItem(MediaItem.fromUri(Uri.fromFile(file)))
            player.prepare()
            player.seekTo((playhead * 1000).toLong())
            if (wasPlaying) player.play()
            previewFile?.takeIf { it != file }?.delete()
            previewFile = file
            builtKey = key
            hasPreview = true
            previewFailed = false
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            previewFailed = true
        } finally {
            isBuilding = false
        }
    }

    /** Stops playback and releases the player. Call when the editor closes. */
    fun close() {
        if (isClosed) return
        isClosed = true
        scope.cancel()
        player.release()
        isPlaying = false
        File(app.cacheDir, "VideoPreview").deleteRecursively()
    }

    // ---------------------------------------------------------------- export

    fun presentExport() {
        if (isPlaying) togglePlay()
        isExportPresented = true
    }

    companion object {
        /** Longest side of the preview render, in pixels (iOS renders its preview at 1280). */
        const val PREVIEW_PIXEL_SIZE = 960
        /** Wait after the last edit before rebuilding the preview. */
        const val REBUILD_DELAY_MS = 350L
        /** Aspects offered for video; free and original don't apply to a timeline. */
        val aspects = listOf(AspectPreset.story, AspectPreset.portrait, AspectPreset.square, AspectPreset.landscape)
    }
}
