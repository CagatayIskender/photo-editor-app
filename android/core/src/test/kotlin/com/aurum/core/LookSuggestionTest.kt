package com.aurum.core

import org.junit.Assert.assertEquals
import org.junit.Test

class LookSuggestionTest {
    private val catalog = TestSupport.shippedCatalog()

    @Test fun blackAndWhitePhotosGetNoir() =
        assertEquals("noir", LookSuggestion.suggest(ImageStats(0.5, 0.02, 0.0), listOf("riviera"), catalog)?.collection)

    @Test fun chosenVibeWinsForColourPhotos() =
        assertEquals("prism", LookSuggestion.suggest(ImageStats(0.5, 0.3, 0.2), listOf("prism"), catalog)?.collection)

    @Test fun warmPhotoWithoutVibesGetsFilm() =
        assertEquals("film-analog", LookSuggestion.suggest(ImageStats(0.5, 0.3, 0.2), emptyList(), catalog)?.collection)

    @Test fun onlyFreeLooksAreSuggested() {
        for (i in 0..10) assertEquals(Tier.free, LookSuggestion.suggest(ImageStats(i / 10.0, 0.3, 0.0), listOf("seasons"), catalog)?.tier)
    }
}
