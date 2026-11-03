package com.aurum.core

import com.aurum.core.render.ArgbImage
import com.aurum.core.render.OnDevicePixels
import com.aurum.core.render.PixelRenderer
import com.aurum.core.render.RetouchRenderer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.tan

// Ported from Packages/AurumCore/Tests/AurumCoreTests/AutoStudioTests.swift.

class InpaintingTest {
    private fun image(width: Int, height: Int, colour: (Int, Int) -> Triple<Float, Float, Float>): RGBAImageBuffer {
        val p = FloatArray(width * height * 4)
        for (y in 0 until height) for (x in 0 until width) {
            val c = colour(x, y)
            val i = (y * width + x) * 4
            p[i] = c.first; p[i + 1] = c.second; p[i + 2] = c.third; p[i + 3] = 1f
        }
        return RGBAImageBuffer(width, height, p)
    }

    private fun squareMask(width: Int, height: Int, from: Int, to: Int): FloatArray {
        val mask = FloatArray(width * height)
        for (y in from until to) for (x in from until to) mask[y * width + x] = 1f
        return mask
    }

    @Test fun flatRegionFillsToTheSurroundingColour() {
        val source = RGBAImageBuffer.filled(32, 32, 0.2f, 0.4f, 0.6f)
        val mask = squareMask(32, 32, 10, 20)
        for (useTexture in listOf(true, false)) {
            val filled = Inpainter.fill(source, mask, useTexture)
            for (i in 0 until 32 * 32) {
                assertEquals(0.2f, filled.pixels[i * 4], 1e-4f)
                assertEquals(0.4f, filled.pixels[i * 4 + 1], 1e-4f)
                assertEquals(0.6f, filled.pixels[i * 4 + 2], 1e-4f)
            }
        }
    }

    @Test fun stripedBackgroundRestoresTheStripes() {
        val stripes = image(64, 64) { x, _ -> if (x % 4 < 2) Triple(0.9f, 0.9f, 0.9f) else Triple(0.1f, 0.1f, 0.1f) }
        val mask = squareMask(64, 64, 24, 40)
        val damaged = stripes.copy()
        for (i in 0 until 64 * 64) if (mask[i] > 0) for (k in 0 until 3) damaged.pixels[i * 4 + k] = 0.5f
        val filled = Inpainter.fill(damaged, mask)
        val smooth = Inpainter.fill(damaged, mask, useTexture = false)
        fun error(result: RGBAImageBuffer): Float {
            var total = 0f
            var count = 0f
            for (i in 0 until 64 * 64) if (mask[i] > 0) {
                total += abs(result.pixels[i * 4] - stripes.pixels[i * 4])
                count += 1
            }
            return total / count
        }
        assertTrue("the patch should continue the stripes", error(filled) < 0.05f)
        assertTrue("texture should beat a smooth fill on stripes", error(filled) < error(smooth))
        assertNotNull(Inpainter.bestPatchOffset(damaged, FloatArray(mask.size) { if (mask[it] >= 0.5f) 0f else 1f }))
    }

    @Test fun pixelsOutsideTheMaskAreUntouched() {
        val source = image(48, 40) { x, y -> Triple((x * 7 % 13) / 13f, (y * 5 % 11) / 11f, ((x + y) % 9) / 9f) }
        val mask = squareMask(48, 40, 12, 26)
        for (useTexture in listOf(true, false)) {
            val filled = Inpainter.fill(source, mask, useTexture)
            for (i in 0 until 48 * 40) if (mask[i] == 0f) for (k in 0 until 4) {
                assertEquals(source.pixels[i * 4 + k], filled.pixels[i * 4 + k], 0f)
            }
            assertTrue(filled.pixels.all { it in 0f..1f })
        }
    }

    @Test fun emptyOrFullMaskReturnsTheImage() {
        val source = RGBAImageBuffer.filled(8, 8, 0.3f, 0.3f, 0.3f)
        assertEquals(source, Inpainter.fill(source, FloatArray(64)))
        assertEquals(source, Inpainter.fill(source, FloatArray(64) { 1f }))
        assertEquals(source, Inpainter.fill(source, FloatArray(0)))
    }

    @Test fun pushPullKeepsKnownValuesAndInterpolatesBetweenThem() {
        val values = floatArrayOf(0f, 0f, 0f, 0f, 1f)
        val weights = floatArrayOf(1f, 0f, 0f, 0f, 1f)
        val filled = Inpainter.pushPull(values, weights, 5, 1, 1)
        assertEquals(0f, filled[0], 0f)
        assertEquals(1f, filled[4], 0f)
        for (i in 1..3) {
            assertTrue(filled[i] > 0f)
            assertTrue(filled[i] < 1f)
        }
    }

