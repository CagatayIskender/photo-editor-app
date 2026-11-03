package com.aurum.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

/** Checks the wire format against what Swift's Codable writes and reads. */
class JsonCompatibilityTest {
    @Test fun fixtureSurvivesARoundTripWithTheSameKeys() {
        val original = AurumJson.format.parseToJsonElement(TestSupport.fixture("document_v1")).jsonObject
        val doc = EditDocument.decode(TestSupport.fixture("document_v1"))
        val again = AurumJson.format.parseToJsonElement(doc.encoded()).jsonObject
        assertEquals(original.keys, again.keys)
        assertEquals("6B2C3B0E-7A3E-4F57-9B3A-2E8C1A2F9D10", again["id"]!!.jsonPrimitive.content)
        assertEquals("2026-11-02T09:00:00Z", again["createdAt"]!!.jsonPrimitive.content)
        val op = (again["operations"] as kotlinx.serialization.json.JsonArray)[0].jsonObject
        assertEquals("look", op["kind"]!!.jsonObject["type"]!!.jsonPrimitive.content)
        // Swift escapes forward slashes; decoders accept both forms.
        assertTrue(doc.encoded().contains("ABC-123\\/L0\\/001"))
        assertEquals(doc, EditDocument.decode(doc.encoded()))
    }

    @Test fun nullOptionalsAreOmittedAndDefaultsWritten() {
        val json = AurumJson.encodeCanonical(StickerOverlay.serializer(), StickerOverlay("sparkle"))
        assertEquals("""{"stickerID":"sparkle","tier":"free"}""", json)
        val adjust = AurumJson.format.parseToJsonElement(AurumJson.encode(AdjustmentSet())) as JsonObject
        assertEquals(20, adjust.size)
        assertTrue(adjust.containsKey("splitToning"))
    }

    @Test fun transitionsUseTheSwiftTags() {
        assertEquals("""{"type":"cut"}""", AurumJson.encodeCanonical(TransitionSerializer, Transition.Cut))
        assertEquals("""{"duration":0.5,"type":"dipToBlack"}""", AurumJson.encodeCanonical(TransitionSerializer, Transition.DipToBlack(0.5)))
        assertEquals(Transition.Dissolve(0.8), AurumJson.decode<Transition>("""{"duration":0.8,"jobID":"j","type":"ai"}"""))
        assertEquals(Transition.Dissolve(0.5), AurumJson.decode<Transition>("""{"type":"dissolve"}"""))
    }

    @Test fun musicSourceUsesSwiftEnumCoding() {
        assertEquals("""{"library":{"trackID":"t1"}}""", AurumJson.encodeCanonical(MusicSourceSerializer, MusicSource.Library("t1")))
        assertEquals(MusicSource.Imported("a.m4a"), AurumJson.decode<MusicSource>("""{"imported":{"fileName":"a.m4a"}}"""))
    }

    @Test fun uuidsAreUpperCaseAndReadInAnyCase() {
        val op = EditOperation(id = java.util.UUID.fromString("0f9d0b4e-1c2a-4c35-8a4b-3b7e9e1d2c01"), kind = OperationKind.Adjust(AdjustmentSet()))
        val json = AurumJson.encode(op)
        assertTrue(json.contains("0F9D0B4E-1C2A-4C35-8A4B-3B7E9E1D2C01"))
        assertFalse(json.contains("0f9d0b4e"))
        assertEquals(op, AurumJson.decode<EditOperation>(json.replace("0F9D0B4E", "0f9d0b4e")))
    }

    @Test fun datesAcceptOffsetsAndDropFractions() {
        val doc = TestSupport.document().copy(createdAt = Instant.ofEpochMilli(1_800_000_000_999))
        assertTrue(doc.encoded().contains("\"createdAt\":\"2027-01-15T08:00:00Z\""))
        val shifted = doc.encoded().replace("\"createdAt\":\"2027-01-15T08:00:00Z\"", "\"createdAt\":\"2027-01-15T11:00:00+03:00\"")
        assertEquals(1_800_000_000L, EditDocument.decode(shifted).createdAt.epochSecond)
    }

    @Test fun canonicalNumbers() {
        assertEquals("1", AurumJson.canonicalNumber("1.0"))
        assertEquals("100", AurumJson.canonicalNumber("100.0"))
        assertEquals("0.0001", AurumJson.canonicalNumber("1.0E-4"))
        assertEquals("0.25", AurumJson.canonicalNumber("0.25"))
        assertEquals("-3", AurumJson.canonicalNumber("-3"))
    }

    @Test fun catalogueRoundTrips() {
        val catalog = TestSupport.shippedCatalog()
        assertEquals(catalog, LookCatalog.decode(AurumJson.encode(catalog)))
    }
}
