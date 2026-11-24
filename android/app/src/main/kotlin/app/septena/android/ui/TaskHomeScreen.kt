package app.septena.android.ui

import app.septena.ui.LocalTaskListStyle
import app.septena.core.generated.RegistryPromptIds
import androidx.compose.material3.LocalContentColor
import androidx.compose.ui.text.font.FontWeight
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.NavigationDrawerItemDefaults
import androidx.compose.material3.PermanentDrawerSheet
import androidx.compose.material3.PermanentNavigationDrawer
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberDrawerState
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import app.septena.android.AndroidAppGraph
import app.septena.core.RegistryActionContext
import app.septena.core.RegistryActionResolver
import app.septena.core.RegistryCatalog
import app.septena.core.generated.RegistryActionIds
import app.septena.core.generated.RegistryCapabilityIds
import app.septena.core.generated.RegistryDestinationIds
import app.septena.core.generated.RegistryIconIds
import app.septena.core.generated.RegistryPlatformIds
import app.septena.core.generated.RegistrySurfaceIds
import app.septena.ui.RegistryIcon
import app.septena.ui.TaskHomeContent
import app.septena.ui.TaskRowMenuAction
import app.septena.ui.TaskSelection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
@OptIn(ExperimentalMaterial3Api::class)
fun TaskHomeScreen(graph: AndroidAppGraph) {
    var openedTaskId by rememberSaveable { mutableStateOf<String?>(null) }
    var openedTaskAttribute by rememberSaveable { mutableStateOf<String?>(null) }
    var quickFindOpen by rememberSaveable { mutableStateOf(false) }
    var settingsOpen by rememberSaveable { mutableStateOf(false) }
    val factory = remember(graph) { TaskHomeViewModelFactory(graph) }
    val homeViewModel: TaskHomeViewModel = viewModel(factory = factory)
    val state by homeViewModel.state.collectAsStateWithLifecycle()
    val selectHomeLocation: (TaskHomeLocation) -> Unit = { location ->
        homeViewModel.select(location)
    }
    val undoSnackbarHostState = remember { SnackbarHostState() }
    val languageTag = LocalConfiguration.current.locales[0].toLanguageTag()
    val wideLayout = LocalConfiguration.current.screenWidthDp >= 600
    val localContext = LocalContext.current
    val rowMenuId = if ((state.location as? TaskHomeLocation.SmartList)?.destinationId == RegistryDestinationIds.RECENTLY_DELETED) {
        "task.recentlyDeleted"
    } else {
        "task.row"
    }
    val rowMenuGroups = remember(rowMenuId, languageTag, state.location) {
        taskRowMenuGroups(rowMenuId, (state.location as? TaskHomeLocation.SmartList)?.destinationId, languageTag)
    }
    val rowMenuAccessibilityLabel = remember(languageTag) {
        surfaceField(RegistrySurfaceIds.TASK_ROW_MENU, "accessibilityLabel", languageTag)
    }
    val shareTitle = RegistryCatalog.actionTitle(RegistryActionIds.TASK_SHARE, languageTag = languageTag).orEmpty()
    val openTaskWithAttribute: (String, String?) -> Unit = { id, attribute ->
        openedTaskId = id
        openedTaskAttribute = attribute
    }
    val onTaskAction: (String, String) -> Unit = { id, actionId ->
        when {
            actionId == RegistryActionIds.TASK_OPEN -> openTaskWithAttribute(id, null)
            RegistryCatalog.actionOpensAttribute(actionId) != null ->
                openTaskWithAttribute(id, RegistryCatalog.actionOpensAttribute(actionId))
            actionId == RegistryActionIds.TASK_TOGGLE_STAR -> homeViewModel.toggleStar(id)
            actionId == RegistryActionIds.TASK_DUPLICATE -> homeViewModel.duplicate(id)
            actionId == RegistryActionIds.TASK_SHARE -> homeViewModel.shareText(id) { shareText ->
                val intent = Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(Intent.EXTRA_TEXT, shareText)
                }
                localContext.startActivity(Intent.createChooser(intent, shareTitle))
            }
            actionId == RegistryActionIds.TASK_TOGGLE_COMPLETE -> homeViewModel.complete(id)
            actionId == RegistryActionIds.TASK_DELETE -> homeViewModel.delete(id)
            actionId == RegistryActionIds.TASK_RESTORE -> homeViewModel.restore(id)
            actionId == RegistryActionIds.TASK_ACCEPT_REVIEW -> homeViewModel.acceptReview(id)
            actionId == RegistryActionIds.TASK_KEEP_FADED -> homeViewModel.keepFaded(id)
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
                    withContext(Dispatchers.IO) { graph.taskUndoHistory.undo(graph.taskMutator) }
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
    val pauseAgentsTitle = RegistryCatalog.actionTitle(
        RegistryActionIds.APP_PAUSE_AGENTS,
        field = if (state.agentsPaused) "activeTitle" else "title",
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
    val areasTitle = RegistryCatalog.capabilityTitle(RegistryCapabilityIds.PLACES_AREAS, languageTag).orEmpty()
    val projectsTitle = RegistryCatalog.capabilityTitle(RegistryCapabilityIds.PLACES_PROJECTS, languageTag).orEmpty()
    val inboxTitle = RegistryCatalog.destinationTitle(RegistryDestinationIds.INBOX, languageTag).orEmpty()
    val todayTitle = RegistryCatalog.destinationTitle(RegistryDestinationIds.TODAY, languageTag).orEmpty()
    val emptyTitle = (state.location as? TaskHomeLocation.SmartList)
        ?.let { RegistryCatalog.destinationEmptyTitle(it.destinationId, languageTag) }
        .orEmpty()
    val emptyDescription = (state.location as? TaskHomeLocation.SmartList)
        ?.let { RegistryCatalog.destinationEmptyDetail(it.destinationId, languageTag) }
        .orEmpty()
    val openQuickFindTarget: (QuickFindTarget) -> Unit = { target ->
        quickFindOpen = false
        when (target) {
            is QuickFindTarget.Task -> {
                val destination = when {
                    target.projectId != null -> state.projects.firstOrNull {
                        (it.location as? TaskHomeLocation.Project)?.id == target.projectId
                    }?.location ?: TaskHomeLocation.Project(target.projectId, "")
                    target.areaId != null -> state.areas.firstOrNull {
                        (it.location as? TaskHomeLocation.Area)?.id == target.areaId
                    }?.location ?: TaskHomeLocation.Area(target.areaId, "")
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

    // The back gesture leaves an area or project page for Today, not the app.
    BackHandler(enabled = state.location !is TaskHomeLocation.SmartList) {
        selectHomeLocation(TaskHomeLocation.SmartList(RegistryDestinationIds.TODAY))
    }

    Box(modifier = Modifier.fillMaxSize()) {
        if (wideLayout) {
            PermanentNavigationDrawer(
                drawerContent = {
                    PermanentDrawerSheet {
                        TaskHomeNavigation(
                            state = state,
                            languageTag = languageTag,
                            areasTitle = areasTitle,
                            projectsTitle = projectsTitle,
                            settingsTitle = settingsTitle,
                            onSelect = selectHomeLocation,
                            onSetAreaEmoji = homeViewModel::setAreaEmoji,
                            onOpenSettings = { settingsOpen = true },
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
                        onBack = { openedTaskId = null; openedTaskAttribute = null },
                        initialAttribute = openedTaskAttribute,
                    )
                } else {
                    TaskHomeScaffold(
                        graph = graph,
                        state = state,
                        title = pageTitle,
                        sidebarActionTitle = sidebarActionTitle,
                        quickAddTitle = quickAddTitle,
                        quickFindTitle = quickFindTitle,
                        pauseAgentsTitle = pauseAgentsTitle,
                        completeTitle = completeTitle,
                        emptyTitle = emptyTitle,
                        emptyDescription = emptyDescription,
                        inboxTitle = inboxTitle,
                        todayTitle = todayTitle,
                        homeViewModel = homeViewModel,
                        languageTag = languageTag,
                        showNavigationAction = false,
                        onComplete = homeViewModel::complete,
                        rowMenuGroups = rowMenuGroups,
                        rowMenuAccessibilityLabel = rowMenuAccessibilityLabel,
                        onOpenTask = { openTaskWithAttribute(it, null) },
                        onTaskAction = onTaskAction,
                        onQuickFind = { quickFindOpen = true },
                        onToggleAgentsPaused = { homeViewModel.setAgentsPaused(!state.agentsPaused) },
                        onSelectHomeLocation = selectHomeLocation,
                        settingsTitle = settingsTitle,
                        onOpenSettings = { settingsOpen = true },
                    )
                }
            }
        } else {
            val drawerState = rememberDrawerState(initialValue = DrawerValue.Closed)
            val scope = rememberCoroutineScope()
            ModalNavigationDrawer(
                drawerState = drawerState,
                drawerContent = {
                    ModalDrawerSheet {
                        TaskHomeNavigation(
                            state = state,
                            languageTag = languageTag,
                            areasTitle = areasTitle,
                            projectsTitle = projectsTitle,
                            settingsTitle = settingsTitle,
                            onSetAreaEmoji = homeViewModel::setAreaEmoji,
                            onSelect = { location ->
                                selectHomeLocation(location)
                                scope.launch { drawerState.close() }
                            },
                            onOpenSettings = {
                                settingsOpen = true
                                scope.launch { drawerState.close() }
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
                        onBack = { openedTaskId = null; openedTaskAttribute = null },
                        initialAttribute = openedTaskAttribute,
                    )
                } else {
                    TaskHomeScaffold(
                        graph = graph,
                        state = state,
                        title = pageTitle,
                        sidebarActionTitle = sidebarActionTitle,
                        quickAddTitle = quickAddTitle,
                        quickFindTitle = quickFindTitle,
                        pauseAgentsTitle = pauseAgentsTitle,
                        completeTitle = completeTitle,
                        emptyTitle = emptyTitle,
                        emptyDescription = emptyDescription,
                        inboxTitle = inboxTitle,
                        todayTitle = todayTitle,
                        homeViewModel = homeViewModel,
                        languageTag = languageTag,
                        showNavigationAction = true,
                        onOpenNavigation = { scope.launch { drawerState.open() } },
                        onComplete = homeViewModel::complete,
                        rowMenuGroups = rowMenuGroups,
                        rowMenuAccessibilityLabel = rowMenuAccessibilityLabel,
                        onOpenTask = { openTaskWithAttribute(it, null) },
                        onTaskAction = onTaskAction,
                        onQuickFind = { quickFindOpen = true },
                        onToggleAgentsPaused = { homeViewModel.setAgentsPaused(!state.agentsPaused) },
                        onSelectHomeLocation = selectHomeLocation,
                        settingsTitle = settingsTitle,
                        onOpenSettings = { settingsOpen = true },
                    )
                }
            }
        }

        SnackbarHost(
            hostState = undoSnackbarHostState,
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(horizontal = 16.dp, vertical = 16.dp),
        )
    }
}

@Composable
private fun TaskHomeNavigation(
    state: TaskHomeUiState,
    languageTag: String,
    areasTitle: String,
    projectsTitle: String,
    settingsTitle: String,
    onSelect: (TaskHomeLocation) -> Unit,
    onSetAreaEmoji: (String, String?) -> Unit,
    onOpenSettings: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(vertical = 12.dp),
    ) {
        state.smartLists.forEach { item ->
            val location = item.location as TaskHomeLocation.SmartList
            val title = RegistryCatalog.destinationTitle(location.destinationId, languageTag).orEmpty()
            NavigationDrawerItem(
                icon = {
                    val icon = RegistryCatalog.destinationIcon(location.destinationId)
                    RegistryIcon(icon, contentDescription = null, tint = glyphTint(icon))
                },
                label = { Text(title) },
                selected = state.location == item.location,
                onClick = { onSelect(item.location) },
                modifier = Modifier.padding(NavigationDrawerItemDefaults.ItemPadding),
            )
        }

        if (areasTitle.isNotEmpty() || projectsTitle.isNotEmpty()) {
            HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
        }
        if (areasTitle.isNotEmpty()) {
            DrawerGroupTitle(areasTitle)
            state.areas.forEach { item ->
                AreaNavigationDrawerItem(
                    item = item,
                    selected = state.location == item.location,
                    languageTag = languageTag,
                    onSelect = { onSelect(item.location) },
                    onSetEmoji = { emoji ->
                        val area = item.location as TaskHomeLocation.Area
                        onSetAreaEmoji(area.id, emoji)
                    },
                )
            }
        }
        if (projectsTitle.isNotEmpty()) {
            DrawerGroupTitle(projectsTitle)
            state.projects.forEach { item ->
                NavigationDrawerItem(
                    icon = { RegistryIcon(RegistryIconIds.PLACE_PROJECT, contentDescription = null) },
                    label = { Text(item.title.orEmpty()) },
                    selected = state.location == item.location,
                    onClick = { onSelect(item.location) },
                    modifier = Modifier.padding(NavigationDrawerItemDefaults.ItemPadding),
                )
            }
        }
        HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
        NavigationDrawerItem(
            icon = {
                RegistryIcon(RegistryCatalog.actionIcon(RegistryActionIds.APP_SETTINGS), contentDescription = null)
            },
            label = { Text(settingsTitle) },
            selected = false,
            onClick = onOpenSettings,
            modifier = Modifier.padding(NavigationDrawerItemDefaults.ItemPadding),
        )
    }
}

@Composable
private fun AreaNavigationDrawerItem(
    item: TaskHomeNavigationItem,
    selected: Boolean,
    languageTag: String,
    onSelect: () -> Unit,
    onSetEmoji: (String?) -> Unit,
) {
    val area = item.location as? TaskHomeLocation.Area ?: return
    var menuExpanded by rememberSaveable(area.id) { mutableStateOf(false) }
    var emojiPickerOpen by rememberSaveable(area.id) { mutableStateOf(false) }
    val menuActions = remember {
        RegistryCatalog.menuActionIds("sidebar.area")
    }
    val actionContext = remember {
        RegistryActionContext(
            platform = RegistryPlatformIds.ANDROID,
            destinationId = null,
            selectedCount = 1,
        )
    }
    val changeEmojiAvailable = RegistryActionIds.AREA_CHANGE_EMOJI in menuActions &&
        RegistryActionResolver.isAvailable(RegistryActionIds.AREA_CHANGE_EMOJI, actionContext)
    val changeEmojiTitle = RegistryCatalog.actionTitle(
        RegistryActionIds.AREA_CHANGE_EMOJI,
        languageTag = languageTag,
    ).orEmpty()

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(NavigationDrawerItemDefaults.ItemPadding),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        NavigationDrawerItem(
            label = {
                Row(horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(10.dp)) {
                    item.emoji?.let { Text(it) }
                    Text(item.title.orEmpty())
                }
            },
            selected = selected,
            onClick = onSelect,
            modifier = Modifier.weight(1f),
        )
        if (changeEmojiAvailable) {
            Box {
                IconButton(onClick = { menuExpanded = true }) {
                    RegistryIcon(RegistryIconIds.ACTION_MORE, contentDescription = changeEmojiTitle)
                }
                DropdownMenu(expanded = menuExpanded, onDismissRequest = { menuExpanded = false }) {
                    DropdownMenuItem(
                        leadingIcon = {
                            RegistryIcon(RegistryCatalog.actionIcon(RegistryActionIds.AREA_CHANGE_EMOJI), contentDescription = null)
                        },
                        text = { Text(changeEmojiTitle) },
                        onClick = {
                            menuExpanded = false
                            emojiPickerOpen = true
                        },
                    )
                }
            }
        }
    }
    if (emojiPickerOpen) {
        AreaEmojiPickerSheet(
            initialEmoji = item.emoji,
            languageTag = languageTag,
            onDismissRequest = { emojiPickerOpen = false },
            onSelect = onSetEmoji,
        )
    }
}

@Composable
private fun DrawerGroupTitle(title: String) {
    Text(
        text = title,
        style = MaterialTheme.typography.titleSmall,
        modifier = Modifier.padding(start = 28.dp, top = 12.dp, bottom = 4.dp),
    )
}

@Composable
@OptIn(ExperimentalMaterial3Api::class)
private fun TaskHomeScaffold(
    graph: AndroidAppGraph,
    state: TaskHomeUiState,
    title: String,
    sidebarActionTitle: String,
    quickAddTitle: String,
    quickFindTitle: String,
    pauseAgentsTitle: String,
    completeTitle: String,
    emptyTitle: String,
    emptyDescription: String,
    inboxTitle: String,
    todayTitle: String,
    homeViewModel: TaskHomeViewModel,
    languageTag: String,
    showNavigationAction: Boolean,
    onOpenNavigation: () -> Unit = {},
    rowMenuGroups: List<List<TaskRowMenuAction>>,
    rowMenuAccessibilityLabel: String,
    onComplete: (String) -> Unit,
    onOpenTask: (String) -> Unit,
    onTaskAction: (String, String) -> Unit,
    onQuickFind: () -> Unit,
    onToggleAgentsPaused: () -> Unit,
    onSelectHomeLocation: (TaskHomeLocation) -> Unit,
    settingsTitle: String,
    onOpenSettings: () -> Unit,
) {
    var quickAddOpen by rememberSaveable { mutableStateOf(false) }
    var overflowOpen by remember { mutableStateOf(false) }
    var newPlacePrompt by rememberSaveable { mutableStateOf<String?>(null) }
    var starredOnly by rememberSaveable(state.location.toString()) { mutableStateOf(false) }
    val hasStarred = (state.inboxTasks + state.tasks).any { it.isStarred && !it.isCompleted }
    val showsStarFilter = hasStarred && state.location is TaskHomeLocation.SmartList &&
        (state.location as TaskHomeLocation.SmartList).destinationId != RegistryDestinationIds.STARRED
    val filterStarred = starredOnly && showsStarFilter
    var selectionPicker by remember { mutableStateOf<SelectionPicker?>(null) }
    var allOnToday by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val selecting = state.selectedIds.isNotEmpty()
    val destinationId = (state.location as? TaskHomeLocation.SmartList)?.destinationId
    val formLabels = remember(languageTag) { TaskFormLabels.fromRegistry(languageTag) }
    val selectToggleLabel = remember(languageTag) {
        RegistryCatalog.actionTitle(RegistryActionIds.TASK_SELECT, languageTag = languageTag).orEmpty()
    }
    val selection = TaskSelection(
        selectedIds = state.selectedIds,
        enabled = remember(destinationId) {
            RegistryActionResolver.isAvailable(
                RegistryActionIds.TASK_SELECT,
                RegistryActionContext(RegistryPlatformIds.ANDROID, destinationId, selectedCount = 1),
            )
        },
        toggleLabel = selectToggleLabel,
        onToggle = homeViewModel::toggleSelection,
    )
    LaunchedEffect(state.selectedIds) { allOnToday = homeViewModel.allOnToday(state.selectedIds) }
    BackHandler(enabled = selecting) { homeViewModel.clearSelection() }

    newPlacePrompt?.let { promptId ->
        TextEntryDialog(
            promptId = promptId,
            languageTag = languageTag,
            onDismiss = { newPlacePrompt = null },
            onConfirm = { title ->
                newPlacePrompt = null
                if (promptId == RegistryPromptIds.NEW_AREA) homeViewModel.createArea(title)
                else homeViewModel.createProject(title)
            },
        )
    }
    if (quickAddOpen) {
        QuickAddSheet(
            today = graph.clock.today(graph.clock.now()),
            errorMessage = state.errorMessage,
            areas = state.areas,
            projects = state.projects,
            languageTag = languageTag,
            onDismiss = { quickAddOpen = false },
            onAdd = { draft -> homeViewModel.quickAdd(draft) { quickAddOpen = false } },
        )
    }
    when (selectionPicker) {
        SelectionPicker.When -> TaskWhenSheet(
            today = graph.clock.today(graph.clock.now()),
            languageTag = languageTag,
            onDismiss = { selectionPicker = null },
            onPick = { day ->
                selectionPicker = null
                homeViewModel.setWhenForSelection(day)
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

    // The header texture sits behind the transparent app bar and the first
    // rows, on the page background (iPhone `HeaderWashView`).
    Box(modifier = Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        HeaderWashBackdrop()
        Scaffold(
            containerColor = Color.Transparent,
            bottomBar = if (selecting) {
                {
                    TaskSelectionBar(
                        selectedCount = state.selectedIds.size,
                        destinationId = destinationId,
                        allOnToday = allOnToday,
                        allSelected = remember(state.selectedIds, state.inboxTasks, state.tasks) {
                            (state.inboxTasks + state.tasks).all { it.id in state.selectedIds }
                        },
                        canComplete = state.canComplete,
                        languageTag = languageTag,
                        onCommand = { command ->
                            when (command) {
                                is TaskSelectionCommand.Apply -> homeViewModel.applyToSelection(command.actionId)
                                is TaskSelectionCommand.SetToday -> homeViewModel.applyToSelection(
                                    RegistryActionIds.TASK_TOGGLE_TODAY,
                                    todayEnabled = command.enabled,
                                )
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
            floatingActionButton = if (!selecting && state.canQuickAdd && state.location is TaskHomeLocation.SmartList) {
                {
                    val orb = LocalAddButtonColors.current
                    FloatingActionButton(
                        onClick = { quickAddOpen = true },
                        containerColor = orb.fill,
                        contentColor = orb.ink,
                    ) {
                        RegistryIcon(
                            RegistryCatalog.actionIcon(RegistryActionIds.APP_QUICK_ADD),
                            contentDescription = quickAddTitle,
                        )
                    }
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
                    // A place shows its title in the page, as on iPhone; a list shows it here with its glyph.
                    title = {
                        if (destinationId != null) {
                            val icon = RegistryCatalog.destinationIcon(destinationId)
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp),
                            ) {
                                RegistryIcon(icon, contentDescription = null, tint = glyphTint(icon))
                                Text(title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
                            }
                        }
                    },
                    navigationIcon = if (showNavigationAction) {
                        {
                            IconButton(onClick = onOpenNavigation) {
                                RegistryIcon(
                                    RegistryCatalog.actionIcon(RegistryActionIds.APP_TOGGLE_SIDEBAR),
                                    contentDescription = sidebarActionTitle,
                                )
                            }
                        }
                    } else {
                        {}
                    },
                    actions = {
                        // iPhone shows the star filter only while an open task is starred.
                        if (showsStarFilter) {
                            IconButton(onClick = { starredOnly = !starredOnly }) {
                                RegistryIcon(
                                    RegistryIconIds.ACTION_STAR,
                                    contentDescription = RegistryCatalog.destinationTitle(
                                        RegistryDestinationIds.STARRED,
                                        languageTag,
                                    ),
                                    on = filterStarred,
                                    tint = if (filterStarred) LocalTaskListStyle.current.starTint
                                    else LocalContentColor.current,
                                )
                            }
                        }
                        IconButton(onClick = onQuickFind) {
                            RegistryIcon(
                                RegistryCatalog.actionIcon(RegistryActionIds.APP_QUICK_FIND),
                                contentDescription = quickFindTitle,
                            )
                        }
                        IconButton(onClick = onOpenSettings) {
                            RegistryIcon(
                                RegistryCatalog.actionIcon(RegistryActionIds.APP_SETTINGS),
                                contentDescription = settingsTitle,
                            )
                        }
                        // Pause all agents is an Android action; it keeps a place here
                        // until the agents page owns it, as on iPhone.
                        Box {
                            IconButton(onClick = { overflowOpen = true }) {
                                RegistryIcon(RegistryIconIds.ACTION_MORE, contentDescription = title)
                            }
                            DropdownMenu(expanded = overflowOpen, onDismissRequest = { overflowOpen = false }) {
                                listOf(
                                    RegistryActionIds.SIDEBAR_NEW_AREA to RegistryPromptIds.NEW_AREA,
                                    RegistryActionIds.SIDEBAR_NEW_PROJECT to RegistryPromptIds.NEW_PROJECT,
                                ).forEach { (actionId, promptId) ->
                                    DropdownMenuItem(
                                        leadingIcon = {
                                            RegistryIcon(RegistryCatalog.actionIcon(actionId), contentDescription = null)
                                        },
                                        text = {
                                            Text(RegistryCatalog.actionTitle(actionId, languageTag = languageTag).orEmpty())
                                        },
                                        onClick = {
                                            overflowOpen = false
                                            newPlacePrompt = promptId
                                        },
                                    )
                                }
                                HorizontalDivider()
                                DropdownMenuItem(
                                    leadingIcon = {
                                        RegistryIcon(
                                            RegistryCatalog.actionIcon(RegistryActionIds.APP_PAUSE_AGENTS),
                                            contentDescription = null,
                                        )
                                    },
                                    text = { Text(pauseAgentsTitle) },
                                    onClick = {
                                        overflowOpen = false
                                        onToggleAgentsPaused()
                                    },
                                )
                            }
                        }
                    },
                )
            },
        ) { contentPadding ->
            when (val location = state.location) {
                is TaskHomeLocation.Area -> AreasProjectsScreen(
                    graph = graph,
                    destination = AreasProjectsDestination.Area(location.id),
                    modifier = Modifier.padding(contentPadding),
                    rowMenuGroups = rowMenuGroups,
                    rowMenuAccessibilityLabel = rowMenuAccessibilityLabel,
                    onTaskAction = onTaskAction,
                    selection = selection,
                    onComplete = onComplete,
                    onOpenProject = { projectId ->
                        val project = state.projects.firstOrNull {
                            (it.location as? TaskHomeLocation.Project)?.id == projectId
                        }?.location ?: TaskHomeLocation.Project(projectId, "")
                        onSelectHomeLocation(project)
                    },
                    onOpenTask = onOpenTask,
                )
                is TaskHomeLocation.Project -> AreasProjectsScreen(
                    graph = graph,
                    destination = AreasProjectsDestination.Project(location.id),
                    modifier = Modifier.padding(contentPadding),
                    onOpenTask = onOpenTask,
                    rowMenuGroups = rowMenuGroups,
                    rowMenuAccessibilityLabel = rowMenuAccessibilityLabel,
                    onTaskAction = onTaskAction,
                    selection = selection,
                    onComplete = onComplete,
                    onClosed = { onSelectHomeLocation(TaskHomeLocation.SmartList(RegistryDestinationIds.TODAY)) },
                )
                is TaskHomeLocation.SmartList -> TaskHomeContent(
                    completeTitle = completeTitle,
                    emptyTitle = emptyTitle,
                    emptyDescription = emptyDescription,
                    inboxBandTitle = inboxTitle,
                    inboxBandIcon = RegistryCatalog.destinationIcon(RegistryDestinationIds.INBOX),
                    todayTitle = todayTitle,
                    todayTint = MaterialTheme.colorScheme.secondary,
                    hasLoaded = state.hasLoaded,
                    isToday = location.destinationId == RegistryDestinationIds.TODAY,
                    inboxTasks = if (filterStarred) state.inboxTasks.filter { it.isStarred } else state.inboxTasks,
                    tasks = if (filterStarred) state.tasks.filter { it.isStarred } else state.tasks,
                    canQuickAdd = state.canQuickAdd,
                    canComplete = state.canComplete,
                    errorMessage = state.errorMessage,
                    rowMenuGroups = rowMenuGroups,
                    rowMenuAccessibilityLabel = rowMenuAccessibilityLabel,
                    rowMenuIcon = RegistryIconIds.ACTION_MORE,
                    modifier = Modifier.padding(contentPadding),
                    selection = selection,
                    onComplete = onComplete,
                    onOpenTask = onOpenTask,
                    onTaskAction = onTaskAction,
                )
            }
        }
    }
}

private fun taskRowMenuGroups(
    menuId: String,
    destinationId: String?,
    languageTag: String,
): List<List<TaskRowMenuAction>> {
    val supportedActions = if (menuId == "task.recentlyDeleted") {
        setOf(RegistryActionIds.TASK_RESTORE)
    } else {
        setOfNotNull(
            // Android has no write that reopens a done task, so Logbook offers none.
            RegistryActionIds.TASK_TOGGLE_COMPLETE.takeIf { destinationId != RegistryDestinationIds.LOGBOOK },
            RegistryActionIds.TASK_ACCEPT_REVIEW,
            RegistryActionIds.TASK_KEEP_FADED,
            RegistryActionIds.TASK_LET_GO_FADED,
            RegistryActionIds.TASK_OPEN,
            RegistryActionIds.TASK_WHEN,
            RegistryActionIds.TASK_MOVE,
            RegistryActionIds.TASK_TAGS,
            RegistryActionIds.TASK_DEADLINE,
            RegistryActionIds.TASK_TOGGLE_STAR,
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
                icon = RegistryCatalog.actionIcon(id),
            )
        }.takeIf { it.isNotEmpty() }
    }
}

private enum class SelectionPicker { When, List }

private class TaskHomeViewModelFactory(
    private val graph: AndroidAppGraph,
) : ViewModelProvider.Factory {
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
        require(modelClass.isAssignableFrom(TaskHomeViewModel::class.java))
        @Suppress("UNCHECKED_CAST")
        return TaskHomeViewModel(graph) as T
    }
}
