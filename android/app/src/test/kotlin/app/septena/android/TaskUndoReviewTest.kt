package app.septena.android

import app.septena.core.ConversationMutator
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
import app.septena.core.TaskUndoHistory
import app.septena.core.TaskStore
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.stringValue
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.LocalDate

class TaskUndoReviewTest {
    private val clock = object : DayClock {
        override fun today(): LocalDate = LocalDate.of(2026, 11, 25)
        override fun now(): Instant = Instant.parse("2026-11-25T10:00:00Z")
        override fun today(at: Instant): LocalDate = LocalDate.of(2026, 11, 25)
    }

    private val ids = object : TaskIdGenerator {
        private var n = 0
        override fun nextTaskId(): String = "t${++n}"
        override fun nextClientOpId(): String = "op-${++n}"
    }

    private class FakeStore : TaskStore {
        val map = linkedMapOf<Pair<String, String>, SyncRecord>()
        override suspend fun record(entity: String, id: String): SyncRecord? = map[entity to id]
        override suspend fun records(entity: String): List<SyncRecord> = map.values.filter { it.entity == entity }
        override suspend fun turns(taskId: String): List<SyncTurn> = emptyList()
        override suspend fun writeLocalAndEnqueue(record: SyncRecord, operation: SyncOperation, notBefore: Instant) {
            map[record.entity to record.id] = record
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

    @Test
    fun undoRestoresBothTaskAndConversationAfterAccept() = runBlocking {
        val store = FakeStore()
        val taskId = "task-review-1"
        val initialTask = SyncRecord(
            entity = RegistryEntityNames.TASK,
            id = taskId,
            fields = mapOf(
                RegistryEntityFields.Task.TITLE to JsonValue.StringValue("Check draft"),
                RegistryEntityFields.Task.STATUS to JsonValue.StringValue(RegistryEntityEnums.TaskStatus.OPEN),
            ),
        )
        val initialConvo = SyncRecord(
            entity = RegistryEntityNames.CONVO,
            id = taskId,
            fields = mapOf(
                RegistryEntityFields.Convo.END_STATE to JsonValue.StringValue(RegistryEntityEnums.ConvoEndState.NEEDS_VERIFY),
                RegistryEntityFields.Convo.END_STATE_NOTE to JsonValue.StringValue("Ready to review"),
            ),
        )
        store.map[RegistryEntityNames.TASK to taskId] = initialTask
        store.map[RegistryEntityNames.CONVO to taskId] = initialConvo

        val taskMutator = TaskMutator(store, clock, ids)
        val convoMutator = ConversationMutator(store, ids)
        val undo = TaskUndoHistory()

        val doneTask = taskMutator.updateFields(
            taskId,
            mapOf(RegistryEntityFields.Task.STATUS to JsonValue.StringValue(RegistryEntityEnums.TaskStatus.DONE)),
        )
        val doneConvo = convoMutator.update(
            taskId,
            mapOf(RegistryEntityFields.Convo.END_STATE to JsonValue.StringValue(RegistryEntityEnums.ConvoEndState.AGENT_ASSISTED_DONE)),
        )
        undo.recordTaskAndConvoEdits(
            listOf(
                TaskUndoHistory.Edit(
                    taskId = taskId,
                    beforeTask = initialTask,
                    afterTask = doneTask?.let { store.record(RegistryEntityNames.TASK, taskId) },
                    beforeConvo = initialConvo,
                    afterConvo = doneConvo,
                ),
            ),
        )

        assertTrue(undo.undo(taskMutator, convoMutator))
        assertEquals(
            RegistryEntityEnums.TaskStatus.OPEN,
            store.record(RegistryEntityNames.TASK, taskId)?.fields?.get(RegistryEntityFields.Task.STATUS).stringValue(),
        )
        assertEquals(
            RegistryEntityEnums.ConvoEndState.NEEDS_VERIFY,
            store.record(RegistryEntityNames.CONVO, taskId)?.fields?.get(RegistryEntityFields.Convo.END_STATE).stringValue(),
        )
    }
}
