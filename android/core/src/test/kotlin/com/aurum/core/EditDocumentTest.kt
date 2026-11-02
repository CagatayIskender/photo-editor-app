package com.aurum.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class EditDocumentTest {
    @Test fun newDocumentIsPristine() = assertTrue(TestSupport.document().isPristine)

    @Test fun applyLookReplacesTheActiveLook() {
        val doc = TestSupport.document().applyLook("film.a").applyLook("film.b")
        assertEquals(listOf("film.b"), doc.lookApplications.map { it.lookID })
        assertFalse(doc.isPristine)
    }

    @Test fun stackLookAddsALayer() {
        val doc = TestSupport.document().applyLook("film.a").stackLook("noir.a")
        assertEquals(listOf("film.a", "noir.a"), doc.lookApplications.map { it.lookID })
    }

    @Test fun looksStayBelowAdjustments() {
        val doc = TestSupport.document().withAdjustments(AdjustmentSet(exposure = 0.3)).applyLook("film.a").stackLook("film.b")
        assertTrue("adjustments stay on top", doc.operations.last().kind is OperationKind.Adjust)
        assertEquals(listOf("film.a", "film.b"), doc.lookApplications.map { it.lookID })
    }

    @Test fun neutralAdjustmentsDoNotAddAnOperation() {
        assertTrue(TestSupport.document().withAdjustments(AdjustmentSet()).operations.isEmpty())
    }

    @Test fun intensityIsClamped() {
        var doc = TestSupport.document().applyLook("film.a").setActiveLookIntensity(1.7)
        assertEquals(1.0, doc.lookApplications.first().intensity, 0.0)
        doc = doc.setActiveLookIntensity(-2.0)
        assertEquals(0.0, doc.lookApplications.first().intensity, 0.0)
        assertTrue("a look at zero intensity changes nothing", doc.isPristine)
    }

    @Test fun toggleAndMoveOperations() {
        var doc = TestSupport.document().applyLook("film.a").stackLook("noir.a")
        val first = doc.operations[0].id
        doc = doc.toggleOperation(first)
        assertFalse(doc.operations[0].isEnabled)
        doc = doc.moveOperation(0, 2)
        assertEquals(first, doc.operations.last().id)
    }

    @Test fun adjustmentSetterClampsToTheControlRange() {
        var a = AdjustmentSet().with(AdjustmentControl.grain, -0.5)
        assertEquals("grain is 0...1", 0.0, a.grain, 0.0)
        a = a.with(AdjustmentControl.exposure, 4.0)
        assertEquals(1.0, a.exposure, 0.0)
        a = a.with(AdjustmentControl.exposure, Double.NaN)
        assertEquals(-1.0, a.exposure, 0.0)
    }

    @Test fun roundTripThroughJSON() {
        var doc = TestSupport.document().applyLook("film.b", 0.6).setActiveLookRefine(RefineOverrides(grain = 0.5))
        val a = AdjustmentSet(warmth = 0.2, hsl = HSLAdjustments().with(HSLAdjustments.Band.blue, HSLAdjustments.Shift(0.1, -0.3, 0.0)))
        doc = doc.withAdjustments(a)
            .copy(crop = CropSpec.centred(AspectPreset.square, doc.source.pixelSize))
            .addOverlay(Overlay(content = OverlayContent.Text(TextOverlay("Hello"))))
            .addOverlay(Overlay(content = OverlayContent.Sticker(StickerOverlay("sparkle"))))
        assertEquals(doc, EditDocument.decode(doc.encoded()))
    }

    @Test fun decodesTheVersionOneFixture() {
        val doc = EditDocument.decode(TestSupport.fixture("document_v1"))
        assertEquals("film-analog.linen", doc.lookApplications.first().lookID)
        assertEquals(0.4, doc.lookApplications.first().refine.grain!!, 0.0)
        assertEquals(0.2, doc.adjustments.exposure, 0.0)
        assertEquals("missing keys take their default", 0.0, doc.adjustments.contrast, 0.0)
        assertEquals(AspectPreset.portrait, doc.crop.aspect)
        assertEquals(1, doc.overlays.size)
        assertEquals("Côte d'Azur", (doc.overlays[0].content as OverlayContent.Text).text.text)
    }

    @Test fun refusesDocumentsFromTheFuture() {
        val json = TestSupport.fixture("document_v1").replace("\"schemaVersion\": 1", "\"schemaVersion\": 99")
        try {
            EditDocument.decode(json)
            fail("expected an error")
        } catch (e: DocumentMigrator.MigrationError.NewerThanSupported) {
            assertEquals(99, e.version)
        }
    }

    @Test fun centredCropMatchesTheAspect() {
        val source = PixelSize(4000, 3000)
        assertEquals(PixelSize(3000, 3000), CropSpec.centred(AspectPreset.square, source).outputSize(source))
        val size = CropSpec.centred(AspectPreset.story, source).outputSize(source)
        assertEquals(9.0 / 16.0, size.width.toDouble() / size.height, 0.01)
        val wide = CropSpec.centred(AspectPreset.landscape, source)
        assertEquals(1.0, wide.rect.width, 0.0)
        assertEquals(4000, wide.outputSize(source).width)
    }

    @Test fun quarterTurnsSwapOutputSize() {
        val crop = CropSpec.of(quarterTurns = 5)
        assertEquals(1, crop.quarterTurns)
        assertEquals(PixelSize(300, 400), crop.outputSize(PixelSize(400, 300)))
    }

    @Test fun fittingKeepsAspectRatio() {
        assertEquals(PixelSize(2048, 1536), PixelSize(4032, 3024).fitting(2048))
        assertEquals(PixelSize(100, 50), PixelSize(100, 50).fitting(2048))
    }

    @Test fun clampedRectStaysInside() {
        val r = NormalizedRect(0.9, -0.2, 0.5, 0.01).clamped()
        assertEquals(0.5, r.x, 1e-9)
        assertEquals(0.0, r.y, 0.0)
        assertEquals(0.05, r.height, 0.0)
    }

    @Test fun retouchSitsAtTheBottomOfTheStack() {
        val doc = TestSupport.document().applyLook("film-analog.linen").withRetouch(RetouchSettings(FaceRetouch(smoothing = 0.4)))
        assertTrue(doc.operations.first().kind is OperationKind.Retouch)
        assertEquals(0.4, doc.retouch.global.smoothing, 0.0)
        assertFalse(doc.isPristine)
        assertTrue(TestSupport.document().withRetouch(RetouchSettings()).operations.isEmpty())
    }

    @Test fun reshapeIsClampedAndPerFaceOverrides() {
        val face = FaceRetouch().with(RetouchControl.jaw, -3.0).with(RetouchControl.smoothing, 2.0)
        assertEquals(-1.0, face.jaw, 0.0)
        assertEquals(1.0, face.smoothing, 0.0)
        val settings = RetouchSettings(FaceRetouch.natural, mapOf(1 to FaceRetouch(eyes = 0.3)))
        assertEquals(FaceRetouch.natural, settings.settings(0))
        assertEquals(0.3, settings.settings(1).eyes, 0.0)
    }

    @Test fun retouchRoundTripUsesStringFaceKeys() {
        val settings = RetouchSettings(FaceRetouch.natural, mapOf(2 to FaceRetouch()))
        val doc = TestSupport.document().withRetouch(settings)
        val json = doc.encoded()
        assertTrue(json, json.contains("\"perFace\":{\"2\":"))
        assertEquals(settings, EditDocument.decode(json).retouch)
    }

    @Test fun activeLookIndexIsNullWithoutLooks() = assertNull(TestSupport.document().activeLookIndex)
}
