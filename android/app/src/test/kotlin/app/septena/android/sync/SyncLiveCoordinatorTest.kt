package app.septena.android.sync

import app.septena.core.JsonValue
import app.septena.core.QueuedOperation
import app.septena.core.RejectedSyncOperation
import app.septena.core.SyncOperation
import app.septena.core.SyncOperationResult
import app.septena.core.SyncPullPage
import app.septena.core.SyncPushResponse
import app.septena.core.SyncRecord
import app.septena.core.SyncTransport
import app.septena.core.SyncTurn
import app.septena.core.SystemDayClock
import app.septena.core.TaskStore
import app.septena.core.TaskSyncEngine
import app.septena.transport.LiveSocketOutcome
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

class SyncLiveCoordinatorTest {

    @Test
    fun pollPolicyMatchesSpecIntervalsAndGating() {
        assertEquals(
            SyncPollPolicy.POLL_WHILE_SOCKET_DOWN_MS,
            SyncPollPolicy.nextPollIntervalMs(wsConnected = false, liveSyncBlocked = false, pollBackoffMs = 0L),
        )
        assertEquals(
            SyncPollPolicy.POLL_WHILE_SOCKET_UP_MS,
            SyncPollPolicy.nextPollIntervalMs(wsConnected = true, liveSyncBlocked = false, pollBackoffMs = 0L),
        )
        assertEquals(
            SyncPollPolicy.POLL_WHILE_SOCKET_DOWN_MS,
            SyncPollPolicy.nextPollIntervalMs(wsConnected = true, liveSyncBlocked = true, pollBackoffMs = 0L),
        )
        assertEquals(
            SyncPollPolicy.POLL_MAX_MS,
            SyncPollPolicy.nextPollIntervalMs(wsConnected = false, liveSyncBlocked = false, pollBackoffMs = 2_000_000L),
        )
        assertTrue(SyncPollPolicy.shouldConnectSocket(foreground = true, signedIn = true, liveSyncBlocked = false, paused = false))
        assertFalse(SyncPollPolicy.shouldConnectSocket(foreground = false, signedIn = true, liveSyncBlocked = false, paused = false))
        assertFalse(SyncPollPolicy.shouldConnectSocket(foreground = true, signedIn = false, liveSyncBlocked = false, paused = false))
        assertFalse(SyncPollPolicy.shouldConnectSocket(foreground = true, signedIn = true, liveSyncBlocked = true, paused = false))
        assertFalse(SyncPollPolicy.shouldConnectSocket(foreground = true, signedIn = true, liveSyncBlocked = false, paused = true))
    }

