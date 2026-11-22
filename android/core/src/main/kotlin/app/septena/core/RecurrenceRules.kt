package app.septena.core

import app.septena.core.generated.RegistryEntityEnums
import java.time.LocalDate
import java.time.YearMonth

data class OrdinalWeekday(val ordinal: Int, val weekday: Int)

data class RecurrenceRule(
    val unit: String,
    val interval: Int = 1,
    val afterCompletion: Boolean = true,
    val weekdays: List<Int>? = null,
    val monthDay: Int? = null,
    val ordinalWeekday: OrdinalWeekday? = null,
)

/** Recurrence arithmetic shared with Swift and the backend conformance vectors. */
object RecurrenceRules {
    fun nextScheduledDate(
        completedOn: String,
        scheduled: String?,
        logicalScheduled: String? = null,
        rule: RecurrenceRule,
    ): String? {
        val completed = parseDay(completedOn) ?: return null
        val anchor = if (rule.afterCompletion) completed
        else parseDay(logicalScheduled ?: scheduled) ?: completed
        val step = maxOf(1, rule.interval)
        val fixed = !rule.afterCompletion
        val weekdays = if (fixed) normalizeWeekdays(rule.weekdays) else emptyList()
        val monthDay = if (fixed) rule.monthDay else null
        val ordinal = if (fixed) rule.ordinalWeekday else null
        val keepMonthEnd = fixed && monthDay == null && ordinal == null

        fun advance(date: LocalDate): LocalDate? = when (rule.unit) {
            RegistryEntityEnums.RecurrenceUnit.DAY -> date.plusDays(step.toLong())
            RegistryEntityEnums.RecurrenceUnit.WEEK -> {
                if (weekdays.isNotEmpty()) advanceWeeklyByWeekdays(date, step, weekdays)
                else date.plusDays(step.toLong() * 7L)
            }
            RegistryEntityEnums.RecurrenceUnit.MONTH -> {
                val target = YearMonth.from(date).plusMonths(step.toLong())
                when {
                    ordinal != null -> resolveOrdinalWeekday(target, ordinal)
                    monthDay != null -> resolveMonthDay(target, monthDay)
                    else -> {
                        val keepEnd = keepMonthEnd && date.dayOfMonth == YearMonth.from(date).lengthOfMonth()
                        val targetDay = if (keepEnd) target.lengthOfMonth()
                        else minOf(date.dayOfMonth, target.lengthOfMonth())
                        target.atDay(targetDay)
                    }
                }
            }
            RegistryEntityEnums.RecurrenceUnit.YEAR -> {
                val target = YearMonth.of(date.year + step, date.monthValue)
                when {
                    ordinal != null -> resolveOrdinalWeekday(target, ordinal)
                    monthDay != null -> resolveMonthDay(target, monthDay)
                    else -> target.atDay(minOf(date.dayOfMonth, target.lengthOfMonth()))
                }
            }
            else -> null
        }

        var next = runCatching { advance(anchor) }.getOrNull() ?: return null
        if (!rule.afterCompletion) {
            var guard = 0
            while (!next.isAfter(completed)) {
                if (++guard > 10_000) return null
                next = runCatching { advance(next) }.getOrNull() ?: return null
            }
        }
        return next.toString()
    }

    fun occurrenceId(sourceTaskId: String, scheduled: String): String {
        var hash = 14_695_981_039_346_656_037uL
        for (byte in "$sourceTaskId|$scheduled".encodeToByteArray()) {
            hash = (hash xor byte.toUByte().toULong()) * 1_099_511_628_211uL
        }
        return "recur-" + hash.toString(16).padStart(16, '0')
    }

    private fun normalizeWeekdays(values: List<Int>?): List<Int> =
        values.orEmpty().filter { it in 1..7 }.distinct().sortedBy(::isoOffset)

    private fun advanceWeeklyByWeekdays(date: LocalDate, step: Int, weekdays: List<Int>): LocalDate? {
        val currentOffset = isoOffset(date.dayOfWeek.value % 7 + 1)
        for (weekday in weekdays) {
            val offset = isoOffset(weekday)
            if (offset > currentOffset) return date.plusDays((offset - currentOffset).toLong())
        }
        val first = weekdays.firstOrNull() ?: return null
        val monday = date.minusDays(currentOffset.toLong())
        return monday.plusDays(step.toLong() * 7L + isoOffset(first))
    }

    private fun isoOffset(sundayFirstWeekday: Int): Int = (sundayFirstWeekday + 5) % 7

    private fun resolveMonthDay(month: YearMonth, monthDay: Int): LocalDate? = when {
        monthDay == -1 -> month.atEndOfMonth()
        monthDay in 1..31 -> month.atDay(minOf(monthDay, month.lengthOfMonth()))
        else -> null
    }

    private fun resolveOrdinalWeekday(month: YearMonth, value: OrdinalWeekday): LocalDate? {
        if (value.weekday !in 1..7 || (value.ordinal != -1 && value.ordinal !in 1..4)) return null
        val targetDay = if (value.weekday == 1) 7 else value.weekday - 1
        if (value.ordinal == -1) {
            val last = month.atEndOfMonth()
            val back = (last.dayOfWeek.value - targetDay + 7) % 7
            return last.minusDays(back.toLong())
        }
        val first = month.atDay(1)
        val offset = (targetDay - first.dayOfWeek.value + 7) % 7
        val day = 1 + offset + (value.ordinal - 1) * 7
        return if (day <= month.lengthOfMonth()) month.atDay(day) else null
    }

    private fun parseDay(value: String?): LocalDate? =
        value?.let { runCatching { LocalDate.parse(it.take(10)) }.getOrNull() }
}
