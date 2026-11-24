package app.septena.android.ui

import app.septena.core.TaskViewMembership
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.septena.android.AndroidAppGraph
import app.septena.core.JsonValue
import app.septena.core.RegistryActionContext
import app.septena.core.RegistryActionResolver
import app.septena.core.RegistryCatalog
import app.septena.core.SmartListResolver
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
)

data class TaskHomeUiState(
    val hasLoaded: Boolean = false,
    val location: TaskHomeLocation = TaskHomeLocation.SmartList(RegistryDestinationIds.TODAY),
    val smartLists: List<TaskHomeNavigationItem> = emptyList(),
    val areas: List<TaskHomeNavigationItem> = emptyList(),
    val projects: List<TaskHomeNavigationItem> = emptyList(),
    val inboxTasks: List<TaskListItem> = emptyList(),
    val tasks: List<TaskListItem> = emptyList(),
    val canQuickAdd: Boolean = false,
    val canComplete: Boolean = false,
    val agentsPaused: Boolean = false,
    /** Task ids picked by a long-press; non-empty means the list is in selection mode. */
    val selectedIds: Set<String> = emptySet(),
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
)

private data class LoadedTaskHome(
    val hasLoaded: Boolean,
    val location: TaskHomeLocation,
    val smartLists: List<TaskHomeNavigationItem>,
    val areas: List<TaskHomeNavigationItem>,
    val projects: List<TaskHomeNavigationItem>,
    val inboxTasks: List<TaskListItem>,
    val tasks: List<TaskListItem>,
    val canQuickAdd: Boolean,
    val canComplete: Boolean,
    val agentsPaused: Boolean,
)

/** Reads the store on IO and refreshes from the sync controller's data version flow. */
class TaskHomeViewModel(private val graph: AndroidAppGraph) : ViewModel() {
    private val location = MutableStateFlow<TaskHomeLocation>(
        TaskHomeLocation.SmartList(RegistryDestinationIds.TODAY),
    )
    private val selectedIds = MutableStateFlow<Set<String>>(emptySet())
    private val errorMessage = MutableStateFlow<String?>(null)

    @OptIn(ExperimentalCoroutinesApi::class)
    private val loaded: StateFlow<LoadedTaskHome> = combine(location, graph.sync.dataVersion) { selected, _ ->
        selected
    }.mapLatest { selected ->
        withContext(Dispatchers.IO) { load(selected) }
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(stopTimeoutMillis = 5_000),
        initialValue = loadInitial(),
    )

    val state: StateFlow<TaskHomeUiState> = combine(loaded, selectedIds, errorMessage) { home, selected, error ->
        TaskHomeUiState(
            hasLoaded = home.hasLoaded,
            location = home.location,
            smartLists = home.smartLists,
            areas = home.areas,
            projects = home.projects,
            inboxTasks = home.inboxTasks,
            tasks = home.tasks,
            canQuickAdd = home.canQuickAdd,
            canComplete = home.canComplete,
            agentsPaused = home.agentsPaused,
            selectedIds = selected,
            errorMessage = error,
        )
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(stopTimeoutMillis = 5_000),
        initialValue = TaskHomeUiState(),
    )

