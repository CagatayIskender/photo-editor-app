package com.aurum.app.ui.autostudio

import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import com.aurum.app.AppContainer
import com.aurum.app.imaging.ImageLoader
import com.aurum.app.l10n.tr
import com.aurum.app.ondevice.OnDeviceImaging
import com.aurum.app.ondevice.PixelImage
import com.aurum.app.ondevice.SceneAnalyzer
import com.aurum.app.ui.AppViewModel
import com.aurum.core.AutoFeature
import com.aurum.core.AutoSuggestion
import com.aurum.core.AutoSuggestions
import com.aurum.core.BrushMask
import com.aurum.core.Entitlement
import com.aurum.core.NormalizedPoint
import com.aurum.core.PortraitLook
import com.aurum.core.SceneAnalysis
import com.aurum.core.Tier
import com.aurum.core.render.OnDevicePixels
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.abs

/** A background offered by the Background tool. */
enum class AutoBackgroundChoice(val swatch: List<String>) {
    ivory(listOf("#F4EFE6", "#E6DDCF")),
    onyx(listOf("#1A1A1C", "#0B0B0C")),
    champagne(listOf("#E9D9BC", "#B89A6A")),
    blush(listOf("#F2DEDB", "#C9A6A4")),
    softFocus(listOf("#8A8A8A", "#4A4A4A")),
    photo(listOf("#3A3A3C", "#1C1C1E"));

    /** What goes behind the person; null for [photo] until a photo is chosen. */
    fun background(photo: PixelImage?): OnDevicePixels.Background? = when (this) {
        softFocus -> OnDevicePixels.Background.Blur(30.0)
        AutoBackgroundChoice.photo -> photo?.let { OnDevicePixels.Background.Image(it.pixels, it.width, it.height) }
        else -> OnDevicePixels.Background.Gradient(argb(swatch[0]), argb(swatch[1]))
    }

    private fun argb(hex: String): Int = (0xFF000000.toInt()) or hex.removePrefix("#").toInt(16)
}

/**
 * Brush strokes painted over the photo for Remove Object, in normalised
 * coordinates of the photo.
 */
data class BrushMaskEditor(
    val mask: BrushMask = BrushMask(),
    /** The stroke being painted, not yet in [mask]. */
    val current: List<NormalizedPoint> = emptyList(),
    /** Brush radius as a fraction of the photo's shorter side. */
    val radius: Double = 0.04,
    val isEraser: Boolean = false,
) {
    val canUndo: Boolean get() = mask.strokes.isNotEmpty()
    val hasPaint: Boolean get() = !mask.isEmpty

    /** Adds a point to the stroke being painted, clamped to the photo. */
    fun extend(point: NormalizedPoint): BrushMaskEditor {
        val p = NormalizedPoint(point.x.coerceIn(0.0, 1.0), point.y.coerceIn(0.0, 1.0))
        val last = current.lastOrNull()
        if (last != null && abs(last.x - p.x) < 0.002 && abs(last.y - p.y) < 0.002) return this
        return copy(current = current + p)
    }

    /** Finishes the stroke being painted. */
    fun endStroke(): BrushMaskEditor {
        if (current.isEmpty()) return this
        return copy(mask = mask.copy(strokes = mask.strokes + BrushMask.Stroke.of(current, radius, isEraser)), current = emptyList())
    }

    fun undo(): BrushMaskEditor = copy(current = emptyList(), mask = mask.copy(strokes = mask.strokes.dropLast(1)))

    fun clear(): BrushMaskEditor = copy(current = emptyList(), mask = BrushMask())
}

/**
 * Drives the Auto Studio (the iOS AutoStudioViewModel): one photo, analysed
 * once on open for suggested fixes, and a set of tools that all run on the
 * phone with bundled ML Kit detection and classic pixel processing. Nothing
 * is generated and nothing is uploaded.
 *
 * Every tool previews for free. Keeping a result that uses a members' tool or
 * look asks for membership, the same moment as an export anywhere else.
 */
class AutoStudioModel(private val context: Context, private val container: AppContainer, private val scope: CoroutineScope) {
    sealed interface Phase {
        data object Idle : Phase
        data object Loading : Phase
        data object Working : Phase
        data object Result : Phase
        data object Saving : Phase
        data class Failed(val message: String) : Phase
    }

