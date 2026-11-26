package app.septena.windows

import app.septena.core.DayClock
import app.septena.core.RecurrenceRule
import app.septena.core.RecurrenceRules
import app.septena.core.TaskStatus
import app.septena.core.asTaskRecord
import app.septena.core.generated.RegistryDestinationIds
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields.Task
import app.septena.core.booleanValue
import app.septena.core.stringValue
import app.septena.sharedcore.RescheduleMode
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
        checkTaskEditor(directory.toPath(), clock)
    } finally {
        check(directory.deleteRecursively()) { "SQLite files remained locked after close" }
    }
    println("Windows spike smoke passed: list membership, offline persistence, task edits, places, filing, editor undo, peer pull, cleanup")
}

private suspend fun checkTaskEditor(directory: Path, clock: DayClock) {
    val fixture = FixtureTransport(clock)
    val path = directory.resolve("editor.db")
    val id = "seedtask0001"
    val scheduled = clock.today().plusDays(1)
    val deadline = clock.today().plusDays(4)
    val weekly = RecurrenceRule(RegistryEntityEnums.RecurrenceUnit.WEEK, interval = 2, afterCompletion = false)
    SpikeWorkspace(path, fixture, clock).use { workspace ->
        workspace.sync()
        val original = checkNotNull(workspace.task(id)).asTaskRecord()
        val edited = workspace.saveText(original, "Plan the delivery", "Check the installer.\nRecord the result.")
        check(edited.title == "Plan the delivery")
        check(edited.fields[Task.NOTES].stringValue() == "Check the installer.\nRecord the result.")
        check(workspace.undo())
        val restored = checkNotNull(workspace.task(id)).asTaskRecord()
        check(restored.title == original.title && restored.fields[Task.NOTES].stringValue() == null)
        check(!workspace.undoState.value.canUndo)

        fixture.online = false
        workspace.saveText(restored, "Plan the delivery", "Keep the Win365 checklist.")
        workspace.setWhen(id, scheduled, RescheduleMode.MAKE_EXCEPTION)
        workspace.setDeadline(id, deadline)
        check(workspace.undo())
        val dateUndo = checkNotNull(workspace.task(id))
        check(dateUndo.fields[Task.SCHEDULED].stringValue() == scheduled.toString())
        check(dateUndo.fields[Task.DEADLINE].stringValue() == null)
        workspace.setDeadline(id, deadline)
        workspace.setRepeat(id, weekly, false)
        check(workspace.undo())
        check(RecurrenceRules.fromFields(checkNotNull(workspace.task(id)).fields) == null)
        val repeated = workspace.setRepeat(id, weekly, false)
        check(repeated.fields[Task.RECURRENCE_ANCHOR_DATE].stringValue() == scheduled.toString())
        workspace.setRepeat(id, weekly, true)
        check(workspace.undo())
        check(checkNotNull(workspace.task(id)).fields[Task.RECURRENCE_PAUSED].booleanValue() == false)

        val newDay = scheduled.plusDays(2)
        val exception = workspace.setWhen(id, newDay, RescheduleMode.MAKE_EXCEPTION)
        check(exception.fields[Task.SCHEDULED].stringValue() == newDay.toString())
        check(exception.fields[Task.RECURRENCE_ANCHOR_DATE].stringValue() == scheduled.toString())
        check(workspace.undo())
        val movedSeries = workspace.setWhen(id, newDay, RescheduleMode.UPDATE_RULE)
        check(movedSeries.fields[Task.RECURRENCE_ANCHOR_DATE].stringValue() == newDay.toString())
        check(workspace.undo())
        val ruleUndo = checkNotNull(workspace.task(id))
        check(ruleUndo.fields[Task.RECURRENCE_ANCHOR_DATE].stringValue() == scheduled.toString())
        check(ruleUndo.fields[Task.SCHEDULED].stringValue() == scheduled.toString())
        check(ruleUndo.fields[Task.DEADLINE].stringValue() == deadline.toString())
    }
    SpikeWorkspace(path, fixture, clock).use { workspace ->
        check(checkNotNull(workspace.task(id)).fields[Task.NOTES].stringValue() == "Keep the Win365 checklist.")
        fixture.online = true
        check(workspace.sync().pushedOperations > 0)
        check(workspace.rejected().isEmpty())
    }
    SpikeWorkspace(directory.resolve("editor-peer.db"), fixture, clock).use { peer ->
        peer.sync()
        val task = checkNotNull(peer.task(id)).asTaskRecord()
        check(task.title == "Plan the delivery")
        check(task.fields[Task.NOTES].stringValue() == "Keep the Win365 checklist.")
        check(task.fields[Task.SCHEDULED].stringValue() == scheduled.toString())
        check(task.fields[Task.DEADLINE].stringValue() == deadline.toString())
        check(RecurrenceRules.fromFields(task.fields) == weekly)
        check(task.fields[Task.RECURRENCE_PAUSED].booleanValue() == false)
    }
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
