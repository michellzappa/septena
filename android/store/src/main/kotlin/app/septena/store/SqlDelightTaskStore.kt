package app.septena.store

import app.cash.sqldelight.db.SqlDriver
import app.septena.core.JsonValue
import app.septena.core.QueuedOperation
import app.septena.core.RejectedSyncOperation
import app.septena.core.SyncOperation
import app.septena.core.SyncOperationResult
import app.septena.core.SyncRecord
import app.septena.core.SyncResultStatus
import app.septena.core.SyncTurn
import app.septena.core.SyncWireCodec
import app.septena.core.TaskStore
import app.septena.core.WireTimestamp
import app.septena.core.stringValue
import app.septena.core.generated.RegistryEntityNames
import app.septena.store.db.SeptenaDatabase
import app.septena.sharedcore.CoreException
import app.septena.sharedcore.PullRowPlan
import app.septena.sharedcore.planPullRow
import java.time.Instant

/** SQLDelight-backed outbox, local rows and remote shadows. The injected driver keeps this module JVM reusable. */
class SqlDelightTaskStore(private val database: SeptenaDatabase) : TaskStore {
    private val queries = database.syncQueries

    constructor(driver: SqlDriver) : this(SeptenaDatabase(driver))

    override suspend fun record(entity: String, id: String): SyncRecord? =
        queries.selectRecord(entity, id).executeAsOneOrNull()?.let { row ->
            SyncRecord(row.entity, row.id, parseObject(row.fieldsJson), row.revision, row.updatedAt, row.deletedAt)
        }

    override suspend fun records(entity: String): List<SyncRecord> =
        queries.selectRecords(entity).executeAsList().map { row ->
            SyncRecord(row.entity, row.id, parseObject(row.fieldsJson), row.revision, row.updatedAt, row.deletedAt)
        }

    override suspend fun turns(taskId: String): List<SyncTurn> {
        val serverTurns = queries.selectTurns(taskId).executeAsList().map { row ->
            SyncTurn(taskId = row.taskId, sequence = row.sequence, fields = parseObject(row.fieldsJson))
        }
        val lastSequence = serverTurns.maxOfOrNull(SyncTurn::sequence) ?: 0L
        val pendingTurns = queries.selectLocalTurns(taskId).executeAsList().mapIndexed { index, row ->
            SyncTurn(
                taskId = row.taskId,
                sequence = lastSequence + index + 1L,
                fields = parseObject(row.fieldsJson),
                isPending = true,
                clientOpId = row.clientOpId,
            )
        }
        return serverTurns + pendingTurns
    }

    override suspend fun writeLocalAndEnqueue(record: SyncRecord, operation: SyncOperation, notBefore: Instant) {
        require(record.entity in RegistryEntityNames.all) {
            "Local record entity '${record.entity}' is not in the registry"
        }
        require(operation !is SyncOperation.AppendTurn) { "Append turns use appendTurnAndEnqueue" }
        require(operation.entityId() == (record.entity to record.id)) {
            "Operation row does not match the local record"
        }
        database.transaction {
            val previous = queries.selectRecord(record.entity, record.id).executeAsOneOrNull()
            val shadow = queries.selectShadow(record.entity, record.id).executeAsOneOrNull()
            val remoteKnown = previous?.remoteKnown == 1L || shadow?.remoteKnown == 1L
            queries.upsertRecord(
                entity = record.entity,
                id = record.id,
                fields_json = encodeObject(record.fields),
                revision = record.revision ?: previous?.revision,
                updated_at = record.updatedAt ?: previous?.updatedAt,
                deleted_at = record.deletedAt,
                remote_known = if (remoteKnown) 1L else 0L,
            )
            when (operation) {
                is SyncOperation.Upsert -> enqueueUpsert(operation, notBefore)
                is SyncOperation.Delete -> enqueueDelete(operation, notBefore, remoteKnown)
                is SyncOperation.AppendTurn -> error("Append turns use appendTurnAndEnqueue")
            }
        }
    }

