package app.septena.windows

import app.cash.sqldelight.driver.jdbc.sqlite.JdbcSqliteDriver
import app.septena.core.DayClock
import app.septena.core.ConversationMutator
import app.septena.core.JsonValue
import app.septena.core.NotesBase
import app.septena.core.QuickFindSearch
import app.septena.core.RecurrenceRule
import app.septena.core.RegistryCatalog
import app.septena.core.RegistryEntityMutator
import app.septena.core.SyncChange
import app.septena.core.SyncOperation
import app.septena.core.SyncOperationResult
import app.septena.core.SyncPullPage
import app.septena.core.SyncPushResponse
import app.septena.core.SyncRecord
import app.septena.core.SyncResultStatus
import app.septena.core.SyncTransport
import app.septena.core.SyncedSettings
import app.septena.core.SyncedSettingsMutator
import app.septena.core.SystemDayClock
import app.septena.core.TaskConversation
import app.septena.core.TaskMutator
import app.septena.core.TaskRecord
import app.septena.core.TaskSnapshot
import app.septena.core.TaskSyncEngine
import app.septena.core.TaskUndoHistory
import app.septena.core.UuidTaskIdGenerator
import app.septena.core.WireTimestamp
import app.septena.core.asSyncRecord
import app.septena.core.asTaskRecord
import app.septena.core.booleanValue
import app.septena.core.generated.RegistryDestinationIds
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.generated.RegistryPlatformIds
import app.septena.core.generated.RegistrySettingKeys
import app.septena.core.stringValue
import app.septena.store.SqlDelightTaskStore
import app.septena.store.db.SeptenaDatabase
import app.septena.sharedcore.RescheduleMode
import java.util.Locale
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import java.time.LocalDate

