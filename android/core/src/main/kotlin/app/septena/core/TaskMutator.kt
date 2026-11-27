package app.septena.core

import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityLimits
import app.septena.core.generated.RegistryEntityNames
import app.septena.sharedcore.DateAction
import app.septena.sharedcore.RescheduleMode
import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import app.septena.sharedcore.TaskSnapshot as CoreTaskSnapshot
import app.septena.sharedcore.applyDateAction as coreApplyDateAction
import app.septena.sharedcore.nextOccurrenceDates as coreNextOccurrenceDates

/** User writes cross this boundary so optimistic rows and outbox operations stay atomic. */
class TaskMutator(
    private val store: TaskStore,
    private val clock: DayClock,
    private val ids: TaskIdGenerator,
    /** Ends the open Do of a task that this mutator closes. Null in hosts without Do. */
    private val doSessions: DoSessionMutator? = null,
    private val sourceClient: String = "Septena Android",
) {
    /**
     * Inline-create drafts whose push waits for the first title (Apple's
     * `deferPush`). Every write to one stays local until a write sets a
     * non-blank title; that write releases the merged insert to the server.
     */
    private val deferredDrafts: MutableSet<String> = java.util.concurrent.ConcurrentHashMap.newKeySet()

    /** When a write to [id] may be sent. A blank draft stays local. */
    private fun pushTime(id: String, changes: Map<String, JsonValue>): Instant {
        if (id !in deferredDrafts) return Instant.EPOCH
        val title = changes[RegistryEntityFields.Task.TITLE]?.stringValue()
        if (title != null && title.isNotBlank()) {
            deferredDrafts.remove(id)
            return Instant.EPOCH
        }
        return DEFERRED_PUSH
    }

    /** True while [id] is an inline draft that has never had a title. */
    fun isUnsentDraft(id: String): Boolean = id in deferredDrafts

    suspend fun create(
        title: String,
        area: String? = null,
        project: String? = null,
        scheduled: String? = null,
        deadline: String? = null,
        today: Boolean = false,
        notes: String? = null,
        source: String = app.septena.core.generated.RegistryEntityEnums.TaskSource.APP,
        heading: String? = null,
        position: Double? = null,
        /**
         * An inline-create draft (empty title): the row stays on this device
         * until its first title write, like Apple's `deferPush`.
         */
        deferPush: Boolean = false,
    ): TaskRecord = createTask(
        title = title,
        area = area,
        project = project,
        scheduled = scheduled,
        deadline = deadline,
        today = today,
        notes = notes,
        source = source,
        kind = null,
        heading = heading,
        position = position,
        deferPush = deferPush,
    )

    suspend fun createHeading(title: String, project: String, position: Double? = null, id: String? = null): TaskRecord = createTask(
        title = title,
        area = null,
        project = project,
        scheduled = null,
        deadline = null,
        today = false,
        notes = null,
        source = app.septena.core.generated.RegistryEntityEnums.TaskSource.APP,
        kind = app.septena.core.generated.RegistryEntityEnums.TaskKind.HEADING,
        heading = null,
        position = position,
        explicitId = id,
    )

    private suspend fun createTask(
        title: String,
        area: String?,
        project: String?,
        scheduled: String?,
        deadline: String?,
        today: Boolean,
        notes: String?,
        source: String,
        kind: String?,
        heading: String?,
        position: Double?,
        explicitId: String? = null,
        deferPush: Boolean = false,
    ): TaskRecord {
        val id = explicitId ?: ids.nextTaskId()
        if (explicitId != null) store.record(RegistryEntityNames.TASK, id)?.let { return it.asTaskRecord() }
        val normalizedTitle = title.trim { it.isWhitespace() }
        val now = clock.now()
        val todayString = clock.today(now).toString()
        val fields = TaskRecord.createFields(
            title = normalizedTitle,
            created = todayString,
            createdAt = WireTimestamp.format(now),
            area = area,
            project = project,
            scheduled = scheduled,
            deadline = deadline,
            today = today,
            todaySetOn = if (today) todayString else null,
            notes = notes,
            source = source,
            sourceClient = sourceClient,
            kind = kind,
            heading = heading,
            position = position,
        )
        validateTitle(normalizedTitle)
        RegistryValidator.requireValidUpsert(RegistryEntityNames.TASK, id, fields, insert = true)

        val task = TaskRecord(id, fields)
        if (deferPush) deferredDrafts += id
        store.writeLocalAndEnqueue(
            task.asSyncRecord(),
            task.toUpsert(ids.nextClientOpId()),
            if (deferPush) DEFERRED_PUSH else Instant.EPOCH,
        )
        return task
    }

    suspend fun rename(id: String, title: String): TaskRecord? {
        val normalizedTitle = title.trim { it.isWhitespace() }
        validateTitle(normalizedTitle)
        val existing = store.record(RegistryEntityNames.TASK, id)?.asTaskRecord() ?: return null
        if (existing.deletedAt != null) return null
        val changes = mapOf(RegistryEntityFields.Task.TITLE to JsonValue.StringValue(normalizedTitle))
        RegistryValidator.requireValidUpsert(RegistryEntityNames.TASK, id, changes, insert = false)
        val updated = existing.changing(changes)
        val operation = SyncOperation.Upsert(ids.nextClientOpId(), RegistryEntityNames.TASK, id, changes)
        store.writeLocalAndEnqueue(updated.asSyncRecord(), operation, pushTime(id, changes))
        return updated
    }

    /**
     * Applies a registry validated task patch for actions whose semantics are owned by the caller.
     * [notesBase]: the notes an editor started from, when the stored ones may have moved on since.
     */
    suspend fun updateFields(id: String, changes: Map<String, JsonValue>, notesBase: NotesBase? = null): TaskRecord? {
        require(changes.isNotEmpty()) { "A task update must contain at least one field" }
        RegistryValidator.requireValidUpsert(RegistryEntityNames.TASK, id, changes, insert = false)
        val existing = store.record(RegistryEntityNames.TASK, id)?.asTaskRecord() ?: return null
        if (existing.deletedAt != null) return null
        val updated = existing.changing(changes)
        store.writeLocalAndEnqueue(
            updated.asSyncRecord(),
            SyncOperation.Upsert(
                ids.nextClientOpId(), RegistryEntityNames.TASK, id, changes,
                base = NotesBase.of(RegistryEntityNames.TASK, changes, existing.fields, notesBase),
            ),
            pushTime(id, changes),
        )
        if (RegistryEntityFields.Task.STATUS in changes || RegistryEntityFields.Task.FADED_AT in changes) endDoIfClosed(updated)
        return updated
    }

    /** One write closed, deleted or faded the task: its open Do ends at once (docs/DO_SPEC.md §2.1). */
    private suspend fun endDoIfClosed(task: TaskRecord) {
        val faded = TaskFadeRules.isFaded(task.fields[RegistryEntityFields.Task.FADED_AT].stringValue())
        if (task.status == TaskStatus.OPEN && task.deletedAt == null && !faded) return
        doSessions?.taskClosed(task.id)
    }

    /**
     * A user gesture on the task: stamps the fade clock (docs/TASK_FADE_SPEC.md §3, Swift `touch`). A
     * defer adds 1 to `deferCount`; any other gesture resets it. Only the gesture layer calls this:
     * the other mutators also run for background work.
     */
    suspend fun touch(id: String, deferred: Boolean = false): TaskRecord? {
        val existing = store.record(RegistryEntityNames.TASK, id) ?: return null
        val defers = if (deferred) (existing.fields[RegistryEntityFields.Task.DEFER_COUNT].longValue() ?: 0L) + 1L else 0L
        return updateFields(
            id,
            mapOf(
                RegistryEntityFields.Task.TOUCHED_AT to JsonValue.StringValue(WireTimestamp.format(clock.now())),
                RegistryEntityFields.Task.DEFER_COUNT to JsonValue.IntegerValue(defers),
                RegistryEntityFields.Task.FADED_AT to JsonValue.Null,
            ),
        )
    }

    /** A1 when [enabled], else A3 (Remove from Today): the core decides the fields. */
    suspend fun setToday(
        id: String,
        enabled: Boolean,
        mode: RescheduleMode = RescheduleMode.MAKE_EXCEPTION,
    ): TaskRecord? =
        applyDateAction(id, if (enabled) DateAction.PutOnToday(mode) else DateAction.RemoveFromToday)

    suspend fun setStarred(id: String, starred: Boolean): TaskRecord? = updateFields(
        id,
        mapOf(RegistryEntityFields.Task.STARRED to JsonValue.BooleanValue(starred)),
    )

    /** Who does the task in a shared project: a member id, or null for nobody. */
    suspend fun assign(id: String, memberId: String?): TaskRecord? {
        val existing = store.record(RegistryEntityNames.TASK, id)?.asTaskRecord() ?: return null
        if (existing.deletedAt != null) return null
        val normalized = memberId?.trim()?.takeIf(String::isNotEmpty)
        val wireChanges = linkedMapOf<String, JsonValue>(
            RegistryEntityFields.Task.ASSIGNED_TO to JsonValue.stringOrNull(normalized),
        )
        RegistryValidator.requireValidUpsert(RegistryEntityNames.TASK, id, wireChanges, insert = false)
        val projectId = existing.fields[RegistryEntityFields.Task.PROJECT].stringValue()
        val share = projectId?.let { ProjectShare.of(store.record(RegistryEntityNames.PROJECT, it)) }
        val localChanges = LinkedHashMap<String, JsonValue>(wireChanges)
        if (normalized != null && share != null) {
            localChanges[RegistryEntityFields.Task.ASSIGNED_BY] = JsonValue.StringValue(share.me)
            localChanges[RegistryEntityFields.Task.ASSIGNED_AT] = JsonValue.StringValue(clock.today(clock.now()).toString())
        } else {
            localChanges[RegistryEntityFields.Task.ASSIGNED_BY] = JsonValue.Null
            localChanges[RegistryEntityFields.Task.ASSIGNED_AT] = JsonValue.Null
        }
        val updated = existing.changing(localChanges)
        val operation = SyncOperation.Upsert(ids.nextClientOpId(), RegistryEntityNames.TASK, id, wireChanges)
        store.writeLocalAndEnqueue(updated.asSyncRecord(), operation)
        return updated
    }

    /** Got It Back (docs/REVIEW_SPEC.md §6): clears manual waiting and takes back shared tasks you assigned. */
    suspend fun gotItBack(id: String): TaskRecord? {
        val existing = store.record(RegistryEntityNames.TASK, id)?.asTaskRecord() ?: return null
        if (existing.deletedAt != null) return null
        var result: TaskRecord? = existing
        val hasManualWait = !existing.fields[RegistryEntityFields.Task.WAITING_ON].stringValue().isNullOrBlank()
        if (hasManualWait) {
            result = setWaiting(id, null) ?: return null
        }
        val projectId = existing.fields[RegistryEntityFields.Task.PROJECT].stringValue()
        val assignedTo = existing.fields[RegistryEntityFields.Task.ASSIGNED_TO].stringValue()
        val assignedBy = existing.fields[RegistryEntityFields.Task.ASSIGNED_BY].stringValue()
        val share = projectId?.let { ProjectShare.of(store.record(RegistryEntityNames.PROJECT, it)) }
        if (share != null && !assignedTo.isNullOrBlank() && assignedTo != share.me && assignedBy == share.me) {
            result = assign(id, share.me) ?: return null
        }
        return result
    }

    /** A2 for a day (a day on or before today is A1), A5 for none. */
    suspend fun schedule(
        id: String,
        day: String?,
        mode: RescheduleMode = RescheduleMode.MAKE_EXCEPTION,
    ): TaskRecord? = setWhen(id, day, mode)

    /** The user-visible When value: A2 for a day (today or earlier is A1), A5 for none. */
    suspend fun setWhen(
        id: String,
        day: String?,
        mode: RescheduleMode = RescheduleMode.MAKE_EXCEPTION,
    ): TaskRecord? = applyDateAction(
        id,
        if (day == null) DateAction.ClearWhenDate else DateAction.ScheduleFor(day, mode),
    )

    /** A9: set or clear the time slot. A time with no day pins the task to Today. */
    suspend fun setTimeSlot(id: String, startTime: String?, durationMinutes: Long?, timeZone: String?): TaskRecord? =
        applyDateAction(id, DateAction.SetTimeSlot(startTime, durationMinutes?.toInt(), timeZone))

    /** A7 / A8: set or clear the deadline. */
    suspend fun setDeadline(id: String, day: String?): TaskRecord? = applyDateAction(id, DateAction.SetDeadline(day))

    /** Saves one repeat-rule edit, including any compatible custom pattern and the paused state. */
    suspend fun setRepeat(id: String, rule: RecurrenceRule?, paused: Boolean? = null): TaskRecord? {
        val existing = store.record(RegistryEntityNames.TASK, id)?.asTaskRecord() ?: return null
        if (existing.deletedAt != null) return null
        val f = existing.fields
        val unit = rule?.unit
        val fixed = rule?.afterCompletion == false
        val previous = RecurrenceRules.fromFields(f)
        val missed = if (fixed) rule?.missed ?: previous?.missed
            ?: RegistryEntityEnums.RecurrenceMissed.KEEP_ONE_OPEN.takeIf { previous == null } else null
        val anchor = f[RegistryEntityFields.Task.RECURRENCE_ANCHOR_DATE].stringValue()
            ?: f[RegistryEntityFields.Task.SCHEDULED].stringValue()
        val starts = when {
            missed == null -> null
            previous?.missed == missed -> f[RegistryEntityFields.Task.RECURRENCE_MISSED_FROM].stringValue()
            previous == null -> anchor
            else -> rule?.let { RecurrenceRules.nextScheduledDate(clock.today().toString(), anchor, anchor, it) }
        }
        val weekdays = rule?.weekdays?.takeIf { fixed && unit == RegistryEntityEnums.RecurrenceUnit.WEEK }
        val useMonthRule = fixed && (unit == RegistryEntityEnums.RecurrenceUnit.MONTH || unit == RegistryEntityEnums.RecurrenceUnit.YEAR)
        val ordinal = rule?.ordinalWeekday?.takeIf { useMonthRule }
        val changes = linkedMapOf(
            RegistryEntityFields.Task.RECURRENCE_UNIT to JsonValue.stringOrNull(unit),
            RegistryEntityFields.Task.RECURRENCE_INTERVAL to JsonValue.integerOrNull(rule?.interval?.coerceIn(1, 99)?.toLong()),
            RegistryEntityFields.Task.RECURRENCE_AFTER_COMPLETION to JsonValue.BooleanValue(rule?.afterCompletion == true),
            RegistryEntityFields.Task.RECURRENCE_MISSED to JsonValue.stringOrNull(missed),
            RegistryEntityFields.Task.RECURRENCE_MISSED_FROM to JsonValue.stringOrNull(starts),
            RegistryEntityFields.Task.RECURRENCE_PAUSED to JsonValue.BooleanValue(
                rule != null && (paused ?: f[RegistryEntityFields.Task.RECURRENCE_PAUSED].booleanValue() ?: false),
            ),
            RegistryEntityFields.Task.RECURRENCE_SERIES_ID to JsonValue.stringOrNull(
                if (rule == null) null else f[RegistryEntityFields.Task.RECURRENCE_SERIES_ID].stringValue() ?: id,
            ),
            RegistryEntityFields.Task.RECURRENCE_ANCHOR_DATE to JsonValue.stringOrNull(
                if (fixed) f[RegistryEntityFields.Task.RECURRENCE_ANCHOR_DATE].stringValue()
                    ?: f[RegistryEntityFields.Task.SCHEDULED].stringValue() else null,
            ),
            RegistryEntityFields.Task.RECURRENCE_WEEKDAYS to (weekdays?.takeIf { it.isNotEmpty() }?.let { days ->
                JsonValue.ArrayValue(days.sorted().map { JsonValue.IntegerValue(it.toLong()) })
            } ?: JsonValue.Null),
            RegistryEntityFields.Task.RECURRENCE_MONTH_DAY to JsonValue.integerOrNull(
                rule?.monthDay?.takeIf { useMonthRule }?.toLong(),
            ),
            RegistryEntityFields.Task.RECURRENCE_ORDINAL_WEEKDAY to (ordinal?.let {
                JsonValue.ObjectValue(mapOf(
                    "ordinal" to JsonValue.IntegerValue(it.ordinal.toLong()),
                    "weekday" to JsonValue.IntegerValue(it.weekday.toLong()),
                ))
            } ?: JsonValue.Null),
        ).apply {
            if (RecurrenceRules.followsCalendar(missed) && f[RegistryEntityFields.Task.TIME_ZONE].stringValue() == null) {
                put(RegistryEntityFields.Task.TIME_ZONE, JsonValue.StringValue(ZoneId.systemDefault().id))
            }
        }.filter { (field, value) -> value != (f[field] ?: JsonValue.Null) }
        if (changes.isEmpty()) return existing
        val series = f[RegistryEntityFields.Task.RECURRENCE_SERIES_ID].stringValue() ?: id
        val shared = changes - setOf(RegistryEntityFields.Task.RECURRENCE_ANCHOR_DATE, RegistryEntityFields.Task.TIME_ZONE)
        if (shared.isNotEmpty()) {
            for (member in store.records(RegistryEntityNames.TASK)) {
                if (member.id != id && member.deletedAt == null &&
                    member.fields[RegistryEntityFields.Task.RECURRENCE_SERIES_ID].stringValue() == series) {
                    updateFields(member.id, shared)
                }
            }
        }
        return updateFields(id, changes)
    }

    /**
     * One date action of docs/TASK_DATES_SPEC.md §4 (D5, #292). The shared core
     * decides every date field (When, deadline, Today pin and its stamp, time
     * slot, a reminder that follows the When date, the fixed-repeat slot, the
     * agent cue); this writes the changed fields in one queued write. No date
     * rule lives in Kotlin.
     */
    suspend fun applyDateAction(id: String, action: DateAction): TaskRecord? {
        val existing = store.record(RegistryEntityNames.TASK, id)?.asTaskRecord() ?: return null
        if (existing.deletedAt != null) return null
        val now = clock.now()
        val shares = ProjectShare.byProject(store)
        val patch = coreApplyDateAction(
            existing.toCoreSnapshot(shares),
            action,
            clock.today(now).toString(),
            WireTimestamp.format(now),
        )
        if (patch.changed.isEmpty()) return existing
        val f = patch.fields
        val changes = linkedMapOf<String, JsonValue>()
        for (name in patch.changed) {
            changes[name] = when (name) {
                RegistryEntityFields.Task.SCHEDULED -> JsonValue.stringOrNull(f.scheduled)
                RegistryEntityFields.Task.DEADLINE -> JsonValue.stringOrNull(f.deadline)
                RegistryEntityFields.Task.DEFERRED_DEADLINE -> JsonValue.stringOrNull(f.deferredDeadline)
                RegistryEntityFields.Task.TODAY -> JsonValue.BooleanValue(f.today)
                RegistryEntityFields.Task.TODAY_SET_ON -> JsonValue.stringOrNull(f.todaySetOn)
                RegistryEntityFields.Task.START_TIME -> JsonValue.stringOrNull(f.startTime)
                RegistryEntityFields.Task.DURATION_MINUTES -> JsonValue.integerOrNull(f.durationMinutes?.toLong())
                RegistryEntityFields.Task.TIME_ZONE -> JsonValue.stringOrNull(f.timeZone)
                RegistryEntityFields.Task.REMINDER_AT -> JsonValue.stringOrNull(f.reminderAt)
                RegistryEntityFields.Task.REMINDER_SNOOZED_UNTIL -> JsonValue.stringOrNull(f.reminderSnoozedUntil)
                RegistryEntityFields.Task.REMINDER_DISMISSED_AT -> JsonValue.stringOrNull(f.reminderDismissedAt)
                RegistryEntityFields.Task.RECURRENCE_ANCHOR_DATE -> JsonValue.stringOrNull(f.recurrenceAnchorDate)
                RegistryEntityFields.Task.ACKNOWLEDGED_AT -> JsonValue.stringOrNull(f.acknowledgedAt)
                else -> error("The core changed an unknown date field: $name")
            }
        }
        val updated = updateFields(id, changes) ?: return null
        val updatesSeries = when (action) {
            is DateAction.ScheduleFor -> action.mode == RescheduleMode.UPDATE_RULE
            is DateAction.PutOnToday -> action.mode == RescheduleMode.UPDATE_RULE
            else -> false
        }
        if (updatesSeries && RegistryEntityFields.Task.RECURRENCE_ANCHOR_DATE in patch.changed) {
            rebaseFixedSeries(updated)
        }
        return updated
    }

    /**
     * Rebases sibling open occurrences of a fixed repeating series after "Update Schedule"
     * moves the anchor slot (#573, mirroring Apple `TasksBackend.rebaseFixedSeries`).
     */
    private suspend fun rebaseFixedSeries(source: TaskRecord) {
        val rule = RecurrenceRules.fromFields(source.fields) ?: return
        if (rule.afterCompletion) return
        val newAnchor = source.fields[RegistryEntityFields.Task.RECURRENCE_ANCHOR_DATE].stringValue() ?: return
        val seriesId = source.fields[RegistryEntityFields.Task.RECURRENCE_SERIES_ID].stringValue() ?: source.id
        if (source.fields[RegistryEntityFields.Task.RECURRENCE_SERIES_ID].stringValue() != seriesId) {
            updateFields(source.id, mapOf(RegistryEntityFields.Task.RECURRENCE_SERIES_ID to JsonValue.StringValue(seriesId)))
        }
        val openSiblings = store.records(RegistryEntityNames.TASK)
            .filter { record ->
                record.id != source.id &&
                    record.deletedAt == null &&
                    record.fields[RegistryEntityFields.Task.STATUS].stringValue() ==
                    app.septena.core.generated.RegistryEntityEnums.TaskStatus.OPEN &&
                    (record.fields[RegistryEntityFields.Task.RECURRENCE_SERIES_ID].stringValue() ?: record.id) == seriesId
            }
            .sortedWith(
                compareBy<SyncRecord>(
                    {
                        it.fields[RegistryEntityFields.Task.RECURRENCE_ANCHOR_DATE].stringValue()
                            ?: it.fields[RegistryEntityFields.Task.SCHEDULED].stringValue()
                            ?: "9999-12-31"
                    },
                    { it.id },
                ),
            )
        var cursor = newAnchor
        for (sibling in openSiblings) {
            val next = RecurrenceRules.nextScheduledDate(
                completedOn = cursor,
                scheduled = cursor,
                logicalScheduled = cursor,
                rule = rule,
            ) ?: break
            cursor = next
            val siblingChanges = linkedMapOf<String, JsonValue>(
                RegistryEntityFields.Task.RECURRENCE_SERIES_ID to JsonValue.StringValue(seriesId),
                RegistryEntityFields.Task.RECURRENCE_ANCHOR_DATE to JsonValue.StringValue(cursor),
                RegistryEntityFields.Task.SCHEDULED to JsonValue.StringValue(cursor),
            )
            val oldScheduled = sibling.fields[RegistryEntityFields.Task.SCHEDULED].stringValue()
            val reminderAt = sibling.fields[RegistryEntityFields.Task.REMINDER_AT].stringValue()
            val shiftedReminder = TaskReminderRules.shiftOnReschedule(reminderAt, oldScheduled, cursor)
            if (shiftedReminder != reminderAt) {
                siblingChanges[RegistryEntityFields.Task.REMINDER_AT] = JsonValue.stringOrNull(shiftedReminder)
                siblingChanges[RegistryEntityFields.Task.REMINDER_SNOOZED_UNTIL] = JsonValue.Null
                siblingChanges[RegistryEntityFields.Task.REMINDER_DISMISSED_AT] = JsonValue.Null
            }
            updateFields(sibling.id, siblingChanges)
        }
    }

    /**
     * Sets or clears the timed reminder, as Apple's `setReminder`: a new
     * reminder starts with no snooze and no dismissal. [reminderAt] is wall
     * clock `YYYY-MM-DDTHH:MM` for a floating reminder or a UTC instant for a
     * fixed one.
     */
    suspend fun setReminder(id: String, reminderAt: String?, mode: String?): TaskRecord? = updateFields(
        id,
        linkedMapOf(
            RegistryEntityFields.Task.REMINDER_AT to JsonValue.stringOrNull(reminderAt),
            RegistryEntityFields.Task.REMINDER_MODE to JsonValue.stringOrNull(if (reminderAt == null) null else mode),
            RegistryEntityFields.Task.REMINDER_SNOOZED_UNTIL to JsonValue.Null,
            RegistryEntityFields.Task.REMINDER_DISMISSED_AT to JsonValue.Null,
        ),
    )

    /** Moves the alert to [until] and clears a dismissal. A task with no reminder is left as is. */
    suspend fun snoozeReminder(id: String, until: java.time.Instant): TaskRecord? {
        val existing = store.record(RegistryEntityNames.TASK, id)?.asTaskRecord() ?: return null
        if (existing.fields[RegistryEntityFields.Task.REMINDER_AT].stringValue() == null) return existing
        return updateFields(
            id,
            linkedMapOf(
                RegistryEntityFields.Task.REMINDER_SNOOZED_UNTIL to JsonValue.StringValue(WireTimestamp.format(until)),
                RegistryEntityFields.Task.REMINDER_DISMISSED_AT to JsonValue.Null,
            ),
        )
    }

    /** Marks the alert as seen on every device and clears a snooze. A task with no reminder is left as is. */
    suspend fun dismissReminder(id: String): TaskRecord? {
        val existing = store.record(RegistryEntityNames.TASK, id)?.asTaskRecord() ?: return null
        if (existing.fields[RegistryEntityFields.Task.REMINDER_AT].stringValue() == null) return existing
        return updateFields(
            id,
            linkedMapOf(
                RegistryEntityFields.Task.REMINDER_DISMISSED_AT to JsonValue.StringValue(WireTimestamp.format(clock.now())),
                RegistryEntityFields.Task.REMINDER_SNOOZED_UNTIL to JsonValue.Null,
            ),
        )
    }

    /**
     * Files a task in an area, a project, or (both null) the Inbox. A new home
     * drops the section: a heading only means something inside its project. A
     * move to the list the task is already in writes nothing.
     */
    suspend fun moveToList(id: String, area: String?, project: String?): TaskRecord? {
        val existing = store.record(RegistryEntityNames.TASK, id)?.asTaskRecord() ?: return null
        val targetArea = if (project == null) area else null
        if (existing.fields[RegistryEntityFields.Task.AREA].stringValue() == targetArea &&
            existing.fields[RegistryEntityFields.Task.PROJECT].stringValue() == project
        ) return existing
        return updateFields(
            id,
            mapOf(
                RegistryEntityFields.Task.AREA to JsonValue.stringOrNull(targetArea),
                RegistryEntityFields.Task.PROJECT to JsonValue.stringOrNull(project),
                RegistryEntityFields.Task.HEADING to JsonValue.Null,
            ),
        )
    }

    suspend fun setNotes(id: String, notes: String?): TaskRecord? = updateFields(
        id,
        mapOf(RegistryEntityFields.Task.NOTES to JsonValue.stringOrNull(notes)),
    )

    suspend fun setTags(id: String, tagIds: List<String>): TaskRecord? {
        require(tagIds.size.toLong() <= RegistryEntityLimits.MAX_TAGS_PER_TASK) {
            "Task has more tags than the registry limit"
        }
        return updateFields(
            id,
            mapOf(RegistryEntityFields.Task.TAGS to JsonValue.ArrayValue(tagIds.map { JsonValue.StringValue(it) })),
        )
    }

    /** Clones a task's editable fields into a fresh, open task and recurrence series. */
    suspend fun duplicate(id: String): TaskRecord? {
        val source = store.record(RegistryEntityNames.TASK, id)?.asTaskRecord() ?: return null
        if (source.deletedAt != null) return null

        val copy = create(
            title = source.title,
            area = source.fields[RegistryEntityFields.Task.AREA].stringValue(),
            project = source.fields[RegistryEntityFields.Task.PROJECT].stringValue(),
            scheduled = source.fields[RegistryEntityFields.Task.SCHEDULED].stringValue(),
            deadline = source.fields[RegistryEntityFields.Task.DEADLINE].stringValue(),
            today = source.fields[RegistryEntityFields.Task.TODAY].booleanValue() == true,
            notes = source.fields[RegistryEntityFields.Task.NOTES].stringValue(),
            heading = source.fields[RegistryEntityFields.Task.HEADING].stringValue(),
        )
        val extra = linkedMapOf<String, JsonValue>()
        source.fields[RegistryEntityFields.Task.STARRED]
            ?.let { extra[RegistryEntityFields.Task.STARRED] = it }
        source.fields[RegistryEntityFields.Task.TAGS]
            ?.let { extra[RegistryEntityFields.Task.TAGS] = it }
        for (field in listOf(
            RegistryEntityFields.Task.DEFERRED_DEADLINE,
            RegistryEntityFields.Task.START_TIME,
            RegistryEntityFields.Task.DURATION_MINUTES,
            RegistryEntityFields.Task.TIME_ZONE,
        )) {
            source.fields[field]?.let { extra[field] = it }
        }

        val recurrenceUnit = source.fields[RegistryEntityFields.Task.RECURRENCE_UNIT].stringValue()
        if (recurrenceUnit != null) {
            for (field in listOf(
                RegistryEntityFields.Task.RECURRENCE_UNIT,
                RegistryEntityFields.Task.RECURRENCE_INTERVAL,
                RegistryEntityFields.Task.RECURRENCE_AFTER_COMPLETION,
                RegistryEntityFields.Task.RECURRENCE_PAUSED,
                RegistryEntityFields.Task.RECURRENCE_ANCHOR_DATE,
                RegistryEntityFields.Task.RECURRENCE_WEEKDAYS,
                RegistryEntityFields.Task.RECURRENCE_MONTH_DAY,
                RegistryEntityFields.Task.RECURRENCE_ORDINAL_WEEKDAY,
            )) {
                source.fields[field]?.let { extra[field] = it }
            }
            extra[RegistryEntityFields.Task.RECURRENCE_SERIES_ID] = JsonValue.StringValue(copy.id)
        }
        return if (extra.isEmpty()) copy else updateFields(copy.id, extra) ?: copy
    }

    private suspend fun isChecklistItem(task: TaskRecord): Boolean {
        if (task.fields[RegistryEntityFields.Task.KIND].stringValue() == RegistryEntityEnums.TaskKind.HEADING) return false
        val project = task.fields[RegistryEntityFields.Task.PROJECT].stringValue() ?: return false
        val row = store.record(RegistryEntityNames.PROJECT, project) ?: return false
        return row.deletedAt == null && row.fields[RegistryEntityFields.Project.CHECKLIST_MODE].stringValue() != null
    }

    suspend fun toggleProjectChecklist(id: String): TaskRecord? {
        val task = store.record(RegistryEntityNames.TASK, id)?.asTaskRecord() ?: return null
        if (task.deletedAt != null || !isChecklistItem(task)) return null
        if (task.status != TaskStatus.OPEN && task.status != TaskStatus.CHECKLIST_CHECKED) return null
        return writeChecklistState(task)
    }

    private suspend fun writeChecklistState(task: TaskRecord): TaskRecord? {
        val updated = updateFields(task.id, ProjectChecklistRules.patch(task.status == TaskStatus.OPEN))
        if (updated != null) endDoIfClosed(updated)
        return updated
    }

    suspend fun complete(id: String): TaskRecord? {
        val existing = store.record(RegistryEntityNames.TASK, id)?.asTaskRecord() ?: return null
        if (existing.deletedAt != null || existing.status != TaskStatus.OPEN) return null
        if (isChecklistItem(existing)) return writeChecklistState(existing)
        val changes = linkedMapOf(
            RegistryEntityFields.Task.STATUS to JsonValue.StringValue(app.septena.core.generated.RegistryEntityEnums.TaskStatus.DONE),
            RegistryEntityFields.Task.COMPLETED_AT to JsonValue.StringValue(WireTimestamp.format(clock.now())),
        )
        RegistryValidator.requireValidUpsert(RegistryEntityNames.TASK, id, changes, insert = false)
        val updated = existing.changing(changes)
        val operation = SyncOperation.Upsert(ids.nextClientOpId(), RegistryEntityNames.TASK, id, changes)
        store.writeLocalAndEnqueue(updated.asSyncRecord(), operation)
        endDoIfClosed(updated)
        spawnNextOccurrence(existing)
        return updated
    }

    /** Reopens a completed or cancelled task (e.g. unchecking during the completion settle window). */
    suspend fun reopen(id: String): TaskRecord? {
        val existing = store.record(RegistryEntityNames.TASK, id)?.asTaskRecord() ?: return null
        if (existing.deletedAt != null || existing.status == TaskStatus.OPEN) return null
        return updateFields(
            id,
            linkedMapOf(
                RegistryEntityFields.Task.STATUS to JsonValue.StringValue(app.septena.core.generated.RegistryEntityEnums.TaskStatus.OPEN),
                RegistryEntityFields.Task.COMPLETED_AT to JsonValue.Null,
                RegistryEntityFields.Task.DROP_REASON to JsonValue.Null,
            ),
        )
    }

    /**
     * A completed repeating task creates its next row (spec A10, W12), as the
     * apps and the backend do. The core computes the next day, the row id and
     * its date fields, so a completion here and one on the phone or by an
     * agent converge on the same row. An existing row with that id is kept.
     */
    private suspend fun spawnNextOccurrence(source: TaskRecord, calendarDay: String? = null, series: String? = null) {
        val f = source.fields
        if (f[RegistryEntityFields.Task.RECURRENCE_PAUSED].booleanValue() == true) return
        val rule = RecurrenceRules.fromFields(f) ?: return
        if (calendarDay == null && !rule.afterCompletion && RecurrenceRules.followsCalendar(rule.missed)) return
        val now = clock.now()
        val today = clock.today(now).toString()
        val next = calendarDay ?: RecurrenceRules.nextScheduledDate(
            completedOn = today,
            scheduled = f[RegistryEntityFields.Task.SCHEDULED].stringValue(),
            logicalScheduled = f[RegistryEntityFields.Task.RECURRENCE_ANCHOR_DATE].stringValue(),
            rule = rule,
        ) ?: return
        val nextId = RecurrenceRules.occurrenceId(series ?: source.id, next)
        if (store.record(RegistryEntityNames.TASK, nextId) != null) return

        val fields = linkedMapOf<String, JsonValue>(
            RegistryEntityFields.Task.STATUS to JsonValue.StringValue(app.septena.core.generated.RegistryEntityEnums.TaskStatus.OPEN),
            RegistryEntityFields.Task.CREATED to JsonValue.StringValue(today),
            RegistryEntityFields.Task.CREATED_AT to JsonValue.StringValue(WireTimestamp.format(now)),
            RegistryEntityFields.Task.RECURRENCE_SERIES_ID to JsonValue.StringValue(
                f[RegistryEntityFields.Task.RECURRENCE_SERIES_ID].stringValue() ?: source.id,
            ),
            RegistryEntityFields.Task.RECURRENCE_PAUSED to JsonValue.BooleanValue(false),
        )
        for (name in listOf(
            RegistryEntityFields.Task.TITLE, RegistryEntityFields.Task.KIND, RegistryEntityFields.Task.HEADING,
            RegistryEntityFields.Task.AREA, RegistryEntityFields.Task.PROJECT, RegistryEntityFields.Task.NOTES,
            RegistryEntityFields.Task.STARRED, RegistryEntityFields.Task.TAGS, RegistryEntityFields.Task.POSITION,
            RegistryEntityFields.Task.SOURCE, RegistryEntityFields.Task.SOURCE_CLIENT,
            RegistryEntityFields.Task.RECURRENCE_UNIT, RegistryEntityFields.Task.RECURRENCE_INTERVAL,
            RegistryEntityFields.Task.RECURRENCE_AFTER_COMPLETION, RegistryEntityFields.Task.RECURRENCE_WEEKDAYS,
            RegistryEntityFields.Task.RECURRENCE_MONTH_DAY, RegistryEntityFields.Task.RECURRENCE_ORDINAL_WEEKDAY,
            RegistryEntityFields.Task.RECURRENCE_MISSED, RegistryEntityFields.Task.RECURRENCE_MISSED_FROM,
        )) {
            val value = f[name]
            if (value != null && value != JsonValue.Null) fields[name] = value
        }
        val dates = coreNextOccurrenceDates(source.toCoreSnapshot(), next, WireTimestamp.format(now))
        fields[RegistryEntityFields.Task.SCHEDULED] = JsonValue.stringOrNull(dates.scheduled)
        fields[RegistryEntityFields.Task.TODAY] = JsonValue.BooleanValue(dates.today)
        dates.startTime?.let { fields[RegistryEntityFields.Task.START_TIME] = JsonValue.StringValue(it) }
        dates.durationMinutes?.let { fields[RegistryEntityFields.Task.DURATION_MINUTES] = JsonValue.IntegerValue(it.toLong()) }
        dates.timeZone?.let { fields[RegistryEntityFields.Task.TIME_ZONE] = JsonValue.StringValue(it) }
        dates.reminderAt?.let {
            fields[RegistryEntityFields.Task.REMINDER_AT] = JsonValue.StringValue(it)
            fields[RegistryEntityFields.Task.REMINDER_MODE] =
                JsonValue.StringValue(f[RegistryEntityFields.Task.REMINDER_MODE].stringValue() ?: "floating")
        }
        dates.recurrenceAnchorDate?.let { fields[RegistryEntityFields.Task.RECURRENCE_ANCHOR_DATE] = JsonValue.StringValue(it) }
        dates.acknowledgedAt?.let { fields[RegistryEntityFields.Task.ACKNOWLEDGED_AT] = JsonValue.StringValue(it) }
        RegistryValidator.requireValidUpsert(RegistryEntityNames.TASK, nextId, fields, insert = true)
        val task = TaskRecord(nextId, fields)
        store.writeLocalAndEnqueue(task.asSyncRecord(), task.toUpsert(ids.nextClientOpId()))

        // The open checklist comes along, unchecked, with ids every device derives alike.
        val items = store.records(RegistryEntityNames.CHECKLIST_ITEM)
            .filter { it.deletedAt == null && it.fields[RegistryEntityFields.ChecklistItem.TASK_ID].stringValue() == source.id }
            .sortedBy { item ->
                val position = item.fields[RegistryEntityFields.ChecklistItem.POSITION]
                (position as? JsonValue.DecimalValue)?.value ?: position.longValue()?.toDouble() ?: 0.0
            }
        items.forEachIndexed { index, item ->
            val itemId = RecurrenceRules.checklistOccurrenceId(nextId, index, item.id)
            val itemFields = linkedMapOf<String, JsonValue>(
                RegistryEntityFields.ChecklistItem.TASK_ID to JsonValue.StringValue(nextId),
                RegistryEntityFields.ChecklistItem.TITLE to (item.fields[RegistryEntityFields.ChecklistItem.TITLE] ?: JsonValue.StringValue("")),
                RegistryEntityFields.ChecklistItem.CHECKED to JsonValue.BooleanValue(false),
                RegistryEntityFields.ChecklistItem.CREATED_AT to JsonValue.StringValue(WireTimestamp.format(now)),
            )
            item.fields[RegistryEntityFields.ChecklistItem.POSITION]?.let { itemFields[RegistryEntityFields.ChecklistItem.POSITION] = it }
            RegistryValidator.requireValidUpsert(RegistryEntityNames.CHECKLIST_ITEM, itemId, itemFields, insert = true)
            store.writeLocalAndEnqueue(
                SyncRecord(RegistryEntityNames.CHECKLIST_ITEM, itemId, itemFields),
                SyncOperation.Upsert(ids.nextClientOpId(), RegistryEntityNames.CHECKLIST_ITEM, itemId, itemFields),
            )
        }
    }

    suspend fun reconcileRepeatWindows(): Boolean {
        val records = store.records(RegistryEntityNames.TASK).filter {
            it.deletedAt == null && it.fields[RegistryEntityFields.Task.RECURRENCE_MISSED].stringValue() != null
        }
        val groups = records.groupBy { it.fields[RegistryEntityFields.Task.RECURRENCE_SERIES_ID].stringValue() ?: it.id }
        fun slot(row: SyncRecord): String =
            row.fields[RegistryEntityFields.Task.RECURRENCE_ANCHOR_DATE].stringValue()
                ?: row.fields[RegistryEntityFields.Task.SCHEDULED].stringValue().orEmpty()
        var changed = false
        for ((id, members) in groups) {
            val head = members.maxWithOrNull(compareBy<SyncRecord>({ slot(it) }, { it.id }))?.asTaskRecord() ?: continue
            val rule = RecurrenceRules.fromFields(head.fields) ?: continue
            if (head.status == TaskStatus.CANCELLED || isChecklistItem(head) || rule.afterCompletion ||
                head.fields[RegistryEntityFields.Task.RECURRENCE_PAUSED].booleanValue() == true ||
                !RecurrenceRules.followsCalendar(rule.missed)) continue
            val plan = RecurrenceRules.window(rule, head.fields, clock.now()) ?: continue
            val starts = head.fields[RegistryEntityFields.Task.RECURRENCE_MISSED_FROM].stringValue().orEmpty()
            for (due in plan.create) {
                if (due >= starts && store.record(RegistryEntityNames.TASK, RecurrenceRules.occurrenceId(id, due)) == null) {
                    spawnNextOccurrence(head, calendarDay = due, series = id)
                    changed = true
                }
            }
            val cutoff = plan.expireBefore ?: continue
            for (row in members) {
                val day = slot(row)
                if (row.asTaskRecord().status == TaskStatus.OPEN && day >= starts && day < cutoff) {
                    updateFields(row.id, mapOf(RegistryEntityFields.Task.STATUS to JsonValue.StringValue(TaskStatus.REPEAT_EXPIRED.wireValue)))
                    changed = true
                }
            }
        }
        return changed
    }

    /** Clear the agent cue: the user engaged with an agent's row. No-op for other rows. */
    suspend fun acknowledge(id: String): TaskRecord? {
        val existing = store.record(RegistryEntityNames.TASK, id)?.asTaskRecord() ?: return null
        val f = existing.fields
        if (f[RegistryEntityFields.Task.SOURCE].stringValue() != app.septena.core.generated.RegistryEntityEnums.TaskSource.MCP ||
            f[RegistryEntityFields.Task.ACKNOWLEDGED_AT].stringValue() != null
        ) return existing
        return updateFields(id, mapOf(RegistryEntityFields.Task.ACKNOWLEDGED_AT to JsonValue.StringValue(WireTimestamp.format(clock.now()))))
    }

    /** Review ▸ Accept (as iOS): complete the task and clear the agent cue. */
    suspend fun acceptReview(id: String): TaskRecord? {
        val done = complete(id) ?: return null
        acknowledge(id)
        return done
    }

    /**
     * Faded ▸ Keep (docs/TASK_FADE_SPEC.md §4, as iOS TasksBackend.touch):
     * the user touched the task, so its fade clock restarts and it returns
     * to its list. Keeping an agent's proposal accepts it (ADR 0039).
     */
    suspend fun keepFaded(id: String): TaskRecord? {
        touch(id) ?: return null
        return acknowledge(id)
    }

    /**
     * Waiting On… and Got It Back (docs/REVIEW_SPEC.md §6, ADR 0053). A name starts or renames the
     * wait: the name is trimmed, and `waitingSince` becomes today when the task had no wait. A null
     * or blank name ends the wait and clears both fields. With [changesWhen], [scheduled] is the day to
     * chase and becomes the When date in the same gesture through the date action: a day schedules
     * the task, null clears When. Without it, When stays as it is (Got It Back, an agent's rename). Only the gesture layer calls
     * this, so the caller records the undo step and stamps the fade clock (a wait ends a fade).
     */
    suspend fun setWaiting(id: String, on: String?, scheduled: String? = null, changesWhen: Boolean = false): TaskRecord? {
        val existing = store.record(RegistryEntityNames.TASK, id)?.asTaskRecord() ?: return null
        if (existing.deletedAt != null) return null
        val name = on?.trim { it.isWhitespace() }?.takeIf(String::isNotEmpty)
        val hadWait = !existing.fields[RegistryEntityFields.Task.WAITING_ON].stringValue().isNullOrBlank()
        val changes = linkedMapOf<String, JsonValue>(
            RegistryEntityFields.Task.WAITING_ON to JsonValue.stringOrNull(name),
        )
        when {
            name == null -> changes[RegistryEntityFields.Task.WAITING_SINCE] = JsonValue.Null
            !hadWait -> changes[RegistryEntityFields.Task.WAITING_SINCE] =
                JsonValue.StringValue(clock.today(clock.now()).toString())
        }
        if (name != null) changes[RegistryEntityFields.Task.FADED_AT] = JsonValue.Null
        val updated = updateFields(id, changes) ?: return null
        if (name == null || !changesWhen) return updated
        return setWhen(id, scheduled)
    }

    /**
     * Faded ▸ Let Go (spec §5, as iOS dropFaded): cancel it with dropReason "faded"; it goes to the Logbook.
     * A task that came back since the row was drawn is left as is.
     */
    suspend fun letGoFaded(id: String): TaskRecord? {
        val existing = store.record(RegistryEntityNames.TASK, id)?.asTaskRecord() ?: return null
        if (existing.deletedAt != null || existing.status != TaskStatus.OPEN) return null
        if (!TaskFadeRules.isFaded(existing.fields[RegistryEntityFields.Task.FADED_AT].stringValue())) return existing
        return updateFields(
            id,
            linkedMapOf(
                RegistryEntityFields.Task.STATUS to JsonValue.StringValue(app.septena.core.generated.RegistryEntityEnums.TaskStatus.CANCELLED),
                RegistryEntityFields.Task.DROP_REASON to JsonValue.StringValue("faded"),
                RegistryEntityFields.Task.COMPLETED_AT to JsonValue.StringValue(WireTimestamp.format(clock.now())),
            ),
        )
    }

    /**
     * The daily fade pass (docs/TASK_FADE_SPEC.md §4), as iOS
     * TasksBackend.runFadePass: stamps fadedAt on every open task the core's
     * shouldFade says has gone untouched for the fade window. Never touches
     * touchedAt. [conversations] maps a task id to its conversation, so agent
     * work and waiting threads stay. Returns how many tasks faded.
     */
    suspend fun runFadePass(conversations: Map<String, TaskConversation>): Int {
        val now = clock.now()
        val today = clock.today(now).toString()
        val shares = ProjectShare.byProject(store)
        var faded = 0
        for (record in store.records(RegistryEntityNames.TASK)) {
            if (record.deletedAt != null) continue
            val task = runCatching { TaskSnapshot.from(record, shares) }.getOrNull() ?: continue
            if (task.status != app.septena.core.generated.RegistryEntityEnums.TaskStatus.OPEN || task.fadedAt != null) continue
            // A waiting task never fades (docs/REVIEW_SPEC.md §6).
            if (task.isWaiting) continue
            val convo = conversations[task.id]
            val fades = runCatching {
                TaskFadeRules.shouldFade(
                    isOpen = true,
                    isHeading = task.isHeading,
                    isDeleted = false,
                    isFaded = false,
                    deadline = task.deadline,
                    scheduled = task.scheduled,
                    hasRecurrence = task.recurrenceUnit != null,
                    isAgentTurn = convo?.isAgentTurn(now) == true,
                    isAssignedToClaude = convo?.assignee == app.septena.core.generated.RegistryEntityEnums.ConvoAssignee.CLAUDE,
                    touchedAt = task.touchedAt?.let { runCatching { java.time.Instant.parse(it) }.getOrNull() },
                    createdAt = task.createdAt?.let { runCatching { java.time.Instant.parse(it) }.getOrNull() },
                    created = task.created,
                    now = now,
                    today = today,
                    isAwaitingHuman = convo?.awaitsHuman == true,
                    isProposal = TaskProvenance.isProposal(task.source, task.acknowledgedAt),
                )
            }.getOrDefault(false)
            if (!fades) continue
            updateFields(task.id, mapOf(RegistryEntityFields.Task.FADED_AT to JsonValue.StringValue(WireTimestamp.format(now))))
            faded++
        }
        return faded
    }

    suspend fun cancel(id: String): TaskRecord? = updateFields(
        id,
        linkedMapOf(
            RegistryEntityFields.Task.STATUS to JsonValue.StringValue(app.septena.core.generated.RegistryEntityEnums.TaskStatus.CANCELLED),
            RegistryEntityFields.Task.COMPLETED_AT to JsonValue.StringValue(WireTimestamp.format(clock.now())),
        ),
    )

    suspend fun delete(id: String): TaskRecord? {
        val existing = store.record(RegistryEntityNames.TASK, id)?.asTaskRecord() ?: return null
        if (existing.deletedAt != null) return null
        val now = clock.now()
        val deletedAt = WireTimestamp.format(now)
        val updated = existing.copy(deletedAt = deletedAt)
        val operation = SyncOperation.Delete(ids.nextClientOpId(), RegistryEntityNames.TASK, id)
        val grace = Duration.ofSeconds(app.septena.core.generated.RegistryRules.DELETE_GRACE_SECONDS)
        store.writeLocalAndEnqueue(updated.asSyncRecord(), operation, now.plus(grace))
        endDoIfClosed(updated)
        return updated
    }

    suspend fun restore(id: String): TaskRecord? {
        val existing = store.record(RegistryEntityNames.TASK, id)?.asTaskRecord() ?: return null
        if (existing.deletedAt == null) return null
        val restored = existing.copy(deletedAt = null)
        RegistryValidator.requireValidUpsert(RegistryEntityNames.TASK, id, restored.fields, insert = false)
        store.writeLocalAndEnqueue(restored.asSyncRecord(), restored.toUpsert(ids.nextClientOpId()))
        return restored
    }

    /** Permanently removes a soft-deleted task (Delete Permanently / Empty Trash, #460). */
    suspend fun purge(id: String): Boolean {
        store.record(RegistryEntityNames.TASK, id) ?: return false
        deferredDrafts.remove(id)
        val operation = SyncOperation.Delete(ids.nextClientOpId(), RegistryEntityNames.TASK, id)
        doSessions?.purge(id)
        store.purgeLocalAndEnqueue(RegistryEntityNames.TASK, id, operation)
        return true
    }

    private fun validateTitle(title: String) {
        val maximum = RegistryEntityLimits.TEXT_MAX
        require(title.length.toLong() <= maximum) { "Task title exceeds the registry limit of $maximum characters" }
    }

    companion object {
        /** The not-before time of a draft's queued insert: never, until a title write releases it. */
        val DEFERRED_PUSH: Instant = Instant.ofEpochMilli(Long.MAX_VALUE)

        /** True when [fields] describe a fixed-schedule (not after-completion) repeating task. */
        fun isFixedRepeating(fields: Map<String, JsonValue>): Boolean =
            fields[RegistryEntityFields.Task.RECURRENCE_UNIT].stringValue() != null &&
                fields[RegistryEntityFields.Task.RECURRENCE_AFTER_COMPLETION].booleanValue() != true

        /**
         * True when scheduling [fields] to [targetDay] triggers the fixed-repeat
         * "Only This Task / Update Schedule" prompt (TASK_DATES_SPEC §4, #573).
         */
        fun needsFixedRepeatReschedulePrompt(fields: Map<String, JsonValue>, targetDay: String?): Boolean =
            targetDay != null &&
                isFixedRepeating(fields) &&
                targetDay != fields[RegistryEntityFields.Task.SCHEDULED].stringValue()
    }
}

