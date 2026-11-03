package com.aurum.core

import com.aurum.core.render.VideoGrade
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VideoRenderingTest {
    private val src = SourceAsset("a", PixelSize(1080, 1920))

    private fun project(): VideoProject = VideoProject(
        clips = listOf(
            Clip.photo(src, 3.0),
            Clip.of(Clip.Kind.video, src, 10.0, trimStart = 2.0, trimEnd = 6.0, transitionIn = Transition.Dissolve(0.5)),
            Clip.of(Clip.Kind.video, src, 8.0, trimStart = 1.0, trimEnd = 5.0, speed = 2.0, isReversed = true, transitionIn = Transition.Slide(0.5)),
        ),
        intro = BookendEffect("curtain", 1.5),
        outro = BookendEffect("monogram", 1.5),
    )

    @Test fun itemsTileTheTimelineExactly() {
        val p = project()
        val items = VideoRenderPlan.items(p)
        assertEquals(5, items.size)
        var t = 0.0
        for (item in items) {
            assertEquals(t, item.start, 1e-9)
            t += item.duration
        }
        assertEquals(p.duration, t, 1e-9)
        // Photo is cut where the dissolve starts.
        assertEquals(2.5, items[1].duration, 1e-9)
        // Video: 4 s source minus the slide overlap of 0.5 s.
        assertEquals(3.5, items[2].duration, 1e-9)
        assertEquals(2.0, items[2].sourceStart, 1e-9)
        assertEquals(5.5, items[2].sourceEnd, 1e-9)
        // Reversed at 2x: reversed file starts at 8 - 5 = 3, plays its full 4 s of source.
        assertEquals(3.0, items[3].sourceStart, 1e-9)
        assertEquals(7.0, items[3].sourceEnd, 1e-9)
        assertEquals(2.0, items[3].duration, 1e-9)
    }

    @Test fun transitionWindows() {
        val w = VideoRenderPlan.transitions(project())
        assertEquals(2, w.size)
        assertEquals(1, w[0].clipIndex)
        assertEquals(4.0, w[0].start, 1e-9)
        assertEquals(2.5, w[0].outgoingLocal, 1e-9)
        assertTrue(VideoRenderPlan.isBookend(project(), 0.2))
        assertFalse(VideoRenderPlan.isBookend(project(), 3.0))
    }

    @Test fun renderSizeIsEven() {
        assertEquals(PixelSize(540, 960), VideoRenderPlan.renderSize(AspectPreset.story, 960))
        assertEquals(PixelSize(1920, 1080), VideoRenderPlan.renderSize(AspectPreset.landscape, 1920))
        assertEquals(PixelSize(1536, 1920), VideoRenderPlan.renderSize(AspectPreset.portrait, 1920))
    }

    @Test fun layerAnimation() {
        val layer = TimedLayer.of(Overlay(content = OverlayContent.Text(TextOverlay("Hello"))), 1.0, 4.0, LayerAnimation.typewriter, LayerAnimation.fade)
        val p = VideoProject(clips = listOf(Clip.photo(src, 5.0)), layers = listOf(layer))
        assertTrue(LayerAnimator.overlays(p, 0.5).isEmpty())
        val mid = LayerAnimator.overlays(p, 1.2).single()
        assertEquals("Hel", (mid.content as OverlayContent.Text).text.text)
        assertEquals(1.0, LayerAnimator.overlays(p, 2.5).single().opacity, 1e-9)
        assertTrue(LayerAnimator.overlays(p, 3.95).single().opacity < 0.5)
    }

    @Test fun memberBookendsAreGatedAndStripped() {
        val bookends = listOf(
            BookendPreset("curtain", "Curtain", BookendPreset.Kind.intro, 1.5, Tier.free),
            BookendPreset("spotlight", "Spotlight", BookendPreset.Kind.intro, 1.5, Tier.member),
        )
        val p = VideoProject(clips = listOf(Clip.photo(src)), intro = BookendEffect("spotlight"))
        val d = VideoExportRules.decision(p, Entitlement.free, TestSupport.smallCatalog, emptyList(), bookends)
        assertTrue(d.requiresMembership)
        assertTrue(VideoExportRules.canExportWithoutPremium(d.premiumItems))
        assertNull(VideoExportRules.strippingPremium(p, TestSupport.smallCatalog, bookends).intro)
        val member = VideoExportRules.decision(p, Entitlement.member, TestSupport.smallCatalog, emptyList(), bookends)
        assertFalse(member.requiresMembership)
        assertFalse(VideoExportRules.canExportWithoutPremium(listOf(PremiumItem.Template("t", "T"))))
    }

    @Test fun gradeIsIdentityWithoutLooks() {
        assertTrue(VideoGrade.of(emptyList(), TestSupport.smallCatalog).isIdentity)
    }

    @Test fun gradeBakesShippedLook() {
        val catalog = TestSupport.shippedCatalog()
        val look = catalog.looks.first { it.params.contrast != 0.0 || it.params.warmth != 0.0 }
        val grade = VideoGrade.of(listOf(EditOperation(kind = OperationKind.Look(LookApplication.of(look.id, 1.0)))), catalog)
        assertNotNull(grade.lut)
        assertEquals(33 * 33 * 33 * 3, grade.lut!!.size)
        assertTrue(grade.lut!!.all { it in 0f..1f })
    }
}
