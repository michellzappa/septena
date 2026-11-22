package app.septena.core

import app.septena.core.generated.RegistryEntityLimits

data class SyncSummary(val pushedOperations: Int, val pulledPages: Int)

/** Shared pull/push orchestration. Store and transport adapters remain replaceable for JVM conformance. */
class TaskSyncEngine(
    private val store: TaskStore,
    private val transport: SyncTransport,
    private val clock: DayClock,
) {
    suspend fun sync(): SyncSummary {
        val batchLimit = RegistryEntityLimits.all.getValue("maxOpsPerPush").toInt()
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
            val response = transport.push(operations)
            val expectedIds = operations.map(SyncOperation::clientOpId)
            val actualIds = response.results.map(SyncOperationResult::clientOpId)
            require(actualIds == expectedIds) { "Push response did not match the submitted operation order" }

            store.applyPushResults(response.results, clock.now())
            pushedCount += operations.size
            pulledPages += pullUntilCaughtUp()
        }

        return SyncSummary(pushedOperations = pushedCount, pulledPages = pulledPages)
    }

    private suspend fun pullUntilCaughtUp(): Int {
        val pageLimit = RegistryEntityLimits.all.getValue("maxPull").toInt()
        var pages = 0
        var resetCount = 0
        while (true) {
            var cursor = store.syncCursor()
            var page = transport.pull(cursor, pageLimit)
            if (page.resetRequired) {
                require(resetCount++ == 0) { "Server requested another sync reset from revision 0" }
                store.resetForFullPull()
                continue
            }

            var restartFromZero = false
            while (true) {
                if (page.resetRequired) {
                    require(resetCount++ == 0) { "Server requested another sync reset from revision 0" }
                    store.resetForFullPull()
                    restartFromZero = true
                    break
                }
                require(page.nextSince >= cursor) { "Sync cursor moved backwards" }
                if (page.hasMore) require(page.nextSince > cursor) { "Sync pull made no progress while more pages remain" }
                store.applyPullPage(page, clock.now())
                pages++
                if (!page.hasMore) return pages

                cursor = page.nextSince
                page = transport.pull(cursor, pageLimit)
            }
            if (!restartFromZero) return pages
        }
    }
}
