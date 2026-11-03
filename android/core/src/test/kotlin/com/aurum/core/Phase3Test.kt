package com.aurum.core

import kotlinx.serialization.KSerializer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneOffset
import kotlin.math.max
import kotlin.math.min

private object P3 {
    val photo = SourceAsset("p", PixelSize(3000, 2000))
    val frame = SourceAsset("f", PixelSize(1920, 1080))
    val date: Instant = Instant.ofEpochSecond(1_800_000_000)

    fun <T> roundTrip(serializer: KSerializer<T>, value: T) {
        val plain = AurumJson.format.decodeFromString(serializer, AurumJson.format.encodeToString(serializer, value))
        assertEquals(value, plain)
        val canonical = AurumJson.format.decodeFromString(serializer, AurumJson.encodeCanonical(serializer, value))
        assertEquals(value, canonical)
    }

    fun overlapArea(a: NormalizedRect, b: NormalizedRect): Double {
        val w = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
        val h = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
        return max(0.0, w) * max(0.0, h)
    }

    fun isInsideUnitSquare(r: NormalizedRect, tolerance: Double = 1e-9) =
        r.x >= -tolerance && r.y >= -tolerance && r.width > 0 && r.height > 0 && r.x + r.width <= 1 + tolerance && r.y + r.height <= 1 + tolerance
}

class CollageTest {
    @Test fun libraryCoversTwoToSixPhotos() {
        val library = CollageLayout.library
        assertEquals(12, library.size)
        assertEquals(library.size, library.map { it.id }.toSet().size)
        for (count in 2..6) assertTrue("$count photos", CollageLayout.layouts(count).size >= 2)
        assertTrue(library.any { it.tier == Tier.member } && library.any { it.tier == Tier.free })
        assertEquals(4, CollageLayout.layout("collage.quartet")?.photoCount)
    }

    @Test fun cellsAreInsideNonOverlappingAndTileTheCanvas() {
        for (layout in CollageLayout.library) {
            var area = 0.0
            layout.cells.forEachIndexed { i, cell ->
                assertTrue("${layout.id} cell $i", P3.isInsideUnitSquare(cell))
                area += cell.width * cell.height
                for (other in layout.cells.drop(i + 1)) assertTrue(layout.id, P3.overlapArea(cell, other) < 1e-9)
            }
            assertEquals(layout.id, 1.0, area, 1e-9)
        }
    }

    @Test fun spacingKeepsFramesApart() {
        for (layout in CollageLayout.library) {
            assertEquals(layout.cells, layout.frames(0.0))
            val frames = layout.frames(0.04)
            frames.forEachIndexed { i, f ->
                assertTrue(layout.id, P3.isInsideUnitSquare(f))
                assertTrue(f.x > 0 && f.x + f.width < 1)
                for (other in frames.drop(i + 1)) assertEquals(layout.id, 0.0, P3.overlapArea(f, other), 0.0)
            }
        }
        val q = CollageLayout.layout("collage.quartet")!!.frames(0.04)
        assertEquals(0.04, q[0].x, 1e-12)
        assertEquals(0.04, q[1].x - (q[0].x + q[0].width), 1e-12)
    }

