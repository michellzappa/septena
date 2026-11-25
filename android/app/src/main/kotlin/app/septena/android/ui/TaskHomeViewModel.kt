package app.septena.android.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.septena.android.AndroidAppGraph
import app.septena.core.JsonValue
import app.septena.core.RegistryActionContext
import app.septena.core.RegistryActionResolver
import app.septena.core.RegistryCatalog
import app.septena.core.SmartListResolver
import app.septena.core.SmartListSection
import app.septena.core.SyncRecord
import app.septena.core.TaskConversation
import app.septena.core.TaskFadeRules
import app.septena.core.TaskProvenance
import app.septena.core.TaskSnapshot
import app.septena.core.TaskViewRules
import app.septena.core.asSyncRecord
import app.septena.core.booleanValue
import app.septena.core.stringValue
import app.septena.core.generated.RegistryActionIds
import app.septena.core.generated.RegistryDestinationIds
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames as EntityNames
import app.septena.core.generated.RegistryPlatformIds
import app.septena.core.generated.RegistrySettingKeys
import app.septena.core.generated.RegistryTaskPageBlockIds
import app.septena.ui.SeptenaIconKind
import app.septena.ui.TaskGroupHeader
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

sealed interface TaskHomeLocation {
    data class SmartList(val destinationId: String) : TaskHomeLocation
    data class Area(val id: String, val title: String) : TaskHomeLocation
    data class Project(val id: String, val title: String) : TaskHomeLocation
}

data class TaskHomeNavigationItem(
    val location: TaskHomeLocation,
    val title: String? = null,
    val emoji: String? = null,
    /** Owning area id for a project item, so the sidebar nests projects under their areas. */
    val parentAreaId: String? = null,
    /** Item count shown on smart-list pills/rows, areas (rolled-up), and projects (matches iOS `SidebarView`). */
    val count: Int? = null,
    /** Done fraction (0..1) for projects, driving the progress ring glyph. */
    val progress: Float = 0f,
)

data class TaskHomeUiState(
    val hasLoaded: Boolean = false,
    val location: TaskHomeLocation = TaskHomeLocation.SmartList(RegistryDestinationIds.TODAY),
    /** Smart lists pinned to the top sidebar/nav zone (above Areas & Projects), identical to iOS. */
    val topSmartLists: List<TaskHomeNavigationItem> = emptyList(),
    /** Smart lists pinned to the bottom sidebar/nav zone (below Areas & Projects), identical to iOS. */
    val bottomSmartLists: List<TaskHomeNavigationItem> = emptyList(),
    val areas: List<TaskHomeNavigationItem> = emptyList(),
    val projects: List<TaskHomeNavigationItem> = emptyList(),
    val inboxTasks: List<TaskListItem> = emptyList(),
    val tasks: List<TaskListItem> = emptyList(),
    /** Soft-deleted tasks shown in Logbook's Deleted tab (#460 / #202). */
    val deletedTasks: List<TaskListItem> = emptyList(),
    val canQuickAdd: Boolean = false,
    val canComplete: Boolean = false,
    val agentsPaused: Boolean = false,
    /** Open agent requests: the rows of Review. */
    val reviewCount: Int = 0,
    /** Top-nav Star filter toggle: shows only starred tasks in the current list. */
    val starredOnly: Boolean = false,
    /** Task ids picked by a long-press; non-empty means the list is in selection mode. */
    val selectedIds: Set<String> = emptySet(),
    /** All currently faded open tasks ready for the Faded sweep sheet. */
    val fadedSweepItems: List<FadeSweepItem> = emptyList(),
    /** Subset of faded tasks since last sweep, shown in the Sunday weekly banner. */
    val weeklySweepItems: List<FadeSweepItem> = emptyList(),
    /** True on sweep day (Sunday) when unswept faded tasks exist and banner wasn't dismissed. */
    val showWeeklySweepBanner: Boolean = false,
    val errorMessage: String? = null,
)

/** The fields of the Quick Add sheet. */
data class QuickAddDraft(
    val title: String = "",
    val notes: String = "",
    val whenDay: String? = null,
    val deadline: String? = null,
    val starred: Boolean = false,
    val areaId: String? = null,
    val projectId: String? = null,
    val headingId: String? = null,
    val today: Boolean = false,
    val position: Double? = null,
    val useTodayPosition: Boolean = false,
)

private data class LoadedTaskHome(
    val hasLoaded: Boolean,
    val location: TaskHomeLocation,
    val topSmartLists: List<TaskHomeNavigationItem>,
    val bottomSmartLists: List<TaskHomeNavigationItem>,
    val areas: List<TaskHomeNavigationItem>,
    val projects: List<TaskHomeNavigationItem>,
    val inboxTasks: List<TaskListItem>,
    val tasks: List<TaskListItem>,
    val deletedTasks: List<TaskListItem> = emptyList(),
    val canQuickAdd: Boolean,
    val canComplete: Boolean,
    val agentsPaused: Boolean,
    val reviewCount: Int = 0,
    val fadedSweepItems: List<FadeSweepItem> = emptyList(),
    val weeklySweepItems: List<FadeSweepItem> = emptyList(),
    val showWeeklySweepBanner: Boolean = false,
)

/** Reads the store on IO and refreshes from the sync controller's data version flow. */
class TaskHomeViewModel(private val graph: AndroidAppGraph) : ViewModel() {
    private val location = MutableStateFlow<TaskHomeLocation>(
        TaskHomeLocation.SmartList(RegistryDestinationIds.TODAY),
    )
    private val starredOnly = MutableStateFlow(false)
    private val selectedIds = MutableStateFlow<Set<String>>(emptySet())
    private val sweepRefresh = MutableStateFlow(0L)
    private val errorMessage = MutableStateFlow<String?>(null)
    @Volatile private var filingSuggestionsByTask: Map<String, FilingSuggestion> = emptyMap()

    @OptIn(ExperimentalCoroutinesApi::class)
    private val loaded: StateFlow<LoadedTaskHome> = combine(
        location,
        graph.sync.dataVersion,
        graph.deviceSettings.changes,
        sweepRefresh,
    ) { selected, _, _, _ ->
        selected
    }.mapLatest { selected ->
        withContext(Dispatchers.IO) { load(selected) }
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(stopTimeoutMillis = 5_000),
        initialValue = loadInitial(),
    )

    val state: StateFlow<TaskHomeUiState> = combine(loaded, starredOnly, selectedIds, errorMessage) { home, starFilter, selected, error ->
        val applyStar = starFilter && (home.location as? TaskHomeLocation.SmartList)?.destinationId != RegistryDestinationIds.STARRED
        TaskHomeUiState(
            hasLoaded = home.hasLoaded,
            location = home.location,
            topSmartLists = home.topSmartLists,
            bottomSmartLists = home.bottomSmartLists,
            areas = home.areas,
            projects = home.projects,
            inboxTasks = if (applyStar) home.inboxTasks.filter(TaskListItem::isStarred) else home.inboxTasks,
            tasks = if (applyStar) home.tasks.filter(TaskListItem::isStarred) else home.tasks,
            deletedTasks = home.deletedTasks,
            canQuickAdd = home.canQuickAdd,
            canComplete = home.canComplete,
            agentsPaused = home.agentsPaused,
            reviewCount = home.reviewCount,
            starredOnly = applyStar,
            selectedIds = selected,
            fadedSweepItems = home.fadedSweepItems,
            weeklySweepItems = home.weeklySweepItems,
            showWeeklySweepBanner = home.showWeeklySweepBanner,
            errorMessage = error,
        )
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(stopTimeoutMillis = 5_000),
        initialValue = TaskHomeUiState(),
    )

