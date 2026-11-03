package com.aurum.app.camera

import android.util.Log
import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Size
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.aurum.core.render.LiveLut
import java.io.File
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine

/**
 * The camera behind the AURUM camera screen (the counterpart of the iOS
 * `CameraController`): CameraX Preview + ImageCapture + ImageAnalysis.
 *
 * Live look: while a look is chosen, every analysis frame (RGBA, about 640x480,
 * newest frame only) is turned upright, mirrored for the front camera, graded
 * with a baked [LiveLut] and published as [frame]; the screen draws it over the
 * plain preview. With "Original" nothing is processed and the plain preview
 * shows through. A shot is always taken from the full-resolution sensor image
 * with no look burned in, so the Studio can still change it.
 */
class LiveCamera(context: Context) {
    private val app = context.applicationContext
    private val mainExecutor = ContextCompat.getMainExecutor(app)
    private val analysisExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    private var provider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var boundOwner: LifecycleOwner? = null

    /** The graded live frame, upright, or null with "Original" (the plain preview shows). */
    var frame by mutableStateOf<ImageBitmap?>(null)
        private set

    /** Whether the bound camera has a flash unit (false for most front cameras). */
    var hasFlash by mutableStateOf(false)
        private set

    /** Set once the first camera has started; false after a failure. */
    var failed by mutableStateOf(false)
        private set

    var isFront by mutableStateOf(false)
        private set

    @Volatile private var lut: LiveLut? = null
    @Volatile private var mirror = false
    @Volatile private var released = false

    private var pixels = IntArray(0)
    private var bytes = ByteArray(0)

    private val preview: Preview = Preview.Builder()
        .setResolutionSelector(selector(ResolutionStrategy.HIGHEST_AVAILABLE_STRATEGY))
        .build()

    private val capture: ImageCapture = ImageCapture.Builder()
        .setCaptureMode(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY)
        .setResolutionSelector(selector(ResolutionStrategy.HIGHEST_AVAILABLE_STRATEGY))
        .build()

    private val analysis: ImageAnalysis = ImageAnalysis.Builder()
        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
        .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
        .setResolutionSelector(
            selector(ResolutionStrategy(Size(640, 480), ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER)),
        )
        .build()
        .also { it.setAnalyzer(analysisExecutor) { image -> process(image) } }

    private fun selector(resolution: ResolutionStrategy) = ResolutionSelector.Builder()
        .setAspectRatioStrategy(AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY)
        .setResolutionStrategy(resolution)
        .build()

    /** The look worn by the live frames; null for "Original". Takes effect on the next frame. */
    fun setLut(value: LiveLut?) {
        lut = value
        if (value == null) mainHandler.post { frame = null }
    }

    /**
     * Starts (or restarts, to switch lens) the camera on [owner]'s lifecycle,
     * drawing the plain preview into [view]. [rotation] is a `Surface.ROTATION_*`.
     */
    fun bind(owner: LifecycleOwner, view: PreviewView, front: Boolean, rotation: Int, onReady: (Boolean) -> Unit = {}) {
        val future = ProcessCameraProvider.getInstance(app)
        future.addListener({
            if (released) return@addListener
            val p = try { future.get() } catch (e: Exception) {
                Log.w(TAG, "Camera provider failed", e)
                failed = true; onReady(false); return@addListener
            }
            provider = p
            fun has(s: CameraSelector) = try { p.hasCamera(s) } catch (e: Exception) { Log.w(TAG, "hasCamera failed", e); false }
            val wanted = if (front) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
            val other = if (front) CameraSelector.DEFAULT_BACK_CAMERA else CameraSelector.DEFAULT_FRONT_CAMERA
            // Some devices list a lens they don't have: fall back to whichever lens is really there.
            val useFront = when { has(wanted) -> front; has(other) -> !front; else -> null }
            if (useFront == null) { Log.w(TAG, "No usable camera"); failed = true; onReady(false); return@addListener }
            val selector = if (useFront) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA
            try {
                p.unbindAll()
                preview.targetRotation = rotation
                capture.targetRotation = rotation
                analysis.targetRotation = rotation
                preview.setSurfaceProvider(view.surfaceProvider)
                mirror = useFront
                camera = p.bindToLifecycle(owner, selector, preview, capture, analysis)
                boundOwner = owner
                isFront = useFront
                hasFlash = camera?.cameraInfo?.hasFlashUnit() == true
                if (!hasFlash) capture.flashMode = ImageCapture.FLASH_MODE_OFF
                failed = false
                onReady(true)
            } catch (e: Exception) {
                Log.w(TAG, "Binding the camera failed", e)
                failed = true
                onReady(false)
            }
        }, mainExecutor)
    }

