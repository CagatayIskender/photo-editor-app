package com.aurum.core

import kotlinx.serialization.Serializable
import java.net.URI
import java.time.Instant
import java.util.Base64
import java.util.Locale
import java.util.UUID

/** A reusable stack of looks and adjustments, without photo, crop or overlays. */
@Serializable
data class Preset(
    val schemaVersion: Int = 1,
    @Serializable(with = UuidSerializer::class) val id: UUID = UUID.randomUUID(),
    val name: String,
    val operations: List<EditOperation>,
    @Serializable(with = InstantSerializer::class) val createdAt: Instant = Instant.now().wholeSeconds,
) {
    /** Applies the preset, replacing looks and adjustments, with fresh operation ids. */
    fun apply(document: EditDocument): EditDocument =
        document.copy(operations = operations.map { EditOperation(isEnabled = it.isEnabled, kind = it.kind) })

    companion object {
        /** Captures the enabled operations of a document. */
        fun from(name: String, document: EditDocument) = Preset(name = name, operations = document.operations.filter { it.isEnabled })
    }
}

/**
 * Shareable preset links: `aurum://preset/<base64url JSON>`, identical to the
 * iOS encoding (sorted keys, no padding), so a link made on one platform
 * opens on the other.
 */
class PresetLinkCodec(val scheme: String = "aurum") {
    sealed class LinkError(message: String) : Exception(message) {
        object WrongScheme : LinkError("wrong scheme")
        object NotAPresetLink : LinkError("not a preset link")
        object InvalidPayload : LinkError("invalid payload")
        object TooLarge : LinkError("too large")
    }

    fun link(preset: Preset): String {
        val json = AurumJson.encodeCanonical(Preset.serializer(), preset)
        val payload = base64UrlEncode(json.toByteArray(Charsets.UTF_8))
        if (payload.length > MAX_PAYLOAD_BYTES) throw LinkError.TooLarge
        return "$scheme://preset/$payload"
    }

    fun preset(link: String): Preset {
        val uri = try {
            URI(link)
        } catch (e: Exception) {
            throw LinkError.InvalidPayload
        }
        if (uri.scheme?.lowercase(Locale.ROOT) != scheme.lowercase(Locale.ROOT)) throw LinkError.WrongScheme
        if (uri.host != "preset") throw LinkError.NotAPresetLink
        val path = uri.path ?: ""
        val payload = if (path.startsWith("/")) path.substring(1) else path
        if (payload.length > MAX_PAYLOAD_BYTES) throw LinkError.InvalidPayload
        val data = base64UrlDecode(payload) ?: throw LinkError.InvalidPayload
        return try {
            AurumJson.format.decodeFromString(Preset.serializer(), String(data, Charsets.UTF_8))
        } catch (e: Exception) {
            throw LinkError.InvalidPayload
        }
    }

    companion object {
        /** Messaging apps truncate long URLs. */
        const val MAX_PAYLOAD_BYTES = 8_000

        fun base64UrlEncode(data: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(data)

        fun base64UrlDecode(text: String): ByteArray? = try {
            if (text.isEmpty() || !text.all { it.isLetterOrDigit() || it == '-' || it == '_' }) null
            else Base64.getUrlDecoder().decode(text)
        } catch (e: IllegalArgumentException) {
            null
        }
    }
}
