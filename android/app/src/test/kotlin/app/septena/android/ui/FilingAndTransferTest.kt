package app.septena.android.ui

import app.septena.core.JsonValue
import app.septena.core.QueuedOperation
import app.septena.core.RejectedSyncOperation
import app.septena.core.SyncOperation
import app.septena.core.SyncOperationResult
import app.septena.core.SyncPullPage
import app.septena.core.SyncRecord
import app.septena.core.SyncTurn
import app.septena.core.TaskStore
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

class FilingAndTransferTest {
    @Test
    fun filingSuggestionEnginePredictsAndRespectsEvidenceAndRejectionGates() {
        val engine = FilingSuggestionEngine(context = null)
        val areas = listOf(
            FilingTarget(FilingSuggestion.Kind.AREA, "a-home", "Home"),
            FilingTarget(FilingSuggestion.Kind.AREA, "a-work", "Work"),
        )
        val projects = listOf(
            FilingTarget(FilingSuggestion.Kind.PROJECT, "p-groc", "Groceries"),
        )
        val training = listOf(
            FilingTrainingTask("1", "Buy oat milk and eggs", null, null, "p-groc"),
            FilingTrainingTask("2", "Pick up sourdough bread and apples", null, null, "p-groc"),
            FilingTrainingTask("3", "Prepare quarterly roadmap deck", null, "a-work", null),
            FilingTrainingTask("4", "Review hiring budget spreadsheet", null, "a-work", null),
        )
        engine.prepare(training, areas, projects)

        val groceryPick = engine.suggest("Organic milk and apples")
        assertNotNull(groceryPick)
        assertEquals(FilingSuggestion.Kind.PROJECT, groceryPick!!.kind)
        assertEquals("p-groc", groceryPick.id)

        // Zero lexical overlap -> silence (evidence gate).
        assertNull(engine.suggest("zzzzqxy unknown token"))

        // Rejecting the match suppresses it on retry.
        engine.recordRejection("Organic milk and apples", FilingSuggestion.Kind.PROJECT, "p-groc")
        engine.prepare(training, areas, projects)
        val afterRejection = engine.suggest("Organic milk and apples")
        assertTrue(afterRejection == null || afterRejection.id != "p-groc")
    }

    @Test
    fun dataTransferExportsJsonMarkdownCsvAndRoundTripsEnvelope() = runBlocking {
        val records = listOf(
            SyncRecord(
                entity = RegistryEntityNames.AREA,
                id = "a1",
                fields = mapOf(RegistryEntityFields.Area.TITLE to JsonValue.StringValue("Personal")),
            ),
            SyncRecord(
                entity = RegistryEntityNames.TASK,
                id = "t1",
                fields = mapOf(
                    RegistryEntityFields.Task.TITLE to JsonValue.StringValue("Buy, \"fresh\" bread"),
                    RegistryEntityFields.Task.STATUS to JsonValue.StringValue(RegistryEntityEnums.TaskStatus.OPEN),
                    RegistryEntityFields.Task.AREA to JsonValue.StringValue("a1"),
                ),
            ),
        )
        val store = object : TaskStore {
            override suspend fun record(entity: String, id: String): SyncRecord? = records.firstOrNull { it.entity == entity && it.id == id }
            override suspend fun records(entity: String): List<SyncRecord> = records.filter { it.entity == entity }
            override suspend fun turns(taskId: String): List<SyncTurn> = emptyList()
            override suspend fun writeLocalAndEnqueue(record: SyncRecord, operation: SyncOperation, notBefore: Instant) = Unit
            override suspend fun appendTurnAndEnqueue(taskId: String, turn: Map<String, JsonValue>, operation: SyncOperation.AppendTurn) = Unit
            override suspend fun claimPendingOperations(limit: Int, now: Instant): List<QueuedOperation> = emptyList()
            override suspend fun applyPushResults(results: List<SyncOperationResult>, at: Instant) = Unit
            override suspend fun notSyncedOperations(): List<RejectedSyncOperation> = emptyList()
            override suspend fun retryNotSynced(clientOpId: String, replacementClientOpId: String) = Unit
            override suspend fun applyPullPage(page: SyncPullPage, at: Instant) = Unit
            override suspend fun syncCursor(): Long = 0L
            override suspend fun resetForFullPull() = Unit
        }

        val json = TaskDataTransferCodec.exportJson(store, Instant.parse("2026-11-25T10:00:00Z"))
        val parsed = TaskDataTransferCodec.parseEnvelope(json).getOrThrow()
        assertEquals(1, parsed.version)
        assertEquals(1, parsed.areas.size)
        assertEquals(1, parsed.tasks.size)

        val md = TaskDataTransferCodec.exportMarkdown(store)
        assertTrue(md.contains("## Personal"))
        assertTrue(md.contains("- [ ] Buy, \"fresh\" bread"))

        val csv = TaskDataTransferCodec.exportCsv(store)
        assertTrue(csv.contains("\"Buy, \"\"fresh\"\" bread\""))
    }
}