    fun select(location: TaskHomeLocation) {
        selectedIds.value = emptySet()
        starredOnly.value = false
        this.location.value = location
    }

    fun toggleStarFilter() {
        starredOnly.value = !starredOnly.value
    }

    /** Long-press enters selection with the row; in selection a tap adds or removes a row. */
    fun toggleSelection(id: String) {
        selectedIds.value = selectedIds.value.let { if (id in it) it - id else it + id }
    }

    fun clearSelection() {
        selectedIds.value = emptySet()
    }

    fun setAreaEmoji(areaId: String, emoji: String?) {
        viewModelScope.launch {
            runCatching {
                withContext(Dispatchers.IO) {
                    graph.registryEntityMutator.update(
                        EntityNames.AREA,
                        areaId,
                        mapOf(RegistryEntityFields.Area.EMOJI to JsonValue.stringOrNull(emoji?.takeIf(String::isNotBlank))),
                    ) != null
                }
            }.onSuccess { changed ->
                errorMessage.value = null
                if (changed) noteLocalChangeAndSync()
            }.onFailure { errorMessage.value = it.message }
        }
    }

    fun createArea(title: String, onCreated: (TaskHomeLocation.Area) -> Unit = {}) {
        val trimmed = title.trim()
        if (trimmed.isEmpty()) return
        viewModelScope.launch {
            runCatching {
                withContext(Dispatchers.IO) {
                    val created = graph.registryEntityMutator.create(
                        EntityNames.AREA,
                        mapOf(RegistryEntityFields.Area.TITLE to JsonValue.StringValue(trimmed)),
                    )
                    TaskHomeLocation.Area(created.id, trimmed)
                }
            }.onSuccess { area ->
                errorMessage.value = null
                noteLocalChangeAndSync()
                onCreated(area)
            }.onFailure { errorMessage.value = it.message }
        }
    }

    fun createProject(title: String, areaId: String? = null, onCreated: (TaskHomeLocation.Project) -> Unit = {}) {
        val trimmed = title.trim()
        if (trimmed.isEmpty()) return
        viewModelScope.launch {
            runCatching {
                withContext(Dispatchers.IO) {
                    val fields = buildMap<String, JsonValue> {
                        put(RegistryEntityFields.Project.TITLE, JsonValue.StringValue(trimmed))
                        put(RegistryEntityFields.Project.STATUS, JsonValue.StringValue(RegistryEntityEnums.ProjectStatus.ACTIVE))
                        areaId?.let { put(RegistryEntityFields.Project.AREA, JsonValue.StringValue(it)) }
                    }
                    val created = graph.registryEntityMutator.create(EntityNames.PROJECT, fields)
                    TaskHomeLocation.Project(created.id, trimmed)
                }
            }.onSuccess { project ->
                errorMessage.value = null
                noteLocalChangeAndSync()
                onCreated(project)
            }.onFailure { errorMessage.value = it.message }
        }
    }

    /** True while a Quick Add write runs, so a second tap on Add cannot create a second task. */
    private var quickAddRunning = false

    /**
     * Creates the Quick Add task. The core decides the date fields (When and
     * deadline go through the same date actions as the task page), and Undo
     * removes the new task in one step. Once the row exists the sheet closes,
     * also when a later field write fails: a retry would create it twice.
     */
    fun quickAdd(draft: QuickAddDraft, onSaved: (taskId: String) -> Unit) {
        val title = draft.title.trim()
        if (title.isEmpty() || quickAddRunning) return
        quickAddRunning = true
        errorMessage.value = null
        viewModelScope.launch {
            runCatching {
                withContext(Dispatchers.IO) {
                    val created = graph.taskMutator.create(
                        title = title,
                        area = if (draft.projectId == null) draft.areaId else null,
                        project = draft.projectId,
                        today = draft.today && draft.whenDay == null,
                        notes = draft.notes.trim().takeIf(String::isNotEmpty),
                        heading = if (draft.projectId != null) draft.headingId else null,
                        position = draft.position,
                    )
                    val fields = runCatching {
                        draft.whenDay?.let { graph.taskMutator.setWhen(created.id, it) }
                        draft.deadline?.let { graph.taskMutator.setDeadline(created.id, it) }
                        if (draft.starred) graph.taskMutator.setStarred(created.id, true)
                        if (draft.useTodayPosition && draft.position != null) {
                            graph.taskMutator.updateFields(
                                created.id,
                                mapOf(RegistryEntityFields.Task.TODAY_POSITION to JsonValue.DecimalValue(draft.position)),
                            )
                        }
                    }
                    graph.taskUndoHistory.recordCreated(created.asSyncRecord())
                    created.id to fields.exceptionOrNull()
                }
            }
                .onSuccess { (taskId, fieldError) ->
                    errorMessage.value = fieldError?.message
                    noteLocalChangeAndSync()
                    onSaved(taskId)
                }
                .onFailure { errorMessage.value = it.message }
            quickAddRunning = false
        }
    }

    /** The selected titles, one per line in list order, for the clipboard. */
    fun copySelection(onReady: (String) -> Unit) {
        val ids = selectedIds.value
        viewModelScope.launch {
            runCatching {
                withContext(Dispatchers.IO) {
                    val order = state.value.let { home -> (home.inboxTasks + home.tasks).map { it.id } }
                    ids.sortedBy { id -> order.indexOf(id).let { if (it < 0) Int.MAX_VALUE else it } }
                        .mapNotNull { id ->
                            graph.taskStore.record(EntityNames.TASK, id)
                                ?.fields?.get(RegistryEntityFields.Task.TITLE).stringValue()
                        }
                        .joinToString("\n")
                }
            }.onSuccess { text ->
                clearSelection()
                if (text.isNotEmpty()) onReady(text)
            }.onFailure { errorMessage.value = it.message }
        }
    }

    /** Selects every row of the list, or clears the selection when all are selected. */
    fun toggleSelectAll() {
        val visible = state.value.let { home -> (home.inboxTasks + home.tasks).map { it.id } }.toSet()
        selectedIds.value = if (selectedIds.value.containsAll(visible)) emptySet() else visible
    }

    /** True when every task in [ids] is on Today, so the batch Today action removes them. */
    suspend fun allOnToday(ids: Set<String>): Boolean = withContext(Dispatchers.IO) {
        if (ids.isEmpty()) return@withContext false
        val now = graph.clock.now()
        val today = graph.clock.today(now)
        ids.all { id ->
            val record = graph.taskStore.record(EntityNames.TASK, id) ?: return@all false
            val snapshot = runCatching { TaskSnapshot.from(record) }.getOrNull() ?: return@all false
            TaskViewRules.membership(snapshot, today, now).isOnToday
        }
    }

    /** Complete, Cancel, Delete or Today on the whole selection, as one undo step. */
    fun applyToSelection(actionId: String, todayEnabled: Boolean = true) {
        batch { id ->
            when (actionId) {
                RegistryActionIds.TASK_TOGGLE_COMPLETE -> graph.taskMutator.complete(id)
                RegistryActionIds.TASK_CANCEL -> graph.taskMutator.cancel(id)
                RegistryActionIds.TASK_DELETE -> graph.taskMutator.delete(id)
                RegistryActionIds.TASK_TOGGLE_TODAY -> graph.taskMutator.setToday(id, todayEnabled)
                else -> error("Unsupported batch action: $actionId")
            }
        }
    }

    /** When for the whole selection; null clears it. */
    fun setWhenForSelection(day: String?) {
        batch { id -> graph.taskMutator.setWhen(id, day) }
    }

