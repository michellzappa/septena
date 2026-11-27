package app.septena.android.doing

import android.content.Context
import app.septena.android.reminders.TaskReminderScheduler
import app.septena.android.sync.SyncController
import app.septena.core.DayClock
import app.septena.core.DoResolution
import app.septena.core.DoRules
import app.septena.core.DoSessionMutator
import app.septena.core.TaskMutator
import app.septena.core.TaskStore
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.stringValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.time.Duration
import java.time.Instant

/** What the user does now. The task's title is a copy, so a surface can draw the notice without a read. */
data class DoState(
    val sessionId: String,
    val taskId: String,
    val title: String,
    val startedAt: Instant,
    val plannedMinutes: Int?,
    val plannedEnd: Instant?,
    val staleAt: Instant,
    val isStale: Boolean,
) {
    /**
     * The time a surface shows: up from the start, or down to the planned end,
     * then up again past it. Whole minutes.
     */
    fun minutes(now: Instant): Long = when {
        plannedEnd != null && now.isBefore(plannedEnd) -> (Duration.between(now, plannedEnd).toMillis() + 59_999) / 60_000
        else -> Duration.between(startedAt, now).toMinutes().coerceAtLeast(0)
    }
}

data class DoUiState(
    /** Null when nothing is done now. A stale Do is here too: its notice asks (§2.2). */
    val current: DoState? = null,
    /** The Do this device shows in full. Local, never synced (ADR 0041). */
    val fullSessionId: String? = null,
    /** The Do that just stopped here: the app offers "Where did you stop?". */
    val justStoppedSessionId: String? = null,
    /** The start of the Do that just ended here: the app says what came in since and needs the user. */
    val endedSince: Instant? = null,
) {
    /** This device shows the Do screen. */
    val isFullHere: Boolean get() = current != null && !current.isStale && current.sessionId == fullSessionId

    /** Another device started it, or this one after Show List. */
    val showsNotice: Boolean get() = current != null && !isFullHere
}

/**
 * The current Do and every gesture on it (docs/DO_SPEC.md). Reads the rows
 * through the core, and writes them through [DoSessionMutator].
 */