    @Test fun candidateOffsetsAreUniqueAndLeaveTheHole() {
        val offsets = Inpainter.candidateOffsets(10, 6)
        assertEquals(offsets.size, offsets.toSet().size)
        assertFalse(offsets.contains(Inpainter.Offset(0, 0)))
        for (o in offsets) assertTrue("$o would overlap the hole", abs(o.dx) > 10 || abs(o.dy) > 6)
    }

    @Test fun rgba8RoundTrip() {
        val bytes = byteArrayOf(0, 128.toByte(), 255.toByte(), 255.toByte(), 10, 20, 30, 40)
        assertTrue(bytes.contentEquals(RGBAImageBuffer.fromRgba8(bytes, 2, 1).rgba8))
    }

    @Test fun objectRemoverFillsOnlyAroundTheBrush() {
        val w = 120
        val h = 80
        val px = IntArray(w * h) { 0xFF336699.toInt() }
        // A dark blob to remove.
        for (y in 35 until 45) for (x in 55 until 65) px[y * w + x] = 0xFF000000.toInt()
        val mask = BrushMask(strokes = listOf(BrushMask.Stroke.of(listOf(NormalizedPoint(0.5, 0.5)), radius = 0.1)))
        val out = ObjectRemover.remove(mask, px, w, h)
        val centre = out[40 * w + 60]
        assertTrue("the blob is gone", abs(((centre shr 16) and 0xff) - 0x33) <= 2 && abs((centre and 0xff) - 0x99) <= 2)
        assertEquals("far pixels are untouched", px[0], out[0])
    }
}

class BrushMaskTest {
    @Test fun emptinessAndBounds() {
        val eraserOnly = BrushMask(strokes = listOf(BrushMask.Stroke.of(listOf(NormalizedPoint(0.5, 0.5)), isEraser = true)))
        assertTrue(eraserOnly.isEmpty)
        assertTrue(BrushMask(polygons = listOf(listOf(NormalizedPoint(0.1, 0.1), NormalizedPoint(0.2, 0.2)))).isEmpty)
        val lasso = BrushMask(polygons = listOf(listOf(NormalizedPoint(0.1, 0.1), NormalizedPoint(0.5, 0.1), NormalizedPoint(0.3, 0.4))))
        assertFalse(lasso.isEmpty)
        assertTrue(lasso.isInBounds)
        val outside = BrushMask(polygons = listOf(listOf(NormalizedPoint(0.1, 0.1), NormalizedPoint(1.5, 0.1), NormalizedPoint(0.3, 0.4))))
        assertFalse(outside.isInBounds)
    }

    @Test fun coverageRasterisesStrokesAndErasers() {
        val paint = BrushMask.Stroke.of(listOf(NormalizedPoint(0.25, 0.5), NormalizedPoint(0.75, 0.5)), radius = 0.1)
        val erase = BrushMask.Stroke.of(listOf(NormalizedPoint(0.75, 0.5)), radius = 0.1, isEraser = true)
        val grid = BrushMask(strokes = listOf(paint, erase)).coverage(40, 20)
        assertEquals(800, grid.size)
        assertEquals("on the stroke", 1f, grid[10 * 40 + 15], 0f)
        assertEquals("far corner", 0f, grid[0], 0f)
        assertEquals("erased", 0f, grid[10 * 40 + 30], 0f)
        val grown = BrushMask(strokes = listOf(paint)).coverage(40, 20, grow = 3.0)
        assertTrue(grown.sum() > BrushMask(strokes = listOf(paint)).coverage(40, 20).sum())
    }

    @Test fun paintedBoundsAndRegionCoverage() {
        val mask = BrushMask(strokes = listOf(BrushMask.Stroke.of(listOf(NormalizedPoint(0.5, 0.5)), radius = 0.1)))
        val box = mask.paintedBounds(2.0)!!
        assertEquals(0.45, box.x, 1e-9)
        assertEquals(0.1, box.width, 1e-9)
        assertEquals(0.4, box.y, 1e-9)
        assertEquals(0.2, box.height, 1e-9)
        assertNull(BrushMask().paintedBounds(1.0))
        val whole = mask.coverage(80, 40)
        val part = mask.coverage(20, 10, 80.0, 40.0, 30.0, 15.0)
        for (y in 0 until 10) for (x in 0 until 20) assertEquals(whole[(y + 15) * 80 + x + 30], part[y * 20 + x], 0f)
    }

