package com.aurum.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.time.Instant

class PresetTest {
    private fun samplePreset(): Preset {
        val doc = TestSupport.document().applyLook("film.a", 0.7).stackLook("noir.a", 0.3).withAdjustments(AdjustmentSet(exposure = 0.1))
        return Preset.from("Gallery night", doc)
    }

    @Test fun linkRoundTrip() {
        val preset = samplePreset()
        val codec = PresetLinkCodec()
        val link = codec.link(preset)
        assertTrue(link.startsWith("aurum://preset/"))
        assertFalse("base64url has no padding", link.contains("="))
        val decoded = codec.preset(link)
        assertEquals("Gallery night", decoded.name)
        assertEquals(preset.operations, decoded.operations)
    }

    @Test fun customSchemeFromBrandConfig() {
        val link = PresetLinkCodec("maison").link(samplePreset())
        assertTrue(link.startsWith("maison://"))
        try {
            PresetLinkCodec().preset(link)
            fail()
        } catch (e: PresetLinkCodec.LinkError) {
            assertEquals(PresetLinkCodec.LinkError.WrongScheme, e)
        }
    }

    @Test fun rejectsGarbage() {
        val codec = PresetLinkCodec()
        for ((link, expected) in listOf(
            "aurum://preset/!!!" to null,
            "aurum://preset/aGVsbG8" to PresetLinkCodec.LinkError.InvalidPayload,
            "aurum://draft/abc" to PresetLinkCodec.LinkError.NotAPresetLink,
        )) {
            try {
                codec.preset(link)
                fail(link)
            } catch (e: PresetLinkCodec.LinkError) {
                if (expected != null) assertEquals(link, expected, e)
            }
        }
    }

    @Test fun applyReplacesOperationsWithFreshIDs() {
        val preset = samplePreset()
        val target = TestSupport.document().applyLook("film.b")
        val once = preset.apply(target)
        val twice = preset.apply(target)
        assertEquals(listOf("film.a", "noir.a"), once.lookApplications.map { it.lookID })
        assertEquals(0.1, once.adjustments.exposure, 0.0)
        assertNotEquals(once.operations.map { it.id }, twice.operations.map { it.id })
        assertEquals(target.source, once.source)
    }

    @Test fun disabledOperationsAreNotSaved() {
        var doc = TestSupport.document().applyLook("film.a").stackLook("film.b")
        doc = doc.toggleOperation(doc.operations[1].id)
        assertEquals(1, Preset.from("x", doc).operations.size)
    }

    /**
     * The exact link iOS produces for this preset (sorted keys, integral
     * numbers without ".0", upper-case UUIDs), so links are interchangeable.
     */
    @Test fun linkBytesMatchTheSwiftEncoding() {
        val preset = Preset(
            id = TestSupport.id(9),
            name = "Salon",
            operations = listOf(EditOperation(id = TestSupport.id(10), kind = OperationKind.Look(LookApplication("film.a", 1.0)))),
            createdAt = Instant.ofEpochSecond(1_800_000_000),
        )
        val json = AurumJson.encodeCanonical(Preset.serializer(), preset)
        assertEquals(
            """{"createdAt":"2027-01-15T08:00:00Z","id":"00000000-0000-0000-0000-000000000009","name":"Salon",""" +
                """"operations":[{"id":"00000000-0000-0000-0000-000000000010","isEnabled":true,"kind":{"look":{"intensity":1,"lookID":"film.a","refine":{}},"type":"look"}}],"schemaVersion":1}""",
            json,
        )
        assertEquals("aurum://preset/" + PresetLinkCodec.base64UrlEncode(json.toByteArray()), PresetLinkCodec().link(preset))
    }
}
