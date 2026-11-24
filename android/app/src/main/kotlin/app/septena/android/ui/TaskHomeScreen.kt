package app.septena.android.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
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
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlin.math.cos
import kotlin.math.sin
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
import app.septena.core.generated.RegistryPlatformIds
import app.septena.core.generated.RegistrySurfaceIds
import app.septena.ui.LocalMagicPlusDrag
import app.septena.ui.MagicPlusDragState
import app.septena.ui.TaskHomeContent
import app.septena.ui.TaskRowMenuAction
import app.septena.ui.TaskSelection
import app.septena.ui.insertionPosition
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
                        settingsTitle = settingsTitle,
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
                        onOpenSettings = { settingsOpen = true },
                        onSelectHomeLocation = selectHomeLocation,
                        snackbarVisible = undoSnackbarHostState.currentSnackbarData != null,
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
                        settingsTitle = settingsTitle,
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
                        onOpenSettings = { settingsOpen = true },
                        onSelectHomeLocation = selectHomeLocation,
                        snackbarVisible = undoSnackbarHostState.currentSnackbarData != null,
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
                label = { Text(title) },
                selected = state.location == item.location,
                onClick = { onSelect(item.location) },
                modifier = Modifier.padding(NavigationDrawerItemDefaults.ItemPadding),
            )
        }

        val areaIds = state.areas.mapNotNull { (it.location as? TaskHomeLocation.Area)?.id }.toSet()
        val projectsByArea = state.projects.groupBy { it.parentAreaId }
        val standaloneProjects = state.projects.filter { it.parentAreaId == null || it.parentAreaId !in areaIds }

        if (areasTitle.isNotEmpty() || standaloneProjects.isNotEmpty()) {
            HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
        }
        if (areasTitle.isNotEmpty() && state.areas.isNotEmpty()) {
            DrawerGroupTitle(areasTitle)
            state.areas.forEach { item ->
                val area = item.location as TaskHomeLocation.Area
                AreaNavigationDrawerItem(
                    item = item,
                    selected = state.location == item.location,
                    languageTag = languageTag,
                    onSelect = { onSelect(item.location) },
                    onSetEmoji = { emoji -> onSetAreaEmoji(area.id, emoji) },
                )
                projectsByArea[area.id].orEmpty().forEach { projectItem ->
                    NavigationDrawerItem(
                        label = { Text(projectItem.title.orEmpty()) },
                        selected = state.location == projectItem.location,
                        onClick = { onSelect(projectItem.location) },
                        modifier = Modifier
                            .padding(NavigationDrawerItemDefaults.ItemPadding)
                            .padding(start = 20.dp),
                    )
                }
            }
        }
        if (projectsTitle.isNotEmpty() && standaloneProjects.isNotEmpty()) {
            DrawerGroupTitle(projectsTitle)
            standaloneProjects.forEach { item ->
                NavigationDrawerItem(
                    label = { Text(item.title.orEmpty()) },
                    selected = state.location == item.location,
                    onClick = { onSelect(item.location) },
                    modifier = Modifier.padding(NavigationDrawerItemDefaults.ItemPadding),
                )
            }
        }
        HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
        NavigationDrawerItem(
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
                IconButton(
                    onClick = { menuExpanded = true },
                    modifier = Modifier.semantics { contentDescription = changeEmojiTitle },
                ) {
                    Text("⋮", style = MaterialTheme.typography.titleLarge)
                }
                DropdownMenu(expanded = menuExpanded, onDismissRequest = { menuExpanded = false }) {
                    DropdownMenuItem(
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
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
private fun TaskHomeScaffold(
    graph: AndroidAppGraph,
    state: TaskHomeUiState,
    title: String,
    sidebarActionTitle: String,
    quickAddTitle: String,
    quickFindTitle: String,
    settingsTitle: String,
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
    onOpenSettings: () -> Unit,
    onSelectHomeLocation: (TaskHomeLocation) -> Unit,
    snackbarVisible: Boolean = false,
) {
    var quickAddDraft by remember { mutableStateOf<QuickAddDraft?>(null) }
    var newSectionTrigger by remember { mutableIntStateOf(0) }
    var selectionPicker by remember { mutableStateOf<SelectionPicker?>(null) }
    var allOnToday by remember { mutableStateOf(false) }
    val magicPlusDrag = remember { MagicPlusDragState() }
    val context = LocalContext.current
    val selecting = state.selectedIds.isNotEmpty()
    val destinationId = (state.location as? TaskHomeLocation.SmartList)?.destinationId
    val canCreateHere = state.location !is TaskHomeLocation.SmartList || state.canQuickAdd
    val imeVisible = WindowInsets.isImeVisible
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
    LaunchedEffect(state.location) { if (!magicPlusDrag.isDragging) magicPlusDrag.reset() }
    BackHandler(enabled = selecting) { homeViewModel.clearSelection() }

    val openDefaultQuickAdd: () -> Unit = {
        quickAddDraft = defaultQuickAddDraft(state.location)
    }
    magicPlusDrag.fallbackDrop = { if (canCreateHere) openDefaultQuickAdd() }

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
    CompositionLocalProvider(LocalMagicPlusDrag provides magicPlusDrag) {
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
                topBar = {
                    TopAppBar(
                        colors = TopAppBarDefaults.topAppBarColors(
                            containerColor = Color.Transparent,
                            scrolledContainerColor = Color.Transparent,
                        ),
                        title = { Text(title) },
                        navigationIcon = if (showNavigationAction) {
                            {
                                IconButton(
                                    onClick = onOpenNavigation,
                                    modifier = Modifier.semantics { contentDescription = sidebarActionTitle },
                                ) {
                                    SidebarMenuGlyph(tint = MaterialTheme.colorScheme.onSurface)
                                }
                            }
                        } else {
                            {}
                        },
                        actions = {
                            IconButton(
                                onClick = onQuickFind,
                                modifier = Modifier.semantics { contentDescription = quickFindTitle },
                            ) {
                                SearchGlyph(tint = MaterialTheme.colorScheme.onSurface)
                            }
                            IconButton(
                                onClick = onOpenSettings,
                                modifier = Modifier.semantics { contentDescription = settingsTitle },
                            ) {
                                SettingsGearGlyph(tint = MaterialTheme.colorScheme.onSurface)
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
                        onOpenProject = { projectId ->
                            val project = state.projects.firstOrNull {
                                (it.location as? TaskHomeLocation.Project)?.id == projectId
                            }?.location ?: TaskHomeLocation.Project(projectId, "")
                            onSelectHomeLocation(project)
                        },
                        onOpenTask = onOpenTask,
                        onMagicPlusDrop = { draft -> quickAddDraft = draft },
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
                        newSectionTrigger = newSectionTrigger,
                        onMagicPlusDrop = { draft -> quickAddDraft = draft },
                    )
                    is TaskHomeLocation.SmartList -> {
                        val isTodayList = location.destinationId == RegistryDestinationIds.TODAY
                        val inboxPositions = state.inboxTasks.map { it.position }
                        val taskPositions = state.tasks.map { it.position }
                        TaskHomeContent(
                            completeTitle = completeTitle,
                            emptyTitle = emptyTitle,
                            emptyDescription = emptyDescription,
                            inboxBandTitle = inboxTitle,
                            todayTitle = todayTitle,
                            todayTint = MaterialTheme.colorScheme.secondary,
                            hasLoaded = state.hasLoaded,
                            isToday = isTodayList,
                            inboxTasks = state.inboxTasks,
                            tasks = state.tasks,
                            canQuickAdd = state.canQuickAdd,
                            canComplete = state.canComplete,
                            errorMessage = state.errorMessage,
                            rowMenuGroups = rowMenuGroups,
                            rowMenuAccessibilityLabel = rowMenuAccessibilityLabel,
                            modifier = Modifier.padding(contentPadding),
                            selection = selection,
                            onComplete = onComplete,
                            onOpenTask = onOpenTask,
                            onTaskAction = onTaskAction,
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
                            onDropTaskRow = if (state.canQuickAdd) {
                                { index, before ->
                                    quickAddDraft = defaultQuickAddDraft(location).copy(
                                        position = insertionPosition(taskPositions, index, before),
                                        useTodayPosition = isTodayList,
                                    )
                                }
                            } else null,
                        )
                    }
                }
            }

            // Round Magic Plus orb (matches iPhone `MagicPlusOrb`): visible on
            // creatable smart lists, areas and projects; hides during multi-select,
            // while a snackbar is up, or when the software keyboard is showing.
            if (canCreateHere && !selecting && !snackbarVisible && !imeVisible) {
                MagicPlusOrb(
                    drag = magicPlusDrag,
                    isViewingProject = state.location is TaskHomeLocation.Project,
                    accessibilityLabel = quickAddTitle,
                    languageTag = languageTag,
                    onNewTask = openDefaultQuickAdd,
                    onNewSection = { newSectionTrigger += 1 },
                    modifier = Modifier
                        .align(Alignment.BottomEnd)
                        .padding(end = 16.dp, bottom = 16.dp),
                )
            }
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

@Composable
private fun SidebarMenuGlyph(tint: Color) {
    Canvas(modifier = Modifier.size(22.dp)) {
        val stroke = 2.dp.toPx()
        val left = 2.dp.toPx()
        val right = size.width - 2.dp.toPx()
        val ys = listOf(size.height * 0.25f, size.height * 0.50f, size.height * 0.75f)
        ys.forEach { y ->
            drawLine(tint, Offset(left, y), Offset(right, y), strokeWidth = stroke, cap = StrokeCap.Round)
        }
    }
}

@Composable
private fun SearchGlyph(tint: Color) {
    Canvas(modifier = Modifier.size(22.dp)) {
        val stroke = 2.dp.toPx()
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

@Composable
private fun SettingsGearGlyph(tint: Color) {
    Canvas(modifier = Modifier.size(22.dp)) {
        val stroke = 1.9.dp.toPx()
        val cx = size.width / 2f
        val cy = size.height / 2f
        val innerR = size.minDimension * 0.17f
        val midR = size.minDimension * 0.31f
        val outerR = size.minDimension * 0.44f
        drawCircle(tint, radius = innerR, center = Offset(cx, cy), style = Stroke(width = stroke))
        drawCircle(tint, radius = midR, center = Offset(cx, cy), style = Stroke(width = stroke))
        for (i in 0 until 8) {
            val angle = i * (Math.PI / 4.0)
            val cosA = cos(angle).toFloat()
            val sinA = sin(angle).toFloat()
            drawLine(
                tint,
                Offset(cx + cosA * midR, cy + sinA * midR),
                Offset(cx + cosA * outerR, cy + sinA * outerR),
                strokeWidth = stroke * 1.15f,
                cap = StrokeCap.Round,
            )
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
        setOf(
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
