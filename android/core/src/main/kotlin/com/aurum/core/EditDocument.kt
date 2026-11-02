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
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import java.time.Instant
import java.util.UUID
import kotlin.math.max
import kotlin.math.min

/**
 * The photo an edit applies to. On iOS `localIdentifier` is a Photos asset id;
 * on Android it is the content URI the photo picker returned.
 */
@Serializable
data class SourceAsset(val localIdentifier: String, val pixelSize: PixelSize)

/** An applied look: which recipe, how strongly, and any Refine changes. */
@Serializable
data class LookApplication(
    val lookID: String,
    /** 0...1 blend between the input and the full recipe. */
    val intensity: Double = 0.8,
    val refine: RefineOverrides = RefineOverrides(),
) {
    companion object {
        fun of(lookID: String, intensity: Double = 0.8, refine: RefineOverrides = RefineOverrides()) =
            LookApplication(lookID, (0.0..1.0).clamp(intensity), refine)
    }
}

/** One step in the edit stack. */
@Serializable
data class EditOperation(
    @Serializable(with = UuidSerializer::class) val id: UUID = UUID.randomUUID(),
    val isEnabled: Boolean = true,
    val kind: OperationKind,
)

/** `{"type": "look", "look": {...}}`, `adjust` or `retouch`, as on iOS. */
@Serializable(with = OperationKindSerializer::class)
sealed interface OperationKind {
    data class Look(val look: LookApplication) : OperationKind
    data class Adjust(val adjust: AdjustmentSet) : OperationKind
    /** Face-aware retouching; always first in the stack. */
    data class Retouch(val retouch: RetouchSettings) : OperationKind
}

object OperationKindSerializer : KSerializer<OperationKind> {
    override val descriptor: SerialDescriptor = buildClassSerialDescriptor("aurum.OperationKind")

    override fun serialize(encoder: Encoder, value: OperationKind) {
        val enc = encoder.asJson()
        val j = enc.json
        val obj = when (value) {
            is OperationKind.Look -> JsonObject(mapOf("type" to JsonPrimitive("look"), "look" to j.encodeToJsonElement(LookApplication.serializer(), value.look)))
            is OperationKind.Adjust -> JsonObject(mapOf("type" to JsonPrimitive("adjust"), "adjust" to j.encodeToJsonElement(AdjustmentSet.serializer(), value.adjust)))
            is OperationKind.Retouch -> JsonObject(mapOf("type" to JsonPrimitive("retouch"), "retouch" to j.encodeToJsonElement(RetouchSettings.serializer(), value.retouch)))
        }
        enc.encodeJsonElement(obj)
    }

    override fun deserialize(decoder: Decoder): OperationKind {
        val dec = decoder.asJson()
        val j = dec.json
        val obj = dec.requireObject()
        return when (obj.string("type")) {
            "look" -> OperationKind.Look(j.decodeFromJsonElement(LookApplication.serializer(), obj["look"] ?: missing("look")))
            "adjust" -> OperationKind.Adjust(j.decodeFromJsonElement(AdjustmentSet.serializer(), obj["adjust"] ?: missing("adjust")))
            "retouch" -> OperationKind.Retouch(j.decodeFromJsonElement(RetouchSettings.serializer(), obj["retouch"] ?: missing("retouch")))
            else -> throw SerializationException("Unknown operation type ${obj["type"]}")
        }
    }
}

/** Aspect ratio presets offered in the Crop sheet. */
@Serializable
enum class AspectPreset(val label: String) {
    free("Free"), original("Original"), story("9:16"), portrait("4:5"), square("1:1"), landscape("16:9");

    /** Width over height, or null for free and original. */
    val ratio: Double?
        get() = when (this) {
            free, original -> null
            story -> 9.0 / 16.0
            portrait -> 4.0 / 5.0
            square -> 1.0
            landscape -> 16.0 / 9.0
        }
}