    @Test fun projectEditing() {
        var project = CollageProject.of(CollageLayout.layout("collage.salon")!!, spacing = 0.2, cornerRadius = -1.0, backgroundHex = "fa0", id = TestSupport.id(1))
        assertEquals(0.05, project.spacing, 0.0)
        assertEquals(0.0, project.cornerRadius, 0.0)
        assertEquals("#FFAA00", project.backgroundHex)
        assertEquals(3, project.cells.size)
        assertEquals("#12AB9C", CollageProject.normalizedHex("#12ab9C"))
        assertNull(CollageProject.normalizedHex("#12ab9"))
        assertNull(CollageProject.normalizedHex("blue"))

        val a = SourceAsset("a", PixelSize(10, 10))
        val b = SourceAsset("b", PixelSize(10, 10))
        val c = SourceAsset("c", PixelSize(10, 10))
        project.add(a)!!.let { (p, i) -> assertEquals(0, i); project = p }
        project.add(b)!!.let { (p, i) -> assertEquals(1, i); project = p }
        project = project.assign(CollageProject.Cell.of(c, zoom = 9.0, center = NormalizedPoint(-1.0, 0.4)), 2)
        assertEquals(4.0, project.cells[2]!!.zoom, 0.0)
        assertEquals(NormalizedPoint(0.0, 0.4), project.cells[2]!!.center)
        assertTrue(project.isComplete)
        assertNull(project.add(a))
        project = project.swapCells(0, 2)
        assertEquals(listOf("c", "b", "a"), project.cells.map { it?.source?.localIdentifier })
        P3.roundTrip(CollageProject.serializer(), project)

        project = project.withLayout(CollageLayout.layout("collage.duet")!!)
        assertEquals(listOf("c", "b"), project.cells.map { it?.source?.localIdentifier })
        project = project.withLayout(CollageLayout.layout("collage.quartet")!!)
        assertEquals(listOf("c", "b", null, null), project.cells.map { it?.source?.localIdentifier })
        assertEquals(2, project.filledCount)
        assertFalse(project.isComplete)
        P3.roundTrip(CollageProject.serializer(), project)
    }

    @Test fun carouselPanelsTileExactly() {
        val cases = listOf(Triple(3.0, 3, 1.0), Triple(4.0 / 3, 3, 4.0 / 5), Triple(16.0 / 9, 5, 4.0 / 5), Triple(21.0 / 9, 7, 1.0), Triple(0.75, 2, 1.0), Triple(2.7, 10, 9.0 / 16), Triple(5.0, 2, 1.0), Triple(4.0, 3, 4.0 / 5))
        for ((image, count, panel) in cases) {
            val panels = Carousel.panels(image, count, panel)
            assertEquals(count, panels.size)
            panels.forEachIndexed { i, p ->
                assertTrue(P3.isInsideUnitSquare(p, 1e-12))
                assertEquals(panel, p.width * image / p.height, 1e-9)
                assertEquals(panels[0].y, p.y, 0.0)
                if (i + 1 < panels.size) assertEquals("seam $i", panels[i + 1].x, p.x + p.width, 0.0)
            }
            val left = panels[0].x
            val right = 1 - (panels.last().x + panels.last().width)
            assertEquals(left, right, 1e-12)
        }
        assertEquals(listOf(0.0, 1.0 / 3, 2.0 / 3), Carousel.panels(3.0, 3, 1.0).map { it.x })
        assertTrue(Carousel.panels(0.0, 3, 1.0).isEmpty())
        assertEquals(Carousel.MAX_PANELS, Carousel.panels(50.0, 100, 1.0).size)
    }

    @Test fun premiumLayoutGatesExport() {
        val free = CollageProject.of(CollageLayout.layout("collage.duet")!!)
        val premiumLayout = CollageLayout.library.first { it.tier == Tier.member }
        val premium = CollageProject.of(premiumLayout)
        assertEquals(ExportDecision.Allowed(true, ExportGate.FREE_MAX_PIXEL_SIZE), ExportGate.collageDecision(free, Entitlement.free))
        assertEquals(ExportDecision.RequiresMembership(listOf(PremiumItem.CollageLayoutItem(premiumLayout.id, premiumLayout.name))), ExportGate.collageDecision(premium, Entitlement.free))
        assertEquals(ExportDecision.Allowed(false, null), ExportGate.collageDecision(premium, Entitlement.member))
    }
}

class DropsTest {
    private fun schedule() = DropSchedule(listOf(
        Drop.of("winter", "Winter Gala", TestSupport.day(2026, 12, 1, 0), TestSupport.day(2027, 1, 1, 0), lookIDs = listOf("gala.1"), tier = Tier.member),
        Drop.of("holiday", "Holiday Lights", TestSupport.day(2026, 12, 20, 0), TestSupport.day(2026, 12, 27, 0), stickerIDs = listOf("lights")),
        Drop.of("spring", "First Bloom", TestSupport.day(2027, 3, 1, 0), TestSupport.day(2027, 4, 1, 0), templateIDs = listOf("bloom")),
        Drop.of("newyear", "Midnight", TestSupport.day(2027, 1, 1, 0), TestSupport.day(2027, 1, 8, 0)),
    ))

