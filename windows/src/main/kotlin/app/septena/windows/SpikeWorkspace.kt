package app.septena.windows

import app.cash.sqldelight.driver.jdbc.sqlite.JdbcSqliteDriver
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
import app.septena.core.asTaskRecord
import app.septena.core.generated.RegistryEntityNames
import app.septena.store.SqlDelightTaskStore
import app.septena.store.db.SeptenaDatabase
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path

internal class SpikeWorkspace(path: Path, transport: FixtureTransport) : AutoCloseable {
    private val driver = openDatabase(path)
    private val store = SqlDelightTaskStore(SeptenaDatabase(driver))
    private val clock = SystemDayClock()
    private val mutator = TaskMutator(store, clock, UuidTaskIdGenerator(), sourceClient = "Septena Windows")
    private val syncEngine = TaskSyncEngine(store, transport, clock)

    suspend fun tasks() = store.activeTasks().map { it.asTaskRecord() }
    suspend fun add(title: String) = mutator.create(title)
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
internal class FixtureTransport : SyncTransport {
    var online = true
    private val clock = SystemDayClock()
    private val changes = mutableListOf(
        taskChange(
            "seedtask0001",
            TaskRecord.createFields(
                title = "Example task from sync",
                created = clock.today().toString(),
                createdAt = WireTimestamp.format(clock.now()),
                sourceClient = "Spike fixture",
            ),
        ),
    )
    private val results = mutableMapOf<String, SyncOperationResult>()

    fun pushedCount() = results.size

    override suspend fun push(operations: List<SyncOperation>): SyncPushResponse {
        if (!online) throw IOException("Fixture is offline")
        val applied = operations.map { operation ->
            results.getOrPut(operation.clientOpId) {
                check(operation is SyncOperation.Upsert && operation.entity == RegistryEntityNames.TASK)
                changes += taskChange(operation.id, operation.fields)
                SyncOperationResult(operation.clientOpId, SyncResultStatus.APPLIED, 1, changes.size.toLong())
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

    private fun taskChange(id: String, fields: Map<String, JsonValue>) = SyncChange(
        RegistryEntityNames.TASK,
        fields + mapOf("id" to JsonValue.StringValue(id), "rev" to JsonValue.IntegerValue(1)),
    )
}
