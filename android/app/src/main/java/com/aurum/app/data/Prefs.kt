package com.aurum.app.data

import android.content.Context
import com.aurum.core.DayStamp
import com.aurum.core.Streak
import java.time.Instant
import java.time.ZoneId

/** Small per-device preferences, the Android counterpart of the iOS `Preferences`. */
class Prefs(context: Context) {
    private val sp = context.getSharedPreferences("aurum", Context.MODE_PRIVATE)

    var hasCompletedOnboarding: Boolean
        get() = sp.getBoolean(KEY_ONBOARDED, false)
        set(value) = sp.edit().putBoolean(KEY_ONBOARDED, value).apply()

    /** Collection ids picked in onboarding, in order. */
    var vibes: List<String>
        get() = sp.getString(KEY_VIBES, "")!!.split(',').filter { it.isNotEmpty() }
        set(value) = sp.edit().putString(KEY_VIBES, value.joinToString(",")).apply()

    var favouriteLookIDs: Set<String>
        get() = sp.getStringSet(KEY_FAVOURITES, emptySet())!!.toSet()
        set(value) = sp.edit().putStringSet(KEY_FAVOURITES, value).apply()

    var streak: Streak
        get() {
            val day = sp.getString(KEY_STREAK_DAY, null)?.split('-')?.mapNotNull { it.toIntOrNull() }
            val last = if (day != null && day.size == 3) DayStamp(day[0], day[1], day[2]) else null
            return Streak(last, sp.getInt(KEY_STREAK_LENGTH, 0), sp.getInt(KEY_STREAK_BEST, 0))
        }
        set(value) {
            sp.edit()
                .putString(KEY_STREAK_DAY, value.lastDay?.let { "${it.year}-${it.month}-${it.day}" })
                .putInt(KEY_STREAK_LENGTH, value.length)
                .putInt(KEY_STREAK_BEST, value.best)
                .apply()
        }

    fun recordCreation(now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()) {
        streak = streak.record(now, zone)
    }

    /** Only used by the debug membership store. */
    var debugMember: Boolean
        get() = sp.getBoolean(KEY_DEBUG_MEMBER, false)
        set(value) = sp.edit().putBoolean(KEY_DEBUG_MEMBER, value).apply()

    private companion object {
        const val KEY_ONBOARDED = "aurum.onboarded"
        const val KEY_VIBES = "aurum.vibes"
        const val KEY_FAVOURITES = "aurum.favouriteLooks"
        const val KEY_STREAK_DAY = "aurum.streak.day"
        const val KEY_STREAK_LENGTH = "aurum.streak.length"
        const val KEY_STREAK_BEST = "aurum.streak.best"
        const val KEY_DEBUG_MEMBER = "aurum.debug.member"
    }
}
