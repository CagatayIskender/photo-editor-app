package com.aurum.app.collage

import android.app.Application
import android.graphics.Canvas
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import com.aurum.app.AppContainer
import com.aurum.app.imaging.ImageLoader
import com.aurum.app.imaging.OverlayPainter
import com.aurum.app.imaging.PhotoExporter
import com.aurum.app.l10n.tr
import com.aurum.core.CollageCellGeometry
import com.aurum.core.CollageLayout
import com.aurum.core.CollageProject
import com.aurum.core.Entitlement
import com.aurum.core.ExportDecision
import com.aurum.core.ExportGate
import com.aurum.core.SourceAsset
import com.aurum.core.Tier
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.ceil
import kotlin.math.max

/**
 * Drives the collage editor (the counterpart of iOS `CollageViewModel`):
 * layout, photos per cell, swapping, per-cell framing, spacing, corners and
 * background, then export. [scope] outlives the screen so a running export is
 * not cancelled by closing it.
 */
class CollageSession(
    private val app: Application,
    private val container: AppContainer,
    private val scope: CoroutineScope,
) {
    sealed interface Phase {
        data object Editing : Phase
        data object Exporting : Phase
        data class Saved(val uri: Uri) : Phase
        data class Failed(val message: String) : Phase
    }

    var project by mutableStateOf(CollageProject.of(CollageLayout.library.first { it.tier == Tier.free }))
        private set
    val thumbnails = mutableStateMapOf<String, ImageBitmap>()
    var selectedCell by mutableStateOf<Int?>(null)
        private set
    var phase by mutableStateOf<Phase>(Phase.Editing)
        private set
    var isPaywallPresented by mutableStateOf(false)

    private val loading = HashSet<String>()
    private val painter = OverlayPainter(app)

    val layouts: List<CollageLayout> get() = CollageLayout.library
    val emptyCellCount: Int get() = project.cells.count { it == null }
    val canExport: Boolean get() = project.filledCount > 0 && phase != Phase.Exporting

    fun decision(entitlement: Entitlement): ExportDecision = ExportGate.collageDecision(project, entitlement)

    // Layout and photos

    fun setLayout(layout: CollageLayout) {
        project = project.withLayout(layout)
        selectedCell = null
        phase = Phase.Editing
    }

    /** Fills empty cells with picked photos, in picking order. */
    fun add(uris: List<Uri>) {
        scope.launch {
            val sources = withContext(Dispatchers.IO) { uris.mapNotNull(::source) }
            // More photos than empty cells: move to the smallest free layout that holds them all, so none are dropped.
            val needed = project.filledCount + sources.size
            if (needed > project.layout.photoCount) {
                CollageLayout.library
                    .filter { it.tier == Tier.free && it.photoCount >= needed }
                    .minByOrNull { it.photoCount }
                    ?.let { project = project.withLayout(it) }
            }
            for (source in sources) {
                val (next, _) = project.add(source) ?: break
                project = next
                loadThumbnail(source.localIdentifier)
            }
            phase = Phase.Editing
        }
    }

    /** Puts a photo in one cell, replacing what was there. */
    fun replace(index: Int, uri: Uri) {
        scope.launch {
            val source = withContext(Dispatchers.IO) { source(uri) } ?: return@launch
            project = project.assign(CollageProject.Cell.of(source), index)
            loadThumbnail(source.localIdentifier)
            selectedCell = null
        }
    }

    fun clear(index: Int) {
        project = project.assign(null, index)
        selectedCell = null
    }

    /** Tapping a cell selects it; tapping another while one is selected swaps them. Returns true when it swapped. */
    fun tap(index: Int): Boolean {
        val selected = selectedCell
        if (selected != null) {
            if (selected == index) {
                selectedCell = null
                return false
            }
            project = project.swapCells(selected, index)
            selectedCell = null
            return true
        }
        selectedCell = index
        return false
    }

    private fun source(uri: Uri): SourceAsset? =
        ImageLoader.size(app, uri)?.let { SourceAsset(uri.toString(), it) }

    private fun loadThumbnail(id: String) {
        if (thumbnails.containsKey(id) || !loading.add(id)) return
        scope.launch {
            val bitmap = withContext(Dispatchers.IO) { ImageLoader.decode(app, Uri.parse(id), THUMBNAIL_SIDE) }
            if (bitmap != null) thumbnails[id] = bitmap.asImageBitmap()
            loading.remove(id)
        }
    }

    // Framing

    /** Pans (in cell pixels) and zooms a cell's photo by the change since the last event. */
    fun adjust(index: Int, panX: Double, panY: Double, zoomChange: Double, cellWidth: Double, cellHeight: Double) {
        val cell = project.cells.getOrNull(index) ?: return
        val iw = cell.source.pixelSize.width.toDouble()
        val ih = cell.source.pixelSize.height.toDouble()
        val zoom = (cell.zoom * zoomChange).coerceIn(1.0, 4.0)
        val center = CollageCellGeometry.panned(cell.center, panX, panY, cellWidth, cellHeight, iw, ih, zoom)
        project = project.assign(CollageProject.Cell(cell.source, zoom, center), index)
    }

    fun setSpacing(value: Double) {
        project = project.copy(spacing = value.coerceIn(CollageProject.SPACING_RANGE.start, CollageProject.SPACING_RANGE.endInclusive))
    }

    fun setCornerRadius(value: Double) {
        project = project.copy(cornerRadius = value.coerceIn(CollageProject.CORNER_RADIUS_RANGE.start, CollageProject.CORNER_RADIUS_RANGE.endInclusive))
    }

    fun setBackground(hex: String) {
        project = project.copy(backgroundHex = CollageProject.normalizedHex(hex) ?: project.backgroundHex)
    }

    fun permissionDenied() {
        phase = Phase.Failed(app.tr("AURUM needs permission to add photos. You can allow it in Settings."))
    }

    // Export

    /** Membership is asked for here and only here, when the layout is a member's. */
    fun export() {
        if (!canExport) return
        val allowed = when (val d = decision(container.membership.entitlement.value)) {
            is ExportDecision.Allowed -> d
            is ExportDecision.RequiresMembership -> {
                isPaywallPresented = true
                return
            }
        }
        phase = Phase.Exporting
        val snapshot = project
        scope.launch {
            phase = try {
                val uri = withContext(Dispatchers.Default) { renderAndSave(snapshot, allowed) }
                container.prefs.recordCreation()
                Phase.Saved(uri)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Phase.Failed(app.tr("The export didn't finish. Please try again."))
            } catch (e: OutOfMemoryError) {
                Phase.Failed(app.tr("The export didn't finish. Please try again."))
            }
        }
    }

    fun resetPhase() { phase = Phase.Editing }

    private suspend fun renderAndSave(snapshot: CollageProject, allowed: ExportDecision.Allowed): Uri {
        val longest = allowed.maxPixelSize ?: MEMBER_LONGEST_SIDE
        val (width, height) = CollageRenderer.canvasSize(snapshot.layout, longest)
        val frames = snapshot.frames
        val bitmap = CollageRenderer.render(snapshot, width, height) { index ->
            val cell = snapshot.cells.getOrNull(index)
            if (cell == null) {
                null
            } else {
                // Decode only as many pixels as this cell can show at its zoom.
                val rect = CollageRenderer.pixelRect(frames[index], width, height)
                val iw = cell.source.pixelSize.width.toDouble()
                val ih = cell.source.pixelSize.height.toDouble()
                val s = CollageCellGeometry.scale(rect.width().toDouble(), rect.height().toDouble(), iw, ih, cell.zoom)
                val needed = max(64, ceil(max(iw, ih) * s).toInt())
                ImageLoader.decode(app, Uri.parse(cell.source.localIdentifier), needed)
            }
        }
        try {
            if (allowed.watermark) {
                painter.drawWatermark(Canvas(bitmap), container.brand.watermarkText, width.toFloat(), height.toFloat())
            }
            val exporter = PhotoExporter(app, container.renderer, painter, container.brand.watermarkText)
            return exporter.saveToLibrary(bitmap)
        } finally {
            bitmap.recycle()
        }
    }

    companion object {
        /** Longest side of a member export; free exports use the gate's limit. */
        const val MEMBER_LONGEST_SIDE = 4096
        const val THUMBNAIL_SIDE = 600

        /** Background colours offered under the canvas. */
        val backgrounds = listOf("#0B0B0C", "#F4EFE6", "#E9D9BC", "#F2DEDB", "#3A3F44", "#FFFFFF")
    }
}
