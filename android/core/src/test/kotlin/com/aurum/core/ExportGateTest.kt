package com.aurum.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ExportGateTest {
    private val catalog = TestSupport.smallCatalog
    private fun pearls() = Overlay(content = OverlayContent.Sticker(StickerOverlay("pearls", Tier.member)))

    @Test fun freeEditExportsWithWatermarkAtLimitedSize() {
        val doc = TestSupport.document().applyLook("film.a")
        assertEquals(ExportDecision.Allowed(true, 2048), ExportGate.decision(doc, Entitlement.free, catalog))
    }

    @Test fun premiumLookNeedsMembershipOnFreeTier() {
        val doc = TestSupport.document().applyLook("film.b")
        assertEquals(
            ExportDecision.RequiresMembership(listOf(PremiumItem.Look("film.b", "Bravo"))),
            ExportGate.decision(doc, Entitlement.free, catalog),
        )
    }

    @Test fun membersExportEverythingCleanAtFullSize() {
        val doc = TestSupport.document().applyLook("film.b").addOverlay(pearls())
        assertEquals(ExportDecision.Allowed(false, null), ExportGate.decision(doc, Entitlement.member, catalog))
    }

    @Test fun disabledOrZeroIntensityPremiumLooksDoNotCount() {
        var doc = TestSupport.document().applyLook("film.b").setActiveLookIntensity(0.0)
        assertTrue(ExportGate.premiumItems(doc, catalog).isEmpty())
        doc = doc.setActiveLookIntensity(0.5)
        doc = doc.toggleOperation(doc.operations[0].id)
        assertTrue(ExportGate.premiumItems(doc, catalog).isEmpty())
    }

    @Test fun premiumStickersAndHiddenOverlays() {
        val sticker = pearls()
        var doc = TestSupport.document().addOverlay(sticker)
        assertEquals(listOf(PremiumItem.Sticker("pearls")), ExportGate.premiumItems(doc, catalog))
        doc = doc.updateOverlay(sticker.copy(isHidden = true))
        assertTrue(ExportGate.premiumItems(doc, catalog).isEmpty())
    }

    @Test fun duplicatesAreListedOnce() {
        val doc = TestSupport.document().applyLook("film.b").stackLook("film.b")
        assertEquals(1, ExportGate.premiumItems(doc, catalog).size)
    }

    @Test fun strippingPremiumLeavesAFreeEdit() {
        val doc = TestSupport.document().applyLook("film.a").stackLook("film.b")
            .addOverlay(pearls()).addOverlay(Overlay(content = OverlayContent.Text(TextOverlay("Hi"))))
        val stripped = ExportGate.strippingPremium(doc, catalog)
        assertEquals(listOf("film.a"), stripped.lookApplications.map { it.lookID })
        assertEquals(1, stripped.overlays.size)
        assertEquals(ExportDecision.Allowed(true, 2048), ExportGate.decision(stripped, Entitlement.free, catalog))
    }

    @Test fun retouchIsAMemberFeatureAndCanBeStripped() {
        val catalog = TestSupport.shippedCatalog()
        val doc = TestSupport.document().withRetouch(RetouchSettings(FaceRetouch.natural))
        assertEquals(ExportDecision.RequiresMembership(listOf(PremiumItem.Retouch)), ExportGate.decision(doc, Entitlement.free, catalog))
        assertTrue(ExportGate.strippingPremium(doc, catalog).operations.isEmpty())
    }

    @Test fun freeVideoIsWatermarkedAt1080AndMembersGet4K() {
        val catalog = TestSupport.shippedCatalog()
        val project = VideoProject(effects = listOf(AnimatedEffect.of(AnimatedEffect.Kind.glitter, tier = Tier.member)))
        val free = ExportGate.videoDecision(project, Entitlement.free, catalog)
        assertTrue(free.watermark)
        assertEquals(1920, free.maxPixelSize)
        assertEquals(listOf(PremiumItem.Effect("glitter")), free.premiumItems)
        assertEquals("Glitter", free.premiumItems[0].displayName)
        val member = ExportGate.videoDecision(project, Entitlement.member, catalog)
        assertFalse(member.requiresMembership)
        assertEquals(3840, member.maxPixelSize)
        assertEquals(60, member.maxFrameRate)
    }
}
