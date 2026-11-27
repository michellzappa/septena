package app.septena.android.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import app.septena.android.AndroidAppGraph
import app.septena.core.JsonValue
import app.septena.core.ListSortPreferences
import app.septena.core.ListSortRules
import app.septena.core.NotesBase
import app.septena.core.ProjectChecklistRules
import app.septena.core.ProjectShare
import app.septena.core.RecurrenceRules
import app.septena.core.SyncRecord
import app.septena.core.RegistryCatalog
import app.septena.core.StructureOrder
import app.septena.core.TaskFadeRules
import app.septena.core.TaskSnapshot
import app.septena.core.TaskViewRules
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.generated.RegistryPlacesScreenIds
import app.septena.core.stringValue
import app.septena.ui.TaskListItem
import app.septena.ui.headingReorderPositions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flowOn
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
    val share: ProjectShare? = null,
)
data class PlaceTaskRow(
    val id: String,
    val title: String,
    val isStarred: Boolean = false,
    val position: Double? = null,
    val assignedTo: String? = null,
    val item: TaskListItem = TaskListItem(id = id, title = title, isStarred = isStarred, position = position),
)
data class PlaceSectionRow(
    val id: String,
    val title: String,
    val tasks: List<PlaceTaskRow>,
    /** The heading's stored manual position; a heading reorder writes it. */
    val position: Double? = null,
)

data class PlaceAreaOption(
    val id: String,
    val title: String,
    val emoji: String? = null,
)