    override suspend fun appendTurnAndEnqueue(
        taskId: String,
        turn: Map<String, JsonValue>,
        operation: SyncOperation.AppendTurn,
    ) {
        require(operation.taskId == taskId && operation.turn == turn) { "Append turn payload does not match operation" }
        val encoded = SyncWireCodec.encodeOperation(operation).canonicalJson()
        database.transaction {
            insertOperation(operation, encoded, Instant.EPOCH)
            queries.insertLocalTurn(taskId, operation.clientOpId, encodeObject(turn))
        }
    }

    override suspend fun claimPendingOperations(limit: Int, now: Instant): List<QueuedOperation> {
        require(limit > 0) { "Operation limit must be positive" }
        return database.transactionWithResult {
            val rows = queries.selectDueOutbox(now.toEpochMilli(), limit.toLong()).executeAsList()
            rows.forEach { queries.markOutboxSent(it.clientOpId) }
            rows.map { row ->
                QueuedOperation(
                    sequence = row.seq,
                    operation = SyncWireCodec.decodeOperation(row.operationJson),
                    notBefore = Instant.ofEpochMilli(row.notBeforeMs),
                )
            }
        }
    }

    override suspend fun applyPushResults(results: List<SyncOperationResult>, at: Instant) {
        database.transaction {
            val outbox = queries.selectAllOutbox().executeAsList().associateBy { it.clientOpId }.toMutableMap()
            for (result in results) {
                val row = outbox.remove(result.clientOpId) ?: continue
                val operation = SyncWireCodec.decodeOperation(row.operationJson)
                when (result.status) {
                    SyncResultStatus.APPLIED, SyncResultStatus.NOOP -> {
                        applySuccessfulOperation(operation, result.revision, result.sequence)
                        queries.deleteOutbox(result.clientOpId)
                    }
                    SyncResultStatus.DROPPED -> {
                        queries.upsertRejected(
                            client_op_id = result.clientOpId,
                            op_json = row.operationJson,
                            reason = result.reason ?: "The row was deleted on the server",
                            rejected_at_ms = at.toEpochMilli(),
                            retryable = 0L,
                        )
                        markDropped(operation, result.revision, at)
                        queries.deleteOutbox(result.clientOpId)
                    }
                    SyncResultStatus.REJECTED -> {
                        queries.upsertRejected(
                            client_op_id = result.clientOpId,
                            op_json = row.operationJson,
                            reason = result.reason?.takeIf(String::isNotBlank) ?: "The server rejected this change",
                            rejected_at_ms = at.toEpochMilli(),
                            retryable = 1L,
                        )
                        restoreRejectedOperation(
                            operation = operation,
                            pendingOperations = outbox.values.sortedBy { it.seq }
                                .map { SyncWireCodec.decodeOperation(it.operationJson) },
                        )
                        queries.deleteOutbox(result.clientOpId)
                    }
                }
            }
        }
    }

    override suspend fun notSyncedOperations(): List<RejectedSyncOperation> =
        queries.selectRejected().executeAsList().map { row ->
            RejectedSyncOperation(
                operation = SyncWireCodec.decodeOperation(row.operationJson),
                reason = row.reason,
                rejectedAt = Instant.ofEpochMilli(row.rejectedAtMs),
                retryable = row.retryable == 1L,
            )
        }

    override suspend fun retryNotSynced(clientOpId: String, replacementClientOpId: String) {
        require(Regex(app.septena.core.generated.RegistryEntityPatterns.clientOpId).matches(replacementClientOpId)) {
            "Invalid replacement client operation id"
        }
        require(clientOpId != replacementClientOpId) { "A retry must use a fresh client operation id" }
        database.transaction {
            val row = queries.selectRejectedByID(clientOpId).executeAsOneOrNull() ?: return@transaction
            if (row.retryable != 1L) return@transaction
            val operation = SyncWireCodec.decodeOperation(row.operationJson).withClientOpId(replacementClientOpId)
            insertOperation(operation, SyncWireCodec.encodeOperation(operation).canonicalJson(), Instant.EPOCH)
            if (operation is SyncOperation.AppendTurn) {
                queries.updateLocalTurnClientOpId(replacementClientOpId, clientOpId)
            }
            queries.deleteRejected(clientOpId)
        }
    }

