package app.septena.core

import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityLimits
import app.septena.core.generated.RegistryEntityNames
import app.septena.sharedcore.DateAction
import app.septena.sharedcore.RescheduleMode
import java.time.Duration
import app.septena.sharedcore.TaskSnapshot as CoreTaskSnapshot
import app.septena.sharedcore.applyDateAction as coreApplyDateAction
import app.septena.sharedcore.nextOccurrenceDates as coreNextOccurrenceDates

/** User writes cross this boundary so optimistic rows and outbox operations stay atomic. */
class TaskMutator(
    private val store: TaskStore,
    private val clock: DayClock,
    private val ids: TaskIdGenerator,
) {
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
    )

    suspend fun createHeading(title: String, project: String, position: Double? = null): TaskRecord = createTask(
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
    ): TaskRecord {
        val id = ids.nextTaskId()
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
            kind = kind,
            heading = heading,
            position = position,
        )
        validateTitle(normalizedTitle)
        RegistryValidator.requireValidUpsert(RegistryEntityNames.TASK, id, fields, insert = true)

        val task = TaskRecord(id, fields)
        store.writeLocalAndEnqueue(task.asSyncRecord(), task.toUpsert(ids.nextClientOpId()))
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
        store.writeLocalAndEnqueue(updated.asSyncRecord(), operation)
        return updated
    }

    /** Applies a registry validated task patch for actions whose semantics are owned by the caller. */
    suspend fun updateFields(id: String, changes: Map<String, JsonValue>): TaskRecord? {
        require(changes.isNotEmpty()) { "A task update must contain at least one field" }
        RegistryValidator.requireValidUpsert(RegistryEntityNames.TASK, id, changes, insert = false)
        val existing = store.record(RegistryEntityNames.TASK, id)?.asTaskRecord() ?: return null
        if (existing.deletedAt != null) return null
        val updated = existing.changing(changes)
        store.writeLocalAndEnqueue(
            updated.asSyncRecord(),
            SyncOperation.Upsert(ids.nextClientOpId(), RegistryEntityNames.TASK, id, changes),
        )
        return updated
    }

    /** A user gesture on the task: stamps the fade clock (docs/TASK_FADE_SPEC.md §3, Swift `touch`). */
    suspend fun touch(id: String): TaskRecord? = updateFields(
        id,
        mapOf(
            RegistryEntityFields.Task.TOUCHED_AT to JsonValue.StringValue(WireTimestamp.format(clock.now())),
            RegistryEntityFields.Task.DEFER_COUNT to JsonValue.IntegerValue(0),
            RegistryEntityFields.Task.FADED_AT to JsonValue.Null,
        ),
    )

    /** A1 when [enabled], else A3 (Remove from Today): the core decides the fields. */
    suspend fun setToday(id: String, enabled: Boolean): TaskRecord? =
        applyDateAction(id, if (enabled) DateAction.PutOnToday(RescheduleMode.MAKE_EXCEPTION) else DateAction.RemoveFromToday)

    suspend fun setStarred(id: String, starred: Boolean): TaskRecord? = updateFields(
        id,
        mapOf(RegistryEntityFields.Task.STARRED to JsonValue.BooleanValue(starred)),
    )

    /** A2 for a day (a day on or before today is A1), A5 for none. */
    suspend fun schedule(id: String, day: String?): TaskRecord? = setWhen(id, day)

    /** The user-visible When value: A2 for a day (today or earlier is A1), A5 for none. */
    suspend fun setWhen(id: String, day: String?): TaskRecord? = applyDateAction(
        id,
        if (day == null) DateAction.ClearWhenDate else DateAction.ScheduleFor(day, RescheduleMode.MAKE_EXCEPTION),
    )

    /** A9: set or clear the time slot. A time with no day pins the task to Today. */
    suspend fun setTimeSlot(id: String, startTime: String?, durationMinutes: Long?, timeZone: String?): TaskRecord? =
        applyDateAction(id, DateAction.SetTimeSlot(startTime, durationMinutes?.toInt(), timeZone))

    /** A7 / A8: set or clear the deadline. */
    suspend fun setDeadline(id: String, day: String?): TaskRecord? = applyDateAction(id, DateAction.SetDeadline(day))

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
        val patch = coreApplyDateAction(
            existing.toCoreSnapshot(),
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
        return updateFields(id, changes)
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

    suspend fun complete(id: String): TaskRecord? {
        val existing = store.record(RegistryEntityNames.TASK, id)?.asTaskRecord() ?: return null
        if (existing.deletedAt != null || existing.status != TaskStatus.OPEN) return null
        val changes = linkedMapOf(
            RegistryEntityFields.Task.STATUS to JsonValue.StringValue(app.septena.core.generated.RegistryEntityEnums.TaskStatus.DONE),
            RegistryEntityFields.Task.COMPLETED_AT to JsonValue.StringValue(WireTimestamp.format(clock.now())),
        )
        RegistryValidator.requireValidUpsert(RegistryEntityNames.TASK, id, changes, insert = false)
        val updated = existing.changing(changes)
        val operation = SyncOperation.Upsert(ids.nextClientOpId(), RegistryEntityNames.TASK, id, changes)
        store.writeLocalAndEnqueue(updated.asSyncRecord(), operation)
        spawnNextOccurrence(existing)
        return updated
    }

    /**
     * A completed repeating task creates its next row (spec A10, W12), as the
     * apps and the backend do. The core computes the next day, the row id and
     * its date fields, so a completion here and one on the phone or by an
     * agent converge on the same row. An existing row with that id is kept.
     */
    private suspend fun spawnNextOccurrence(source: TaskRecord) {
        val f = source.fields
        val unit = f[RegistryEntityFields.Task.RECURRENCE_UNIT].stringValue() ?: return
        if (f[RegistryEntityFields.Task.RECURRENCE_PAUSED].booleanValue() == true) return
        val ordinal = f[RegistryEntityFields.Task.RECURRENCE_ORDINAL_WEEKDAY] as? JsonValue.ObjectValue
        val rule = RecurrenceRule(
            unit = unit,
            interval = f[RegistryEntityFields.Task.RECURRENCE_INTERVAL].longValue()?.toInt() ?: 1,
            afterCompletion = f[RegistryEntityFields.Task.RECURRENCE_AFTER_COMPLETION].booleanValue() ?: true,
            weekdays = (f[RegistryEntityFields.Task.RECURRENCE_WEEKDAYS] as? JsonValue.ArrayValue)
                ?.values?.mapNotNull { it.longValue()?.toInt() },
            monthDay = f[RegistryEntityFields.Task.RECURRENCE_MONTH_DAY].longValue()?.toInt(),
            ordinalWeekday = ordinal?.let {
                val o = it["ordinal"].longValue()?.toInt()
                val w = it["weekday"].longValue()?.toInt()
                if (o != null && w != null) OrdinalWeekday(o, w) else null
            },
        )
        val now = clock.now()
        val today = clock.today(now).toString()
        val next = RecurrenceRules.nextScheduledDate(
            completedOn = today,
            scheduled = f[RegistryEntityFields.Task.SCHEDULED].stringValue(),
            logicalScheduled = f[RegistryEntityFields.Task.RECURRENCE_ANCHOR_DATE].stringValue(),
            rule = rule,
        ) ?: return
        val nextId = RecurrenceRules.occurrenceId(source.id, next)
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

    /** Clear the agent cue: the user engaged with an agent's row. No-op for other rows. */
    suspend fun acknowledge(id: String): TaskRecord? {
        val existing = store.record(RegistryEntityNames.TASK, id)?.asTaskRecord() ?: return null
        val f = existing.fields
        if (f[RegistryEntityFields.Task.SOURCE].stringValue() != app.septena.core.generated.RegistryEntityEnums.TaskSource.MCP ||
            f[RegistryEntityFields.Task.ACKNOWLEDGED_AT].stringValue() != null
        ) return existing
        return updateFields(id, mapOf(RegistryEntityFields.Task.ACKNOWLEDGED_AT to JsonValue.StringValue(WireTimestamp.format(clock.now()))))
    }

    /** Review ▸ Accept (as iOS): complete the task, clear the agent cue, and stamp the fade clock. */
    suspend fun acceptReview(id: String): TaskRecord? {
        val done = complete(id) ?: return null
        acknowledge(id)
        touch(id)
        return done
    }

    /**
     * Faded ▸ Keep (docs/TASK_FADE_SPEC.md §4, as iOS TasksBackend.touch):
     * the user touched the task, so its fade clock restarts and it returns
     * to its list.
     */
    suspend fun keepFaded(id: String): TaskRecord? = touch(id)

    /** Faded ▸ Let Go (spec §5, as iOS dropFaded): cancel it with dropReason "faded"; it goes to the Logbook. */
    suspend fun letGoFaded(id: String): TaskRecord? {
        val existing = store.record(RegistryEntityNames.TASK, id)?.asTaskRecord() ?: return null
        if (existing.deletedAt != null || existing.status != TaskStatus.OPEN) return null
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
        var faded = 0
        for (record in store.records(RegistryEntityNames.TASK)) {
            if (record.deletedAt != null) continue
            val task = runCatching { TaskSnapshot.from(record) }.getOrNull() ?: continue
            if (task.status != app.septena.core.generated.RegistryEntityEnums.TaskStatus.OPEN || task.fadedAt != null) continue
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
        val operation = SyncOperation.Delete(ids.nextClientOpId(), RegistryEntityNames.TASK, id)
        store.purgeLocalAndEnqueue(RegistryEntityNames.TASK, id, operation)
        return true
    }

    private fun validateTitle(title: String) {
        val maximum = RegistryEntityLimits.TEXT_MAX
        require(title.length.toLong() <= maximum) { "Task title exceeds the registry limit of $maximum characters" }
    }
}

/** The task as the shared core reads it, every date field included. */
internal fun TaskRecord.toCoreSnapshot(): CoreTaskSnapshot {
    val base = TaskSnapshot.from(asSyncRecord()).toCore()
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
