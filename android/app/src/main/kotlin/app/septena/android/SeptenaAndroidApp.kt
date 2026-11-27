package app.septena.android

import android.app.Application
import app.cash.sqldelight.driver.android.AndroidSqliteDriver
import app.septena.android.auth.AppCredentials
import app.septena.android.auth.LastAccountStore
import app.septena.android.auth.SessionStore
import app.septena.android.doing.DoController
import app.septena.android.reminders.TaskReminderScheduler
import app.septena.android.sync.SyncController
import app.septena.android.sync.SyncLiveCoordinator
import app.septena.android.ui.AppearanceStore
import app.septena.core.ConversationMutator
import app.septena.core.ConversationRules
import app.septena.core.DoSessionMutator
import app.septena.core.JsonValue
import app.septena.core.RecurrenceRules
import app.septena.core.RegistryEntityMutator
import app.septena.core.ReviewGroupIds
import app.septena.core.SyncRecord
import app.septena.core.SyncedSettings
import app.septena.core.SyncedSettingsMutator
import app.septena.core.SystemDayClock
import app.septena.core.TaskConversation
import app.septena.core.TaskMutator
import app.septena.core.TaskUndoHistory
import app.septena.core.TaskRefAddResult
import app.septena.core.TaskRefLookup
import app.septena.core.TaskRefMutator
import app.septena.core.TaskSnapshot
import app.septena.core.TaskSyncEngine
import app.septena.core.TaskTouchRules
import app.septena.core.TaskViewRules
import app.septena.core.UuidTaskIdGenerator
import app.septena.core.WireTimestamp
import app.septena.core.booleanValue
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.generated.RegistrySettingKeys
import app.septena.store.SqlDelightTaskStore
import app.septena.store.db.SeptenaDatabase
import app.septena.transport.SeptenaAccessClient
import app.septena.transport.SeptenaAuthClient
import app.septena.transport.SeptenaShareClient
import app.septena.transport.SeptenaSupportClient
import app.septena.transport.SeptenaTaskBackendClient
import app.septena.transport.SyncLiveSocket
import app.septena.transport.UrlConnectionSyncTransport
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class SeptenaAndroidApp : Application() {
    val graph: AndroidAppGraph by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        AndroidAppGraph(this)
    }

    override fun onCreate() {
        super.onCreate()
        // Start warming registries and the active-task SQLite cache before Activity.onCreate.
        graph.prewarm()
    }
}

class AndroidAppGraph(application: Application) {
    private val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    /** `X-Septena-Version`: "<marketing> (<build>)", the same form as iOS and Mac. */
    private val clientVersion: String = runCatching {
        val info = application.packageManager.getPackageInfo(application.packageName, 0)
        "${info.versionName ?: "0.0.0"} (${info.longVersionCode})"
    }.getOrNull() ?: "0.0.0 (0)"

    private val driver = AndroidSqliteDriver(
        schema = SeptenaDatabase.Schema,
        context = application,
        name = "septena-android.db",
    )
    val taskStore = SqlDelightTaskStore(driver)
    val clock = SystemDayClock()
    val ids = UuidTaskIdGenerator()
    val doSessions = DoSessionMutator(taskStore, clock, ids)
    val taskMutator = TaskMutator(taskStore, clock, ids, doSessions)
    val taskUndoHistory = TaskUndoHistory()
    val deviceSettings = app.septena.android.ui.AndroidDeviceSettings(application)
    val filingSuggestions = app.septena.android.ui.FilingSuggestionEngine(application)
    val registryEntityMutator = RegistryEntityMutator(taskStore, clock, ids)
    val taskRefMutator = TaskRefMutator(taskStore, clock, ids)
    val taskRefLookup = TaskRefLookup(taskStore)
    val conversationMutator = ConversationMutator(taskStore, ids)
    val recurrenceRules = RecurrenceRules
    val conversationRules = ConversationRules
    val syncedSettings = SyncedSettings(taskStore)
    val syncedSettingsMutator = SyncedSettingsMutator(taskStore, ids)
    val fadeSweepStore = app.septena.android.ui.FadeSweepStore(application, syncedSettings, syncedSettingsMutator)

