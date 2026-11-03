package com.aurum.app.collage

import android.app.Application
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import com.aurum.app.AppContainer
import com.aurum.app.imaging.ImageLoader
import com.aurum.app.imaging.OverlayPainter
import com.aurum.app.imaging.PhotoExporter
import com.aurum.app.l10n.tr
import com.aurum.core.AspectPreset
import com.aurum.core.Carousel
import com.aurum.core.Entitlement
import com.aurum.core.ExportGate
import com.aurum.core.NormalizedRect
import com.aurum.core.PixelSize
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Drives the carousel splitter (the counterpart of iOS `CarouselViewModel`):
 * one wide photo cut into 2-10 panels that line up seamlessly when swiped,
 * saved to the library in order.
 */
class CarouselSession(
    private val app: Application,
    private val container: AppContainer,
    private val scope: CoroutineScope,
) {
    sealed interface Phase {
        data object Empty : Phase
        data object Loading : Phase
        data object Ready : Phase
        data class Exporting(val done: Int, val total: Int) : Phase
        data class Saved(val count: Int) : Phase
        data class Failed(val message: String) : Phase
    }

    var photo by mutableStateOf<Uri?>(null)
        private set
    var photoSize by mutableStateOf<PixelSize?>(null)
        private set
    var count by mutableStateOf(3)
        private set
    var aspect by mutableStateOf(AspectPreset.portrait)
        private set
    var panels by mutableStateOf<List<ImageBitmap>>(emptyList())
        private set
    var phase by mutableStateOf<Phase>(Phase.Empty)
        private set

    private var proxy: Bitmap? = null
    private var refreshJob: Job? = null
    private val painter = OverlayPainter(app)

    val panelAspect: Double get() = aspect.ratio ?: 1.0

    val canExport: Boolean
        get() = photo != null && (phase is Phase.Ready || phase is Phase.Saved || phase is Phase.Failed)

    /** Panels as normalised rects of the photo. */
    val panelRects: List<NormalizedRect>
        get() = photoSize?.let { Carousel.panels(it.aspectRatio, count, panelAspect) } ?: emptyList()

    fun setCount(value: Int) {
        val clamped = clampCount(value)
        if (clamped == count) return
        count = clamped
        refreshPanels()
    }

    fun setAspect(value: AspectPreset) {
        if (value == aspect) return
        aspect = value
        refreshPanels()
    }

    fun setPhoto(uri: Uri) {
        scope.launch {
            phase = Phase.Loading
            val loaded = withContext(Dispatchers.IO) {
                val size = ImageLoader.size(app, uri)
                val bitmap = size?.let { ImageLoader.decode(app, uri, PREVIEW_PIXEL_SIZE) }
                if (size != null && bitmap != null) size to bitmap else null
            }
            if (loaded == null) {
                phase = Phase.Failed(app.tr("This photo couldn't be opened."))
                return@launch
            }
            proxy = loaded.second
            photo = uri
            photoSize = loaded.first
            phase = Phase.Ready
            refreshPanels()
        }
    }

    private fun refreshPanels() {
        val source = proxy ?: return
        refreshJob?.cancel()
        val n = count
        val aspectRatio = panelAspect
        refreshJob = scope.launch {
            val cuts = withContext(Dispatchers.Default) {
                CarouselRenderer.panelRects(source.width, source.height, n, aspectRatio)
                    .map { CarouselRenderer.cut(source, it, PREVIEW_PIXEL_SIZE).asImageBitmap() }
            }
            panels = cuts
        }
    }

    fun resetPhase() {
        if (photo != null) phase = Phase.Ready
    }

    fun permissionDenied() {
        phase = Phase.Failed(app.tr("AURUM needs permission to add photos. You can allow it in Settings."))
    }

    /**
     * Free exports follow the photo rules (panels up to 2048 px); the small
     * mark goes on the last panel only, so the swipe stays clean.
     */
    fun export(entitlement: Entitlement) {
        val uri = photo ?: return
        if (!canExport) return
        val isFree = entitlement == Entitlement.free
        val panelSide = if (isFree) ExportGate.FREE_MAX_PIXEL_SIZE else MEMBER_PANEL_SIDE
        val total = count
        val aspectRatio = panelAspect
        phase = Phase.Exporting(0, total)
        scope.launch {
            phase = try {
                val saved = withContext(Dispatchers.Default) {
                    // Enough pixels for every panel at full panel size, within reason and within memory.
                    val full = ImageLoader.size(app, uri) ?: throw IllegalStateException("unreadable source")
                    val needed = min(panelSide * max(total, 1) * 1.1, 12_000.0).toInt()
                    val image = ImageLoader.decode(app, uri, min(needed, memoryLimitedLongest(full))) ?: throw IllegalStateException("decode failed")
                    val exporter = PhotoExporter(app, container.renderer, painter, container.brand.watermarkText)
                    try {
                        val rects = CarouselRenderer.panelRects(image.width, image.height, total, aspectRatio)
                        rects.forEachIndexed { index, rect ->
                            val panel = CarouselRenderer.cut(image, rect, panelSide)
                            try {
                                if (isFree && index == rects.lastIndex) {
                                    painter.drawWatermark(Canvas(panel), container.brand.watermarkText, panel.width.toFloat(), panel.height.toFloat())
                                }
                                exporter.saveToLibrary(panel)
                            } finally {
                                panel.recycle()
                            }
                            withContext(Dispatchers.Main) { phase = Phase.Exporting(index + 1, total) }
                        }
                        rects.size
                    } finally {
                        image.recycle()
                    }
                }
                container.prefs.recordCreation()
                Phase.Saved(saved)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Phase.Failed(app.tr("The export didn't finish. Please try again."))
            } catch (e: OutOfMemoryError) {
                Phase.Failed(app.tr("The export didn't finish. Please try again."))
            }
        }
    }

    /** The longest side that keeps the decoded photo (about 4 bytes a pixel) within ~40% of the heap. */
    private fun memoryLimitedLongest(size: PixelSize): Int {
        val maxPixels = Runtime.getRuntime().maxMemory() * 0.4 / 4.0
        val aspect = size.width.toDouble() / max(1, size.height)
        val longest = if (aspect >= 1) sqrt(maxPixels * aspect) else sqrt(maxPixels / aspect)
        return max(512, longest.toInt())
    }

    companion object {
        const val MIN_PANELS = 2
        const val MAX_PANELS = 10
        const val PREVIEW_PIXEL_SIZE = 1600
        /** Longest side of each exported panel for members. */
        const val MEMBER_PANEL_SIDE = 2160

        /** Panel shapes offered: the common feed shapes. */
        val aspects = listOf(AspectPreset.portrait, AspectPreset.square, AspectPreset.landscape)

        fun clampCount(value: Int): Int = min(max(value, MIN_PANELS), MAX_PANELS)
    }
}
