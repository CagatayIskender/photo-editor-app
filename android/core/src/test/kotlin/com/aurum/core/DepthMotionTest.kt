package com.aurum.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.max

/** Ported from Phase3Tests.swift (DepthMotionTests) and Phase3FeaturesTests.swift. */
class DepthMotionTest {
    @Test fun loopIsSeamless() {
        for (preset in DepthMotionPreset.entries) {
            for (intensity in listOf(0.3, 1.0)) {
                val motion = DepthMotion.of(preset, intensity)
                val duration = 4.0
                assertEquals("$preset", motion.sample(0.0, duration), motion.sample(duration, duration))
                val start = motion.sample(0.0, duration)
                val end = motion.sample(duration - 1e-6, duration)
                assertEquals(start.dx, end.dx, 1e-6)
                assertEquals(start.dy, end.dy, 1e-6)
                assertEquals(start.zoom, end.zoom, 1e-6)
                assertEquals(start.focusDepth, end.focusDepth, 1e-6)
                // Times wrap around.
                val a = motion.sample(1.0, duration)
                val b = motion.sample(9.0, duration)
                assertEquals(a.dx, b.dx, 1e-12)
                assertEquals(a.zoom, b.zoom, 1e-12)
            }
        }
    }

    @Test fun samplesStayInBoundsAndCoverTheFrame() {
        for (preset in DepthMotionPreset.entries) {
            for (intensity in listOf(0.0, 0.5, 1.0)) {
                val motion = DepthMotion.of(preset, intensity, focusDepth = 0.9)
                val limit = DepthMotion.MAX_OFFSET * intensity + 1e-12
                var moved = false
                for (step in 0..240) {
                    val s = motion.sample(step / 60.0, 4.0)
                    assertTrue(abs(s.dx) <= limit)
                    assertTrue(abs(s.dy) <= limit)
                    assertTrue(s.zoom >= 1)
                    assertTrue(s.zoom <= 1 + DepthMotion.MAX_ZOOM + 1e-12)
                    assertTrue(s.zoom - 1 + 1e-12 >= 2 * max(abs(s.dx), abs(s.dy)))
                    assertTrue(s.focusDepth in 0.0..1.0)
                    if (s != motion.sample(0.0, 4.0)) moved = true
                }
                assertEquals("$preset $intensity", intensity > 0, moved)
            }
        }
    }

    @Test fun zeroIntensityIsStillAndSamplingIsDeterministic() {
        val still = DepthMotion.of(DepthMotionPreset.orbit, intensity = 0.0, focusDepth = 0.3).sample(1.3, 4.0)
        assertEquals(0.0, still.dx, 0.0)
        assertEquals(0.0, still.dy, 0.0)
        assertEquals(1.0, still.zoom, 0.0)
        assertEquals(0.3, still.focusDepth, 0.0)
        val m = DepthMotion.of(DepthMotionPreset.float, intensity = 0.8)
        assertEquals(m.sample(2.2, 5.0), m.sample(2.2, 5.0))
        assertEquals(m.sample(2.2, 0.0), m.sample(0.0, 5.0))
        assertEquals(1.0, DepthMotion.of(DepthMotionPreset.swing, intensity = 3.0).intensity, 0.0)
    }

    @Test fun depthMotionRoundTrips() {
        val motion = DepthMotion.of(DepthMotionPreset.dolly, intensity = 0.7, focusDepth = 0.25)
        val plain = AurumJson.format.decodeFromString(DepthMotion.serializer(), AurumJson.format.encodeToString(DepthMotion.serializer(), motion))
        assertEquals(motion, plain)
        val canonical = AurumJson.format.decodeFromString(DepthMotion.serializer(), AurumJson.encodeCanonical(DepthMotion.serializer(), motion))
        assertEquals(motion, canonical)
        // Same shape as Swift Codable (sorted keys, raw-value enum).
        assertEquals("""{"focusDepth":0.25,"intensity":0.7,"preset":"dolly"}""", AurumJson.encodeCanonical(DepthMotion.serializer(), motion))
    }

    @Test fun memberMovesNeedMembershipOnlyForFreeUsers() {
        assertTrue(DepthMotion.requiresMembership(DepthMotionPreset.orbit, Entitlement.free))
        assertFalse(DepthMotion.requiresMembership(DepthMotionPreset.orbit, Entitlement.member))
        assertFalse(DepthMotion.requiresMembership(DepthMotionPreset.dolly, Entitlement.free))
    }

    @Test fun exportSizeIsEvenAndCapped() {
        val size = DepthMotion.exportSize(4033, 3025)
        assertTrue(max(size.width, size.height) <= DepthMotion.EXPORT_LONGEST_SIDE)
        assertEquals(0, size.width % 2)
        assertEquals(0, size.height % 2)
        assertEquals(PixelSize(1080, 1350), DepthMotion.exportSize(0, 10))
        assertEquals(PixelSize(800, 600), DepthMotion.exportSize(801, 601))
    }
}
