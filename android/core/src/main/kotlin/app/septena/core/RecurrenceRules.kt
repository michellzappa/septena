package app.septena.core

import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields.Task
import app.septena.sharedcore.OrdinalWeekday as CoreOrdinalWeekday
import app.septena.sharedcore.RecurrenceRule as CoreRecurrenceRule
import app.septena.sharedcore.checklistOccurrenceId as coreChecklistOccurrenceId
import app.septena.sharedcore.nextScheduledDate as coreNextScheduledDate
import app.septena.sharedcore.occurrenceId as coreOccurrenceId
import app.septena.sharedcore.invokeJson
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

data class OrdinalWeekday(val ordinal: Int, val weekday: Int)

data class RecurrenceRule(
    val unit: String,
    val interval: Int = 1,
    val afterCompletion: Boolean = true,
    val weekdays: List<Int>? = null,
    val monthDay: Int? = null,
    val ordinalWeekday: OrdinalWeekday? = null,
    val missed: String? = null,
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
            missed = fields[Task.RECURRENCE_MISSED].stringValue()?.takeIf {
                it == RegistryEntityEnums.RecurrenceMissed.KEEP_ONE_OPEN ||
                    it == RegistryEntityEnums.RecurrenceMissed.START_FRESH ||
                    it == RegistryEntityEnums.RecurrenceMissed.KEEP_EACH
            },
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

    data class Window(val create: List<String>, val expireBefore: String?)

    fun followsCalendar(mode: String?): Boolean =
        mode == RegistryEntityEnums.RecurrenceMissed.START_FRESH || mode == RegistryEntityEnums.RecurrenceMissed.KEEP_EACH

    fun window(rule: RecurrenceRule, fields: Map<String, JsonValue>, now: Instant): Window? {
        val slot = fields[Task.RECURRENCE_ANCHOR_DATE].stringValue() ?: fields[Task.SCHEDULED].stringValue() ?: return null
        val zone = fields[Task.TIME_ZONE].stringValue()?.let { runCatching { ZoneId.of(it) }.getOrNull() } ?: ZoneId.systemDefault()
        val local = now.atZone(zone)
        val options = linkedMapOf(
            "unit" to JsonValue.StringValue(rule.unit),
            "interval" to JsonValue.IntegerValue(rule.interval.toLong()),
            "afterCompletion" to JsonValue.BooleanValue(rule.afterCompletion),
            "weekdays" to (fields[Task.RECURRENCE_WEEKDAYS] ?: JsonValue.Null),
            "monthDay" to (fields[Task.RECURRENCE_MONTH_DAY] ?: JsonValue.Null),
            "ordinalWeekday" to (fields[Task.RECURRENCE_ORDINAL_WEEKDAY] ?: JsonValue.Null),
        )
        val input = JsonValue.ObjectValue(mapOf(
            "mode" to JsonValue.stringOrNull(rule.missed),
            "lastSlot" to JsonValue.StringValue(slot),
            "today" to JsonValue.StringValue(local.toLocalDate().toString()),
            "localTime" to JsonValue.StringValue(local.format(DateTimeFormatter.ofPattern("HH:mm"))),
            "startTime" to (fields[Task.START_TIME] ?: JsonValue.Null),
            "rule" to JsonValue.ObjectValue(options),
        ))
        val output = (JsonValue.parse(invokeJson("recurrenceWindow", input.canonicalJson())) as JsonValue.ObjectValue).fields
        return Window(
            (output["create"] as? JsonValue.ArrayValue)?.values.orEmpty().mapNotNull { it.stringValue() },
            output["expireBefore"].stringValue(),
        )
    }

    fun occurrenceId(sourceTaskId: String, scheduled: String): String = coreOccurrenceId(sourceTaskId, scheduled)

    fun checklistOccurrenceId(newTaskId: String, index: Int, sourceItemId: String): String =
        coreChecklistOccurrenceId(newTaskId, index.toUInt(), sourceItemId)
}
