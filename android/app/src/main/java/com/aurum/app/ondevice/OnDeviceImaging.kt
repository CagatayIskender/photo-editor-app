package com.aurum.app.ondevice

import android.graphics.Bitmap
import com.aurum.core.AutoFeature
import com.aurum.core.BrushMask
import com.aurum.core.FaceGeometry
import com.aurum.core.ObjectRemover
import com.aurum.core.PortraitLook
import com.aurum.core.SceneAnalysis
import com.aurum.core.SceneLabel
import com.aurum.core.render.OnDevicePixels
import com.aurum.core.render.PixelRenderer

/** A photo as packed ARGB pixels, the form the on-device tools work on. */
class PixelImage(val pixels: IntArray, val width: Int, val height: Int) {
    fun toBitmap(): Bitmap = Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888)

    companion object {
        fun of(bitmap: Bitmap): PixelImage {
            val px = IntArray(bitmap.width * bitmap.height)
            bitmap.getPixels(px, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
            return PixelImage(px, bitmap.width, bitmap.height)
        }
    }
}

/**
 * Looks at a photo once, on the device, to suggest one-tap fixes: faces and
 * their brightness, how much of the frame people fill, the horizon's tilt, a
 * colour cast and red eyes. Counterpart of the iOS `SceneAnalyzer`; the scene
 * labels come from pixel statistics (open sky, people) since Android has no
 * bundled scene classifier here.
 */
object SceneAnalyzer {
    class Result(val analysis: SceneAnalysis, val personMatte: FloatArray?)

    fun analyze(bitmap: Bitmap, image: PixelImage): Result {
        val px = image.pixels
        val w = image.width
        val h = image.height
        val faces = OnDeviceFaces.detect(bitmap)
        var faceLuminance: Double? = null
        var redEye = false
        if (faces.isNotEmpty()) {
            val values = faces.mapNotNull { OnDevicePixels.averageLuminance(px, w, h, it.bounds) }
            if (values.isNotEmpty()) faceLuminance = values.average()
            redEye = OnDevicePixels.hasRedEye(px, w, h, faces)
        }
        val matte = PersonSegmentation.matte(bitmap)
        val coverage = matte?.let(OnDevicePixels::coverage) ?: 0.0
        val stats = PixelRenderer.stats(px, w, h)
        val labels = mutableListOf<SceneLabel>()
        val sky = OnDevicePixels.skyConfidence(px, w, h)
        if (sky >= 0.1) labels.add(SceneLabel("sky", sky))
        if (coverage >= 0.06 || faces.isNotEmpty()) labels.add(SceneLabel("people", if (faces.isNotEmpty()) 0.9 else 0.5))
        val analysis = SceneAnalysis(
            faces = faces,
            faceLuminance = faceLuminance,
            luminance = stats.luminance,
            warmth = stats.warmth,
            personCoverage = coverage,
            horizonDegrees = OnDevicePixels.horizonDegrees(px, w, h),
            redEyeLikely = redEye,
            labels = labels.sortedByDescending { it.confidence },
        )
        return Result(analysis, matte)
    }
}

/**
 * The Auto Studio's work, off the main thread: the counterpart of
 * `AutoStudioViewModel.process` and `OnDeviceImaging` on iOS.
 */
object OnDeviceImaging {
    enum class Failure { noPerson, noFace, emptyMask, failed }

    class Job(
        val feature: AutoFeature,
        val source: Bitmap,
        val image: PixelImage,
        val faces: List<FaceGeometry>?,
        val personMatte: FloatArray?,
        val horizonDegrees: Double?,
        val enhanceOptions: OnDevicePixels.EnhanceOptions,
        val blurAmount: Double,
        val background: OnDevicePixels.Background?,
        val lightDirection: OnDevicePixels.LightDirection,
        val lightIntensity: Double,
        val retouchStrength: Double,
        val look: PortraitLook?,
        val mask: BrushMask,
    )

    sealed interface Outcome {
        class Success(val image: PixelImage) : Outcome
        data class Failed(val failure: Failure) : Outcome
    }

    fun process(job: Job): Outcome = try {
        run(job)
    } catch (e: OutOfMemoryError) {
        Outcome.Failed(Failure.failed)
    } catch (e: Exception) {
        Outcome.Failed(Failure.failed)
    }

    private fun run(job: Job): Outcome {
        val px = job.image.pixels
        val w = job.image.width
        val h = job.image.height
        fun faces() = job.faces ?: OnDeviceFaces.detect(job.source)
        fun person() = job.personMatte ?: PersonSegmentation.matte(job.source)
        fun done(out: IntArray) = Outcome.Success(PixelImage(out, w, h))
        return when (job.feature) {
            AutoFeature.enhance ->
                done(OnDevicePixels.enhance(px, w, h, job.enhanceOptions, if (job.enhanceOptions.redEye) faces() else emptyList(), job.horizonDegrees))
            AutoFeature.portraitBlur -> {
                val matte = person() ?: return Outcome.Failed(Failure.noPerson)
                done(OnDevicePixels.portraitBlur(px, w, h, job.blurAmount, matte))
            }
            AutoFeature.replaceBackground -> {
                val matte = person() ?: return Outcome.Failed(Failure.noPerson)
                val background = job.background ?: return Outcome.Failed(Failure.failed)
                done(OnDevicePixels.replaceBackground(px, w, h, background, matte))
            }
            AutoFeature.relight ->
                done(OnDevicePixels.relight(px, w, h, faces(), job.lightDirection, job.lightIntensity, person()))
            AutoFeature.retouch -> {
                val found = faces()
                if (found.isEmpty()) return Outcome.Failed(Failure.noFace)
                done(OnDevicePixels.naturalRetouch(px, w, h, found, job.retouchStrength))
            }
            AutoFeature.removeObject -> {
                if (job.mask.isEmpty) return Outcome.Failed(Failure.emptyMask)
                try {
                    done(ObjectRemover.remove(job.mask, px, w, h))
                } catch (e: ObjectRemover.EmptyMask) {
                    Outcome.Failed(Failure.emptyMask)
                }
            }
            AutoFeature.portraitLooks -> {
                val look = job.look ?: return Outcome.Failed(Failure.failed)
                done(OnDevicePixels.portraitLook(px, w, h, look, faces(), person()))
            }
        }
    }
}
