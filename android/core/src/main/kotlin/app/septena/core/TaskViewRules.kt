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
    /** The deadline the user planned past (docs/TASK_DATES_SPEC.md I8). */
    val deferredDeadline: String? = null,
    val source: String? = null,
    val sourceClient: String? = null,
    val acknowledgedAt: String? = null,
    val starred: Boolean = false,
    val recurrenceUnit: String? = null,
    val deletedAt: String? = null,
    val fadedAt: String? = null,
    val touchedAt: String? = null,
    val startTime: String? = null,
    val durationMinutes: Int? = null,
    val timeZone: String? = null,
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
                deferredDeadline = f[RegistryEntityFields.Task.DEFERRED_DEADLINE].stringValue(),
                today = f[RegistryEntityFields.Task.TODAY].booleanValue() ?: false,
                todaySetOn = f[RegistryEntityFields.Task.TODAY_SET_ON].stringValue(),
                source = f[RegistryEntityFields.Task.SOURCE].stringValue(),
                sourceClient = f[RegistryEntityFields.Task.SOURCE_CLIENT].stringValue(),
                acknowledgedAt = f[RegistryEntityFields.Task.ACKNOWLEDGED_AT].stringValue(),
                starred = f[RegistryEntityFields.Task.STARRED].booleanValue() ?: false,
                recurrenceUnit = f[RegistryEntityFields.Task.RECURRENCE_UNIT].stringValue(),
                deletedAt = record.deletedAt,
                fadedAt = f[RegistryEntityFields.Task.FADED_AT].stringValue(),
                touchedAt = f[RegistryEntityFields.Task.TOUCHED_AT].stringValue(),
                startTime = f[RegistryEntityFields.Task.START_TIME].stringValue(),
                durationMinutes = when (val raw = f[RegistryEntityFields.Task.DURATION_MINUTES]) {
                    is JsonValue.IntegerValue -> raw.value.toInt()
                    is JsonValue.DecimalValue -> raw.value.toInt()
                    else -> null
                },
                timeZone = f[RegistryEntityFields.Task.TIME_ZONE].stringValue(),
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
    /** Core R3: `"overdue"` or `"dueToday"`, else null. */
    val dueState: String? = null,
    /** Core R4: true when the deadline renders in red. */
    val deadlineRed: Boolean = false,
    /** Core upcoming bucket day (`YYYY-MM-DD`) when the task matches Upcoming, else null. */
    val upcomingDay: String? = null,
)

/**
 * List membership, from the shared core (`views.rs`, ADR 0025 C1 #247): the
 * rule the Apple apps and the backend run. today and now come from DayClock.
 */
object TaskViewRules {
    const val DUE_OVERDUE = "overdue"
    const val DUE_TODAY = "dueToday"

    /** Core membership for non-open, heading, or deleted rows without crossing JNA. */
    val INACTIVE_MEMBERSHIP = TaskViewMembership(
        isUnfiled = false,
        isInboxMember = false,
        inTriageBand = false,
        isOnToday = false,
        inTodayInbox = false,
        daysOnToday = 0,
        matchesView = mapOf(
            RegistryDestinationIds.TODAY to false,
            RegistryDestinationIds.INBOX to false,
            RegistryDestinationIds.UPCOMING to false,
            RegistryDestinationIds.ANYTIME to false,
        ),
        dueState = null,
        deadlineRed = false,
    )

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
            dueState = m.dueState,
            deadlineRed = m.deadlineRed,
            upcomingDay = m.upcomingDay,
        )
    }

    /**
     * The Review group of a task (docs/REVIEW_SPEC.md §1), or null when it is not in Review.
     * [conversationGroup] is the core's group for its conversation.
     */
    fun reviewGroup(task: TaskSnapshot, conversationGroup: String?): String? = when {
        task.status != RegistryEntityEnums.TaskStatus.OPEN || task.isHeading || task.deletedAt != null -> null
        TaskFadeRules.isFaded(task.fadedAt) -> ReviewGroupIds.FADED
        else -> conversationGroup
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
        val membership = if (task.status == RegistryEntityEnums.TaskStatus.OPEN && !task.isHeading && task.deletedAt == null) {
            membership(task, today, now)
        } else {
            INACTIVE_MEMBERSHIP
        }
        return matchesView(task, membership, destinationId)
    }

    /** Reuses a precomputed core [TaskViewMembership] so list loops never cross FFI twice per task. */
    fun matchesView(
        task: TaskSnapshot,
        membership: TaskViewMembership,
        destinationId: String,
    ): Boolean {
        val activeMembership = membership.matchesView[destinationId]
        if (activeMembership != null) return activeMembership

        val isHeading = task.isHeading
        val isDeleted = task.deletedAt != null
        return when (destinationId) {
            RegistryDestinationIds.REPEATING ->
                task.status == RegistryEntityEnums.TaskStatus.OPEN &&
                    !isHeading && !isDeleted && !TaskFadeRules.isFaded(task.fadedAt) &&
                    task.recurrenceUnit in recurrenceUnits

            // Favorites: open starred tasks, as iOS.
            RegistryDestinationIds.STARRED ->
                task.status == RegistryEntityEnums.TaskStatus.OPEN &&
                    !isHeading && !isDeleted && !TaskFadeRules.isFaded(task.fadedAt) && task.starred

            // The Faded pile: open tasks the fade pass took out of their lists.
            RegistryDestinationIds.FADED ->
                task.status == RegistryEntityEnums.TaskStatus.OPEN &&
                    !isHeading && !isDeleted && TaskFadeRules.isFaded(task.fadedAt)

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

/** Ids of the Review groups (registry/destinations.json `review.groups`). */
object ReviewGroupIds {
    const val QUESTIONS: String = "questions"
    const val FINISHED: String = "finished"
    const val FADED: String = RegistryDestinationIds.FADED
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
    deferredDeadline = deferredDeadline,
    today = today,
    todaySetOn = todaySetOn,
    source = source,
    acknowledgedAt = acknowledgedAt,
    starred = starred,
    recurrenceUnit = recurrenceUnit,
    deletedAt = deletedAt,
    fadedAt = fadedAt,
    startTime = startTime,
    durationMinutes = durationMinutes,
    timeZone = timeZone,
    reminderAt = null,
    reminderSnoozedUntil = null,
    reminderDismissedAt = null,
    recurrenceAfterCompletion = null,
    recurrenceAnchorDate = null,
)
