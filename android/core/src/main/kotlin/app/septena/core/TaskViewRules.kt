package app.septena.core

import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.generated.RegistryDestinationIds
import app.septena.sharedcore.taskViewMembership
import java.time.Instant
import java.time.LocalDate
import app.septena.sharedcore.TaskSnapshot as CoreTaskSnapshot

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
    val sourceClient: String? = null,
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
                sourceClient = f[RegistryEntityFields.Task.SOURCE_CLIENT].stringValue(),
                acknowledgedAt = f[RegistryEntityFields.Task.ACKNOWLEDGED_AT].stringValue(),
                starred = f[RegistryEntityFields.Task.STARRED].booleanValue() ?: false,
                recurrenceUnit = f[RegistryEntityFields.Task.RECURRENCE_UNIT].stringValue(),
                deletedAt = record.deletedAt,
                fadedAt = f["fadedAt"].stringValue(),
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

/**
 * List membership, from the shared core (`views.rs`, ADR 0025 C1 #247): the
 * rule the Apple apps and the backend run. today and now come from DayClock.
 */
object TaskViewRules {
    private val recurrenceUnits = setOf(
        RegistryEntityEnums.RecurrenceUnit.DAY,
        RegistryEntityEnums.RecurrenceUnit.WEEK,
        RegistryEntityEnums.RecurrenceUnit.MONTH,
        RegistryEntityEnums.RecurrenceUnit.YEAR,
    )

    fun membership(task: TaskSnapshot, today: LocalDate, now: Instant): TaskViewMembership {
        val m = taskViewMembership(task.toCore(), today.toString(), now.toString())
        return TaskViewMembership(
            isUnfiled = m.isUnfiled,
            isInboxMember = m.isInboxMember,
            inTriageBand = m.inTriageBand,
            isOnToday = m.isOnToday,
            inTodayInbox = m.inTodayInbox,
            daysOnToday = m.daysOnToday.toInt(),
            matchesView = linkedMapOf(
                RegistryDestinationIds.TODAY to m.matchesToday,
                RegistryDestinationIds.INBOX to m.matchesInbox,
                RegistryDestinationIds.UPCOMING to m.matchesUpcoming,
                RegistryDestinationIds.ANYTIME to m.matchesAnytime,
            ),
        )
    }

    /**
     * Membership for a registry destination, including the historical lists
     * whose rows are not represented by the open-task fields in
     * [TaskViewMembership.matchesView].
     */
    fun matchesView(
        task: TaskSnapshot,
        destinationId: String,
        today: LocalDate,
        now: Instant,
    ): Boolean {
        val activeMembership = membership(task, today, now).matchesView[destinationId]
        if (activeMembership != null) return activeMembership

        val isHeading = task.isHeading
        val isDeleted = task.deletedAt != null
        return when (destinationId) {
            RegistryDestinationIds.REPEATING ->
                task.status == RegistryEntityEnums.TaskStatus.OPEN &&
                    !isHeading && !isDeleted && !TaskFadeRules.isFaded(task.fadedAt) &&
                    task.recurrenceUnit in recurrenceUnits

            RegistryDestinationIds.LOGBOOK ->
                !isHeading && !isDeleted &&
                    task.status in setOf(
                        RegistryEntityEnums.TaskStatus.DONE,
                        RegistryEntityEnums.TaskStatus.CANCELLED,
                    )

            RegistryDestinationIds.RECENTLY_DELETED -> isDeleted && !isHeading
            else -> false
        }
    }
}

/** The task as the shared core reads it. */
internal fun TaskSnapshot.toCore(): CoreTaskSnapshot = CoreTaskSnapshot(
    id = id,
    title = title,
    status = status,
    kind = kind,
    area = area,
    project = project,
    created = created,
    createdAt = createdAt,
    scheduled = scheduled,
    deadline = deadline,
    today = today,
    todaySetOn = todaySetOn,
    source = source,
    acknowledgedAt = acknowledgedAt,
    starred = starred,
    recurrenceUnit = recurrenceUnit,
    deletedAt = deletedAt,
    fadedAt = fadedAt,
    startTime = null,
    durationMinutes = null,
    timeZone = null,
    reminderAt = null,
    reminderSnoozedUntil = null,
    reminderDismissedAt = null,
    recurrenceAfterCompletion = null,
    recurrenceAnchorDate = null,
)
