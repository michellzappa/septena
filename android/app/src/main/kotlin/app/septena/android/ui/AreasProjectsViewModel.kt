package app.septena.android.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import app.septena.android.AndroidAppGraph
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.TaskFadeRules
import app.septena.core.TaskSnapshot
import app.septena.core.TaskViewRules
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.generated.RegistryPlacesScreenIds
import app.septena.core.stringValue
import app.septena.ui.TaskListItem
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

sealed interface AreasProjectsDestination {
    val id: String

    data class Area(override val id: String) : AreasProjectsDestination
    data class Project(override val id: String) : AreasProjectsDestination

    val key: String
        get() = when (this) {
            is Area -> "area:$id"
            is Project -> "project:$id"
        }
}

data class PlaceProjectRow(
    val id: String,
    val title: String,
    val progress: Float = 0f,
    val openCount: Int = 0,
)
data class PlaceTaskRow(
    val id: String,
    val title: String,
    val isStarred: Boolean = false,
    val position: Double? = null,
    val item: TaskListItem = TaskListItem(id = id, title = title, isStarred = isStarred, position = position),
)
data class PlaceSectionRow(val id: String, val title: String, val tasks: List<PlaceTaskRow>)

data class AreasProjectsUiState(
    val destination: AreasProjectsDestination? = null,
    val isLoading: Boolean = true,
    val title: String = "",
    val emoji: String? = null,
    val notes: String = "",
    val projects: List<PlaceProjectRow> = emptyList(),
    val areaTasks: List<PlaceTaskRow> = emptyList(),
    val unsectionedTasks: List<PlaceTaskRow> = emptyList(),
    val sections: List<PlaceSectionRow> = emptyList(),
    val errorMessage: String? = null,
)

/** Store-backed area/project detail state. Reads stay on IO and reload after every sync data-version change. */
class AreasProjectsViewModel(private val graph: AndroidAppGraph) : ViewModel() {
    class Factory(private val graph: AndroidAppGraph) : ViewModelProvider.Factory {
        override fun <T : ViewModel> create(modelClass: Class<T>): T {
            require(modelClass.isAssignableFrom(AreasProjectsViewModel::class.java))
            @Suppress("UNCHECKED_CAST")
            return AreasProjectsViewModel(graph) as T
        }
    }

    private val destination = MutableStateFlow<AreasProjectsDestination?>(null)
    private val errorMessage = MutableStateFlow<String?>(null)

    @OptIn(ExperimentalCoroutinesApi::class)
    private val loaded: StateFlow<AreasProjectsUiState> = combine(destination, graph.sync.dataVersion) { selected, _ ->
        selected
    }.mapLatest { selected ->
        withContext(Dispatchers.IO) { load(selected) }
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(stopTimeoutMillis = 5_000),
        initialValue = AreasProjectsUiState(),
    )

    val state: StateFlow<AreasProjectsUiState> = combine(loaded, errorMessage) { places, error ->
        places.copy(errorMessage = error)
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(stopTimeoutMillis = 5_000),
        initialValue = AreasProjectsUiState(),
    )

    fun select(destination: AreasProjectsDestination) {
        if (this.destination.value != destination) {
            this.destination.value = destination
            errorMessage.value = null
        }
    }

    fun renameSelected(title: String) {
        val trimmed = title.trim()
        if (trimmed.isEmpty()) return
        val selected = destination.value ?: return
        mutate {
            val titleField = when (selected) {
                is AreasProjectsDestination.Area -> RegistryEntityFields.Area.TITLE
                is AreasProjectsDestination.Project -> RegistryEntityFields.Project.TITLE
            }
            graph.registryEntityMutator.update(
                selected.entityName(),
                selected.id,
                mapOf(titleField to JsonValue.StringValue(trimmed)),
            ) != null
        }
    }

    fun saveNotes(notes: String) {
        val selected = destination.value ?: return
        mutate {
            val field = when (selected) {
                is AreasProjectsDestination.Area -> RegistryEntityFields.Area.CONTEXT
                is AreasProjectsDestination.Project -> RegistryEntityFields.Project.NOTES
            }
            graph.registryEntityMutator.update(
                selected.entityName(),
                selected.id,
                mapOf(field to JsonValue.stringOrNull(notes)),
            ) != null
        }
    }

    fun setAreaEmoji(emoji: String?) {
        val selected = destination.value as? AreasProjectsDestination.Area ?: return
        mutate {
            graph.registryEntityMutator.update(
                RegistryEntityNames.AREA,
                selected.id,
                mapOf(RegistryEntityFields.Area.EMOJI to JsonValue.stringOrNull(emoji?.takeIf(String::isNotBlank))),
            ) != null
        }
    }

