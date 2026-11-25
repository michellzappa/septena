package app.septena.android.sync

import app.septena.core.TaskSyncEngine
import app.septena.transport.SyncAuthenticationException
import app.septena.transport.SyncSubscriptionRequiredException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.time.Instant
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

sealed interface SyncState {
    data object Idle : SyncState
    data object Syncing : SyncState
    data class Synced(val at: Instant) : SyncState
    data class Failed(val message: String) : SyncState
    data object NeedsSignIn : SyncState
}

/**
 * Runs one sync at a time on the IO dispatcher. A request that arrives while a sync runs is coalesced into
 * one more run afterwards, so a write made during a sync is never left unpushed.
 */
class SyncController(
    private val engine: TaskSyncEngine,
    private val scope: CoroutineScope,
    /**
     * Work that needs the rows on the server first (attachment uploads). Runs after
     * each successful sync; true asks for one more sync to pull what it changed.
     */
    private val afterSync: suspend () -> Boolean = { false },
) {
    private val running = AtomicBoolean(false)
    private val again = AtomicBoolean(false)
    private val pendingDebounce = AtomicReference<Job?>(null)

    private val _state = MutableStateFlow<SyncState>(SyncState.Idle)
    val state: StateFlow<SyncState> = _state.asStateFlow()

    /** Bumped after every sync that may have changed local rows; screens reload on change. */
    private val _dataVersion = MutableStateFlow(0L)
    val dataVersion: StateFlow<Long> = _dataVersion.asStateFlow()

    /** Set while account deletion runs: no sync may write rows back after the server emptied the store. */
    private val _paused = MutableStateFlow(false)
    val paused: StateFlow<Boolean> = _paused.asStateFlow()

    fun requestSync() {
        pendingDebounce.getAndSet(null)?.cancel()
        again.set(true)
        if (_paused.value) return
        if (!running.compareAndSet(false, true)) return
        // `pause` sets the flag, then waits on `running`; this checks in the opposite order, so a
        // sync that slips past the first check above still never starts once `pause` has returned.
        if (_paused.value) {
            running.set(false)
            return
        }
        scope.launch(Dispatchers.IO) {
            try {
                while (again.getAndSet(false)) runOnce()
            } finally {
                running.set(false)
                // A request that landed between the last check and the reset above.
                if (again.get() && !_paused.value) requestSync()
            }
        }
    }

    /** Coalesces rapid live nudges into one sync run after [delayMs]. */
    fun requestSyncDebounced(delayMs: Long = SyncPollPolicy.NUDGE_DEBOUNCE_MS) {
        if (_paused.value) return
        if (delayMs <= 0L) {
            requestSync()
            return
        }
        val job = scope.launch(Dispatchers.Default) {
            delay(delayMs)
            requestSync()
        }
        pendingDebounce.getAndSet(job)?.cancel()
    }

    /** Runs a sync now and returns when it and any coalesced follow-up have finished. */
    suspend fun syncAndWait() {
        requestSync()
        while (running.get()) delay(POLL_MS)
    }

    /** Stops new syncs and waits for a running one to finish. [resume] lets them run again. */
    suspend fun pause() {
        pendingDebounce.getAndSet(null)?.cancel()
        _paused.value = true
        while (running.get()) delay(POLL_MS)
    }

    /** Allows syncs again and, when one was asked for meanwhile, runs it. */
    fun resume() {
        _paused.value = false
        if (again.get()) requestSync()
    }

    /** Local writes change the store without a sync; screens reload on this too. */
    fun noteLocalChange() {
        _dataVersion.value += 1
    }

    private suspend fun runOnce() {
        _state.value = SyncState.Syncing
        _state.value = try {
            engine.sync()
            // A failed follow-up never marks the sync itself as failed: it retries next sync.
            if (runCatching { afterSync() }.getOrDefault(false)) again.set(true)
            SyncState.Synced(Instant.now())
        } catch (error: SyncAuthenticationException) {
            SyncState.NeedsSignIn
        } catch (error: SyncSubscriptionRequiredException) {
            SyncState.Failed(error.message ?: "Sync needs a subscription")
        } catch (error: Exception) {
            SyncState.Failed(error.message ?: error.javaClass.simpleName)
        } finally {
            _dataVersion.value += 1
        }
    }

    private companion object {
        const val POLL_MS = 100L
    }
}
