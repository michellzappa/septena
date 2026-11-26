package app.septena.core

import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import app.septena.sharedcore.RescheduleMode
import java.time.Instant
import java.time.LocalDate
import kotlin.coroutines.Continuation
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.startCoroutine

class FixedRepeatRescheduleConformanceTest {

    private class FixedClock(private val instant: Instant, private val day: LocalDate) : DayClock {
        override fun today(): LocalDate = day
        override fun now(): Instant = instant
        override fun today(at: Instant): LocalDate = day
    }

    private class SeqIds : TaskIdGenerator {
        private var n = 0
        override fun nextTaskId(): String = "t${++n}"
        override fun nextClientOpId(): String = "op${++n}"
    }

    private class InMemoryStore : TaskStore {
        val rows = linkedMapOf<Pair<String, String>, SyncRecord>()
        override suspend fun record(entity: String, id: String): SyncRecord? = rows[entity to id]
        override suspend fun records(entity: String): List<SyncRecord> =
            rows.entries.filter { it.key.first == entity }.map { it.value }
        override suspend fun turns(taskId: String): List<SyncTurn> = emptyList()
        override suspend fun writeLocalAndEnqueue(record: SyncRecord, operation: SyncOperation, notBefore: Instant) {
            rows[record.entity to record.id] = record
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

    private fun <T> runSync(block: suspend () -> T): T {
        var result: Result<T>? = null
        val latch = java.util.concurrent.CountDownLatch(1)
        block.startCoroutine(object : Continuation<T> {
            override val context = EmptyCoroutineContext
            override fun resumeWith(value: Result<T>) {
                result = value
                latch.countDown()
            }
        })
        check(latch.await(10, java.util.concurrent.TimeUnit.SECONDS)) { "Suspending operation did not complete" }
        return result!!.getOrThrow()
    }

    fun runAll() {
        makeExceptionLeavesAnchorAndSiblingsUntouchedWhileUpdateRuleRebasesSeries()
    }

    private fun makeExceptionLeavesAnchorAndSiblingsUntouchedWhileUpdateRuleRebasesSeries() {
        runSync {
            val store = InMemoryStore()
            val clock = FixedClock(Instant.parse("2026-11-26T09:00:00Z"), LocalDate.of(2026, 11, 26))
            val mutator = TaskMutator(store, clock, SeqIds())

            fun seedFixed(id: String, seriesId: String, day: String, reminder: String? = null) {
                val fields = linkedMapOf<String, JsonValue>(
                    RegistryEntityFields.Task.TITLE to JsonValue.StringValue("Standup"),
                    RegistryEntityFields.Task.STATUS to JsonValue.StringValue(RegistryEntityEnums.TaskStatus.OPEN),
                    RegistryEntityFields.Task.CREATED to JsonValue.StringValue("2026-11-01"),
                    RegistryEntityFields.Task.SCHEDULED to JsonValue.StringValue(day),
                    RegistryEntityFields.Task.TODAY to JsonValue.BooleanValue(false),
                    RegistryEntityFields.Task.RECURRENCE_UNIT to JsonValue.StringValue("week"),
                    RegistryEntityFields.Task.RECURRENCE_INTERVAL to JsonValue.IntegerValue(1),
                    RegistryEntityFields.Task.RECURRENCE_AFTER_COMPLETION to JsonValue.BooleanValue(false),
                    RegistryEntityFields.Task.RECURRENCE_SERIES_ID to JsonValue.StringValue(seriesId),
                    RegistryEntityFields.Task.RECURRENCE_ANCHOR_DATE to JsonValue.StringValue(day),
                )
                if (reminder != null) {
                    fields[RegistryEntityFields.Task.REMINDER_AT] = JsonValue.StringValue(reminder)
                    fields[RegistryEntityFields.Task.REMINDER_MODE] = JsonValue.StringValue("floating")
                }
                store.rows[RegistryEntityNames.TASK to id] = SyncRecord(RegistryEntityNames.TASK, id, fields)
            }

            // 1. Exception move: only the moved row's scheduled date changes; anchor & sibling stay put.
            seedFixed("ex1", "series-ex", "2026-11-30")
            seedFixed("ex2", "series-ex", "2026-12-07")
            mutator.setWhen("ex1", "2026-12-02", RescheduleMode.MAKE_EXCEPTION)

            val ex1 = store.record(RegistryEntityNames.TASK, "ex1")!!
            val ex2 = store.record(RegistryEntityNames.TASK, "ex2")!!
            check(ex1.fields[RegistryEntityFields.Task.SCHEDULED].stringValue() == "2026-12-02") {
                "ex1 scheduled mismatch: ${ex1.fields[RegistryEntityFields.Task.SCHEDULED]}"
            }
            check(ex1.fields[RegistryEntityFields.Task.RECURRENCE_ANCHOR_DATE].stringValue() == "2026-11-30") {
                "ex1 anchor should stay 2026-11-30, got ${ex1.fields[RegistryEntityFields.Task.RECURRENCE_ANCHOR_DATE]}"
            }
            check(ex2.fields[RegistryEntityFields.Task.SCHEDULED].stringValue() == "2026-12-07") {
                "ex2 should stay 2026-12-07, got ${ex2.fields[RegistryEntityFields.Task.SCHEDULED]}"
            }

            // 2. Update schedule: anchor moves AND open sibling copies rebase forward by +1 week.
            seedFixed("up1", "series-up", "2026-11-30")
            seedFixed("up2", "series-up", "2026-12-07", reminder = "2026-12-07T09:00")
            seedFixed("up3", "series-up", "2026-12-14")
            mutator.setWhen("up1", "2026-12-02", RescheduleMode.UPDATE_RULE)

            val up1 = store.record(RegistryEntityNames.TASK, "up1")!!
            val up2 = store.record(RegistryEntityNames.TASK, "up2")!!
            val up3 = store.record(RegistryEntityNames.TASK, "up3")!!
            check(up1.fields[RegistryEntityFields.Task.SCHEDULED].stringValue() == "2026-12-02") {
                "up1 scheduled mismatch: ${up1.fields[RegistryEntityFields.Task.SCHEDULED]}"
            }
            check(up1.fields[RegistryEntityFields.Task.RECURRENCE_ANCHOR_DATE].stringValue() == "2026-12-02") {
                "up1 anchor mismatch: ${up1.fields[RegistryEntityFields.Task.RECURRENCE_ANCHOR_DATE]}"
            }
            check(up2.fields[RegistryEntityFields.Task.SCHEDULED].stringValue() == "2026-12-09") {
                "up2 scheduled mismatch: ${up2.fields[RegistryEntityFields.Task.SCHEDULED]}"
            }
            check(up2.fields[RegistryEntityFields.Task.RECURRENCE_ANCHOR_DATE].stringValue() == "2026-12-09") {
                "up2 anchor mismatch: ${up2.fields[RegistryEntityFields.Task.RECURRENCE_ANCHOR_DATE]}"
            }
            check(up2.fields[RegistryEntityFields.Task.REMINDER_AT].stringValue() == "2026-12-09T09:00") {
                "up2 reminder mismatch: ${up2.fields[RegistryEntityFields.Task.REMINDER_AT]}"
            }
            check(up3.fields[RegistryEntityFields.Task.SCHEDULED].stringValue() == "2026-12-16") {
                "up3 scheduled mismatch: ${up3.fields[RegistryEntityFields.Task.SCHEDULED]}"
            }
            check(up3.fields[RegistryEntityFields.Task.RECURRENCE_ANCHOR_DATE].stringValue() == "2026-12-16") {
                "up3 anchor mismatch: ${up3.fields[RegistryEntityFields.Task.RECURRENCE_ANCHOR_DATE]}"
            }
        }
        println("core fixed-repeat reschedule rebase: passed")
    }
}