    /** Stops the camera. The screen calls this when it leaves. */
    fun unbind() {
        runCatching { provider?.unbindAll() }
        camera = null
        boundOwner = null
        frame = null
    }

    fun release() {
        released = true
        unbind()
        analysis.clearAnalyzer()
        analysisExecutor.shutdown()
    }

    /** 0 off, 1 auto, 2 on. */
    fun setFlash(mode: Int) {
        capture.flashMode = when (mode) {
            1 -> ImageCapture.FLASH_MODE_AUTO
            2 -> ImageCapture.FLASH_MODE_ON
            else -> ImageCapture.FLASH_MODE_OFF
        }
    }

    /** Focus and meter at a point of the preview view, in the view's own pixels. */
    fun focus(view: PreviewView, x: Float, y: Float) {
        val cam = camera ?: return
        val point = view.meteringPointFactory.createPoint(x, y)
        runCatching { cam.cameraControl.startFocusAndMetering(FocusMeteringAction.Builder(point).build()) }
    }

    /**
     * Takes a full-resolution JPEG into the app's own storage and returns its
     * file, or null on failure. The shot is also copied to Pictures/AURUM
     * (best effort, no permission needed on Android 10 and later).
     */
    suspend fun takePhoto(): File? {
        val dir = File(app.filesDir, "captures").apply { mkdirs() }
        val file = File(dir, "AURUM-${UUID.randomUUID().toString().take(8)}.jpg")
        val options = ImageCapture.OutputFileOptions.Builder(file).build()
        val saved = suspendCancellableCoroutine { cont ->
            capture.takePicture(options, mainExecutor, object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(output: ImageCapture.OutputFileResults) { if (cont.isActive) cont.resume(true) }
                override fun onError(exception: ImageCaptureException) { if (cont.isActive) cont.resume(false) }
            })
        }
        return if (saved && file.length() > 0) file else null
    }

    /** Adds [file] to the photo library under Pictures/AURUM. Android 10 and later; quietly does nothing elsewhere. */
    fun addToGallery(file: File) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        runCatching {
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, file.name)
                put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/AURUM")
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
            val resolver = app.contentResolver
            val uri: Uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values) ?: return
            resolver.openOutputStream(uri)?.use { out -> file.inputStream().use { it.copyTo(out) } }
            values.clear()
            values.put(MediaStore.Images.Media.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        }
    }

    // MARK: Live frames

    private fun process(image: ImageProxy) {
        try {
            val look = lut
            if (look == null || released) return
            val plane = image.planes[0]
            val w = image.width
            val h = image.height
            val rowStride = plane.rowStride
            val pixelStride = plane.pixelStride
            val buffer = plane.buffer
            buffer.rewind()
            val needed = buffer.remaining()
            if (bytes.size < needed) bytes = ByteArray(needed)
            buffer.get(bytes, 0, needed)

            val turned = image.imageInfo.rotationDegrees
            val sideways = turned == 90 || turned == 270
            val ow = if (sideways) h else w
            val oh = if (sideways) w else h
            if (pixels.size < ow * oh) pixels = IntArray(ow * oh)
            val flip = mirror
            val out = pixels
            val src = bytes
            for (oy in 0 until oh) {
                val row = oy * ow
                for (ox in 0 until ow) {
                    val x = if (flip) ow - 1 - ox else ox
                    val sx: Int
                    val sy: Int
                    when (turned) {
                        90 -> { sx = oy; sy = h - 1 - x }
                        180 -> { sx = w - 1 - x; sy = h - 1 - oy }
                        270 -> { sx = w - 1 - oy; sy = x }
                        else -> { sx = x; sy = oy }
                    }
                    val i = sy * rowStride + sx * pixelStride
                    out[row + ox] = (0xff shl 24) or
                        ((src[i].toInt() and 0xff) shl 16) or
                        ((src[i + 1].toInt() and 0xff) shl 8) or
                        (src[i + 2].toInt() and 0xff)
                }
            }
            look.apply(out, ow * oh)
            val bitmap = Bitmap.createBitmap(out, 0, ow, ow, oh, Bitmap.Config.ARGB_8888)
            // A look swapped back to "Original" while this frame was in flight must not bring the frame back.
            if (lut != null) mainHandler.post { if (lut != null) frame = bitmap.asImageBitmap() }
        } catch (e: Exception) {
            // A dropped frame is invisible; the next one replaces it.
        } finally {
            image.close()
        }
    }
}

private const val TAG = "AurumCamera"
