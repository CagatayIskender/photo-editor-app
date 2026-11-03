package com.aurum.app.ondevice

import android.graphics.Bitmap
import android.graphics.PointF
import com.aurum.core.FaceGeometry
import com.aurum.core.NormalizedPoint
import com.aurum.core.NormalizedRect
import com.aurum.core.render.OnDevicePixels
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.Face
import com.google.mlkit.vision.face.FaceContour
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import com.google.mlkit.vision.face.FaceLandmark
import com.google.mlkit.vision.segmentation.Segmentation
import com.google.mlkit.vision.segmentation.selfie.SelfieSegmenterOptions
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Finds faces with ML Kit (bundled model, on the device) and converts them
 * to [FaceGeometry], normalised with a top-left origin, the counterpart of
 * the iOS `FaceDetector` (Vision). Blocking: call it off the main thread.
 */
object OnDeviceFaces {
    /** Longest side detection looks at; geometry is normalised, so it applies at any size. */
    private const val DETECTION_SIDE = 1280

    private val options: FaceDetectorOptions = FaceDetectorOptions.Builder()
        .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_ACCURATE)
        .setLandmarkMode(FaceDetectorOptions.LANDMARK_MODE_ALL)
        .setContourMode(FaceDetectorOptions.CONTOUR_MODE_ALL)
        .setMinFaceSize(0.06f)
        .build()

    /** Every face in [bitmap], in reading order. Empty when none was found or detection failed. */
    fun detect(bitmap: Bitmap): List<FaceGeometry> {
        if (bitmap.width < 8 || bitmap.height < 8) return emptyList()
        val longest = max(bitmap.width, bitmap.height)
        val input = if (longest > DETECTION_SIDE) {
            val s = DETECTION_SIDE.toDouble() / longest
            Bitmap.createScaledBitmap(bitmap, max(1, (bitmap.width * s).roundToInt()), max(1, (bitmap.height * s).roundToInt()), true)
        } else bitmap
        val detector = FaceDetection.getClient(options)
        return try {
            val found = Tasks.await(detector.process(InputImage.fromBitmap(input, 0)))
            FaceGeometry.readingOrder(found.map { geometry(it, input.width.toDouble(), input.height.toDouble()) })
        } catch (e: Exception) {
            emptyList()
        } finally {
            detector.close()
            if (input !== bitmap) input.recycle()
        }
    }

    /**
     * Converts one face. ML Kit's contours are mapped onto the regions the
     * retouch uses; the face contour is reduced to its lower half (ear to ear
     * around the chin, like Vision's). When only landmarks are known (ML Kit
     * gives contours for the most prominent faces), small regions are built
     * around them.
     */
    internal fun geometry(face: Face, w: Double, h: Double): FaceGeometry {
        val box = face.boundingBox
        val bounds = NormalizedRect(box.left / w, box.top / h, box.width() / w, box.height() / h)
        fun norm(points: List<PointF>) = points.map { NormalizedPoint((it.x / w).coerceIn(0.0, 1.0), (it.y / h).coerceIn(0.0, 1.0)) }
        fun contour(vararg types: Int): List<PointF> = types.flatMap { face.getContour(it)?.points.orEmpty() }

        val regions = mutableMapOf<FaceGeometry.Region, List<NormalizedPoint>>()
        val outline = contour(FaceContour.FACE)
        if (outline.size >= 28) {
            // 36 points clockwise from the top of the forehead: 9 to 27 run ear to ear around the chin.
            regions[FaceGeometry.Region.faceContour] = norm(outline.subList(9, 28))
        }
        fun put(region: FaceGeometry.Region, points: List<PointF>) {
            if (points.size >= 2) regions[region] = norm(points)
        }
        put(FaceGeometry.Region.leftEye, contour(FaceContour.LEFT_EYE))
        put(FaceGeometry.Region.rightEye, contour(FaceContour.RIGHT_EYE))
        put(FaceGeometry.Region.leftEyebrow, contour(FaceContour.LEFT_EYEBROW_TOP, FaceContour.LEFT_EYEBROW_BOTTOM))
        put(FaceGeometry.Region.rightEyebrow, contour(FaceContour.RIGHT_EYEBROW_TOP, FaceContour.RIGHT_EYEBROW_BOTTOM))
        put(FaceGeometry.Region.nose, contour(FaceContour.NOSE_BRIDGE, FaceContour.NOSE_BOTTOM))
        put(FaceGeometry.Region.outerLips, contour(FaceContour.UPPER_LIP_TOP, FaceContour.LOWER_LIP_BOTTOM))
        put(FaceGeometry.Region.innerLips, contour(FaceContour.UPPER_LIP_BOTTOM, FaceContour.LOWER_LIP_TOP))

        // Landmark fallbacks, sized from the face box.
        val fw = box.width().toFloat()
        fun around(p: PointF, rx: Float, ry: Float) = listOf(PointF(p.x - rx, p.y - ry), PointF(p.x + rx, p.y - ry), PointF(p.x + rx, p.y + ry), PointF(p.x - rx, p.y + ry))
        fun landmark(type: Int): PointF? = face.getLandmark(type)?.position
        if (FaceGeometry.Region.leftEye !in regions) landmark(FaceLandmark.LEFT_EYE)?.let { put(FaceGeometry.Region.leftEye, around(it, fw * 0.09f, fw * 0.035f)) }
        if (FaceGeometry.Region.rightEye !in regions) landmark(FaceLandmark.RIGHT_EYE)?.let { put(FaceGeometry.Region.rightEye, around(it, fw * 0.09f, fw * 0.035f)) }
        if (FaceGeometry.Region.nose !in regions) landmark(FaceLandmark.NOSE_BASE)?.let { put(FaceGeometry.Region.nose, around(it, fw * 0.1f, fw * 0.12f)) }
        val mouthLeft = landmark(FaceLandmark.MOUTH_LEFT)
        val mouthRight = landmark(FaceLandmark.MOUTH_RIGHT)
        val mouthBottom = landmark(FaceLandmark.MOUTH_BOTTOM)
        if (mouthLeft != null && mouthRight != null) {
            val midY = (mouthLeft.y + mouthRight.y) / 2
            val bottom = mouthBottom?.y ?: (midY + fw * 0.06f)
            val top = midY - (bottom - midY) * 0.8f
            val cx = (mouthLeft.x + mouthRight.x) / 2
            if (FaceGeometry.Region.outerLips !in regions) {
                put(FaceGeometry.Region.outerLips, listOf(mouthLeft, PointF(cx, top), mouthRight, PointF(cx, bottom)))
            }
            if (FaceGeometry.Region.innerLips !in regions) {
                val inset = (mouthRight.x - mouthLeft.x) * 0.15f
                put(FaceGeometry.Region.innerLips, listOf(PointF(mouthLeft.x + inset, midY), PointF(cx, midY - fw * 0.01f), PointF(mouthRight.x - inset, midY), PointF(cx, midY + fw * 0.01f)))
            }
        }
        return FaceGeometry(bounds, regions)
    }
}

