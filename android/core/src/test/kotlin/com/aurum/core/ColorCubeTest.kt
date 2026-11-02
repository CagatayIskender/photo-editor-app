package com.aurum.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ColorCubeTest {
    @Test fun neutralAdjustmentsNeedNoCube() = assertNull(ColorCube.make(AdjustmentSet()))

    @Test fun cubeHasTheExpectedSize() {
        val cube = ColorCube.make(AdjustmentSet(curves = ToneCurves(master = listOf(CurvePoint(0.5, 0.6)))), 8)
        assertNotNull(cube)
        assertEquals(8 * 8 * 8 * 4, cube!!.size)
        assertTrue(cube.all { it in 0f..1f })
    }

    @Test fun curveBrightensMidtonesButKeepsEnds() {
        val dim = 3
        val cube = ColorCube.make(AdjustmentSet(curves = ToneCurves(master = listOf(CurvePoint(0.5, 0.7)))), dim)!!
        fun entry(r: Int, g: Int, b: Int): List<Float> {
            val i = ((b * dim + g) * dim + r) * 4
            return cube.slice(i until i + 3)
        }
        assertEquals(listOf(0f, 0f, 0f), entry(0, 0, 0))
        assertEquals(listOf(1f, 1f, 1f), entry(2, 2, 2))
        assertEquals(0.7f, entry(1, 1, 1)[0], 0.001f)
    }

    @Test fun hslRoundTrip() {
        for (c in listOf(doubleArrayOf(0.8, 0.2, 0.1), doubleArrayOf(0.1, 0.6, 0.9), doubleArrayOf(0.5, 0.5, 0.5), doubleArrayOf(0.95, 0.9, 0.2))) {
            val (h, s, l) = ColorCube.hslFrom(c[0], c[1], c[2]).toList()
            val back = ColorCube.rgb(h, s, l)
            for (i in 0..2) assertEquals(c[i], back[i], 1e-9)
        }
    }

    @Test fun blueSaturationOnlyTouchesBlues() {
        val hsl = HSLAdjustments().with(HSLAdjustments.Band.blue, HSLAdjustments.Shift(saturation = -1.0))
        val blue = ColorCube.applyHSL(0.1, 0.3, 0.9, hsl)
        assertTrue("blue should be nearly grey", ColorCube.hslFrom(blue[0], blue[1], blue[2])[1] < 0.1)
        val red = ColorCube.applyHSL(0.9, 0.1, 0.1, hsl)
        assertEquals(0.9, red[0], 1e-9)
        assertEquals(0.1, red[1], 1e-9)
    }

    @Test fun bandWeightsWrapAroundRed() {
        assertEquals(1 - 10.0 / 45, ColorCube.weight(350.0, 0.0), 1e-9)
        assertEquals(0.0, ColorCube.weight(180.0, 0.0), 0.0)
    }

    @Test fun splitToningWarmsHighlightsAndCoolsShadows() {
        val dim = 3
        val a = AdjustmentSet(splitToning = SplitToning(shadowHue = 220.0, shadowSaturation = 1.0, highlightHue = 35.0, highlightSaturation = 1.0))
        val cube = ColorCube.make(a, dim)!!
        fun entry(i: Int): List<Float> { val k = ((i * dim + i) * dim + i) * 4; return cube.slice(k until k + 3) }
        val dark = entry(0)
        val light = entry(2)
        assertTrue("shadows lean blue", dark[2] > dark[0])
        assertTrue("highlights lean warm", light[0] >= light[2])
    }
}
