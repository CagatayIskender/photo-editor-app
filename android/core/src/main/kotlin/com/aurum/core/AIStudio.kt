package com.aurum.core

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive
import java.time.Instant
import java.time.ZoneId
import java.util.UUID

// The client-side contract for the server AI features. The Android app shows
// these tools as "coming to Android"; the rules are ported so credits and
// requests behave identically once the screens arrive.

@Serializable
enum class AIFeature {
    portrait, avatar, relight, removeObject, replaceBackground, enhance, aiTransition;

    val creditCost: Int
        get() = when (this) {
            enhance -> 1
            removeObject, relight -> 2
            replaceBackground -> 3
            portrait, avatar -> 4
            aiTransition -> 5
        }

    val requiresMask: Boolean get() = this == removeObject
    val requiresStyle: Boolean get() = this == portrait || this == avatar
    val acceptsPrompt: Boolean get() = this in setOf(portrait, avatar, relight, replaceBackground)
    val requiresPrompt: Boolean get() = this == replaceBackground
    val inputCount: Int get() = if (this == aiTransition) 2 else 1

    val maxInputPixels: Int
        get() = when (this) {
            enhance -> 4_000_000
            aiTransition -> 1920 * 1080
            portrait, avatar -> 8_000_000
            relight, removeObject, replaceBackground -> 12_000_000
        }

    val displayNameKey: String get() = "ai.feature.$name"
}

@Serializable
data class AIStyle(val id: String, val name: String, val feature: AIFeature, val tier: Tier) {
    companion object {
        val library = listOf(
            AIStyle("portrait.studio", "Studio", AIFeature.portrait, Tier.free),
            AIStyle("portrait.editorial", "Editorial", AIFeature.portrait, Tier.member),
            AIStyle("portrait.oil", "Oil Portrait", AIFeature.portrait, Tier.member),
            AIStyle("portrait.noir", "Silver Screen", AIFeature.portrait, Tier.member),
            AIStyle("avatar.clean", "Clean", AIFeature.avatar, Tier.free),
            AIStyle("avatar.gilded", "Gilded", AIFeature.avatar, Tier.member),
            AIStyle("avatar.illustrated", "Illustrated", AIFeature.avatar, Tier.member),
            AIStyle("avatar.clay", "Soft Clay", AIFeature.avatar, Tier.member),
        )

        fun styles(feature: AIFeature, styles: List<AIStyle> = library) = styles.filter { it.feature == feature }
    }
}

@Serializable
data class AIMask(val polygons: List<List<NormalizedPoint>> = emptyList(), val strokes: List<Stroke> = emptyList()) {
    @Serializable
    data class Stroke(val points: List<NormalizedPoint>, val radius: Double = 0.03, val isEraser: Boolean = false) {
        companion object {
            fun of(points: List<NormalizedPoint>, radius: Double = 0.03, isEraser: Boolean = false) =
                Stroke(points, (0.001..0.5).clamp(radius), isEraser)
        }
    }

    val isEmpty: Boolean
        get() = polygons.none { it.size >= 3 } && strokes.none { !it.isEraser && it.points.isNotEmpty() }

    val isInBounds: Boolean
        get() {
            fun inside(p: NormalizedPoint) = p.x in 0.0..1.0 && p.y in 0.0..1.0
            return polygons.all { poly -> poly.all(::inside) } && strokes.all { s -> s.points.all(::inside) }
        }
}

sealed interface AIValidationError {
    data class PromptTooLong(val length: Int, val limit: Int) : AIValidationError
    object PromptRequired : AIValidationError
    object PromptNotSupported : AIValidationError
    object MaskRequired : AIValidationError
    object MaskOutOfBounds : AIValidationError
    object StyleRequired : AIValidationError
    data class UnknownStyle(val id: String) : AIValidationError
    data class StyleForOtherFeature(val id: String) : AIValidationError
    data class WrongInputCount(val expected: Int, val actual: Int) : AIValidationError
    data class InputTooLarge(val pixels: Int, val limit: Int) : AIValidationError
    object EmptyInput : AIValidationError
}

