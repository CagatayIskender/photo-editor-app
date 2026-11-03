package com.aurum.app.depth

import android.graphics.Bitmap
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.segmentation.Segmentation
import com.google.mlkit.vision.segmentation.selfie.SelfieSegmenterOptions
import kotlin.math.max
import kotlin.math.min

/**
 * A depth map: [values] holds width × height samples, 1 is near, 0 far
 * (white near, black far, as on iOS).
 */
class DepthMap(val width: Int, val height: Int, val values: FloatArray, val isEstimated: Boolean)

/**
 * Finds depth for a 3D photo move, the counterpart of the iOS `DepthEstimator`.
 *
 * Android has no common way to read the depth some cameras embed, so this is
 * always the iOS pseudo-depth: the person near (ML Kit selfie segmentation,
 * bundled model, on the device), the rest far, with the lower part of the
 * frame (usually the ground) a little nearer than the top. Blocking: call it
 * off the main thread.
 */
object DepthEstimator {

    fun depth(image: Bitmap): DepthMap {
        val w = image.width
        val h = image.height
        val depth = FloatArray(w * h)
        // Ground plane: 0.35 at the bottom fading to 0 at 70% of the height.
        val ramp = h * 0.7
        for (y in 0 until h) {
            val fromBottom = (h - 1 - y) + 0.5
            val v = (0.35 * (1.0 - min(1.0, fromBottom / ramp))).toFloat()
            val row = y * w
            for (x in 0 until w) depth[row + x] = v
        }
        personMask(image)?.let { person ->
            for (i in depth.indices) depth[i] = max(depth[i], person[i])
        }
        // Soft edges keep the layers from tearing at the outline.
        DepthImaging.blur(depth, w, h, min(w, h) * 0.01)
        return DepthMap(w, h, depth, isEstimated = true)
    }

    /** Person confidence per pixel at the image's size, or null when segmentation fails. */
    private fun personMask(image: Bitmap): FloatArray? {
        val options = SelfieSegmenterOptions.Builder()
            .setDetectorMode(SelfieSegmenterOptions.SINGLE_IMAGE_MODE)
            .build()
        val segmenter = Segmentation.getClient(options)
        return try {
            val mask = Tasks.await(segmenter.process(InputImage.fromBitmap(image, 0)))
            val mw = mask.width
            val mh = mask.height
            if (mw <= 0 || mh <= 0) return null
            val buffer = mask.buffer
            buffer.rewind()
            val raw = FloatArray(mw * mh)
            buffer.asFloatBuffer().get(raw)
            for (i in raw.indices) raw[i] = raw[i].coerceIn(0f, 1f)
            DepthImaging.resample(raw, mw, mh, image.width, image.height)
        } catch (e: Exception) {
            null
        } finally {
            segmenter.close()
        }
    }
}
