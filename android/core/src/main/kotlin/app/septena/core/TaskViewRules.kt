package app.septena.core

import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.generated.RegistryRules
import java.time.Duration
import java.time.Instant
import java.time.LocalDate

/** Platform-neutral task values used by list membership and the adaptive UI. */
data class TaskSnapshot(
    val id: String,
    val title: String,
    val status: String,
    val kind: String? = null,
    val area: String? = null,
    val project: String? = null,
    val created: String? = null,
    val createdAt: String? = null,
    val scheduled: String? = null,
    val deadline: String? = null,
    val today: Boolean = false,
    val todaySetOn: String? = null,
    val source: String? = null,
    val acknowledgedAt: String? = null,
    val starred: Boolean = false,
    val recurrenceUnit: String? = null,
    val deletedAt: String? = null,
    val fadedAt: String? = null,
) {
    val isHeading: Boolean get() = kind == RegistryEntityEnums.TaskKind.HEADING

    companion object {
        fun from(record: SyncRecord): TaskSnapshot {
            require(record.entity == RegistryEntityNames.TASK) { "Expected a task record" }
            val f = record.fields
            return TaskSnapshot(
                id = record.id,
                title = f[RegistryEntityFields.Task.TITLE].stringValue().orEmpty(),
                status = f[RegistryEntityFields.Task.STATUS].stringValue().orEmpty(),
                kind = f[RegistryEntityFields.Task.KIND].stringValue(),
                area = f[RegistryEntityFields.Task.AREA].stringValue(),
                project = f[RegistryEntityFields.Task.PROJECT].stringValue(),
                created = f[RegistryEntityFields.Task.CREATED].stringValue(),
                createdAt = f[RegistryEntityFields.Task.CREATED_AT].stringValue(),
                scheduled = f[RegistryEntityFields.Task.SCHEDULED].stringValue(),
                deadline = f[RegistryEntityFields.Task.DEADLINE].stringValue(),
                today = f[RegistryEntityFields.Task.TODAY].booleanValue() ?: false,
                todaySetOn = f[RegistryEntityFields.Task.TODAY_SET_ON].stringValue(),
                source = f[RegistryEntityFields.Task.SOURCE].stringValue(),
                acknowledgedAt = f[RegistryEntityFields.Task.ACKNOWLEDGED_AT].stringValue(),
                starred = f[RegistryEntityFields.Task.STARRED].booleanValue() ?: false,
                recurrenceUnit = f[RegistryEntityFields.Task.RECURRENCE_UNIT].stringValue(),
                deletedAt = record.deletedAt,
            )
        }
    }
}

data class TaskViewMembership(
    val isUnfiled: Boolean,
    val isInboxMember: Boolean,
    val inTriageBand: Boolean,
    val isOnToday: Boolean,
    val inTodayInbox: Boolean,
    val daysOnToday: Int,
    val matchesView: Map<String, Boolean>,
)

/** Shared list membership rules; today and now are supplied by DayClock. */
object TaskViewRules {
    fun membership(task: TaskSnapshot, today: LocalDate, now: Instant): TaskViewMembership {
        val open = task.status == RegistryEntityEnums.TaskStatus.OPEN
        val deleted = task.deletedAt != null
        val faded = task.fadedAt != null
        val activeTask = open && !task.isHeading && !deleted && !faded
        val unfiled = task.area == null && task.project == null
        val isOnToday = activeTask && (
            task.today ||
                day(task.scheduled)?.let { !it.isAfter(today) } == true ||
                day(task.deadline)?.let { !it.isAfter(today) } == true
            )
        val isInbox = activeTask && unfiled
        val freshAgentProposal = isFreshAgentProposal(task, now)
        val inTriageBand = isInbox && if (task.source == "mcp") {
            freshAgentProposal && if (task.today || task.scheduled != null || task.deadline != null) {
                task.acknowledgedAt == null
            } else {
                true
            }
        } else {
            task.scheduled == null && task.deadline == null && !task.today
        }
        val inTodayInbox = inTriageBand || (isInbox && isOnToday)
        val hasAgentCue = task.source == "mcp" && task.acknowledgedAt == null && freshAgentProposal
        val daysOnToday = carriedDays(task, today, open, isOnToday, hasAgentCue)
        val scheduled = day(task.scheduled)
        val deadline = day(task.deadline)
        val matches = linkedMapOf(
            "today" to (activeTask && (isOnToday || inTriageBand)),
            "inbox" to inTodayInbox,
            "upcoming" to (activeTask && !task.today &&
                (scheduled?.isAfter(today) == true || deadline?.isAfter(today) == true)),
            "anytime" to (activeTask && !task.today && task.scheduled == null && task.deadline == null),
        )
        return TaskViewMembership(
            isUnfiled = unfiled,
            isInboxMember = isInbox,
            inTriageBand = inTriageBand,
            isOnToday = isOnToday,
            inTodayInbox = inTodayInbox,
            daysOnToday = daysOnToday,
            matchesView = matches,
        )
    }

    private fun isFreshAgentProposal(task: TaskSnapshot, now: Instant): Boolean {
        if (task.source != "mcp") return false
        val createdAt = instant(task.createdAt) ?: return false
        return Duration.between(createdAt, now) < Duration.ofDays(RegistryRules.cueDecayDays)
    }

    private fun carriedDays(
        task: TaskSnapshot,
        today: LocalDate,
        open: Boolean,
        isOnToday: Boolean,
        hasAgentCue: Boolean,
    ): Int {
        if (!open || !isOnToday || hasAgentCue) return 0
        val landed = buildList {
            if (task.today) day(task.todaySetOn)?.let(::add)
            day(task.scheduled)?.takeIf { !it.isAfter(today) }?.let(::add)
            day(task.deadline)?.takeIf { !it.isAfter(today) }?.let(::add)
        }.minOrNull() ?: return 0
        val created = day(task.created)
        val floor = created?.takeIf { it.isAfter(landed) } ?: landed
        return maxOf(0, (today.toEpochDay() - floor.toEpochDay()).toInt())
    }

    private fun day(raw: String?): LocalDate? = raw?.let { runCatching { LocalDate.parse(it.take(10)) }.getOrNull() }

    private fun instant(raw: String?): Instant? = raw?.let { runCatching { Instant.parse(it) }.getOrNull() }
}