    var feature by mutableStateOf(AutoFeature.enhance)
        private set
    var hasPhoto by mutableStateOf(false)
        private set
    var sourcePreview by mutableStateOf<ImageBitmap?>(null)
        private set
    var resultPreview by mutableStateOf<ImageBitmap?>(null)
        private set
    var phase by mutableStateOf<Phase>(Phase.Idle)
        private set
    var analysis by mutableStateOf<SceneAnalysis?>(null)
        private set
    var suggestions by mutableStateOf<List<AutoSuggestion>>(emptyList())
        private set
    var isAnalysing by mutableStateOf(false)
        private set
    var enhanceOptions by mutableStateOf(OnDevicePixels.EnhanceOptions.all)
    var blurAmount by mutableStateOf(0.6)
    var maskEditor by mutableStateOf(BrushMaskEditor())
    var background by mutableStateOf(AutoBackgroundChoice.ivory)
    var hasBackgroundPhoto by mutableStateOf(false)
        private set
    var lightDirection by mutableStateOf(OnDevicePixels.LightDirection.left)
    var lightIntensity by mutableStateOf(0.6)
    var retouchStrength by mutableStateOf(0.8)
    var portraitLookID by mutableStateOf(PortraitLook.library[0].id)
    var isPaywallPresented by mutableStateOf(false)

    private var sourceBitmap: Bitmap? = null
    private var sourceImage: PixelImage? = null
    private var personMatte: FloatArray? = null
    private var backgroundImage: PixelImage? = null
    private var resultBitmap: Bitmap? = null
    /** Bumped whenever the photo changes, so late analysis of an older photo is dropped. */
    private var generation = 0
    private var analysisJob: Job? = null

    /** Membership needed to keep the result on screen. */
    var resultTier: Tier = Tier.free
        private set

    val entitlement: Entitlement get() = container.membership.entitlement.value

    val resultRequiresMembership: Boolean get() = resultTier == Tier.member && entitlement == Entitlement.free

    val isBusy: Boolean get() = phase == Phase.Loading || phase == Phase.Working || phase == Phase.Saving

    // MARK: Photo

    /** Opens a tool with fresh results; the photo and its analysis stay. */
    fun select(feature: AutoFeature) {
        this.feature = feature
        maskEditor = BrushMaskEditor()
        resultPreview = null
        resultBitmap = null
        phase = Phase.Idle
    }

    /** Uses the picked photo and analyses it. */
    fun setPhoto(uri: Uri) {
        val token = ++generation
        analysisJob?.cancel()
        resultPreview = null
        resultBitmap = null
        maskEditor = BrushMaskEditor()
        analysis = null
        suggestions = emptyList()
        personMatte = null
        isAnalysing = false
        phase = Phase.Loading
        scope.launch {
            val bitmap = withContext(Dispatchers.IO) { ImageLoader.decode(context, uri, WORKING_PIXEL_SIZE) }
            if (token != generation) return@launch
            if (bitmap == null) {
                sourceBitmap = null
                sourceImage = null
                sourcePreview = null
                hasPhoto = false
                phase = Phase.Failed(context.tr("This photo couldn't be opened."))
                return@launch
            }
            val image = withContext(Dispatchers.Default) { PixelImage.of(bitmap) }
            sourceBitmap = bitmap
            sourceImage = image
            sourcePreview = bitmap.asImageBitmap()
            hasPhoto = true
            phase = Phase.Idle
            analyse(token, bitmap, image)
        }
    }

    /** Runs the detectors once on the photo and ranks the one-tap fixes. */
    private fun analyse(token: Int, bitmap: Bitmap, image: PixelImage) {
        isAnalysing = true
        analysisJob = scope.launch {
            val result = withContext(Dispatchers.Default) { runCatching { SceneAnalyzer.analyze(bitmap, image) }.getOrNull() }
            // The photo may have changed while the detectors were busy.
            if (token != generation) return@launch
            val found = result?.analysis ?: SceneAnalysis()
            analysis = found
            personMatte = result?.personMatte
            suggestions = AutoSuggestions.rank(found)
            isAnalysing = false
        }
    }

    /** Chooses the photo shown behind the person in Background. */
    fun setBackgroundPhoto(uri: Uri) {
        scope.launch {
            val image = withContext(Dispatchers.IO) {
                ImageLoader.decode(context, uri, WORKING_PIXEL_SIZE)?.let { b -> PixelImage.of(b).also { b.recycle() } }
            }
            if (image == null) {
                phase = Phase.Failed(context.tr("This photo couldn't be opened."))
                return@launch
            }
            backgroundImage = image
            hasBackgroundPhoto = true
            background = AutoBackgroundChoice.photo
        }
    }

    // MARK: Suggestions

    /** Opens the suggestion's tool with matching settings and runs it. */
    fun apply(suggestion: AutoSuggestion) {
        select(suggestion.feature)
        optionsFor(suggestion.kind)?.let { enhanceOptions = it }
        when (suggestion.kind) {
            AutoSuggestion.Kind.brightenFaces -> {
                lightDirection = OnDevicePixels.LightDirection.front
                lightIntensity = 0.5
            }
            AutoSuggestion.Kind.blurBackground -> blurAmount = 0.6
            AutoSuggestion.Kind.smoothSkin -> retouchStrength = 0.8
            else -> Unit
        }
        run()
    }

    // MARK: Running