class DoController(
    private val context: Context,
    private val store: TaskStore,
    private val sessions: DoSessionMutator,
    private val tasks: TaskMutator,
    private val clock: DayClock,
    private val sync: SyncController,
    private val reminders: TaskReminderScheduler,
    private val scope: CoroutineScope,
    /** Records the task write of a gesture for Undo. */
    private val captureTaskEdit: suspend (String, suspend () -> Unit) -> Unit,
    /** Done for a task: the one completion path (a task in Review is accepted). */
    private val completeTask: suspend (String) -> Boolean,
) {
    private val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val lock = Mutex()
    private val _ui = MutableStateFlow(DoUiState(fullSessionId = prefs.getString(KEY_FULL, null)))
    private val _plannedEndReached = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    private var wake: Job? = null
    private var armed: DoState? = null
    private var armedOnce = false

    val ui: StateFlow<DoUiState> = _ui.asStateFlow()

    /** A planned length ended on the device that shows the Do. */
    val plannedEndReached: SharedFlow<Unit> = _plannedEndReached.asSharedFlow()

    /** False when the linked core has no Do rules: then no surface offers a start. */
    val isAvailable: Boolean by lazy { DoRules.resolve(emptyList(), clock.now()) != null }

    /** Follows every sync and every local write. */
    fun start() {
        scope.launch {
            // The first read loads the native core, so do it off the main thread.
            isAvailable
            sync.dataVersion.collect { runCatching { refresh() } }
        }
    }

    /** The app came to the front: the clock can have passed an end while it slept. */
    fun requestRefresh() {
        scope.launch { runCatching { refresh() } }
    }

    suspend fun refresh() = withContext(Dispatchers.IO) { lock.withLock { refreshLocked() } }

    private suspend fun refreshLocked() {
        val next = sessions.resolve()?.current?.let { stateOf(it) }
        val before = _ui.value
        _ui.update { ui ->
            ui.copy(
                current = next,
                fullSessionId = ui.fullSessionId?.takeIf { it == next?.sessionId },
                endedSince = ui.endedSince ?: before.current?.startedAt?.takeIf { before.isFullHere && next == null },
            )
        }
        saveFull()
        val full = _ui.value.let { if (it.isFullHere) it.current else null }
        armEndAlert(full)
        scheduleWake(next, signals = full != null)
    }

    private suspend fun stateOf(current: DoResolution.Current): DoState? {
        val session = sessions.session(current.id) ?: return null
        val task = store.record(RegistryEntityNames.TASK, session.taskId) ?: return null
        return DoState(
            sessionId = session.id,
            taskId = session.taskId,
            title = task.fields[RegistryEntityFields.Task.TITLE].stringValue().orEmpty(),
            startedAt = current.startedAt,
            plannedMinutes = session.plannedMinutes,
            plannedEnd = current.plannedEnd,
            staleAt = current.staleAt,
            isStale = current.isStale,
        )
    }

    // Gestures

    /** Starts a Do of an open task and shows it here. A Do that was open ends. */
    fun begin(taskId: String, onStarted: () -> Unit = {}) = gesture {
        val current = _ui.value.current
        val sessionId = if (current?.taskId == taskId && !current.isStale) {
            current.sessionId
        } else {
            sessions.begin(taskId, tasks) ?: return@gesture
        }
        _ui.update { it.copy(fullSessionId = sessionId, justStoppedSessionId = null, endedSince = null) }
        refreshLocked()
        withContext(Dispatchers.Main) { onStarted() }
    }

    /** Done is the existing complete action. The task mutator ends the Do. */
    fun done(doing: DoState) = gesture {
        completeTask(doing.taskId)
        _ui.update { it.copy(endedSince = doing.startedAt) }
    }

    /** Stop for now. Ends one Do by its id. */
    fun stop(doing: DoState) = gesture {
        if (!sessions.end(doing.sessionId, RegistryEntityEnums.DoExit.STOPPED)) return@gesture
        _ui.update { it.copy(justStoppedSessionId = doing.sessionId, endedSince = doing.startedAt) }
    }

    /** Only a saved date ends the Do. Clear changes the task and the Do goes on. */
    fun later(
        doing: DoState,
        day: String?,
        mode: app.septena.sharedcore.RescheduleMode = app.septena.sharedcore.RescheduleMode.MAKE_EXCEPTION,
    ) = gesture {
        var saved = false
        captureTaskEdit(doing.taskId) { saved = tasks.setWhen(doing.taskId, day, mode) != null }
        if (!saved || day == null) return@gesture
        sessions.end(doing.sessionId, RegistryEntityEnums.DoExit.LATER)
        _ui.update { it.copy(endedSince = doing.startedAt) }
    }

    /** The stale question's Still on It. */
    fun confirm(doing: DoState) = gesture { sessions.confirm(doing.sessionId) }

    /** Null counts up. */
    fun setLength(doing: DoState, minutes: Int?) = gesture { sessions.setLength(doing.sessionId, minutes) }

    /** The answer to "Where did you stop?". Null closes the question. */
    fun answerStopNote(note: String?) {
        val sessionId = _ui.value.justStoppedSessionId ?: return
        _ui.update { it.copy(justStoppedSessionId = null) }
        if (!note.isNullOrBlank()) gesture { sessions.setNote(sessionId, note) }
    }

    fun dismissNeedsYou() = _ui.update { it.copy(endedSince = null) }

    /** Do Here: this device becomes the full one. */
    fun showHere() = setFull(_ui.value.current?.takeUnless { it.isStale }?.sessionId)

    /** Show List. The Do goes on, and this device shows the notice. */
    fun showList() = setFull(null)

    private fun setFull(sessionId: String?) {
        _ui.update { it.copy(fullSessionId = sessionId) }
        saveFull()
        requestRefresh()
    }

    private fun saveFull() {
        prefs.edit().putString(KEY_FULL, _ui.value.fullSessionId).apply()
    }

    private fun gesture(write: suspend () -> Unit) {
        scope.launch(Dispatchers.IO) {
            runCatching {
                lock.withLock {
                    write()
                    refreshLocked()
                }
            }
            sync.noteLocalChange()
            sync.requestSync()
        }
    }

    // Clock

    /** One wake at the next instant that changes the state: the planned end or the stale limit. */
    private fun scheduleWake(current: DoState?, signals: Boolean) {
        wake?.cancel()
        if (current == null || current.isStale) return
        val now = clock.now()
        val planned = current.plannedEnd?.takeIf { it.isAfter(now) }
        val next = if (planned != null && planned.isBefore(current.staleAt)) planned else current.staleAt
        wake = scope.launch {
            delay(Duration.between(now, next).toMillis().coerceAtLeast(0) + WAKE_SLACK_MS)
            if (signals && next == planned) _plannedEndReached.tryEmit(Unit)
            // A new job: this one is cancelled by the refresh that it starts.
            requestRefresh()
        }
    }

    /** Arms the one local notification at the planned end, on this device only. */
    private fun armEndAlert(full: DoState?) {
        if (full == armed && armedOnce) return
        armedOnce = true
        armed = full
        val end = full?.plannedEnd
        when {
            end == null -> reminders.cancelDoEnd()
            end.isAfter(clock.now()) -> reminders.armDoEnd(full.sessionId, end)
        }
    }

    /** The alarm went off: post the notification when the Do is still full here. */
    suspend fun firePlannedEnd(sessionId: String) {
        refresh()
        val doing = _ui.value.takeIf { it.isFullHere }?.current?.takeIf { it.sessionId == sessionId } ?: return
        val end = doing.plannedEnd ?: return
        val minutes = doing.plannedMinutes ?: return
        if (end.isAfter(clock.now().plusSeconds(1))) return
        val languageTag = context.resources.configuration.locales[0].toLanguageTag()
        reminders.postDoEnd(doing.title, DoCopy(languageTag).plannedEnd(minutes), end)
    }

    private companion object {
        const val PREFS = "septena.do"
        const val KEY_FULL = "fullSession"
        const val WAKE_SLACK_MS = 200L
    }
}
