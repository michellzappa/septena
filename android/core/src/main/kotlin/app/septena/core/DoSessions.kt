package app.septena.core

import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityLimits
import app.septena.core.generated.RegistryEntityNames
import app.septena.sharedcore.invokeJson
import java.time.Duration
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

// Do: one task now (docs/DO_SPEC.md, ADR 0041). The rules live in the shared
// core (`do_session.rs`). This file holds the rows, the one seam to the core
// and the gestures that write rows.

/** Stamps stay the text that syncs, so a pull and a push of the same instant compare equal. */
object DoStamp {
    private val formatter = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC)

    fun text(value: Instant): String = formatter.format(value)

    fun instant(text: String): Instant? = runCatching { OffsetDateTime.parse(text).toInstant() }.getOrNull()
}

/** One `doSession` row, as a value. */
data class DoSession(
    val id: String,
    val taskId: String,
    val startedAt: Instant,
    val plannedMinutes: Int?,
    val endedAt: Instant?,
    /** A `doExit` of the registry, null while open. */
    val exit: String?,
    val lapsed: Boolean,
    val note: String?,
) {
    /** Null while it is open, and when the length is unknown. */
    val length: Duration?
        get() = endedAt?.takeUnless { lapsed }?.let { Duration.between(startedAt, it).coerceAtLeast(Duration.ZERO) }

    companion object {
        fun from(record: SyncRecord): DoSession? {
            val f = record.fields
            return DoSession(
                id = record.id,
                taskId = f[RegistryEntityFields.DoSession.TASK_ID].stringValue() ?: return null,
                startedAt = f[RegistryEntityFields.DoSession.STARTED_AT].stringValue()?.let(DoStamp::instant) ?: return null,
                plannedMinutes = f[RegistryEntityFields.DoSession.PLANNED_MINUTES].longValue()?.toInt(),
                endedAt = f[RegistryEntityFields.DoSession.ENDED_AT].stringValue()?.let(DoStamp::instant),
                exit = f[RegistryEntityFields.DoSession.EXIT].stringValue(),
                lapsed = f[RegistryEntityFields.DoSession.LAPSED].isTrue(),
                note = f[RegistryEntityFields.DoSession.NOTE].stringValue()?.takeIf(String::isNotBlank),
            )
        }
    }
}

/** What the core says about the rows of this device. */
data class DoResolution(val ends: List<End>, val current: Current?) {
    data class End(val id: String, val endedAt: String, val exit: String, val lapsed: Boolean)

    data class Current(
        val id: String,
        val startedAt: Instant,
        val plannedEnd: Instant?,
        val staleAt: Instant,
        val isStale: Boolean,
    )
}

/**
 * The one seam to the core's Do rules. They are JSON only: typed bindings do
 * not fit the core's size budget.
 */
object DoRules {
    /** Null when the linked core has no Do rules or refuses the rows: the caller then changes nothing. */
    fun resolve(rows: List<JsonValue.ObjectValue>, now: Instant): DoResolution? = runCatching {
        val input = JsonValue.ObjectValue(
            linkedMapOf(
                "sessions" to JsonValue.ArrayValue(rows),
                "now" to JsonValue.StringValue(DoStamp.text(now)),
            ),
        )
        val out = JsonValue.parse(invokeJson(RESOLVE, input.canonicalJson())) as JsonValue.ObjectValue
        if (out.fields.containsKey("error")) return@runCatching null
        DoResolution(
            ends = (out.fields["ends"] as? JsonValue.ArrayValue)?.values.orEmpty().map { raw ->
                val end = (raw as JsonValue.ObjectValue).fields
                DoResolution.End(
                    id = requireNotNull(end["id"].stringValue()),
                    endedAt = requireNotNull(end["endedAt"].stringValue()),
                    exit = requireNotNull(end["exit"].stringValue()),
                    lapsed = end["lapsed"].booleanValue() == true,
                )
            },
            current = (out.fields["current"] as? JsonValue.ObjectValue)?.fields?.let { current ->
                DoResolution.Current(
                    id = requireNotNull(current["id"].stringValue()),
                    startedAt = Instant.ofEpochMilli(requireNotNull(current["startedMs"].longValue())),
                    plannedEnd = current["plannedEndMs"].longValue()?.let(Instant::ofEpochMilli),
                    staleAt = Instant.ofEpochMilli(requireNotNull(current["staleAtMs"].longValue())),
                    isStale = current["isStale"].booleanValue() == true,
                )
            },
        )
    }.getOrNull()

    private const val RESOLVE = "resolveDoSessions"
}

/**
 * Every gesture on a Do, and the reads they need. A client ends rows for its
 * own gestures only. The store leaves no other end to a client: in the middle
 * of a pull a client may not have the task yet (docs/DO_SPEC.md §2.1).
 */
