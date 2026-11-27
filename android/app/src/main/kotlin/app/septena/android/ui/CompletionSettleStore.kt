package app.septena.android.ui

import app.septena.core.generated.RegistryCompletionMotion
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** One row lingering in the standard completion settle window (`tokens.json` `motion.completion`). */
data class CompletionSettleEntry(
    val fadingOut: Boolean = false,
    /** Review group held while settling in Review so accepted rows stay in place. */
    val reviewGroupId: String? = null,
)

data class CompletionSettleState(
    val entries: Map<String, CompletionSettleEntry> = emptyMap(),
) {
    fun isSettling(id: String): Boolean = id in entries
    fun isFadingOut(id: String): Boolean = entries[id]?.fadingOut == true
}

/**
 * Shared completion settle timer matching iOS `SettleStore` and Web `CompletionSettleController`
 * (`docs/DesignSpec.md` §9). Checked tasks linger in place for [settleDelayMs], then fade out
 * over [fadeOutMs] before leaving the open list. Unchecking within the window aborts the fade.
 */
class CompletionSettleStore(
    private val scope: CoroutineScope,
    private val settleDelayMs: Long = RegistryCompletionMotion.SETTLE_DELAY_MS,
    private val fadeOutMs: Long = RegistryCompletionMotion.FADE_OUT_MS.toLong(),
) {
    private val _state = MutableStateFlow(CompletionSettleState())
    val state: StateFlow<CompletionSettleState> = _state.asStateFlow()

    private val lock = Any()
    private val jobs = mutableMapOf<String, Job>()

    fun isSettling(id: String): Boolean = _state.value.isSettling(id)

    fun start(id: String, reviewGroupId: String? = null) {
        synchronized(lock) {
            jobs.remove(id)?.cancel()
            _state.update { current ->
                current.copy(entries = current.entries + (id to CompletionSettleEntry(fadingOut = false, reviewGroupId = reviewGroupId)))
            }
            jobs[id] = scope.launch {
                delay(settleDelayMs)
                _state.update { current ->
                    val existing = current.entries[id] ?: return@update current
                    current.copy(entries = current.entries + (id to existing.copy(fadingOut = true)))
                }
                delay(fadeOutMs)
                synchronized(lock) {
                    jobs.remove(id)
                }
                _state.update { current ->
                    if (id !in current.entries) current else current.copy(entries = current.entries - id)
                }
            }
        }
    }

    fun cancel(id: String) {
        synchronized(lock) {
            jobs.remove(id)?.cancel()
            _state.update { current ->
                if (id !in current.entries) current else current.copy(entries = current.entries - id)
            }
        }
    }

    fun clearAll() {
        synchronized(lock) {
            if (jobs.isEmpty() && _state.value.entries.isEmpty()) return
            jobs.values.forEach(Job::cancel)
            jobs.clear()
            _state.value = CompletionSettleState()
        }
    }
}
