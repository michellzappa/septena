package app.septena.windows

import kotlinx.coroutines.runBlocking
import java.io.IOException
import java.nio.file.Files

fun main() = runBlocking {
    val directory = Files.createTempDirectory("septena-windows-smoke-").toFile()
    val path = directory.resolve("tasks.db").toPath()
    val fixture = FixtureTransport()
    try {
        val id = SpikeWorkspace(path, fixture).use { workspace ->
            check(workspace.sync().pushedOperations == 0)
            check(workspace.tasks().single().title == "Example task from sync") { "Initial pull failed" }
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
        SpikeWorkspace(path, fixture).use { workspace ->
            check(workspace.tasks().single { it.id == id }.title == "Created offline") { "Offline task lost on reopen" }
            fixture.online = true
            check(workspace.sync().pushedOperations == 1) { "Outbox did not retry" }
            check(workspace.rejected().isEmpty())
            check(workspace.sync().pushedOperations == 0) { "Acknowledged write remained queued" }
            check(fixture.pushedCount() == 1) { "Fixture received duplicate writes" }
        }
        SpikeWorkspace(directory.resolve("peer.db").toPath(), fixture).use { peer ->
            peer.sync()
            check(peer.tasks().single { it.id == id }.title == "Created offline") { "Peer did not pull the task" }
        }
    } finally {
        check(directory.deleteRecursively()) { "SQLite files remained locked after close" }
    }
    println("Windows spike smoke passed: pull, offline persistence, reopen, reconnect, peer pull, cleanup")
}