/** One AI job; [id] doubles as the idempotency key for the server and the ledger. */
@Serializable
data class AIJobRequest(
    @Serializable(with = UuidSerializer::class) val id: UUID = UUID.randomUUID(),
    val feature: AIFeature,
    val styleID: String? = null,
    val prompt: String? = null,
    val mask: AIMask? = null,
    val inputs: List<SourceAsset>,
    @Serializable(with = InstantSerializer::class) val createdAt: Instant = Instant.now().wholeSeconds,
) {
    val trimmedPrompt: String? get() = prompt?.trim()?.takeIf { it.isNotEmpty() }

    /** Everything wrong with the request, in a stable order. Empty means valid. */
    fun validate(styles: List<AIStyle> = AIStyle.library): List<AIValidationError> {
        val errors = mutableListOf<AIValidationError>()
        val p = trimmedPrompt
        if (p != null) {
            val length = p.codePointCount(0, p.length)
            if (!feature.acceptsPrompt) errors.add(AIValidationError.PromptNotSupported)
            else if (length > MAX_PROMPT_LENGTH) errors.add(AIValidationError.PromptTooLong(length, MAX_PROMPT_LENGTH))
        } else if (feature.requiresPrompt) {
            errors.add(AIValidationError.PromptRequired)
        }
        if (feature.requiresMask) {
            val m = mask
            if (m != null && !m.isEmpty) {
                if (!m.isInBounds) errors.add(AIValidationError.MaskOutOfBounds)
            } else {
                errors.add(AIValidationError.MaskRequired)
            }
        }
        val sid = styleID
        if (sid != null) {
            val style = styles.firstOrNull { it.id == sid }
            if (style == null) errors.add(AIValidationError.UnknownStyle(sid))
            else if (style.feature != feature) errors.add(AIValidationError.StyleForOtherFeature(sid))
        } else if (feature.requiresStyle) {
            errors.add(AIValidationError.StyleRequired)
        }
        if (inputs.size != feature.inputCount) errors.add(AIValidationError.WrongInputCount(feature.inputCount, inputs.size))
        for (input in inputs) {
            val pixels = input.pixelSize.width * input.pixelSize.height
            if (input.pixelSize.width <= 0 || input.pixelSize.height <= 0) errors.add(AIValidationError.EmptyInput)
            else if (pixels > feature.maxInputPixels) errors.add(AIValidationError.InputTooLarge(pixels, feature.maxInputPixels))
        }
        return errors
    }

    val isValid: Boolean get() = validate().isEmpty()

    companion object {
        const val MAX_PROMPT_LENGTH = 300
    }
}

/** Where a job is: `{"type": "running", "progress": 0.4}`. */
@Serializable(with = AIJobStatusSerializer::class)
sealed interface AIJobStatus {
    object Queued : AIJobStatus { override fun toString() = "Queued" }
    data class Running(val progress: Double) : AIJobStatus
    data class Succeeded(val resultRefs: List<String>) : AIJobStatus
    data class Failed(val reason: String) : AIJobStatus
    data class RejectedByModeration(val reason: String) : AIJobStatus

    val isTerminal: Boolean get() = this !is Queued && this !is Running
    val refundsCredits: Boolean get() = this is Failed || this is RejectedByModeration
}

object AIJobStatusSerializer : KSerializer<AIJobStatus> {
    override val descriptor: SerialDescriptor = buildClassSerialDescriptor("aurum.AIJobStatus")

    override fun serialize(encoder: Encoder, value: AIJobStatus) {
        val m = linkedMapOf<String, JsonElement>()
        when (value) {
            AIJobStatus.Queued -> m["type"] = JsonPrimitive("queued")
            is AIJobStatus.Running -> { m["type"] = JsonPrimitive("running"); m["progress"] = JsonPrimitive(value.progress) }
            is AIJobStatus.Succeeded -> { m["type"] = JsonPrimitive("succeeded"); m["resultRefs"] = JsonArray(value.resultRefs.map { JsonPrimitive(it) }) }
            is AIJobStatus.Failed -> { m["type"] = JsonPrimitive("failed"); m["reason"] = JsonPrimitive(value.reason) }
            is AIJobStatus.RejectedByModeration -> { m["type"] = JsonPrimitive("rejectedByModeration"); m["reason"] = JsonPrimitive(value.reason) }
        }
        encoder.asJson().encodeJsonElement(JsonObject(m))
    }