    val auth = SeptenaAuthClient(clientVersion)
    val credentials = AppCredentials(
        SessionStore(application),
        auth,
        LastAccountStore(application),
        beforeAdopt = ::finishPendingWipe,
    )
    private val transport = UrlConnectionSyncTransport(credentials, clientVersion)
    val access = SeptenaAccessClient(credentials, clientVersion)
    val shares = SeptenaShareClient(access)
    /** Contact Support (ADR 0054): the client and this device's support key. */
    val support = SeptenaSupportClient(credentials, clientVersion)
    val supportKeys = app.septena.android.auth.SupportKeyStore(application)
    val taskBackend = SeptenaTaskBackendClient(credentials, clientVersion)
    val attachments = TaskAttachmentStore(application, taskStore, registryEntityMutator, clock, taskBackend)
    val accountWipe = AccountWipe(application, taskStore, attachments, taskUndoHistory)
    val sync = SyncController(TaskSyncEngine(taskStore, transport, clock), appScope, afterSync = ::afterSync)
    private val liveSocket = SyncLiveSocket(credentials, clientVersion)
    val liveSync = SyncLiveCoordinator(
        sync = sync,
        signedIn = credentials.signedIn,
        currentCursor = { taskStore.syncCursor() },
        connectSocket = liveSocket::connectAndListen,
        scope = appScope,
    )
    val appearance = AppearanceStore(deviceSettings, syncedSettings, syncedSettingsMutator, sync, clock, appScope)
    val firstRun = FirstRunState(application, taskStore, syncedSettings, syncedSettingsMutator, clock)

    /** One-shot OIDC callback from `septask://auth/callback?oidc_code=...` (ADR 0047). */
    data class OidcCallback(val code: String?, val error: String?)
    val pendingOidcCallback = kotlinx.coroutines.flow.MutableStateFlow<OidcCallback?>(null)

    /** Finishes the wipe of a deleted account that failed earlier (`AccountWipe`); nothing to do otherwise. */
    suspend fun finishPendingWipe() {
        if (accountWipe.finishIfPending()) sync.noteLocalChange()
    }

    /** The app day the fade pass last ran in this process. */
    @Volatile private var lastFadePassDay: String? = null
    private val prewarmed = java.util.concurrent.atomic.AtomicBoolean(false)

    /** Starts warming startup registries and active-task caches in parallel with Compose's first frame. */
    fun prewarm() {
        if (!prewarmed.compareAndSet(false, true)) return
        appScope.launch(Dispatchers.Default) {
            runCatching { app.septena.core.RegistryCatalog.prewarmStartup() }
        }
        appScope.launch(Dispatchers.IO) {
            runCatching {
                taskStore.activeTasks()
                taskStore.records(RegistryEntityNames.AREA)
                taskStore.records(RegistryEntityNames.PROJECT)
                taskStore.records(RegistryEntityNames.CONVO)
                taskStore.allTurnsByTask()
                taskStore.records(RegistryEntityNames.CHECKLIST_ITEM)
                taskStore.records(RegistryEntityNames.TASK_REF)
                taskStore.records(RegistryEntityNames.DO_SESSION)
                taskStore.records(RegistryEntityNames.TAG)
            }
        }
    }

    /**
     * After each sync: attachment uploads, then the daily fade pass once per
     * app day (docs/TASK_FADE_SPEC.md §4, as iOS runFadePassIfDue). The pass
     * runs after a pull, so it sees other devices' touches first, and only
     * while "Fade inactive tasks" is on. A skipped or failed pass tries again
     * after the next sync. True asks for one more sync, which pushes what the
     * pass or the uploads changed.
     */
    private suspend fun afterSync(): Boolean {
        val uploads = attachments.afterSync()
        if (!credentials.signedIn.value) return uploads
        val changed = moveFadeSettingToAccount() || uploads
        val day = clock.today(clock.now()).toString()
        if (lastFadePassDay == day || !fadesInactiveTasks()) return changed
        val faded = taskMutator.runFadePass(conversations())
        lastFadePassDay = day
        return changed || faded > 0
    }

    /** Every task's conversation, by task id. */
    suspend fun conversations(): Map<String, TaskConversation> {
        val turnsByTask = taskStore.allTurnsByTask()
        return taskStore.records(RegistryEntityNames.CONVO)
            .filter { it.deletedAt == null }
            .mapNotNull { r -> runCatching { r.id to TaskConversation.from(r, turnsByTask[r.id].orEmpty()) }.getOrNull() }
            .toMap()
    }

    /**
     * Settings ▸ "Fade inactive tasks" (`tasksShowAging`), one setting per account. A device that had
     * it off before it synced keeps it off until [moveFadeSettingToAccount] ran.
     */
    suspend fun fadesInactiveTasks(): Boolean {
        val key = RegistrySettingKeys.TASKS_SHOW_AGING
        if (syncedSettings.rawValue(key) == null && deviceSettings.storedBool(key) == false) return false
        return syncedSettings.value(key).booleanValue() ?: true
    }

