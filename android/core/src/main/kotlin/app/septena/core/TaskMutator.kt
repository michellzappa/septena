package app.septena.core

import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityLimits
import app.septena.core.generated.RegistryEntityNames
import java.time.Duration

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

    suspend fun setToday(id: String, enabled: Boolean): TaskRecord? = updateFields(
        id,
        linkedMapOf(
            RegistryEntityFields.Task.TODAY to JsonValue.BooleanValue(enabled),
            RegistryEntityFields.Task.TODAY_SET_ON to if (enabled) JsonValue.StringValue(clock.today(clock.now()).toString()) else JsonValue.Null,
        ),
    )

    suspend fun setStarred(id: String, starred: Boolean): TaskRecord? = updateFields(
        id,
        mapOf(RegistryEntityFields.Task.STARRED to JsonValue.BooleanValue(starred)),
    )

    suspend fun schedule(id: String, day: String?): TaskRecord? {
        val existing = store.record(RegistryEntityNames.TASK, id)?.asTaskRecord() ?: return null
        if (existing.deletedAt != null) return null
        val oldDay = existing.fields[RegistryEntityFields.Task.SCHEDULED].stringValue()
        val oldReminder = existing.fields[RegistryEntityFields.Task.REMINDER_AT].stringValue()
        val shiftedReminder = TaskReminderRules.shiftOnReschedule(oldReminder, oldDay, day)
        val changes = linkedMapOf<String, JsonValue>(
            RegistryEntityFields.Task.SCHEDULED to JsonValue.stringOrNull(day),
        )
        if (shiftedReminder != oldReminder) {
            changes[RegistryEntityFields.Task.REMINDER_AT] = JsonValue.stringOrNull(shiftedReminder)
        }
        return updateFields(id, changes)
    }

    /** Sets the user-visible When value in one queued write, keeping Today and its date exclusive. */
    suspend fun setWhen(id: String, day: String?): TaskRecord? {
        val existing = store.record(RegistryEntityNames.TASK, id)?.asTaskRecord() ?: return null
        if (existing.deletedAt != null) return null
        val today = clock.today(clock.now()).toString()
        val isToday = day == today
        val scheduled = day?.takeUnless { isToday }
        val oldScheduled = existing.fields[RegistryEntityFields.Task.SCHEDULED].stringValue()
        val oldReminder = existing.fields[RegistryEntityFields.Task.REMINDER_AT].stringValue()
        val shiftedReminder = TaskReminderRules.shiftOnReschedule(oldReminder, oldScheduled, scheduled)
        val changes = linkedMapOf<String, JsonValue>(
            RegistryEntityFields.Task.SCHEDULED to JsonValue.stringOrNull(scheduled),
            RegistryEntityFields.Task.TODAY to JsonValue.BooleanValue(isToday),
            RegistryEntityFields.Task.TODAY_SET_ON to JsonValue.stringOrNull(if (isToday) today else null),
        )
        if (shiftedReminder != oldReminder) {
            changes[RegistryEntityFields.Task.REMINDER_AT] = JsonValue.stringOrNull(shiftedReminder)
        }
        return updateFields(id, changes)
    }

    suspend fun setTimeSlot(id: String, startTime: String?, durationMinutes: Long?, timeZone: String?): TaskRecord? =
        updateFields(
            id,
            linkedMapOf(
                RegistryEntityFields.Task.START_TIME to JsonValue.stringOrNull(startTime),
                RegistryEntityFields.Task.DURATION_MINUTES to JsonValue.integerOrNull(durationMinutes),
                RegistryEntityFields.Task.TIME_ZONE to JsonValue.stringOrNull(timeZone),
            ),
        )

    suspend fun setDeadline(id: String, day: String?): TaskRecord? = updateFields(
        id,
        mapOf(RegistryEntityFields.Task.DEADLINE to JsonValue.stringOrNull(day)),
    )

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
        return updated
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

    private fun validateTitle(title: String) {
        val maximum = RegistryEntityLimits.TEXT_MAX
        require(title.length.toLong() <= maximum) { "Task title exceeds the registry limit of $maximum characters" }
    }
}
