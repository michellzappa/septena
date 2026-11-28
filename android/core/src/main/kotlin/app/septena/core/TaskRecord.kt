package app.septena.core

import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.generated.RegistryEntityEnums
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

data class TaskRecord(
    val id: String,
    val fields: Map<String, JsonValue>,
    val revision: Long? = null,
    val updatedAt: String? = null,
    val deletedAt: String? = null,
) {
    val title: String
        get() = fields[RegistryEntityFields.Task.TITLE].stringValue().orEmpty()

    val status: TaskStatus
        get() = TaskStatus.fromWire(fields[RegistryEntityFields.Task.STATUS].stringValue())

    /** How the task was added (ADR 0064). Null on rows from before the field existed. */
    val addedVia: TaskAddedVia?
        get() = TaskAddedVia.fromWire(fields[RegistryEntityFields.Task.ADDED_VIA].stringValue())

    fun changing(changes: Map<String, JsonValue>): TaskRecord = copy(fields = fields + changes)

    companion object {
        fun createFields(
            title: String,
            created: String,
            createdAt: String,
            area: String? = null,
            project: String? = null,
            scheduled: String? = null,
            deadline: String? = null,
            today: Boolean = false,
            todaySetOn: String? = null,
            notes: String? = null,
            source: String = RegistryEntityEnums.TaskSource.APP,
            sourceClient: String = "Septena Android",
            addedVia: TaskAddedVia = TaskAddedVia.TYPED,
            kind: String? = null,
            heading: String? = null,
            position: Double? = null,
        ): Map<String, JsonValue> = linkedMapOf(
            RegistryEntityFields.Task.TITLE to JsonValue.StringValue(title),
            RegistryEntityFields.Task.STATUS to JsonValue.StringValue(RegistryEntityEnums.TaskStatus.OPEN),
            RegistryEntityFields.Task.CREATED to JsonValue.StringValue(created),
            RegistryEntityFields.Task.TODAY to JsonValue.BooleanValue(today),
            RegistryEntityFields.Task.SOURCE to JsonValue.StringValue(source),
            RegistryEntityFields.Task.SOURCE_CLIENT to JsonValue.StringValue(sourceClient),
            RegistryEntityFields.Task.ADDED_VIA to JsonValue.StringValue(addedVia.wireValue),
            RegistryEntityFields.Task.CREATED_AT to JsonValue.StringValue(createdAt),
        ).apply {
            area?.let { put(RegistryEntityFields.Task.AREA, JsonValue.StringValue(it)) }
            project?.let { put(RegistryEntityFields.Task.PROJECT, JsonValue.StringValue(it)) }
            scheduled?.let { put(RegistryEntityFields.Task.SCHEDULED, JsonValue.StringValue(it)) }
            deadline?.let { put(RegistryEntityFields.Task.DEADLINE, JsonValue.StringValue(it)) }
            if (todaySetOn != null) put(RegistryEntityFields.Task.TODAY_SET_ON, JsonValue.StringValue(todaySetOn))
            kind?.let { put(RegistryEntityFields.Task.KIND, JsonValue.StringValue(it)) }
            heading?.let { put(RegistryEntityFields.Task.HEADING, JsonValue.StringValue(it)) }
            position?.let { put(RegistryEntityFields.Task.POSITION, JsonValue.DecimalValue(it)) }
            notes?.let { put(RegistryEntityFields.Task.NOTES, JsonValue.StringValue(it)) }
        }
    }
}

enum class TaskStatus(val wireValue: String) {
    OPEN(RegistryEntityEnums.TaskStatus.OPEN),
    DONE(RegistryEntityEnums.TaskStatus.DONE),
    CANCELLED(RegistryEntityEnums.TaskStatus.CANCELLED),
    CHECKLIST_CHECKED(RegistryEntityEnums.TaskStatus.CHECKLIST_CHECKED),
    UNKNOWN("unknown");

    companion object {
        fun fromWire(value: String?): TaskStatus = entries.firstOrNull { it.wireValue == value }
            ?: UNKNOWN
    }
}

/**
 * How a task was added (registry enum `taskAddedVia`, ADR 0064). Set once when
 * the task is created; later edits never change it. Android creates `TYPED`,
 * `QUICK_ADD`, `SHARE` and `IMPORT`; the other values come from other shells,
 * agents and the API, and Android reads them on synced rows.
 */
enum class TaskAddedVia(val wireValue: String) {
    TYPED(RegistryEntityEnums.TaskAddedVia.TYPED),
    QUICK_ENTRY(RegistryEntityEnums.TaskAddedVia.QUICK_ENTRY),
    QUICK_ADD(RegistryEntityEnums.TaskAddedVia.QUICK_ADD),
    SHARE(RegistryEntityEnums.TaskAddedVia.SHARE),
    SHORTCUT(RegistryEntityEnums.TaskAddedVia.SHORTCUT),
    IMPORT(RegistryEntityEnums.TaskAddedVia.IMPORT),
    AGENT(RegistryEntityEnums.TaskAddedVia.AGENT),
    API(RegistryEntityEnums.TaskAddedVia.API);

    companion object {
        /** Null for a missing or unknown wire value: an old row, or a value a newer registry added. */
        fun fromWire(value: String?): TaskAddedVia? = entries.firstOrNull { it.wireValue == value }
    }
}

fun TaskRecord.toUpsert(clientOpId: String): SyncOperation.Upsert = SyncOperation.Upsert(
    clientOpId = clientOpId,
    entity = RegistryEntityNames.TASK,
    id = id,
    fields = fields,
)

fun SyncRecord.asTaskRecord(): TaskRecord {
    require(entity == RegistryEntityNames.TASK) { "Expected task row, received '$entity'" }
    return TaskRecord(id, fields, revision, updatedAt, deletedAt)
}

fun TaskRecord.asSyncRecord(): SyncRecord = SyncRecord(
    entity = RegistryEntityNames.TASK,
    id = id,
    fields = fields,
    revision = revision,
    updatedAt = updatedAt,
    deletedAt = deletedAt,
)

object WireTimestamp {
    private val formatter = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'").withZone(ZoneOffset.UTC)
    fun format(value: Instant): String = formatter.format(value)
}
