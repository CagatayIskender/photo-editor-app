package com.aurum.core

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerializationException
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.math.BigDecimal
import java.time.Instant
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale
import java.util.UUID

/**
 * JSON settings shared with the iOS app.
 *
 * Swift's synthesised `Codable` writes every non-optional property and leaves
 * out `nil` optionals, ignores unknown keys, writes UUIDs in upper case and
 * dates as ISO 8601 without fractional seconds. These settings and the
 * serialisers below reproduce that, so a document, preset link or drop
 * schedule moves between the platforms unchanged.
 */
object AurumJson {
    val format: Json = Json {
        encodeDefaults = true
        explicitNulls = false
        ignoreUnknownKeys = true
        isLenient = false
    }

    inline fun <reified T> encode(value: T): String = format.encodeToString(kotlinx.serialization.serializer<T>(), value)

    inline fun <reified T> decode(text: String): T = format.decodeFromString(kotlinx.serialization.serializer<T>(), text)

    /**
     * The same bytes Swift's `JSONEncoder` with `.sortedKeys` writes: keys in
     * order, integral numbers without ".0", plain (non-exponent) decimals and
     * escaped forward slashes.
     */
    fun <T> encodeCanonical(serializer: KSerializer<T>, value: T): String {
        val element = format.encodeToJsonElement(serializer, value)
        val sb = StringBuilder()
        writeCanonical(element, sb)
        return sb.toString()
    }

    inline fun <reified T> encodeCanonical(value: T): String = encodeCanonical(kotlinx.serialization.serializer<T>(), value)

    private fun writeCanonical(element: JsonElement, out: StringBuilder) {
        when (element) {
            is JsonObject -> {
                out.append('{')
                element.keys.sorted().forEachIndexed { i, key ->
                    if (i > 0) out.append(',')
                    writeString(key, out)
                    out.append(':')
                    writeCanonical(element.getValue(key), out)
                }
                out.append('}')
            }
            is JsonArray -> {
                out.append('[')
                element.forEachIndexed { i, item ->
                    if (i > 0) out.append(',')
                    writeCanonical(item, out)
                }
                out.append(']')
            }
            JsonNull -> out.append("null")
            is JsonPrimitive -> when {
                element.isString -> writeString(element.content, out)
                element.content == "true" || element.content == "false" -> out.append(element.content)
                else -> out.append(canonicalNumber(element.content))
            }
        }
    }

    internal fun canonicalNumber(text: String): String {
        if (!text.contains('.') && !text.contains('e') && !text.contains('E')) return text
        return try {
            val plain = BigDecimal(text).stripTrailingZeros().toPlainString()
            if (plain == "-0") "-0" else plain
        } catch (e: NumberFormatException) {
            text
        }
    }

    private fun writeString(s: String, out: StringBuilder) {
        out.append('"')
        for (ch in s) {
            when (ch) {
                '"' -> out.append("\\\"")
                '\\' -> out.append("\\\\")
                '/' -> out.append("\\/")
                '\n' -> out.append("\\n")
                '\r' -> out.append("\\r")
                '\t' -> out.append("\\t")
                '\b' -> out.append("\\b")
                '\u000C' -> out.append("\\f")
                else -> if (ch < ' ') out.append(String.format(Locale.ROOT, "\\u%04x", ch.code)) else out.append(ch)
            }
        }
        out.append('"')
    }
}

/** UUIDs as Swift writes them: upper case. Reading accepts either case. */
object UuidSerializer : KSerializer<UUID> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("aurum.UUID", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: UUID) = encoder.encodeString(value.toString().uppercase(Locale.ROOT))
    override fun deserialize(decoder: Decoder): UUID = try {
        UUID.fromString(decoder.decodeString())
    } catch (e: IllegalArgumentException) {
        throw SerializationException("Invalid UUID", e)
    }
}

/**
 * Dates as Swift's `.iso8601` strategy writes them: "2026-11-02T09:00:00Z",
 * whole seconds. Reading accepts any offset.
 */
object InstantSerializer : KSerializer<Instant> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("aurum.Instant", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: Instant) =
        encoder.encodeString(DateTimeFormatter.ISO_INSTANT.format(value.truncatedTo(ChronoUnit.SECONDS)))

    override fun deserialize(decoder: Decoder): Instant = try {
        OffsetDateTime.parse(decoder.decodeString(), DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant()
    } catch (e: Exception) {
        throw SerializationException("Invalid ISO 8601 date", e)
    }
}

/** Drops sub-second precision, matching Swift's `wholeSeconds`. */
val Instant.wholeSeconds: Instant get() = Instant.ofEpochSecond(epochSecond)

/** `(lo..hi).clamp(v)` with Swift's NaN rule: NaN becomes the lower bound. */
fun ClosedFloatingPointRange<Double>.clamp(value: Double): Double {
    if (value.isNaN()) return start
    return value.coerceIn(start, endInclusive)
}

internal fun JsonDecoder.requireObject(): JsonObject =
    decodeJsonElement() as? JsonObject ?: throw SerializationException("Expected a JSON object")

internal fun Decoder.asJson(): JsonDecoder =
    this as? JsonDecoder ?: throw SerializationException("This type can only be read from JSON")

internal fun Encoder.asJson(): JsonEncoder =
    this as? JsonEncoder ?: throw SerializationException("This type can only be written as JSON")

internal fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

internal fun JsonObject.double(key: String): Double? = (this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toDoubleOrNull()