/** Crop, rotation and flips, applied after every look and adjustment. */
@Serializable
data class CropSpec(
    val rect: NormalizedRect = NormalizedRect.full,
    val aspect: AspectPreset = AspectPreset.original,
    /** 90° clockwise turns, 0...3. */
    val quarterTurns: Int = 0,
    /** Fine rotation, -45...45 degrees. */
    val straightenDegrees: Double = 0.0,
    val flipHorizontal: Boolean = false,
    val flipVertical: Boolean = false,
) {
    val isIdentity: Boolean get() = this == identity

    /** Output size in pixels for a given source size. */
    fun outputSize(source: PixelSize): PixelSize {
        val w = swiftRoundToInt(source.width * rect.width)
        val h = swiftRoundToInt(source.height * rect.height)
        return if (quarterTurns % 2 == 0) PixelSize(w, h) else PixelSize(h, w)
    }

    companion object {
        val identity = CropSpec()

        /** Normalises turns into 0...3 and clamps straightening, like the Swift initialiser. */
        fun of(
            rect: NormalizedRect = NormalizedRect.full,
            aspect: AspectPreset = AspectPreset.original,
            quarterTurns: Int = 0,
            straightenDegrees: Double = 0.0,
            flipHorizontal: Boolean = false,
            flipVertical: Boolean = false,
        ) = CropSpec(rect, aspect, ((quarterTurns % 4) + 4) % 4, (-45.0..45.0).clamp(straightenDegrees), flipHorizontal, flipVertical)

        /** The largest centred crop of the aspect that fits the source. */
        fun centred(aspect: AspectPreset, source: PixelSize): CropSpec {
            val target = aspect.ratio ?: return CropSpec(aspect = aspect)
            val sourceRatio = source.aspectRatio
            var rect = NormalizedRect.full
            if (target < sourceRatio) {
                val w = target / sourceRatio
                rect = rect.copy(width = w, x = (1 - w) / 2)
            } else {
                val h = sourceRatio / target
                rect = rect.copy(height = h, y = (1 - h) / 2)
            }
            return CropSpec(rect = rect, aspect = aspect)
        }
    }
}

/**
 * A complete, serialisable edit: the single source of truth for the Studio,
 * drafts, presets and export. Immutable; every change returns a new value,
 * which makes undo snapshots free.
 */