    override suspend fun applyPullPage(page: app.septena.core.SyncPullPage, at: Instant) {
        require(!page.resetRequired) { "A reset-required page must be handled by the sync engine" }
        require(page.nextSince >= syncCursor()) { "Sync cursor moved backwards" }
        database.transaction {
            val outbox = queries.selectAllOutbox().executeAsList()
            val pendingFields = mutableMapOf<Pair<String, String>, MutableSet<String>>()
            val pendingDeletes = mutableSetOf<Pair<String, String>>()
            for (outboxRow in outbox) {
                when (val operation = SyncWireCodec.decodeOperation(outboxRow.operationJson)) {
                    is SyncOperation.Upsert ->
                        pendingFields.getOrPut(operation.entity to operation.id) { mutableSetOf() }
                            .addAll(operation.fields.keys)
                    is SyncOperation.Delete -> pendingDeletes += operation.entity to operation.id
                    is SyncOperation.AppendTurn -> Unit
                }
            }

            // Each row's local write is the shared core's plan (planPullRow,
            // sync-engine.json): merge around queued local edits, keep a task
            // row on a remote delete, never let a server row undo a local
            // delete. This loop only carries the plan out.
            for (change in page.changes) {
                val rowJson = encodeObject(change.row)
                val id = change.row["id"].stringValue()
                val key = id?.let { change.entity to it }
                val currentRow = id?.let { queries.selectRecord(change.entity, it).executeAsOneOrNull() }
                // A malformed row is a store error (IllegalStateException), as
                // before the core: the whole page rolls back.
                val plan = try {
                    planPullRow(
                        entity = change.entity,
                        rowJson = rowJson,
                        currentFieldsJson = currentRow?.fieldsJson,
                        pendingFields = key?.let { pendingFields[it]?.toList() }.orEmpty(),
                        pendingDelete = key != null && key in pendingDeletes,
                    )
                } catch (e: CoreException.InvalidInput) {
                    error(e.reason)
                }
                when (plan) {
                    is PullRowPlan.Turn -> queries.upsertTurn(plan.taskId, plan.seq, canonical(plan.rowJson))
                    PullRowPlan.Skip -> Unit
                    is PullRowPlan.Tombstone -> {
                        val rowId = requireNotNull(id)
                        rejectPendingForRemoteDelete(change.entity, rowId, at)
                        if (plan.keepLocalRow && currentRow != null) {
                            queries.upsertRecord(
                                entity = currentRow.entity,
                                id = currentRow.id,
                                fields_json = currentRow.fieldsJson,
                                revision = plan.revision ?: currentRow.revision,
                                updated_at = plan.updatedAt ?: currentRow.updatedAt,
                                deleted_at = plan.deletedAt,
                                remote_known = 1L,
                            )
                        } else {
                            queries.deleteRecord(change.entity, rowId)
                        }
                        queries.upsertShadow(change.entity, rowId, canonical(plan.shadowJson), plan.revision, 1L, 1L)
                    }
                    is PullRowPlan.ShadowOnly ->
                        queries.upsertShadow(change.entity, requireNotNull(id), canonical(plan.shadowJson), plan.revision, 0L, 1L)
                    is PullRowPlan.Merge -> {
                        val rowId = requireNotNull(id)
                        queries.upsertRecord(
                            entity = change.entity,
                            id = rowId,
                            fields_json = canonical(plan.fieldsJson),
                            revision = plan.revision ?: currentRow?.revision,
                            updated_at = plan.updatedAt ?: currentRow?.updatedAt,
                            deleted_at = null,
                            remote_known = 1L,
                        )
                        queries.upsertShadow(change.entity, rowId, canonical(plan.shadowJson), plan.revision, 0L, 1L)
                    }
                }
            }
            queries.setSyncCursor(page.nextSince.toString())
        }
    }

