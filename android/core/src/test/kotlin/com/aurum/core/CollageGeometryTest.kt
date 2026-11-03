package com.aurum.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CollageGeometryTest {
    @Test
    fun imageAlwaysCoversTheCell() {
        for (center in listOf(NormalizedPoint(0.0, 0.0), NormalizedPoint.center, NormalizedPoint(1.0, 1.0))) {
            val f = CollageCellGeometry.imageFrame(100.0, 200.0, 400.0, 300.0, 1.5, center)
            assertTrue(f.x <= 0.0001)
            assertTrue(f.y <= 0.0001)
            assertTrue(f.maxX >= 100.0 - 0.0001)
            assertTrue(f.maxY >= 200.0 - 0.0001)
        }
    }

    @Test
    fun panningRightMovesTheCentreLeft() {
        val moved = CollageCellGeometry.panned(NormalizedPoint.center, 20.0, 0.0, 100.0, 100.0, 400.0, 200.0, 1.0)
        assertTrue(moved.x < 0.5)
        assertEquals(0.5, moved.y, 1e-9)
    }
}