    fun createProject(title: String) {
        val selected = destination.value as? AreasProjectsDestination.Area ?: return
        val trimmed = title.trim()
        if (trimmed.isEmpty()) return
        mutate {
            val projects = graph.taskStore.records(RegistryEntityNames.PROJECT)
                .filter { it.deletedAt == null && it.fields[RegistryEntityFields.Project.AREA].stringValue() == selected.id }
            val nextPosition = (projects.mapNotNull { it.fields[RegistryEntityFields.Project.POSITION].numberValue() }
                .maxOrNull() ?: -1.0) + 1.0
            graph.registryEntityMutator.create(
                RegistryEntityNames.PROJECT,
                linkedMapOf(
                    RegistryEntityFields.Project.TITLE to JsonValue.StringValue(trimmed),
                    RegistryEntityFields.Project.STATUS to JsonValue.StringValue(RegistryEntityEnums.ProjectStatus.ACTIVE),
                    RegistryEntityFields.Project.AREA to JsonValue.StringValue(selected.id),
                    RegistryEntityFields.Project.CREATED to JsonValue.StringValue(graph.clock.today(graph.clock.now()).toString()),
                    RegistryEntityFields.Project.POSITION to JsonValue.IntegerValue(nextPosition.toLong()),
                ),
            )
            true
        }
    }

    fun createSection(title: String) {
        val selected = destination.value as? AreasProjectsDestination.Project ?: return
        val trimmed = title.trim()
        if (trimmed.isEmpty()) return
        mutate {
            val position = graph.taskStore.records(RegistryEntityNames.TASK)
                .asSequence()
                .filter { it.deletedAt == null }
                .filter { it.fields[RegistryEntityFields.Task.PROJECT].stringValue() == selected.id }
                .filter { it.fields[RegistryEntityFields.Task.KIND].stringValue() == RegistryEntityEnums.TaskKind.HEADING }
                .mapNotNull { it.fields[RegistryEntityFields.Task.POSITION].numberValue() }
                .maxOrNull()?.plus(1.0) ?: 0.0
            graph.taskMutator.createHeading(trimmed, selected.id, position)
            true
        }
    }

    fun renameSection(id: String, title: String) {
        val selected = destination.value as? AreasProjectsDestination.Project ?: return
        val trimmed = title.trim()
        if (trimmed.isEmpty()) return
        mutate {
            requireHeading(id, selected.id)
            graph.taskMutator.rename(id, trimmed) != null
        }
    }

    fun deleteSection(id: String) {
        val selected = destination.value as? AreasProjectsDestination.Project ?: return
        mutate {
            requireHeading(id, selected.id)
            graph.taskMutator.delete(id) != null
        }
    }

    fun clearError() {
        errorMessage.value = null
    }

    /** Reorders [ids] inside this area, project, or project section as one undoable edit. */
    fun reorderTasks(
        ids: List<String>,
        positions: List<Double>,
        targetHeadingId: String? = null,
        updateHeading: Boolean = false,
    ) {
        if (ids.isEmpty() || positions.size < ids.size) return
        val ordered = ids.zip(positions)
        mutate {
            graph.captureTaskEdits(ids.toSet()) { id ->
                val pos = ordered.firstOrNull { it.first == id }?.second ?: return@captureTaskEdits
                val changes = linkedMapOf<String, JsonValue>(
                    RegistryEntityFields.Task.POSITION to JsonValue.DecimalValue(pos),
                )
                if (updateHeading) {
                    changes[RegistryEntityFields.Task.HEADING] = JsonValue.stringOrNull(targetHeadingId)
                }
                graph.taskMutator.updateFields(id, changes)
            }
            true
        }
    }

    /** Re-homes dragged area tasks into one of the area's projects, preserving relative order at top. */
    fun moveTasksToProject(ids: List<String>, projectId: String) {
        if (ids.isEmpty()) return
        mutate {
            val minPos = graph.taskStore.records(RegistryEntityNames.TASK)
                .asSequence()
                .filter { it.deletedAt == null }
                .filter { it.fields[RegistryEntityFields.Task.PROJECT].stringValue() == projectId }
                .filter { it.fields[RegistryEntityFields.Task.KIND].stringValue() != RegistryEntityEnums.TaskKind.HEADING }
                .mapNotNull { it.fields[RegistryEntityFields.Task.POSITION].numberValue() }
                .minOrNull() ?: 0.0
            val startPos = minPos - ids.size.toDouble()
            val ordered = ids.mapIndexed { idx, id -> id to (startPos + idx.toDouble()) }
            graph.captureTaskEdits(ids.toSet()) { id ->
                val pos = ordered.firstOrNull { it.first == id }?.second ?: return@captureTaskEdits
                graph.taskMutator.updateFields(
                    id,
                    linkedMapOf(
                        RegistryEntityFields.Task.AREA to JsonValue.Null,
                        RegistryEntityFields.Task.PROJECT to JsonValue.StringValue(projectId),
                        RegistryEntityFields.Task.HEADING to JsonValue.Null,
                        RegistryEntityFields.Task.POSITION to JsonValue.DecimalValue(pos),
                    ),
                )
            }
            true
        }
    }