    /** Move the whole selection to an area, a project, or (both null) the Inbox. */
    fun moveSelection(areaId: String?, projectId: String?) {
        batch { id -> graph.taskMutator.moveToList(id, areaId, projectId) }
    }

    /**
     * Reorders [ids] in place (and optionally files them into [targetGroupKey] or Inbox)
     * as one undoable edit, writing `todayPosition` on Today and `position` elsewhere
     * (`docs/DRAG_AND_DROP.md` §4–5).
     */
    fun reorderTasks(
        ids: List<String>,
        positions: List<Double>,
        useTodayPosition: Boolean,
        targetGroupKey: String? = null,
        moveToInbox: Boolean = false,
    ) {
        if (ids.isEmpty() || positions.size < ids.size) return
        val positionKey = if (useTodayPosition) {
            RegistryEntityFields.Task.TODAY_POSITION
        } else {
            RegistryEntityFields.Task.POSITION
        }
        selectedIds.value = emptySet()
        viewModelScope.launch {
            runCatching {
                withContext(Dispatchers.IO) {
                    val ordered = ids.zip(positions)
                    graph.captureTaskEdits(ids.toSet()) { id ->
                        val pos = ordered.firstOrNull { it.first == id }?.second ?: return@captureTaskEdits
                        val changes = linkedMapOf<String, JsonValue>(
                            positionKey to JsonValue.DecimalValue(pos),
                        )
                        when {
                            moveToInbox -> {
                                changes[RegistryEntityFields.Task.AREA] = JsonValue.Null
                                changes[RegistryEntityFields.Task.PROJECT] = JsonValue.Null
                                changes[RegistryEntityFields.Task.HEADING] = JsonValue.Null
                            }
                            targetGroupKey != null && targetGroupKey.startsWith("area:") -> {
                                changes[RegistryEntityFields.Task.AREA] = JsonValue.StringValue(targetGroupKey.removePrefix("area:"))
                                changes[RegistryEntityFields.Task.PROJECT] = JsonValue.Null
                                changes[RegistryEntityFields.Task.HEADING] = JsonValue.Null
                            }
                            targetGroupKey != null && targetGroupKey.startsWith("project:") -> {
                                changes[RegistryEntityFields.Task.AREA] = JsonValue.Null
                                changes[RegistryEntityFields.Task.PROJECT] = JsonValue.StringValue(targetGroupKey.removePrefix("project:"))
                                changes[RegistryEntityFields.Task.HEADING] = JsonValue.Null
                            }
                        }
                        graph.taskMutator.updateFields(id, changes)
                    }
                }
            }.onSuccess {
                errorMessage.value = null
                noteLocalChangeAndSync()
            }.onFailure { errorMessage.value = it.message }
        }
    }

    private fun batch(write: suspend (String) -> Unit) {
        val ids = selectedIds.value
        if (ids.isEmpty()) return
        selectedIds.value = emptySet()
        viewModelScope.launch {
            runCatching {
                withContext(Dispatchers.IO) { graph.captureTaskEdits(ids) { id -> write(id) } }
            }.onSuccess { errorMessage.value = null; noteLocalChangeAndSync() }
                .onFailure { errorMessage.value = it.message; noteLocalChangeAndSync() }
        }
    }

    fun complete(id: String) {
        viewModelScope.launch {
            runCatching {
                withContext(Dispatchers.IO) {
                    graph.captureTaskEdit(id) { graph.taskMutator.complete(id) }
                }
            }
                .onSuccess {
                    errorMessage.value = null
                    noteLocalChangeAndSync()
                }
                .onFailure { errorMessage.value = it.message }
        }
    }

    fun toggleStar(id: String) {
        viewModelScope.launch {
            runCatching {
                withContext(Dispatchers.IO) {
                    val record = graph.taskStore.record(EntityNames.TASK, id) ?: error("Task is unavailable")
                    val starred = record.fields[RegistryEntityFields.Task.STARRED].booleanValue() == true
                    graph.captureTaskEdit(id) {
                        check(graph.taskMutator.setStarred(id, !starred) != null)
                    }
                }
            }.onSuccess { errorMessage.value = null; noteLocalChangeAndSync() }
                .onFailure { errorMessage.value = it.message }
        }
    }

    fun delete(id: String) {
        viewModelScope.launch {
            runCatching {
                withContext(Dispatchers.IO) {
                    graph.captureTaskEdit(id) { check(graph.taskMutator.delete(id) != null) }
                }
            }.onSuccess { errorMessage.value = null; noteLocalChangeAndSync() }
                .onFailure { errorMessage.value = it.message }
        }
    }

    fun acceptReview(id: String) {
        viewModelScope.launch {
            runCatching {
                withContext(Dispatchers.IO) { check(graph.acceptReview(id)) }
            }.onSuccess { errorMessage.value = null; noteLocalChangeAndSync() }
                .onFailure { errorMessage.value = it.message }
        }
    }

    fun keepFaded(id: String) = editTask(id) { graph.taskMutator.keepFaded(id) }

    fun letGoFaded(id: String) = editTask(id) { graph.taskMutator.letGoFaded(id) }

    /** One-tap filing from an Inbox suggestion capsule (`edit.filing-suggestion`, #368). */
    fun applyFilingSuggestion(id: String) {
        val suggestion = filingSuggestionsByTask[id] ?: return
        val changes = when (suggestion.kind) {
            FilingSuggestion.Kind.AREA -> mapOf(
                RegistryEntityFields.Task.AREA to JsonValue.StringValue(suggestion.id),
                RegistryEntityFields.Task.PROJECT to JsonValue.Null,
            )
            FilingSuggestion.Kind.PROJECT -> mapOf(
                RegistryEntityFields.Task.AREA to JsonValue.Null,
                RegistryEntityFields.Task.PROJECT to JsonValue.StringValue(suggestion.id),
            )
        }
        editTask(id) { graph.taskMutator.updateFields(id, changes) }
    }

    /** Drops all remaining sweep rows in ONE undo entry (`docs/TASK_FADE_SPEC.md` §5). */
    fun letGoFadedBatch(ids: List<String>) {
        if (ids.isEmpty()) return
        viewModelScope.launch {
            runCatching {
                withContext(Dispatchers.IO) {
                    graph.captureTaskEdits(ids) { id -> graph.taskMutator.letGoFaded(id) }
                }
            }.onSuccess { errorMessage.value = null; noteLocalChangeAndSync() }
                .onFailure { errorMessage.value = it.message; noteLocalChangeAndSync() }
        }
    }

    fun dismissWeeklySweepBanner() {
        graph.fadeSweepStore.dismissSweepForCurrentWeek(graph.clock.now())
        sweepRefresh.value += 1
    }

    fun markSweepCompleted() {
        graph.fadeSweepStore.markSweepCompleted(graph.clock.now())
        sweepRefresh.value += 1
    }

    /** One undoable task edit off the main thread, then a sync. */
    private fun editTask(id: String, edit: suspend () -> Any?) {
        viewModelScope.launch {
            runCatching {
                withContext(Dispatchers.IO) {
                    graph.captureTaskEdit(id) { check(edit() != null) }
                }
            }.onSuccess { errorMessage.value = null; noteLocalChangeAndSync() }
                .onFailure { errorMessage.value = it.message }
        }
    }

    fun restore(id: String) {
        viewModelScope.launch {
            runCatching {
                withContext(Dispatchers.IO) {
                    graph.captureTaskEdit(id) { check(graph.taskMutator.restore(id) != null) }
                }
            }.onSuccess { errorMessage.value = null; noteLocalChangeAndSync() }
                .onFailure { errorMessage.value = it.message }
        }
    }