/** The task as the shared core reads it, every date field included. */
internal fun TaskRecord.toCoreSnapshot(
    shares: Map<String, ProjectShare> = emptyMap(),
): CoreTaskSnapshot {
    val base = TaskSnapshot.from(asSyncRecord(), shares).toCore()
    val f = fields
    return base.copy(
        startTime = f[RegistryEntityFields.Task.START_TIME].stringValue(),
        durationMinutes = (f[RegistryEntityFields.Task.DURATION_MINUTES] as? JsonValue.IntegerValue)?.value?.toInt(),
        timeZone = f[RegistryEntityFields.Task.TIME_ZONE].stringValue(),
        reminderAt = f[RegistryEntityFields.Task.REMINDER_AT].stringValue(),
        reminderSnoozedUntil = f[RegistryEntityFields.Task.REMINDER_SNOOZED_UNTIL].stringValue(),
        reminderDismissedAt = f[RegistryEntityFields.Task.REMINDER_DISMISSED_AT].stringValue(),
        recurrenceAfterCompletion = f[RegistryEntityFields.Task.RECURRENCE_AFTER_COMPLETION].booleanValue(),
        recurrenceAnchorDate = f[RegistryEntityFields.Task.RECURRENCE_ANCHOR_DATE].stringValue(),
    )
}
