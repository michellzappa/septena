package app.septena.core

import java.time.Instant
import java.time.LocalDate
import kotlin.coroutines.Continuation
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.startCoroutine

class SyncEngineConformanceTest {
    fun pullPageVectors() {
        val fixture = ConformanceFixtures.load("sync-engine.json")
        for (caseValue in fixture.arrayAt("pullPage")) {
            val case = caseValue.asObject()
            val input = case.objectAt("input")
            val expected = case.objectAt("expected")
            val page = input.objectAt("page").toPullPage()
            val plan = expected.requiredString("decision")
            val pages = when {
                plan == "reset" -> listOf(page, emptyPage(0))
                plan == "applyAndContinue" -> listOf(page, emptyPage(page.nextSince))
                plan == "fail" && expected.stringAt("reason")?.contains("another sync reset") == true ->
                    listOf(page, page)
                else -> listOf(page)
            }
            val store = MemoryTaskStore(cursor = input.requiredLong("cursor"))
            val transport = ScriptedTransport(pages = pages)
            val engine = TaskSyncEngine(store, transport, FixedClock)

            if (plan == "fail") {
                val failure = assertFailsWith<IllegalArgumentException>(
                    case.requiredString("name"),
                ) { runSuspending { engine.sync() } }
                assertEquals(expected.requiredString("reason"), failure.message, case.requiredString("name"))
            } else {
                val summary = runSuspending { engine.sync() }
                assertEquals(plan == "reset", store.resetCount > 0, case.requiredString("name"))
                assertEquals(
                    if (plan == "applyAndContinue") 2 else 1,
                    store.appliedPages.size,
                    case.requiredString("name"),
                )
                assertEquals(store.appliedPages.size, summary.pulledPages, case.requiredString("name"))
                if (plan == "applyAndContinue") {
                    assertEquals(page.nextSince, transport.pullRequests[1], case.requiredString("name"))
                }
            }
        }
    }

    fun pushResponseVectors() {
        val fixture = ConformanceFixtures.load("sync-engine.json")
        for (caseValue in fixture.arrayAt("pushResponse")) {
            val case = caseValue.asObject()
            val input = case.objectAt("input")
            val expected = case.objectAt("expected")
            val rawIds = input.arrayAt("sentIds").map { it.stringValue() ?: error("Expected operation id") }
            val operations = rawIds.mapIndexed { index, rawId ->
                SyncOperation.Upsert(
                    clientOpId = clientId(rawId),
                    entity = "task",
                    id = "task-${index + 1}",
                    fields = mapOf("title" to JsonValue.StringValue("Task ${index + 1}")),
                )
            }
            val store = MemoryTaskStore(operations = operations)
            val outcome = input.objectAt("outcome")
            val transport = ScriptedTransport(pushHandler = { submitted ->
                when (outcome.requiredString("kind")) {
                    "response" -> SyncPushResponse(
                        appliedThrough = 0,
                        results = outcome.arrayAt("resultIds").map { value ->
                            SyncOperationResult(clientId(value.stringValue()!!), SyncResultStatus.APPLIED)
                        },
                    )
                    "httpFailure" -> throw SyncHttpFailure(
                        outcome.requiredLong("status").toInt(),
                        outcome.stringAt("body").orEmpty(),
                    )
                    else -> error("Unknown push outcome")
                }.also { if (it.results.isNotEmpty()) assertTrue(submitted.isNotEmpty()) }
            })
            val engine = TaskSyncEngine(store, transport, FixedClock)
            when (val plan = expected.requiredString("plan")) {
                "applyResults" -> runSuspending { engine.sync() }
                "fail" -> {
                    val failure = assertFailsWith<IllegalArgumentException>(case.requiredString("name")) {
                        runSuspending { engine.sync() }
                    }
                    assertEquals(expected.requiredString("reason"), failure.message, case.requiredString("name"))
                }
                "bisect" -> {
                    runSuspending { engine.sync() }
                    assertEquals(rawIds.size, transport.pushBatchSizes.first(), case.requiredString("name"))
                    assertEquals(
                        expected.requiredLong("splitAt").toInt(),
                        transport.pushBatchSizes[1],
                        case.requiredString("name"),
                    )
                }
                "rejectOne" -> {
                    runSuspending { engine.sync() }
                    val rejected = store.notSynced.single()
                    assertEquals(clientId(expected.requiredString("clientOpId")), rejected.operation.clientOpId)
                    assertEquals(expected.requiredString("reason"), rejected.reason, case.requiredString("name"))
                }
                "propagate" -> {
                    val failure = assertFailsWith<SyncHttpFailure>(case.requiredString("name")) {
                        runSuspending { engine.sync() }
                    }
                    assertEquals(expected.requiredLong("status").toInt(), failure.statusCode, case.requiredString("name"))
                }
                else -> error("Unknown push plan '$plan'")
            }
        }
    }