    private suspend fun requireHeading(id: String, projectId: String) {
        val heading = graph.taskStore.record(RegistryEntityNames.TASK, id)
        require(heading != null && heading.deletedAt == null) { placeError(RegistryPlacesScreenIds.PLACE_ERROR_SECTION_UNAVAILABLE) }
        require(heading.fields[RegistryEntityFields.Task.PROJECT].stringValue() == projectId) {
            placeError(RegistryPlacesScreenIds.PLACE_ERROR_SECTION_WRONG_PROJECT)
        }
        require(heading.fields[RegistryEntityFields.Task.KIND].stringValue() == RegistryEntityEnums.TaskKind.HEADING) {
            placeError(RegistryPlacesScreenIds.PLACE_ERROR_NOT_A_SECTION)
        }
    }

    private fun placeError(id: String): String =
        RegistryCatalog.surface(id)?.fields?.get("message").stringValue()
            ?: error("Missing registry error copy for '$id'")

    private fun mutate(block: suspend () -> Boolean) {
        viewModelScope.launch {
            runCatching { withContext(Dispatchers.IO) { block() } }
                .onSuccess { changed ->
                    errorMessage.value = null
                    if (changed) {
                        graph.sync.noteLocalChange()
                        graph.sync.requestSync()
                    }
                }
                .onFailure { errorMessage.value = it.message }
        }
    }

