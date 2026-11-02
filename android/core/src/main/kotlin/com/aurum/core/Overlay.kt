package com.aurum.core

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.util.UUID

/** How an overlay mixes with the photo beneath it. */
@Serializable
enum class BlendMode { normal, screen, multiply, overlay, softLight, lighten, darken }

/** Decorative treatment for a text overlay. */
@Serializable
enum class TextStyle { plain, outline, shadow, glow, gradient, box }

@Serializable
enum class TextAlignment { leading, center, trailing }

@Serializable
data class TextOverlay(
    val text: String,
    /** A font id from [OverlayFont.all], e.g. "playfair.italic". */
    val fontID: String = "playfair.italic",
    /** Point size at a 1080 px wide render. */
    val size: Double = 64.0,
    val colorHex: String = "#F4EFE6",
    val style: TextStyle = TextStyle.shadow,
    val alignment: TextAlignment = TextAlignment.center,
)

@Serializable
data class StickerOverlay(
    val stickerID: String,
    val tier: Tier = Tier.free,
    /** Optional recolour; null keeps the sticker's own colours. */
    val tintHex: String? = null,
)

/**
 * Text or a sticker placed on the photo, positioned in coordinates normalised
 * to the crop rectangle.
 */
@Serializable
data class Overlay(
    @Serializable(with = UuidSerializer::class) val id: UUID = UUID.randomUUID(),
    val content: OverlayContent,
    val center: NormalizedPoint = NormalizedPoint.center,
    val scale: Double = 1.0,
    val rotationDegrees: Double = 0.0,
    /** 0...1 */
    val opacity: Double = 1.0,
    val blendMode: BlendMode = BlendMode.normal,
    val isHidden: Boolean = false,
)

/** `{"type": "text", "text": {...}}` or `{"type": "sticker", "sticker": {...}}`. */
@Serializable(with = OverlayContentSerializer::class)
sealed interface OverlayContent {
    data class Text(val text: TextOverlay) : OverlayContent
    data class Sticker(val sticker: StickerOverlay) : OverlayContent
}

object OverlayContentSerializer : KSerializer<OverlayContent> {
    override val descriptor: SerialDescriptor = buildClassSerialDescriptor("aurum.OverlayContent")

    override fun serialize(encoder: Encoder, value: OverlayContent) {
        val json = encoder.asJson()
        val obj = when (value) {
            is OverlayContent.Text -> JsonObject(
                mapOf("type" to JsonPrimitive("text"), "text" to json.json.encodeToJsonElement(TextOverlay.serializer(), value.text)),
            )
            is OverlayContent.Sticker -> JsonObject(
                mapOf("type" to JsonPrimitive("sticker"), "sticker" to json.json.encodeToJsonElement(StickerOverlay.serializer(), value.sticker)),
            )
        }
        json.encodeJsonElement(obj)
    }

    override fun deserialize(decoder: Decoder): OverlayContent {
        val json = decoder.asJson()
        val obj = json.requireObject()
        return when (obj.string("type")) {
            "text" -> OverlayContent.Text(json.json.decodeFromJsonElement(TextOverlay.serializer(), obj["text"] ?: missing("text")))
            "sticker" -> OverlayContent.Sticker(json.json.decodeFromJsonElement(StickerOverlay.serializer(), obj["sticker"] ?: missing("sticker")))
            else -> throw SerializationException("Unknown overlay type ${obj["type"]}")
        }
    }
}

internal fun missing(key: String): Nothing = throw SerializationException("Missing key \"$key\"")
