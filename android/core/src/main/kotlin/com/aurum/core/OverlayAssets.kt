package com.aurum.core

/**
 * A font offered in the Text tool. The Android app maps [fileName] to the
 * same OFL TTF that iOS bundles (copied unmodified into res/font).
 */
data class OverlayFont(
    val id: String,
    val displayName: String,
    val postScriptName: String,
    /** "serif" or "sans", used when the font file is missing. */
    val fallbackDesign: String,
    val isItalic: Boolean = false,
) {
    /** Android resource name of the font file (lower case, underscores). */
    val resourceName: String get() = postScriptName.replace(Regex("([a-z])([A-Z])"), "$1_$2").replace('-', '_').lowercase()

    companion object {
        val all = listOf(
            OverlayFont("playfair.italic", "Playfair", "PlayfairDisplay-Italic", "serif", isItalic = true),
            OverlayFont("playfair", "Playfair Roman", "PlayfairDisplay-Medium", "serif"),
            OverlayFont("cormorant.italic", "Cormorant", "CormorantGaramond-MediumItalic", "serif", isItalic = true),
            OverlayFont("italiana", "Italiana", "Italiana-Regular", "serif"),
            OverlayFont("bodoni", "Bodoni", "BodoniModa-Medium", "serif"),
            OverlayFont("inter", "Inter", "Inter-Medium", "sans"),
        )

        fun font(id: String): OverlayFont = all.firstOrNull { it.id == id } ?: all[0]
    }
}

/** A sticker in the Stickers tool; artwork is `R.drawable.sticker_<id>`. */
data class StickerDefinition(val id: String, val name: String, val category: String, val tier: Tier) {
    /** Android drawable name, converted from the iOS SVG by tools/sync_android_assets.py. */
    val drawableName: String get() = "sticker_" + id.replace('-', '_')

    companion object {
        val categories = listOf("Ornaments", "Frames", "Celestial", "Notes", "Seasonal")

        val starterSet = listOf(
            StickerDefinition("sparkle", "Sparkle", "Ornaments", Tier.free),
            StickerDefinition("laurel", "Laurel", "Ornaments", Tier.free),
            StickerDefinition("bow", "Bow", "Ornaments", Tier.free),
            StickerDefinition("heart-line", "Heart", "Ornaments", Tier.free),
            StickerDefinition("pearls", "Pearl String", "Ornaments", Tier.member),
            StickerDefinition("monogram", "Monogram", "Ornaments", Tier.member),
            StickerDefinition("oval-frame", "Oval Frame", "Frames", Tier.free),
            StickerDefinition("gallery-frame", "Gallery Frame", "Frames", Tier.member),
            StickerDefinition("crescent", "Crescent", "Celestial", Tier.free),
            StickerDefinition("sunburst", "Sunburst", "Celestial", Tier.free),
            StickerDefinition("constellation", "Constellation", "Celestial", Tier.member),
            StickerDefinition("envelope", "Envelope", "Notes", Tier.free),
            StickerDefinition("wax-seal", "Wax Seal", "Notes", Tier.member),
            StickerDefinition("snowflake", "Snowflake", "Seasonal", Tier.free),
            StickerDefinition("holly", "Holly", "Seasonal", Tier.member),
        )
    }
}