    /** Permanently deletes one or more trashed tasks (Delete Permanently / Empty Trash, #460). */
    fun purgeTasks(ids: List<String>) {
        if (ids.isEmpty()) return
        viewModelScope.launch {
            runCatching {
                withContext(Dispatchers.IO) {
                    for (id in ids) {
                        graph.taskMutator.purge(id)
                    }
                }
            }.onSuccess {
                clearSelection()
                errorMessage.value = null
                noteLocalChangeAndSync()
            }.onFailure { errorMessage.value = it.message }
        }
    }

    fun duplicate(id: String) {
        viewModelScope.launch {
            runCatching {
                withContext(Dispatchers.IO) {
                    val copy = graph.taskMutator.duplicate(id) ?: error("Task is unavailable")
                    graph.taskUndoHistory.recordCreated(copy.asSyncRecord())
                }
            }.onSuccess { errorMessage.value = null; noteLocalChangeAndSync() }
                .onFailure { errorMessage.value = it.message }
        }
    }

    fun shareText(id: String, onReady: (String) -> Unit) {
        viewModelScope.launch {
            runCatching {
                withContext(Dispatchers.IO) {
                    val task = graph.taskStore.record(EntityNames.TASK, id) ?: error("Task is unavailable")
                    val title = task.fields[RegistryEntityFields.Task.TITLE].stringValue().orEmpty()
                    val notes = task.fields[RegistryEntityFields.Task.NOTES].stringValue()
                        ?.trim()
                        .orEmpty()
                    if (notes.isEmpty()) title else "$title\n\n$notes"
                }
            }.onSuccess(onReady).onFailure { errorMessage.value = it.message }
        }
    }

    fun setAgentsPaused(paused: Boolean) {
        viewModelScope.launch {
            runCatching {
                withContext(Dispatchers.IO) {
                    graph.syncedSettingsMutator.set(
                        RegistrySettingKeys.AGENTS_PAUSED,
                        JsonValue.BooleanValue(paused),
                    )
                }
            }.onSuccess {
                errorMessage.value = null
                noteLocalChangeAndSync()
            }.onFailure { errorMessage.value = it.message }
        }
    }

    private fun noteLocalChangeAndSync() {
        graph.sync.noteLocalChange()
        graph.sync.requestSync()
    }

    private fun loadInitial() = LoadedTaskHome(
        hasLoaded = false,
        location = TaskHomeLocation.SmartList(RegistryDestinationIds.TODAY),
        topSmartLists = emptyList(),
        bottomSmartLists = emptyList(),
        areas = emptyList(),
        projects = emptyList(),
        inboxTasks = emptyList(),
        tasks = emptyList(),
        canQuickAdd = false,
        canComplete = true,
        agentsPaused = false,
    )

