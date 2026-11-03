package com.aurum.core

import com.aurum.core.render.LiveLut
import com.aurum.core.render.PixelRenderer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LiveLookTest {
    private val catalog = TestSupport.shippedCatalog()
    private val renderer = PixelRenderer(catalog)

    @Test
    fun unknownLookAndZeroIntensityGiveNoTable() {
        assertNull(LiveLut.forLook(renderer, catalog, LookApplication.of("nope", 0.8)))
        assertNull(LiveLut.forLook(renderer, catalog, LookApplication.of(catalog.looks.first().id, 0.0)))
    }

    @Test
    fun tableMatchesTheColourRecipeOfTheRenderer() {
        for (look in catalog.looks.take(8)) {
            val app = LookApplication.of(look.id, 1.0)
            val lut = LiveLut.forLook(renderer, catalog, app)!!
            val px = IntArray(64) { i -> (0xff shl 24) or (((i * 4) and 0xff) shl 16) or (((i * 29) and 0xff) shl 8) or ((i * 53) and 0xff) }
            val expected = renderer.renderLook(app, px, 8, 8)
            val actual = px.copyOf().also { lut.apply(it, it.size) }
            // Looks with spatial effects differ a little from the colour-only table; the colour must stay close.
            val p = look.params
            if (p.bloom == 0.0 && p.lightLeak == 0.0 && p.vignette == 0.0 && p.grain == 0.0) {
                for (i in px.indices) for (shift in intArrayOf(16, 8, 0)) {
                    val e = (expected[i] shr shift) and 0xff
                    val a = (actual[i] shr shift) and 0xff
                    assertTrue("look ${look.id} pixel $i channel $shift: $e vs $a", kotlin.math.abs(e - a) <= 3)
                }
            }
        }
    }

    @Test
    fun lowerIntensityStaysCloserToTheInput() {
        val id = catalog.looks.first().id
        val full = LiveLut.forLook(renderer, catalog, LookApplication.of(id, 1.0))!!.lookup(0.8f, 0.4f, 0.2f)
        val half = LiveLut.forLook(renderer, catalog, LookApplication.of(id, 0.5))!!.lookup(0.8f, 0.4f, 0.2f)
        val input = floatArrayOf(0.8f, 0.4f, 0.2f)
        for (c in 0..2) {
            assertTrue(kotlin.math.abs(half[c] - input[c]) <= kotlin.math.abs(full[c] - input[c]) + 0.01f)
        }
        assertEquals(3, half.size)
    }
}