    @Test fun coverageFillsOutlines() {
        val square = BrushMask(polygons = listOf(listOf(
            NormalizedPoint(0.25, 0.25), NormalizedPoint(0.75, 0.25), NormalizedPoint(0.75, 0.75), NormalizedPoint(0.25, 0.75),
        )))
        val grid = square.coverage(20, 20)
        assertEquals(1f, grid[10 * 20 + 10], 0f)
        assertEquals(0f, grid[2 * 20 + 2], 0f)
        assertEquals(100f, grid.sum(), 0f)
    }

    @Test fun jsonMatchesSwiftShape() {
        val mask = BrushMask(strokes = listOf(BrushMask.Stroke.of(listOf(NormalizedPoint(0.5, 0.25)), radius = 0.04)))
        val json = AurumJson.encodeCanonical(BrushMask.serializer(), mask)
        assertTrue(json, json.contains("\"isEraser\":false") && json.contains("\"polygons\":[]"))
    }
}

class AutoSuggestionTest {
    private val face = FaceGeometry(NormalizedRect(0.4, 0.2, 0.25, 0.3))

    @Test fun nothingDetectedStillOffersEnhance() =
        assertEquals(listOf(AutoSuggestion.Kind.enhance), AutoSuggestions.rank(SceneAnalysis()).map { it.kind })

    @Test fun tiltedLandscapeLeadsWithStraighten() {
        val ranked = AutoSuggestions.rank(SceneAnalysis(luminance = 0.5, horizonDegrees = 2.3, labels = listOf(SceneLabel("sky", 0.8))))
        assertEquals(AutoSuggestion.Kind.straighten, ranked.first().kind)
        assertEquals(2.3, ranked.first().degrees!!, 0.0)
        assertEquals(AutoFeature.enhance, ranked.first().feature)
    }

    @Test fun tinyOrHugeTiltsAreNotOffered() {
        for (tilt in listOf(0.1, -0.2, 30.0)) {
            assertFalse("$tilt", AutoSuggestions.rank(SceneAnalysis(horizonDegrees = tilt)).any { it.kind == AutoSuggestion.Kind.straighten })
        }
    }

    @Test fun darkPortraitRanksFacesAndBackground() {
        val analysis = SceneAnalysis(faces = listOf(face), faceLuminance = 0.2, luminance = 0.45, personCoverage = 0.35, labels = listOf(SceneLabel("people", 0.9)))
        val ranked = AutoSuggestions.rank(analysis)
        val kinds = ranked.map { it.kind }
        assertEquals(AutoSuggestion.Kind.brightenFaces, kinds.first())
        assertTrue(AutoSuggestion.Kind.blurBackground in kinds)
        assertTrue(AutoSuggestion.Kind.smoothSkin in kinds)
        assertTrue(ranked.size <= 4)
        assertEquals(AutoFeature.relight, ranked.first().feature)
    }

    @Test fun redEyeComesFirstWhenFound() {
        val analysis = SceneAnalysis(faces = listOf(face), faceLuminance = 0.2, luminance = 0.2, personCoverage = 0.3, horizonDegrees = 3.0, redEyeLikely = true)
        assertEquals(AutoSuggestion.Kind.fixRedEye, AutoSuggestions.rank(analysis).first().kind)
        assertFalse(AutoSuggestions.rank(SceneAnalysis(redEyeLikely = true)).any { it.kind == AutoSuggestion.Kind.fixRedEye })
    }

    @Test fun colourCastAndDarknessAreSuggested() {
        val kinds = AutoSuggestions.rank(SceneAnalysis(luminance = 0.2, warmth = 0.3)).map { it.kind }
        assertEquals(listOf(AutoSuggestion.Kind.enhance, AutoSuggestion.Kind.balanceColour), kinds)
    }

    @Test fun rankingIsSortedAndLimited() {
        val analysis = SceneAnalysis(faces = listOf(face), faceLuminance = 0.3, luminance = 0.2, warmth = -0.3, personCoverage = 0.3, horizonDegrees = 4.0, redEyeLikely = true)
        val all = AutoSuggestions.rank(analysis, limit = 10)
        assertEquals(AutoSuggestion.Kind.entries.size, all.size)
        assertEquals(all.map { it.score }.sortedDescending(), all.map { it.score })
        assertEquals(2, AutoSuggestions.rank(analysis, limit = 2).size)
        assertEquals(1, AutoSuggestions.rank(analysis, limit = 0).size)
    }
}