    override suspend fun syncCursor(): Long =
        queries.selectSyncCursor().executeAsOneOrNull()?.toLongOrNull() ?: 0L

    override suspend fun resetForFullPull() {
        database.transaction {
            queries.resetRemoteRecords()
            queries.clearRemoteRecordMetadata()
            queries.deleteAllShadows()
            queries.deleteAllTurns()
            queries.setSyncCursor("0")
        }
    }

    /**
     * Removes every local row, turn, outbox entry, shadow and the sync cursor: the account is gone
     * (account deletion). Not part of [TaskStore]: only the app's account flow calls it.
     */
    fun wipeAllLocalData() {
        database.transaction {
            queries.deleteAllRecords()
            queries.deleteAllShadows()
            queries.deleteAllTurns()
            queries.deleteAllLocalTurnRows()
            queries.deleteAllOutboxRows()
            queries.deleteAllRejectedRows()
            queries.deleteAllMetadata()
        }
    }

    private fun enqueueUpsert(operation: SyncOperation.Upsert, notBefore: Instant) {
        val last = queries.selectLastRowOperation(operation.entity, operation.id).executeAsOneOrNull()
        if (last != null && last.kind == "upsert" && last.sent == 0L) {
            val mergedFields = parseObject(last.payloadJson) + operation.fields
            val merged = operation.copy(clientOpId = last.clientOpId, fields = mergedFields)
            queries.updateUnsentOutbox(
                op_json = SyncWireCodec.encodeOperation(merged).canonicalJson(),
                payload_json = encodeObject(mergedFields),
                not_before_ms = notBefore.toEpochMilli(),
                client_op_id = last.clientOpId,
            )
            return
        }
        if (last != null && last.kind == "delete" && last.sent == 0L) queries.deleteOutbox(last.clientOpId)
        insertOperation(operation, SyncWireCodec.encodeOperation(operation).canonicalJson(), notBefore)
    }

    private fun enqueueDelete(operation: SyncOperation.Delete, notBefore: Instant, remoteKnown: Boolean) {
        val rowOps = queries.selectOutboxForRow(operation.entity, operation.id).executeAsList()
        if (rowOps.any { it.kind == "delete" }) return
        val sentWriteMayExist = rowOps.any { it.sent != 0L }
        if (!remoteKnown && !sentWriteMayExist) {
            queries.deleteUnsentRowOutbox(operation.entity, operation.id)
            queries.deleteRecord(operation.entity, operation.id)
            if (operation.entity == RegistryEntityNames.TASK) {
                queries.deleteUnsentRowOutbox("turn", operation.id)
                queries.deleteLocalTurns(operation.id)
            }
            return
        }
        queries.deleteUnsentRowOutbox(operation.entity, operation.id)
        insertOperation(operation, SyncWireCodec.encodeOperation(operation).canonicalJson(), notBefore)
    }

    private fun insertOperation(operation: SyncOperation, encoded: String, notBefore: Instant) {
        val row = when (operation) {
            is SyncOperation.Upsert -> OutboxRow(operation.entity, operation.id, "upsert", encodeObject(operation.fields))
            is SyncOperation.Delete -> OutboxRow(operation.entity, operation.id, "delete", "{}")
            is SyncOperation.AppendTurn -> OutboxRow("turn", operation.taskId, "appendTurn", encodeObject(operation.turn))
        }
        queries.insertOutbox(
            client_op_id = operation.clientOpId,
            op_json = encoded,
            entity = row.entity,
            row_id = row.id,
            kind = row.kind,
            payload_json = row.payload,
            not_before_ms = notBefore.toEpochMilli(),
            sent = 0L,
        )
    }

