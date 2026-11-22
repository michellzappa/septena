package app.septena.core

import app.septena.core.generated.RegistryEntityNames

/** Conversation rows are keyed by task ID; turns are append-only operations. */
class ConversationMutator(
    private val store: TaskStore,
    private val ids: TaskIdGenerator,
) {
    suspend fun update(taskId: String, changes: Map<String, JsonValue>): SyncRecord {
        require(changes.isNotEmpty()) { "A conversation update must contain at least one field" }
        val task = store.record(RegistryEntityNames.TASK, taskId)
            ?: throw IllegalArgumentException("Unknown task '$taskId'")
        require(task.deletedAt == null) { "A deleted task conversation cannot be changed" }
        RegistryValidator.requireValidUpsert(RegistryEntityNames.CONVO, taskId, changes, insert = false)
        val previous = store.record(RegistryEntityNames.CONVO, taskId)
        val updated = SyncRecord(
            entity = RegistryEntityNames.CONVO,
            id = taskId,
            fields = previous?.fields.orEmpty() + changes,
            revision = previous?.revision,
            updatedAt = previous?.updatedAt,
        )
        store.writeLocalAndEnqueue(
            updated,
            SyncOperation.Upsert(ids.nextClientOpId(), RegistryEntityNames.CONVO, taskId, changes),
        )
        return updated
    }

    suspend fun appendTurn(taskId: String, fields: Map<String, JsonValue>): SyncOperation.AppendTurn {
        val task = store.record(RegistryEntityNames.TASK, taskId)
            ?: throw IllegalArgumentException("Unknown task '$taskId'")
        require(task.deletedAt == null) { "A deleted task cannot receive a conversation turn" }
        val operation = SyncOperation.AppendTurn(ids.nextClientOpId(), taskId, fields)
        SyncWireCodec.encodeOperation(operation)
        store.appendTurnAndEnqueue(taskId, fields, operation)
        return operation
    }
}