data class AreasProjectsUiState(
    val destination: AreasProjectsDestination? = null,
    val isLoading: Boolean = true,
    val title: String = "",
    val emoji: String? = null,
    val notes: String = "",
    val currentAreaId: String? = null,
    val share: ProjectShare? = null,
    val availableAreas: List<PlaceAreaOption> = emptyList(),
    val projects: List<PlaceProjectRow> = emptyList(),
    val areaTasks: List<PlaceTaskRow> = emptyList(),
    val unsectionedTasks: List<PlaceTaskRow> = emptyList(),
    val sections: List<PlaceSectionRow> = emptyList(),
    val checklistMode: String? = null,
    val checklistRows: List<SyncRecord> = emptyList(),
    /** The Sort By choice of this page (docs/LIST_SORT_SPEC.md); Manual is the stored order. */
    val listSort: String = RegistryEntityEnums.ListSort.MANUAL,
    /** The rows the core sorts, by id. Empty under Manual. */
    val sortSnapshots: Map<String, TaskSnapshot> = emptyMap(),
    val errorMessage: String? = null,
) {
    /** A sorted page turns drag between rows off; drops on headings still work (spec §6). */
    val isSorted: Boolean get() = listSort != RegistryEntityEnums.ListSort.MANUAL
}

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
    /** The row in inline edit: it keeps its place in a sorted page until the edit ends. */
    private val pinnedTaskId = MutableStateFlow<String?>(null)
    /** The row order each group of the page showed last, for [pinnedTaskId]. */
    @Volatile private var lastShownOrder: Map<String, List<String>> = emptyMap()

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

    /** [loaded] with the page's Sort By applied off the main thread, inside each group. */
    private val sortedLoaded = combine(loaded, pinnedTaskId) { places, pinned ->
        applyListSort(places, pinned)
    }.flowOn(Dispatchers.Default)

    val state: StateFlow<AreasProjectsUiState> = combine(sortedLoaded, errorMessage) { places, error ->
        places.copy(errorMessage = error)
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(stopTimeoutMillis = 5_000),
        initialValue = AreasProjectsUiState(),
    )

    /** The row in inline edit, or null when no edit is open. */
    fun setPinnedTask(id: String?) {
        pinnedTaskId.value = id
    }

    /** Sorts the area's tasks, the tasks above the first heading, and each heading's tasks; headings keep their order. */
    private fun applyListSort(places: AreasProjectsUiState, pinned: String?): AreasProjectsUiState {
        val destination = places.destination
        if (destination == null || !places.isSorted) {
            lastShownOrder = emptyMap()
            return places
        }
        val shown = mutableMapOf<String, List<String>>()
        val previous = lastShownOrder
        fun sort(group: String, rows: List<PlaceTaskRow>): List<PlaceTaskRow> {
            val key = "${destination.key}|$group"
            val sorted = ListSortRules.sortInGroups(
                items = rows,
                sort = places.listSort,
                id = PlaceTaskRow::id,
                groupKey = { null },
                snapshot = { places.sortSnapshots[it.id] },
                isFixed = { it.item.isCompleted },
                pinnedId = pinned,
                previousIds = previous[key].orEmpty(),
            )
            shown[key] = sorted.map(PlaceTaskRow::id)
            return sorted
        }
        val result = places.copy(
            areaTasks = sort("area", places.areaTasks),
            unsectionedTasks = sort("unsectioned", places.unsectionedTasks),
            sections = places.sections.map { it.copy(tasks = sort("section:${it.id}", it.tasks)) },
        )
        lastShownOrder = shown
        return result
    }

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

    /** [base]: the notes the editor started from. */
    fun saveNotes(notes: String, base: String) {
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
                notesBase = NotesBase(base.ifEmpty { null }),
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

    fun moveProjectToArea(areaId: String?) {
        val selected = destination.value as? AreasProjectsDestination.Project ?: return
        mutate {
            graph.registryEntityMutator.update(
                RegistryEntityNames.PROJECT,
                selected.id,
                mapOf(RegistryEntityFields.Project.AREA to JsonValue.stringOrNull(areaId)),
            ) != null
        }
    }

    fun createProject(title: String) {
        val selected = destination.value as? AreasProjectsDestination.Area ?: return
        val trimmed = title.trim()
        if (trimmed.isEmpty()) return
        mutate {
            val projects = graph.taskStore.records(RegistryEntityNames.PROJECT)
                .filter {
                    val status = it.fields[RegistryEntityFields.Project.STATUS].stringValue()
                    it.deletedAt == null &&
                        (status == null || status == RegistryEntityEnums.ProjectStatus.ACTIVE) &&
                        it.fields[RegistryEntityFields.Project.AREA].stringValue() == selected.id
                }
            val nextPosition = StructureOrder.nextAppendPosition(
                projects.map { it.fields[RegistryEntityFields.Project.POSITION].numberValue() },
            )
            val created = graph.registryEntityMutator.create(
                RegistryEntityNames.PROJECT,
                linkedMapOf(
                    RegistryEntityFields.Project.TITLE to JsonValue.StringValue(trimmed),
                    RegistryEntityFields.Project.STATUS to JsonValue.StringValue(RegistryEntityEnums.ProjectStatus.ACTIVE),
                    RegistryEntityFields.Project.AREA to JsonValue.StringValue(selected.id),
                    RegistryEntityFields.Project.CREATED to JsonValue.StringValue(graph.clock.today(graph.clock.now()).toString()),
                    RegistryEntityFields.Project.POSITION to JsonValue.IntegerValue(nextPosition),
                ),
            )
            // Recorded at the gesture, after the create lands: Undo removes the project.
            graph.taskUndoHistory.recordCreatedEntity(created)
            true
        }
    }

    fun useAsChecklist(mode: String) {
        val project = destination.value as? AreasProjectsDestination.Project ?: return
        mutate {
            graph.registryEntityMutator.update(
                RegistryEntityNames.PROJECT,
                project.id,
                mapOf(RegistryEntityFields.Project.CHECKLIST_MODE to JsonValue.StringValue(mode)),
            ) != null
        }
    }

    fun addChecklistItem(title: String, heading: String?) {
        val project = destination.value as? AreasProjectsDestination.Project ?: return
        val name = title.trim()
        if (name.isEmpty()) return
        mutate {
            val projectRow = graph.taskStore.record(RegistryEntityNames.PROJECT, project.id) ?: return@mutate false
            val mode = projectRow.fields[RegistryEntityFields.Project.CHECKLIST_MODE].stringValue() ?: return@mutate false
            val suggested = ProjectChecklistRules.layout(emptyList(), name, mode == RegistryEntityEnums.ChecklistMode.GROCERIES).suggestedGroup
            val groupName = when (suggested) {
                "produce" -> "Produce"
                "dairy" -> "Dairy"
                "bakery" -> "Bakery"
                "meatSeafood" -> "Meat & Seafood"
                "pantry" -> "Pantry"
                "frozen" -> "Frozen"
                else -> null
            }
            val assignment = heading ?: groupName?.let { group ->
                val id = RecurrenceRules.occurrenceId("checklist:${project.id}", requireNotNull(suggested))
                graph.taskStore.records(RegistryEntityNames.TASK).firstOrNull { row ->
                    row.deletedAt == null &&
                        row.fields[RegistryEntityFields.Task.PROJECT].stringValue() == project.id &&
                        row.fields[RegistryEntityFields.Task.KIND].stringValue() == RegistryEntityEnums.TaskKind.HEADING &&
                        (row.id == id || row.fields[RegistryEntityFields.Task.TITLE].stringValue() == group)
                }?.id ?: graph.taskMutator.createHeading(group, project.id, id = id)
                    .takeIf { it.deletedAt == null }?.id
            }
            val item = graph.taskMutator.create(name, project = project.id, heading = assignment)
            graph.taskUndoHistory.recordCreatedEntity(
                SyncRecord(RegistryEntityNames.TASK, item.id, item.fields, item.revision, item.updatedAt, item.deletedAt),
            )
            true
        }
    }

    fun toggleChecklistItem(id: String) {
        mutate {
            graph.captureTaskEdit(id, touches = false) { graph.taskMutator.toggleProjectChecklist(id) }
            true
        }
    }

    fun moveChecklistItem(id: String, heading: String?) {
        mutate {
            graph.captureTaskEdit(id) {
                graph.taskMutator.updateFields(
                    id, mapOf(RegistryEntityFields.Task.HEADING to JsonValue.stringOrNull(heading)),
                )
            }
            true
        }
    }

    fun deleteChecklistItem(id: String) {
        mutate {
            graph.captureTaskEdit(id, touches = false) { graph.taskMutator.delete(id) }
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

    /**
     * Moves [ids] (headings of this project) just above [beforeHeadingId], or to
     * the end when it is null, as one undoable edit. Only the headings' own
     * positions change: their tasks keep `heading`, so the section moves with
     * them. Works in a sorted page too (docs/LIST_SORT_SPEC.md §6).
     */
    fun reorderSections(ids: List<String>, beforeHeadingId: String?) {
        val selected = destination.value as? AreasProjectsDestination.Project ?: return
        val headings = state.value.sections.map { it.id to it.position }
        val writes = headingReorderPositions(headings, ids, beforeHeadingId)
        if (writes.isEmpty()) return
        mutate {
            for ((id, _) in writes) requireHeading(id, selected.id)
            val byId = writes.toMap()
            // A heading does not fade, so a reorder does not touch it.
            graph.captureTaskEdits(byId.keys, touches = false) { id ->
                val pos = byId[id] ?: return@captureTaskEdits
                graph.taskMutator.updateFields(
                    id,
                    linkedMapOf<String, JsonValue>(RegistryEntityFields.Task.POSITION to JsonValue.DecimalValue(pos)),
                )
            }
            true
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
                runCatching { record to TaskSnapshot.from(record, metadataCatalog.shares) }.getOrNull()
            }
            .toList()
        val taskRows = allTaskRecords
            .filter { (_, task) -> task.status == RegistryEntityEnums.TaskStatus.OPEN }
        val listSort = ListSortPreferences.fromSynced(graph.syncedSettings).sortFor(
            when (selected) {
                is AreasProjectsDestination.Area -> ListSortPreferences.areaKey(selected.id)
                is AreasProjectsDestination.Project -> ListSortPreferences.projectKey(selected.id)
            },
        )
        fun sortSnapshots(ids: Set<String>): Map<String, TaskSnapshot> =
            if (listSort == RegistryEntityEnums.ListSort.MANUAL) {
                emptyMap()
            } else {
                taskRows.asSequence().map { it.second }.filter { it.id in ids }.associateBy(TaskSnapshot::id)
            }

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
                showsOwnAssignee = selected is AreasProjectsDestination.Project,
            ).copy(position = pos)
                .withFade(task, conversations[record.id], now, today, showAging)
            return PlaceTaskRow(
                id = record.id,
                title = task.title,
                isStarred = task.starred,
                position = pos,
                assignedTo = task.assignedTo,
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
                val projects = StructureOrder.orderByPosition(
                    items = graph.taskStore.records(RegistryEntityNames.PROJECT)
                        .filter { it.deletedAt == null }
                        .filter {
                            val status = it.fields[RegistryEntityFields.Project.STATUS].stringValue()
                            status == null || status == RegistryEntityEnums.ProjectStatus.ACTIVE
                        }
                        .filter { it.fields[RegistryEntityFields.Project.AREA].stringValue() == selected.id }
                        .mapNotNull { record ->
                            record.fields[RegistryEntityFields.Project.TITLE].stringValue()?.let { name ->
                                val (open, done) = projectStats[record.id] ?: (0 to 0)
                                val total = open + done
                                val progress = if (total > 0) done.toFloat() / total.toFloat() else 0f
                                record to PlaceProjectRow(
                                    record.id, name, progress = progress, openCount = open, share = ProjectShare.of(record),
                                )
                            }
                        },
                    position = { it.first.fields[RegistryEntityFields.Project.POSITION].numberValue() },
                    label = { it.second.title },
                ).map { it.second }
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
                    listSort = listSort,
                    sortSnapshots = sortSnapshots(tasks.mapTo(HashSet(), PlaceTaskRow::id)),
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
                        position = heading.position,
                        tasks = visibleTasks.filter { it.headingId == heading.recordId }
                            .sortedWith(compareBy({ it.position ?: Double.MAX_VALUE }, { it.row.title.lowercase() }))
                            .map(ProjectTask::row),
                    )
                }
                val availableAreas = StructureOrder.orderByPosition(
                    items = graph.taskStore.records(RegistryEntityNames.AREA)
                        .filter { it.deletedAt == null }
                        .mapNotNull { record ->
                            record.fields[RegistryEntityFields.Area.TITLE].stringValue()?.let { areaTitle ->
                                record to PlaceAreaOption(
                                    id = record.id,
                                    title = areaTitle,
                                    emoji = record.fields[RegistryEntityFields.Area.EMOJI].stringValue()?.takeIf(String::isNotBlank),
                                )
                            }
                        },
                    position = { it.first.fields[RegistryEntityFields.Area.POSITION].numberValue() },
                    label = { it.second.title },
                ).map { it.second }
                val currentAreaId = container.fields[RegistryEntityFields.Project.AREA].stringValue()?.takeIf(String::isNotBlank)
                AreasProjectsUiState(
                    destination = selected,
                    isLoading = false,
                    title = title,
                    notes = notes,
                    currentAreaId = currentAreaId,
                    share = ProjectShare.of(container),
                    availableAreas = availableAreas,
                    unsectionedTasks = unsectioned,
                    sections = sections,
                    checklistMode = container.fields[RegistryEntityFields.Project.CHECKLIST_MODE].stringValue(),
                    checklistRows = if (container.fields[RegistryEntityFields.Project.CHECKLIST_MODE].stringValue() != null) {
                        allTaskRecords.filter { (_, task) -> task.project == selected.id }
                            .map { it.first }
                            .sortedWith(compareBy<SyncRecord>(
                                { it.fields[RegistryEntityFields.Task.POSITION].numberValue() ?: Double.MAX_VALUE },
                                { it.fields[RegistryEntityFields.Task.TITLE].stringValue()?.lowercase().orEmpty() },
                                { it.id },
                            ))
                    } else emptyList(),
                    listSort = listSort,
                    sortSnapshots = sortSnapshots(
                        (unsectioned + sections.flatMap(PlaceSectionRow::tasks)).mapTo(HashSet(), PlaceTaskRow::id),
                    ),
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