    private suspend fun load(selected: TaskHomeLocation): LoadedTaskHome {
        val selectedDestId = (selected as? TaskHomeLocation.SmartList)?.destinationId
        val needsFullHistory = selectedDestId == RegistryDestinationIds.LOGBOOK ||
            selectedDestId == RegistryDestinationIds.AGENT
        // Fast path for Today / active lists: read only open + soft-deleted tasks (skips thousands of Logbook rows).
        val taskRecords = if (needsFullHistory) {
            graph.taskStore.records(EntityNames.TASK)
        } else {
            graph.taskStore.activeTasks()
        }
        val areaRecords = graph.taskStore.records(EntityNames.AREA)
            .filter { it.deletedAt == null }
            .mapNotNull { record ->
                record.fields[RegistryEntityFields.Area.TITLE].stringValue()?.let { title ->
                    val position = record.fields[RegistryEntityFields.Area.POSITION].numberValue()
                    Triple(
                        position,
                        title.lowercase(),
                        TaskHomeNavigationItem(
                            location = TaskHomeLocation.Area(record.id, title),
                            title = title,
                            emoji = record.fields[RegistryEntityFields.Area.EMOJI].stringValue()?.takeIf(String::isNotBlank),
                        ),
                    )
                }
            }
            .sortedWith(compareBy<Triple<Double?, String, TaskHomeNavigationItem>>({ it.first ?: Double.MAX_VALUE }, { it.second }))
            .map { it.third }
        val projectRecords = graph.taskStore.records(EntityNames.PROJECT)
            .filter { it.deletedAt == null }
            .filter {
                val status = it.fields[RegistryEntityFields.Project.STATUS].stringValue()
                status == null || status == RegistryEntityEnums.ProjectStatus.ACTIVE
            }
            .mapNotNull { record ->
                record.fields[RegistryEntityFields.Project.TITLE].stringValue()?.let { title ->
                    val position = record.fields[RegistryEntityFields.Project.POSITION].numberValue()
                    val parentAreaId = record.fields[RegistryEntityFields.Project.AREA].stringValue()
                        ?.takeIf(String::isNotBlank)
                    Triple(
                        position,
                        title.lowercase(),
                        TaskHomeNavigationItem(
                            location = TaskHomeLocation.Project(record.id, title),
                            title = title,
                            parentAreaId = parentAreaId,
                        ),
                    )
                }
            }
            .sortedWith(compareBy<Triple<Double?, String, TaskHomeNavigationItem>>({ it.first ?: Double.MAX_VALUE }, { it.second }))
            .map { it.third }

        val agentsPaused = graph.syncedSettings.value(RegistrySettingKeys.AGENTS_PAUSED).booleanValue() ?: false

        val areaTitles = areaRecords.mapNotNull { item ->
            val area = item.location as? TaskHomeLocation.Area ?: return@mapNotNull null
            area.id to area.title
        }.toMap()
        val projectTitles = projectRecords.mapNotNull { item ->
            val project = item.location as? TaskHomeLocation.Project ?: return@mapNotNull null
            project.id to project.title
        }.toMap()

        val allSnapshots = taskRecords.mapNotNull { record ->
            runCatching { record to TaskSnapshot.from(record) }.getOrNull()
        }
        val metadataCatalog = TaskRowMetadataCatalog.load(graph.taskStore)
        val now = graph.clock.now()
        val today = graph.clock.today(now)
        // Load all turns in 2 bulk queries (cached) and evaluate only relevant conversations ONCE.
        val turnsByTask = graph.taskStore.allTurnsByTask()
        val relevantTaskIds = if (needsFullHistory) null else allSnapshots.mapTo(HashSet(allSnapshots.size)) { it.second.id }
        val convoRecords = graph.taskStore.records(EntityNames.CONVO)
            .asSequence()
            .filter { it.deletedAt == null }
            .filter { relevantTaskIds == null || it.id in relevantTaskIds }
            .associateBy(SyncRecord::id)
        val conversations = convoRecords.mapValues { (id, record) ->
            runCatching { TaskConversation.from(record, turnsByTask[id].orEmpty()) }.getOrNull()
        }
        val projectParentAreaTitle = projectRecords.mapNotNull { item ->
            val proj = item.location as? TaskHomeLocation.Project ?: return@mapNotNull null
            val areaTitle = item.parentAreaId?.let(areaTitles::get) ?: return@mapNotNull null
            proj.id to areaTitle
        }.toMap()
        val reviewFallback = RegistryCatalog.surface(RegistryTaskPageBlockIds.TASK_PAGE_CONVERSATION)
            ?.fields?.get("reviewFallback")?.stringValue().orEmpty()
        val inboxLabel = RegistryCatalog.destinationTitle(RegistryDestinationIds.INBOX).orEmpty()
        val convoStates = HashMap<String, app.septena.core.ConversationSnapshotState>(conversations.size)
        for ((id, convo) in conversations) {
            if (convo != null) {
                runCatching { convo.evaluate(now) }.getOrNull()?.let { convoStates[id] = it }
            }
        }

        // Compute core TaskViewMembership ONCE per open non-heading non-deleted task
        // (avoids ~8,000 redundant JNA roundtrips across Done/Cancelled Logbook rows).
        val memberships = HashMap<String, app.septena.core.TaskViewMembership>(allSnapshots.size)
        var todayCount = 0
        var upcomingCount = 0
        var repeatingCount = 0
        var anytimeCount = 0
        var reviewCount = 0
        var agentCount = 0
        var starredCount = 0
        var fadedCount = 0
        var deletedCount = 0
        val zoneId = java.time.ZoneId.systemDefault()
        var doneTodayCount = if (needsFullHistory) 0 else graph.taskStore.countDoneTasksOnLocalDay(today, zoneId)
        val projectOpenCounts = mutableMapOf<String, Int>()
        val projectDoneCounts = mutableMapOf<String, Int>()
        val areaDirectOpenCounts = mutableMapOf<String, Int>()
        val activeProjectAreaById = projectRecords.mapNotNull { item ->
            val proj = item.location as? TaskHomeLocation.Project ?: return@mapNotNull null
            item.parentAreaId?.let { proj.id to it }
        }.toMap()

        val fadedSweepList = mutableListOf<FadeSweepItem>()
        for ((record, snapshot) in allSnapshots) {
            if (snapshot.isHeading) continue
            if (snapshot.deletedAt != null) {
                deletedCount += 1
                continue
            }
            val convoState = convoStates[snapshot.id]
            if (convoState?.agentStage != null) agentCount += 1

            when (snapshot.status) {
                RegistryEntityEnums.TaskStatus.OPEN -> {
                    val membership = TaskViewRules.membership(snapshot, today, now)
                    memberships[snapshot.id] = membership
                    if (membership.matchesView[RegistryDestinationIds.TODAY] == true) todayCount += 1
                    if (membership.matchesView[RegistryDestinationIds.UPCOMING] == true) upcomingCount += 1
                    if (membership.matchesView[RegistryDestinationIds.ANYTIME] == true) anytimeCount += 1
                    if (TaskViewRules.matchesView(snapshot, membership, RegistryDestinationIds.REPEATING)) repeatingCount += 1
                    if (convoState?.needsHumanReview == true) reviewCount += 1
                    if (TaskFadeRules.isFaded(snapshot.fadedAt)) {
                        fadedCount += 1
                        val fadedInstant = snapshot.fadedAt?.let { runCatching { java.time.Instant.parse(it) }.getOrNull() }
                        val touchedInstant = snapshot.touchedAt?.let { runCatching { java.time.Instant.parse(it) }.getOrNull() }
                        val createdInstant = snapshot.createdAt?.let { runCatching { java.time.Instant.parse(it) }.getOrNull() }
                        val listName = snapshot.project?.let(projectTitles::get) ?: snapshot.area?.let(areaTitles::get)
                        fadedSweepList += FadeSweepItem(
                            id = snapshot.id,
                            title = snapshot.title,
                            reason = FadeSweepRules.sweepReason(
                                touchedAt = touchedInstant,
                                createdAt = createdInstant,
                                created = snapshot.created,
                                listName = listName,
                                scheduled = snapshot.scheduled,
                                now = now,
                                inboxLabel = inboxLabel,
                                zoneId = zoneId,
                            ),
                            fadedAt = fadedInstant,
                        )
                    } else {
                        if (snapshot.starred) starredCount += 1
                        val projId = snapshot.project
                        val areaId = snapshot.area
                        if (projId != null) {
                            projectOpenCounts[projId] = (projectOpenCounts[projId] ?: 0) + 1
                        } else if (areaId != null) {
                            areaDirectOpenCounts[areaId] = (areaDirectOpenCounts[areaId] ?: 0) + 1
                        }
                    }
                }
                RegistryEntityEnums.TaskStatus.DONE -> {
                    val completedAt = record.fields[RegistryEntityFields.Task.COMPLETED_AT].stringValue()
                    val completedDay = completedAt?.let {
                        runCatching { java.time.Instant.parse(it).atZone(zoneId).toLocalDate() }.getOrNull()
                            ?: runCatching { java.time.LocalDate.parse(it.take(10)) }.getOrNull()
                    }
                    if (completedDay == today) doneTodayCount += 1
                    snapshot.project?.let { projId ->
                        projectDoneCounts[projId] = (projectDoneCounts[projId] ?: 0) + 1
                    }
                }
            }
        }

        val areaRolledUpCounts = mutableMapOf<String, Int>().apply {
            areaDirectOpenCounts.forEach { (areaId, count) -> put(areaId, count) }
            projectOpenCounts.forEach { (projId, count) ->
                val parentArea = activeProjectAreaById[projId] ?: return@forEach
                put(parentArea, (this[parentArea] ?: 0) + count)
            }
        }

        val countedAreas = areaRecords.map { item ->
            val areaId = (item.location as? TaskHomeLocation.Area)?.id
            item.copy(count = areaId?.let { areaRolledUpCounts[it] ?: 0 } ?: 0)
        }
        val countedProjects = projectRecords.map { item ->
            val projId = (item.location as? TaskHomeLocation.Project)?.id
            val open = projId?.let { projectOpenCounts[it] ?: 0 } ?: 0
            val done = projId?.let { projectDoneCounts[it] ?: 0 } ?: 0
            val total = open + done
            item.copy(
                count = open,
                progress = if (total > 0) done.toFloat() / total.toFloat() else 0f,
            )
        }

        val nonEmptyDestinations = buildSet {
            if (reviewCount > 0 || (selected as? TaskHomeLocation.SmartList)?.destinationId == RegistryDestinationIds.REVIEW) {
                add(RegistryDestinationIds.REVIEW)
            }
            if (agentCount > 0 || (selected as? TaskHomeLocation.SmartList)?.destinationId == RegistryDestinationIds.AGENT) {
                add(RegistryDestinationIds.AGENT)
            }
            if (starredCount > 0) add(RegistryDestinationIds.STARRED)
            if (fadedCount > 0) add(RegistryDestinationIds.FADED)
            if (deletedCount > 0) add(RegistryDestinationIds.RECENTLY_DELETED)
        }

        fun smartListCount(destinationId: String): Int? = when (destinationId) {
            RegistryDestinationIds.TODAY -> todayCount
            RegistryDestinationIds.UPCOMING -> upcomingCount
            RegistryDestinationIds.REPEATING -> repeatingCount
            RegistryDestinationIds.ANYTIME -> anytimeCount
            RegistryDestinationIds.REVIEW -> reviewCount.takeIf { it > 0 }
            RegistryDestinationIds.AGENT -> agentCount.takeIf { it > 0 }
            RegistryDestinationIds.STARRED -> starredCount.takeIf { it > 0 }
            RegistryDestinationIds.LOGBOOK -> doneTodayCount.takeIf { it > 0 }
            RegistryDestinationIds.FADED -> fadedCount.takeIf { it > 0 }
            RegistryDestinationIds.RECENTLY_DELETED -> deletedCount.takeIf { it > 0 }
            else -> null
        }

        val topSmartListItems = SmartListResolver.visibleFromSynced(
            graph.syncedSettings,
            nonEmptyIds = nonEmptyDestinations,
            section = SmartListSection.TOP,
        ).filter { it.id in SHELL_DESTINATIONS }
            .map {
                TaskHomeNavigationItem(
                    location = TaskHomeLocation.SmartList(it.id),
                    count = smartListCount(it.id),
                )
            }
        val bottomSmartListItems = SmartListResolver.visibleFromSynced(
            graph.syncedSettings,
            nonEmptyIds = nonEmptyDestinations,
            section = SmartListSection.BOTTOM,
        ).filter { it.id in SHELL_DESTINATIONS }
            .map {
                TaskHomeNavigationItem(
                    location = TaskHomeLocation.SmartList(it.id),
                    count = smartListCount(it.id),
                )
            }
        val agentGroups = agentGroupTitles()
        val showAging = graph.deviceSettings.bool(RegistrySettingKeys.TASKS_SHOW_AGING)
        val resolvedLocation = when (selected) {
            is TaskHomeLocation.Area -> areaRecords.firstOrNull {
                (it.location as? TaskHomeLocation.Area)?.id == selected.id
            }?.location ?: selected
            is TaskHomeLocation.Project -> projectRecords.firstOrNull {
                (it.location as? TaskHomeLocation.Project)?.id == selected.id
            }?.location ?: selected
            is TaskHomeLocation.SmartList -> selected
        }

        val inbox = mutableListOf<PositionedTask>()
        val visible = mutableListOf<PositionedTask>()
        val deleted = mutableListOf<PositionedTask>()
        val currentDestinationId = (resolvedLocation as? TaskHomeLocation.SmartList)?.destinationId
        val filingSuggestionsEnabled = graph.deviceSettings.bool(RegistrySettingKeys.TASKS_FILING_SUGGESTIONS)
        val shouldSuggestInline = filingSuggestionsEnabled && (
            currentDestinationId == RegistryDestinationIds.TODAY ||
                currentDestinationId == RegistryDestinationIds.INBOX
            )
        val nextSuggestions = linkedMapOf<String, FilingSuggestion>()
        if (shouldSuggestInline && (areaRecords.isNotEmpty() || projectRecords.isNotEmpty())) {
            val training = allSnapshots.map { (rec, snap) ->
                FilingTrainingTask(
                    id = snap.id,
                    title = snap.title,
                    notes = rec.fields[RegistryEntityFields.Task.NOTES].stringValue(),
                    areaId = snap.area,
                    projectId = snap.project,
                    isCancelled = snap.status == RegistryEntityEnums.TaskStatus.CANCELLED,
                )
            }
            val areaTargets = areaRecords.mapNotNull { item ->
                val a = item.location as? TaskHomeLocation.Area ?: return@mapNotNull null
                FilingTarget(FilingSuggestion.Kind.AREA, a.id, a.title)
            }
            val projectTargets = projectRecords.mapNotNull { item ->
                val p = item.location as? TaskHomeLocation.Project ?: return@mapNotNull null
                FilingTarget(FilingSuggestion.Kind.PROJECT, p.id, p.title)
            }
            graph.filingSuggestions.prepare(training, areaTargets, projectTargets)
        }
        for ((record, snapshot) in allSnapshots) {
            val membership = memberships[snapshot.id] ?: TaskViewRules.INACTIVE_MEMBERSHIP
            when (resolvedLocation) {
                is TaskHomeLocation.SmartList -> {
                    if (resolvedLocation.destinationId == RegistryDestinationIds.LOGBOOK &&
                        snapshot.deletedAt != null &&
                        !snapshot.isHeading
                    ) {
                        val deletedItem = taskListItem(
                            record = record,
                            snapshot = snapshot,
                            membership = membership,
                            selected = resolvedLocation,
                            areaTitles = areaTitles,
                            projectTitles = projectTitles,
                            catalog = metadataCatalog,
                            today = today,
                            now = now,
                            showTodayIndicator = false,
                            isLogbook = true,
                        )
                        deleted += PositionedTask(
                            item = deletedItem,
                            position = null,
                            archiveDate = record.deletedAt,
                            areaId = snapshot.area,
                            projectId = snapshot.project,
                        )
                        continue
                    }
                    val conversation = conversations[snapshot.id]
                    val convoState = convoStates[snapshot.id]
                    val stage = convoState?.agentStage
                    val listed = when (resolvedLocation.destinationId) {
                        // Review: open tasks an agent handed back to verify.
                        RegistryDestinationIds.REVIEW ->
                            snapshot.status == RegistryEntityEnums.TaskStatus.OPEN && !snapshot.isHeading &&
                                snapshot.deletedAt == null && convoState?.needsHumanReview == true
                        // Agent: every task with an agent stage, grouped by stage.
                        RegistryDestinationIds.AGENT ->
                            stage != null && !snapshot.isHeading && snapshot.deletedAt == null
                        else -> TaskViewRules.matchesView(snapshot, membership, resolvedLocation.destinationId)
                    }
                    if (!listed) continue
                    val inTodayInbox = resolvedLocation.destinationId == RegistryDestinationIds.TODAY && membership.inTodayInbox
                    val isLooseTodayCapture = resolvedLocation.destinationId == RegistryDestinationIds.TODAY &&
                        snapshot.status == RegistryEntityEnums.TaskStatus.OPEN &&
                        snapshot.scheduled == null &&
                        snapshot.deadline == null &&
                        snapshot.area == null &&
                        snapshot.project == null &&
                        snapshot.today
                    val suggestedTarget = if (shouldSuggestInline &&
                        snapshot.project == null &&
                        (inTodayInbox || isLooseTodayCapture || resolvedLocation.destinationId == RegistryDestinationIds.INBOX)
                    ) {
                        graph.filingSuggestions.suggest(
                            title = snapshot.title,
                            notes = record.fields[RegistryEntityFields.Task.NOTES].stringValue(),
                        )?.takeUnless { s ->
                            (s.kind == FilingSuggestion.Kind.AREA && snapshot.area == s.id) ||
                                (s.kind == FilingSuggestion.Kind.PROJECT && snapshot.project == s.id)
                        }?.also { nextSuggestions[snapshot.id] = it }
                    } else null
                    val item = taskListItem(
                        record = record,
                        snapshot = snapshot,
                        membership = membership,
                        selected = resolvedLocation,
                        areaTitles = areaTitles,
                        projectTitles = projectTitles,
                        catalog = metadataCatalog,
                        today = today,
                        now = now,
                        showTodayIndicator = resolvedLocation.destinationId != RegistryDestinationIds.TODAY && !inTodayInbox,
                        isLogbook = resolvedLocation.destinationId == RegistryDestinationIds.LOGBOOK,
                    ).withFade(snapshot, conversation, convoState, now, today, showAging)
                        .let { base ->
                            if (suggestedTarget != null) base.copy(filingSuggestionLabel = suggestedTarget.title) else base
                        }
                    val rowPosition = record.fields[positionField(resolvedLocation.destinationId)].numberValue()
                        ?: record.fields[RegistryEntityFields.Task.POSITION].numberValue()
                    val positioned = PositionedTask(
                        when (resolvedLocation.destinationId) {
                            RegistryDestinationIds.AGENT -> {
                                val stageTitle = agentGroups[stage]
                                item.copy(
                                    group = stageTitle?.let {
                                        TaskGroupHeader(
                                            key = "agent:${stage.orEmpty()}",
                                            title = it,
                                            iconKind = SeptenaIconKind.None,
                                        )
                                    },
                                    groupTitle = stageTitle,
                                    position = rowPosition,
                                )
                            }
                            RegistryDestinationIds.REVIEW -> {
                                val note = conversation?.endStateNote?.trim()?.takeIf(String::isNotEmpty)
                                    ?: reviewFallback
                                val projTitle = snapshot.project?.let(projectTitles::get)
                                val areaTitle = snapshot.area?.let(areaTitles::get)
                                    ?: snapshot.project?.let(projectParentAreaTitle::get)
                                val listLabel = when {
                                    areaTitle != null && projTitle != null -> "$areaTitle › $projTitle"
                                    projTitle != null -> projTitle
                                    areaTitle != null -> areaTitle
                                    else -> inboxLabel
                                }
                                val askedAgo = relativeAgo(conversation?.endStateAt)?.let { "asked $it" }
                                val artifactTitle = (convoRecords[snapshot.id]?.fields?.get("artifact") as? JsonValue.ObjectValue)
                                    ?.fields?.get("title")?.stringValue()?.trim()?.takeIf(String::isNotEmpty)
                                val metaLine = listOfNotNull(listLabel, askedAgo, artifactTitle)
                                    .joinToString(" · ")
                                item.copy(
                                    position = rowPosition,
                                    reviewNote = note,
                                    reviewMeta = metaLine,
                                )
                            }
                            else -> item.copy(position = rowPosition)
                        },
                        rowPosition,
                        archiveDate = when (resolvedLocation.destinationId) {
                            RegistryDestinationIds.LOGBOOK ->
                                record.fields[RegistryEntityFields.Task.COMPLETED_AT].stringValue()
                            RegistryDestinationIds.RECENTLY_DELETED -> record.deletedAt
                            else -> null
                        },
                        areaId = snapshot.area,
                        projectId = snapshot.project,
                    )
                    if (inTodayInbox) {
                        inbox += positioned
                    } else {
                        visible += positioned
                    }
                }
                is TaskHomeLocation.Area -> {
                    if (snapshot.area != resolvedLocation.id || !isOpenVisible(snapshot)) continue
                    visible += PositionedTask(
                        taskListItem(
                            record = record,
                            snapshot = snapshot,
                            membership = membership,
                            selected = resolvedLocation,
                            areaTitles = areaTitles,
                            projectTitles = projectTitles,
                            catalog = metadataCatalog,
                            today = today,
                            now = now,
                            showTodayIndicator = true,
                        ).withFade(snapshot, conversations[snapshot.id], convoStates[snapshot.id], now, today, showAging),
                        record.fields[RegistryEntityFields.Task.POSITION].numberValue(),
                    )
                }
                is TaskHomeLocation.Project -> {
                    if (snapshot.project != resolvedLocation.id || !isOpenVisible(snapshot)) continue
                    visible += PositionedTask(
                        taskListItem(
                            record = record,
                            snapshot = snapshot,
                            membership = membership,
                            selected = resolvedLocation,
                            areaTitles = areaTitles,
                            projectTitles = projectTitles,
                            catalog = metadataCatalog,
                            today = today,
                            now = now,
                            showTodayIndicator = true,
                        ).withFade(snapshot, conversations[snapshot.id], convoStates[snapshot.id], now, today, showAging),
                        record.fields[RegistryEntityFields.Task.POSITION].numberValue(),
                    )
                }
            }
        }

        val destinationId = (resolvedLocation as? TaskHomeLocation.SmartList)?.destinationId
        val supportsInlineCreate = destinationId?.let {
            RegistryCatalog.destinationSupportsInlineCreate(it)
        } == true
        val canQuickAdd = supportsInlineCreate &&
            RegistryActionResolver.isAvailable(
                RegistryActionIds.APP_QUICK_ADD,
                RegistryActionContext(
                    platform = RegistryPlatformIds.ANDROID,
                    destinationId = destinationId,
                    selectedCount = 0,
                ),
            )
        val canComplete = RegistryActionResolver.isAvailable(
            RegistryActionIds.TASK_TOGGLE_COMPLETE,
            RegistryActionContext(
                platform = RegistryPlatformIds.ANDROID,
                destinationId = destinationId,
                selectedCount = 1,
            ),
        ) && destinationId != RegistryDestinationIds.LOGBOOK &&
            destinationId != RegistryDestinationIds.RECENTLY_DELETED
        val stageOrder = agentGroups.values.toList()
        val groupByList = (destinationId == RegistryDestinationIds.TODAY &&
            graph.deviceSettings.bool(RegistrySettingKeys.TODAY_GROUP_BY_LIST)) ||
            destinationId == RegistryDestinationIds.ANYTIME
        val orderedTasks = if (groupByList) {
            groupByAreaAndProject(
                tasks = visible,
                areas = areaRecords,
                projects = projectRecords,
                destinationId = destinationId,
            )
        } else {
            visible.sortedTaskItems(destinationId).let { items ->
                if (destinationId == RegistryDestinationIds.AGENT) {
                    items.sortedBy { stageOrder.indexOf(it.groupTitle).let { i -> if (i < 0) Int.MAX_VALUE else i } }
                } else {
                    items
                }
            }
        }
        filingSuggestionsByTask = nextSuggestions
        val lastSweepAt = graph.fadeSweepStore.lastSweepAt()
        val dismissedWeek = graph.fadeSweepStore.dismissedSweepWeek()
        val sortedFadedSweep = fadedSweepList.sortedWith(
            compareByDescending<FadeSweepItem> { it.fadedAt ?: java.time.Instant.EPOCH }
                .thenBy { it.title.lowercase() },
        )
        val currentWeekSweep = sortedFadedSweep.filter { FadeSweepRules.isInCurrentSweep(it.fadedAt, lastSweepAt) }
        val showSweepBanner = FadeSweepRules.isSweepDue(
            now = now,
            lastSweepAt = lastSweepAt,
            dismissedWeek = dismissedWeek,
            fadedDates = sortedFadedSweep.mapNotNull(FadeSweepItem::fadedAt),
            zoneId = zoneId,
        )
        return LoadedTaskHome(
            hasLoaded = true,
            location = resolvedLocation,
            topSmartLists = topSmartListItems,
            bottomSmartLists = bottomSmartListItems,
            areas = countedAreas,
            projects = countedProjects,
            inboxTasks = inbox.sortedTaskItems(),
            tasks = orderedTasks,
            deletedTasks = deleted.sortedTaskItems(RegistryDestinationIds.RECENTLY_DELETED),
            canQuickAdd = canQuickAdd,
            canComplete = canComplete,
            agentsPaused = agentsPaused,
            reviewCount = reviewCount,
            fadedSweepItems = sortedFadedSweep,
            weeklySweepItems = currentWeekSweep,
            showWeeklySweepBanner = showSweepBanner,
        )
    }

