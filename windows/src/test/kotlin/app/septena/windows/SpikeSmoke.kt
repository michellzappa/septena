package app.septena.windows

import app.septena.core.DayClock
import app.septena.core.TaskStatus
import app.septena.core.asTaskRecord
import app.septena.core.generated.RegistryDestinationIds
import kotlinx.coroutines.runBlocking
import java.io.IOException
import java.nio.file.Files
import java.time.Instant
import java.time.LocalDate

fun main() = runBlocking {
    val directory = Files.createTempDirectory("septena-windows-smoke-").toFile()
    val path = directory.resolve("tasks.db").toPath()
    val clock = object : DayClock {
        override fun now(): Instant = Instant.parse("2026-11-26T12:00:00Z")
        override fun today(): LocalDate = LocalDate.parse("2026-11-26")
    }
    val fixture = FixtureTransport(clock)
    try {
        val id = SpikeWorkspace(path, fixture, clock).use { workspace ->
            check(workspace.sync().pushedOperations == 0)
            val initial = workspace.lists("en")
            val inboxRow = initial.inbox.single()
            check(inboxRow.title == "Example task from sync") { "Initial pull failed" }
            check(initial.rows(RegistryDestinationIds.TODAY).isEmpty())
            check(initial.rows(RegistryDestinationIds.ANYTIME).single().id == inboxRow.id)
            val upcoming = initial.rows(RegistryDestinationIds.UPCOMING).single()
            check(upcoming.group?.key == "day:2026-11-27" && upcoming.group.title == "Tomorrow")
            fixture.online = false
            val task = workspace.add("Created offline")
            try {
                workspace.sync()
                error("Offline sync unexpectedly succeeded")
            } catch (expected: IOException) {
                check(expected.message == "Fixture is offline")
            }
            check(fixture.pushedCount() == 0)
            task.id
        }
        SpikeWorkspace(path, fixture, clock).use { workspace ->
            check(workspace.lists("en").inbox.single { it.id == id }.title == "Created offline") {
                "Offline task lost on reopen"
            }
            fixture.online = true
            check(workspace.sync().pushedOperations == 1) { "Outbox did not retry" }
            check(workspace.rejected().isEmpty())
            check(workspace.sync().pushedOperations == 0) { "Acknowledged write remained queued" }
            check(fixture.pushedCount() == 1) { "Fixture received duplicate writes" }
            checkNotNull(workspace.rename(id, "Renamed task"))
            check(workspace.lists("en").inbox.single { it.id == id }.title == "Renamed task")
            check(workspace.sync().pushedOperations == 1)
            checkNotNull(workspace.complete(id))
            check(workspace.lists("en").inbox.none { it.id == id })
            check(workspace.sync().pushedOperations == 1)
        }
        SpikeWorkspace(directory.resolve("peer.db").toPath(), fixture, clock).use { peer ->
            peer.sync()
            val task = checkNotNull(peer.task(id)).asTaskRecord()
            check(task.title == "Renamed task" && task.status == TaskStatus.DONE) { "Peer did not pull the edits" }
            check(peer.lists("en").rows(RegistryDestinationIds.ANYTIME).none { it.id == id })
        }
    } finally {
        check(directory.deleteRecursively()) { "SQLite files remained locked after close" }
    }
    println("Windows spike smoke passed: list membership, offline persistence, reconnect, edit, completion, peer pull, cleanup")
}
