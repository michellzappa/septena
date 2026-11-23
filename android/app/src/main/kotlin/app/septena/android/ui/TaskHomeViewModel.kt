package app.septena.android.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.septena.android.AndroidAppGraph
import app.septena.core.JsonValue
import app.septena.core.RegistryActionContext
import app.septena.core.RegistryActionResolver
import app.septena.core.RegistryCatalog
import app.septena.core.SmartListResolver
import app.septena.core.TaskFadeRules
import app.septena.core.TaskSnapshot
import app.septena.core.TaskViewRules
import app.septena.core.stringValue
import app.septena.core.generated.RegistryActionIds
import app.septena.core.generated.RegistryDestinationIds
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames as EntityNames
import app.septena.core.generated.RegistryPlatformIds
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
)

data class TaskHomeUiState(
    val location: TaskHomeLocation = TaskHomeLocation.SmartList(RegistryDestinationIds.TODAY),
    val smartLists: List<TaskHomeNavigationItem> = emptyList(),
    val areas: List<TaskHomeNavigationItem> = emptyList(),
    val projects: List<TaskHomeNavigationItem> = emptyList(),
    val inboxTasks: List<TaskListItem> = emptyList(),
    val tasks: List<TaskListItem> = emptyList(),
    val canQuickAdd: Boolean = false,
    val canComplete: Boolean = false,
    val draftTitle: String = "",
    val errorMessage: String? = null,
)

private data class LoadedTaskHome(
    val location: TaskHomeLocation,
    val smartLists: List<TaskHomeNavigationItem>,
    val areas: List<TaskHomeNavigationItem>,
    val projects: List<TaskHomeNavigationItem>,
    val inboxTasks: List<TaskListItem>,
    val tasks: List<TaskListItem>,
    val canQuickAdd: Boolean,
    val canComplete: Boolean,
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
            location = home.location,
            smartLists = home.smartLists,
            areas = home.areas,
            projects = home.projects,
            inboxTasks = home.inboxTasks,
            tasks = home.tasks,
            canQuickAdd = home.canQuickAdd,
            canComplete = home.canComplete,
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
            runCatching { withContext(Dispatchers.IO) { graph.taskMutator.complete(id) } }
                .onSuccess {
                    errorMessage.value = null
                    noteLocalChangeAndSync()
                }
                .onFailure { errorMessage.value = it.message }
        }
    }

    private fun noteLocalChangeAndSync() {
        graph.sync.noteLocalChange()
        graph.sync.requestSync()
    }

    private fun loadInitial() = LoadedTaskHome(
        location = TaskHomeLocation.SmartList(RegistryDestinationIds.TODAY),
        smartLists = emptyList(),
        areas = emptyList(),
        projects = emptyList(),
        inboxTasks = emptyList(),
        tasks = emptyList(),
        canQuickAdd = false,
        canComplete = true,
    )

    private suspend fun load(selected: TaskHomeLocation): LoadedTaskHome {
        val taskRecords = graph.taskStore.records(EntityNames.TASK)
        val areaRecords = graph.taskStore.records(EntityNames.AREA)
            .filter { it.deletedAt == null }
            .mapNotNull { record ->
                record.fields[RegistryEntityFields.Area.TITLE].stringValue()?.let { title ->
                    TaskHomeNavigationItem(TaskHomeLocation.Area(record.id, title), title)
                }
            }
        val projectRecords = graph.taskStore.records(EntityNames.PROJECT)
            .filter { it.deletedAt == null }
            .mapNotNull { record ->
                record.fields[RegistryEntityFields.Project.TITLE].stringValue()?.let { title ->
                    TaskHomeNavigationItem(TaskHomeLocation.Project(record.id, title), title)
                }
            }

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

        val allSnapshots = taskRecords.mapNotNull { record ->
            runCatching { record to TaskSnapshot.from(record) }.getOrNull()
        }
        val now = graph.clock.now()
        val today = graph.clock.today(now)
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
                    if (!TaskViewRules.matchesView(snapshot, resolvedLocation.destinationId, today, now)) continue
                    val positioned = PositionedTask(
                        TaskListItem(record.id, snapshot.title),
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
                        TaskListItem(record.id, snapshot.title),
                        record.fields[RegistryEntityFields.Task.POSITION].numberValue(),
                    )
                }
                is TaskHomeLocation.Project -> {
                    if (snapshot.project != resolvedLocation.id || !isOpenVisible(snapshot)) continue
                    visible += PositionedTask(
                        TaskListItem(record.id, snapshot.title),
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
        return LoadedTaskHome(
            location = resolvedLocation,
            smartLists = smartListItems,
            areas = areaRecords,
            projects = projectRecords,
            inboxTasks = inbox.sortedTaskItems(),
            tasks = visible.sortedTaskItems(destinationId),
            canQuickAdd = canQuickAdd,
            canComplete = canComplete,
        )
    }

    private fun positionField(destinationId: String): String =
        if (destinationId == RegistryDestinationIds.TODAY) {
            RegistryEntityFields.Task.TODAY_POSITION
        } else {
            RegistryEntityFields.Task.POSITION
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
            RegistryDestinationIds.UPCOMING,
            RegistryDestinationIds.REPEATING,
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