    private suspend fun load(selected: AreasProjectsDestination?): AreasProjectsUiState {
        if (selected == null) return AreasProjectsUiState(isLoading = false)
        val entity = selected.entityName()
        val container = graph.taskStore.record(entity, selected.id)
            ?: return AreasProjectsUiState(destination = selected, isLoading = false)
        if (container.deletedAt != null) return AreasProjectsUiState(destination = selected, isLoading = false)

        val titleField = when (selected) {
            is AreasProjectsDestination.Area -> RegistryEntityFields.Area.TITLE
            is AreasProjectsDestination.Project -> RegistryEntityFields.Project.TITLE
        }
        val notesField = when (selected) {
            is AreasProjectsDestination.Area -> RegistryEntityFields.Area.CONTEXT
            is AreasProjectsDestination.Project -> RegistryEntityFields.Project.NOTES
        }
        val title = container.fields[titleField].stringValue().orEmpty()
        val notes = container.fields[notesField].stringValue().orEmpty()
        val now = graph.clock.now()
        val today = graph.clock.today(now)
        val metadataCatalog = TaskRowMetadataCatalog.load(graph.taskStore)
        val showAging = graph.fadesInactiveTasks()
        val conversations = graph.conversations()
        val allTaskRecords = graph.taskStore.records(RegistryEntityNames.TASK)
            .asSequence()
            .filter { it.deletedAt == null }
            .mapNotNull { record ->
                runCatching { record to TaskSnapshot.from(record) }.getOrNull()
            }
            .toList()
        val taskRows = allTaskRecords
            .filter { (_, task) -> task.status == RegistryEntityEnums.TaskStatus.OPEN }

        fun placeRow(record: app.septena.core.SyncRecord, task: TaskSnapshot, pos: Double?): PlaceTaskRow {
            val membership = TaskViewRules.membership(task, today, now)
            val base = buildTaskListItem(
                record = record,
                snapshot = task,
                membership = membership,
                subtitle = null,
                catalog = metadataCatalog,
                today = today,
                now = now,
                showTodayIndicator = true,
            ).copy(position = pos)
                .withFade(task, conversations[record.id], now, today, showAging)
            return PlaceTaskRow(
                id = record.id,
                title = task.title,
                isStarred = task.starred,
                position = pos,
                item = base,
            )
        }

        return when (selected) {
            is AreasProjectsDestination.Area -> {
                val projectStats = mutableMapOf<String, Pair<Int, Int>>()
                for ((_, task) in allTaskRecords) {
                    if (task.isHeading) continue
                    val pid = task.project ?: continue
                    val prev = projectStats[pid] ?: (0 to 0)
                    when (task.status) {
                        // Faded open tasks leave every count and ring (docs/TASK_FADE_SPEC.md §4).
                        RegistryEntityEnums.TaskStatus.OPEN -> if (!TaskFadeRules.isFaded(task.fadedAt)) projectStats[pid] = (prev.first + 1) to prev.second
                        RegistryEntityEnums.TaskStatus.DONE -> projectStats[pid] = prev.first to (prev.second + 1)
                    }
                }
                val projects = graph.taskStore.records(RegistryEntityNames.PROJECT)
                    .asSequence()
                    .filter { it.deletedAt == null }
                    .filter { it.fields[RegistryEntityFields.Project.STATUS].stringValue() == RegistryEntityEnums.ProjectStatus.ACTIVE }
                    .filter { it.fields[RegistryEntityFields.Project.AREA].stringValue() == selected.id }
                    .mapNotNull { record ->
                        record.fields[RegistryEntityFields.Project.TITLE].stringValue()?.let { name ->
                            val (open, done) = projectStats[record.id] ?: (0 to 0)
                            val total = open + done
                            val progress = if (total > 0) done.toFloat() / total.toFloat() else 0f
                            record to PlaceProjectRow(record.id, name, progress = progress, openCount = open)
                        }
                    }
                    .sortedWith(compareBy({ it.first.fields[RegistryEntityFields.Project.POSITION].numberValue() ?: Double.MAX_VALUE }, { it.second.title.lowercase() }))
                    .map { it.second }
                    .toList()
                val tasks = taskRows.asSequence()
                    .filter { (_, task) -> task.area == selected.id && task.project == null && !task.isHeading }
                    .map { (record, task) ->
                        val pos = record.fields[RegistryEntityFields.Task.POSITION].numberValue()
                        PositionedPlaceTask(placeRow(record, task, pos), pos)
                    }
                    .sortedWith(PLACE_TASK_ORDER)
                    .map { it.task }
                    .toList()
                AreasProjectsUiState(
                    destination = selected,
                    isLoading = false,
                    title = title,
                    emoji = container.fields[RegistryEntityFields.Area.EMOJI].stringValue()?.takeIf(String::isNotBlank),
                    notes = notes,
                    projects = projects,
                    areaTasks = tasks,
                )
            }
            is AreasProjectsDestination.Project -> {
                val projectRows = taskRows.asSequence()
                    .filter { (_, task) -> task.project == selected.id }
                    .map { (record, task) ->
                        val pos = record.fields[RegistryEntityFields.Task.POSITION].numberValue()
                        ProjectTask(
                            recordId = record.id,
                            row = if (task.isHeading) {
                                PlaceTaskRow(record.id, task.title, task.starred, pos)
                            } else {
                                placeRow(record, task, pos)
                            },
                            headingId = record.fields[RegistryEntityFields.Task.HEADING].stringValue(),
                            isHeading = task.isHeading,
                            position = pos,
                        )
                    }
                    .toList()
                val headings = projectRows.filter(ProjectTask::isHeading)
                    .sortedWith(compareBy<ProjectTask>({ it.position ?: Double.MAX_VALUE }, { it.row.title.lowercase() }))
                val headingIds = headings.mapTo(mutableSetOf(), ProjectTask::recordId)
                val visibleTasks = projectRows.filterNot(ProjectTask::isHeading)
                val unsectioned = visibleTasks.filter { it.headingId !in headingIds }
                    .sortedWith(compareBy({ it.position ?: Double.MAX_VALUE }, { it.row.title.lowercase() }))
                    .map(ProjectTask::row)
                val sections = headings.map { heading ->
                    PlaceSectionRow(
                        id = heading.recordId,
                        title = heading.row.title,
                        tasks = visibleTasks.filter { it.headingId == heading.recordId }
                            .sortedWith(compareBy({ it.position ?: Double.MAX_VALUE }, { it.row.title.lowercase() }))
                            .map(ProjectTask::row),
                    )
                }
                AreasProjectsUiState(
                    destination = selected,
                    isLoading = false,
                    title = title,
                    notes = notes,
                    unsectionedTasks = unsectioned,
                    sections = sections,
                )
            }
        }
    }

    private fun AreasProjectsDestination.entityName(): String = when (this) {
        is AreasProjectsDestination.Area -> RegistryEntityNames.AREA
        is AreasProjectsDestination.Project -> RegistryEntityNames.PROJECT
    }

    private data class ProjectTask(
        val recordId: String,
        val row: PlaceTaskRow,
        val headingId: String?,
        val isHeading: Boolean,
        val position: Double?,
    )

    private data class PositionedPlaceTask(val task: PlaceTaskRow, val position: Double?)

    private companion object {
        val PLACE_TASK_ORDER = compareBy<PositionedPlaceTask>(
            { it.position ?: Double.MAX_VALUE },
            { it.task.title.lowercase() },
        )
    }
}

private fun JsonValue?.numberValue(): Double? = when (this) {
    is JsonValue.IntegerValue -> value.toDouble()
    is JsonValue.DecimalValue -> value
    else -> null
}
