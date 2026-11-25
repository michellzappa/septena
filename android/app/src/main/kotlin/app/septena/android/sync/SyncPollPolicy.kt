package app.septena.android.sync

/**
 * Pure polling and live-socket policy for Android sync, aligned with Apple's
 * `TaskSyncPollPolicy` (`SeptenaCore/TaskBackend/TaskBackendLimits.swift`,
 * spec §6.3 and §6.4 finding 8).
 */
object SyncPollPolicy {
    /** Poll interval while live sync is unavailable (free plan poll-only or socket down): 2 minutes. */
    const val POLL_WHILE_SOCKET_DOWN_MS: Long = 120_000L

    /** Safety pull while the live WebSocket is connected, catching any missed nudge: 10 minutes. */
    const val POLL_WHILE_SOCKET_UP_MS: Long = 600_000L

    /** Backoff cap after transient network/server errors: 15 minutes. */
    const val POLL_MAX_MS: Long = 900_000L

    /** Initial reconnect delay after a dropped live socket: 1 second. */
    const val SOCKET_RETRY_INITIAL_MS: Long = 1_000L

    /** Maximum reconnect delay after repeated live socket failures: 60 seconds. */
    const val SOCKET_RETRY_MAX_MS: Long = 60_000L

    /** Coalesce burst rev nudges into one pull (matches Apple `scheduleSync(after: 0.3)`). */
    const val NUDGE_DEBOUNCE_MS: Long = 300L

    /** Keep socket alive across brief activity restarts such as screen rotation. */
    const val FOREGROUND_STOP_GRACE_MS: Long = 1_500L

    fun shouldConnectSocket(
        foreground: Boolean,
        signedIn: Boolean,
        liveSyncBlocked: Boolean,
        paused: Boolean,
    ): Boolean = foreground && signedIn && !liveSyncBlocked && !paused

    fun basePollIntervalMs(
        wsConnected: Boolean,
        liveSyncBlocked: Boolean,
        pollWhileSocketDownMs: Long = POLL_WHILE_SOCKET_DOWN_MS,
        pollWhileSocketUpMs: Long = POLL_WHILE_SOCKET_UP_MS,
    ): Long = if (wsConnected && !liveSyncBlocked) pollWhileSocketUpMs else pollWhileSocketDownMs

    fun nextPollIntervalMs(
        wsConnected: Boolean,
        liveSyncBlocked: Boolean,
        pollBackoffMs: Long,
        pollWhileSocketDownMs: Long = POLL_WHILE_SOCKET_DOWN_MS,
        pollWhileSocketUpMs: Long = POLL_WHILE_SOCKET_UP_MS,
        pollMaxMs: Long = POLL_MAX_MS,
    ): Long {
        val base = basePollIntervalMs(wsConnected, liveSyncBlocked, pollWhileSocketDownMs, pollWhileSocketUpMs)
        return minOf(pollMaxMs, maxOf(base, pollBackoffMs))
    }

    fun nextSocketRetryMs(
        currentMs: Long,
        maxMs: Long = SOCKET_RETRY_MAX_MS,
    ): Long = minOf(maxMs, maxOf(1L, currentMs) * 2L)
}
