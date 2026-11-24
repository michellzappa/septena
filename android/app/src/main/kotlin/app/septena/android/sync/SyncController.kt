package app.septena.android.sync

import app.septena.core.TaskSyncEngine
import app.septena.transport.SyncAuthenticationException
import app.septena.transport.SyncSubscriptionRequiredException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.time.Instant
import java.util.concurrent.atomic.AtomicBoolean

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

    private val _state = MutableStateFlow<SyncState>(SyncState.Idle)
    val state: StateFlow<SyncState> = _state.asStateFlow()

    /** Bumped after every sync that may have changed local rows; screens reload on change. */
    private val _dataVersion = MutableStateFlow(0L)
    val dataVersion: StateFlow<Long> = _dataVersion.asStateFlow()

    fun requestSync() {
        again.set(true)
        if (!running.compareAndSet(false, true)) return
        scope.launch(Dispatchers.IO) {
            try {
                while (again.getAndSet(false)) runOnce()
            } finally {
                running.set(false)
                // A request that landed between the last check and the reset above.
                if (again.get()) requestSync()
            }
        }
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
}