internal class SpikeWorkspace(
    path: Path,
    transport: FixtureTransport,
    private val clock: DayClock = SystemDayClock(),
) : AutoCloseable {
    private val driver = openDatabase(path)
    private val store = SqlDelightTaskStore(SeptenaDatabase(driver))
    private val ids = UuidTaskIdGenerator()
    private val mutator = TaskMutator(store, clock, ids, sourceClient = "Septena Windows")
    private val entityMutator = RegistryEntityMutator(store, clock, ids)
    private val conversationMutator = ConversationMutator(store, ids)
    private val settings = SyncedSettings(store, RegistryPlatformIds.WINDOWS)
    private val settingsMutator = SyncedSettingsMutator(store, ids, RegistryPlatformIds.WINDOWS)
    private val syncEngine = TaskSyncEngine(store, transport, clock)
    private val undoHistory = TaskUndoHistory()
    val undoState = undoHistory.state

    suspend fun lists(languageTag: String): DesktopTaskLists {
        val records = store.activeTasks()
        val checked = store.records(RegistryEntityNames.TASK).filter {
            it.deletedAt == null &&
                it.fields[RegistryEntityFields.Task.STATUS].stringValue() == RegistryEntityEnums.TaskStatus.CHECKLIST_CHECKED
        }
        return desktopTaskLists(records, places(records), clock, languageTag, checked).copy(
            agentsPaused = settings.value(RegistrySettingKeys.AGENTS_PAUSED).booleanValue() == true,
        )
    }

    private suspend fun places(tasks: List<SyncRecord>? = null) =
        desktopPlaces(store.records(RegistryEntityNames.AREA), store.records(RegistryEntityNames.PROJECT), tasks ?: store.activeTasks())

    suspend fun task(id: String) = store.record(RegistryEntityNames.TASK, id)

    suspend fun conversation(id: String): DesktopConversation {
        val record = store.record(RegistryEntityNames.CONVO, id) ?: SyncRecord(RegistryEntityNames.CONVO, id, emptyMap())
        val turns = store.turns(id)
        return DesktopConversation(TaskConversation.from(record, turns), turns)
    }

    suspend fun changeConversation(id: String, edit: ConversationEdit) {
        val task = checkNotNull(task(id)).asTaskRecord()
        require(task.deletedAt == null && task.status == app.septena.core.TaskStatus.OPEN)
        val current = conversation(id)
        when (edit) {
            is ConversationEdit.Stop -> {
                require(current.canStop(clock.now()))
                if ((current.state.stoppedAt != null) != edit.stopped) {
                    conversationMutator.setStopped(id, edit.stopped, clock.now())
                }
            }
            is ConversationEdit.Answer -> {
                val question = checkNotNull(current.question()) { "This question has already been answered." }
                require(question.sequence == edit.sequence) { "The agent has asked a different question." }
                val value = edit.text.trim()
                require(value.isNotEmpty() && (edit.other || value in question.choices()))
                appendUserTurn(id, question.fields["step"].stringValue() ?: RegistryEntityEnums.ConvoTurnStep.WORK,
                    mapOf(
                        (if (edit.other) "otherText" else "chosen") to JsonValue.StringValue(value),
                        "inReplyTo" to JsonValue.IntegerValue(question.sequence),
                    ),
                )
            }
            is ConversationEdit.Reply -> {
                require(current.question() == null)
                val reply = edit.text.trim()
                require(reply.isNotEmpty())
                appendUserTurn(id, RegistryEntityEnums.ConvoTurnStep.WORK, mapOf("note" to JsonValue.StringValue(reply)))
            }
        }
    }

    private suspend fun appendUserTurn(id: String, step: String, answer: Map<String, JsonValue>) {
        conversationMutator.appendUserTurn(id, answer + mapOf(
            "role" to JsonValue.StringValue(RegistryEntityEnums.ConvoTurnRole.USER),
            "step" to JsonValue.StringValue(step),
            "ts" to JsonValue.StringValue(WireTimestamp.format(clock.now())),
        ))
        mutator.touch(id)
    }

    suspend fun setAgentsPaused(paused: Boolean) {
        settingsMutator.set(RegistrySettingKeys.AGENTS_PAUSED, JsonValue.BooleanValue(paused))
    }

    suspend fun quickFindSnapshot(): QuickFindSearch =
        QuickFindSearch(store, clock, includeArchivedProjects = false).snapshot()

    fun today(): LocalDate = clock.today(clock.now())
    fun now() = clock.now()

    suspend fun saveText(original: TaskRecord, title: String, notes: String): TaskRecord {
        val cleanTitle = title.trim()
        require(cleanTitle.isNotEmpty())
        val originalNotes = original.fields[RegistryEntityFields.Task.NOTES].stringValue()
        val changes = buildMap {
            if (cleanTitle != original.title) put(RegistryEntityFields.Task.TITLE, JsonValue.StringValue(cleanTitle))
            if (notes != originalNotes.orEmpty()) put(RegistryEntityFields.Task.NOTES, JsonValue.stringOrNull(notes.ifEmpty { null }))
        }
        return editTask(original.id) {
            if (changes.isEmpty()) task(original.id)?.asTaskRecord()
            else mutator.updateFields(original.id, changes, notesBase = NotesBase(originalNotes))
        }
    }

    suspend fun setWhen(id: String, day: LocalDate?, mode: RescheduleMode): TaskRecord {
        val current = checkNotNull(task(id))
        val series = current.fields[RegistryEntityFields.Task.RECURRENCE_SERIES_ID].stringValue() ?: id
        val before = if (mode == RescheduleMode.UPDATE_RULE) {
            (store.activeTasks().filter { row ->
                row.deletedAt == null && row.fields[RegistryEntityFields.Task.RECURRENCE_SERIES_ID].stringValue() == series
            } + current).distinctBy(SyncRecord::id)
        } else listOf(current)
        val updated = checkNotNull(mutator.setWhen(id, day?.toString(), mode))
        undoHistory.recordEdits(before.map { it to task(it.id) })
        return updated
    }

    suspend fun setDeadline(id: String, day: LocalDate?): TaskRecord =
        editTask(id) { mutator.setDeadline(id, day?.toString()) }

    suspend fun setRepeat(id: String, rule: RecurrenceRule?, paused: Boolean): TaskRecord =
        editTask(id) { mutator.setRepeat(id, rule, paused) }

    suspend fun undo(): Boolean = undoHistory.undo(mutator)

    private suspend fun editTask(id: String, write: suspend () -> TaskRecord?): TaskRecord {
        val before = checkNotNull(task(id))
        val after = checkNotNull(write())
        undoHistory.recordEdits(listOf(before to after.asSyncRecord()))
        return after
    }

    suspend fun add(title: String, location: DesktopLocation = DesktopLocation.Smart(RegistryDestinationIds.INBOX)): TaskRecord {
        requirePlace(location)
        return when (location) {
            is DesktopLocation.Smart -> mutator.create(title, today = location.id == RegistryDestinationIds.TODAY)
            is DesktopLocation.Area -> mutator.create(title, area = location.id)
            is DesktopLocation.Project -> mutator.create(title, project = location.id).also { created ->
                // A new Checklist item with no section joins the core's suggested group (#860).
                mutator.placeChecklistItem(created.id, created.title) { group ->
                    RegistryCatalog.checklistGroupTitle(group, Locale.getDefault().toLanguageTag())
                }
            }
            is DesktopLocation.Section -> mutator.create(title, project = location.projectId, heading = location.id)
        }
    }

    suspend fun addArea(title: String): DesktopLocation.Area {
        val position = store.records(RegistryEntityNames.AREA).count { it.deletedAt == null }.toLong()
        val record = entityMutator.create(
            RegistryEntityNames.AREA,
            mapOf(
                RegistryEntityFields.Area.TITLE to JsonValue.StringValue(title.trim()),
                RegistryEntityFields.Area.POSITION to JsonValue.IntegerValue(position),
            ),
        )
        return DesktopLocation.Area(record.id)
    }

    suspend fun addProject(title: String, area: DesktopLocation.Area?): DesktopLocation.Project {
        if (area != null) requirePlace(area)
        val position = store.records(RegistryEntityNames.PROJECT).count {
            it.deletedAt == null &&
                it.fields[RegistryEntityFields.Project.STATUS].stringValue() == RegistryEntityEnums.ProjectStatus.ACTIVE &&
                it.fields[RegistryEntityFields.Project.AREA].stringValue() == area?.id
        }.toLong()
        val fields = buildMap {
            put(RegistryEntityFields.Project.TITLE, JsonValue.StringValue(title.trim()))
            put(RegistryEntityFields.Project.STATUS, JsonValue.StringValue(RegistryEntityEnums.ProjectStatus.ACTIVE))
            put(RegistryEntityFields.Project.POSITION, JsonValue.IntegerValue(position))
            area?.let { put(RegistryEntityFields.Project.AREA, JsonValue.StringValue(it.id)) }
        }
        return DesktopLocation.Project(entityMutator.create(RegistryEntityNames.PROJECT, fields).id)
    }

    suspend fun addSection(title: String, project: DesktopLocation.Project): DesktopLocation.Section {
        requirePlace(project)
        val places = places()
        val position = (places.sections[project.id].orEmpty().mapNotNull(DesktopPlace::position).maxOrNull() ?: -1.0) + 1
        val heading = mutator.createHeading(title, project.id, position)
        return DesktopLocation.Section(project.id, heading.id)
    }

    suspend fun renamePlace(location: DesktopLocation, title: String) {
        requirePlace(location)
        when (location) {
            is DesktopLocation.Area -> checkNotNull(entityMutator.update(
                RegistryEntityNames.AREA,
                location.id,
                mapOf(RegistryEntityFields.Area.TITLE to JsonValue.StringValue(title.trim())),
            ))
            is DesktopLocation.Project -> checkNotNull(entityMutator.update(
                RegistryEntityNames.PROJECT,
                location.id,
                mapOf(RegistryEntityFields.Project.TITLE to JsonValue.StringValue(title.trim())),
            ))
            is DesktopLocation.Section -> checkNotNull(mutator.rename(location.id, title))
            is DesktopLocation.Smart -> error("Cannot rename a smart list")
        }
    }

    suspend fun move(id: String, location: DesktopLocation) {
        requirePlace(location)
        val record = checkNotNull(task(id))
        val source = TaskSnapshot.from(record)
        check(!source.isHeading && source.deletedAt == null && source.status == RegistryEntityEnums.TaskStatus.OPEN)
        val heading = record.fields[RegistryEntityFields.Task.HEADING].stringValue()
        val moved = when (location) {
            is DesktopLocation.Smart -> {
                require(location.id == RegistryDestinationIds.INBOX)
                mutator.moveToList(id, area = null, project = null)
            }
            is DesktopLocation.Area -> mutator.moveToList(id, area = location.id, project = null)
            is DesktopLocation.Project -> {
                if (source.project == location.id && heading != null) {
                    mutator.updateFields(id, mapOf(RegistryEntityFields.Task.HEADING to JsonValue.Null))
                } else {
                    mutator.moveToList(id, area = null, project = location.id)
                }
            }
            is DesktopLocation.Section -> {
                if (source.project == location.projectId && heading == location.id) return
                mutator.updateFields(id, mapOf(
                    RegistryEntityFields.Task.AREA to JsonValue.Null,
                    RegistryEntityFields.Task.PROJECT to JsonValue.StringValue(location.projectId),
                    RegistryEntityFields.Task.HEADING to JsonValue.StringValue(location.id),
                ))
            }
        }
        checkNotNull(moved)
    }

    private suspend fun requirePlace(location: DesktopLocation) {
        when (location) {
            is DesktopLocation.Smart -> Unit
            is DesktopLocation.Area -> {
                val area = store.record(RegistryEntityNames.AREA, location.id)
                require(area != null && area.deletedAt == null)
            }
            is DesktopLocation.Project -> {
                val project = store.record(RegistryEntityNames.PROJECT, location.id)
                require(project != null && project.deletedAt == null &&
                    project.fields[RegistryEntityFields.Project.STATUS].stringValue() == RegistryEntityEnums.ProjectStatus.ACTIVE)
            }
            is DesktopLocation.Section -> {
                requirePlace(DesktopLocation.Project(location.projectId))
                val heading = task(location.id)?.let(TaskSnapshot::from)
                require(heading != null && heading.isHeading && heading.project == location.projectId &&
                    heading.deletedAt == null && heading.status == RegistryEntityEnums.TaskStatus.OPEN)
            }
        }
    }

    suspend fun rename(id: String, title: String) = mutator.rename(id, title)
    /**
     * The row checkbox. A Checklist row checks and reopens with the core patch
     * as one undo step, so Undo brings back the date it cleared (#860).
     */
    suspend fun complete(id: String): TaskRecord? {
        if (!mutator.isChecklistRow(id)) return mutator.complete(id)
        val checked = task(id)?.fields?.get(RegistryEntityFields.Task.STATUS).stringValue() ==
            RegistryEntityEnums.TaskStatus.CHECKLIST_CHECKED
        return editTask(id) { if (checked) mutator.reopen(id) else mutator.complete(id) }
    }
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
    private val records = mutableMapOf<Pair<String, String>, SyncRecord>()
    private val results = mutableMapOf<String, SyncOperationResult>()
    private val turnSequences = mutableMapOf<String, Long>()

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
        ).forEach { recordChange(it.asSyncRecord()) }
        recordChange(SyncRecord(RegistryEntityNames.CONVO, "seedtask0001", mapOf(
            RegistryEntityFields.Convo.ASSIGNEE to JsonValue.StringValue(RegistryEntityEnums.ConvoAssignee.CLAUDE),
        ), revision = 1))
        recordTurn("seedtask0001", mapOf(
            "role" to JsonValue.StringValue(RegistryEntityEnums.ConvoTurnRole.PROVIDER),
            "step" to JsonValue.StringValue(RegistryEntityEnums.ConvoTurnStep.CONFIRM),
            "question" to JsonValue.StringValue("Which part should I check first?"),
            "options" to JsonValue.ArrayValue(listOf("Installer", "Task lists").map(JsonValue::StringValue)),
            "ts" to JsonValue.StringValue(stamp),
        ))
        recordChange(SyncRecord(RegistryEntityNames.AREA, "seedarea0001", mapOf(
            RegistryEntityFields.Area.TITLE to JsonValue.StringValue("Example area"),
        ), revision = 1))
        recordChange(SyncRecord(RegistryEntityNames.PROJECT, "seedproj0001", mapOf(
            RegistryEntityFields.Project.TITLE to JsonValue.StringValue("Example project"),
            RegistryEntityFields.Project.STATUS to JsonValue.StringValue(RegistryEntityEnums.ProjectStatus.ACTIVE),
            RegistryEntityFields.Project.AREA to JsonValue.StringValue("seedarea0001"),
        ), revision = 1))
        recordChange(TaskRecord("seedhead0001", TaskRecord.createFields(
            title = "Example section",
            created = today.toString(),
            createdAt = stamp,
            project = "seedproj0001",
            kind = RegistryEntityEnums.TaskKind.HEADING,
            sourceClient = "Spike fixture",
        ), revision = 1).asSyncRecord())
    }

    fun pushedCount() = results.size

    override suspend fun push(operations: List<SyncOperation>): SyncPushResponse {
        if (!online) throw IOException("Fixture is offline")
        val applied = operations.map { operation ->
            results.getOrPut(operation.clientOpId) {
                when (operation) {
                    is SyncOperation.Upsert -> {
                        val previous = records[operation.entity to operation.id]
                        val revision = (previous?.revision ?: 0L) + 1L
                        recordChange(SyncRecord(operation.entity, operation.id, previous?.fields.orEmpty() + operation.fields, revision))
                        SyncOperationResult(operation.clientOpId, SyncResultStatus.APPLIED, revision, changes.size.toLong())
                    }
                    is SyncOperation.AppendTurn -> SyncOperationResult(
                        operation.clientOpId, SyncResultStatus.APPLIED, sequence = recordTurn(operation.taskId, operation.turn),
                    )
                    is SyncOperation.Delete -> error("The fixture does not accept deletes")
                }
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

    private fun recordChange(record: SyncRecord) {
        records[record.entity to record.id] = record
        changes += SyncChange(
            record.entity,
            record.fields + mapOf(
                "id" to JsonValue.StringValue(record.id),
                "rev" to JsonValue.IntegerValue(requireNotNull(record.revision)),
            ),
        )
    }

    private fun recordTurn(taskId: String, turn: Map<String, JsonValue>): Long {
        val sequence = (turnSequences[taskId] ?: 0L) + 1L
        turnSequences[taskId] = sequence
        changes += SyncChange("turn", turn + mapOf(
            "taskId" to JsonValue.StringValue(taskId),
            "seq" to JsonValue.IntegerValue(sequence),
        ))
        return sequence
    }
}
