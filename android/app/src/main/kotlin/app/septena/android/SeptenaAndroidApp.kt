package app.septena.android

import android.app.Application
import app.cash.sqldelight.driver.android.AndroidSqliteDriver
import app.septena.android.auth.AppCredentials
import app.septena.android.auth.SessionStore
import app.septena.android.reminders.TaskReminderScheduler
import app.septena.android.sync.SyncController
import app.septena.android.ui.AppearanceStore
import app.septena.core.ConversationMutator
import app.septena.core.ConversationRules
import app.septena.core.JsonValue
import app.septena.core.RecurrenceRules
import app.septena.core.RegistryEntityMutator
import app.septena.core.SyncRecord
import app.septena.core.SyncedSettings
import app.septena.core.SyncedSettingsMutator
import app.septena.core.SystemDayClock
import app.septena.core.TaskConversation
import app.septena.core.TaskMutator
import app.septena.core.TaskRefLookup
import app.septena.core.TaskRefMutator
import app.septena.core.TaskSyncEngine
import app.septena.core.UuidTaskIdGenerator
import app.septena.core.WireTimestamp
import app.septena.core.asSyncRecord
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import app.septena.store.SqlDelightTaskStore
import app.septena.store.db.SeptenaDatabase
import app.septena.transport.SeptenaAccessClient
import app.septena.transport.SeptenaAuthClient
import app.septena.transport.SeptenaShareClient
import app.septena.transport.SeptenaTaskBackendClient
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
    private val clientVersion: String = runCatching {
        application.packageManager.getPackageInfo(application.packageName, 0).versionName
    }.getOrNull() ?: "0.0.0"

    private val driver = AndroidSqliteDriver(
        schema = SeptenaDatabase.Schema,
        context = application,
        name = "septena-android.db",
    )
    val taskStore = SqlDelightTaskStore(driver)
    val clock = SystemDayClock()
    val ids = UuidTaskIdGenerator()
    val taskMutator = TaskMutator(taskStore, clock, ids)
    val taskUndoHistory = TaskUndoHistory()
    val deviceSettings = app.septena.android.ui.AndroidDeviceSettings(application)
    val filingSuggestions = app.septena.android.ui.FilingSuggestionEngine(application)
    val fadeSweepStore = app.septena.android.ui.FadeSweepStore(application)
    val registryEntityMutator = RegistryEntityMutator(taskStore, clock, ids)
    val taskRefMutator = TaskRefMutator(taskStore, clock, ids)
    val taskRefLookup = TaskRefLookup(taskStore)
    val conversationMutator = ConversationMutator(taskStore, ids)
    val recurrenceRules = RecurrenceRules
    val conversationRules = ConversationRules
    val syncedSettings = SyncedSettings(taskStore)
    val syncedSettingsMutator = SyncedSettingsMutator(taskStore, ids)

    val auth = SeptenaAuthClient(clientVersion)
    val credentials = AppCredentials(SessionStore(application), auth, beforeAdopt = ::finishPendingWipe)
    private val transport = UrlConnectionSyncTransport(credentials, clientVersion)
    val access = SeptenaAccessClient(credentials, clientVersion)
    val shares = SeptenaShareClient(access)
    val taskBackend = SeptenaTaskBackendClient(credentials, clientVersion)
    val attachments = TaskAttachmentStore(application, taskStore, registryEntityMutator, clock, taskBackend)
    val accountWipe = AccountWipe(application, taskStore, attachments, taskUndoHistory)
    val sync = SyncController(TaskSyncEngine(taskStore, transport, clock), appScope, afterSync = ::afterSync)
    val appearance = AppearanceStore(deviceSettings, syncedSettings, syncedSettingsMutator, sync, clock, appScope)
    val firstRun = FirstRunState(application, taskStore, syncedSettings, syncedSettingsMutator, clock)

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
                taskStore.records(RegistryEntityNames.TAG)
            }
        }
    }

    /**
     * After each sync: attachment uploads, then the daily fade pass once per
     * app day (docs/TASK_FADE_SPEC.md §4, as iOS runFadePassIfDue). The pass
     * runs after a pull, so it sees other devices' touches first. True asks
     * for one more sync, which pushes what the pass or the uploads changed.
     */
    private suspend fun afterSync(): Boolean {
        val uploads = attachments.afterSync()
        val day = clock.today(clock.now()).toString()
        if (lastFadePassDay == day) return uploads
        lastFadePassDay = day
        val turnsByTask = taskStore.allTurnsByTask()
        val conversations = taskStore.records(RegistryEntityNames.CONVO)
            .filter { it.deletedAt == null }
            .mapNotNull { r -> runCatching { r.id to TaskConversation.from(r, turnsByTask[r.id].orEmpty()) }.getOrNull() }
            .toMap()
        val faded = taskMutator.runFadePass(conversations)
        return uploads || faded > 0
    }

    val reminders = TaskReminderScheduler(application, taskStore)

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

    /**
     * Wraps a user gesture's task write so undo captures only that local edit.
     * Sync and background code call mutators directly and never enter this path.
     */
    suspend fun captureTaskEdit(taskId: String, mutation: suspend () -> Unit) {
        val before = taskStore.record(RegistryEntityNames.TASK, taskId)
        mutation()
        val after = taskStore.record(RegistryEntityNames.TASK, taskId)
        taskUndoHistory.recordEdit(before, after)
    }

    init {
        // Remote attachment deletes drop the local row when sync applies them
        // (plan_pull_row drops non-task rows), so free the cached file here.
        taskStore.onRemoteDelete = { entity, id ->
            if (entity == RegistryEntityNames.ATTACHMENT) attachments.deleteLocalCopy(id)
        }
    }

    /**
     * One unified Accept for both Review rows and the conversation card (#415):
     * completes the task, acknowledges any MCP provenance, stamps the fade clock,
     * moves the conversation to `agent_assisted_done`, and records a single undo
     * step that reverts both task and conversation fields.
     */
    suspend fun acceptReview(taskId: String): Boolean {
        val beforeTask = taskStore.record(RegistryEntityNames.TASK, taskId) ?: return false
        val beforeConvo = taskStore.record(RegistryEntityNames.CONVO, taskId)
        val completed = taskMutator.acceptReview(taskId) ?: return false
        conversationMutator.update(
            taskId,
            mapOf(
                RegistryEntityFields.Convo.END_STATE to
                    JsonValue.StringValue(RegistryEntityEnums.ConvoEndState.AGENT_ASSISTED_DONE),
            ),
        )
        val afterTask = taskStore.record(RegistryEntityNames.TASK, taskId) ?: completed.asSyncRecord()
        val afterConvo = taskStore.record(RegistryEntityNames.CONVO, taskId)
        taskUndoHistory.recordTaskAndConvoEdit(
            taskId = taskId,
            beforeTask = beforeTask,
            afterTask = afterTask,
            beforeConvo = beforeConvo,
            afterConvo = afterConvo,
        )
        return true
    }

    /**
     * One unified Send back (#412, #415): appends the user's note, reopens the
     * conversation for Claude, stamps the fade clock, and records a single undo
     * step restoring both task and conversation state.
     */
    suspend fun sendBackReview(taskId: String, note: String): Boolean {
        val clean = note.trim()
        if (clean.isEmpty()) return false
        val beforeTask = taskStore.record(RegistryEntityNames.TASK, taskId) ?: return false
        val beforeConvo = taskStore.record(RegistryEntityNames.CONVO, taskId)
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
        val afterTask = taskStore.record(RegistryEntityNames.TASK, taskId)
        val afterConvo = taskStore.record(RegistryEntityNames.CONVO, taskId)
        taskUndoHistory.recordTaskAndConvoEdit(
            taskId = taskId,
            beforeTask = beforeTask,
            afterTask = afterTask,
            beforeConvo = beforeConvo,
            afterConvo = afterConvo,
        )
        return true
    }

    /**
     * Runs one gesture's write on each of [taskIds] and records the lot as one
     * undo step. A write that throws stops the batch; the tasks already
     * written stay recorded, so Undo still reverts them.
     */
    suspend fun captureTaskEdits(taskIds: Collection<String>, mutation: suspend (String) -> Unit) {
        val edits = mutableListOf<Pair<SyncRecord?, SyncRecord?>>()
        try {
            for (taskId in taskIds) {
                val before = taskStore.record(RegistryEntityNames.TASK, taskId)
                mutation(taskId)
                edits += before to taskStore.record(RegistryEntityNames.TASK, taskId)
            }
        } finally {
            withContext(NonCancellable) { taskUndoHistory.recordEdits(edits) }
        }
    }
}