    private fun restoreRejectedOperation(
        operation: SyncOperation,
        pendingOperations: List<SyncOperation>,
    ) {
        when (operation) {
            is SyncOperation.Upsert -> {
                val row = queries.selectRecord(operation.entity, operation.id).executeAsOneOrNull() ?: return
                val shadow = queries.selectShadow(operation.entity, operation.id).executeAsOneOrNull() ?: return
                if (shadow.remoteKnown != 1L) return

                val shadowFields = parseObject(shadow.fieldsJson)
                val restoredFields = parseObject(row.fieldsJson).toMutableMap()
                val remainingUpserts = pendingOperations.filterIsInstance<SyncOperation.Upsert>()
                    .filter { it.entity == operation.entity && it.id == operation.id }
                for (field in operation.fields.keys) {
                    val pendingValue = remainingUpserts.asReversed()
                        .firstOrNull { field in it.fields }
                        ?.fields
                        ?.get(field)
                    when {
                        pendingValue != null -> restoredFields[field] = pendingValue
                        field in shadowFields -> restoredFields[field] = shadowFields.getValue(field)
                        else -> restoredFields.remove(field)
                    }
                }
                queries.upsertRecord(
                    entity = row.entity,
                    id = row.id,
                    fields_json = encodeObject(restoredFields),
                    revision = row.revision,
                    updated_at = row.updatedAt,
                    deleted_at = row.deletedAt,
                    remote_known = row.remoteKnown,
                )
            }
            is SyncOperation.Delete, is SyncOperation.AppendTurn -> Unit
        }
    }

    private fun applySuccessfulOperation(operation: SyncOperation, revision: Long?, sequence: Long?) {
        when (operation) {
            is SyncOperation.Upsert -> {
                val existing = queries.selectShadow(operation.entity, operation.id).executeAsOneOrNull()
                val fields = existing?.fieldsJson?.let(::parseObject).orEmpty() + operation.fields
                queries.upsertShadow(
                    entity = operation.entity,
                    id = operation.id,
                    fields_json = encodeObject(fields),
                    revision = revision ?: existing?.revision,
                    gone = 0L,
                    remote_known = 1L,
                )
                val row = queries.selectRecord(operation.entity, operation.id).executeAsOneOrNull()
                if (row != null) queries.upsertRecord(
                    entity = row.entity,
                    id = row.id,
                    fields_json = row.fieldsJson,
                    revision = revision ?: row.revision,
                    updated_at = row.updatedAt,
                    deleted_at = row.deletedAt,
                    remote_known = 1L,
                )
            }
            is SyncOperation.Delete -> markShadowGone(operation, revision)
            is SyncOperation.AppendTurn -> {
                val serverSequence = sequence ?: error("Applied appendTurn result is missing its server sequence")
                val row = operation.turn + mapOf(
                    "taskId" to JsonValue.StringValue(operation.taskId),
                    "seq" to JsonValue.IntegerValue(serverSequence),
                )
                queries.upsertTurn(operation.taskId, serverSequence, encodeObject(row))
                queries.deleteLocalTurnByOp(operation.clientOpId)
            }
        }
    }

    private fun markShadowGone(operation: SyncOperation, revision: Long?) {
        val (entity, id) = operation.entityId()
        val existing = queries.selectShadow(entity, id).executeAsOneOrNull()
        queries.upsertShadow(
            entity = entity,
            id = id,
            fields_json = existing?.fieldsJson ?: "{}",
            revision = revision ?: existing?.revision,
            gone = 1L,
            remote_known = 1L,
        )
    }

