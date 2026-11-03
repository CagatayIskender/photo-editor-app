package com.aurum.app.ui.autostudio

import android.content.Context
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.aurum.app.AppContainer
import com.aurum.app.depth.DepthEstimator
import com.aurum.app.depth.DepthMotionExporter
import com.aurum.app.depth.DepthMotionRenderer
import com.aurum.app.imaging.ImageLoader
import com.aurum.app.imaging.OverlayPainter
import com.aurum.app.l10n.tr
import com.aurum.core.DepthMotion
import com.aurum.core.DepthMotionPreset
import com.aurum.core.Entitlement
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Where 3D Motion is, the counterpart of `DepthMotionViewModel.Phase`. */
sealed interface DepthMotionPhase {
    data object Empty : DepthMotionPhase
    data object Loading : DepthMotionPhase
    data object Ready : DepthMotionPhase
    data class Exporting(val progress: Double) : DepthMotionPhase
    data class Saved(val uri: Uri) : DepthMotionPhase
    data class Failed(val message: String) : DepthMotionPhase
}

/**
 * Drives 3D Motion: one photo, a camera move and its intensity, a live
 * looping preview, and export as a video to Movies/AURUM. Ported from the iOS
 * `DepthMotionViewModel`; all work is on the device.
 */
class DepthMotionModel(
    private val context: Context,
    private val container: AppContainer,
    private val scope: CoroutineScope,
) {
    var photo by mutableStateOf<Uri?>(null)
        private set
    var preset by mutableStateOf(DepthMotionPreset.dolly)
    var intensity by mutableStateOf(0.6)
    var phase by mutableStateOf<DepthMotionPhase>(DepthMotionPhase.Empty)
        private set
    /** The preview-size layers, drawn every frame by the preview. */
    var renderer by mutableStateOf<DepthMotionRenderer?>(null)
        private set
    /** Android always estimates depth (see [DepthEstimator]). */
    var usesRealDepth by mutableStateOf(false)
        private set
    var isPaywallPresented by mutableStateOf(false)

    private var loadJob: Job? = null
    private var exportJob: Job? = null
    private val painter by lazy { OverlayPainter(context) }

    val motion: DepthMotion get() = DepthMotion.of(preset, intensity)

    val isReady: Boolean get() = phase == DepthMotionPhase.Ready || phase is DepthMotionPhase.Saved

    fun requiresMembership(entitlement: Entitlement): Boolean = DepthMotion.requiresMembership(preset, entitlement)

    // Loading

    fun setPhoto(uri: Uri) {
        exportJob?.cancel()
        loadJob?.cancel()
        photo = uri
        phase = DepthMotionPhase.Loading
        renderer = null
        loadJob = scope.launch {
            try {
                val prepared = withContext(Dispatchers.Default) {
                    val image = ImageLoader.decode(context, uri, PREVIEW_PIXEL_SIZE) ?: return@withContext null
                    try {
                        val depth = DepthEstimator.depth(image)
                        DepthMotionRenderer.prepare(image, depth)
                    } finally {
                        image.recycle()
                    }
                }
                if (prepared == null) {
                    phase = DepthMotionPhase.Failed(context.tr("This photo couldn't be opened."))
                } else {
                    usesRealDepth = !prepared.depth.isEstimated
                    renderer = prepared
                    phase = DepthMotionPhase.Ready
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                // Includes OutOfMemoryError on very large photos.
                phase = DepthMotionPhase.Failed(context.tr("This photo couldn't be opened."))
            }
        }
    }

    // Export

    fun export(entitlement: Entitlement) {
        val source = photo ?: return
        val preview = renderer ?: return
        if (requiresMembership(entitlement)) {
            isPaywallPresented = true
            return
        }
        if (phase is DepthMotionPhase.Exporting) return
        phase = DepthMotionPhase.Exporting(0.0)
        val watermark = if (entitlement == Entitlement.free) container.brand.watermarkText else null
        val move = motion
        exportJob = scope.launch {
            try {
                val uri = withContext(Dispatchers.Default) {
                    val image = ImageLoader.decode(context, source, DepthMotion.EXPORT_LONGEST_SIDE)
                        ?: throw DepthMotionExporter.ExportFailed("decode failed")
                    val size = DepthMotion.exportSize(image.width, image.height)
                    val full = try {
                        DepthMotionRenderer.prepare(image, preview.depth)
                    } finally {
                        image.recycle()
                    }
                    val overlay: ((android.graphics.Canvas, Float, Float) -> Unit)? =
                        watermark?.let { text -> { canvas: android.graphics.Canvas, w: Float, h: Float -> painter.drawWatermark(canvas, text, w, h) } }
                    DepthMotionExporter.export(context, full, move, DURATION, size.width, size.height, overlay) { value ->
                        if (phase is DepthMotionPhase.Exporting) phase = DepthMotionPhase.Exporting(value)
                    }
                }
                container.prefs.recordCreation()
                phase = DepthMotionPhase.Saved(uri)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                phase = DepthMotionPhase.Failed(context.tr("The export didn't finish. Please try again."))
            }
        }
    }

    /** Android 8–9 refused the storage permission needed to add a video. */
    fun permissionDenied() {
        phase = DepthMotionPhase.Failed(context.tr("AURUM needs permission to add videos. You can allow it in Settings."))
    }

    /** Switches to a free move, for the paywall's alternative. */
    fun useFreeMove() {
        preset = DepthMotionPreset.dolly
        isPaywallPresented = false
    }

    /** Back to the ready state after a save or a failed export. */
    fun reset() {
        if (renderer != null) phase = DepthMotionPhase.Ready
    }

    companion object {
        /** Preview proxy size and loop length, as on iOS. */
        const val PREVIEW_PIXEL_SIZE = 900
        const val DURATION = DepthMotion.DEFAULT_DURATION
    }
}
