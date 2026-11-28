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
    /** Who the user handed the task to (docs/REVIEW_SPEC.md §6), or null. */
    val waitingOn: String? = null,
    /** The day the wait started (`YYYY-MM-DD`), or null. */
    val waitingSince: String? = null,
    /** Shared projects: the member id of the person who does this task. */
    val assignedTo: String? = null,
    /** Shared projects: the member id who set `assignedTo` (server-owned). */
    val assignedBy: String? = null,
    /** Shared projects: the day `assignedTo` was set (`YYYY-MM-DD`, server-owned). */
    val assignedAt: String? = null,
    /** True when this shared task is assigned to another member (`assignedTo != share.me`). */
    val assignedToOther: Boolean = false,
    /** Shared-project Waiting target name when this user assigned the task to another member. */
    val sharedWaitingOn: String? = null,
    /** Shared-project Waiting start day (`assignedAt`). */
    val sharedWaitingSince: String? = null,
) {
    val isHeading: Boolean get() = kind == RegistryEntityEnums.TaskKind.HEADING

    /** The task waits on a person (docs/REVIEW_SPEC.md §6): manual `waitingOn` or shared assignment by me. */
    val isWaiting: Boolean get() = !waitingOn.isNullOrBlank() || !sharedWaitingOn.isNullOrBlank()

    /** Active wait target name, manual `waitingOn` first. */
    val effectiveWaitingOn: String?
        get() = waitingOn?.trim()?.takeIf(String::isNotEmpty) ?: sharedWaitingOn

    /** Active wait start day (`YYYY-MM-DD`), for oldest-first sorting in Review ▸ Waiting. */
    val effectiveWaitingSince: String?
        get() = if (!waitingOn.isNullOrBlank()) waitingSince else sharedWaitingSince

    companion object {
        fun from(record: SyncRecord, shares: Map<String, ProjectShare> = emptyMap()): TaskSnapshot {
            require(record.entity == RegistryEntityNames.TASK) { "Expected a task record" }
            val f = record.fields
            val project = f[RegistryEntityFields.Task.PROJECT].stringValue()
            val assignedTo = f[RegistryEntityFields.Task.ASSIGNED_TO].stringValue()
            val assignedBy = f[RegistryEntityFields.Task.ASSIGNED_BY].stringValue()
            val assignedAt = f[RegistryEntityFields.Task.ASSIGNED_AT].stringValue()
            val share = project?.let(shares::get)
            val assignedToOther = if (share != null) {
                !assignedTo.isNullOrBlank() && assignedTo != share.me
            } else {
                f["assignedToOther"].booleanValue() ?: false
            }
            val isSharedWaiting = share != null &&
                !assignedTo.isNullOrBlank() &&
                assignedTo != share.me &&
                assignedBy == share.me
            val sharedWaitingOn = if (isSharedWaiting) {
                share.member(assignedTo.orEmpty())?.name ?: assignedTo
            } else {
                null
            }
            return TaskSnapshot(
                id = record.id,
                title = f[RegistryEntityFields.Task.TITLE].stringValue().orEmpty(),
                status = f[RegistryEntityFields.Task.STATUS].stringValue().orEmpty(),
                kind = f[RegistryEntityFields.Task.KIND].stringValue(),
                area = f[RegistryEntityFields.Task.AREA].stringValue(),
                project = project,
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
                waitingOn = f[RegistryEntityFields.Task.WAITING_ON].stringValue(),
                waitingSince = f[RegistryEntityFields.Task.WAITING_SINCE].stringValue(),
                assignedTo = assignedTo,
                assignedBy = assignedBy,
                assignedAt = assignedAt,
                assignedToOther = assignedToOther,
                sharedWaitingOn = sharedWaitingOn,
                sharedWaitingSince = if (isSharedWaiting) assignedAt else null,
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
     * The Review group of a task (docs/REVIEW_SPEC.md §1), or null when it is not in Review:
     * the first that fits of what waits on the user, a wait on a person (§6, ADR 0053), agent work
     * in progress, and Faded (ADR 0046). [conversationGroup] is the core's group for its
     * conversation; [agentStage] is the core's agent stage, which shows as its own group while the
     * agent works.
     */
    fun reviewGroup(task: TaskSnapshot, conversationGroup: String?, agentStage: String? = null): String? = when {
        task.status != RegistryEntityEnums.TaskStatus.OPEN || task.isHeading || task.deletedAt != null -> null
        conversationGroup != null -> conversationGroup
        task.isWaiting -> ReviewGroupIds.WAITING
        agentStage in ReviewGroupIds.AGENT_WORK -> agentStage
        TaskFadeRules.isFaded(task.fadedAt) -> ReviewGroupIds.FADED
        else -> null
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

            // Starred: open starred tasks, as iOS.
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
    const val WAITING: String = "waiting"
    const val WORKING: String = "working"
    const val QUEUED: String = "queued"
    const val STOPPED: String = "stopped"
    const val FADED: String = RegistryDestinationIds.FADED

    /** Agent work in progress: the core's agent stages that show as Review groups. `done` does not. */
    val AGENT_WORK: Set<String> = setOf(WORKING, QUEUED, STOPPED)

    /** Every group, in the order the Review list draws them. */
    val ORDER: List<String> = listOf(QUESTIONS, FINISHED, WAITING, WORKING, QUEUED, STOPPED, FADED)

    /** The groups that wait on the user. Only they count in the Review badge; Waiting does not. */
    val BADGE: Set<String> = setOf(QUESTIONS, FINISHED)
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
    assignedToOther = assignedToOther,
)
