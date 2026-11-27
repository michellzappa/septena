package app.septena.android.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.CalendarContract
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.PermanentDrawerSheet
import androidx.compose.material3.PermanentNavigationDrawer
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isMetaPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import app.septena.android.AndroidAppGraph
import app.septena.android.calendar.AndroidCalendarReader
import app.septena.android.doing.DoCopy
import app.septena.android.widgets.WidgetLaunchAction
import app.septena.core.JsonValue
import app.septena.core.generated.RegistrySettingKeys
import app.septena.core.stringValue
import app.septena.ui.CalendarAgendaRow
import app.septena.core.RegistryActionContext
import app.septena.core.RegistryActionResolver
import app.septena.core.ListSortCopy
import app.septena.core.RegistryCatalog
import app.septena.core.QuickFindTarget
import app.septena.core.formatUpcomingDayHeader
import app.septena.core.generated.RegistryActionIds
import app.septena.core.generated.RegistryDestinationIds
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.generated.RegistryNoticeIds
import app.septena.core.generated.RegistryPlatformIds
import app.septena.core.generated.RegistryPromptIds
import app.septena.core.generated.RegistryRules
import app.septena.core.generated.RegistrySurfaceIds
import app.septena.ui.CheckmarkGlyph
import app.septena.ui.ChevronDownGlyph
import app.septena.ui.ChevronLeftGlyph
import app.septena.ui.CollapsibleTaskGroup
import app.septena.ui.LocalMagicPlusDrag
import app.septena.ui.LocalTaskReorderDrag
import app.septena.ui.MagicPlusDragState
import app.septena.ui.SeptenaGlyph
import app.septena.ui.SeptenaIconKind
import app.septena.ui.StarGlyph
import app.septena.ui.TaskCardMetrics
import app.septena.ui.TaskCardPosition
import app.septena.ui.TaskDragStackOverlay
import app.septena.ui.TaskListItem
import app.septena.ui.TaskReorderDragState
import app.septena.ui.reorderPositions
import app.septena.ui.TaskHomeContent
import app.septena.ui.TaskMenuActionIcon
import app.septena.ui.TaskRowMenuAction
import app.septena.ui.TaskSelection
import app.septena.ui.insertionPosition
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
@OptIn(ExperimentalMaterial3Api::class)
fun TaskHomeScreen(
    graph: AndroidAppGraph,
    launchAction: WidgetLaunchAction? = null,
    onConsumeLaunchAction: () -> Unit = {},
) {
    var openedTaskId by rememberSaveable { mutableStateOf<String?>(null) }
    var openedTaskAttribute by rememberSaveable { mutableStateOf<String?>(null) }
    var openedTaskSendBack by rememberSaveable { mutableStateOf(false) }
    /** Task expanded in place in the list (Things-style inline foldout, ADR 0029). */
    var expandedTaskId by rememberSaveable { mutableStateOf<String?>(null) }
    /** The task whose Add Reference dialog is open (row menu). */
    var referenceTaskId by rememberSaveable { mutableStateOf<String?>(null) }
    /** The task whose Assign To dialog is open (row menu). */
    var assignTaskId by rememberSaveable { mutableStateOf<String?>(null) }
    // The task whose Waiting On… sheet is open.
    var waitingTaskId by rememberSaveable { mutableStateOf<String?>(null) }
    /** Join a Shared Project: the open dialog, and the token of the link that opened it. */
    var joinOpen by rememberSaveable { mutableStateOf(false) }
    var joinToken by rememberSaveable { mutableStateOf<String?>(null) }
    var shareProjectId by rememberSaveable { mutableStateOf<String?>(null) }
    var quickFindOpen by rememberSaveable { mutableStateOf(false) }
    var settingsOpen by rememberSaveable { mutableStateOf(false) }
    // On mobile, opens on Today with the Lists Homepage one Back away (Things / iOS `SeptaskRootView`).
    var showingListsHome by rememberSaveable { mutableStateOf(false) }
    var logbookShowingDeleted by rememberSaveable { mutableStateOf(false) }
    var pendingPurgeRequest by remember { mutableStateOf<PurgeTasksRequest?>(null) }
    var homeQuickAddDraft by remember { mutableStateOf<QuickAddDraft?>(null) }
    val factory = remember(graph) { TaskHomeViewModelFactory(graph) }
    val homeViewModel: TaskHomeViewModel = viewModel(factory = factory)
    val state by homeViewModel.state.collectAsStateWithLifecycle()
    val doing by graph.doing.ui.collectAsStateWithLifecycle()
    val selectHomeLocation: (TaskHomeLocation) -> Unit = { location ->
        expandedTaskId = null
        logbookShowingDeleted = false
        homeViewModel.select(location)
        showingListsHome = false
    }
    LaunchedEffect(state.selectedIds) {
        if (state.selectedIds.isNotEmpty()) expandedTaskId = null
    }
    LaunchedEffect(launchAction) {
        when (launchAction) {
            null -> Unit
            is WidgetLaunchAction.OpenDestination -> {
                settingsOpen = false
                quickFindOpen = false
                openedTaskId = null
                openedTaskAttribute = null
                expandedTaskId = null
                graph.doing.showList()
                selectHomeLocation(TaskHomeLocation.SmartList(launchAction.destinationId))
                onConsumeLaunchAction()
            }
            is WidgetLaunchAction.OpenTask -> {
                settingsOpen = false
                quickFindOpen = false
                expandedTaskId = null
                graph.doing.showList()
                launchAction.destinationId?.let { selectHomeLocation(TaskHomeLocation.SmartList(it)) }
                openedTaskId = launchAction.taskId
                openedTaskAttribute = null
                onConsumeLaunchAction()
            }
            is WidgetLaunchAction.QuickAdd -> {
                settingsOpen = false
                quickFindOpen = false
                openedTaskId = null
                openedTaskAttribute = null
                expandedTaskId = null
                showingListsHome = false
                homeQuickAddDraft = QuickAddDraft(today = launchAction.today)
                onConsumeLaunchAction()
            }
            is WidgetLaunchAction.JoinShare -> {
                joinToken = launchAction.token
                joinOpen = true
                onConsumeLaunchAction()
            }
        }
    }
    val undoSnackbarHostState = remember { SnackbarHostState() }
    val languageTag = LocalConfiguration.current.locales[0].toLanguageTag()
    val wideLayout = LocalConfiguration.current.screenWidthDp >= 600
    val localContext = LocalContext.current
    val currentDestId = (state.location as? TaskHomeLocation.SmartList)?.destinationId
    val showingDeleted = currentDestId == RegistryDestinationIds.RECENTLY_DELETED ||
        (currentDestId == RegistryDestinationIds.LOGBOOK && logbookShowingDeleted)
    val effectiveDestId = if (showingDeleted) RegistryDestinationIds.RECENTLY_DELETED else currentDestId
    val rowMenuId = if (showingDeleted) "task.recentlyDeleted" else TASK_ROW_MENU
    val rowMenuGroups = remember(rowMenuId, languageTag, effectiveDestId) {
        taskRowMenuGroups(rowMenuId, effectiveDestId, languageTag, offersDo = graph.doing.isAvailable)
    }
    val rowMenuAccessibilityLabel = remember(languageTag) {
        surfaceField(RegistrySurfaceIds.TASK_ROW_MENU, "accessibilityLabel", languageTag)
    }
    val shareTitle = RegistryCatalog.actionTitle(RegistryActionIds.TASK_SHARE, languageTag = languageTag).orEmpty()
    val toggleExpandTask: (String) -> Unit = { id ->
        expandedTaskId = if (expandedTaskId == id) null else id
    }
    val openTaskWithAttribute: (String, String?) -> Unit = { id, attribute ->
        expandedTaskId = null
        openedTaskId = id
        openedTaskAttribute = attribute
        openedTaskSendBack = false
    }
    val openTaskSendBack: (String) -> Unit = { id ->
        expandedTaskId = null
        openedTaskId = id
        openedTaskAttribute = null
        openedTaskSendBack = true
    }
    val onTaskAction: (String, String) -> Unit = { id, actionId ->
        when {
            actionId == RegistryActionIds.TASK_OPEN -> openTaskWithAttribute(id, null)
            RegistryCatalog.actionOpensAttribute(actionId) != null ->
                openTaskWithAttribute(id, RegistryCatalog.actionOpensAttribute(actionId))
            actionId == RegistryActionIds.TASK_DO -> {
                expandedTaskId = null
                graph.doing.begin(id)
            }
            actionId == RegistryActionIds.TASK_TOGGLE_STAR -> homeViewModel.toggleStar(id)
            actionId == RegistryActionIds.TASK_ADD_REFERENCE -> referenceTaskId = id
            actionId == ASSIGN_SUBMENU -> assignTaskId = id
            actionId == RegistryActionIds.TASK_DUPLICATE -> homeViewModel.duplicate(id)
            actionId == RegistryActionIds.TASK_SHARE -> homeViewModel.shareText(id) { shareText ->
                val intent = Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(Intent.EXTRA_TEXT, shareText)
                }
                localContext.startActivity(Intent.createChooser(intent, shareTitle))
            }
            actionId == RegistryActionIds.TASK_DELETE -> {
                if (expandedTaskId == id) expandedTaskId = null
                homeViewModel.delete(id)
            }
            actionId == RegistryActionIds.TASK_RESTORE -> homeViewModel.restore(id)
            actionId == RegistryActionIds.TASK_DELETE_PERMANENTLY -> {
                pendingPurgeRequest = PurgeTasksRequest(listOf(id), RegistryPromptIds.DELETE_PERMANENTLY)
            }
            actionId == RegistryActionIds.TASK_ACCEPT_REVIEW -> homeViewModel.complete(id)
            actionId == RegistryActionIds.TASK_SEND_BACK_REVIEW -> openTaskSendBack(id)
            actionId == RegistryActionIds.TASK_KEEP_FADED -> homeViewModel.keepFaded(id)
            actionId == RegistryActionIds.TASK_WAITING_ON -> waitingTaskId = id
            actionId == RegistryActionIds.TASK_GOT_IT_BACK -> homeViewModel.gotItBack(id)
            actionId == RegistryActionIds.TASK_LET_GO_FADED -> homeViewModel.letGoFaded(id)
            actionId == RegistryActionIds.TASK_SELECT -> homeViewModel.toggleSelection(id)
        }
    }
    val undoTitle = RegistryCatalog.actionTitle(
        RegistryActionIds.APP_UNDO,
        languageTag = languageTag,
    ).orEmpty()
    val undoMessage = RegistryCatalog.actionTitle(
        RegistryActionIds.APP_UNDO,
        field = "message",
        languageTag = languageTag,
    ).orEmpty()

    LaunchedEffect(graph, undoSnackbarHostState, undoTitle, undoMessage) {
        var lastEditId = graph.taskUndoHistory.state.value.latestEditId
        graph.taskUndoHistory.state.collect { undoState ->
            if (undoState.latestEditId == lastEditId) return@collect
            lastEditId = undoState.latestEditId
            val result = undoSnackbarHostState.showSnackbar(
                message = undoMessage,
                actionLabel = undoTitle,
                withDismissAction = true,
                duration = SnackbarDuration.Long,
            )
            if (result == SnackbarResult.ActionPerformed) {
                val undone = runCatching {
                    withContext(Dispatchers.IO) {
                        graph.taskUndoHistory.undo(graph.taskMutator, graph.conversationMutator, graph.registryEntityMutator)
                    }
                }.getOrDefault(false)
                if (undone) {
                    graph.sync.noteLocalChange()
                    graph.sync.requestSync()
                }
            }
        }
    }
    val pageTitle = when (val location = state.location) {
        is TaskHomeLocation.SmartList -> RegistryCatalog.destinationTitle(location.destinationId, languageTag)
            .orEmpty()
        is TaskHomeLocation.Area -> location.title
        is TaskHomeLocation.Project -> location.title
    }
    val quickAddTitle = RegistryCatalog.actionTitle(
        RegistryActionIds.APP_QUICK_ADD,
        languageTag = languageTag,
    ).orEmpty()
    val quickFindTitle = RegistryCatalog.actionTitle(
        RegistryActionIds.APP_QUICK_FIND,
        languageTag = languageTag,
    ).orEmpty()
    val settingsTitle = RegistryCatalog.actionTitle(
        RegistryActionIds.APP_SETTINGS,
        languageTag = languageTag,
    ).orEmpty()
    val starredFilterTitle = RegistryCatalog.destinationTitle(
        RegistryDestinationIds.STARRED,
        languageTag = languageTag,
    ).orEmpty()
    val completeTitle = RegistryCatalog.actionTitle(
        RegistryActionIds.TASK_TOGGLE_COMPLETE,
        languageTag = languageTag,
    ).orEmpty()
    val sidebarActionTitle = RegistryCatalog.actionAddTitle(
        RegistryActionIds.APP_TOGGLE_SIDEBAR,
        languageTag = languageTag,
    ).orEmpty()
    val inboxTitle = RegistryCatalog.destinationTitle(RegistryDestinationIds.INBOX, languageTag).orEmpty()
    val todayTitle = RegistryCatalog.destinationTitle(RegistryDestinationIds.TODAY, languageTag).orEmpty()
    val fadedTitle = RegistryCatalog.destinationTitle(RegistryDestinationIds.FADED, languageTag).orEmpty()
    val emptyTitle = if (state.starredOnly) {
        RegistryCatalog.destinationEmptyTitle(RegistryDestinationIds.STARRED, languageTag).orEmpty()
    } else {
        effectiveDestId?.let { RegistryCatalog.destinationEmptyTitle(it, languageTag) }.orEmpty()
    }
    val emptyDescription = if (state.starredOnly) {
        RegistryCatalog.destinationEmptyDetail(RegistryDestinationIds.STARRED, languageTag).orEmpty()
    } else {
        effectiveDestId?.let { RegistryCatalog.destinationEmptyDetail(it, languageTag) }.orEmpty()
    }
    val openQuickFindTarget: (QuickFindTarget) -> Unit = { target ->
        quickFindOpen = false
        when (target) {
            is QuickFindTarget.Task -> {
                val projectId = target.projectId
                val areaId = target.areaId
                val destination = when {
                    projectId != null -> state.projects.firstOrNull {
                        (it.location as? TaskHomeLocation.Project)?.id == projectId
                    }?.location ?: TaskHomeLocation.Project(projectId, "")
                    areaId != null -> state.areas.firstOrNull {
                        (it.location as? TaskHomeLocation.Area)?.id == areaId
                    }?.location ?: TaskHomeLocation.Area(areaId, "")
                    else -> TaskHomeLocation.SmartList(target.destinationId ?: RegistryDestinationIds.TODAY)
                }
                selectHomeLocation(destination)
                openedTaskId = target.taskId
                openedTaskAttribute = null
            }
            is QuickFindTarget.Area -> {
                val destination = state.areas.firstOrNull {
                    (it.location as? TaskHomeLocation.Area)?.id == target.areaId
                }?.location ?: TaskHomeLocation.Area(target.areaId, "")
                selectHomeLocation(destination)
            }
            is QuickFindTarget.Project -> {
                val destination = state.projects.firstOrNull {
                    (it.location as? TaskHomeLocation.Project)?.id == target.projectId
                }?.location ?: TaskHomeLocation.Project(target.projectId, "")
                selectHomeLocation(destination)
            }
        }
    }

    val isDark = LocalSeptenaDarkTheme.current
    val appearance = LocalAppearance.current

    referenceTaskId?.let { id ->
        AddReferenceDialog(graph = graph, taskId = id, onDismiss = { referenceTaskId = null })
    }

    assignTaskId?.let { id ->
        AssignTaskDialog(
            graph = graph,
            taskId = id,
            title = RegistryCatalog.submenuTitle(TASK_ROW_MENU, ASSIGN_SUBMENU, languageTag).orEmpty(),
            languageTag = languageTag,
            onDismiss = { assignTaskId = null },
            onPick = { memberId ->
                assignTaskId = null
                homeViewModel.assign(id, memberId)
            },
        )
    }

    shareProjectId?.let { id ->
        ShareProjectDialog(
            graph = graph,
            projectId = id,
            languageTag = languageTag,
            onDismiss = { shareProjectId = null },
            onEnded = {
                if ((state.location as? TaskHomeLocation.Project)?.id == id) {
                    selectHomeLocation(TaskHomeLocation.SmartList(RegistryDestinationIds.TODAY))
                }
            },
        )
    }

    if (joinOpen) {
        JoinSharedProjectDialog(
            graph = graph,
            languageTag = languageTag,
            initialToken = joinToken,
            onDismiss = {
                joinOpen = false
                joinToken = null
            },
        )
    }

    homeQuickAddDraft?.let { initialDraft ->
        QuickAddSheet(
            today = graph.clock.today(graph.clock.now()),
            errorMessage = state.errorMessage,
            areas = state.areas,
            projects = state.projects,
            languageTag = languageTag,
            initialDraft = initialDraft,
            onDismiss = { homeQuickAddDraft = null },
            onAdd = { draft -> homeViewModel.quickAdd(draft) { homeQuickAddDraft = null } },
            onAddAndDo = addAndDo(graph, homeViewModel) { homeQuickAddDraft = null },
        )
    }

    waitingTaskId?.let { id ->
        // The sheet opens on the task's name and When date.
        val initial by produceState<Pair<String, String?>?>(initialValue = null, id) {
            value = withContext(Dispatchers.IO) {
                val fields = graph.taskStore.record(RegistryEntityNames.TASK, id)?.fields
                fields?.get(RegistryEntityFields.Task.WAITING_ON).stringValue().orEmpty() to
                    fields?.get(RegistryEntityFields.Task.SCHEDULED).stringValue()
            }
        }
        initial?.let { (name, whenDay) ->
            WaitingOnDialog(
                initialName = name,
                initialWhen = whenDay,
                today = graph.clock.today(graph.clock.now()),
                languageTag = languageTag,
                onDismiss = { waitingTaskId = null },
                onConfirm = { newName, checkBack ->
                    homeViewModel.setWaiting(id, newName, checkBack)
                    waitingTaskId = null
                },
            )
        }
    }

    pendingPurgeRequest?.let { req ->
        val prompt = remember(req.promptId, req.ids.size, languageTag) {
            purgePromptCopy(req.promptId, req.ids.size, languageTag)
        }
        AlertDialog(
            onDismissRequest = { pendingPurgeRequest = null },
            title = { Text(prompt.title) },
            text = if (prompt.message.isNotBlank()) { { Text(prompt.message) } } else null,
            confirmButton = {
                TextButton(
                    onClick = {
                        homeViewModel.purgeTasks(req.ids)
                        pendingPurgeRequest = null
                    },
                ) {
                    Text(prompt.confirmTitle, color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingPurgeRequest = null }) {
                    Text(prompt.cancelTitle)
                }
            },
        )
    }

    if (doing.justStoppedSessionId != null) {
        DoStopNoteDialog(graph.doing, doing.justStoppedSessionId.orEmpty(), languageTag)
    }

    val shortcutScope = rememberCoroutineScope()
    val smartListNavOrder = remember(state.topSmartLists, state.bottomSmartLists) {
        (state.topSmartLists + state.bottomSmartLists).map { it.location }
    }
    val hardwareShortcutModifier = Modifier.onPreviewKeyEvent { event ->
        if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
        val primary = event.isCtrlPressed || event.isMetaPressed
        when {
            primary && event.key == Key.N -> {
                settingsOpen = false
                quickFindOpen = false
                openedTaskId = null
                expandedTaskId = null
                homeQuickAddDraft = defaultQuickAddDraft(state.location)
                true
            }
            primary && event.key == Key.K -> {
                settingsOpen = false
                expandedTaskId = null
                quickFindOpen = !quickFindOpen
                true
            }
            primary && event.key == Key.Comma -> {
                quickFindOpen = false
                expandedTaskId = null
                settingsOpen = !settingsOpen
                true
            }
            primary && event.key == Key.Z && openedTaskId == null && expandedTaskId == null && homeQuickAddDraft == null && !quickFindOpen && !settingsOpen -> {
                shortcutScope.launch {
                    val undone = runCatching {
                        withContext(Dispatchers.IO) {
                            graph.taskUndoHistory.undo(graph.taskMutator, graph.conversationMutator, graph.registryEntityMutator)
                        }
                    }.getOrDefault(false)
                    if (undone) {
                        graph.sync.noteLocalChange()
                        graph.sync.requestSync()
                    }
                }
                true
            }
            primary && event.key in KEYBOARD_LIST_INDEX -> {
                val index = KEYBOARD_LIST_INDEX.getValue(event.key)
                val target = smartListNavOrder.getOrNull(index) ?: return@onPreviewKeyEvent false
                settingsOpen = false
                quickFindOpen = false
                openedTaskId = null
                expandedTaskId = null
                selectHomeLocation(target)
                true
            }
            event.key == Key.Escape -> when {
                quickFindOpen -> { quickFindOpen = false; true }
                settingsOpen -> { settingsOpen = false; true }
                openedTaskId != null -> {
                    openedTaskId = null
                    openedTaskAttribute = null
                    openedTaskSendBack = false
                    true
                }
                expandedTaskId != null -> {
                    expandedTaskId = null
                    true
                }
                state.selectedIds.isNotEmpty() -> {
                    homeViewModel.clearSelection()
                    true
                }
                else -> false
            }
            else -> false
        }
    }

    Box(modifier = Modifier.fillMaxSize().then(hardwareShortcutModifier)) {
        val fullDo = doing.current?.takeIf { doing.isFullHere }
        if (fullDo != null) {
            DoScreen(
                graph = graph,
                doing = fullDo,
                quickAddTitle = quickAddTitle,
                onQuickAdd = { homeQuickAddDraft = QuickAddDraft() },
                onOpenTask = { id ->
                    graph.doing.showList()
                    settingsOpen = false
                    quickFindOpen = false
                    openTaskWithAttribute(id, null)
                },
            )
        } else if (wideLayout) {
            PermanentNavigationDrawer(
                drawerContent = {
                    PermanentDrawerSheet(
                        drawerContainerColor = if (isDark) {
                            MaterialTheme.colorScheme.surfaceContainerLow
                        } else {
                            MaterialTheme.colorScheme.surfaceContainer
                        },
                    ) {
                        TabletSidebarPane(
                            state = state,
                            languageTag = languageTag,
                            settingsTitle = settingsTitle,
                            quickAddTitle = quickAddTitle,
                            isDark = isDark,
                            hasActiveTexture = appearance.hasActiveTexture,
                            onSelect = selectHomeLocation,
                            onSetAreaEmoji = homeViewModel::setAreaEmoji,
                            onOpenSettings = { settingsOpen = true },
                            onCreateArea = { title, insertIndex ->
                                homeViewModel.createArea(title, insertIndex = insertIndex) { created ->
                                    selectHomeLocation(created)
                                }
                            },
                            onCreateProject = { title, areaId, insertIndex ->
                                homeViewModel.createProject(title, areaId = areaId, insertIndex = insertIndex) { created ->
                                    selectHomeLocation(created)
                                }
                            },
                            onMoveProjectToArea = homeViewModel::moveProjectToArea,
                            onRenameArea = homeViewModel::renameArea,
                            onRenameProject = homeViewModel::renameProject,
                            onDeleteArea = homeViewModel::deleteArea,
                            onDeleteProject = homeViewModel::deleteProject,
                            onReorderAreas = homeViewModel::reorderAreas,
                            onReorderProjects = homeViewModel::reorderProjects,
                            onShareProject = { shareProjectId = it },
                            onJoinShared = {
                                joinToken = null
                                joinOpen = true
                            },
                        )
                    }
                }
            ) {
                if (settingsOpen) {
                    SettingsScreen(graph, onBack = { settingsOpen = false })
                } else if (quickFindOpen) {
                    QuickFindScreen(graph, onBack = { quickFindOpen = false }, onSelect = openQuickFindTarget)
                } else if (openedTaskId != null) {
                    TaskDetailScreen(
                        graph,
                        openedTaskId!!,
                        onBack = { openedTaskId = null; openedTaskAttribute = null; openedTaskSendBack = false },
                        initialAttribute = openedTaskAttribute,
                        onOpenTask = { openTaskWithAttribute(it, null) },
                        openSendBackInitially = openedTaskSendBack,
                    )
                } else {
                    TaskHomeScaffold(
                        graph = graph,
                        state = state,
                        onShareProject = { shareProjectId = it },
                        title = pageTitle,
                        sidebarActionTitle = sidebarActionTitle,
                        quickAddTitle = quickAddTitle,
                        quickFindTitle = quickFindTitle,
                        starredFilterTitle = starredFilterTitle,
                        settingsTitle = settingsTitle,
                        completeTitle = completeTitle,
                        emptyTitle = emptyTitle,
                        emptyDescription = emptyDescription,
                        inboxTitle = inboxTitle,
                        todayTitle = todayTitle,
                        fadedTitle = fadedTitle,
                        homeViewModel = homeViewModel,
                        languageTag = languageTag,
                        showNavigationAction = false,
                        onComplete = homeViewModel::complete,
                        rowMenuGroups = rowMenuGroups,
                        rowMenuAccessibilityLabel = rowMenuAccessibilityLabel,
                        expandedTaskId = expandedTaskId,
                        onToggleExpandTask = toggleExpandTask,
                        onCollapseExpandedTask = { expandedTaskId = null },
                        onOpenFullPage = { openTaskWithAttribute(it, null) },
                        onSendBackReview = openTaskSendBack,
                        onTaskAction = onTaskAction,
                        onToggleStarFilter = homeViewModel::toggleStarFilter,
                        onQuickFind = { expandedTaskId = null; quickFindOpen = true },
                        onOpenSettings = { expandedTaskId = null; settingsOpen = true },
                        onSelectHomeLocation = selectHomeLocation,
                        logbookShowingDeleted = logbookShowingDeleted,
                        onLogbookShowingDeletedChange = { expandedTaskId = null; logbookShowingDeleted = it },
                        onRequestEmptyTrash = {
                            val ids = state.deletedTasks.map { it.id }
                            if (ids.isNotEmpty()) {
                                pendingPurgeRequest = PurgeTasksRequest(ids, RegistryPromptIds.EMPTY_TRASH)
                            }
                        },
                        snackbarVisible = undoSnackbarHostState.currentSnackbarData != null,
                    )
                }
            }
        } else {
            // Mobile phone layout: Things / iOS root Lists Homepage (no hamburger drawer).
            // Back gesture from any list returns to the Lists Homepage.
            BackHandler(
                enabled = !showingListsHome && !settingsOpen && !quickFindOpen && openedTaskId == null && expandedTaskId == null && state.selectedIds.isEmpty(),
            ) {
                showingListsHome = true
            }
            if (settingsOpen) {
                SettingsScreen(graph, onBack = { settingsOpen = false })
            } else if (quickFindOpen) {
                QuickFindScreen(graph, onBack = { quickFindOpen = false }, onSelect = openQuickFindTarget)
            } else if (openedTaskId != null) {
                TaskDetailScreen(
                    graph,
                    openedTaskId!!,
                    onBack = { openedTaskId = null; openedTaskAttribute = null; openedTaskSendBack = false },
                    initialAttribute = openedTaskAttribute,
                    onOpenTask = { openTaskWithAttribute(it, null) },
                    openSendBackInitially = openedTaskSendBack,
                )
            } else if (showingListsHome) {
                ListsHomePage(
                    state = state,
                    languageTag = languageTag,
                    quickFindTitle = quickFindTitle,
                    settingsTitle = settingsTitle,
                    quickAddTitle = quickAddTitle,
                    onSelectLocation = selectHomeLocation,
                    onSetAreaEmoji = homeViewModel::setAreaEmoji,
                    onQuickFind = { quickFindOpen = true },
                    onOpenSettings = { settingsOpen = true },
                    onCreateArea = { title, insertIndex ->
                        homeViewModel.createArea(title, insertIndex = insertIndex) { created ->
                            selectHomeLocation(created)
                        }
                    },
                    onCreateProject = { title, areaId, insertIndex ->
                        homeViewModel.createProject(title, areaId = areaId, insertIndex = insertIndex) { created ->
                            selectHomeLocation(created)
                        }
                    },
                    onMoveProjectToArea = homeViewModel::moveProjectToArea,
                    onRenameArea = homeViewModel::renameArea,
                    onRenameProject = homeViewModel::renameProject,
                    onDeleteArea = homeViewModel::deleteArea,
                    onDeleteProject = homeViewModel::deleteProject,
                    onReorderAreas = homeViewModel::reorderAreas,
                    onReorderProjects = homeViewModel::reorderProjects,
                    onJoinShared = {
                        joinToken = null
                        joinOpen = true
                    },
                    onShareProject = { shareProjectId = it },
                    onRefresh = graph.sync::syncAndWait,
                )
            } else {
                TaskHomeScaffold(
                    graph = graph,
                    state = state,
                    onShareProject = { shareProjectId = it },
                    title = pageTitle,
                    sidebarActionTitle = sidebarActionTitle,
                    quickAddTitle = quickAddTitle,
                    quickFindTitle = quickFindTitle,
                    starredFilterTitle = starredFilterTitle,
                    settingsTitle = settingsTitle,
                    completeTitle = completeTitle,
                    emptyTitle = emptyTitle,
                    emptyDescription = emptyDescription,
                    inboxTitle = inboxTitle,
                    todayTitle = todayTitle,
                    fadedTitle = fadedTitle,
                    homeViewModel = homeViewModel,
                    languageTag = languageTag,
                    showNavigationAction = true,
                    onOpenNavigation = { expandedTaskId = null; showingListsHome = true },
                    onComplete = homeViewModel::complete,
                    rowMenuGroups = rowMenuGroups,
                    rowMenuAccessibilityLabel = rowMenuAccessibilityLabel,
                    expandedTaskId = expandedTaskId,
                    onToggleExpandTask = toggleExpandTask,
                    onCollapseExpandedTask = { expandedTaskId = null },
                    onOpenFullPage = { openTaskWithAttribute(it, null) },
                    onSendBackReview = openTaskSendBack,
                    onTaskAction = onTaskAction,
                    onToggleStarFilter = homeViewModel::toggleStarFilter,
                    onQuickFind = { expandedTaskId = null; quickFindOpen = true },
                    onOpenSettings = { expandedTaskId = null; settingsOpen = true },
                    onSelectHomeLocation = selectHomeLocation,
                    logbookShowingDeleted = logbookShowingDeleted,
                    onLogbookShowingDeletedChange = { expandedTaskId = null; logbookShowingDeleted = it },
                    onRequestEmptyTrash = {
                        val ids = state.deletedTasks.map { it.id }
                        if (ids.isNotEmpty()) {
                            pendingPurgeRequest = PurgeTasksRequest(ids, RegistryPromptIds.EMPTY_TRASH)
                        }
                    },
                    snackbarVisible = undoSnackbarHostState.currentSnackbarData != null,
                )
            }
        }

        SnackbarHost(
            hostState = undoSnackbarHostState,
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .navigationBarsPadding()
                .imePadding()
                // The exits of the Do screen stay free.
                .padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = if (fullDo != null) 132.dp else 16.dp),
        )
    }
}

