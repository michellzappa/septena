package app.septena.android.ui

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
    val draftTitle: String = "",
    val errorMessage: String? = null,
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
    private val draftTitle = MutableStateFlow("")
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

    val state: StateFlow<TaskHomeUiState> = combine(loaded, draftTitle, errorMessage) { home, draft, error ->
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
            draftTitle = draft,
            errorMessage = error,
        )
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(stopTimeoutMillis = 5_000),
        initialValue = TaskHomeUiState(),
    )

    fun select(location: TaskHomeLocation) {
        this.location.value = location
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

    fun updateDraft(title: String) {
        draftTitle.value = title
        errorMessage.value = null
    }

    fun quickAdd() {
        val title = draftTitle.value.trim()
        if (title.isEmpty()) return
        viewModelScope.launch {
            runCatching { withContext(Dispatchers.IO) { graph.taskMutator.create(title) } }
                .onSuccess {
                    draftTitle.value = ""
                    errorMessage.value = null
                    noteLocalChangeAndSync()
                }
                .onFailure { errorMessage.value = it.message }
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
                    val item = taskListItem(record, snapshot, resolvedLocation, areaTitles, projectTitles, membership.isOnToday)
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
                        taskListItem(record, snapshot, resolvedLocation, areaTitles, projectTitles, membership.isOnToday)
                            .withFade(snapshot, conversations[snapshot.id], now, today, showAging),
                        record.fields[RegistryEntityFields.Task.POSITION].numberValue(),
                    )
                }
                is TaskHomeLocation.Project -> {
                    if (snapshot.project != resolvedLocation.id || !isOpenVisible(snapshot)) continue
                    visible += PositionedTask(
                        taskListItem(record, snapshot, resolvedLocation, areaTitles, projectTitles, membership.isOnToday)
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
        record: SyncRecord,
        snapshot: TaskSnapshot,
        selected: TaskHomeLocation,
        areaTitles: Map<String, String>,
        projectTitles: Map<String, String>,
        isOnToday: Boolean,
    ): TaskListItem {
        val projectTitle = snapshot.project?.let(projectTitles::get)
        val areaTitle = snapshot.area?.let(areaTitles::get)
        val subtitle = when (selected) {
            is TaskHomeLocation.SmartList -> projectTitle ?: areaTitle
            is TaskHomeLocation.Area -> projectTitle
            is TaskHomeLocation.Project -> null
        }
        return TaskListItem(
            id = record.id,
            title = snapshot.title,
            agentName = agentName(snapshot),
            subtitle = subtitle,
            isCompleted = snapshot.status == RegistryEntityEnums.TaskStatus.DONE,
            isOnToday = isOnToday,
            isStarred = snapshot.starred,
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

/** The agent's name for a row an agent added (`task.provenance`), else null. */
private fun agentName(snapshot: TaskSnapshot): String? =
    if (TaskProvenance.isAgentAuthored(snapshot.source)) {
        TaskProvenance.addedByName(snapshot.source, snapshot.sourceClient)
    } else {
        null
    }