    private fun positionField(destinationId: String): String =
        if (destinationId == RegistryDestinationIds.TODAY) {
            RegistryEntityFields.Task.TODAY_POSITION
        } else {
            RegistryEntityFields.Task.POSITION
        }

    private fun taskListItem(
        record: SyncRecord,
        snapshot: TaskSnapshot,
        membership: app.septena.core.TaskViewMembership,
        selected: TaskHomeLocation,
        areaTitles: Map<String, String>,
        projectTitles: Map<String, String>,
        catalog: TaskRowMetadataCatalog,
        today: java.time.LocalDate,
        now: java.time.Instant,
        showTodayIndicator: Boolean,
        isLogbook: Boolean = false,
    ): TaskListItem {
        val projectTitle = snapshot.project?.let(projectTitles::get)
        val areaTitle = snapshot.area?.let(areaTitles::get)
        val subtitle = when (selected) {
            is TaskHomeLocation.SmartList -> projectTitle ?: areaTitle
            is TaskHomeLocation.Area -> projectTitle
            is TaskHomeLocation.Project -> null
        }
        return buildTaskListItem(
            record = record,
            snapshot = snapshot,
            membership = membership,
            subtitle = subtitle,
            catalog = catalog,
            today = today,
            now = now,
            showTodayIndicator = showTodayIndicator,
            isLogbook = isLogbook,
        )
    }