/**
 * Caches detected faces by photo (its URI), so detection runs once per photo
 * however many times the Studio preview renders it.
 */
object FaceCache {
    private val storage = HashMap<String, List<FaceGeometry>>()

    fun faces(key: String, image: Bitmap): List<FaceGeometry> {
        synchronized(storage) { storage[key]?.let { return it } }
        val found = OnDeviceFaces.detect(image)
        synchronized(storage) { storage[key] = found }
        return found
    }

    fun store(found: List<FaceGeometry>, key: String) = synchronized(storage) { storage[key] = found }
}

/**
 * A person matte from ML Kit's selfie segmentation (bundled model), standing
 * in for Vision's person segmentation. Blocking: call it off the main thread.
 */
object PersonSegmentation {
    private const val SEGMENT_SIDE = 1024

    /**
     * Person confidence per pixel at [bitmap]'s size, edges softened, or null
     * when segmentation failed or found nobody.
     */
    fun matte(bitmap: Bitmap): FloatArray? {
        val longest = max(bitmap.width, bitmap.height)
        val input = if (longest > SEGMENT_SIDE) {
            val s = SEGMENT_SIDE.toDouble() / longest
            Bitmap.createScaledBitmap(bitmap, max(1, (bitmap.width * s).roundToInt()), max(1, (bitmap.height * s).roundToInt()), true)
        } else bitmap
        val segmenter = Segmentation.getClient(
            SelfieSegmenterOptions.Builder().setDetectorMode(SelfieSegmenterOptions.SINGLE_IMAGE_MODE).build(),
        )
        return try {
            val mask = Tasks.await(segmenter.process(InputImage.fromBitmap(input, 0)))
            val mw = mask.width
            val mh = mask.height
            if (mw <= 0 || mh <= 0) return null
            val buffer = mask.buffer
            buffer.rewind()
            val raw = FloatArray(mw * mh)
            buffer.asFloatBuffer().get(raw)
            val matte = OnDevicePixels.resizeMatte(raw, mw, mh, bitmap.width, bitmap.height)
            if (OnDevicePixels.coverage(matte) < 0.01) null else matte
        } catch (e: Exception) {
            null
        } finally {
            segmenter.close()
            if (input !== bitmap) input.recycle()
        }
    }
}
