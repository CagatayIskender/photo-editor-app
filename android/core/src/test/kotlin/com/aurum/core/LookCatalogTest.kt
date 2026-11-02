package com.aurum.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class LookCatalogTest {
    /** Mirrors the deny-list in LookCatalogTests.swift and tools/generate_catalog.py. */
    private val denyList = listOf(
        "vsco", "huji", "dazz", "lightroom", "snapseed", "picsart", "prequel", "facetune",
        "kodak", "fuji", "polaroid", "ilford", "agfa", "instagram", "tiktok", "lomo",
        "portra", "ektar", "velvia", "tri-x", "hp5", "cinestill", "hasselblad", "leica",
    )

    @Test fun shippedCatalogHasOneHundredLooksInTenCollections() {
        val catalog = TestSupport.shippedCatalog()
        assertEquals(100, catalog.looks.size)
        assertEquals(10, catalog.collections.size)
        for (c in catalog.collections) assertEquals(c.id, 10, catalog.looks(c.id).size)
    }

    @Test fun shippedCatalogHasThirtyFreeLooks() {
        assertEquals(30, TestSupport.shippedCatalog().looks.count { it.tier == Tier.free })
    }

    @Test fun noNameUsesADeniedTerm() {
        val catalog = TestSupport.shippedCatalog()
        val names = catalog.looks.map { it.name } + catalog.collections.map { it.name } +
            StickerDefinition.starterSet.map { it.name } + CollageLayout.library.map { it.name }
        for (name in names) for (term in denyList) assertFalse("$name contains $term", name.lowercase().contains(term))
    }

    @Test fun parametersAreInRange() {
        for (look in TestSupport.shippedCatalog().looks) {
            val p = look.params
            for (v in listOf(p.exposure, p.contrast, p.highlights, p.shadows, p.saturation, p.vibrance, p.warmth, p.tint)) {
                assertTrue(look.id, v in -1.0..1.0)
            }
            for (v in listOf(p.fade, p.grain, p.vignette, p.lightLeak, p.bloom)) assertTrue(look.id, v in 0.0..1.0)
            assertEquals(look.id, 3, p.shadowsTint.size)
            assertEquals(look.id, 3, p.highlightsTint.size)
        }
    }

    @Test fun duplicateIDsAreRejected() {
        val c = TestSupport.smallCatalog
        try {
            c.copy(looks = c.looks + c.looks[0]).validate()
            fail()
        } catch (e: LookCatalog.LoadError.DuplicateLookID) {
            assertEquals("film.a", e.id)
        }
    }

    @Test(expected = LookCatalog.LoadError.UnknownCollection::class)
    fun unknownCollectionIsRejected() {
        val c = TestSupport.smallCatalog
        c.copy(looks = c.looks + LookRecipe("x.y", "X", "missing", Tier.free, params = LookParameters())).validate()
    }

    @Test fun neighbourWrapsWithinTheCollection() {
        val c = TestSupport.smallCatalog
        assertEquals("film.b", c.neighbour("film.a", 1)?.id)
        assertEquals("film.a", c.neighbour("film.c", 1)?.id)
        assertEquals("film.c", c.neighbour("film.a", -1)?.id)
        assertEquals("noir.a", c.neighbour("noir.a", 1)?.id)
        assertNull(c.neighbour("nope", 1))
    }

    @Test fun searchRanksNameMatchesFirst() {
        val results = TestSupport.smallCatalog.search("bravo warm")
        assertEquals("film.b", results.first().id)
        assertTrue(results.any { it.id == "film.a" })
    }

    @Test fun searchUsesSynonyms() = assertEquals(listOf("noir.a"), TestSupport.smallCatalog.search("bw").map { it.id })

    @Test fun searchFindsRealLooks() {
        val c = TestSupport.shippedCatalog()
        assertTrue(c.search("warm film").isNotEmpty())
        assertTrue(c.search("90s").isNotEmpty())
        assertFalse(c.search("sparkle").isEmpty() || c.search("glow").isEmpty())
    }

    @Test fun emptySearchReturnsEverything() = assertEquals(4, TestSupport.smallCatalog.search("  ").size)

    @Test fun refineOverridesApply() {
        val refined = LookParameters(grain = 0.2).applying(RefineOverrides(grain = 3.0, fade = 0.4))
        assertEquals(1.0, refined.grain, 0.0)
        assertEquals(0.4, refined.fade, 0.0)
        assertEquals(0.0, refined.vignette, 0.0)
    }

    @Test fun missingParametersDecodeToNeutral() {
        val p = AurumJson.decode<LookParameters>("""{"warmth": 0.3}""")
        assertEquals(0.3, p.warmth, 0.0)
        assertEquals(1.0, p.grainSize, 0.0)
        assertEquals(listOf(1.0, 1.0, 1.0), p.highlightsTint)
        assertFalse(p.monochrome)
    }
}