    override fun deserialize(decoder: Decoder): AIJobStatus {
        val dec = decoder.asJson()
        val obj = dec.requireObject()
        return when (obj.string("type")) {
            "queued" -> AIJobStatus.Queued
            "running" -> AIJobStatus.Running(obj.double("progress") ?: 0.0)
            "succeeded" -> AIJobStatus.Succeeded(obj["resultRefs"]?.let { dec.json.decodeFromJsonElement(ListSerializer(String.serializer()), it) } ?: emptyList())
            "failed" -> AIJobStatus.Failed(obj.string("reason") ?: "")
            "rejectedByModeration" -> AIJobStatus.RejectedByModeration(obj.string("reason") ?: "")
            else -> throw SerializationException("Unknown job status ${obj["type"]}")
        }
    }
}

/**
 * The user's AI credits: idempotent grants, purchases, charges and refunds.
 * The JSON matches Swift's synthesised coding, including the `charges`
 * dictionary, which Swift writes as a flat `[uuid, cost, uuid, cost]` array.
 */
@Serializable(with = CreditLedgerSerializer::class)
class CreditLedger(balance: Int = 0) {
    @Serializable
    data class Entry(
        val kind: Kind,
        /** Signed: positive adds credits. */
        val amount: Int,
        @Serializable(with = UuidSerializer::class) val jobID: UUID? = null,
        val reference: String? = null,
        @Serializable(with = InstantSerializer::class) val date: Instant,
    ) {
        @Serializable
        enum class Kind { grant, purchase, spend, refund }

        companion object {
            fun of(kind: Kind, amount: Int, jobID: UUID? = null, reference: String? = null, date: Instant) =
                Entry(kind, amount, jobID, reference, date.wholeSeconds)
        }
    }

    sealed interface SpendResult {
        object Spent : SpendResult { override fun toString() = "Spent" }
        object AlreadySpent : SpendResult { override fun toString() = "AlreadySpent" }
        data class InsufficientCredits(val balance: Int, val cost: Int) : SpendResult
    }

    var balance: Int = maxOf(0, balance)
        private set
    private val _history = mutableListOf<Entry>()
    val history: List<Entry> get() = _history
    internal val charges = LinkedHashMap<UUID, Int>()
    internal val refunded = LinkedHashSet<UUID>()
    internal val grantedPeriods = LinkedHashSet<String>()
    internal val purchases = LinkedHashSet<String>()

    fun canAfford(cost: Int) = balance >= maxOf(0, cost)
    fun canAfford(feature: AIFeature) = canAfford(feature.creditCost)
    fun hasCharged(jobID: UUID) = charges.containsKey(jobID)

    fun grantMonthly(period: String, amount: Int = MONTHLY_MEMBER_GRANT, date: Instant): Boolean {
        if (amount <= 0 || !grantedPeriods.add(period)) return false
        balance += amount
        append(Entry.of(Entry.Kind.grant, amount, reference = period, date = date))
        return true
    }

    fun purchase(credits: Int, transactionID: String, date: Instant): Boolean {
        if (credits <= 0 || !purchases.add(transactionID)) return false
        balance += credits
        append(Entry.of(Entry.Kind.purchase, credits, reference = transactionID, date = date))
        return true
    }

    fun spend(cost: Int, jobID: UUID, date: Instant): SpendResult {
        if (charges.containsKey(jobID)) return SpendResult.AlreadySpent
        val c = maxOf(0, cost)
        if (balance < c) return SpendResult.InsufficientCredits(balance, c)
        balance -= c
        charges[jobID] = c
        append(Entry.of(Entry.Kind.spend, -c, jobID = jobID, date = date))
        return SpendResult.Spent
    }

