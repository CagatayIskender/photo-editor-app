package com.aurum.core

import com.aurum.core.render.ColorOps
import com.aurum.core.render.CropGeometry
import com.aurum.core.render.Lut3D
import com.aurum.core.render.PixelRenderer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class RendererTest {
    private val catalog = TestSupport.shippedCatalog()
    private val renderer = PixelRenderer(catalog)
    private val w = 48
    private val h = 32

    /** A gradient test card with colour in it. */
    private val card = IntArray(w * h) { i ->
        val x = i % w
        val y = i / w
        val r = x * 255 / (w - 1)
        val g = y * 255 / (h - 1)
        val b = 255 - r
        (0xFF shl 24) or (r shl 16) or (g shl 8) or b
    }

    private fun channels(p: Int) = intArrayOf((p shr 16) and 0xff, (p shr 8) and 0xff, p and 0xff)

    @Test fun pristineDocumentLeavesPixelsUntouched() {
        assertArrayEquals(card, renderer.render(TestSupport.document(), card, w, h))
    }

    @Test fun zeroIntensityAndDisabledLooksAreSkipped() {
        val doc = TestSupport.document().applyLook("film-analog.linen").setActiveLookIntensity(0.0)
        assertArrayEquals(card, renderer.render(doc, card, w, h))
        val on = TestSupport.document().applyLook("film-analog.linen")
        assertArrayEquals(card, renderer.render(on.toggleOperation(on.operations[0].id), card, w, h))
    }

    @Test fun everyShippedLookRendersDeterministically() {
        for (look in catalog.looks) {
            val doc = TestSupport.document().applyLook(look.id, 1.0)
            val a = renderer.render(doc, card, w, h)
            val b = renderer.render(doc, card, w, h)
            assertArrayEquals(look.id, a, b)
            assertTrue("${look.id} changes the image", !a.contentEquals(card))
            assertTrue(a.all { (it ushr 24) == 0xFF })
        }
    }

    @Test fun monochromeLooksAreGreyBeforeToning() {
        for (look in catalog.looks.filter { it.params.monochrome && it.params.shadowsTint == listOf(1.0, 1.0, 1.0) && it.params.highlightsTint == listOf(1.0, 1.0, 1.0) && it.params.warmth == 0.0 && it.params.tint == 0.0 && it.params.lightLeak == 0.0 }) {
            val out = renderer.render(TestSupport.document().applyLook(look.id, 1.0), card, w, h)
            for (p in out) {
                val c = channels(p)
                assertTrue(look.id, abs(c[0] - c[1]) <= 2 && abs(c[1] - c[2]) <= 2)
            }
        }
    }

    @Test fun intensityBlendsBetweenOriginalAndLook() {
        val lookID = catalog.looks("noir").first().id
        val half = renderer.render(TestSupport.document().applyLook(lookID, 0.5), card, w, h)
        val fullLook = renderer.render(TestSupport.document().applyLook(lookID, 1.0), card, w, h)
        val i = w * h / 2 + 3
        for (ch in 0..2) {
            val o = channels(card[i])[ch]
            val f = channels(fullLook[i])[ch]
            val m = channels(half[i])[ch]
            assertTrue("channel $ch: $o $m $f", m in (minOf(o, f) - 1)..(maxOf(o, f) + 1))
        }
    }

    @Test fun exposureBrightensAndVignetteDarkensCorners() {
        val bright = renderer.render(TestSupport.document().withAdjustments(AdjustmentSet(exposure = 0.5)), card, w, h)
        assertTrue(channels(bright[w * h / 2])[1] > channels(card[w * h / 2])[1])
        val flat = IntArray(w * h) { 0xFF808080.toInt() }
        val vig = renderer.render(TestSupport.document().withAdjustments(AdjustmentSet(vignette = 1.0)), flat, w, h)
        assertTrue(channels(vig[0])[0] < channels(vig[(h / 2) * w + w / 2])[0])
        val lighter = renderer.render(TestSupport.document().withAdjustments(AdjustmentSet(vignette = -1.0)), flat, w, h)
        assertTrue(channels(lighter[0])[0] > 0x80)
    }

    @Test fun grainIsSeededByDocument() {
        val flat = IntArray(w * h) { 0xFF808080.toInt() }
        val doc = TestSupport.document().withAdjustments(AdjustmentSet(grain = 1.0))
        val a = renderer.render(doc, flat, w, h)
        assertArrayEquals(a, renderer.render(doc, flat, w, h))
        assertNotEquals(a.toList(), renderer.render(doc.copy(id = TestSupport.id(77)), flat, w, h).toList())
    }

    @Test fun neutralColourOpsAreIdentity() {
        val c = doubleArrayOf(0.2, 0.5, 0.8)
        assertArrayEquals(c, ColorOps.exposure(c, 0.0), 1e-12)
        assertArrayEquals(c, ColorOps.colorControls(c, 0.0, 0.0, 0.0), 1e-12)
        assertArrayEquals(c, ColorOps.toneCurve(c, 0.0, 0.0), 1e-9)
        val lut = Lut3D.build { r, g, b -> doubleArrayOf(r, g, b) }
        val out = lut.lookup(0.3f, 0.6f, 0.9f)
        assertArrayEquals(floatArrayOf(0.3f, 0.6f, 0.9f), out, 1e-5f)
    }

    @Test fun fadeLiftsBlacks() {
        val out = ColorOps.toneCurve(doubleArrayOf(0.0, 0.0, 0.0), 0.18, -0.04)
        assertEquals(0.18, out[0], 1e-9)
    }

    @Test fun seedMatchesTheSwiftFnvHash() {
        // FNV-1a 64 over 16 zero bytes (value checked independently in Python).
        assertEquals("9808874869469701221", java.lang.Long.toUnsignedString(PixelRenderer.seed(java.util.UUID(0, 0))))
        assertNotEquals(PixelRenderer.seed(TestSupport.id(1)), PixelRenderer.seed(TestSupport.id(2)))
    }

    @Test fun cropGeometry() {
        assertEquals(1.0, CropGeometry.straightenScale(400.0, 300.0, 0.0), 1e-12)
        assertTrue(CropGeometry.straightenScale(400.0, 300.0, Math.toRadians(10.0)) > 1.0)
        val rect = CropGeometry.pixelRect(CropSpec.centred(AspectPreset.square, PixelSize(400, 300)), 400, 300)
        assertEquals(CropGeometry.IntRect(50, 0, 350, 300), rect)
    }

    @Test fun statsDetectGreyAndWarmPhotos() {
        val grey = PixelRenderer.stats(IntArray(100) { 0xFF777777.toInt() }, 10, 10)
        assertTrue(grey.saturation < 0.01)
        val warm = PixelRenderer.stats(IntArray(100) { 0xFFD08040.toInt() }, 10, 10)
        assertTrue(warm.warmth > 0.3)
    }
}
