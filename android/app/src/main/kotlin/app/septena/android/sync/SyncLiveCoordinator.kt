package app.septena.android.sync

import app.septena.transport.LiveSocketOutcome
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Keeps the Android app live while open (#542), mirroring Apple `TaskSyncEngine.swift`
 * and Web `web/src/lib/sync/engine.ts`:
 * - Opens `/v1/sync/ws` while foregrounded and signed in; each `{ "rev": N }` nudge
 *   with `N > localCursor` triggers a debounced sync.
 * - Falls back to foreground polling (2 min while socket is down or plan-blocked with
 *   HTTP 402; 10 min safety poll while the socket is up; exponential backoff up to 15 min
 *   on transient sync errors).
 * - Cleanly closes the socket and stops polling when backgrounded, paused, or signed out.
 */
class SyncLiveCoordinator(
    private val sync: SyncController,
    private val signedIn: StateFlow<Boolean>,
    private val currentCursor: suspend () -> Long,
    private val connectSocket: suspend (onConnected: () -> Unit, onRevNudge: (Long) -> Unit) -> LiveSocketOutcome,
    private val scope: CoroutineScope,
    private val pollWhileSocketDownMs: Long = SyncPollPolicy.POLL_WHILE_SOCKET_DOWN_MS,
    private val pollWhileSocketUpMs: Long = SyncPollPolicy.POLL_WHILE_SOCKET_UP_MS,
    private val pollMaxMs: Long = SyncPollPolicy.POLL_MAX_MS,
    private val nudgeDebounceMs: Long = SyncPollPolicy.NUDGE_DEBOUNCE_MS,
    private val stopGraceMs: Long = SyncPollPolicy.FOREGROUND_STOP_GRACE_MS,
    private val socketRetryInitialMs: Long = SyncPollPolicy.SOCKET_RETRY_INITIAL_MS,
    private val socketRetryMaxMs: Long = SyncPollPolicy.SOCKET_RETRY_MAX_MS,
) {
    private val lock = Any()
    private var startedActivities = 0
    private var foreground = false
    private var stopGraceJob: Job? = null
    private var socketJob: Job? = null
    private var pollJob: Job? = null

    private val _isLiveConnected = MutableStateFlow(false)
    val isLiveConnected: StateFlow<Boolean> = _isLiveConnected.asStateFlow()

    private val _liveSyncBlocked = MutableStateFlow(false)
    val liveSyncBlocked: StateFlow<Boolean> = _liveSyncBlocked.asStateFlow()

    private val stateWatcher: Job = scope.launch {
        var lastSignedIn = signedIn.value
        combine(signedIn, sync.paused) { isSignedIn, isPaused -> isSignedIn to isPaused }
            .collect { (isSignedIn, isPaused) ->
                val justSignedIn = isSignedIn && !lastSignedIn
                val justSignedOut = !isSignedIn && lastSignedIn
                lastSignedIn = isSignedIn

                if (justSignedOut || justSignedIn) {
                    _liveSyncBlocked.value = false
                }
                if (!isSignedIn || isPaused) {
                    stopLoopsLocked()
                } else {
                    val triggerSync = synchronized(lock) {
                        if (foreground) {
                            ensureLoopsLocked()
                            justSignedIn
                        } else {
                            false
                        }
                    }
                    if (triggerSync) sync.requestSync()
                }
            }
    }

    /** Call from `Activity.onStart()`. Starts live sync and pulls immediately on foreground entry. */
    fun onActivityStarted() {
        val shouldSyncNow = synchronized(lock) {
            startedActivities += 1
            stopGraceJob?.cancel()
            stopGraceJob = null
            val enteringForeground = !foreground
            foreground = true
            if (signedIn.value && !sync.paused.value) {
                ensureLoopsLocked()
                enteringForeground
            } else {
                false
            }
        }
        if (shouldSyncNow) sync.requestSync()
    }

    /** Call from `Activity.onStop()`. Closes the socket and pauses polling after a brief rotation grace window. */
    fun onActivityStopped() {
        synchronized(lock) {
            if (startedActivities > 0) startedActivities -= 1
            if (startedActivities > 0) return
            stopGraceJob?.cancel()
            if (stopGraceMs <= 0L) {
                foreground = false
                cancelLoopsLocked()
            } else {
                stopGraceJob = scope.launch {
                    delay(stopGraceMs)
                    synchronized(lock) {
                        if (startedActivities == 0) {
                            foreground = false
                            cancelLoopsLocked()
                        }
                    }
                }
            }
        }
    }

    /** Stops background observers (for tests). */
    fun close() {
        stateWatcher.cancel()
        synchronized(lock) {
            stopGraceJob?.cancel()
            stopGraceJob = null
            foreground = false
            cancelLoopsLocked()
        }
    }

    private fun stopLoopsLocked() {
        synchronized(lock) { cancelLoopsLocked() }
    }

    private fun cancelLoopsLocked() {
        socketJob?.cancel()
        socketJob = null
        pollJob?.cancel()
        pollJob = null
        _isLiveConnected.value = false
    }

    private fun ensureLoopsLocked() {
        if (!foreground || !signedIn.value || sync.paused.value) return
        if (socketJob?.isActive != true && canConnectSocketLocked()) {
            socketJob = launchSocketLoop()
        }
        if (pollJob?.isActive != true) {
            pollJob = launchPollLoop()
        }
    }

    private fun canConnectSocketLocked(): Boolean = SyncPollPolicy.shouldConnectSocket(
        foreground = foreground,
        signedIn = signedIn.value,
        liveSyncBlocked = _liveSyncBlocked.value,
        paused = sync.paused.value,
    )

    private fun launchSocketLoop(): Job = scope.launch(Dispatchers.IO) {
        var retryMs = socketRetryInitialMs
        try {
            while (isActive && synchronized(lock) { canConnectSocketLocked() }) {
                val outcome = try {
                    connectSocket(
                        {
                            _isLiveConnected.value = true
                            retryMs = socketRetryInitialMs
                        },
                        { rev -> handleRevNudge(rev) },
                    )
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Exception) {
                    LiveSocketOutcome.Failed(error.message ?: error.javaClass.simpleName)
                } finally {
                    _isLiveConnected.value = false
                }

                when (outcome) {
                    LiveSocketOutcome.LiveSyncBlocked -> {
                        _liveSyncBlocked.value = true
                        return@launch
                    }
                    LiveSocketOutcome.NeedsSignIn -> return@launch
                    LiveSocketOutcome.Closed, is LiveSocketOutcome.Failed -> {
                        if (!isActive || !synchronized(lock) { canConnectSocketLocked() }) return@launch
                        delay(retryMs)
                        retryMs = SyncPollPolicy.nextSocketRetryMs(retryMs, socketRetryMaxMs)
                    }
                }
            }
        } finally {
            _isLiveConnected.value = false
        }
    }

    private fun handleRevNudge(rev: Long) {
        scope.launch(Dispatchers.IO) {
            if (!signedIn.value || sync.paused.value) return@launch
            val cursor = runCatching { currentCursor() }.getOrDefault(0L)
            if (rev > cursor) {
                sync.requestSyncDebounced(nudgeDebounceMs)
            }
        }
    }

    private fun launchPollLoop(): Job = scope.launch(Dispatchers.Default) {
        var pollBackoffMs = 0L
        while (isActive) {
            val active = synchronized(lock) { foreground && signedIn.value && !sync.paused.value }
            if (!active) break
            val waitMs = SyncPollPolicy.nextPollIntervalMs(
                wsConnected = _isLiveConnected.value,
                liveSyncBlocked = _liveSyncBlocked.value,
                pollBackoffMs = pollBackoffMs,
                pollWhileSocketDownMs = pollWhileSocketDownMs,
                pollWhileSocketUpMs = pollWhileSocketUpMs,
                pollMaxMs = pollMaxMs,
            )
            delay(waitMs)
            val stillActive = synchronized(lock) { foreground && signedIn.value && !sync.paused.value }
            if (!stillActive) break

            sync.syncAndWait()
            when (sync.state.value) {
                is SyncState.Synced -> pollBackoffMs = 0L
                SyncState.NeedsSignIn -> break
                is SyncState.Failed, SyncState.NotSyncing -> {
                    pollBackoffMs = if (pollBackoffMs == 0L) {
                        pollWhileSocketDownMs
                    } else {
                        minOf(pollMaxMs, pollBackoffMs * 2L)
                    }
                }
                SyncState.Idle, SyncState.Syncing -> Unit
            }

            // Safety net: if the socket loop exited unexpectedly while live sync is allowed, re-arm it.
            synchronized(lock) {
                if (!_isLiveConnected.value && socketJob?.isActive != true && canConnectSocketLocked()) {
                    socketJob = launchSocketLoop()
                }
            }
        }
    }
}
