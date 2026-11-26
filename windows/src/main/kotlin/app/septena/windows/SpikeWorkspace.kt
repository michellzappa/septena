package app.septena.windows

import app.cash.sqldelight.driver.jdbc.sqlite.JdbcSqliteDriver
import app.septena.core.DayClock
import app.septena.core.JsonValue
import app.septena.core.SyncChange
import app.septena.core.SyncOperation
import app.septena.core.SyncOperationResult
import app.septena.core.SyncPullPage
import app.septena.core.SyncPushResponse
import app.septena.core.SyncResultStatus
import app.septena.core.SyncTransport
import app.septena.core.SystemDayClock
import app.septena.core.TaskMutator
import app.septena.core.TaskRecord
import app.septena.core.TaskSyncEngine
import app.septena.core.UuidTaskIdGenerator
import app.septena.core.WireTimestamp
import app.septena.core.generated.RegistryEntityNames
import app.septena.store.SqlDelightTaskStore
import app.septena.store.db.SeptenaDatabase
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path

internal class SpikeWorkspace(
    path: Path,
    transport: FixtureTransport,
    private val clock: DayClock = SystemDayClock(),
) : AutoCloseable {
    private val driver = openDatabase(path)
    private val store = SqlDelightTaskStore(SeptenaDatabase(driver))
    private val mutator = TaskMutator(store, clock, UuidTaskIdGenerator(), sourceClient = "Septena Windows")
    private val syncEngine = TaskSyncEngine(store, transport, clock)

    suspend fun lists(languageTag: String) = desktopTaskLists(store.activeTasks(), clock, languageTag)
    suspend fun task(id: String) = store.record(RegistryEntityNames.TASK, id)
    suspend fun add(title: String, today: Boolean = false) = mutator.create(title, today = today)
    suspend fun rename(id: String, title: String) = mutator.rename(id, title)
    suspend fun complete(id: String) = mutator.complete(id)
    suspend fun sync() = syncEngine.sync()
    suspend fun rejected() = store.notSyncedOperations()

    override fun close() = driver.close()
}

private fun openDatabase(path: Path): JdbcSqliteDriver {
    val create = Files.notExists(path)
    val driver = JdbcSqliteDriver("jdbc:sqlite:${path.toAbsolutePath()}")
    try {
        if (create) SeptenaDatabase.Schema.create(driver)
        return driver
    } catch (failure: Throwable) {
        driver.close()
        throw failure
    }
}

/** In-process fixture. Its rows, acknowledgements, and connectivity stay inside the spike. */
internal class FixtureTransport(clock: DayClock = SystemDayClock()) : SyncTransport {
    var online = true
    private val changes = mutableListOf<SyncChange>()
    private val tasks = mutableMapOf<String, TaskRecord>()
    private val results = mutableMapOf<String, SyncOperationResult>()

    init {
        val now = clock.now()
        val today = clock.today(now)
        val stamp = WireTimestamp.format(now)
        listOf(
            TaskRecord("seedtask0001", TaskRecord.createFields(
                title = "Example task from sync",
                created = today.toString(),
                createdAt = stamp,
                sourceClient = "Spike fixture",
            ), revision = 1),
            TaskRecord("seedtask0002", TaskRecord.createFields(
                title = "Example scheduled task",
                created = today.toString(),
                createdAt = stamp,
                scheduled = today.plusDays(1).toString(),
                sourceClient = "Spike fixture",
            ), revision = 1),
        ).forEach(::recordTask)
    }

    fun pushedCount() = results.size

    override suspend fun push(operations: List<SyncOperation>): SyncPushResponse {
        if (!online) throw IOException("Fixture is offline")
        val applied = operations.map { operation ->
            results.getOrPut(operation.clientOpId) {
                check(operation is SyncOperation.Upsert && operation.entity == RegistryEntityNames.TASK)
                val previous = tasks[operation.id]
                val revision = (previous?.revision ?: 0L) + 1L
                recordTask(TaskRecord(operation.id, previous?.fields.orEmpty() + operation.fields, revision))
                SyncOperationResult(operation.clientOpId, SyncResultStatus.APPLIED, revision, changes.size.toLong())
            }
        }
        return SyncPushResponse(changes.size.toLong(), applied)
    }

    override suspend fun pull(
        since: Long,
        limit: Int,
        includeSettings: Boolean,
        includeChecklists: Boolean,
        includeTags: Boolean,
        includeRefs: Boolean,
        includeDoSessions: Boolean,
    ): SyncPullPage {
        if (!online) throw IOException("Fixture is offline")
        val page = changes.drop(since.toInt()).take(limit)
        val next = since + page.size
        return SyncPullPage(changes = page, nextSince = next, hasMore = next < changes.size)
    }

    private fun recordTask(task: TaskRecord) {
        tasks[task.id] = task
        changes += SyncChange(
            RegistryEntityNames.TASK,
            task.fields + mapOf(
                "id" to JsonValue.StringValue(task.id),
                "rev" to JsonValue.IntegerValue(requireNotNull(task.revision)),
            ),
        )
    }
}
