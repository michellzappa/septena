package app.septena.core

import app.septena.core.generated.RegistryEntityLimits
import app.septena.sharedcore.PullPageDecision
import app.septena.sharedcore.PullPageHeader
import app.septena.sharedcore.PushOutcome
import app.septena.sharedcore.PushPlan
import app.septena.sharedcore.checkPullPage
import app.septena.sharedcore.planPushResponse

data class SyncSummary(val pushedOperations: Int, val pulledPages: Int)

/** Shared pull/push orchestration. Store and transport adapters remain replaceable for JVM conformance. */
class TaskSyncEngine(
    private val store: TaskStore,
    private val transport: SyncTransport,
    private val clock: DayClock,
) {
    suspend fun sync(): SyncSummary {
        val batchLimit = RegistryEntityLimits.MAX_OPS_PER_PUSH.toInt()
        var pushedCount = 0
        var pulledPages = 0

        while (true) {
            val queued = store.claimPendingOperations(batchLimit, clock.now())
            if (queued.isEmpty()) {
                if (pushedCount == 0) pulledPages += pullUntilCaughtUp()
                break
            }

            require(queued.size <= batchLimit) { "Store returned more operations than the registry batch limit" }
            val operations = queued.sortedBy(QueuedOperation::sequence).map(QueuedOperation::operation)
            pushOperations(operations)
            pushedCount += operations.size
            pulledPages += pullUntilCaughtUp()
        }

        return SyncSummary(pushedOperations = pushedCount, pulledPages = pulledPages)
    }

    private suspend fun pushOperations(operations: List<SyncOperation>) {
        if (operations.isEmpty()) return

        val rejected = mutableListOf<SyncOperationResult>()
        val valid = operations.filter { operation ->
            try {
                SyncWireCodec.encodeOperation(operation)
                true
            } catch (error: RuntimeException) {
                rejected += SyncOperationResult(
                    clientOpId = operation.clientOpId,
                    status = SyncResultStatus.REJECTED,
                    reason = error.message?.takeIf(String::isNotBlank) ?: "The operation failed local validation",
                )
                false
            }
        }
        if (rejected.isNotEmpty()) store.applyPushResults(rejected, clock.now())
        pushValidatedOperations(valid)
    }

    /**
     * Sends one batch. What to do with the answer is the shared core's
     * decision (`planPushResponse`, sync-engine.json): apply the results, or
     * on a 400 split the batch until the bad operation stands alone and mark
     * only it rejected, with the server's reason.
     */
    private suspend fun pushValidatedOperations(operations: List<SyncOperation>) {
        if (operations.isEmpty()) return
        val sentIds = operations.map(SyncOperation::clientOpId)
        val response = try {
            transport.push(operations)
        } catch (failure: SyncHttpFailure) {
            act(planPushResponse(sentIds, PushOutcome.HttpFailure(failure.statusCode.toUShort(), failure.responseBody)), operations, failure)
            return
        }
        when (val plan = planPushResponse(sentIds, PushOutcome.Response(response.results.map(SyncOperationResult::clientOpId)))) {
            PushPlan.ApplyResults -> store.applyPushResults(response.results, clock.now())
            else -> act(plan, operations, null)
        }
    }

    private suspend fun act(plan: PushPlan, operations: List<SyncOperation>, failure: SyncHttpFailure?) {
        when (plan) {
            PushPlan.ApplyResults -> error("A push failure cannot apply results")
            is PushPlan.RejectOne -> store.applyPushResults(
                listOf(SyncOperationResult(plan.clientOpId, SyncResultStatus.REJECTED, plan.reason)),
                clock.now(),
            )
            is PushPlan.Bisect -> {
                val split = plan.splitAt.toInt()
                pushValidatedOperations(operations.subList(0, split))
                pushValidatedOperations(operations.subList(split, operations.size))
            }
            is PushPlan.Propagate -> throw failure ?: SyncHttpFailure(plan.status.toInt(), "")
            is PushPlan.Fail -> throw IllegalStateException(plan.reason)
        }
    }

    /**
     * Pulls until caught up. Each page's fate (apply, continue, reset once,
     * fail) is the shared core's decision (`checkPullPage`, sync-engine.json).
     */
    private suspend fun pullUntilCaughtUp(): Int {
        val pageLimit = RegistryEntityLimits.MAX_PULL.toInt()
        var pages = 0
        var resets = 0u
        var cursor = store.syncCursor()
        while (true) {
            val page = transport.pull(cursor, pageLimit)
            when (val decision = checkPullPage(cursor, PullPageHeader(page.resetRequired, page.nextSince, page.hasMore), resets)) {
                PullPageDecision.Apply -> {
                    store.applyPullPage(page, clock.now())
                    return pages + 1
                }
                is PullPageDecision.ApplyAndContinue -> {
                    store.applyPullPage(page, clock.now())
                    pages++
                    cursor = decision.nextCursor
                }
                PullPageDecision.Reset -> {
                    resets++
                    store.resetForFullPull()
                    cursor = store.syncCursor()
                }
                is PullPageDecision.Fail -> throw IllegalArgumentException(decision.reason)
            }
        }
    }
}