class AutoStudioRulesTest {
    @Test fun onlyRetouchIsAMembersTool() {
        assertEquals(listOf(AutoFeature.retouch), AutoFeature.entries.filter { it.tier == Tier.member })
        assertEquals(listOf(AutoFeature.removeObject), AutoFeature.entries.filter { it.requiresMask })
    }

    @Test fun straightenCoverScale() {
        assertEquals(1.0, Straighten.coverScale(400.0, 300.0, 0.0), 1e-12)
        val angle = 3.0 * Math.PI / 180
        val k = Straighten.coverScale(400.0, 300.0, angle)
        assertTrue(k > 1)
        for ((cx, cy) in listOf(200.0 to 150.0, -200.0 to 150.0, 200.0 to -150.0, -200.0 to -150.0)) {
            val x = cx * cos(angle) + cy * sin(angle)
            val y = -cx * sin(angle) + cy * cos(angle)
            assertTrue(abs(x) <= 200 * k + 1e-9)
            assertTrue(abs(y) <= 150 * k + 1e-9)
        }
        assertEquals(k, Straighten.coverScale(400.0, 300.0, -angle), 1e-12)
        assertTrue(Straighten.isWorthCorrecting(-2.3))
        assertFalse(Straighten.isWorthCorrecting(0.2))
    }

    @Test fun portraitLooksAreUniqueWithFreeAndMemberLooks() {
        val ids = PortraitLook.library.map { it.id }
        assertEquals(ids.size, ids.toSet().size)
        assertTrue(PortraitLook.library.any { it.tier == Tier.free })
        assertTrue(PortraitLook.library.any { it.tier == Tier.member })
        assertEquals(true, PortraitLook.look("portrait.silver")?.params?.monochrome)
        assertNull(PortraitLook.look("missing"))
    }

    @Test fun naturalRetouchScales() {
        assertTrue(FaceRetouch.natural.scaled(0.0).isNeutral)
        assertEquals(FaceRetouch.natural, FaceRetouch.natural.scaled(1.0))
        assertEquals(FaceRetouch.natural.smoothing / 2, FaceRetouch.natural.scaled(0.5).smoothing, 1e-12)
        assertEquals(FaceRetouch.natural, FaceRetouch.natural.scaled(4.0))
    }

    @Test fun facesSortInReadingOrder() {
        val right = FaceGeometry(NormalizedRect(0.6, 0.1, 0.2, 0.2))
        val left = FaceGeometry(NormalizedRect(0.1, 0.12, 0.2, 0.2))
        val below = FaceGeometry(NormalizedRect(0.05, 0.6, 0.2, 0.2))
        assertEquals(listOf(left, right, below), FaceGeometry.readingOrder(listOf(below, right, left)))
    }
}

/** Android-only checks of the pixel ports (iOS tests these through Core Image snapshots). */
class OnDevicePixelsTest {
    private val w = 200
    private val h = 160

    /** A noisy skin-coloured square with eyes, on grey. */
    private fun portrait(): Pair<IntArray, FaceGeometry> {
        val px = IntArray(w * h) { i ->
            val x = i % w
            val y = i / w
            val inFace = x in 60 until 140 && y in 40 until 130
            val noise = ((x * 31 + y * 17) % 23) - 11
            if (inFace) argb(200 + noise, 150 + noise, 120 + noise) else argb(90, 90, 90)
        }
        val face = FaceGeometry(
            NormalizedRect(60.0 / w, 40.0 / h, 80.0 / w, 90.0 / h),
            mapOf(
                FaceGeometry.Region.leftEye to listOf(NormalizedPoint(80.0 / w, 70.0 / h), NormalizedPoint(90.0 / w, 70.0 / h)),
                FaceGeometry.Region.rightEye to listOf(NormalizedPoint(110.0 / w, 70.0 / h), NormalizedPoint(120.0 / w, 70.0 / h)),
            ),
        )
        return px to face
    }

    private fun argb(r: Int, g: Int, b: Int) = (0xFF shl 24) or (r.coerceIn(0, 255) shl 16) or (g.coerceIn(0, 255) shl 8) or b.coerceIn(0, 255)