@Serializable
data class EditDocument(
    val schemaVersion: Int = CURRENT_SCHEMA_VERSION,
    @Serializable(with = UuidSerializer::class) val id: UUID = UUID.randomUUID(),
    val source: SourceAsset,
    /** Applied in order, first to last. */
    val operations: List<EditOperation> = emptyList(),
    val crop: CropSpec = CropSpec.identity,
    /** Drawn above the photo, first to last. */
    val overlays: List<Overlay> = emptyList(),
    @Serializable(with = InstantSerializer::class) val createdAt: Instant = Instant.now().wholeSeconds,
    @Serializable(with = InstantSerializer::class) val modifiedAt: Instant = createdAt,
) {
    // MARK: Looks

    val lookApplications: List<LookApplication>
        get() = operations.mapNotNull { (it.kind as? OperationKind.Look)?.look }

    /** The look the Looks sheet edits: the topmost look operation. */
    val activeLookIndex: Int?
        get() = operations.indexOfLast { it.kind is OperationKind.Look }.takeIf { it >= 0 }

    private val adjustIndex: Int?
        get() = operations.indexOfFirst { it.kind is OperationKind.Adjust }.takeIf { it >= 0 }

    private val retouchIndex: Int?
        get() = operations.indexOfFirst { it.kind is OperationKind.Retouch }.takeIf { it >= 0 }

    /** Replaces the topmost look, or adds one below the adjustments. */
    fun applyLook(lookID: String, intensity: Double = 0.8): EditDocument {
        val application = LookApplication.of(lookID, intensity)
        val ops = operations.toMutableList()
        val i = activeLookIndex
        if (i != null) {
            ops[i] = ops[i].copy(kind = OperationKind.Look(application), isEnabled = true)
        } else {
            ops.add(adjustIndex ?: ops.size, EditOperation(kind = OperationKind.Look(application)))
        }
        return copy(operations = ops)
    }

    /** Adds another look on top of the existing ones (below the adjustments). */
    fun stackLook(lookID: String, intensity: Double = 0.8): EditDocument {
        val ops = operations.toMutableList()
        ops.add(adjustIndex ?: ops.size, EditOperation(kind = OperationKind.Look(LookApplication.of(lookID, intensity))))
        return copy(operations = ops)
    }

    fun setActiveLookIntensity(value: Double): EditDocument = updateActiveLook { it.copy(intensity = (0.0..1.0).clamp(value)) }

    fun setActiveLookRefine(refine: RefineOverrides): EditDocument = updateActiveLook { it.copy(refine = refine) }

    private fun updateActiveLook(change: (LookApplication) -> LookApplication): EditDocument {
        val i = activeLookIndex ?: return this
        val look = (operations[i].kind as OperationKind.Look).look
        return copy(operations = operations.toMutableList().also { it[i] = it[i].copy(kind = OperationKind.Look(change(look))) })
    }

    fun removeOperation(id: UUID): EditDocument = copy(operations = operations.filter { it.id != id })

    fun toggleOperation(id: UUID): EditDocument =
        copy(operations = operations.map { if (it.id == id) it.copy(isEnabled = !it.isEnabled) else it })

    fun moveOperation(from: Int, to: Int): EditDocument {
        if (from !in operations.indices) return this
        val ops = operations.toMutableList()
        val op = ops.removeAt(from)
        ops.add(min(max(to, 0), ops.size), op)
        return copy(operations = ops)
    }

    // MARK: Adjustments

    /** The single adjustments operation; neutral if none exists yet. */
    val adjustments: AdjustmentSet
        get() = adjustIndex?.let { (operations[it].kind as OperationKind.Adjust).adjust } ?: AdjustmentSet()

    fun withAdjustments(value: AdjustmentSet): EditDocument {
        val i = adjustIndex
        return when {
            i != null -> copy(operations = operations.toMutableList().also { it[i] = it[i].copy(kind = OperationKind.Adjust(value)) })
            !value.isNeutral -> copy(operations = operations + EditOperation(kind = OperationKind.Adjust(value)))
            else -> this
        }
    }

    // MARK: Retouch

    val retouch: RetouchSettings
        get() = retouchIndex?.let { (operations[it].kind as OperationKind.Retouch).retouch } ?: RetouchSettings()

    fun withRetouch(value: RetouchSettings): EditDocument {
        val i = retouchIndex
        return when {
            i != null -> copy(operations = operations.toMutableList().also { it[i] = it[i].copy(kind = OperationKind.Retouch(value)) })
            !value.isNeutral -> copy(operations = listOf(EditOperation(kind = OperationKind.Retouch(value))) + operations)
            else -> this
        }
    }

    // MARK: Overlays

    fun addOverlay(overlay: Overlay): EditDocument = copy(overlays = overlays + overlay)

    fun updateOverlay(overlay: Overlay): EditDocument =
        copy(overlays = overlays.map { if (it.id == overlay.id) overlay else it })

    fun removeOverlay(id: UUID): EditDocument = copy(overlays = overlays.filter { it.id != id })

    /** True when nothing has been changed from the original photo. */
    val isPristine: Boolean
        get() = operations.all { op ->
            if (!op.isEnabled) true else when (val k = op.kind) {
                is OperationKind.Look -> k.look.intensity == 0.0
                is OperationKind.Adjust -> k.adjust.isNeutral
                is OperationKind.Retouch -> k.retouch.isNeutral
            }
        } && crop.isIdentity && overlays.isEmpty()

    // MARK: Serialisation

    /** Sorted-key JSON, byte-compatible with iOS. */
    fun encoded(): String = AurumJson.encodeCanonical(serializer(), this)

    companion object {
        const val CURRENT_SCHEMA_VERSION = 1

        /** Decodes any supported schema version, migrating it to the current one. */
        fun decode(json: String): EditDocument = DocumentMigrator.decode(json)
    }
}

/** Upgrades saved documents from older schema versions (none yet). */
object DocumentMigrator {
    sealed class MigrationError(message: String) : Exception(message) {
        object NotAnObject : MigrationError("Not a JSON object")
        data class NewerThanSupported(val version: Int) : MigrationError("Schema $version is newer than supported")
    }

    /** steps[n] migrates version n + 1 to n + 2. */
    private val steps: List<(JsonObject) -> JsonObject> = emptyList()

    fun decode(json: String): EditDocument {
        var obj = try {
            AurumJson.format.parseToJsonElement(json) as? JsonObject
        } catch (e: Exception) {
            null
        } ?: throw MigrationError.NotAnObject
        var version = obj["schemaVersion"]?.jsonPrimitive?.intOrNull ?: 1
        if (version > EditDocument.CURRENT_SCHEMA_VERSION) throw MigrationError.NewerThanSupported(version)
        while (version < EditDocument.CURRENT_SCHEMA_VERSION) {
            obj = steps[version - 1](obj)
            version += 1
            obj = JsonObject(obj + ("schemaVersion" to JsonPrimitive(version)))
        }
        return AurumJson.format.decodeFromJsonElement(EditDocument.serializer(), obj)
    }
}