/**
 * Large list/section title with leading icon + nav dropdown menu, aligned to the
 * shared leading grid (`TaskCardMetrics.HeaderLeading` + `LeadingColumnWidth`) so
 * the Today sun / destination icon / area emoji / project ring sits directly above
 * every area emoji and task checkbox, and the title aligns with area & task titles
 * (mirrors iOS `ScreenTitleMenuLabel` + `TaskNavMenu`).
 */
@Composable
private fun SectionTitleDropdownHeader(
    state: TaskHomeUiState,
    title: String,
    languageTag: String,
    settingsTitle: String,
    onSelectLocation: (TaskHomeLocation) -> Unit,
    onOpenSettings: () -> Unit,
    onShareProject: (String) -> Unit,
) {
    var menuExpanded by remember { mutableStateOf(false) }
    val todayTint = MaterialTheme.colorScheme.secondary
    val mutedIcon = MaterialTheme.colorScheme.onSurfaceVariant
    val currentAreaEmoji = (state.location as? TaskHomeLocation.Area)?.let { area ->
        state.areas.firstOrNull { (it.location as? TaskHomeLocation.Area)?.id == area.id }?.emoji
    }

    val share = (state.location as? TaskHomeLocation.Project)?.let { project ->
        state.projects.firstOrNull { (it.location as? TaskHomeLocation.Project)?.id == project.id }?.share
    }

    val (iconKind, iconTint) = when (val loc = state.location) {
        is TaskHomeLocation.SmartList -> {
            val kind = destinationIconKind(loc.destinationId)
            val tint = if (kind == SeptenaIconKind.Today || kind == SeptenaIconKind.Starred) {
                todayTint
            } else {
                MaterialTheme.colorScheme.primary
            }
            kind to tint
        }
        is TaskHomeLocation.Area -> SeptenaIconKind.Area to MaterialTheme.colorScheme.primary
        is TaskHomeLocation.Project -> SeptenaIconKind.Project to MaterialTheme.colorScheme.primary
    }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(
                start = TaskCardMetrics.HeaderLeading,
                end = TaskCardMetrics.Margin,
                top = 4.dp,
                bottom = 14.dp,
            ),
    ) {
        share?.let {
            ShareMembersRow(
                share = it,
                languageTag = languageTag,
                onClick = { (state.location as? TaskHomeLocation.Project)?.id?.let(onShareProject) },
                modifier = Modifier.align(Alignment.CenterEnd),
            )
        }
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(TaskCardMetrics.IconTextGap),
            modifier = Modifier
                .padding(end = if (share != null) 132.dp else 0.dp)
                .clip(RoundedCornerShape(10.dp))
                .clickable { menuExpanded = true }
                .padding(vertical = 4.dp),
        ) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier.width(TaskCardMetrics.LeadingColumnWidth),
            ) {
                if (currentAreaEmoji != null) {
                    Text(text = currentAreaEmoji, fontSize = 23.sp, lineHeight = 26.sp)
                } else {
                    SeptenaGlyph(
                        kind = iconKind,
                        tint = iconTint,
                        size = if (iconKind == SeptenaIconKind.Project) 20.dp else 23.dp,
                    )
                }
            }
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Text(
                    text = title,
                    fontSize = 28.sp,
                    lineHeight = 33.sp,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                ChevronDownGlyph(
                    tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.72f),
                    size = 18.dp,
                )
            }
        }

        val isDark = LocalSeptenaDarkTheme.current
        DropdownMenu(
            expanded = menuExpanded,
            onDismissRequest = { menuExpanded = false },
            shape = RoundedCornerShape(14.dp),
            containerColor = if (isDark) MaterialTheme.colorScheme.surfaceContainerHigh else Color(0xF7FFFFFF),
            tonalElevation = 0.dp,
            shadowElevation = 10.dp,
            modifier = Modifier.width(248.dp),
        ) {
            // Top smart lists (identical to iOS `TaskNavMenu` `.top`).
            state.topSmartLists.forEach { item ->
                val loc = item.location as TaskHomeLocation.SmartList
                val itemTitle = RegistryCatalog.destinationTitle(loc.destinationId, languageTag).orEmpty()
                val kind = destinationIconKind(loc.destinationId)
                val tint = if (kind == SeptenaIconKind.Today || kind == SeptenaIconKind.Starred) todayTint else mutedIcon
                val isCurrent = state.location == loc
                DropdownMenuItem(
                    leadingIcon = {
                        Box(modifier = Modifier.width(22.dp), contentAlignment = Alignment.Center) {
                            SeptenaGlyph(kind = kind, tint = tint, size = 18.dp)
                        }
                    },
                    text = {
                        Text(
                            text = itemTitle,
                            fontWeight = if (isCurrent) FontWeight.SemiBold else FontWeight.Normal,
                        )
                    },
                    trailingIcon = if (isCurrent) {
                        { CheckmarkGlyph(tint = MaterialTheme.colorScheme.primary, size = 16.dp) }
                    } else null,
                    onClick = {
                        menuExpanded = false
                        onSelectLocation(loc)
                    },
                )
            }

            val areaIds = state.areas.mapNotNull { (it.location as? TaskHomeLocation.Area)?.id }.toSet()
            val projectsByArea = state.projects.groupBy { it.parentAreaId }
            val standaloneProjects = state.projects.filter { it.parentAreaId == null || it.parentAreaId !in areaIds }

            if (standaloneProjects.isNotEmpty()) {
                HorizontalDivider()
                standaloneProjects.forEach { projItem ->
                    val isCurrent = state.location == projItem.location
                    DropdownMenuItem(
                        leadingIcon = {
                            Box(modifier = Modifier.width(22.dp), contentAlignment = Alignment.Center) {
                                SeptenaGlyph(kind = SeptenaIconKind.Project, tint = mutedIcon, size = 15.dp)
                            }
                        },
                        text = {
                            Text(
                                text = projItem.title.orEmpty(),
                                fontWeight = if (isCurrent) FontWeight.SemiBold else FontWeight.Normal,
                            )
                        },
                        trailingIcon = if (isCurrent) {
                            { CheckmarkGlyph(tint = MaterialTheme.colorScheme.primary, size = 16.dp) }
                        } else null,
                        onClick = {
                            menuExpanded = false
                            onSelectLocation(projItem.location)
                        },
                    )
                }
            }

            state.areas.forEach { areaItem ->
                val area = areaItem.location as? TaskHomeLocation.Area ?: return@forEach
                val areaCurrent = state.location == area
                HorizontalDivider()
                DropdownMenuItem(
                    leadingIcon = {
                        Box(modifier = Modifier.width(22.dp), contentAlignment = Alignment.Center) {
                            if (areaItem.emoji != null) {
                                Text(areaItem.emoji, fontSize = 16.sp)
                            } else {
                                SeptenaGlyph(kind = SeptenaIconKind.Area, tint = mutedIcon, size = 17.dp)
                            }
                        }
                    },
                    text = {
                        Text(
                            text = area.title,
                            fontWeight = if (areaCurrent) FontWeight.SemiBold else FontWeight.Medium,
                        )
                    },
                    trailingIcon = if (areaCurrent) {
                        { CheckmarkGlyph(tint = MaterialTheme.colorScheme.primary, size = 16.dp) }
                    } else null,
                    onClick = {
                        menuExpanded = false
                        onSelectLocation(area)
                    },
                )
                projectsByArea[area.id].orEmpty().forEach { projItem ->
                    val projCurrent = state.location == projItem.location
                    DropdownMenuItem(
                        leadingIcon = {
                            Box(
                                modifier = Modifier.padding(start = 14.dp).width(22.dp),
                                contentAlignment = Alignment.Center,
                            ) {
                                SeptenaGlyph(kind = SeptenaIconKind.Project, tint = mutedIcon, size = 14.dp)
                            }
                        },
                        text = {
                            Text(
                                text = projItem.title.orEmpty(),
                                fontWeight = if (projCurrent) FontWeight.SemiBold else FontWeight.Normal,
                            )
                        },
                        trailingIcon = if (projCurrent) {
                            { CheckmarkGlyph(tint = MaterialTheme.colorScheme.primary, size = 16.dp) }
                        } else null,
                        onClick = {
                            menuExpanded = false
                            onSelectLocation(projItem.location)
                        },
                    )
                }
            }

            // Bottom smart lists (identical to iOS `TaskNavMenu` `.bottom`: Logbook, etc.).
            if (state.bottomSmartLists.isNotEmpty()) {
                HorizontalDivider()
                state.bottomSmartLists.forEach { item ->
                    val loc = item.location as TaskHomeLocation.SmartList
                    val itemTitle = RegistryCatalog.destinationTitle(loc.destinationId, languageTag).orEmpty()
                    val kind = destinationIconKind(loc.destinationId)
                    val tint = if (kind == SeptenaIconKind.Today || kind == SeptenaIconKind.Starred) todayTint else mutedIcon
                    val isCurrent = state.location == loc
                    DropdownMenuItem(
                        leadingIcon = {
                            Box(modifier = Modifier.width(22.dp), contentAlignment = Alignment.Center) {
                                SeptenaGlyph(kind = kind, tint = tint, size = 18.dp)
                            }
                        },
                        text = {
                            Text(
                                text = itemTitle,
                                fontWeight = if (isCurrent) FontWeight.SemiBold else FontWeight.Normal,
                            )
                        },
                        trailingIcon = if (isCurrent) {
                            { CheckmarkGlyph(tint = MaterialTheme.colorScheme.primary, size = 16.dp) }
                        } else null,
                        onClick = {
                            menuExpanded = false
                            onSelectLocation(loc)
                        },
                    )
                }
            }

            HorizontalDivider()
            DropdownMenuItem(
                leadingIcon = {
                    Box(modifier = Modifier.width(22.dp), contentAlignment = Alignment.Center) {
                        SeptenaGlyph(kind = SeptenaIconKind.Settings, tint = mutedIcon, size = 18.dp)
                    }
                },
                text = { Text(settingsTitle) },
                onClick = {
                    menuExpanded = false
                    onOpenSettings()
                },
            )
        }
    }
}