    fun rejectionReasonVectors() {
        val fixture = ConformanceFixtures.load("sync-engine.json")
        for (caseValue in fixture.arrayAt("rejectionReason")) {
            val case = caseValue.asObject()
            val input = case.objectAt("input")
            val operation = SyncOperation.Upsert(
                clientOpId = "reason-op-0001",
                entity = "task",
                id = "task-reason-1",
                fields = mapOf("title" to JsonValue.StringValue("Rejected")),
            )
            val store = MemoryTaskStore(operations = listOf(operation))
            val transport = ScriptedTransport(
                pushHandler = {
                    throw SyncHttpFailure(input.requiredLong("status").toInt(), input.requiredString("body"))
                },
            )
            runSuspending { TaskSyncEngine(store, transport, FixedClock).sync() }
            assertEquals(case.fields["expected"].stringValue(), store.notSynced.single().reason, case.requiredString("name"))
        }
    }
}

private object FixedClock : DayClock {
    private val instant = Instant.parse("2026-11-21T12:00:00Z")
    override fun today(): LocalDate = LocalDate.parse("2026-11-21")
    override fun now(): Instant = instant
}

private class MemoryTaskStore(
    cursor: Long = 0,
    operations: List<SyncOperation> = emptyList(),
) : TaskStore {
    private var cursorValue = cursor
    private val operationById = operations.associateBy(SyncOperation::clientOpId)
    private val pending = operations.mapIndexed { index, operation ->
        QueuedOperation(index + 1L, operation, Instant.EPOCH)
    }.toMutableList()
    val appliedPages = mutableListOf<SyncPullPage>()
    val notSynced = mutableListOf<RejectedSyncOperation>()
    var resetCount: Int = 0
        private set

    override suspend fun record(entity: String, id: String): SyncRecord? = null
    override suspend fun records(entity: String): List<SyncRecord> = emptyList()
    override suspend fun turns(taskId: String): List<SyncTurn> = emptyList()
    override suspend fun writeLocalAndEnqueue(record: SyncRecord, operation: SyncOperation, notBefore: Instant) =
        error("Not used by sync conformance vectors")
    override suspend fun appendTurnAndEnqueue(taskId: String, turn: Map<String, JsonValue>, operation: SyncOperation.AppendTurn) =
        error("Not used by sync conformance vectors")

    override suspend fun claimPendingOperations(limit: Int, now: Instant): List<QueuedOperation> {
        val selected = pending.sortedBy(QueuedOperation::sequence).take(limit)
        pending.removeAll(selected.toSet())
        return selected
    }

    override suspend fun applyPushResults(results: List<SyncOperationResult>, at: Instant) {
        results.filter { it.status == SyncResultStatus.REJECTED }.forEach { result ->
            val operation = operationById[result.clientOpId] ?: return@forEach
            notSynced += RejectedSyncOperation(
                operation = operation,
                reason = result.reason.orEmpty(),
                rejectedAt = at,
            )
        }
    }

    override suspend fun notSyncedOperations(): List<RejectedSyncOperation> = notSynced.toList()
    override suspend fun retryNotSynced(clientOpId: String, replacementClientOpId: String) = Unit

    override suspend fun applyPullPage(page: SyncPullPage, at: Instant) {
        appliedPages += page
        cursorValue = page.nextSince
    }

    override suspend fun syncCursor(): Long = cursorValue
    override suspend fun resetForFullPull() {
        resetCount++
        cursorValue = 0
    }
}

private class ScriptedTransport(
    pages: List<SyncPullPage> = emptyList(),
    private val pushHandler: suspend (List<SyncOperation>) -> SyncPushResponse = { submitted ->
        SyncPushResponse(
            appliedThrough = 0,
            results = submitted.map { SyncOperationResult(it.clientOpId, SyncResultStatus.APPLIED) },
        )
    },
) : SyncTransport {
    private val remainingPages = pages.toMutableList()
    val pullRequests = mutableListOf<Long>()
    val pushBatchSizes = mutableListOf<Int>()

    override suspend fun push(operations: List<SyncOperation>): SyncPushResponse {
        pushBatchSizes += operations.size
        return pushHandler(operations)
    }

    override suspend fun pull(
        since: Long,
        limit: Int,
        includeSettings: Boolean,
        includeChecklists: Boolean,
        includeTags: Boolean,
        includeRefs: Boolean,
    ): SyncPullPage {
        pullRequests += since
        return if (remainingPages.isEmpty()) emptyPage(since) else remainingPages.removeAt(0)
    }
}

private fun JsonValue.ObjectValue.toPullPage(): SyncPullPage = SyncPullPage(
    resetRequired = booleanAt("resetRequired") ?: false,
    changes = emptyList(),
    nextSince = requiredLong("nextSince"),
    hasMore = requiredBoolean("hasMore"),
)

private fun emptyPage(since: Long) = SyncPullPage(changes = emptyList(), nextSince = since, hasMore = false)

private fun clientId(vectorId: String): String = "client-$vectorId"

private fun <T> runSuspending(block: suspend () -> T): T {
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