    /**
     * Moves this device's old `tasksShowAging` to the account, once: an explicit off is pushed when the
     * account has no value yet. Runs after a pull, so it never overrides another device's choice.
     */
    private suspend fun moveFadeSettingToAccount(): Boolean {
        val key = RegistrySettingKeys.TASKS_SHOW_AGING
        val stored = deviceSettings.storedBool(key) ?: return false
        val pushes = !stored && syncedSettings.rawValue(key) == null
        if (pushes) syncedSettingsMutator.set(key, JsonValue.BooleanValue(false))
        deviceSettings.forget(key)
        return pushes
    }

    val reminders = TaskReminderScheduler(application, taskStore)
    val completionSettle = app.septena.android.ui.CompletionSettleStore(appScope)
    val doing = DoController(
        context = application,
        store = taskStore,
        sessions = doSessions,
        tasks = taskMutator,
        clock = clock,
        sync = sync,
        reminders = reminders,
        scope = appScope,
        captureTaskEdit = { id, write -> captureTaskEdit(id, mutation = write) },
        completeTask = ::completeTask,
    ).also { it.start() }

    /** Runs a write that must outlive the screen that asked for it. */
    fun launch(write: suspend () -> Unit) {
        appScope.launch(Dispatchers.IO) { runCatching { write() } }
    }

    init {
        // Timed reminders follow the store: every sync and every local write
        // bumps dataVersion, and the alarms are armed again (#362). A burst of
        // bumps runs one reconcile; defer past initial boot so the UI loads first.
        appScope.launch {
            sync.dataVersion.collectLatest {
                delay(1500)
                runCatching { reminders.reconcile() }
                runCatching { app.septena.android.widgets.SeptenaWidgetUpdater.refreshAll(application) }
            }
        }
    }

    init {
        // Another account must not inherit this one's fade pass day or sweep state.
        appScope.launch {
            credentials.signedIn.collect { signedIn ->
                if (!signedIn) forgetAccountScopedState()
            }
        }
    }

    /** Drops the state that belongs to one account: on sign-out, and when another account replaces this one. */
    fun forgetAccountScopedState() {
        lastFadePassDay = null
        fadeSweepStore.forgetAccount()
    }

    /**
     * Wraps a user gesture's task write: it stamps the fade clock, and undo captures the edit and the
     * stamp as one step. Sync and background code call mutators directly and never enter this path.
     */
    suspend fun captureTaskEdit(taskId: String, touches: Boolean = true, mutation: suspend () -> Unit) =
        captureTaskEdits(listOf(taskId), touches) { mutation() }

    /**
     * A user gesture that Android does not undo (checklist, references, attachments, a conversation
     * turn): it stamps the fade clock and records nothing, so Undo never takes back only the stamp.
     */
    suspend fun touchTask(taskId: String) {
        taskMutator.touch(taskId)
    }

    /** The user adds a reference to a task that exists. */
    suspend fun addTaskRef(taskId: String, input: String): TaskRefAddResult {
        val result = taskRefMutator.add(taskId, input)
        if (result is TaskRefAddResult.Added) touchTask(taskId)
        return result
    }

    /** The fade clock of an edit that began at [before]; see [TaskTouchRules]. */
    private suspend fun stampTouch(before: SyncRecord?) {
        val after = before?.let { taskStore.record(RegistryEntityNames.TASK, it.id) } ?: return
        if (TaskTouchRules.stamps(before, after)) {
            taskMutator.touch(before.id, deferred = TaskTouchRules.isDefer(before, after))
        }
    }

    /**
     * Opening a faded task keeps it (docs/TASK_FADE_SPEC.md §4), as Faded ▸ Keep. False when the task
     * is not faded.
     */
    suspend fun keepFadedOnOpen(taskId: String): Boolean {
        val task = taskStore.record(RegistryEntityNames.TASK, taskId)?.let { TaskSnapshot.from(it) } ?: return false
        if (TaskViewRules.reviewGroup(task, conversationGroup = null) != ReviewGroupIds.FADED) return false
        captureTaskEdit(taskId) { taskMutator.keepFaded(taskId) }
        return true
    }

    init {
        // Remote attachment deletes drop the local row when sync applies them
        // (plan_pull_row drops non-task rows), so free the cached file here.
        taskStore.onRemoteDelete = { entity, id ->
            if (entity == RegistryEntityNames.ATTACHMENT) attachments.deleteLocalCopy(id)
        }
    }

