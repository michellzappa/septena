package app.septena.core

import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import java.io.IOException
import java.time.Instant

/**
 * The notes an edit started from. The server merges when the row changed meanwhile, so nobody's
 * words are lost (docs/PROJECT_SHARING_SPEC.md §5a).
 */
data class NotesBase(val notes: String?) {
    companion object {
        /** The base of a write of [changes], or null when the write carries none. */
        fun of(entity: String, changes: Map<String, JsonValue>, stored: Map<String, JsonValue>, edited: NotesBase?): NotesBase? {
            val field = when (entity) {
                RegistryEntityNames.TASK -> RegistryEntityFields.Task.NOTES
                RegistryEntityNames.PROJECT -> RegistryEntityFields.Project.NOTES
                else -> return null
            }
            if (field !in changes) return null
            return edited ?: NotesBase(stored[field].stringValue())
        }
    }
}

sealed interface SyncOperation {
    val clientOpId: String

    data class Upsert(
        override val clientOpId: String,
        val entity: String,
        val id: String,
        val fields: Map<String, JsonValue>,
        /** The notes this write was made from. Task and project only. */
        val base: NotesBase? = null,
    ) : SyncOperation

    data class Delete(
        override val clientOpId: String,
        val entity: String,
        val id: String,
    ) : SyncOperation

    data class AppendTurn(
        override val clientOpId: String,
        val taskId: String,
        val turn: Map<String, JsonValue>,
    ) : SyncOperation
}

data class QueuedOperation(
    val sequence: Long,
    val operation: SyncOperation,
    val notBefore: Instant,
)

enum class SyncResultStatus(val wireValue: String) {
    APPLIED("applied"),
    NOOP("noop"),
    DROPPED("dropped"),
    REJECTED("rejected");

    companion object {
        fun fromWire(value: String): SyncResultStatus = entries.firstOrNull { it.wireValue == value }
            ?: error("Unknown sync result status '$value'")
    }
}

data class SyncOperationResult(
    val clientOpId: String,
    val status: SyncResultStatus,
    val revision: Long? = null,
    val sequence: Long? = null,
    val reason: String? = null,
)

data class SyncPushResponse(
    val appliedThrough: Long,
    val results: List<SyncOperationResult>,
)

/** Local row plus server metadata; field names and JSON values remain registry-owned. */
data class SyncRecord(
    val entity: String,
    val id: String,
    val fields: Map<String, JsonValue>,
    val revision: Long? = null,
    val updatedAt: String? = null,
    val deletedAt: String? = null,
)

data class SyncTurn(
    val taskId: String,
    val sequence: Long,
    val fields: Map<String, JsonValue>,
    val isPending: Boolean = false,
    val clientOpId: String? = null,
)

data class SyncChange(val entity: String, val row: Map<String, JsonValue>)

data class SyncPullPage(
    val resetRequired: Boolean = false,
    val changes: List<SyncChange>,
    val nextSince: Long,
    val hasMore: Boolean,
)

/** HTTP/WebSocket implementation belongs in the platform adapter, not in the shared core. */
interface SyncTransport {
    suspend fun push(operations: List<SyncOperation>): SyncPushResponse

    suspend fun pull(
        since: Long,
        limit: Int,
        includeSettings: Boolean = true,
        includeChecklists: Boolean = true,
        includeTags: Boolean = true,
        includeRefs: Boolean = true,
    ): SyncPullPage
}

/** HTTP failure metadata shared with the sync engine without depending on a platform transport module. */
open class SyncHttpFailure(
    val statusCode: Int,
    val responseBody: String,
) : IOException("Septena sync returned HTTP $statusCode")

/** Persistence contract. Each write method must store the row and its outbox op atomically. */
interface TaskStore {
    suspend fun record(entity: String, id: String): SyncRecord?

    suspend fun records(entity: String): List<SyncRecord>

    suspend fun turns(taskId: String): List<SyncTurn>

    /** Persists the optimistic row and its outbox op in the same SQLite transaction. */
    suspend fun writeLocalAndEnqueue(
        record: SyncRecord,
        operation: SyncOperation,
        notBefore: Instant = Instant.EPOCH,
    )

    /** Permanently removes a local row and enqueues an immediate delete op (Delete Permanently / Empty Trash). */
    suspend fun purgeLocalAndEnqueue(
        entity: String,
        id: String,
        operation: SyncOperation.Delete,
    ) {}

    suspend fun appendTurnAndEnqueue(taskId: String, turn: Map<String, JsonValue>, operation: SyncOperation.AppendTurn)

    /** Seals due operations before returning them; sent payloads never change under their clientOpId. */
    suspend fun claimPendingOperations(limit: Int, now: Instant): List<QueuedOperation>

    /** Clears applied/noop/dropped ops and moves rejected ops into the visible Not synced collection. */
    suspend fun applyPushResults(results: List<SyncOperationResult>, at: Instant)

    suspend fun notSyncedOperations(): List<RejectedSyncOperation>

    /** Requeues a rejected payload under a fresh id so server idempotency does not replay the rejection. */
    suspend fun retryNotSynced(clientOpId: String, replacementClientOpId: String)

    /** Applies a page and persists its cursor in one transaction, preserving fields with pending ops. */
    suspend fun applyPullPage(page: SyncPullPage, at: Instant)

    suspend fun syncCursor(): Long

    /** Clears the remote cache and cursor while preserving local rows and pending writes. */
    suspend fun resetForFullPull()
}

data class RejectedSyncOperation(
    val operation: SyncOperation,
    val reason: String,
    val rejectedAt: Instant,
    val retryable: Boolean = true,
)

interface TaskIdGenerator {
    fun nextTaskId(): String
    fun nextClientOpId(): String
}

class UuidTaskIdGenerator : TaskIdGenerator {
    override fun nextTaskId(): String = java.util.UUID.randomUUID().toString()
        .replace("-", "")
        .take(12)
        .lowercase()

    override fun nextClientOpId(): String = "s1-" + java.util.UUID.randomUUID().toString().replace("-", "")
}