    fun select(location: TaskHomeLocation) {
        selectedIds.value = emptySet()
        this.location.value = location
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

    /** True while a Quick Add write runs, so a second tap on Add cannot create a second task. */
    private var quickAddRunning = false

    /**
     * Creates the Quick Add task. The core decides the date fields (When and
     * deadline go through the same date actions as the task page), and Undo
     * removes the new task in one step. Once the row exists the sheet closes,
     * also when a later field write fails: a retry would create it twice.
     */
    fun quickAdd(draft: QuickAddDraft, onSaved: () -> Unit) {
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
                        notes = draft.notes.trim().takeIf(String::isNotEmpty),
                    )
                    val fields = runCatching {
                        draft.whenDay?.let { graph.taskMutator.setWhen(created.id, it) }
                        draft.deadline?.let { graph.taskMutator.setDeadline(created.id, it) }
                        if (draft.starred) graph.taskMutator.setStarred(created.id, true)
                    }
                    graph.taskUndoHistory.recordCreated(created.asSyncRecord())
                    fields.exceptionOrNull()
                }
            }
                .onSuccess { fieldError ->
                    errorMessage.value = fieldError?.message
                    noteLocalChangeAndSync()
                    onSaved()
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

    fun acceptReview(id: String) = editTask(id) { graph.taskMutator.acceptReview(id) }

    fun keepFaded(id: String) = editTask(id) { graph.taskMutator.keepFaded(id) }

    fun letGoFaded(id: String) = editTask(id) { graph.taskMutator.letGoFaded(id) }

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
        smartLists = emptyList(),
        areas = emptyList(),
        projects = emptyList(),
        inboxTasks = emptyList(),
        tasks = emptyList(),
        canQuickAdd = false,
        canComplete = true,
        agentsPaused = false,
    )

    private suspend fun load(selected: TaskHomeLocation): LoadedTaskHome {
        val taskRecords = graph.taskStore.records(EntityNames.TASK)
        val areaRecords = graph.taskStore.records(EntityNames.AREA)
            .filter { it.deletedAt == null }
            .mapNotNull { record ->
                record.fields[RegistryEntityFields.Area.TITLE].stringValue()?.let { title ->
                    TaskHomeNavigationItem(
                        TaskHomeLocation.Area(record.id, title),
                        title,
                        record.fields[RegistryEntityFields.Area.EMOJI].stringValue()?.takeIf(String::isNotBlank),
                    )
                }
            }
        val projectRecords = graph.taskStore.records(EntityNames.PROJECT)
            .filter { it.deletedAt == null }
            .mapNotNull { record ->
                record.fields[RegistryEntityFields.Project.TITLE].stringValue()?.let { title ->
                    TaskHomeNavigationItem(TaskHomeLocation.Project(record.id, title), title)
                }
            }

        val agentsPaused = graph.syncedSettings.value(RegistrySettingKeys.AGENTS_PAUSED).booleanValue() ?: false

        val nonEmptyDestinations = buildSet {
            if (taskRecords.any { it.deletedAt != null }) add(RegistryDestinationIds.RECENTLY_DELETED)
        }
        val smartListItems = SmartListResolver.visibleFromSynced(
            graph.syncedSettings,
            nonEmptyIds = nonEmptyDestinations,
        ).map { descriptor ->
            descriptor.id to TaskHomeNavigationItem(
                location = TaskHomeLocation.SmartList(descriptor.id),
            )
        }.filter { (id, _) -> id in SHELL_DESTINATIONS }
            .sortedBy { (id, _) -> if (id == RegistryDestinationIds.TODAY) 0 else 1 }
            .map { it.second }

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
        val now = graph.clock.now()
        val today = graph.clock.today(now)
        // Conversations (one per task id) drive Review, Agent and the fade
        // exemptions; their rules are the core's (convo.rs).
        val conversations = graph.taskStore.records(EntityNames.CONVO)
            .filter { it.deletedAt == null }
            .associate { it.id to runCatching { TaskConversation.from(it, graph.taskStore.turns(it.id)) }.getOrNull() }
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

        val rows = TaskRowSource.load(graph, today)
        val inbox = mutableListOf<PositionedTask>()
        val visible = mutableListOf<PositionedTask>()
        for ((record, snapshot) in allSnapshots) {
            val membership = TaskViewRules.membership(snapshot, today, now)
            when (resolvedLocation) {
                is TaskHomeLocation.SmartList -> {
                    val conversation = conversations[snapshot.id]
                    val stage = conversation?.agentStage(now)
                    val listed = when (resolvedLocation.destinationId) {
                        // Review: open tasks an agent handed back to verify.
                        RegistryDestinationIds.REVIEW ->
                            snapshot.status == RegistryEntityEnums.TaskStatus.OPEN && !snapshot.isHeading &&
                                snapshot.deletedAt == null && conversation?.needsHumanReview == true
                        // Agent: every task with an agent stage, grouped by stage.
                        RegistryDestinationIds.AGENT ->
                            stage != null && !snapshot.isHeading && snapshot.deletedAt == null
                        else -> TaskViewRules.matchesView(snapshot, resolvedLocation.destinationId, today, now)
                    }
                    if (!listed) continue
                    val item = taskListItem(rows, record, snapshot, resolvedLocation, areaTitles, projectTitles, membership)
                        .withFade(snapshot, conversation, now, today, showAging)
                    val positioned = PositionedTask(
                        if (resolvedLocation.destinationId == RegistryDestinationIds.AGENT) {
                            item.copy(groupTitle = agentGroups[stage])
                        } else {
                            item
                        },
                        record.fields[positionField(resolvedLocation.destinationId)].numberValue()
                            ?: record.fields[RegistryEntityFields.Task.POSITION].numberValue(),
                        archiveDate = when (resolvedLocation.destinationId) {
                            RegistryDestinationIds.LOGBOOK ->
                                record.fields[RegistryEntityFields.Task.COMPLETED_AT].stringValue()
                            RegistryDestinationIds.RECENTLY_DELETED -> record.deletedAt
                            else -> null
                        },
                    )
                    if (resolvedLocation.destinationId == RegistryDestinationIds.TODAY && membership.inTodayInbox) {
                        inbox += positioned
                    } else {
                        visible += positioned
                    }
                }
                is TaskHomeLocation.Area -> {
                    if (snapshot.area != resolvedLocation.id || !isOpenVisible(snapshot)) continue
                    visible += PositionedTask(
                        taskListItem(rows, record, snapshot, resolvedLocation, areaTitles, projectTitles, membership)
                            .withFade(snapshot, conversations[snapshot.id], now, today, showAging),
                        record.fields[RegistryEntityFields.Task.POSITION].numberValue(),
                    )
                }
                is TaskHomeLocation.Project -> {
                    if (snapshot.project != resolvedLocation.id || !isOpenVisible(snapshot)) continue
                    visible += PositionedTask(
                        taskListItem(rows, record, snapshot, resolvedLocation, areaTitles, projectTitles, membership)
                            .withFade(snapshot, conversations[snapshot.id], now, today, showAging),
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
        val orderedTasks = visible.sortedTaskItems(destinationId).let { items ->
            if (destinationId == RegistryDestinationIds.AGENT) {
                items.sortedBy { stageOrder.indexOf(it.groupTitle).let { i -> if (i < 0) Int.MAX_VALUE else i } }
            } else {
                items
            }
        }
        return LoadedTaskHome(
            hasLoaded = true,
            location = resolvedLocation,
            smartLists = smartListItems,
            areas = areaRecords,
            projects = projectRecords,
            inboxTasks = inbox.sortedTaskItems(),
            tasks = orderedTasks,
            canQuickAdd = canQuickAdd,
            canComplete = canComplete,
            agentsPaused = agentsPaused,
        )
    }

    private fun positionField(destinationId: String): String =
        if (destinationId == RegistryDestinationIds.TODAY) {
            RegistryEntityFields.Task.TODAY_POSITION
        } else {
            RegistryEntityFields.Task.POSITION
        }

    private fun taskListItem(
        rows: TaskRowSource,
        record: SyncRecord,
        snapshot: TaskSnapshot,
        selected: TaskHomeLocation,
        areaTitles: Map<String, String>,
        projectTitles: Map<String, String>,
        membership: TaskViewMembership,
    ): TaskListItem {
        val projectTitle = snapshot.project?.let(projectTitles::get)
        val areaTitle = snapshot.area?.let(areaTitles::get)
        val subtitle = when (selected) {
            is TaskHomeLocation.SmartList -> projectTitle ?: areaTitle
            is TaskHomeLocation.Area -> projectTitle
            is TaskHomeLocation.Project -> null
        }
        val onTodayList = (selected as? TaskHomeLocation.SmartList)?.destinationId == RegistryDestinationIds.TODAY
        return rows.item(record, snapshot, membership, subtitle, showsToday = !onTodayList)
    }

    /**
     * Row opacity from the core's fade fill (fade.rs), as on iOS: an
     * untouched open task fades over the fade window. Agent work, waiting
     * conversations, dated, deadline and repeating tasks never fade.
     */
    private fun TaskListItem.withFade(
        snapshot: TaskSnapshot,
        conversation: TaskConversation?,
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
                isAgentTurn = conversation?.isAgentTurn(now) == true,
                isAssignedToClaude = conversation?.assignee == RegistryEntityEnums.ConvoAssignee.CLAUDE,
                showsAgentCue = TaskProvenance.isAgentAuthored(snapshot.source) && snapshot.acknowledgedAt == null,
                touchedAt = snapshot.touchedAt?.let { runCatching { java.time.Instant.parse(it) }.getOrNull() },
                createdAt = snapshot.createdAt?.let { runCatching { java.time.Instant.parse(it) }.getOrNull() },
                created = snapshot.created,
                now = now,
                today = today.toString(),
                isAwaitingHuman = conversation?.awaitsHuman == true,
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

    private data class PositionedTask(
        val item: TaskListItem,
        val position: Double?,
        val archiveDate: String? = null,
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