    fun spend(request: AIJobRequest, date: Instant) = spend(request.feature.creditCost, request.id, date)

    fun refund(jobID: UUID, date: Instant): Boolean {
        val cost = charges[jobID] ?: return false
        if (jobID in refunded) return false
        refunded.add(jobID)
        balance += cost
        append(Entry.of(Entry.Kind.refund, cost, jobID = jobID, date = date))
        return true
    }

    fun settle(jobID: UUID, status: AIJobStatus, date: Instant) = if (status.refundsCredits) refund(jobID, date) else false

    private fun append(entry: Entry) {
        _history.add(entry)
        while (_history.size > HISTORY_LIMIT) _history.removeAt(0)
    }

    internal fun restore(balance: Int, history: List<Entry>) {
        this.balance = balance
        _history.clear()
        _history.addAll(history)
    }

    override fun equals(other: Any?): Boolean = other is CreditLedger && balance == other.balance && history == other.history &&
        charges == other.charges && refunded == other.refunded && grantedPeriods == other.grantedPeriods && purchases == other.purchases

    override fun hashCode(): Int = balance * 31 + history.hashCode()

    companion object {
        const val MONTHLY_MEMBER_GRANT = 100
        const val HISTORY_LIMIT = 200

        /** "2026-11" in the zone's calendar. */
        fun period(date: Instant, zone: ZoneId): String {
            val d = date.atZone(zone)
            val m = d.monthValue
            return if (m < 10) "${d.year}-0$m" else "${d.year}-$m"
        }
    }
}

object CreditLedgerSerializer : KSerializer<CreditLedger> {
    override val descriptor: SerialDescriptor = buildClassSerialDescriptor("aurum.CreditLedger")

    override fun serialize(encoder: Encoder, value: CreditLedger) {
        val j = encoder.asJson().json
        val charges = JsonArray(value.charges.flatMap { (k, v) -> listOf(JsonPrimitive(k.toString().uppercase()), JsonPrimitive(v)) })
        val obj = JsonObject(
            linkedMapOf(
                "balance" to JsonPrimitive(value.balance),
                "history" to j.encodeToJsonElement(ListSerializer(CreditLedger.Entry.serializer()), value.history),
                "charges" to charges,
                "refunded" to JsonArray(value.refunded.map { JsonPrimitive(it.toString().uppercase()) }),
                "grantedPeriods" to JsonArray(value.grantedPeriods.map { JsonPrimitive(it) }),
                "purchases" to JsonArray(value.purchases.map { JsonPrimitive(it) }),
            ),
        )
        encoder.asJson().encodeJsonElement(obj)
    }

    override fun deserialize(decoder: Decoder): CreditLedger {
        val dec = decoder.asJson()
        val obj = dec.requireObject()
        val ledger = CreditLedger()
        val history = obj["history"]?.let { dec.json.decodeFromJsonElement(ListSerializer(CreditLedger.Entry.serializer()), it) } ?: emptyList()
        ledger.restore(obj["balance"]?.jsonPrimitive?.int ?: 0, history)
        val charges = obj["charges"]
        when (charges) {
            is JsonArray -> charges.chunked(2).forEach { pair ->
                if (pair.size == 2) ledger.charges[UUID.fromString(pair[0].jsonPrimitive.content)] = pair[1].jsonPrimitive.int
            }
            // Tolerate an object form keyed by UUID string.
            is JsonObject -> charges.forEach { (k, v) -> ledger.charges[UUID.fromString(k)] = v.jsonPrimitive.int }
            else -> {}
        }
        (obj["refunded"] as? JsonArray)?.forEach { ledger.refunded.add(UUID.fromString(it.jsonPrimitive.content)) }
        (obj["grantedPeriods"] as? JsonArray)?.forEach { ledger.grantedPeriods.add(it.jsonPrimitive.content) }
        (obj["purchases"] as? JsonArray)?.forEach { ledger.purchases.add(it.jsonPrimitive.content) }
        return ledger
    }
}
