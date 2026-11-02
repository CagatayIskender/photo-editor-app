package com.aurum.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.min

class VideoProjectTest {
    private val asset = SourceAsset("v", PixelSize(1920, 1080))
    private fun video(length: Double) = Clip.of(Clip.Kind.video, asset, length)

    @Test fun durationAccountsForTrimSpeedAndTransitions() {
        val a = video(10.0).trimmed(2.0, 6.0)
        val b = video(8.0).withSpeed(2.0).copy(transitionIn = Transition.Dissolve(1.0))
        val project = VideoProject(clips = listOf(a, b))
        assertEquals(listOf(0.0, 3.0), project.clipStartTimes)
        assertEquals(7.0, project.duration, 1e-9)
    }

    @Test fun introAndOutroExtendTheTimeline() {
        val project = VideoProject(clips = listOf(video(5.0)), intro = BookendEffect("curtain", 1.5), outro = BookendEffect("seal", 2.0))
        assertEquals(listOf(1.5), project.clipStartTimes)
        assertEquals(8.5, project.duration, 1e-9)
    }

    @Test fun splitMakesTwoClipsThatPlayTheSameMedia() {
        val project = VideoProject(clips = listOf(video(10.0))).split(4.0)!!
        assertEquals(2, project.clips.size)
        assertEquals(4.0, project.clips[0].trimEnd, 1e-9)
        assertEquals(4.0, project.clips[1].trimStart, 1e-9)
        assertEquals(10.0, project.duration, 1e-9)
        assertNotEquals(project.clips[0].id, project.clips[1].id)
    }

    @Test fun splitRespectsSpeedAndReverse() {
        val clip = video(10.0).withSpeed(2.0).copy(isReversed = true)
        val project = VideoProject(clips = listOf(clip)).split(1.0)!!
        assertEquals(8.0, project.clips[0].trimStart, 1e-9)
        assertEquals(8.0, project.clips[1].trimEnd, 1e-9)
    }

    @Test fun splitTooCloseToAnEdgeIsRefused() {
        val project = VideoProject(clips = listOf(video(10.0)))
        assertNull(project.split(0.05))
        assertNull(project.split(9.95))
    }

    @Test fun trimAndSpeedAreClamped() {
        var clip = video(5.0).trimmed(4.95, 2.0)
        assertTrue(clip.trimEnd - clip.trimStart >= Clip.MINIMUM_DURATION - 1e-9)
        assertTrue(clip.trimEnd <= 5.0)
        clip = clip.withSpeed(100.0)
        assertEquals(4.0, clip.speed, 0.0)
    }

    @Test fun clipLookup() {
        val project = VideoProject(clips = listOf(video(3.0), video(2.0)))
        assertEquals(0, project.clipAt(1.0)?.first)
        assertEquals(1, project.clipAt(3.5)?.first)
        assertEquals(0.5, project.clipAt(3.5)!!.second, 1e-9)
        assertNull(project.clipAt(6.0))
    }

    @Test fun reorder() {
        val a = video(1.0); val b = video(2.0); val c = video(3.0)
        val project = VideoProject(clips = listOf(a, b, c)).moveClip(2, 0)
        assertEquals(listOf(c.id, a.id, b.id), project.clips.map { it.id })
    }

    @Test fun roundTripThroughJSON() {
        var project = VideoProject(clips = listOf(video(4.0), Clip.photo(asset)))
        project = project.copy(
            clips = project.clips.mapIndexed { i, c -> if (i == 1) c.copy(transitionIn = Transition.Slide(0.8)) else c },
            layers = listOf(TimedLayer.of(Overlay(content = OverlayContent.Text(TextOverlay("Hi"))), 1.0, 3.0, animationIn = LayerAnimation.rise)),
            music = MusicSelection(MusicSource.Library("t1"), "Velvet", beats = BeatGrid.of(96.0)),
            effects = listOf(AnimatedEffect.of(AnimatedEffect.Kind.lightLeak)),
        )
        assertEquals(project, VideoProject.decode(project.encoded()))
    }

    @Test fun layerPresenceFadesInAndOut() {
        val layer = TimedLayer.of(Overlay(content = OverlayContent.Text(TextOverlay("x"))), 1.0, 3.0, animationDuration = 0.5)
        assertEquals(0.0, layer.presence(0.5), 0.0)
        assertEquals(0.5, layer.presence(1.25), 1e-9)
        assertEquals(1.0, layer.presence(2.0), 0.0)
        assertEquals(0.5, layer.presence(2.75), 1e-9)
    }