    @Test fun retouchSmoothsTheFaceAndLeavesTheRestAlone() {
        val (px, face) = portrait()
        val out = px.copyOf()
        RetouchRenderer.apply(RetouchSettings(FaceRetouch(smoothing = 1.0)), listOf(face), ArgbImage(out, w, h))
        assertEquals("outside the face", px[5 * w + 5], out[5 * w + 5])
        fun spread(a: IntArray): Int {
            var mn = 255
            var mx = 0
            for (y in 90 until 110) for (x in 90 until 110) {
                val r = (a[y * w + x] shr 16) and 0xff
                mn = minOf(mn, r); mx = maxOf(mx, r)
            }
            return mx - mn
        }
        assertTrue("skin is smoother: ${spread(out)} < ${spread(px)}", spread(out) < spread(px))
        val untouched = px.copyOf()
        RetouchRenderer.apply(RetouchSettings(), listOf(face), ArgbImage(untouched, w, h))
        assertTrue(untouched.contentEquals(px))
    }

    @Test fun rendererAppliesTheRetouchOperationOnlyWithFaces() {
        val (px, face) = portrait()
        val renderer = PixelRenderer(TestSupport.smallCatalog)
        val doc = TestSupport.document(w, h).withRetouch(RetouchSettings(FaceRetouch.natural))
        assertTrue(renderer.render(doc, px, w, h).contentEquals(px))
        assertFalse(renderer.render(doc, px, w, h, faces = listOf(face)).contentEquals(px))
        // Reshaping moves pixels too.
        val reshaped = TestSupport.document(w, h).withRetouch(RetouchSettings(FaceRetouch(eyes = 1.0, jaw = -1.0)))
        assertFalse(renderer.render(reshaped, px, w, h, faces = listOf(face)).contentEquals(px))
    }

    @Test fun findsATiltedHorizon() {
        val tilt = 3.0 // counter-clockwise: the line rises to the right
        val t = tan(Math.toRadians(tilt))
        val px = IntArray(400 * 300) { i ->
            val x = i % 400
            val y = i / 400
            val horizon = 150 - (x - 200) * t
            if (y < horizon) argb(150, 190, 235) else argb(40, 70, 90)
        }
        val found = OnDevicePixels.horizonDegrees(px, 400, 300)
        assertNotNull(found)
        assertEquals(tilt, found!!, 0.5)
        assertNull("a flat photo has no horizon", OnDevicePixels.horizonDegrees(IntArray(400 * 300) { argb(120, 120, 120) }, 400, 300))
        assertTrue(OnDevicePixels.skyConfidence(px, 400, 300) > 0.3)
    }

    @Test fun straightenLevelsWithoutEmptyCorners() {
        val px = IntArray(w * h) { argb(200, 10, 10) }
        val out = OnDevicePixels.straighten(px, w, h, 5.0)
        assertEquals(px[0], out[0])
        assertEquals(px[w * h - 1], out[w * h - 1])
    }

    @Test fun backgroundToolsKeepThePerson() {
        val (px, _) = portrait()
        val matte = FloatArray(w * h) { i -> if (i % w in 60 until 140 && i / w in 40 until 130) 1f else 0f }
        val replaced = OnDevicePixels.replaceBackground(px, w, h, OnDevicePixels.Background.Color(0xFFF4EFE6.toInt()), matte)
        assertEquals(px[100 * w + 100], replaced[100 * w + 100])
        assertEquals(0xFFF4EFE6.toInt(), replaced[2 * w + 2])
        val blurred = OnDevicePixels.portraitBlur(px, w, h, 0.6, matte)
        assertEquals(px[100 * w + 100], blurred[100 * w + 100])
        val lit = OnDevicePixels.relight(px, w, h, emptyList(), OnDevicePixels.LightDirection.front, 0.8, null)
        assertNotEquals(px[60 * w + 100], lit[60 * w + 100])
    }

    @Test fun redEyeIsFoundAndFixed() {
        val px = IntArray(w * h) { argb(200, 160, 130) }
        val eye = listOf(NormalizedPoint(80.0 / w, 70.0 / h), NormalizedPoint(100.0 / w, 70.0 / h))
        for (y in 66 until 75) for (x in 84 until 96) px[y * w + x] = argb(220, 30, 30)
        val face = FaceGeometry(NormalizedRect(0.3, 0.3, 0.4, 0.4), mapOf(FaceGeometry.Region.leftEye to eye))
        assertTrue(OnDevicePixels.hasRedEye(px, w, h, listOf(face)))
        val fixed = OnDevicePixels.fixRedEye(px, w, h, listOf(face))
        assertFalse(OnDevicePixels.hasRedEye(fixed, w, h, listOf(face)))
    }
}
