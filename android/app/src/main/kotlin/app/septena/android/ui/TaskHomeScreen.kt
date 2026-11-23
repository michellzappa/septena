package app.septena.android.ui

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
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberDrawerState
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
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
import kotlinx.coroutines.launch

@Composable
@OptIn(ExperimentalMaterial3Api::class)
fun TaskHomeScreen(graph: AndroidAppGraph) {
    val factory = remember(graph) { TaskHomeViewModelFactory(graph) }
    val homeViewModel: TaskHomeViewModel = viewModel(factory = factory)
    val state by homeViewModel.state.collectAsStateWithLifecycle()
    val languageTag = LocalConfiguration.current.locales[0].toLanguageTag()
    val wideLayout = LocalConfiguration.current.screenWidthDp >= 600
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
    val emptyTitle = (state.location as? TaskHomeLocation.SmartList)
        ?.let { RegistryCatalog.destinationEmptyTitle(it.destinationId, languageTag) }
        .orEmpty()

    if (wideLayout) {
        PermanentNavigationDrawer(
            drawerContent = {
                PermanentDrawerSheet {
                    TaskHomeNavigation(
                        state = state,
                        languageTag = languageTag,
                        areasTitle = areasTitle,
                        projectsTitle = projectsTitle,
                        onSelect = homeViewModel::select,
                    )
                }
            },
        ) {
            TaskHomeScaffold(
                state = state,
                title = pageTitle,
                sidebarActionTitle = sidebarActionTitle,
                quickAddTitle = quickAddTitle,
                completeTitle = completeTitle,
                emptyTitle = emptyTitle,
                inboxTitle = inboxTitle,
                showNavigationAction = false,
                onDraftTitleChange = homeViewModel::updateDraft,
                onQuickAdd = homeViewModel::quickAdd,
                onComplete = homeViewModel::complete,
            )
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
                        onSelect = { location ->
                            homeViewModel.select(location)
                            scope.launch { drawerState.close() }
                        },
                    )
                }
            },
        ) {
            TaskHomeScaffold(
                state = state,
                title = pageTitle,
                sidebarActionTitle = sidebarActionTitle,
                quickAddTitle = quickAddTitle,
                completeTitle = completeTitle,
                emptyTitle = emptyTitle,
                inboxTitle = inboxTitle,
                showNavigationAction = true,
                onOpenNavigation = { scope.launch { drawerState.open() } },
                onDraftTitleChange = homeViewModel::updateDraft,
                onQuickAdd = homeViewModel::quickAdd,
                onComplete = homeViewModel::complete,
            )
        }
    }
}

@Composable
private fun TaskHomeNavigation(
    state: TaskHomeUiState,
    languageTag: String,
    areasTitle: String,
    projectsTitle: String,
    onSelect: (TaskHomeLocation) -> Unit,
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
    state: TaskHomeUiState,
    title: String,
    sidebarActionTitle: String,
    quickAddTitle: String,
    completeTitle: String,
    emptyTitle: String,
    inboxTitle: String,
    showNavigationAction: Boolean,
    onOpenNavigation: () -> Unit = {},
    onDraftTitleChange: (String) -> Unit,
    onQuickAdd: () -> Unit,
    onComplete: (String) -> Unit,
) {
    Scaffold(
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
            )
        },
    ) { contentPadding ->
        TaskHomeContent(
            quickAddTitle = quickAddTitle,
            completeTitle = completeTitle,
            emptyTitle = emptyTitle,
            inboxBandTitle = inboxTitle,
            isToday = (state.location as? TaskHomeLocation.SmartList)?.destinationId == RegistryDestinationIds.TODAY,
            inboxTasks = state.inboxTasks,
            tasks = state.tasks,
            canQuickAdd = state.canQuickAdd,
            canComplete = state.canComplete,
            draftTitle = state.draftTitle,
            errorMessage = state.errorMessage,
            modifier = Modifier.padding(contentPadding),
            onDraftTitleChange = onDraftTitleChange,
            onQuickAdd = onQuickAdd,
            onComplete = onComplete,
        )
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
