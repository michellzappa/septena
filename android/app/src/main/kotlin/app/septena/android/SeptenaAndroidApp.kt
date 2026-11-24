package app.septena.android

import android.app.Application
import app.cash.sqldelight.driver.android.AndroidSqliteDriver
import app.septena.android.auth.AppCredentials
import app.septena.android.auth.SessionStore
import app.septena.android.sync.SyncController
import app.septena.core.ConversationMutator
import app.septena.core.ConversationRules
import app.septena.core.RecurrenceRules
import app.septena.core.RegistryEntityMutator
import app.septena.core.SyncedSettings
import app.septena.core.SyncedSettingsMutator
import app.septena.core.SystemDayClock
import app.septena.core.TaskMutator
import app.septena.core.TaskSyncEngine
import app.septena.core.UuidTaskIdGenerator
import app.septena.core.generated.RegistryEntityNames
import app.septena.store.SqlDelightTaskStore
import app.septena.store.db.SeptenaDatabase
import app.septena.transport.SeptenaAccessClient
import app.septena.transport.SeptenaAuthClient
import app.septena.transport.UrlConnectionSyncTransport
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

class SeptenaAndroidApp : Application() {
    val graph: AndroidAppGraph by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        AndroidAppGraph(this)
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
    val registryEntityMutator = RegistryEntityMutator(taskStore, clock, ids)
    val conversationMutator = ConversationMutator(taskStore, ids)
    val recurrenceRules = RecurrenceRules
    val conversationRules = ConversationRules
    val syncedSettings = SyncedSettings(taskStore)
    val syncedSettingsMutator = SyncedSettingsMutator(taskStore, ids)

    val auth = SeptenaAuthClient(clientVersion)
    val credentials = AppCredentials(SessionStore(application), auth)
    private val transport = UrlConnectionSyncTransport(credentials, clientVersion)
    val access = SeptenaAccessClient(credentials, clientVersion)
    val sync = SyncController(TaskSyncEngine(taskStore, transport, clock), appScope)

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
}
