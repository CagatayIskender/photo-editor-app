package com.aurum.core

import kotlinx.serialization.Serializable
import java.time.Instant
import java.time.ZoneId

/** A seasonal drop: a limited-time bundle of looks, templates and stickers. */
@Serializable
data class Drop(
    val id: String,
    val title: String,
    @Serializable(with = InstantSerializer::class) val startsAt: Instant,
    /** Exclusive. */
    @Serializable(with = InstantSerializer::class) val endsAt: Instant,
    val lookIDs: List<String> = emptyList(),
    val templateIDs: List<String> = emptyList(),
    val stickerIDs: List<String> = emptyList(),
    val tier: Tier = Tier.free,
) {
    fun isActive(at: Instant) = !startsAt.isAfter(at) && at.isBefore(endsAt)

    companion object {
        fun of(id: String, title: String, startsAt: Instant, endsAt: Instant, lookIDs: List<String> = emptyList(), templateIDs: List<String> = emptyList(), stickerIDs: List<String> = emptyList(), tier: Tier = Tier.free) =
            Drop(id, title, startsAt.wholeSeconds, endsAt.wholeSeconds, lookIDs, templateIDs, stickerIDs, tier)
    }
}

/** The drop calendar, Content/drops.json. */
@Serializable
data class DropSchedule(val drops: List<Drop>) {
    sealed class ValidationError(message: String) : Exception(message) {
        data class DuplicateID(val id: String) : ValidationError("Duplicate drop $id")
        data class EndsBeforeStart(val id: String) : ValidationError("Drop $id ends before it starts")
    }

    fun validate() {
        val seen = HashSet<String>()
        for (drop in drops) {
            if (!seen.add(drop.id)) throw ValidationError.DuplicateID(drop.id)
            if (!drop.endsAt.isAfter(drop.startsAt)) throw ValidationError.EndsBeforeStart(drop.id)
        }
    }

    /** Drops running at [date], most recently started first. */
    fun active(date: Instant): List<Drop> = drops.filter { it.isActive(date) }
        .sortedWith(compareByDescending<Drop> { it.startsAt }.thenBy { it.id })

    /** Drops not started by [date], soonest first. */
    fun upcoming(date: Instant): List<Drop> = drops.filter { it.startsAt.isAfter(date) }
        .sortedWith(compareBy<Drop> { it.startsAt }.thenBy { it.id })

    fun encoded(): String = AurumJson.encodeCanonical(serializer(), this)

    companion object {
        fun decode(json: String): DropSchedule {
            val s = AurumJson.format.decodeFromString(serializer(), json)
            s.validate()
            return s
        }
    }
}

/** A calendar day, independent of time zone once recorded. */
@Serializable
data class DayStamp(val year: Int, val month: Int, val day: Int) : Comparable<DayStamp> {
    /** Proleptic Gregorian Julian Day Number. */
    val dayNumber: Int
        get() {
            val a = (14 - month) / 12
            val y = year + 4800 - a
            val m = month + 12 * a - 3
            return day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045
        }

    override fun compareTo(other: DayStamp) = dayNumber.compareTo(other.dayNumber)

    companion object {
        fun of(date: Instant, zone: ZoneId): DayStamp {
            val d = date.atZone(zone)
            return DayStamp(d.year, d.monthValue, d.dayOfMonth)
        }
    }
}

/** Consecutive days with at least one creation. */
@Serializable
data class Streak(val lastDay: DayStamp? = null, val length: Int = 0, val best: Int = 0) {
    /** Several creations on one day count once; a missed day starts over; older dates are ignored. */
    fun record(date: Instant, zone: ZoneId): Streak {
        val today = DayStamp.of(date, zone)
        val last = lastDay ?: return Streak(today, 1, maxOf(best, 1))
        val gap = today.dayNumber - last.dayNumber
        if (gap <= 0) return this
        val newLength = if (gap == 1) length + 1 else 1
        return Streak(today, newLength, maxOf(best, newLength))
    }

    /** Alive if the last creation was today or yesterday, else 0. */
    fun current(date: Instant, zone: ZoneId): Int {
        val last = lastDay ?: return 0
        return if (DayStamp.of(date, zone).dayNumber - last.dayNumber <= 1) length else 0
    }

    /** Alive, but nothing made today yet. */
    fun isAtRisk(date: Instant, zone: ZoneId): Boolean {
        val last = lastDay ?: return false
        if (length <= 0) return false
        return DayStamp.of(date, zone).dayNumber - last.dayNumber == 1
    }
}