    private fun markDropped(operation: SyncOperation, revision: Long?, at: Instant) {
        val (entity, id) = operation.entityId()
        if (operation is SyncOperation.AppendTurn) {
            rejectPendingForRemoteDelete(RegistryEntityNames.TASK, id, at)
            queries.deleteLocalTurns(id)
        } else {
            rejectPendingForRemoteDelete(entity, id, at)
        }
        if (entity == RegistryEntityNames.TASK) {
            val row = queries.selectRecord(entity, id).executeAsOneOrNull()
            if (row != null) queries.upsertRecord(
                entity = row.entity,
                id = row.id,
                fields_json = row.fieldsJson,
                revision = revision ?: row.revision,
                updated_at = row.updatedAt,
                deleted_at = row.deletedAt ?: WireTimestamp.format(at),
                remote_known = 1L,
            )
        } else if (entity != "turn") {
            queries.deleteRecord(entity, id)
        }
        markShadowGone(operation, revision)
        if (entity == "turn") {
            val taskShadow = queries.selectShadow(RegistryEntityNames.TASK, id).executeAsOneOrNull()
            queries.upsertShadow(
                entity = RegistryEntityNames.TASK,
                id = id,
                fields_json = taskShadow?.fieldsJson ?: "{}",
                revision = taskShadow?.revision,
                gone = 1L,
                remote_known = 1L,
            )
            val task = queries.selectRecord(RegistryEntityNames.TASK, id).executeAsOneOrNull()
            if (task != null) queries.upsertRecord(
                entity = task.entity,
                id = task.id,
                fields_json = task.fieldsJson,
                revision = task.revision,
                updated_at = task.updatedAt,
                deleted_at = task.deletedAt ?: WireTimestamp.format(at),
                remote_known = 1L,
            )
        }
    }

    private fun SyncOperation.entityId(): Pair<String, String> = when (this) {
        is SyncOperation.Upsert -> entity to id
        is SyncOperation.Delete -> entity to id
        is SyncOperation.AppendTurn -> "turn" to taskId
    }

    private fun SyncOperation.withClientOpId(clientOpId: String): SyncOperation = when (this) {
        is SyncOperation.Upsert -> copy(clientOpId = clientOpId)
        is SyncOperation.Delete -> copy(clientOpId = clientOpId)
        is SyncOperation.AppendTurn -> copy(clientOpId = clientOpId)
    }

    private fun rejectPendingForRemoteDelete(entity: String, id: String, at: Instant) {
        val related = when (entity) {
            RegistryEntityNames.TASK -> setOf(entity to id, RegistryEntityNames.CONVO to id, "turn" to id)
            else -> setOf(entity to id)
        }
        val matching = queries.selectAllOutbox().executeAsList().filter { row ->
            (row.entity to row.rowId) in related
        }
        matching.forEach { row ->
            val operation = SyncWireCodec.decodeOperation(row.operationJson)
            if (operation !is SyncOperation.Delete) {
                queries.upsertRejected(
                    client_op_id = operation.clientOpId,
                    op_json = row.operationJson,
                    reason = "The row was deleted on the server",
                    rejected_at_ms = at.toEpochMilli(),
                    retryable = 0L,
                )
            }
            queries.deleteOutbox(row.clientOpId)
        }
        if (entity == RegistryEntityNames.TASK) {
            queries.deleteLocalTurns(id)
            queries.deleteTurns(id)
        }
    }

    private fun encodeObject(fields: Map<String, JsonValue>): String = JsonValue.ObjectValue(fields).canonicalJson()

    /** The core's JSON in this store's canonical key order, so stored rows compare by text. */
    private fun canonical(json: String): String = encodeObject(parseObject(json))

    private fun parseObject(json: String): Map<String, JsonValue> =
        (JsonValue.parse(json) as? JsonValue.ObjectValue)?.fields ?: error("Expected a JSON object")

    private fun JsonValue?.asLong(): Long? = when (this) {
        is JsonValue.IntegerValue -> value
        is JsonValue.DecimalValue -> if (value % 1.0 == 0.0) value.toLong() else null
        else -> null
    }

    companion object {
        private val ROW_METADATA_KEYS = setOf("id", "rev", "updatedAt", "deletedAt")
    }

    private data class OutboxRow(val entity: String, val id: String, val kind: String, val payload: String)
}
