package app.septena.android.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
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
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberDrawerState
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import app.septena.android.AndroidAppGraph
import app.septena.core.RegistryCatalog
import app.septena.core.generated.RegistryActionIds
import app.septena.core.generated.RegistryCapabilityIds
import app.septena.core.generated.RegistryDestinationIds
import app.septena.ui.TaskHomeContent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
@OptIn(ExperimentalMaterial3Api::class)
fun TaskHomeScreen(graph: AndroidAppGraph) {
    var openedTaskId by rememberSaveable { mutableStateOf<String?>(null) }
    var quickFindOpen by rememberSaveable { mutableStateOf(false) }
    var settingsOpen by rememberSaveable { mutableStateOf(false) }
    var inlineDraftOpen by rememberSaveable { mutableStateOf(false) }
    val factory = remember(graph) { TaskHomeViewModelFactory(graph) }
    val homeViewModel: TaskHomeViewModel = viewModel(factory = factory)
    val state by homeViewModel.state.collectAsStateWithLifecycle()
    val selectHomeLocation: (TaskHomeLocation) -> Unit = { location ->
        inlineDraftOpen = false
        homeViewModel.select(location)
    }
    val undoSnackbarHostState = remember { SnackbarHostState() }
    val languageTag = LocalConfiguration.current.locales[0].toLanguageTag()
    val wideLayout = LocalConfiguration.current.screenWidthDp >= 600
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
    val quickAddSubmitTitle = RegistryCatalog.actionAddTitle(
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
                    TaskDetailScreen(graph, openedTaskId!!, onBack = { openedTaskId = null })
                } else {
                    TaskHomeScaffold(
                        graph = graph,
                        state = state,
                        title = pageTitle,
                        sidebarActionTitle = sidebarActionTitle,
                        quickAddTitle = quickAddTitle,
                        quickAddSubmitTitle = quickAddSubmitTitle,
                        quickFindTitle = quickFindTitle,
                        pauseAgentsTitle = pauseAgentsTitle,
                        completeTitle = completeTitle,
                        emptyTitle = emptyTitle,
                        emptyDescription = emptyDescription,
                        inboxTitle = inboxTitle,
                        todayTitle = todayTitle,
                        inlineDraftOpen = inlineDraftOpen,
                        onOpenInlineDraft = { inlineDraftOpen = true },
                        showNavigationAction = false,
                        onDraftTitleChange = homeViewModel::updateDraft,
                        onQuickAdd = homeViewModel::quickAdd,
                        onComplete = homeViewModel::complete,
                        onOpenTask = { openedTaskId = it },
                        onQuickFind = { quickFindOpen = true },
                        onToggleAgentsPaused = { homeViewModel.setAgentsPaused(!state.agentsPaused) },
                        onSelectHomeLocation = selectHomeLocation,
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
                    TaskDetailScreen(graph, openedTaskId!!, onBack = { openedTaskId = null })
                } else {
                    TaskHomeScaffold(
                        graph = graph,
                        state = state,
                        title = pageTitle,
                        sidebarActionTitle = sidebarActionTitle,
                        quickAddTitle = quickAddTitle,
                        quickAddSubmitTitle = quickAddSubmitTitle,
                        quickFindTitle = quickFindTitle,
                        pauseAgentsTitle = pauseAgentsTitle,
                        completeTitle = completeTitle,
                        emptyTitle = emptyTitle,
                        emptyDescription = emptyDescription,
                        inboxTitle = inboxTitle,
                        todayTitle = todayTitle,
                        inlineDraftOpen = inlineDraftOpen,
                        onOpenInlineDraft = { inlineDraftOpen = true },
                        showNavigationAction = true,
                        onOpenNavigation = { scope.launch { drawerState.open() } },
                        onDraftTitleChange = homeViewModel::updateDraft,
                        onQuickAdd = homeViewModel::quickAdd,
                        onComplete = homeViewModel::complete,
                        onOpenTask = { openedTaskId = it },
                        onQuickFind = { quickFindOpen = true },
                        onToggleAgentsPaused = { homeViewModel.setAgentsPaused(!state.agentsPaused) },
                        onSelectHomeLocation = selectHomeLocation,
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

        if (areasTitle.isNotEmpty() || projectsTitle.isNotEmpty()) {
            HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
        }
        if (areasTitle.isNotEmpty()) {
            DrawerGroupTitle(areasTitle)
            state.areas.forEach { item ->
                NavigationDrawerItem(
                    label = { Text(item.title.orEmpty()) },
                    selected = state.location == item.location,
                    onClick = { onSelect(item.location) },
                    modifier = Modifier.padding(NavigationDrawerItemDefaults.ItemPadding),
                )
            }
        }
        if (projectsTitle.isNotEmpty()) {
            DrawerGroupTitle(projectsTitle)
            state.projects.forEach { item ->
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
    quickAddSubmitTitle: String,
    quickFindTitle: String,
    pauseAgentsTitle: String,
    completeTitle: String,
    emptyTitle: String,
    emptyDescription: String,
    inboxTitle: String,
    todayTitle: String,
    inlineDraftOpen: Boolean,
    onOpenInlineDraft: () -> Unit,
    showNavigationAction: Boolean,
    onOpenNavigation: () -> Unit = {},
    onDraftTitleChange: (String) -> Unit,
    onQuickAdd: () -> Unit,
    onComplete: (String) -> Unit,
    onOpenTask: (String) -> Unit,
    onQuickFind: () -> Unit,
    onToggleAgentsPaused: () -> Unit,
    onSelectHomeLocation: (TaskHomeLocation) -> Unit,
) {
    Scaffold(
        floatingActionButton = if (state.canQuickAdd && state.location is TaskHomeLocation.SmartList) {
            {
                FloatingActionButton(
                    onClick = onOpenInlineDraft,
                    modifier = Modifier.semantics { contentDescription = quickAddTitle },
                ) {
                    Text(
                        text = "+",
                        style = MaterialTheme.typography.headlineSmall,
                        textAlign = TextAlign.Center,
                    )
                }
            }
        } else {
            {}
        },
        topBar = {
            TopAppBar(
                title = { Text(title) },
                navigationIcon = if (showNavigationAction) {
                    {
                        TextButton(onClick = onOpenNavigation) {
                            Text(sidebarActionTitle)
                        }
                    }
                } else {
                    {}
                },
                actions = {
                    TextButton(onClick = onToggleAgentsPaused) {
                        Text(pauseAgentsTitle)
                    }
                    TextButton(onClick = onQuickFind) {
                        Text(quickFindTitle)
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
            )
            is TaskHomeLocation.SmartList -> TaskHomeContent(
                quickAddTitle = quickAddTitle,
                quickAddSubmitTitle = quickAddSubmitTitle,
                completeTitle = completeTitle,
                emptyTitle = emptyTitle,
                emptyDescription = emptyDescription,
                inboxBandTitle = inboxTitle,
                todayTitle = todayTitle,
                todayTint = MaterialTheme.colorScheme.secondary,
                hasLoaded = state.hasLoaded,
                isToday = location.destinationId == RegistryDestinationIds.TODAY,
                inboxTasks = state.inboxTasks,
                tasks = state.tasks,
                canQuickAdd = state.canQuickAdd,
                isDraftOpen = inlineDraftOpen,
                canComplete = state.canComplete,
                draftTitle = state.draftTitle,
                errorMessage = state.errorMessage,
                modifier = Modifier.padding(contentPadding),
                onDraftTitleChange = onDraftTitleChange,
                onQuickAdd = onQuickAdd,
                onComplete = onComplete,
                onOpenTask = onOpenTask,
            )
        }
    }
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