    /**
     * Row opacity from the core's fade fill (fade.rs), as on iOS: an
     * untouched open task fades over the fade window. Agent work, waiting
     * conversations, dated, deadline and repeating tasks never fade.
     */
    private fun TaskListItem.withFade(
        snapshot: TaskSnapshot,
        conversation: TaskConversation?,
        convoState: app.septena.core.ConversationSnapshotState?,
        now: java.time.Instant,
        today: java.time.LocalDate,
        showAging: Boolean,
    ): TaskListItem {
        // Settings ▸ Lists ▸ "Fade inactive tasks" (tasksShowAging) off: rows stay at full strength.
        if (!showAging) return this
        val fill = runCatching {
            TaskFadeRules.fadeFill(
                isOpen = snapshot.status == RegistryEntityEnums.TaskStatus.OPEN,
                isHeading = snapshot.isHeading,
                isDeleted = snapshot.deletedAt != null,
                isFaded = TaskFadeRules.isFaded(snapshot.fadedAt),
                deadline = snapshot.deadline,
                scheduled = snapshot.scheduled,
                hasRecurrence = snapshot.recurrenceUnit != null,
                isAgentTurn = convoState?.isAgentWorking == true,
                isAssignedToClaude = conversation?.assignee == RegistryEntityEnums.ConvoAssignee.CLAUDE,
                showsAgentCue = TaskProvenance.isAgentAuthored(snapshot.source) && snapshot.acknowledgedAt == null,
                touchedAt = snapshot.touchedAt?.let { runCatching { java.time.Instant.parse(it) }.getOrNull() },
                createdAt = snapshot.createdAt?.let { runCatching { java.time.Instant.parse(it) }.getOrNull() },
                created = snapshot.created,
                now = now,
                today = today.toString(),
                isAwaitingHuman = convoState?.awaitsHuman == true,
            )
        }.getOrNull()
        return copy(opacity = TaskFadeRules.rowOpacity(fill).toFloat())
    }