    @Test fun musicFades() {
        val music = MusicSelection(MusicSource.Imported("a.m4a"), "A", volume = 1.0, fadeIn = 1.0, fadeOut = 2.0)
        assertEquals(0.5, music.gain(0.5, 10.0), 1e-9)
        assertEquals(1.0, music.gain(5.0, 10.0), 0.0)
        assertEquals(0.5, music.gain(9.0, 10.0), 1e-9)
    }

    @Test fun undoableCoalescesTransactions() {
        val history = Undoable(VideoProject(clips = listOf(video(4.0))))
        var p = history.current
        for (v in listOf(1.5, 2.0, 3.0)) {
            p = p.copy(clips = listOf(p.clips[0].withSpeed(v)))
            history.update(p)
        }
        history.commit(p)
        assertEquals(3.0, history.current.clips[0].speed, 0.0)
        history.undo()
        assertEquals(1.0, history.current.clips[0].speed, 0.0)
        assertTrue(!history.canUndo)
        history.redo()
        assertEquals(3.0, history.current.clips[0].speed, 0.0)
    }
}

class TemplateTest {
    private val photo = TemplateMedia(SourceAsset("p", PixelSize(100, 100)), Clip.Kind.photo)

    @Test fun beatGrid() {
        val grid = BeatGrid.of(120.0, 0.25)
        assertEquals(0.5, grid.beatLength, 0.0)
        assertEquals(listOf(0.25, 0.75, 1.25, 1.75), grid.beats(0.0, 2.0))
        assertEquals(1.25, grid.quantize(1.1), 1e-9)
    }

    @Test fun cutsLandOnTheBeat() {
        val template = TemplateDefinition("t", "T", "", Tier.free, slots = listOf(
            TemplateSlot(2), TemplateSlot(4, Transition.Dissolve(0.25)), TemplateSlot(2),
        ), bpm = 120.0)
        val project = TemplateBuilder.build(template, listOf(photo, photo, photo))
        val starts = project.clipStartTimes
        assertEquals(1.0, starts[1] + project.clips[1].transitionIn.duration, 1e-9)
        assertEquals(3.0, starts[2], 1e-9)
        assertEquals(4.0, project.duration, 1e-9)
    }

    @Test fun mediaCyclesWhenThereAreFewerItemsThanSlots() {
        val b = TemplateMedia(SourceAsset("b", PixelSize(1, 1)), Clip.Kind.photo)
        val template = TemplateDefinition("t", "T", "", Tier.free, slots = List(5) { TemplateSlot(1) })
        assertEquals(listOf("p", "b", "p", "b", "p"), TemplateBuilder.build(template, listOf(photo, b)).clips.map { it.source.localIdentifier })
    }

    @Test fun shortVideoIsSlowedToFillItsSlot() {
        val short = TemplateMedia(SourceAsset("v", PixelSize(1, 1)), Clip.Kind.video, 1.0)
        val template = TemplateDefinition("t", "T", "", Tier.free, slots = listOf(TemplateSlot(4)), bpm = 120.0)
        val project = TemplateBuilder.build(template, listOf(short))
        assertEquals(0.5, project.clips[0].speed, 1e-9)
        assertEquals(2.0, project.duration, 1e-9)
    }

    @Test fun longVideoUsesItsMiddle() {
        val long = TemplateMedia(SourceAsset("v", PixelSize(1, 1)), Clip.Kind.video, 10.0)
        val template = TemplateDefinition("t", "T", "", Tier.free, slots = listOf(TemplateSlot(4)), bpm = 120.0)
        val clip = TemplateBuilder.build(template, listOf(long)).clips[0]
        assertEquals(4.0, clip.trimStart, 1e-9)
        assertEquals(6.0, clip.trimEnd, 1e-9)
    }

    @Test(expected = TemplateBuilder.NoMedia::class)
    fun noMediaIsAnError() {
        TemplateBuilder.build(TemplateDefinition("t", "T", "", Tier.free, slots = listOf(TemplateSlot(1))), emptyList())
    }

    @Test fun shippedTemplatesAreValid() {
        val templates = ContentCatalogs.templates(TestSupport.repoFile("Content/templates.json"))
        assertTrue(templates.size >= 12)
        assertEquals(templates.size, templates.map { it.id }.toSet().size)
        val catalog = TestSupport.shippedCatalog()
        for (t in templates) {
            assertTrue(t.id, t.slots.isNotEmpty())
            t.lookID?.let { assertNotNull("${t.id} uses unknown look $it", catalog.look(it)) }
        }
    }