    /** Why Preview is unavailable, or null when it can run. */
    val runIssue: String?
        get() = when {
            sourceImage == null -> context.tr("Choose a photo.")
            feature.requiresMask && maskEditor.mask.isEmpty -> context.tr("Brush over what you'd like removed.")
            feature == AutoFeature.replaceBackground && background == AutoBackgroundChoice.photo && backgroundImage == null ->
                context.tr("Choose the photo to put behind.")
            else -> null
        }

    /** Runs the current tool on the photo. Free; nothing leaves the phone. */
    fun run() {
        val bitmap = sourceBitmap ?: return
        val image = sourceImage ?: return
        if (runIssue != null || isBusy) return
        phase = Phase.Working
        val token = generation
        val look = PortraitLook.look(portraitLookID)
        val job = OnDeviceImaging.Job(
            feature = feature,
            source = bitmap,
            image = image,
            faces = analysis?.faces,
            personMatte = personMatte,
            horizonDegrees = analysis?.horizonDegrees,
            enhanceOptions = enhanceOptions,
            blurAmount = blurAmount,
            background = background.background(backgroundImage),
            lightDirection = lightDirection,
            lightIntensity = lightIntensity,
            retouchStrength = retouchStrength,
            look = look,
            mask = maskEditor.mask,
        )
        scope.launch {
            val outcome = withContext(Dispatchers.Default) {
                when (val o = OnDeviceImaging.process(job)) {
                    is OnDeviceImaging.Outcome.Success -> runCatching { o.image.toBitmap() }.getOrNull()?.let { Result.success(it) }
                        ?: Result.failure(IllegalStateException())
                    is OnDeviceImaging.Outcome.Failed -> Result.failure(FailureException(o.failure))
                }
            }
            if (token != generation) return@launch
            outcome.fold(
                onSuccess = { output ->
                    resultBitmap = output
                    resultPreview = output.asImageBitmap()
                    resultTier = tier(job.feature, look?.id)
                    phase = Phase.Result
                },
                onFailure = { e ->
                    phase = Phase.Failed(message((e as? FailureException)?.failure ?: OnDeviceImaging.Failure.failed))
                },
            )
        }
    }

    private class FailureException(val failure: OnDeviceImaging.Failure) : Exception()

    private fun message(failure: OnDeviceImaging.Failure): String = when (failure) {
        OnDeviceImaging.Failure.noPerson -> context.tr("No person was found in this photo. This tool works best on portraits.")
        OnDeviceImaging.Failure.noFace -> context.tr("No face was found in this photo.")
        OnDeviceImaging.Failure.emptyMask -> context.tr("Brush over what you'd like removed.")
        OnDeviceImaging.Failure.failed -> context.tr("That didn't work on this photo. Please try another.")
    }

    // MARK: Results

    fun discardResult() {
        resultPreview = null
        resultBitmap = null
        phase = Phase.Idle
    }

    /**
     * Saves the result to the photo library and opens it in the Studio. A
     * result made with a members' tool or look asks for membership first.
     * [permissionDenied] is true when Android 8 or 9 refused storage access.
     */
    fun openResultInStudio(app: AppViewModel, permissionDenied: Boolean = false) {
        val bitmap = resultBitmap ?: return
        if (resultRequiresMembership) {
            isPaywallPresented = true
            return
        }
        if (permissionDenied) {
            phase = Phase.Failed(context.tr("AURUM needs permission to add photos. You can allow it in Settings."))
            return
        }
        phase = Phase.Saving
        scope.launch {
            val uri = withContext(Dispatchers.IO) { runCatching { AtelierSupport.saveJpeg(context, bitmap) }.getOrNull() }
            if (uri == null) {
                phase = Phase.Failed(context.tr("The export didn't finish. Please try again."))
                return@launch
            }
            app.openCapturedPhoto(uri, null)
        }
    }

    companion object {
        /** Longest side used for processing and previews. */
        const val WORKING_PIXEL_SIZE = 2048

        /** The tier of a result made with [feature] (and, for Portrait Looks, [lookID]). */
        fun tier(feature: AutoFeature, lookID: String?): Tier {
            if (feature == AutoFeature.portraitLooks && lookID != null) PortraitLook.look(lookID)?.let { return it.tier }
            return feature.tier
        }

        /** The Enhance parts a suggestion switches on, or null if it uses another tool. */
        fun optionsFor(kind: AutoSuggestion.Kind): OnDevicePixels.EnhanceOptions? = when (kind) {
            AutoSuggestion.Kind.fixRedEye -> OnDevicePixels.EnhanceOptions.none.copy(redEye = true)
            AutoSuggestion.Kind.straighten -> OnDevicePixels.EnhanceOptions.none.copy(straighten = true)
            AutoSuggestion.Kind.balanceColour -> OnDevicePixels.EnhanceOptions.none.copy(whiteBalance = true)
            AutoSuggestion.Kind.enhance -> OnDevicePixels.EnhanceOptions.all
            AutoSuggestion.Kind.brightenFaces, AutoSuggestion.Kind.blurBackground, AutoSuggestion.Kind.smoothSkin -> null
        }
    }
}
