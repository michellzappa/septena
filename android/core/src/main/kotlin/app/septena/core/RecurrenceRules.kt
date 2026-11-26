package app.septena.core

import app.septena.core.generated.RegistryEntityFields.Task
import app.septena.sharedcore.OrdinalWeekday as CoreOrdinalWeekday
import app.septena.sharedcore.RecurrenceRule as CoreRecurrenceRule
import app.septena.sharedcore.checklistOccurrenceId as coreChecklistOccurrenceId
import app.septena.sharedcore.nextScheduledDate as coreNextScheduledDate
import app.septena.sharedcore.occurrenceId as coreOccurrenceId

data class OrdinalWeekday(val ordinal: Int, val weekday: Int)

data class RecurrenceRule(
    val unit: String,
    val interval: Int = 1,
    val afterCompletion: Boolean = true,
    val weekdays: List<Int>? = null,
    val monthDay: Int? = null,
    val ordinalWeekday: OrdinalWeekday? = null,
)

/**
 * Recurrence, from the shared core (`recurrence.rs`, ADR 0025 C1 #247): the
 * date arithmetic and the occurrence ids Apple and the backend run, so a
 * completion on any device converges on one next row.
 */
object RecurrenceRules {
    fun fromFields(fields: Map<String, JsonValue>): RecurrenceRule? {
        val unit = fields[Task.RECURRENCE_UNIT].stringValue() ?: return null
        val ordinal = fields[Task.RECURRENCE_ORDINAL_WEEKDAY] as? JsonValue.ObjectValue
        return RecurrenceRule(
            unit = unit,
            interval = fields[Task.RECURRENCE_INTERVAL].longValue()?.toInt() ?: 1,
            afterCompletion = fields[Task.RECURRENCE_AFTER_COMPLETION].booleanValue() ?: true,
            weekdays = (fields[Task.RECURRENCE_WEEKDAYS] as? JsonValue.ArrayValue)?.values?.mapNotNull { it.longValue()?.toInt() },
            monthDay = fields[Task.RECURRENCE_MONTH_DAY].longValue()?.toInt(),
            ordinalWeekday = ordinal?.let {
                val o = it["ordinal"].longValue()?.toInt()
                val w = it["weekday"].longValue()?.toInt()
                if (o != null && w != null) OrdinalWeekday(o, w) else null
            },
        )
    }

    fun nextScheduledDate(
        completedOn: String,
        scheduled: String?,
        logicalScheduled: String? = null,
        rule: RecurrenceRule,
    ): String? = coreNextScheduledDate(
        completedOn,
        scheduled,
        logicalScheduled,
        CoreRecurrenceRule(
            unit = rule.unit,
            interval = rule.interval,
            afterCompletion = rule.afterCompletion,
            weekdays = rule.weekdays,
            monthDay = rule.monthDay,
            ordinalWeekday = rule.ordinalWeekday?.let { CoreOrdinalWeekday(it.ordinal, it.weekday) },
        ),
    )

    fun occurrenceId(sourceTaskId: String, scheduled: String): String = coreOccurrenceId(sourceTaskId, scheduled)

    fun checklistOccurrenceId(newTaskId: String, index: Int, sourceItemId: String): String =
        coreChecklistOccurrenceId(newTaskId, index.toUInt(), sourceItemId)
}