@Composable
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
private fun TaskHomeScaffold(
    graph: AndroidAppGraph,
    state: TaskHomeUiState,
    onShareProject: (String) -> Unit,
    title: String,
    sidebarActionTitle: String,
    quickAddTitle: String,
    quickFindTitle: String,
    starredFilterTitle: String,
    settingsTitle: String,
    completeTitle: String,
    emptyTitle: String,
    emptyDescription: String,
    inboxTitle: String,
    todayTitle: String,
    fadedTitle: String,
    homeViewModel: TaskHomeViewModel,
    languageTag: String,
    showNavigationAction: Boolean,
    onOpenNavigation: () -> Unit = {},
    rowMenuGroups: List<List<TaskRowMenuAction>>,
    rowMenuAccessibilityLabel: String,
    expandedTaskId: String?,
    onToggleExpandTask: (String) -> Unit,
    onCollapseExpandedTask: () -> Unit,
    onComplete: (String) -> Unit,
    onOpenFullPage: (String) -> Unit,
    onSendBackReview: (String) -> Unit,
    onTaskAction: (String, String) -> Unit,
    onToggleStarFilter: () -> Unit,
    onQuickFind: () -> Unit,
    onOpenSettings: () -> Unit,
    onSelectHomeLocation: (TaskHomeLocation) -> Unit,
    logbookShowingDeleted: Boolean = false,
    onLogbookShowingDeletedChange: (Boolean) -> Unit = {},
    onRequestEmptyTrash: () -> Unit = {},
    snackbarVisible: Boolean = false,
) {
    var quickAddDraft by remember { mutableStateOf<QuickAddDraft?>(null) }
    var newSectionTrigger by remember { mutableIntStateOf(0) }
    var selectionPicker by remember { mutableStateOf<SelectionPicker?>(null) }
    var pendingFixedReschedule by remember { mutableStateOf<PendingFixedReschedule?>(null) }
    var allOnToday by remember { mutableStateOf(false) }
    var activeSweepItems by remember { mutableStateOf<List<FadeSweepItem>?>(null) }
    val pullScope = rememberCoroutineScope()
    var isPullRefreshing by remember { mutableStateOf(false) }
    val magicPlusDrag = remember { MagicPlusDragState() }
    val reorderDrag = remember { TaskReorderDragState() }
    val context = LocalContext.current
    val dataVersion by graph.sync.dataVersion.collectAsStateWithLifecycle()
    val deviceSettingsVersion by graph.deviceSettings.changes.collectAsStateWithLifecycle()
    var calendarRefreshTick by remember { mutableIntStateOf(0) }
    var calendarEvents by remember { mutableStateOf<List<CalendarAgendaRow>>(emptyList()) }
    val isDark = LocalSeptenaDarkTheme.current
    val appearance = LocalAppearance.current
    val selecting = state.selectedIds.isNotEmpty()
    val destinationId = (state.location as? TaskHomeLocation.SmartList)?.destinationId
    val canCreateHere = state.location !is TaskHomeLocation.SmartList || state.canQuickAdd
    val showStarFilterButton = destinationId != RegistryDestinationIds.STARRED &&
        destinationId != RegistryDestinationIds.RECENTLY_DELETED &&
        !(destinationId == RegistryDestinationIds.LOGBOOK && logbookShowingDeleted)
    val imeVisible = WindowInsets.isImeVisible
    val formLabels = remember(languageTag) { TaskFormLabels.fromRegistry(languageTag) }
    val selectToggleLabel = remember(languageTag) {
        RegistryCatalog.actionTitle(RegistryActionIds.TASK_SELECT, languageTag = languageTag).orEmpty()
    }
    val effectiveSelectionDestId = if (destinationId == RegistryDestinationIds.LOGBOOK && logbookShowingDeleted) {
        RegistryDestinationIds.RECENTLY_DELETED
    } else {
        destinationId
    }
    val selection = TaskSelection(
        selectedIds = state.selectedIds,
        enabled = remember(effectiveSelectionDestId) {
            RegistryActionResolver.isAvailable(
                RegistryActionIds.TASK_SELECT,
                RegistryActionContext(RegistryPlatformIds.ANDROID, effectiveSelectionDestId, selectedCount = 1),
            )
        },
        toggleLabel = selectToggleLabel,
        onToggle = homeViewModel::toggleSelection,
    )
    LaunchedEffect(state.selectedIds) { allOnToday = homeViewModel.allOnToday(state.selectedIds) }
    val listSortCopy = remember(languageTag) { ListSortCopy.fromRegistry(languageTag) }
    var sortMenuOpen by remember { mutableStateOf(false) }
    // A row in its inline foldout keeps its place in a sorted list until it closes (LIST_SORT_SPEC §6).
    LaunchedEffect(expandedTaskId) { homeViewModel.setPinnedTask(expandedTaskId) }
    LaunchedEffect(state.location) {
        sortMenuOpen = false
        if (!magicPlusDrag.isDragging) magicPlusDrag.reset()
        if (!reorderDrag.isDragging) reorderDrag.reset()
    }
    DisposableEffect(context, destinationId) {
        val isTodayOrUpcoming = destinationId == RegistryDestinationIds.TODAY ||
            destinationId == RegistryDestinationIds.UPCOMING
        if (!isTodayOrUpcoming || !AndroidCalendarReader.hasPermission(context)) {
            return@DisposableEffect onDispose {}
        }
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                calendarRefreshTick += 1
            }
        }
        val resolver = context.contentResolver
        runCatching {
            resolver.registerContentObserver(CalendarContract.Events.CONTENT_URI, true, observer)
            resolver.registerContentObserver(CalendarContract.Instances.CONTENT_URI, true, observer)
        }
        onDispose {
            runCatching { resolver.unregisterContentObserver(observer) }
        }
    }
    LaunchedEffect(destinationId, dataVersion, deviceSettingsVersion, calendarRefreshTick, languageTag) {
        val isTodayOrUpcoming = destinationId == RegistryDestinationIds.TODAY ||
            destinationId == RegistryDestinationIds.UPCOMING
        if (!isTodayOrUpcoming || !AndroidCalendarReader.hasPermission(context)) {
            calendarEvents = emptyList()
            return@LaunchedEffect
        }
        calendarEvents = withContext(Dispatchers.IO) {
            if (!graph.deviceSettings.bool(RegistrySettingKeys.TASKS_SHOW_CALENDAR_EVENTS)) {
                return@withContext emptyList()
            }
            val hidden = (graph.syncedSettings.value(RegistrySettingKeys.CALENDAR_HIDDEN_TITLES) as? JsonValue.ArrayValue)
                ?.values.orEmpty()
                .mapNotNull { it.stringValue() }
                .toSet()
            val today = graph.clock.today(graph.clock.now())
            if (destinationId == RegistryDestinationIds.TODAY) {
                AndroidCalendarReader.loadAgendaRows(
                    context = context,
                    startDay = today,
                    dayCount = 1,
                    hiddenTitles = hidden,
                    includeDayLabel = false,
                    languageTag = languageTag,
                )
            } else {
                AndroidCalendarReader.loadAgendaRows(
                    context = context,
                    startDay = today.plusDays(1),
                    dayCount = RegistryRules.UPCOMING_CALENDAR_DAYS.toInt(),
                    hiddenTitles = hidden,
                    includeDayLabel = true,
                    languageTag = languageTag,
                )
            }
        }
    }
    BackHandler(enabled = selecting) { homeViewModel.clearSelection() }

    val openDefaultQuickAdd: () -> Unit = {
        quickAddDraft = defaultQuickAddDraft(state.location)
    }
    magicPlusDrag.fallbackDrop = { if (canCreateHere) openDefaultQuickAdd() }

    val openGroupTarget: (String) -> Unit = { targetKey ->
        when {
            targetKey.startsWith("area:") -> {
                val id = targetKey.removePrefix("area:")
                val dest = state.areas.firstOrNull { (it.location as? TaskHomeLocation.Area)?.id == id }?.location
                    ?: TaskHomeLocation.Area(id, "")
                onSelectHomeLocation(dest)
            }
            targetKey.startsWith("project:") -> {
                val id = targetKey.removePrefix("project:")
                val dest = state.projects.firstOrNull { (it.location as? TaskHomeLocation.Project)?.id == id }?.location
                    ?: TaskHomeLocation.Project(id, "")
                onSelectHomeLocation(dest)
            }
        }
    }

    quickAddDraft?.let { initial ->
        QuickAddSheet(
            today = graph.clock.today(graph.clock.now()),
            errorMessage = state.errorMessage,
            areas = state.areas,
            projects = state.projects,
            languageTag = languageTag,
            initialDraft = initial,
            onDismiss = { quickAddDraft = null },
            onAdd = { draft -> homeViewModel.quickAdd(draft) { quickAddDraft = null } },
            onAddAndDo = addAndDo(graph, homeViewModel) { quickAddDraft = null },
        )
    }
    pendingFixedReschedule?.let { pending ->
        RescheduleFixedRepeatDialog(
            languageTag = languageTag,
            onPickMode = { mode ->
                pendingFixedReschedule = null
                when (pending) {
                    is PendingFixedReschedule.SelectionWhen -> homeViewModel.setWhenForSelection(pending.day, mode)
                    PendingFixedReschedule.SelectionToday -> homeViewModel.applyToSelection(
                        RegistryActionIds.TASK_TOGGLE_TODAY,
                        todayEnabled = true,
                        mode = mode,
                    )
                    is PendingFixedReschedule.UpcomingDrag -> homeViewModel.rescheduleToDay(
                        pending.ids,
                        pending.dayIso,
                        mode,
                    )
                }
            },
            onDismiss = { pendingFixedReschedule = null },
        )
    }
    when (selectionPicker) {
        SelectionPicker.When -> TaskWhenSheet(
            today = graph.clock.today(graph.clock.now()),
            languageTag = languageTag,
            onDismiss = { selectionPicker = null },
            onPick = { day ->
                selectionPicker = null
                if (day == null) {
                    homeViewModel.setWhenForSelection(null)
                } else {
                    val ids = state.selectedIds
                    pullScope.launch {
                        if (homeViewModel.anyNeedsFixedRepeatPrompt(ids, day)) {
                            pendingFixedReschedule = PendingFixedReschedule.SelectionWhen(day)
                        } else {
                            homeViewModel.setWhenForSelection(day)
                        }
                    }
                }
            },
        )
        SelectionPicker.List -> TaskListPickerDialog(
            title = RegistryCatalog.actionTitle(RegistryActionIds.TASK_MOVE, field = "pluralTitle", languageTag = languageTag)
                .orEmpty(),
            areaId = null,
            projectId = null,
            showsCurrent = false,
            areas = state.areas,
            projects = state.projects,
            labels = formLabels,
            onDismiss = { selectionPicker = null },
            onPick = { areaId, projectId ->
                selectionPicker = null
                homeViewModel.moveSelection(areaId, projectId)
            },
        )
        null -> Unit
    }

    activeSweepItems?.let { itemsToSweep ->
        val keepLabel = remember(languageTag) {
            RegistryCatalog.actionTitle(RegistryActionIds.TASK_KEEP_FADED, languageTag = languageTag).orEmpty()
        }
        TaskFadeSweepSheet(
            items = itemsToSweep,
            keepTitle = keepLabel,
            languageTag = languageTag,
            isDark = isDark,
            hasActiveTexture = appearance.hasActiveTexture,
            onKeep = homeViewModel::keepFaded,
            onLetRestGo = homeViewModel::letGoFadedBatch,
            onMarkCompleted = homeViewModel::markSweepCompleted,
            onDismiss = { activeSweepItems = null },
        )
    }

    val doing by graph.doing.ui.collectAsStateWithLifecycle()
    val sectionHeader: @Composable () -> Unit = {
        SectionTitleDropdownHeader(
            state = state,
            title = title,
            languageTag = languageTag,
            settingsTitle = settingsTitle,
            onSelectLocation = onSelectHomeLocation,
            onOpenSettings = onOpenSettings,
            onShareProject = onShareProject,
        )
        state.listSort?.let(listSortCopy::sortedBy)?.let { sortedBy ->
            Text(
                text = sortedBy,
                fontSize = 13.sp,
                lineHeight = 16.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(
                    start = TaskCardMetrics.HeaderLeading,
                    end = TaskCardMetrics.Margin,
                    bottom = 10.dp,
                ),
            )
        }
        val noticedDo = doing.current?.takeIf { doing.showsNotice }
        val needsYou = doing.endedSince?.let { since -> state.agentRequestTimes.count { !it.isBefore(since) } } ?: 0
        if (noticedDo != null) {
            DoNoticeCard(
                graph = graph,
                doing = noticedDo,
                languageTag = languageTag,
                isDark = isDark,
                hasActiveTexture = appearance.hasActiveTexture,
                modifier = Modifier.padding(bottom = 10.dp),
            )
        } else if (needsYou > 0) {
            FadeSweepBannerCard(
                message = remember(languageTag, needsYou) { DoCopy(languageTag).needsYou(needsYou) },
                reviewLabel = RegistryCatalog.destinationTitle(RegistryDestinationIds.REVIEW, languageTag).orEmpty(),
                dismissLabel = noticeDismissTitle(languageTag),
                isDark = isDark,
                hasActiveTexture = appearance.hasActiveTexture,
                onReview = {
                    graph.doing.dismissNeedsYou()
                    onSelectHomeLocation(TaskHomeLocation.SmartList(RegistryDestinationIds.REVIEW))
                },
                onDismiss = graph.doing::dismissNeedsYou,
                modifier = Modifier.padding(bottom = 10.dp),
            )
        }
        if (destinationId == RegistryDestinationIds.TODAY &&
            state.showWeeklySweepBanner &&
            state.weeklySweepItems.isNotEmpty()
        ) {
            val notice = remember(languageTag, state.weeklySweepItems.size) {
                registryNoticeCopy(RegistryNoticeIds.WEEKLY_SWEEP, languageTag, state.weeklySweepItems.size)
            }
            val bannerMessage = listOf(notice.title, notice.detail).filter(String::isNotBlank).joinToString(". ")
            FadeSweepBannerCard(
                message = bannerMessage,
                reviewLabel = notice.primaryTitle,
                dismissLabel = fadeSweepText("dismissTitle", languageTag),
                isDark = isDark,
                hasActiveTexture = appearance.hasActiveTexture,
                onReview = { activeSweepItems = state.weeklySweepItems },
                onDismiss = homeViewModel::dismissWeeklySweepBanner,
                modifier = Modifier.padding(bottom = 10.dp),
            )
        } else if (destinationId == RegistryDestinationIds.LOGBOOK &&
            (state.deletedTasks.isNotEmpty() || logbookShowingDeleted)
        ) {
            val logbookLabel = remember(languageTag) {
                RegistryCatalog.destinationTitle(RegistryDestinationIds.LOGBOOK, languageTag).orEmpty()
            }
            val deletedLabel = remember(languageTag) {
                RegistryCatalog.destinationTitle(RegistryDestinationIds.RECENTLY_DELETED, languageTag).orEmpty()
            }
            val emptyTrashLabel = remember(languageTag) {
                RegistryCatalog.actionTitle(RegistryActionIds.TASK_EMPTY_TRASH, languageTag = languageTag).orEmpty()
            }
            val deletedTabLabel = if (state.deletedTasks.isNotEmpty()) {
                "$deletedLabel (${state.deletedTasks.size})"
            } else {
                deletedLabel
            }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = TaskCardMetrics.Margin, vertical = 4.dp)
                    .padding(bottom = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                SingleChoiceSegmentedButtonRow(modifier = Modifier.weight(1f)) {
                    SegmentedButton(
                        selected = !logbookShowingDeleted,
                        onClick = { onLogbookShowingDeletedChange(false) },
                        shape = SegmentedButtonDefaults.itemShape(0, 2),
                    ) {
                        Text(logbookLabel, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    SegmentedButton(
                        selected = logbookShowingDeleted,
                        onClick = { onLogbookShowingDeletedChange(true) },
                        shape = SegmentedButtonDefaults.itemShape(1, 2),
                    ) {
                        Text(deletedTabLabel, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
                if (logbookShowingDeleted && state.deletedTasks.isNotEmpty() && emptyTrashLabel.isNotBlank()) {
                    TextButton(onClick = onRequestEmptyTrash) {
                        Text(emptyTrashLabel, color = MaterialTheme.colorScheme.error, maxLines = 1)
                    }
                }
            }
        }
    }

    val fadedBanner: @Composable () -> Unit = {
        val notice = remember(languageTag) {
            registryNoticeCopy(RegistryNoticeIds.FADED_PILE, languageTag)
        }
        FadeSweepBannerCard(
            message = listOf(notice.title, notice.detail).filter(String::isNotBlank).joinToString(" · "),
            reviewLabel = notice.primaryTitle,
            dismissLabel = null,
            isDark = isDark,
            hasActiveTexture = appearance.hasActiveTexture,
            onReview = { activeSweepItems = state.fadedSweepItems },
        )
    }

    // Grouped canvas background so translucent glass task cards lift gently off the
    // canvas and let the procedural Header Wash texture shine through at the top.
    val canvasBackground = if (isDark) {
        MaterialTheme.colorScheme.background
    } else {
        MaterialTheme.colorScheme.surfaceContainerLow
    }

    CompositionLocalProvider(
        LocalMagicPlusDrag provides magicPlusDrag,
        LocalTaskReorderDrag provides reorderDrag,
    ) {
        Box(modifier = Modifier.fillMaxSize().background(canvasBackground)) {
            HeaderWashBackdrop()
            Scaffold(
                containerColor = Color.Transparent,
                bottomBar = if (selecting) {
                    {
                        TaskSelectionBar(
                            selectedCount = state.selectedIds.size,
                            destinationId = destinationId,
                            allOnToday = allOnToday,
                            allSelected = remember(state.selectedIds, state.visibleTasks) {
                                state.visibleTasks.all { it.id in state.selectedIds }
                            },
                            canComplete = state.canComplete,
                            languageTag = languageTag,
                            onCommand = { command ->
                                when (command) {
                                    is TaskSelectionCommand.Apply -> homeViewModel.applyToSelection(command.actionId)
                                    is TaskSelectionCommand.SetToday -> {
                                        if (!command.enabled) {
                                            homeViewModel.applyToSelection(
                                                RegistryActionIds.TASK_TOGGLE_TODAY,
                                                todayEnabled = false,
                                            )
                                        } else {
                                            val ids = state.selectedIds
                                            val todayIso = graph.clock.today(graph.clock.now()).toString()
                                            pullScope.launch {
                                                if (homeViewModel.anyNeedsFixedRepeatPrompt(ids, todayIso)) {
                                                    pendingFixedReschedule = PendingFixedReschedule.SelectionToday
                                                } else {
                                                    homeViewModel.applyToSelection(
                                                        RegistryActionIds.TASK_TOGGLE_TODAY,
                                                        todayEnabled = true,
                                                    )
                                                }
                                            }
                                        }
                                    }
                                    TaskSelectionCommand.PickWhen -> { selectionPicker = SelectionPicker.When }
                                    TaskSelectionCommand.PickList -> { selectionPicker = SelectionPicker.List }
                                    TaskSelectionCommand.Copy -> homeViewModel.copySelection { text ->
                                        context.getSystemService(ClipboardManager::class.java)
                                            ?.setPrimaryClip(ClipData.newPlainText(null, text))
                                    }
                                    TaskSelectionCommand.ToggleSelectAll -> homeViewModel.toggleSelectAll()
                                    TaskSelectionCommand.Done -> homeViewModel.clearSelection()
                                }
                            },
                        )
                    }
                } else {
                    {}
                },
                topBar = {
                    TopAppBar(
                        colors = TopAppBarDefaults.topAppBarColors(
                            containerColor = Color.Transparent,
                            scrolledContainerColor = Color.Transparent,
                        ),
                        // Title + icon + nav dropdown sits below over the Header Wash (iOS `ScreenTitleMenuLabel`).
                        title = {},
                        navigationIcon = if (showNavigationAction) {
                            {
                                IconButton(
                                    onClick = onOpenNavigation,
                                    modifier = Modifier.semantics { contentDescription = sidebarActionTitle },
                                ) {
                                    ChevronLeftGlyph(tint = MaterialTheme.colorScheme.onSurface)
                                }
                            }
                        } else {
                            {}
                        },
                        // Home top nav is Star + Search (matching iOS; Settings lives in sidebar & title nav menu).
                        actions = {
                            if (showStarFilterButton) {
                                IconButton(
                                    onClick = onToggleStarFilter,
                                    modifier = Modifier.semantics { contentDescription = starredFilterTitle },
                                ) {
                                    StarGlyph(
                                        filled = state.starredOnly,
                                        tint = if (state.starredOnly) {
                                            MaterialTheme.colorScheme.secondary
                                        } else {
                                            MaterialTheme.colorScheme.onSurface
                                        },
                                        size = 21.dp,
                                    )
                                }
                            }
                            state.listSort?.let { currentSort ->
                                ListSortMenuButton(
                                    copy = listSortCopy,
                                    current = currentSort,
                                    expanded = sortMenuOpen,
                                    onExpandedChange = { sortMenuOpen = it },
                                    onPick = homeViewModel::setListSort,
                                )
                            }
                            IconButton(
                                onClick = onQuickFind,
                                modifier = Modifier.semantics { contentDescription = quickFindTitle },
                            ) {
                                SearchGlyph(tint = MaterialTheme.colorScheme.onSurface)
                            }
                        },
                    )
                },
            ) { contentPadding ->
                PullToRefreshBox(
                    isRefreshing = isPullRefreshing,
                    onRefresh = {
                        if (!isPullRefreshing) {
                            isPullRefreshing = true
                            pullScope.launch {
                                try {
                                    graph.sync.syncAndWait()
                                } finally {
                                    isPullRefreshing = false
                                }
                            }
                        }
                    },
                    modifier = Modifier.fillMaxSize().padding(contentPadding),
                ) {
                    val expandedTaskContent: @Composable (TaskListItem, TaskCardPosition, Modifier) -> Unit = { task, position, rowModifier ->
                        TaskInlineFoldout(
                            graph = graph,
                            taskId = task.id,
                            fallbackTitle = task.title,
                            fallbackCompleted = task.isCompleted,
                            position = position,
                            isDark = isDark,
                            hasActiveTexture = appearance.hasActiveTexture,
                            onOpenFullPage = { id ->
                                onCollapseExpandedTask()
                                onOpenFullPage(id)
                            },
                            onCollapse = onCollapseExpandedTask,
                            modifier = rowModifier,
                        )
                    }
                    when (val location = state.location) {
                        is TaskHomeLocation.Area -> AreasProjectsScreen(
                            graph = graph,
                            destination = AreasProjectsDestination.Area(location.id),
                            modifier = Modifier.fillMaxSize(),
                            starredOnly = state.starredOnly,
                            completeTitle = completeTitle,
                            todayTitle = todayTitle,
                            fadedTitle = fadedTitle,
                            headerContent = sectionHeader,
                            rowMenuGroups = rowMenuGroups,
                            rowMenuAccessibilityLabel = rowMenuAccessibilityLabel,
                            onComplete = onComplete,
                            onTaskAction = onTaskAction,
                            selection = selection,
                            onOpenProject = { projectId ->
                                val project = state.projects.firstOrNull {
                                    (it.location as? TaskHomeLocation.Project)?.id == projectId
                                }?.location ?: TaskHomeLocation.Project(projectId, "")
                                onSelectHomeLocation(project)
                            },
                            onOpenTask = onToggleExpandTask,
                            onMagicPlusDrop = { draft -> quickAddDraft = draft },
                            expandedTaskId = expandedTaskId,
                            expandedTaskContent = expandedTaskContent,
                        )
                        is TaskHomeLocation.Project -> AreasProjectsScreen(
                            graph = graph,
                            destination = AreasProjectsDestination.Project(location.id),
                            modifier = Modifier.fillMaxSize(),
                            starredOnly = state.starredOnly,
                            completeTitle = completeTitle,
                            todayTitle = todayTitle,
                            fadedTitle = fadedTitle,
                            headerContent = sectionHeader,
                            onComplete = onComplete,
                            onOpenTask = onToggleExpandTask,
                            rowMenuGroups = rowMenuGroups,
                            rowMenuAccessibilityLabel = rowMenuAccessibilityLabel,
                            onTaskAction = onTaskAction,
                            selection = selection,
                            newSectionTrigger = newSectionTrigger,
                            onLeftProject = {
                                onSelectHomeLocation(TaskHomeLocation.SmartList(RegistryDestinationIds.TODAY))
                            },
                            onMagicPlusDrop = { draft -> quickAddDraft = draft },
                            expandedTaskId = expandedTaskId,
                            expandedTaskContent = expandedTaskContent,
                        )
                        is TaskHomeLocation.SmartList -> {
                            val isTodayList = location.destinationId == RegistryDestinationIds.TODAY
                            val isUpcomingList = location.destinationId == RegistryDestinationIds.UPCOMING
                            val isReviewList = location.destinationId == RegistryDestinationIds.REVIEW
                            val showingDeletedTab = location.destinationId == RegistryDestinationIds.LOGBOOK &&
                                logbookShowingDeleted
                            val displayedTasks = if (showingDeletedTab) state.deletedTasks else state.tasks
                            val reviewAcceptTitle = remember(languageTag) {
                                RegistryCatalog.actionTitle(RegistryActionIds.TASK_ACCEPT_REVIEW, languageTag = languageTag).orEmpty()
                            }
                            val reviewSendBackTitle = remember(languageTag) {
                                RegistryCatalog.actionTitle(RegistryActionIds.TASK_SEND_BACK_REVIEW, languageTag = languageTag).orEmpty()
                            }
                            val canReorderList = location.destinationId in setOf(
                                RegistryDestinationIds.TODAY,
                                RegistryDestinationIds.INBOX,
                                RegistryDestinationIds.UPCOMING,
                                RegistryDestinationIds.ANYTIME,
                                RegistryDestinationIds.STARRED,
                            )
                            val allowMainInlineExpand = !isReviewList && !showingDeletedTab &&
                                location.destinationId != RegistryDestinationIds.RECENTLY_DELETED
                            val inboxPositions = state.inboxTasks.map { it.position }
                            val taskPositions = displayedTasks.map { it.position }
                            TaskHomeContent(
                                completeTitle = completeTitle,
                                emptyTitle = emptyTitle,
                                emptyDescription = emptyDescription,
                                inboxBandTitle = inboxTitle,
                                todayTitle = todayTitle,
                                todayTint = MaterialTheme.colorScheme.secondary,
                                fadedTitle = fadedTitle,
                                showFadedIndicator = !isReviewList && !showingDeletedTab,
                                isDarkTheme = isDark,
                                hasActiveTexture = appearance.hasActiveTexture,
                                headerContent = sectionHeader,
                                hasLoaded = state.hasLoaded,
                                isToday = isTodayList,
                                isUpcoming = isUpcomingList,
                                upcomingDayLabelForIso = if (isUpcomingList) {
                                    { iso ->
                                        val todayDay = graph.clock.today(graph.clock.now())
                                        runCatching { java.time.LocalDate.parse(iso) }.getOrNull()
                                            ?.let { formatUpcomingDayHeader(it, todayDay, languageTag) }
                                            ?: iso
                                    }
                                } else null,
                                inboxTasks = state.inboxTasks,
                                tasks = displayedTasks,
                                calendarEvents = calendarEvents,
                                canQuickAdd = state.canQuickAdd,
                                canComplete = state.canComplete,
                                errorMessage = state.errorMessage,
                                rowMenuGroups = rowMenuGroups,
                                rowMenuAccessibilityLabel = rowMenuAccessibilityLabel,
                                modifier = Modifier.fillMaxSize(),
                                listKey = location.destinationId to showingDeletedTab,
                            selection = selection,
                            onComplete = onComplete,
                            onOpenTask = if (allowMainInlineExpand) onToggleExpandTask else onOpenFullPage,
                            onOpenCollapsibleTask = onToggleExpandTask,
                            expandedTaskId = expandedTaskId,
                            expandedTaskContent = expandedTaskContent,
                            onTaskAction = onTaskAction,
                            onOpenGroupTarget = openGroupTarget,
                            onDropInboxHeader = if (isTodayList && state.canQuickAdd) {
                                {
                                    quickAddDraft = QuickAddDraft(
                                        today = false,
                                        position = inboxPositions.firstOrNull()?.let { it - 1.0 },
                                    )
                                }
                            } else null,
                            onDropInboxRow = if (isTodayList && state.canQuickAdd) {
                                { index, before ->
                                    quickAddDraft = QuickAddDraft(
                                        today = false,
                                        position = insertionPosition(inboxPositions, index, before),
                                    )
                                }
                            } else null,
                            onDropTaskRow = if (state.canQuickAdd || isUpcomingList) {
                                { index, before ->
                                    val dayIso = if (isUpcomingList) {
                                        displayedTasks.getOrNull(index)?.group?.key?.removePrefix("day:")
                                    } else null
                                    quickAddDraft = defaultQuickAddDraft(location).copy(
                                        whenDay = dayIso,
                                        position = if (isUpcomingList) null else insertionPosition(taskPositions, index, before),
                                        useTodayPosition = isTodayList,
                                    )
                                }
                            } else null,
                            onDropGroupHeader = if (state.canQuickAdd || isUpcomingList) {
                                { targetLocationKey ->
                                    if (targetLocationKey.startsWith("day:")) {
                                        quickAddDraft = QuickAddDraft(
                                            whenDay = targetLocationKey.removePrefix("day:"),
                                        )
                                    } else {
                                        val firstInGroupPos = displayedTasks
                                            .firstOrNull { it.group?.targetLocationKey == targetLocationKey }
                                            ?.position
                                        val areaId = targetLocationKey.removePrefix("area:")
                                            .takeIf { targetLocationKey.startsWith("area:") }
                                        val projectId = targetLocationKey.removePrefix("project:")
                                            .takeIf { targetLocationKey.startsWith("project:") }
                                        quickAddDraft = defaultQuickAddDraft(location).copy(
                                            areaId = areaId,
                                            projectId = projectId,
                                            position = firstInGroupPos?.let { it - 1.0 },
                                            useTodayPosition = isTodayList,
                                        )
                                    }
                                }
                            } else null,
                            canReorder = canReorderList,
                            reorderBetweenRows = !state.isSorted,
                            onReorderInboxHeader = if (isTodayList) {
                                { ids ->
                                    val topPos = inboxPositions.firstOrNull() ?: 0.0
                                    val newPositions = List(ids.size) { i -> topPos - (ids.size - i).toDouble() }
                                    homeViewModel.reorderTasks(
                                        ids = ids,
                                        positions = newPositions,
                                        useTodayPosition = false,
                                        moveToInbox = true,
                                    )
                                }
                            } else null,
                            onReorderInboxRow = if (isTodayList) {
                                { ids, index, before ->
                                    val newPositions = reorderPositions(inboxPositions, index, before, ids.size)
                                    homeViewModel.reorderTasks(
                                        ids = ids,
                                        positions = newPositions,
                                        useTodayPosition = false,
                                        moveToInbox = true,
                                    )
                                }
                            } else null,
                            onReorderTaskRow = if (canReorderList) {
                                { ids, index, before ->
                                    val targetGroup = displayedTasks.getOrNull(index)?.group?.targetLocationKey
                                    if (isUpcomingList && targetGroup != null && targetGroup.startsWith("day:")) {
                                        homeViewModel.rescheduleToDay(ids, targetGroup.removePrefix("day:"))
                                    } else {
                                        val newPositions = reorderPositions(taskPositions, index, before, ids.size)
                                        homeViewModel.reorderTasks(
                                            ids = ids,
                                            positions = newPositions,
                                            useTodayPosition = isTodayList,
                                            targetGroupKey = targetGroup,
                                        )
                                    }
                                }
                            } else null,
                            onReorderGroupHeader = if (canReorderList) {
                                { ids, targetLocationKey ->
                                    if (isUpcomingList && targetLocationKey.startsWith("day:")) {
                                        val dayIso = targetLocationKey.removePrefix("day:")
                                        pullScope.launch {
                                            if (homeViewModel.anyNeedsFixedRepeatPrompt(ids, dayIso)) {
                                                pendingFixedReschedule = PendingFixedReschedule.UpcomingDrag(ids, dayIso)
                                            } else {
                                                homeViewModel.rescheduleToDay(ids, dayIso)
                                            }
                                        }
                                    } else {
                                        val firstInGroupPos = displayedTasks
                                            .firstOrNull { it.group?.targetLocationKey == targetLocationKey }
                                            ?.position ?: 0.0
                                        val newPositions = List(ids.size) { i -> firstInGroupPos - (ids.size - i).toDouble() }
                                        homeViewModel.reorderTasks(
                                            ids = ids,
                                            positions = newPositions,
                                            useTodayPosition = isTodayList,
                                            targetGroupKey = targetLocationKey,
                                        )
                                    }
                                }
                            } else null,
                            onApplyFilingSuggestion = homeViewModel::applyFilingSuggestion,
                            reviewAcceptTitle = reviewAcceptTitle,
                            reviewSendBackTitle = reviewSendBackTitle,
                            onAcceptReview = if (isReviewList) onComplete else null,
                            onSendBackReview = if (isReviewList) onSendBackReview else null,
                            collapsibleGroup = state.fadedGroup?.let { header ->
                                CollapsibleTaskGroup(
                                    header = header,
                                    tasks = state.fadedTasks,
                                    isExpanded = state.fadedGroupExpanded,
                                    onToggle = homeViewModel::toggleFadedGroup,
                                    banner = fadedBanner,
                                )
                            },
                        )
                        }
                    }
                }
            }

            // Round Magic Plus orb (matches iPhone `MagicPlusOrb`): visible on
            // creatable smart lists, areas and projects; hides during multi-select,
            // while an inline foldout is open, while a snackbar is up, or when the software keyboard is showing.
            if (canCreateHere && !selecting && expandedTaskId == null && !snackbarVisible && !imeVisible && !reorderDrag.isDragging) {
                MagicPlusOrb(
                    drag = magicPlusDrag,
                    isViewingProject = state.location is TaskHomeLocation.Project,
                    accessibilityLabel = quickAddTitle,
                    languageTag = languageTag,
                    onNewTask = openDefaultQuickAdd,
                    onNewSection = { newSectionTrigger += 1 },
                    modifier = Modifier
                        .align(Alignment.BottomEnd)
                        .navigationBarsPadding()
                        .padding(end = 16.dp, bottom = 16.dp),
                )
            }

            TaskDragStackOverlay(
                drag = reorderDrag,
                isDark = isDark,
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

private fun defaultQuickAddDraft(location: TaskHomeLocation): QuickAddDraft = when (location) {
    is TaskHomeLocation.Area -> QuickAddDraft(areaId = location.id)
    is TaskHomeLocation.Project -> QuickAddDraft(projectId = location.id)
    is TaskHomeLocation.SmartList -> when (location.destinationId) {
        RegistryDestinationIds.TODAY -> QuickAddDraft(today = true)
        RegistryDestinationIds.STARRED -> QuickAddDraft(starred = true)
        else -> QuickAddDraft()
    }
}

/**
 * Sort By (docs/LIST_SORT_SPEC.md §6): the list's toolbar menu with the `listSort` choices
 * and a check on the current one. Picking one is a view change, not an undoable edit.
 */
@Composable
private fun ListSortMenuButton(
    copy: ListSortCopy,
    current: String,
    expanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
    onPick: (String) -> Unit,
) {
    Box {
        IconButton(
            onClick = { onExpandedChange(true) },
            modifier = Modifier.semantics { contentDescription = copy.menuTitle },
        ) {
            SortGlyph(tint = MaterialTheme.colorScheme.onSurface)
        }
        val isDark = LocalSeptenaDarkTheme.current
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { onExpandedChange(false) },
            shape = RoundedCornerShape(14.dp),
            containerColor = if (isDark) MaterialTheme.colorScheme.surfaceContainerHigh else Color(0xF7FFFFFF),
            tonalElevation = 0.dp,
            shadowElevation = 10.dp,
            modifier = Modifier.width(210.dp),
        ) {
            Text(
                text = copy.menuTitle,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
            )
            copy.options.forEach { option ->
                val isCurrent = option.value == current
                DropdownMenuItem(
                    text = {
                        Text(
                            text = option.title,
                            fontWeight = if (isCurrent) FontWeight.SemiBold else FontWeight.Normal,
                        )
                    },
                    trailingIcon = if (isCurrent) {
                        { CheckmarkGlyph(tint = MaterialTheme.colorScheme.primary, size = 16.dp) }
                    } else null,
                    onClick = {
                        onExpandedChange(false)
                        if (!isCurrent) onPick(option.value)
                    },
                )
            }
        }
    }
}

/** The `action.sort` glyph of registry/icons.json (Material `swap_vert`): an up and a down arrow. */
@Composable
private fun SortGlyph(tint: Color) {
    Canvas(modifier = Modifier.size(21.dp)) {
        val stroke = 1.9.dp.toPx()
        val head = size.width * 0.16f
        val upX = size.width * 0.34f
        val downX = size.width * 0.66f
        val top = size.height * 0.18f
        val bottom = size.height * 0.82f
        drawLine(tint, Offset(upX, top), Offset(upX, bottom), strokeWidth = stroke, cap = StrokeCap.Round)
        drawLine(tint, Offset(upX, top), Offset(upX - head, top + head), strokeWidth = stroke, cap = StrokeCap.Round)
        drawLine(tint, Offset(upX, top), Offset(upX + head, top + head), strokeWidth = stroke, cap = StrokeCap.Round)
        drawLine(tint, Offset(downX, top), Offset(downX, bottom), strokeWidth = stroke, cap = StrokeCap.Round)
        drawLine(tint, Offset(downX, bottom), Offset(downX - head, bottom - head), strokeWidth = stroke, cap = StrokeCap.Round)
        drawLine(tint, Offset(downX, bottom), Offset(downX + head, bottom - head), strokeWidth = stroke, cap = StrokeCap.Round)
    }
}

@Composable
internal fun SearchGlyph(tint: Color) {
    Canvas(modifier = Modifier.size(21.dp)) {
        val stroke = 1.9.dp.toPx()
        val radius = size.minDimension * 0.30f
        val center = Offset(size.width * 0.43f, size.height * 0.43f)
        drawCircle(tint, radius = radius, center = center, style = Stroke(width = stroke))
        val offset = radius * 0.72f
        drawLine(
            tint,
            Offset(center.x + offset, center.y + offset),
            Offset(size.width * 0.86f, size.height * 0.86f),
            strokeWidth = stroke,
            cap = StrokeCap.Round,
        )
    }
}

/** Add and Do for a Quick Add sheet, or null when the linked core has no Do rules. */
private fun addAndDo(
    graph: AndroidAppGraph,
    homeViewModel: TaskHomeViewModel,
    onSaved: () -> Unit,
): ((QuickAddDraft) -> Unit)? {
    if (!graph.doing.isAvailable) return null
    return { draft ->
        homeViewModel.quickAdd(draft) { taskId ->
            onSaved()
            graph.doing.begin(taskId)
        }
    }
}

private fun taskRowMenuGroups(
    menuId: String,
    destinationId: String?,
    languageTag: String,
    offersDo: Boolean,
): List<List<TaskRowMenuAction>> {
    val supportedActions = if (menuId == "task.recentlyDeleted") {
        setOf(RegistryActionIds.TASK_RESTORE, RegistryActionIds.TASK_DELETE_PERMANENTLY)
    } else {
        setOfNotNull(
            RegistryActionIds.TASK_DO.takeIf { offersDo },
            RegistryActionIds.TASK_ACCEPT_REVIEW,
            RegistryActionIds.TASK_KEEP_FADED,
            RegistryActionIds.TASK_LET_GO_FADED,
            RegistryActionIds.TASK_WAITING_ON,
            RegistryActionIds.TASK_GOT_IT_BACK,
            RegistryActionIds.TASK_OPEN,
            RegistryActionIds.TASK_WHEN,
            RegistryActionIds.TASK_MOVE,
            RegistryActionIds.TASK_TAGS,
            RegistryActionIds.TASK_DEADLINE,
            RegistryActionIds.TASK_TOGGLE_STAR,
            RegistryActionIds.TASK_ADD_REFERENCE,
            RegistryActionIds.TASK_DUPLICATE,
            RegistryActionIds.TASK_SHARE,
            RegistryActionIds.TASK_SELECT,
            RegistryActionIds.TASK_DELETE,
        )
    }
    val context = RegistryActionContext(
        platform = RegistryPlatformIds.ANDROID,
        destinationId = destinationId,
        selectedCount = 1,
    )
    val available = RegistryActionResolver.availableActionIds(context).toSet()
    return RegistryCatalog.menuActionGroups(menuId).mapNotNull { group ->
        group.actionIds.mapNotNull { id ->
            if (id !in supportedActions || id !in available) return@mapNotNull null
            val title = RegistryCatalog.actionTitle(id, languageTag = languageTag).orEmpty()
            TaskRowMenuAction(
                id = id,
                title = title,
                isDestructive = RegistryCatalog.actionRole(id) == "destructive",
                selectedTitle = if (id == RegistryActionIds.TASK_TOGGLE_STAR) {
                    RegistryCatalog.actionTitle(id, field = "removeTitle", languageTag = languageTag)
                } else null,
                unselectedTitle = if (id == RegistryActionIds.TASK_TOGGLE_STAR) {
                    RegistryCatalog.actionAddTitle(id, languageTag)
                } else null,
                needsReview = id == RegistryActionIds.TASK_ACCEPT_REVIEW,
                needsFaded = id == RegistryActionIds.TASK_KEEP_FADED || id == RegistryActionIds.TASK_LET_GO_FADED,
                needsWaiting = id == RegistryActionIds.TASK_GOT_IT_BACK,
                icon = actionMenuIcon(id),
            )
        }.withAssign(menuId, languageTag).takeIf { it.isNotEmpty() }
    }
}

/** Assign To follows Move, as in the registry menu; a row shows it only in a shared project. */
private fun List<TaskRowMenuAction>.withAssign(menuId: String, languageTag: String): List<TaskRowMenuAction> {
    val move = indexOfFirst { it.id == RegistryActionIds.TASK_MOVE }
    val title = RegistryCatalog.submenuTitle(menuId, ASSIGN_SUBMENU, languageTag)
    if (move < 0 || title == null) return this
    val assign = TaskRowMenuAction(
        id = ASSIGN_SUBMENU,
        title = title,
        icon = TaskMenuActionIcon.Assign,
        needsAssignees = true,
    )
    return take(move + 1) + assign + drop(move + 1)
}

private const val TASK_ROW_MENU = "task.row"

/** The `task.row` submenu that opens the member list. */
private const val ASSIGN_SUBMENU = "assign"

private fun actionMenuIcon(actionId: String): TaskMenuActionIcon = when (actionId) {
    RegistryActionIds.TASK_DO -> TaskMenuActionIcon.Do
    RegistryActionIds.TASK_WHEN -> TaskMenuActionIcon.When
    RegistryActionIds.TASK_MOVE -> TaskMenuActionIcon.Move
    RegistryActionIds.TASK_TAGS -> TaskMenuActionIcon.Tags
    RegistryActionIds.TASK_DEADLINE -> TaskMenuActionIcon.Deadline
    RegistryActionIds.TASK_TOGGLE_STAR -> TaskMenuActionIcon.Star
    RegistryActionIds.TASK_OPEN -> TaskMenuActionIcon.Open
    RegistryActionIds.TASK_ADD_REFERENCE -> TaskMenuActionIcon.AddReference
    RegistryActionIds.TASK_DUPLICATE -> TaskMenuActionIcon.Duplicate
    RegistryActionIds.TASK_SHARE -> TaskMenuActionIcon.Share
    RegistryActionIds.TASK_SELECT -> TaskMenuActionIcon.Select
    RegistryActionIds.TASK_DELETE,
    RegistryActionIds.TASK_DELETE_PERMANENTLY -> TaskMenuActionIcon.Delete
    RegistryActionIds.TASK_RESTORE -> TaskMenuActionIcon.Restore
    RegistryActionIds.TASK_ACCEPT_REVIEW,
    RegistryActionIds.TASK_KEEP_FADED -> TaskMenuActionIcon.Check
    RegistryActionIds.TASK_LET_GO_FADED -> TaskMenuActionIcon.Cancel
    RegistryActionIds.TASK_WAITING_ON -> TaskMenuActionIcon.Assign
    RegistryActionIds.TASK_GOT_IT_BACK -> TaskMenuActionIcon.Restore
    else -> TaskMenuActionIcon.None
}

private val KEYBOARD_LIST_INDEX: Map<Key, Int> = mapOf(
    Key.One to 0,
    Key.Two to 1,
    Key.Three to 2,
    Key.Four to 3,
    Key.Five to 4,
    Key.Six to 5,
    Key.Seven to 6,
    Key.Eight to 7,
    Key.Nine to 8,
)

private enum class SelectionPicker { When, List }

private sealed interface PendingFixedReschedule {
    data class SelectionWhen(val day: String) : PendingFixedReschedule
    data object SelectionToday : PendingFixedReschedule
    data class UpcomingDrag(val ids: List<String>, val dayIso: String) : PendingFixedReschedule
}

private data class PurgeTasksRequest(val ids: List<String>, val promptId: String)

private data class PurgePromptCopy(
    val title: String,
    val message: String,
    val confirmTitle: String,
    val cancelTitle: String,
)

private fun purgePromptCopy(promptId: String, count: Int, languageTag: String): PurgePromptCopy {
    val prompt = RegistryCatalog.surface(promptId)?.fields.orEmpty()
    val rawTitle = prompt["title"]
    val title = when (rawTitle) {
        is JsonValue.ObjectValue -> {
            val otherKey = rawTitle.fields["other"].stringValue().orEmpty()
            val oneFallback = rawTitle.fields["one"].stringValue() ?: otherKey
            localizedPlural(otherKey, oneFallback, otherKey, count, languageTag)
        }
        else -> {
            val raw = rawTitle.stringValue().orEmpty()
            (RegistryCatalog.localizedString(raw, languageTag) ?: raw).replace("{count}", count.toString())
        }
    }
    val rawMessage = prompt["message"].stringValue().orEmpty()
    val message = RegistryCatalog.localizedString(rawMessage, languageTag) ?: rawMessage
    val rawConfirm = prompt["confirmTitle"].stringValue().orEmpty()
    val confirmTitle = RegistryCatalog.localizedString(rawConfirm, languageTag) ?: rawConfirm
    val promptsRoot = RegistryCatalog.document("surfaces").fields["prompts"] as? JsonValue.ObjectValue
    val rawCancel = promptsRoot?.fields?.get("cancelTitle").stringValue().orEmpty()
    val cancelTitle = RegistryCatalog.localizedString(rawCancel, languageTag) ?: rawCancel
    return PurgePromptCopy(title = title, message = message, confirmTitle = confirmTitle, cancelTitle = cancelTitle)
}

internal fun localizedPlural(
    key: String,
    oneFallback: String,
    otherFallback: String,
    count: Int,
    languageTag: String,
): String {
    val translations = RegistryCatalog.document("localizations")
    val locale = translations.fields.keys.firstOrNull { it.equals(languageTag, ignoreCase = true) }
        ?: translations.fields.keys.firstOrNull {
            it.substringBefore('-').equals(languageTag.substringBefore('-'), ignoreCase = true)
        }
    val selected = locale?.let { translations.fields[it] as? JsonValue.ObjectValue }
    val entry = selected?.fields?.get(key)
    val template = when (entry) {
        is JsonValue.ObjectValue -> {
            val forms = (entry.fields["forms"] as? JsonValue.ObjectValue)?.fields ?: entry.fields
            if (count == 1) forms["one"].stringValue() ?: forms["other"].stringValue()
            else forms["other"].stringValue()
        }
        is JsonValue.StringValue -> entry.value
        else -> null
    } ?: if (count == 1) oneFallback else otherFallback
    return template.replace("{count}", count.toString())
}

private class TaskHomeViewModelFactory(
    private val graph: AndroidAppGraph,
) : ViewModelProvider.Factory {
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
        require(modelClass.isAssignableFrom(TaskHomeViewModel::class.java))
        @Suppress("UNCHECKED_CAST")
        return TaskHomeViewModel(graph) as T
    }
}