    @Test fun activeAndUpcoming() {
        val s = schedule()
        s.validate()
        assertEquals(listOf("holiday", "winter"), s.active(TestSupport.day(2026, 12, 22)).map { it.id })
        assertEquals(emptyList<String>(), s.active(TestSupport.day(2026, 11, 2)).map { it.id })
        assertEquals(listOf("newyear"), s.active(TestSupport.day(2027, 1, 1, 0)).map { it.id })
        assertEquals(listOf("newyear", "spring"), s.upcoming(TestSupport.day(2026, 12, 22)).map { it.id })
        assertEquals(emptyList<String>(), s.upcoming(TestSupport.day(2027, 3, 1, 0)).map { it.id })
    }

    @Test fun scheduleValidationAndRoundTrip() {
        assertEquals(10L, Drop.of("x", "x", Instant.ofEpochMilli(10_900), Instant.ofEpochSecond(20)).startsAt.epochSecond)
        val clean = schedule()
        assertEquals(clean, DropSchedule.decode(clean.encoded()))
        P3.roundTrip(DropSchedule.serializer(), clean)
        try {
            DropSchedule(clean.drops + clean.drops[0]).validate(); fail()
        } catch (e: DropSchedule.ValidationError.DuplicateID) { assertEquals("winter", e.id) }
        try {
            DropSchedule(listOf(Drop.of("b", "b", P3.date, P3.date))).validate(); fail()
        } catch (e: DropSchedule.ValidationError.EndsBeforeStart) { assertEquals("b", e.id) }
    }

    @Test fun streakCountsConsecutiveCalendarDays() {
        val z = TestSupport.zone
        var streak = Streak()
        assertEquals(0, streak.current(TestSupport.day(2026, 12, 30), z))
        streak = streak.record(TestSupport.day(2026, 12, 30, 9), z).record(TestSupport.day(2026, 12, 30, 22), z)
        assertEquals(1, streak.length)
        streak = streak.record(TestSupport.day(2026, 12, 31, 23, 59), z).record(TestSupport.day(2027, 1, 1, 0, 1), z)
        assertEquals(3, streak.current(TestSupport.day(2027, 1, 1), z))
        assertFalse(streak.isAtRisk(TestSupport.day(2027, 1, 1), z))
        assertEquals(3, streak.current(TestSupport.day(2027, 1, 2, 23), z))
        assertTrue(streak.isAtRisk(TestSupport.day(2027, 1, 2), z))
        assertEquals(0, streak.current(TestSupport.day(2027, 1, 3, 0), z))
        streak = streak.record(TestSupport.day(2027, 1, 3), z)
        assertEquals(1, streak.length)
        assertEquals(3, streak.best)
        streak = streak.record(TestSupport.day(2026, 6, 1), z)
        assertEquals(DayStamp(2027, 1, 3), streak.lastDay)
        P3.roundTrip(Streak.serializer(), streak)
    }

    @Test fun streakUsesTheCalendarTimeZone() {
        val lateUTC = LocalDateTime.of(2028, 2, 28, 22, 30).toInstant(ZoneOffset.UTC)
        assertEquals(DayStamp(2028, 2, 28), DayStamp.of(lateUTC, ZoneOffset.UTC))
        assertEquals(DayStamp(2028, 2, 29), DayStamp.of(lateUTC, TestSupport.zone))
        val streak = Streak().record(TestSupport.day(2028, 2, 28), TestSupport.zone).record(lateUTC, TestSupport.zone).record(TestSupport.day(2028, 3, 1), TestSupport.zone)
        assertEquals(3, streak.length)
        assertEquals(2, DayStamp(2028, 3, 1).dayNumber - DayStamp(2028, 2, 28).dayNumber)
        assertEquals(1, DayStamp(2027, 3, 1).dayNumber - DayStamp(2027, 2, 28).dayNumber)
        assertTrue(DayStamp(2026, 12, 31) < DayStamp(2027, 1, 1))
    }
}
