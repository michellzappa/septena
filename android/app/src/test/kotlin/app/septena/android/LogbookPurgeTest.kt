package app.septena.android

import app.septena.core.DayClock
import app.septena.core.JsonValue
import app.septena.core.QueuedOperation
import app.septena.core.RejectedSyncOperation
import app.septena.core.SyncOperation
import app.septena.core.SyncOperationResult
import app.septena.core.SyncPullPage
import app.septena.core.SyncRecord
import app.septena.core.SyncTurn
import app.septena.core.TaskIdGenerator
import app.septena.core.TaskMutator
import app.septena.core.TaskStore
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.LocalDate

class LogbookPurgeTest {
    private class InMemoryPurgeStore : TaskStore {
        val rows = linkedMapOf<Pair<String, String>, SyncRecord>()
        val purgedOps = mutableListOf<SyncOperation.Delete>()

        override suspend fun record(entity: String, id: String): SyncRecord? = rows[entity to id]
        override suspend fun records(entity: String): List<SyncRecord> = rows.values.filter { it.entity == entity }
        override suspend fun turns(taskId: String): List<SyncTurn> = emptyList()
        override suspend fun writeLocalAndEnqueue(record: SyncRecord, operation: SyncOperation, notBefore: Instant) {
            rows[record.entity to record.id] = record
        }
        override suspend fun purgeLocalAndEnqueue(entity: String, id: String, operation: SyncOperation.Delete) {
            rows.remove(entity to id)
            purgedOps += operation
        }
        override suspend fun appendTurnAndEnqueue(taskId: String, turn: Map<String, JsonValue>, operation: SyncOperation.AppendTurn) = Unit
        override suspend fun claimPendingOperations(limit: Int, now: Instant): List<QueuedOperation> = emptyList()
        override suspend fun applyPushResults(results: List<SyncOperationResult>, at: Instant) = Unit
        override suspend fun notSyncedOperations(): List<RejectedSyncOperation> = emptyList()
        override suspend fun retryNotSynced(clientOpId: String, replacementClientOpId: String) = Unit
        override suspend fun applyPullPage(page: SyncPullPage, at: Instant) = Unit
        override suspend fun syncCursor(): Long = 0L
        override suspend fun resetForFullPull() = Unit
    }

    private val clock = object : DayClock {
        override fun now(): Instant = Instant.parse("2026-11-25T12:00:00Z")
        override fun today(): LocalDate = LocalDate.of(2026, 11, 25)
        override fun today(at: Instant): LocalDate = LocalDate.of(2026, 11, 25)
    }

    private val ids = object : TaskIdGenerator {
        private var seq = 1
        override fun nextTaskId(): String = "task_${seq++}"
        override fun nextClientOpId(): String = "op_${seq++}"
    }

    @Test
    fun purgeRemovesSoftDeletedTaskAndEnqueuesDelete() = runBlocking {
        val store = InMemoryPurgeStore()
        val mutator = TaskMutator(store, clock, ids)
        val created = mutator.create(title = "Old note")
        val deleted = mutator.delete(created.id)
        assertTrue(deleted?.deletedAt != null)

        assertTrue(mutator.purge(created.id))
        assertNull(store.record(RegistryEntityNames.TASK, created.id))
        assertEquals(1, store.purgedOps.size)
        assertEquals(created.id, store.purgedOps.first().id)
        assertFalse(mutator.purge("missing"))
    }
}
