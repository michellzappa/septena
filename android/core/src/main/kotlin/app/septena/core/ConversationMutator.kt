package app.septena.core

import app.septena.core.generated.RegistryEntityNames
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import java.time.Instant

/** Conversation rows are keyed by task ID; turns are append-only operations. */
class ConversationMutator(
    private val store: TaskStore,
    private val ids: TaskIdGenerator,
) {
    suspend fun appendUserTurn(taskId: String, fields: Map<String, JsonValue>) {
        appendTurn(taskId, fields)
        val chosen = fields["chosen"].stringValue()
        if (chosen != null && fields["step"].stringValue() == RegistryEntityEnums.ConvoTurnStep.CONFIRM) {
            update(taskId, mapOf(
                RegistryEntityFields.Convo.CONFIRMED_INTENT to JsonValue.StringValue(fields["note"].stringValue() ?: chosen),
            ))
        }
    }

    suspend fun setStopped(taskId: String, stopped: Boolean, now: Instant): SyncRecord {
        val changes = if (stopped) {
            mapOf(RegistryEntityFields.Convo.STOPPED_AT to JsonValue.StringValue(WireTimestamp.format(now)))
        } else {
            mapOf(
                RegistryEntityFields.Convo.STOPPED_AT to JsonValue.Null,
                RegistryEntityFields.Convo.ASSIGNEE to JsonValue.StringValue(RegistryEntityEnums.ConvoAssignee.CLAUDE),
            )
        }
        return update(taskId, changes)
    }

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
