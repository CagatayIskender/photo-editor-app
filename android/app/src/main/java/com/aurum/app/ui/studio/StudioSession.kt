package com.aurum.app.ui.studio

import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.asImageBitmap
import com.aurum.app.AppContainer
import com.aurum.app.imaging.EditRendering
import com.aurum.app.imaging.ImageLoader
import com.aurum.app.imaging.OverlayPainter
import com.aurum.core.EditDocument
import com.aurum.core.EditHistory
import com.aurum.core.ExportDecision
import com.aurum.core.ExportGate
import com.aurum.core.LookApplication
import com.aurum.core.LookSuggestion
import com.aurum.core.Overlay
import com.aurum.core.Preset
import com.aurum.core.render.PixelRenderer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant
import java.util.UUID

enum class StudioTool(val titleKey: String) { looks("Looks"), adjust("Adjust"), crop("Crop"), text("Text"), stickers("Stickers") }

/**
 * One photo open in the Studio: the document and its undo history, the
 * preview rendered off the main thread, and the look thumbnails.
 *
 * Sliders and gestures edit inside a history transaction (begin, update...,
 * end), so one drag is one undo step, as on iOS.
 */
class StudioSession(
    private val context: Context,
    val container: AppContainer,
    val sourceUri: Uri,
    initial: EditDocument,
    private val scope: CoroutineScope,
) {
    private val history = EditHistory(initial)
    val painter = OverlayPainter(context)
    private val renderer: PixelRenderer get() = container.renderer
    val catalog get() = container.catalog

    var document by mutableStateOf(initial)
        private set
    private var historyVersion by mutableIntStateOf(0)
    val canUndo: Boolean get() { historyVersion; return history.canUndo }
    val canRedo: Boolean get() { historyVersion; return history.canRedo }

    var tool by mutableStateOf(StudioTool.looks)
    var selectedOverlayID by mutableStateOf<UUID?>(null)

    /** Graded and cropped preview, about 1280 px on the long side. */
    var preview by mutableStateOf<ImageBitmap?>(null)
        private set
    /** The cropped photo without looks, for press-and-hold compare. */
    var original by mutableStateOf<ImageBitmap?>(null)
        private set
    var isLoading by mutableStateOf(true)
        private set
    var loadFailed by mutableStateOf(false)
        private set

    /** Look id -> the photo in that look, small, for the Looks strip. */
    val thumbnails = mutableStateMapOf<String, ImageBitmap>()

    private var base: Bitmap? = null
    /** The document as opened (plus any suggested look); closing without changes saves no draft. */
    private var baseline: EditDocument = initial
    private val renderRequests = MutableStateFlow<EditDocument?>(null)
    private var renderJob: Job? = null

    // ---------------------------------------------------------------- loading

    fun load(suggestLook: Boolean, queuedLookID: String?) {
        scope.launch {
            val bitmap = withContext(Dispatchers.IO) { ImageLoader.decode(context, sourceUri, PREVIEW_SIZE) }
            if (bitmap == null) {
                loadFailed = true
                isLoading = false
                return@launch
            }
            base = bitmap
            if (queuedLookID != null && catalog.look(queuedLookID) != null) {
                commit(document.applyLook(queuedLookID))
            } else if (suggestLook) {
                val stats = withContext(Dispatchers.Default) {
                    val w = bitmap.width
                    val h = bitmap.height
                    val px = IntArray(w * h).also { bitmap.getPixels(it, 0, w, 0, 0, w, h) }
                    PixelRenderer.stats(px, w, h)
                }
                LookSuggestion.suggest(stats, container.prefs.vibes, catalog)?.let { commit(document.applyLook(it.id)) }
                baseline = document
            }
            startRendering()
            renderThumbnails(bitmap)
        }
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    private fun startRendering() {
        renderJob?.cancel()
        renderRequests.value = document
        renderJob = scope.launch {
            // Overlays are drawn live by the canvas, so only photo changes re-render.
            renderRequests.filterNotNull()
                .map { it.copy(overlays = emptyList(), modifiedAt = Instant.EPOCH) }
                .distinctUntilChanged()
                .collectLatest { doc ->
                    val source = base ?: return@collectLatest
                    val (graded, plain) = withContext(Dispatchers.Default) {
                        EditRendering.render(renderer, doc, source).asImageBitmap() to
                            EditRendering.crop(source, doc.crop).asImageBitmap()
                    }
                    preview = graded
                    original = plain
                    isLoading = false
                }
        }
    }

    private fun renderThumbnails(bitmap: Bitmap) {
        scope.launch(Dispatchers.Default) {
            val side = THUMB_SIZE
            val shortest = minOf(bitmap.width, bitmap.height)
            val square = Bitmap.createBitmap(bitmap, (bitmap.width - shortest) / 2, (bitmap.height - shortest) / 2, shortest, shortest)
            val small = Bitmap.createScaledBitmap(square, side, side, true)
            val px = IntArray(side * side).also { small.getPixels(it, 0, side, 0, 0, side, side) }
            for (look in catalog.looks) {
                val out = renderer.renderLook(LookApplication.of(look.id, 1.0), px, side, side)
                val bmp = Bitmap.createBitmap(out, side, side, Bitmap.Config.ARGB_8888)
                withContext(Dispatchers.Main) { thumbnails[look.id] = bmp.asImageBitmap() }
            }
        }
    }

    // ---------------------------------------------------------------- editing

    private fun publish(doc: EditDocument) {
        document = doc
        historyVersion++
        renderRequests.value = doc
    }

    /** A single, undoable change. */
    fun commit(doc: EditDocument) {
        history.commit(doc)
        publish(history.current)
    }

    /** Starts a continuous edit (a slider drag or a gesture). */
    fun begin() {
        if (!history.isInTransaction) history.beginTransaction()
    }

    fun update(doc: EditDocument) {
        if (!history.isInTransaction) history.beginTransaction()
        history.update(doc)
        publish(doc)
    }

    /** Ends a continuous edit as one undo step. */
    fun end() {
        if (!history.isInTransaction) return
        history.commit(document)
        publish(history.current)
    }

    fun undo() { history.undo()?.let(::publish) }
    fun redo() { history.redo()?.let(::publish) }

    fun updateOverlay(overlay: Overlay, live: Boolean) {
        val doc = document.updateOverlay(overlay)
        if (live) update(doc) else commit(doc)
    }

    val selectedOverlay: Overlay? get() = document.overlays.firstOrNull { it.id == selectedOverlayID }

    /** Changes the look by [offset] within its collection (swipe on the photo). */
    fun cycleLook(offset: Int) {
        val active = document.activeLookIndex?.let { document.lookApplications.lastOrNull() } ?: return
        val next = catalog.neighbour(active.lookID, offset) ?: return
        commit(document.applyLook(next.id, active.intensity))
    }

    // ---------------------------------------------------------------- favourites and presets

    var favouriteLookIDs by mutableStateOf(container.prefs.favouriteLookIDs)
        private set

    fun toggleFavourite(lookID: String) {
        val next = if (lookID in favouriteLookIDs) favouriteLookIDs - lookID else favouriteLookIDs + lookID
        favouriteLookIDs = next
        container.prefs.favouriteLookIDs = next
    }

    fun saveAsPreset(name: String): Preset {
        val preset = Preset.from(name, document)
        scope.launch { container.presets.add(preset) }
        return preset
    }

    // ---------------------------------------------------------------- export

    fun exportDecision(): ExportDecision =
        ExportGate.decision(document, container.membership.entitlement.value, catalog)

    fun stripPremium() = commit(ExportGate.strippingPremium(document, catalog))

    /** Saves a draft if anything was changed; called when the Studio closes. */
    suspend fun close() {
        renderJob?.cancel()
        if (document == baseline || loadFailed) return
        val doc = document.copy(modifiedAt = Instant.ofEpochSecond(Instant.now().epochSecond))
        if (!doc.isPristine) {
            val thumb = preview?.let { img ->
                withContext(Dispatchers.Default) {
                    EditRendering.fitting(img.asAndroidBitmap().copy(Bitmap.Config.ARGB_8888, false), 360)
                }
            }
            container.drafts.save(doc, thumb)
        }
    }

    companion object {
        const val PREVIEW_SIZE = 1280
        const val THUMB_SIZE = 112
    }
}