    /** Agent stage id to its title, in the order registry/destinations.json lists the groups. */
    private fun agentGroupTitles(): LinkedHashMap<String?, String> {
        val groups = (RegistryCatalog.destination(RegistryDestinationIds.AGENT)?.fields?.get("groups") as? JsonValue.ArrayValue)
            ?.values.orEmpty()
        val out = LinkedHashMap<String?, String>()
        for (group in groups) {
            val g = (group as? JsonValue.ObjectValue)?.fields ?: continue
            val id = g["id"].stringValue() ?: continue
            out[id] = g["title"].stringValue() ?: id
        }
        return out
    }

    private fun isOpenVisible(task: TaskSnapshot): Boolean =
            task.status == RegistryEntityEnums.TaskStatus.OPEN &&
            !task.isHeading && task.deletedAt == null && !TaskFadeRules.isFaded(task.fadedAt)

    private fun List<PositionedTask>.sortedTaskItems(destinationId: String? = null): List<TaskListItem> =
        sortedWith(
            if (destinationId == RegistryDestinationIds.LOGBOOK ||
                destinationId == RegistryDestinationIds.RECENTLY_DELETED
            ) {
                compareByDescending<PositionedTask> { it.archiveDate.orEmpty() }
                    .thenBy { it.item.title.lowercase() }
            } else {
                compareBy<PositionedTask>({ it.position ?: Double.MAX_VALUE }, { it.item.title.lowercase() })
            },
        )
            .map(PositionedTask::item)

    /**
     * Groups open tasks by area and project in sidebar order, matching Apple
     * `TaskListView.groupedOpenItems`: unfiled tasks first (outside Today),
     * then each area's direct tasks followed by its projects, then top-level
     * projects without an area.
     */
    private fun groupByAreaAndProject(
        tasks: List<PositionedTask>,
        areas: List<TaskHomeNavigationItem>,
        projects: List<TaskHomeNavigationItem>,
        destinationId: String?,
    ): List<TaskListItem> {
        val sorted = tasks.sortedWith(
            compareBy<PositionedTask>({ it.position ?: Double.MAX_VALUE }, { it.item.title.lowercase() }),
        )
        val byProject = sorted.filter { it.projectId != null }.groupBy { it.projectId!! }
        val byArea = sorted.filter { it.projectId == null && it.areaId != null }.groupBy { it.areaId!! }
        val emitted = mutableSetOf<String>()
        val result = mutableListOf<TaskListItem>()

        // Unfiled tasks (headerless) on Anytime; on Today loose tasks live in the Inbox band above.
        if (destinationId != RegistryDestinationIds.TODAY) {
            sorted.filter { it.projectId == null && it.areaId == null }.forEach { entry ->
                emitted += entry.item.id
                result += entry.item.copy(group = null, groupTitle = null)
            }
        }

        val areaIds = areas.mapNotNull { (it.location as? TaskHomeLocation.Area)?.id }.toSet()
        for (areaItem in areas) {
            val area = areaItem.location as? TaskHomeLocation.Area ?: continue
            val areaHeader = TaskGroupHeader(
                key = "area:${area.id}",
                title = area.title,
                iconKind = SeptenaIconKind.Area,
                emoji = areaItem.emoji,
                targetLocationKey = "area:${area.id}",
            )
            byArea[area.id].orEmpty().forEach { entry ->
                emitted += entry.item.id
                result += entry.item.copy(group = areaHeader, groupTitle = area.title, subtitle = null)
            }
            for (projectItem in projects) {
                if (projectItem.parentAreaId != area.id) continue
                val project = projectItem.location as? TaskHomeLocation.Project ?: continue
                val projectHeader = TaskGroupHeader(
                    key = "project:${project.id}",
                    title = project.title,
                    iconKind = SeptenaIconKind.Project,
                    targetLocationKey = "project:${project.id}",
                )
                byProject[project.id].orEmpty().forEach { entry ->
                    emitted += entry.item.id
                    result += entry.item.copy(group = projectHeader, groupTitle = project.title, subtitle = null)
                }
            }
        }

        // Top-level projects (no area, or whose area is no longer active).
        for (projectItem in projects) {
            if (projectItem.parentAreaId != null && projectItem.parentAreaId in areaIds) continue
            val project = projectItem.location as? TaskHomeLocation.Project ?: continue
            val projectHeader = TaskGroupHeader(
                key = "project:${project.id}",
                title = project.title,
                iconKind = SeptenaIconKind.Project,
                targetLocationKey = "project:${project.id}",
            )
            byProject[project.id].orEmpty().forEach { entry ->
                emitted += entry.item.id
                result += entry.item.copy(group = projectHeader, groupTitle = project.title, subtitle = null)
            }
        }

        // Fallback: keep any remaining task visible even if its area/project is archived.
        sorted.filter { it.item.id !in emitted }.forEach { entry ->
            result += entry.item
        }
        return result
    }

    private data class PositionedTask(
        val item: TaskListItem,
        val position: Double?,
        val archiveDate: String? = null,
        val areaId: String? = null,
        val projectId: String? = null,
    )

    private companion object {
        val SHELL_DESTINATIONS = setOf(
            RegistryDestinationIds.TODAY,
            RegistryDestinationIds.REVIEW,
            RegistryDestinationIds.AGENT,
            RegistryDestinationIds.UPCOMING,
            RegistryDestinationIds.REPEATING,
            RegistryDestinationIds.STARRED,
            RegistryDestinationIds.FADED,
            RegistryDestinationIds.ANYTIME,
            RegistryDestinationIds.LOGBOOK,
            RegistryDestinationIds.RECENTLY_DELETED,
        )
    }
}

private fun JsonValue?.numberValue(): Double? = when (this) {
    is JsonValue.IntegerValue -> value.toDouble()
    is JsonValue.DecimalValue -> value
    else -> null
}
