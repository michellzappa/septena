package app.septena.core

import app.septena.core.generated.RegistryEntities
import app.septena.core.generated.RegistryColumnSpec
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.generated.RegistryRules
import java.time.Duration

/** Generic mutator for registry entities without task-specific lifecycle behavior. */
class RegistryEntityMutator(
    private val store: TaskStore,
    private val clock: DayClock,
    private val ids: TaskIdGenerator,
) {
    suspend fun create(entity: String, fields: Map<String, JsonValue>): SyncRecord {
        require(entity in RegistryEntityNames.all) { "Unknown registry entity '$entity'" }
        require(entity != RegistryEntityNames.TASK && entity != RegistryEntityNames.SETTING && entity != RegistryEntityNames.CONVO) {
            "Use the entity-specific mutator for '$entity'"
        }
        val id = ids.nextTaskId()
        val completeFields = defaultFields(entity) + fields
        RegistryValidator.requireValidUpsert(entity, id, completeFields, insert = true)
        val record = SyncRecord(entity = entity, id = id, fields = completeFields)
        store.writeLocalAndEnqueue(
            record,
            SyncOperation.Upsert(ids.nextClientOpId(), entity, id, completeFields),
        )
        return record
    }

    /** [notesBase]: the notes an editor started from, when the stored ones may have moved on since. */
    suspend fun update(
        entity: String,
        id: String,
        changes: Map<String, JsonValue>,
        notesBase: NotesBase? = null,
    ): SyncRecord? {
        require(entity in RegistryEntityNames.all) { "Unknown registry entity '$entity'" }
        require(entity != RegistryEntityNames.TASK && entity != RegistryEntityNames.SETTING && entity != RegistryEntityNames.CONVO) {
            "Use the entity-specific mutator for '$entity'"
        }
        require(changes.isNotEmpty()) { "An entity update must contain at least one field" }
        RegistryValidator.requireValidUpsert(entity, id, changes, insert = false)
        val existing = store.record(entity, id) ?: return null
        if (existing.deletedAt != null) return null
        val updated = existing.copy(fields = existing.fields + changes)
        store.writeLocalAndEnqueue(
            updated,
            SyncOperation.Upsert(
                ids.nextClientOpId(), entity, id, changes,
                base = NotesBase.of(entity, changes, existing.fields, notesBase),
            ),
        )
        return updated
    }

    suspend fun delete(entity: String, id: String): SyncRecord? {
        require(entity in RegistryEntityNames.deletable) { "Entity '$entity' cannot be deleted" }
        require(entity != RegistryEntityNames.TASK) { "Tasks use TaskMutator.delete" }
        val existing = store.record(entity, id) ?: return null
        if (existing.deletedAt != null) return null
        val now = clock.now()
        val deleted = existing.copy(deletedAt = WireTimestamp.format(now))
        store.writeLocalAndEnqueue(
            deleted,
            SyncOperation.Delete(ids.nextClientOpId(), entity, id),
            now.plus(Duration.ofSeconds(RegistryRules.DELETE_GRACE_SECONDS)),
        )
        return deleted
    }

    private fun defaultFields(entity: String): Map<String, JsonValue> =
        RegistryEntities.all.getValue(entity).columns.mapNotNull { (name, column) ->
            column.defaultFieldValue()?.let { name to it }
        }.toMap()
}

internal fun RegistryColumnSpec.defaultFieldValue(): JsonValue? {
    val raw = defaultJson ?: return null
    if (kind != "bool") return JsonValue.parse(raw)
    return when (raw) {
        "1", "true" -> JsonValue.BooleanValue(true)
        "0", "false" -> JsonValue.BooleanValue(false)
        else -> error("Registry boolean default is not boolean-like")
    }
}