class DoSessionMutator(
    private val store: TaskStore,
    private val clock: DayClock,
    private val ids: TaskIdGenerator,
) {
    /** The core's answer over the rows of this device. Never writes. */
    suspend fun resolve(): DoResolution? = resolve(openAndLater(records()))

    /** A task's Do history, newest first. */
    suspend fun history(taskId: String): List<DoSession> =
        records().mapNotNull(DoSession::from).filter { it.taskId == taskId }.sortedByDescending { it.startedAt }

    suspend fun session(id: String): DoSession? = row(id)?.let(DoSession::from)

    /**
     * Starts a Do of an open task and returns its id. A Do that was open ends.
     * Returns null, and writes nothing, when the task cannot be done or the
     * linked core has no Do rules.
     */
    suspend fun begin(taskId: String, tasks: TaskMutator, plannedMinutes: Int? = null): String? {
        val task = store.record(RegistryEntityNames.TASK, taskId) ?: return null
        if (task.deletedAt != null ||
            task.fields[RegistryEntityFields.Task.KIND].stringValue() == RegistryEntityEnums.TaskKind.HEADING ||
            task.fields[RegistryEntityFields.Task.STATUS].stringValue() != RegistryEntityEnums.TaskStatus.OPEN
        ) return null
        val fields = linkedMapOf<String, JsonValue>(
            RegistryEntityFields.DoSession.TASK_ID to JsonValue.StringValue(taskId),
            RegistryEntityFields.DoSession.STARTED_AT to JsonValue.StringValue(DoStamp.text(clock.now())),
            RegistryEntityFields.DoSession.LAPSED to JsonValue.BooleanValue(false),
            RegistryEntityFields.DoSession.SOURCE_CLIENT to JsonValue.StringValue(SOURCE_CLIENT),
        )
        plannedMinutes?.let { fields[RegistryEntityFields.DoSession.PLANNED_MINUTES] = JsonValue.IntegerValue(clamped(it)) }
        val record = SyncRecord(RegistryEntityNames.DO_SESSION, "do-" + java.util.UUID.randomUUID(), fields)
        RegistryValidator.requireValidUpsert(record.entity, record.id, fields, insert = true)
        // The start is engagement: it resets the fade and keeps a faded task,
        // so the rules see the task as it is after the touch.
        if (DoRules.resolve(emptyList(), clock.now()) == null || tasks.touch(taskId) == null) return null
        val resolution = resolve(openAndLater(records() + record)) ?: return null
        store.writeLocalAndEnqueue(
            record,
            SyncOperation.Upsert(ids.nextClientOpId(), record.entity, record.id, fields),
        )
        resolution.ends.filter { it.id != record.id }.forEach { end(it) }
        return record.id
    }

    /** Ends one open Do by its id, never "whatever is open". False when it had ended already. */
    suspend fun end(sessionId: String, exit: String): Boolean {
        val open = row(sessionId)?.takeIf(::isOpen) ?: return false
        val current = resolve()?.current
        return end(
            DoResolution.End(
                id = open.id,
                endedAt = DoStamp.text(clock.now()),
                exit = exit,
                lapsed = current?.id == open.id && current.isStale,
            ),
        )
    }

    /** The stale question's Still on It. */
    suspend fun confirm(sessionId: String): Boolean = updateOpen(
        sessionId,
        mapOf(RegistryEntityFields.DoSession.CONFIRMED_AT to JsonValue.StringValue(DoStamp.text(clock.now()))),
    )

    /** Null counts up. */
    suspend fun setLength(sessionId: String, minutes: Int?): Boolean = updateOpen(
        sessionId,
        mapOf(
            RegistryEntityFields.DoSession.PLANNED_MINUTES to
                JsonValue.integerOrNull(minutes?.let { clamped(it) }),
        ),
    )

    /** The answer to "Where did you stop?". An empty answer writes nothing. */
    suspend fun setNote(sessionId: String, note: String): Boolean {
        val text = note.trim().take(RegistryEntityLimits.DO_NOTE_MAX.toInt())
        if (text.isEmpty()) return false
        return update(sessionId, mapOf(RegistryEntityFields.DoSession.NOTE to JsonValue.StringValue(text)))
    }

    /**
     * A task mutator closed, deleted or faded this task: its open Do ends at
     * once (§2.1 rule 5). The store applies the same rule for every other
     * client. A sync apply never calls this.
     */
    suspend fun taskClosed(taskId: String) {
        val open = records().filter { isOpen(it) && taskIdOf(it) == taskId }.map { it.id }.toSet()
        if (open.isEmpty()) return
        resolve()?.ends.orEmpty().filter { it.id in open }.forEach { end(it) }
    }

    /** A purged task takes its Do history with it. */
    suspend fun purge(taskId: String) {
        for (record in records().filter { taskIdOf(it) == taskId }) {
            store.purgeLocalAndEnqueue(
                record.entity,
                record.id,
                SyncOperation.Delete(ids.nextClientOpId(), record.entity, record.id),
            )
        }
    }

    /**
     * Writes an imported row. An imported Do is history, so an open one ends
     * where it started. False when the row cannot come back.
     */
    suspend fun importEnded(id: String, fields: Map<String, JsonValue>): Boolean {
        if (store.record(RegistryEntityNames.DO_SESSION, id) != null) return false
        if (RegistryValidator.validateUpsert(RegistryEntityNames.DO_SESSION, id, fields, insert = true).isNotEmpty()) return false
        store.writeLocalAndEnqueue(
            SyncRecord(RegistryEntityNames.DO_SESSION, id, fields),
            SyncOperation.Upsert(ids.nextClientOpId(), RegistryEntityNames.DO_SESSION, id, fields),
        )
        return true
    }

    private suspend fun end(end: DoResolution.End): Boolean = updateOpen(
        end.id,
        linkedMapOf(
            RegistryEntityFields.DoSession.ENDED_AT to JsonValue.StringValue(end.endedAt),
            RegistryEntityFields.DoSession.EXIT to JsonValue.StringValue(end.exit),
            RegistryEntityFields.DoSession.LAPSED to JsonValue.BooleanValue(end.lapsed),
        ),
    )

    /** A closed row never opens again (§2.1 rule 4), and only its note changes. */
    private suspend fun updateOpen(sessionId: String, changes: Map<String, JsonValue>): Boolean =
        row(sessionId)?.takeIf(::isOpen) != null && update(sessionId, changes)

    private suspend fun update(sessionId: String, changes: Map<String, JsonValue>): Boolean {
        val existing = row(sessionId) ?: return false
        RegistryValidator.requireValidUpsert(existing.entity, existing.id, changes, insert = false)
        store.writeLocalAndEnqueue(
            existing.copy(fields = existing.fields + changes),
            SyncOperation.Upsert(ids.nextClientOpId(), existing.entity, existing.id, changes),
        )
        return true
    }

    private suspend fun records(): List<SyncRecord> =
        store.records(RegistryEntityNames.DO_SESSION).filter { it.deletedAt == null }

    private suspend fun row(id: String): SyncRecord? =
        store.record(RegistryEntityNames.DO_SESSION, id)?.takeIf { it.deletedAt == null }

    /** Every open row, and every row that started after the oldest open one. */
    private fun openAndLater(rows: List<SyncRecord>): List<SyncRecord> {
        val oldest = rows.filter(::isOpen).mapNotNull(::startOf).minOrNull() ?: return emptyList()
        return rows.filter { row -> startOf(row)?.let { it >= oldest } == true }
    }

    private suspend fun resolve(rows: List<SyncRecord>): DoResolution? = DoRules.resolve(
        rows.map { row ->
            val f = row.fields
            JsonValue.ObjectValue(
                linkedMapOf(
                    "id" to JsonValue.StringValue(row.id),
                    "startedAt" to (f[RegistryEntityFields.DoSession.STARTED_AT] ?: JsonValue.Null),
                    "plannedMinutes" to (f[RegistryEntityFields.DoSession.PLANNED_MINUTES] ?: JsonValue.Null),
                    "confirmedAt" to (f[RegistryEntityFields.DoSession.CONFIRMED_AT] ?: JsonValue.Null),
                    "endedAt" to (f[RegistryEntityFields.DoSession.ENDED_AT] ?: JsonValue.Null),
                    "taskStatus" to JsonValue.stringOrNull(taskStatus(taskIdOf(row))),
                ),
            )
        },
        clock.now(),
    )

    /**
     * A task that is not here may still be on its way in a pull: it counts as
     * open, and the store ends the Do when the task is really gone. Null means
     * deleted or faded.
     */
    private suspend fun taskStatus(id: String?): String? {
        val task = id?.let { store.record(RegistryEntityNames.TASK, it) } ?: return RegistryEntityEnums.TaskStatus.OPEN
        if (task.deletedAt != null || TaskFadeRules.isFaded(task.fields[RegistryEntityFields.Task.FADED_AT].stringValue())) return null
        return task.fields[RegistryEntityFields.Task.STATUS].stringValue()
    }

    private fun isOpen(record: SyncRecord): Boolean =
        record.fields[RegistryEntityFields.DoSession.ENDED_AT].stringValue() == null

    private fun taskIdOf(record: SyncRecord): String? =
        record.fields[RegistryEntityFields.DoSession.TASK_ID].stringValue()

    private fun startOf(record: SyncRecord): Instant? =
        record.fields[RegistryEntityFields.DoSession.STARTED_AT].stringValue()?.let(DoStamp::instant)

    private fun clamped(minutes: Int): Long = minutes.toLong().coerceIn(1L, RegistryEntityLimits.DO_PLANNED_MINUTES_MAX)

    private companion object {
        /** The name Android tasks carry too (`TaskRecord.createFields`). */
        const val SOURCE_CLIENT = "Septena Android"
    }
}

/** A row pulled from the server can hold a bool as 0 or 1. */
private fun JsonValue?.isTrue(): Boolean = booleanValue() == true || longValue() == 1L
