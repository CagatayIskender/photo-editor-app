package com.aurum.core

import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer

/** Brand/brand.json: every brand string, colour and product id, so a rename is one change. */
@Serializable
data class BrandConfig(
    val appName: String,
    val membershipName: String,
    val watermarkText: String,
    val urlScheme: String,
    val products: Products,
    val colors: Colors,
    val fonts: Fonts,
    val freeExportMaxPixelSize: Int = ExportGate.FREE_MAX_PIXEL_SIZE,
) {
    @Serializable
    data class Products(val weekly: String, val yearly: String, val credits20: String? = null, val credits100: String? = null)

    @Serializable
    data class Colors(
        val onyx: String,
        val graphite: String,
        val graphiteRaised: String,
        val hairline: String,
        val ivory: String,
        val ivoryDim: String,
        val stone: String,
        val champagne: String,
        val ivoryThemeBackground: String? = null,
        val ivoryThemeText: String? = null,
        val ivoryThemeAccent: String? = null,
    )

    @Serializable
    data class Fonts(val display: String, val displayItalic: String, val text: String, val textMedium: String, val textSemibold: String)

    companion object {
        fun decode(json: String): BrandConfig = AurumJson.format.decodeFromString(serializer(), json)
    }
}

/** Decoders for the shared Content JSON catalogues. */
object ContentCatalogs {
    fun templates(json: String): List<TemplateDefinition> =
        AurumJson.format.decodeFromString(ListSerializer(TemplateDefinition.serializer()), json)

    fun bookends(json: String): List<BookendPreset> =
        AurumJson.format.decodeFromString(ListSerializer(BookendPreset.serializer()), json)

    fun music(json: String): List<MusicTrack> =
        AurumJson.format.decodeFromString(ListSerializer(MusicTrack.serializer()), json)

    fun drops(json: String): DropSchedule = DropSchedule.decode(json)
}
