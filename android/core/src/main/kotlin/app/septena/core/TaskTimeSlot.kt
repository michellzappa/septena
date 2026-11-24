package app.septena.core

/**
 * Start time and duration formatting & presets for `task.times`, matching
 * Apple `SeptenaCore/Models.swift` (`TaskTimeSlot`).
 */
object TaskTimeSlot {
    data class DurationPreset(val minutes: Int, val label: String)

    /** Quick duration presets shown inside the When board's time controls. */
    val quickDurations: List<DurationPreset> = listOf(
        DurationPreset(15, "15m"),
        DurationPreset(30, "30m"),
        DurationPreset(60, "1h"),
        DurationPreset(120, "2h"),
    )

    const val DEFAULT_START_TIME = "09:00"

    /** Parse `"HH:MM"` into `(hour, minute)`. */
    fun parse(hhmm: String?): Pair<Int, Int>? {
        if (hhmm == null || hhmm.length != 5 || hhmm[2] != ':') return null
        val h = hhmm.substring(0, 2).toIntOrNull() ?: return null
        val m = hhmm.substring(3, 5).toIntOrNull() ?: return null
        if (h !in 0..23 || m !in 0..59) return null
        return h to m
    }

    /** Format `(hour, minute)` into canonical 24-hour `"HH:MM"`. */
    fun hhmm(hour: Int, minute: Int): String {
        val h = hour.coerceIn(0, 23)
        val m = minute.coerceIn(0, 59)
        return "%02d:%02d".format(h, m)
    }

    /** Format quiet display range (`"14:00–15:00"` when duration >= 5m, else `"14:00"`). */
    fun format(startTime: String?, durationMinutes: Int?): String? {
        val (h, m) = parse(startTime) ?: return null
        val start = hhmm(h, m)
        val dur = durationMinutes ?: return start
        if (dur < 5) return start
        val total = (h * 60 + m + dur) % (24 * 60)
        val end = hhmm(total / 60, total % 60)
        return "$start–$end"
    }
}