    /**
     * Every way a user completes a task (checkbox, menu, selection, notification, widget, task page)
     * ends here, as one undo step. A task in Review is accepted (docs/REVIEW_SPEC.md §4): that also
     * acknowledges any MCP provenance and moves the conversation to `agent_assisted_done`. The store sets that end state on a plain completion too, so only a
     * conversation write here lets Undo put the task back in Review. False when nothing was open.
     */
    suspend fun completeTasks(taskIds: Collection<String>): Boolean {
        val edits = mutableListOf<TaskUndoHistory.Edit>()
        try {
            for (taskId in taskIds) {
                val convo = taskStore.record(RegistryEntityNames.CONVO, taskId)
                val inReview = convo != null && TaskConversation.needsHumanReview(convo)
                val edit = captureTaskAndConvo(taskId) {
                    if (!inReview) {
                        taskMutator.complete(taskId) != null
                    } else if (taskMutator.acceptReview(taskId) != null) {
                        conversationMutator.update(
                            taskId,
                            mapOf(
                                RegistryEntityFields.Convo.END_STATE to
                                    JsonValue.StringValue(RegistryEntityEnums.ConvoEndState.AGENT_ASSISTED_DONE),
                            ),
                        )
                        true
                    } else {
                        false
                    }
                }
                if (edit != null) edits += edit
            }
        } finally {
            withContext(NonCancellable) { taskUndoHistory.recordTaskAndConvoEdits(edits) }
        }
        return edits.isNotEmpty()
    }

    suspend fun completeTask(taskId: String): Boolean = completeTasks(listOf(taskId))

    /** Reopens a completed or cancelled task (e.g. unchecking during the completion settle window). */
    suspend fun reopenTask(taskId: String) {
        captureTaskEdit(taskId) { taskMutator.reopen(taskId) }
    }

    /** The task, with its fade clock, and its conversation around [write]; null when [write] did nothing. */
    private suspend fun captureTaskAndConvo(taskId: String, write: suspend () -> Boolean): TaskUndoHistory.Edit? {
        val beforeTask = taskStore.record(RegistryEntityNames.TASK, taskId) ?: return null
        val beforeConvo = taskStore.record(RegistryEntityNames.CONVO, taskId)
        if (!write()) return null
        stampTouch(beforeTask)
        return TaskUndoHistory.Edit(
            taskId = taskId,
            beforeTask = beforeTask,
            afterTask = taskStore.record(RegistryEntityNames.TASK, taskId),
            beforeConvo = beforeConvo,
            afterConvo = taskStore.record(RegistryEntityNames.CONVO, taskId),
        )
    }

    /**
     * One unified Send back (#412, #415): appends the user's note, reopens the
     * conversation for Claude, stamps the fade clock, and records a single undo
     * step restoring both task and conversation state.
     */
    suspend fun sendBackReview(taskId: String, note: String): Boolean {
        val clean = note.trim()
        if (clean.isEmpty()) return false
        val edit = captureTaskAndConvo(taskId) {
            conversationMutator.appendTurn(
                taskId,
                mapOf(
                    "role" to JsonValue.StringValue(RegistryEntityEnums.ConvoTurnRole.USER),
                    "step" to JsonValue.StringValue(RegistryEntityEnums.ConvoTurnStep.WORK),
                    "note" to JsonValue.StringValue(clean),
                    "ts" to JsonValue.StringValue(WireTimestamp.format(clock.now())),
                ),
            )
            conversationMutator.update(
                taskId,
                mapOf(
                    RegistryEntityFields.Convo.END_STATE to
                        JsonValue.StringValue(RegistryEntityEnums.ConvoEndState.OPEN),
                    RegistryEntityFields.Convo.END_STATE_NOTE to JsonValue.Null,
                    RegistryEntityFields.Convo.STOPPED_AT to JsonValue.Null,
                    RegistryEntityFields.Convo.ASSIGNEE to
                        JsonValue.StringValue(RegistryEntityEnums.ConvoAssignee.CLAUDE),
                ),
            )
            taskMutator.touch(taskId)
            true
        } ?: return false
        taskUndoHistory.recordTaskAndConvoEdits(listOf(edit))
        return true
    }

    /**
     * Runs one gesture's write on each of [taskIds], stamps their fade clocks and records the lot as
     * one undo step. [touches] is false for Let Go, which drops the task instead of keeping it. A write that throws stops the batch; the tasks already
     * written stay recorded, so Undo still reverts them.
     */
    suspend fun captureTaskEdits(
        taskIds: Collection<String>,
        touches: Boolean = true,
        mutation: suspend (String) -> Unit,
    ) {
        val edits = mutableListOf<Pair<SyncRecord?, SyncRecord?>>()
        try {
            for (taskId in taskIds) {
                val before = taskStore.record(RegistryEntityNames.TASK, taskId)
                mutation(taskId)
                if (touches) stampTouch(before)
                edits += before to taskStore.record(RegistryEntityNames.TASK, taskId)
            }
        } finally {
            withContext(NonCancellable) { taskUndoHistory.recordEdits(edits) }
        }
    }
}