    @Test
    fun revNudgeAboveCursorTriggersSyncAndStaleNudgeDoesNot() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        try {
            val cursor = AtomicLong(10L)
            val pulls = AtomicInteger(0)
            val controller = SyncController(
                engine = TaskSyncEngine(FakeTaskStore(cursor), FakeSyncTransport(pulls, cursor), SystemDayClock()),
                scope = scope,
            )
            val signedIn = MutableStateFlow(true)
            val nudgeRef = AtomicReference<((Long) -> Unit)?>(null)
            val connectedGate = CompletableDeferred<Unit>()
            val holdSocket = CompletableDeferred<LiveSocketOutcome>()

            val coordinator = SyncLiveCoordinator(
                sync = controller,
                signedIn = signedIn,
                currentCursor = { cursor.get() },
                connectSocket = { onConnected, onRevNudge ->
                    nudgeRef.set(onRevNudge)
                    onConnected()
                    connectedGate.complete(Unit)
                    holdSocket.await()
                },
                scope = scope,
                pollWhileSocketDownMs = 60_000L,
                pollWhileSocketUpMs = 60_000L,
                nudgeDebounceMs = 15L,
                stopGraceMs = 0L,
            )

            coordinator.onActivityStarted()
            connectedGate.await()
            waitUntil { pulls.get() >= 1 }
            val afterStartPulls = pulls.get()
            assertTrue(coordinator.isLiveConnected.value)

            // Stale nudge (<= cursor 10) must not trigger a redundant pull.
            nudgeRef.get()!!.invoke(10L)
            delay(80L)
            assertEquals(afterStartPulls, pulls.get())

            // Newer nudge (> cursor 10) triggers a debounced pull and advances dataVersion.
            val beforeVersion = controller.dataVersion.value
            nudgeRef.get()!!.invoke(15L)
            waitUntil { pulls.get() > afterStartPulls && controller.dataVersion.value > beforeVersion }
            assertTrue(pulls.get() > afterStartPulls)

            coordinator.onActivityStopped()
            waitUntil { !coordinator.isLiveConnected.value }
            coordinator.close()
        } finally {
            scope.cancel()
        }
    }

    @Test
    fun http402BlocksReconnectAndFallsBackToForegroundPolling() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        try {
            val cursor = AtomicLong(1L)
            val pulls = AtomicInteger(0)
            val socketAttempts = AtomicInteger(0)
            val controller = SyncController(
                engine = TaskSyncEngine(FakeTaskStore(cursor), FakeSyncTransport(pulls, cursor), SystemDayClock()),
                scope = scope,
            )
            val signedIn = MutableStateFlow(true)

            val coordinator = SyncLiveCoordinator(
                sync = controller,
                signedIn = signedIn,
                currentCursor = { cursor.get() },
                connectSocket = { _, _ ->
                    socketAttempts.incrementAndGet()
                    LiveSocketOutcome.LiveSyncBlocked
                },
                scope = scope,
                pollWhileSocketDownMs = 50L,
                pollWhileSocketUpMs = 60_000L,
                stopGraceMs = 0L,
            )

            coordinator.onActivityStarted()
            waitUntil { coordinator.liveSyncBlocked.value }
            waitUntil { pulls.get() >= 3 }
            assertEquals(1, socketAttempts.get())
            assertFalse(coordinator.isLiveConnected.value)

            // Signing out clears liveSyncBlocked so a fresh account can try live sync again.
            signedIn.value = false
            waitUntil { !coordinator.liveSyncBlocked.value }
            coordinator.close()
        } finally {
            scope.cancel()
        }
    }

    private suspend fun waitUntil(timeoutMs: Long = 3_000L, predicate: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (predicate()) return
            delay(15L)
        }
        assertTrue("Condition was not satisfied within ${timeoutMs}ms", predicate())
    }

    private class FakeSyncTransport(
        private val pulls: AtomicInteger,
        private val cursor: AtomicLong,
    ) : SyncTransport {
        override suspend fun push(operations: List<SyncOperation>): SyncPushResponse =
            SyncPushResponse(appliedThrough = cursor.get(), results = emptyList())

        override suspend fun pull(
            since: Long,
            limit: Int,
            includeSettings: Boolean,
            includeChecklists: Boolean,
            includeTags: Boolean,
            includeRefs: Boolean,
        ): SyncPullPage {
            pulls.incrementAndGet()
            return SyncPullPage(
                resetRequired = false,
                changes = emptyList(),
                nextSince = cursor.get(),
                hasMore = false,
            )
        }
    }

    private class FakeTaskStore(private val cursor: AtomicLong) : TaskStore {
        override suspend fun record(entity: String, id: String): SyncRecord? = null
        override suspend fun records(entity: String): List<SyncRecord> = emptyList()
        override suspend fun turns(taskId: String): List<SyncTurn> = emptyList()
        override suspend fun writeLocalAndEnqueue(record: SyncRecord, operation: SyncOperation, notBefore: Instant) = Unit
        override suspend fun appendTurnAndEnqueue(taskId: String, turn: Map<String, JsonValue>, operation: SyncOperation.AppendTurn) = Unit
        override suspend fun claimPendingOperations(limit: Int, now: Instant): List<QueuedOperation> = emptyList()
        override suspend fun applyPushResults(results: List<SyncOperationResult>, at: Instant) = Unit
        override suspend fun notSyncedOperations(): List<RejectedSyncOperation> = emptyList()
        override suspend fun retryNotSynced(clientOpId: String, replacementClientOpId: String) = Unit
        override suspend fun applyPullPage(page: SyncPullPage, at: Instant) {
            cursor.set(page.nextSince)
        }
        override suspend fun syncCursor(): Long = cursor.get()
        override suspend fun resetForFullPull() {
            cursor.set(0L)
        }
    }
}
