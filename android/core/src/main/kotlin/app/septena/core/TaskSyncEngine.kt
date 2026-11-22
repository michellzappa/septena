package app.septena.core

import app.septena.core.generated.RegistryEntityLimits
import app.septena.core.stringValue

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

    private suspend fun pushValidatedOperations(operations: List<SyncOperation>) {
        if (operations.isEmpty()) return

        try {
            val response = transport.push(operations)
            val expectedIds = operations.map(SyncOperation::clientOpId)
            val actualIds = response.results.map(SyncOperationResult::clientOpId)
            require(actualIds == expectedIds) { "Push response did not match the submitted operation order" }
            store.applyPushResults(response.results, clock.now())
        } catch (failure: SyncHttpFailure) {
            if (failure.statusCode != 400) throw failure

            if (operations.size == 1) {
                store.applyPushResults(
                    listOf(
                        SyncOperationResult(
                            clientOpId = operations.single().clientOpId,
                            status = SyncResultStatus.REJECTED,
                            reason = serverRejectionReason(failure),
                        ),
                    ),
                    clock.now(),
                )
            } else {
                val split = operations.size / 2
                pushValidatedOperations(operations.subList(0, split))
                pushValidatedOperations(operations.subList(split, operations.size))
            }
        }
    }

    private fun serverRejectionReason(failure: SyncHttpFailure): String {
        val body = failure.responseBody.trim()
        val root = try {
            JsonValue.parse(body) as? JsonValue.ObjectValue
        } catch (_: RuntimeException) {
            null
        }
        val issues = (root?.fields?.get("issues") as? JsonValue.ArrayValue)?.values.orEmpty()
            .mapNotNull { value ->
                val fields = (value as? JsonValue.ObjectValue)?.fields ?: return@mapNotNull null
                val message = fields["message"].stringValue() ?: return@mapNotNull null
                val path = (fields["path"] as? JsonValue.ArrayValue)?.values.orEmpty()
                    .mapNotNull { part ->
                        when (part) {
                            is JsonValue.StringValue -> part.value
                            is JsonValue.IntegerValue -> part.value.toString()
                            else -> null
                        }
                    }
                    .joinToString(".")
                if (path.isEmpty()) message else "$path: $message"
            }

        return issues.takeIf { it.isNotEmpty() }?.joinToString("; ")
            ?: root?.fields?.get("message").stringValue()
            ?: root?.fields?.get("error").stringValue()
            ?: body.takeIf(String::isNotBlank)
            ?: "The server rejected this operation with HTTP ${failure.statusCode}"
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