    @Test fun shippedBookendsDropsAndBrandDecode() {
        val bookends = ContentCatalogs.bookends(TestSupport.repoFile("Content/bookends.json"))
        assertTrue(bookends.any { it.kind == BookendPreset.Kind.intro } && bookends.any { it.kind == BookendPreset.Kind.outro })
        val drops = ContentCatalogs.drops(TestSupport.repoFile("Content/drops.json"))
        assertEquals(3, drops.drops.size)
        val catalog = TestSupport.shippedCatalog()
        for (d in drops.drops) for (look in d.lookIDs) assertNotNull("${d.id}: $look", catalog.look(look))
        assertTrue(ContentCatalogs.music(TestSupport.repoFile("Content/music.json")).isEmpty())
        val brand = BrandConfig.decode(TestSupport.repoFile("Brand/brand.json"))
        assertEquals("#0B0B0C", brand.colors.onyx)
        assertEquals("#C9A86A", brand.colors.champagne)
        assertEquals(ExportGate.FREE_MAX_PIXEL_SIZE, brand.freeExportMaxPixelSize)
    }
}

class AnimatedEffectTest {
    @Test fun samplesAreDeterministic() {
        for (kind in AnimatedEffect.Kind.entries) {
            val e = AnimatedEffect.of(kind, seed = 42uL)
            assertEquals(kind.name, e.sample(1.234), e.sample(1.234))
        }
    }

    @Test fun inactiveEffectIsNeutral() {
        val e = AnimatedEffect.of(AnimatedEffect.Kind.shake, start = 2.0, end = 4.0)
        assertEquals(AnimatedEffect.Sample(), e.sample(1.0))
        assertEquals(AnimatedEffect.Sample(), e.sample(5.0))
        assertNotEquals(AnimatedEffect.Sample(), e.sample(3.0))
    }

    @Test fun valuesStayInSensibleRanges() {
        for (kind in AnimatedEffect.Kind.entries) {
            val e = AnimatedEffect.of(kind, intensity = 1.0, rate = 2.0, seed = 7uL)
            for (i in 0 until 500) {
                val s = e.sample(i / 30.0)
                assertTrue("$kind exposure ${s.exposure}", s.exposure in 0.7..1.3)
                assertTrue(kind.name, s.leak in 0.0..1.0 && s.glitter in 0.0..1.0 && s.tracking in 0.0..1.0)
                assertTrue(kind.name, abs(s.offsetX) <= 0.02 && abs(s.offsetY) <= 0.02)
                assertTrue("$kind zoom ${s.zoom}", s.zoom in 1.0..1.1)
            }
        }
    }

    @Test fun noiseIsBounded() {
        for (i in 0 until 1000) assertTrue(AnimatedEffect.noise(i * 0.37, 3uL) in -1.0..1.0)
    }

    /** Large seeds survive JSON as unsigned 64-bit numbers, as Swift writes UInt64. */
    @Test fun unsignedSeedRoundTrips() {
        val e = AnimatedEffect.of(AnimatedEffect.Kind.flicker, seed = ULong.MAX_VALUE)
        val json = AurumJson.encode(e)
        assertTrue(json, json.contains("\"seed\":18446744073709551615"))
        assertEquals(e, AurumJson.decode<AnimatedEffect>(json))
    }
}

class BeatDetectorTest {
    private fun clicks(bpm: Double, offset: Double, seconds: Double, sampleRate: Double = 8000.0): FloatArray {
        val samples = FloatArray((seconds * sampleRate).toInt())
        var rng = 12345uL
        var t = offset
        while (t < seconds) {
            val start = (t * sampleRate).toInt()
            for (i in 0 until (0.03 * sampleRate).toInt()) {
                if (start + i >= samples.size) break
                rng = rng * 6364136223846793005uL + 1442695040888963407uL
                val noise = ((rng shr 11).toLong() % 2000).toFloat() / 1000 - 1
                samples[start + i] = noise * exp(-i / (0.008 * sampleRate)).toFloat()
            }
            t += 60 / bpm
        }
        return samples
    }

    @Test fun findsTempoAndPhaseOfAClickTrack() {
        for ((bpm, offset) in listOf(120.0 to 0.2, 96.0 to 0.05, 140.0 to 0.3)) {
            val grid = BeatDetector.detect(clicks(bpm, offset, 12.0), 8000.0)!!
            assertEquals("bpm $bpm", bpm, grid.bpm, bpm * 0.02)
            assertTrue("bpm $bpm", abs(grid.quantize(offset) - offset) < 0.02)
            val beatError = (grid.offset - offset).rem(60 / bpm)
            assertTrue("bpm $bpm", min(abs(beatError), 60 / bpm - abs(beatError)) < 0.02)
        }
    }

    @Test fun silenceAndShortAudioGiveNoGrid() {
        assertNull(BeatDetector.detect(FloatArray(80000), 8000.0))
        assertNull(BeatDetector.detect(floatArrayOf(0.1f, 0.2f), 8000.0))
    }
}
