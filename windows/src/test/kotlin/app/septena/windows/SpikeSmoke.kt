package app.septena.windows

import app.septena.core.DayClock
import app.septena.core.TaskStatus
import app.septena.core.asTaskRecord
import app.septena.core.generated.RegistryDestinationIds
import kotlinx.coroutines.runBlocking
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
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
        checkPlaceParity(directory.toPath(), clock)
    } finally {
        check(directory.deleteRecursively()) { "SQLite files remained locked after close" }
    }
    println("Windows spike smoke passed: list membership, offline persistence, edit, completion, places, sections, filing, peer pull, cleanup")
}

private suspend fun checkPlaceParity(directory: Path, clock: DayClock) {
    val fixture = FixtureTransport(clock)
    val path = directory.resolve("places.db")
    val (area, project, section) = SpikeWorkspace(path, fixture, clock).use { workspace ->
        workspace.sync()
        val seeded = workspace.lists("en").places
        check(seeded.outline().map { it.title } == listOf("Example area", "Example project", "Example section"))

        fixture.online = false
        val area = workspace.addArea("Work")
        val project = workspace.addProject("Ship the Windows client", area)
        val section = workspace.addSection("Validation", project)
        val areaTask = workspace.add("Triage feedback", area)
        val projectTask = workspace.add("Update the project", project)
        val sectionTask = workspace.add("Run checks", section)
        check(workspace.lists("en").rows(area).single().id == areaTask.id)
        check(workspace.lists("en").rows(section).single().id == sectionTask.id)

        val wrongProject = (seeded.projects.single().location as DesktopLocation.Project).id
        val invalidSection = DesktopLocation.Section(wrongProject, section.id)
        val invalidMove = runCatching { workspace.move(areaTask.id, invalidSection) }
        check(invalidMove.exceptionOrNull() is IllegalArgumentException)
        check(workspace.lists("en").rows(area).single().id == areaTask.id)

        workspace.move(areaTask.id, section)
        workspace.move(sectionTask.id, project)
        workspace.renamePlace(area, "Team")
        workspace.renamePlace(project, "Windows delivery")
        workspace.renamePlace(section, "Verification")

        val lists = workspace.lists("en")
        check(lists.rows(area).isEmpty())
        check(lists.rows(project).map { it.id }.toSet() == setOf(areaTask.id, projectTask.id, sectionTask.id))
        check(lists.rows(project).single { it.id == areaTask.id }.group?.title == "Verification")
        check(lists.rows(project).single { it.id == sectionTask.id }.group == null)
        check(lists.rows(RegistryDestinationIds.ANYTIME).none { it.id == section.id })
        Triple(area, project, section)
    }
    SpikeWorkspace(path, fixture, clock).use { workspace ->
        check(workspace.lists("en").places.place(section)?.title == "Verification")
        fixture.online = true
        check(workspace.sync().pushedOperations > 0)
        check(workspace.sync().pushedOperations == 0)
        check(workspace.rejected().isEmpty())
    }
    SpikeWorkspace(directory.resolve("places-peer.db"), fixture, clock).use { peer ->
        peer.sync()
        val lists = peer.lists("en")
        check(lists.places.place(area)?.title == "Team")
        check(lists.places.place(project)?.areaId == area.id)
        check(lists.places.place(project)?.title == "Windows delivery")
        check(lists.places.place(section)?.title == "Verification")
        check(lists.rows(section).single().title == "Triage feedback")
        check(lists.rows(area).isEmpty())
        check(lists.rows(project).map { it.title }.toSet() == setOf("Run checks", "Update the project", "Triage feedback"))
    }
}
