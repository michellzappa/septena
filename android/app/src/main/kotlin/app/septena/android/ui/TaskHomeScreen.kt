package app.septena.android.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
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
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
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
import app.septena.core.RegistryActionContext
import app.septena.core.RegistryActionResolver
import app.septena.core.RegistryCatalog
import app.septena.core.generated.RegistryActionIds
import app.septena.core.generated.RegistryDestinationIds
import app.septena.core.generated.RegistryNoticeIds
import app.septena.core.generated.RegistryPlatformIds
import app.septena.core.generated.RegistrySurfaceIds
import app.septena.ui.CheckmarkGlyph
import app.septena.ui.ChevronDownGlyph
import app.septena.ui.ChevronLeftGlyph
import app.septena.ui.LocalMagicPlusDrag
import app.septena.ui.LocalTaskReorderDrag
import app.septena.ui.MagicPlusDragState
import app.septena.ui.SeptenaGlyph
import app.septena.ui.SeptenaIconKind
import app.septena.ui.StarGlyph
import app.septena.ui.TaskCardMetrics
import app.septena.ui.TaskDragStackOverlay
import app.septena.ui.TaskReorderDragState
import app.septena.ui.reorderPositions
import app.septena.ui.TaskHomeContent
import app.septena.ui.TaskMenuActionIcon
import app.septena.ui.TaskRowMenuAction
import app.septena.ui.TaskSelection
import app.septena.ui.insertionPosition
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Composable
@OptIn(ExperimentalMaterial3Api::class)
fun TaskHomeScreen(graph: AndroidAppGraph) {
    var openedTaskId by rememberSaveable { mutableStateOf<String?>(null) }
    var openedTaskAttribute by rememberSaveable { mutableStateOf<String?>(null) }
    var quickFindOpen by rememberSaveable { mutableStateOf(false) }
    var settingsOpen by rememberSaveable { mutableStateOf(false) }
    // On mobile, opens on Today with the Lists Homepage one Back away (Things / iOS `SeptaskRootView`).
    var showingListsHome by rememberSaveable { mutableStateOf(false) }
    var homeQuickAddDraft by remember { mutableStateOf<QuickAddDraft?>(null) }
    val factory = remember(graph) { TaskHomeViewModelFactory(graph) }
    val homeViewModel: TaskHomeViewModel = viewModel(factory = factory)
    val state by homeViewModel.state.collectAsStateWithLifecycle()
    val selectHomeLocation: (TaskHomeLocation) -> Unit = { location ->
        homeViewModel.select(location)
        showingListsHome = false
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
        (state.location as? TaskHomeLocation.SmartList)
            ?.let { RegistryCatalog.destinationEmptyTitle(it.destinationId, languageTag) }
            .orEmpty()
    }
    val emptyDescription = if (state.starredOnly) {
        RegistryCatalog.destinationEmptyDetail(RegistryDestinationIds.STARRED, languageTag).orEmpty()
    } else {
        (state.location as? TaskHomeLocation.SmartList)
            ?.let { RegistryCatalog.destinationEmptyDetail(it.destinationId, languageTag) }
            .orEmpty()
    }
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

    val isDark = LocalSeptenaDarkTheme.current
    val appearance = LocalAppearance.current

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
        )
    }

    Box(modifier = Modifier.fillMaxSize()) {
        if (wideLayout) {
            PermanentNavigationDrawer(
                drawerContent = {
                    PermanentDrawerSheet(
                        drawerContainerColor = if (isDark) {
                            MaterialTheme.colorScheme.surfaceContainerLow
                        } else {
                            MaterialTheme.colorScheme.surfaceContainer
                        },
                    ) {
                        ListsHomeContent(
                            state = state,
                            languageTag = languageTag,
                            settingsTitle = settingsTitle,
                            isDark = isDark,
                            hasActiveTexture = appearance.hasActiveTexture,
                            highlightSelection = true,
                            showSettingsRow = true,
                            onSelect = selectHomeLocation,
                            onSetAreaEmoji = homeViewModel::setAreaEmoji,
                            onOpenSettings = { settingsOpen = true },
                            modifier = Modifier.padding(top = 8.dp),
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
                        onOpenTask = { openTaskWithAttribute(it, null) },
                        onTaskAction = onTaskAction,
                        onToggleStarFilter = homeViewModel::toggleStarFilter,
                        onQuickFind = { quickFindOpen = true },
                        onOpenSettings = { settingsOpen = true },
                        onSelectHomeLocation = selectHomeLocation,
                        snackbarVisible = undoSnackbarHostState.currentSnackbarData != null,
                    )
                }
            }
        } else {
            // Mobile phone layout: Things / iOS root Lists Homepage (no hamburger drawer).
            // Back gesture from any list returns to the Lists Homepage.
            BackHandler(
                enabled = !showingListsHome && !settingsOpen && !quickFindOpen && openedTaskId == null && state.selectedIds.isEmpty(),
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
                    onBack = { openedTaskId = null; openedTaskAttribute = null },
                    initialAttribute = openedTaskAttribute,
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
                    onNewTask = { draft -> homeQuickAddDraft = draft },
                    onCreateArea = { title ->
                        homeViewModel.createArea(title) { created -> selectHomeLocation(created) }
                    },
                    onCreateProject = { title ->
                        homeViewModel.createProject(title) { created -> selectHomeLocation(created) }
                    },
                )
            } else {
                TaskHomeScaffold(
                    graph = graph,
                    state = state,
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
                    onOpenNavigation = { showingListsHome = true },
                    onComplete = homeViewModel::complete,
                    rowMenuGroups = rowMenuGroups,
                    rowMenuAccessibilityLabel = rowMenuAccessibilityLabel,
                    onOpenTask = { openTaskWithAttribute(it, null) },
                    onTaskAction = onTaskAction,
                    onToggleStarFilter = homeViewModel::toggleStarFilter,
                    onQuickFind = { quickFindOpen = true },
                    onOpenSettings = { settingsOpen = true },
                    onSelectHomeLocation = selectHomeLocation,
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
                .padding(horizontal = 16.dp, vertical = 16.dp),
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
) {
    var menuExpanded by remember { mutableStateOf(false) }
    val todayTint = MaterialTheme.colorScheme.secondary
    val mutedIcon = MaterialTheme.colorScheme.onSurfaceVariant
    val currentAreaEmoji = (state.location as? TaskHomeLocation.Area)?.let { area ->
        state.areas.firstOrNull { (it.location as? TaskHomeLocation.Area)?.id == area.id }?.emoji
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
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(TaskCardMetrics.IconTextGap),
            modifier = Modifier
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

            // Bottom smart lists (identical to iOS `TaskNavMenu` `.bottom`: Logbook, Faded, Deleted, etc.).
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
    onComplete: (String) -> Unit,
    onOpenTask: (String) -> Unit,
    onTaskAction: (String, String) -> Unit,
    onToggleStarFilter: () -> Unit,
    onQuickFind: () -> Unit,
    onOpenSettings: () -> Unit,
    onSelectHomeLocation: (TaskHomeLocation) -> Unit,
    snackbarVisible: Boolean = false,
) {
    var quickAddDraft by remember { mutableStateOf<QuickAddDraft?>(null) }
    var newSectionTrigger by remember { mutableIntStateOf(0) }
    var selectionPicker by remember { mutableStateOf<SelectionPicker?>(null) }
    var allOnToday by remember { mutableStateOf(false) }
    var activeSweepItems by remember { mutableStateOf<List<FadeSweepItem>?>(null) }
    val magicPlusDrag = remember { MagicPlusDragState() }
    val reorderDrag = remember { TaskReorderDragState() }
    val context = LocalContext.current
    val isDark = LocalSeptenaDarkTheme.current
    val appearance = LocalAppearance.current
    val selecting = state.selectedIds.isNotEmpty()
    val destinationId = (state.location as? TaskHomeLocation.SmartList)?.destinationId
    val canCreateHere = state.location !is TaskHomeLocation.SmartList || state.canQuickAdd
    val showStarFilterButton = destinationId != RegistryDestinationIds.STARRED &&
        destinationId != RegistryDestinationIds.RECENTLY_DELETED
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
    LaunchedEffect(state.location) {
        if (!magicPlusDrag.isDragging) magicPlusDrag.reset()
        if (!reorderDrag.isDragging) reorderDrag.reset()
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

    val sectionHeader: @Composable () -> Unit = {
        SectionTitleDropdownHeader(
            state = state,
            title = title,
            languageTag = languageTag,
            settingsTitle = settingsTitle,
            onSelectLocation = onSelectHomeLocation,
            onOpenSettings = onOpenSettings,
        )
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
        } else if (destinationId == RegistryDestinationIds.FADED && state.fadedSweepItems.isNotEmpty()) {
            val notice = remember(languageTag) {
                registryNoticeCopy(RegistryNoticeIds.FADED_PILE, languageTag)
            }
            val bannerMessage = listOf(notice.title, notice.detail).filter(String::isNotBlank).joinToString(" · ")
            FadeSweepBannerCard(
                message = bannerMessage,
                reviewLabel = notice.primaryTitle,
                dismissLabel = null,
                isDark = isDark,
                hasActiveTexture = appearance.hasActiveTexture,
                onReview = { activeSweepItems = state.fadedSweepItems },
                modifier = Modifier.padding(bottom = 10.dp),
            )
        }
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
                when (val location = state.location) {
                    is TaskHomeLocation.Area -> AreasProjectsScreen(
                        graph = graph,
                        destination = AreasProjectsDestination.Area(location.id),
                        modifier = Modifier.padding(contentPadding),
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
                        onOpenTask = onOpenTask,
                        onMagicPlusDrop = { draft -> quickAddDraft = draft },
                    )
                    is TaskHomeLocation.Project -> AreasProjectsScreen(
                        graph = graph,
                        destination = AreasProjectsDestination.Project(location.id),
                        modifier = Modifier.padding(contentPadding),
                        starredOnly = state.starredOnly,
                        completeTitle = completeTitle,
                        todayTitle = todayTitle,
                        fadedTitle = fadedTitle,
                        headerContent = sectionHeader,
                        onComplete = onComplete,
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
                        val canReorderList = location.destinationId in setOf(
                            RegistryDestinationIds.TODAY,
                            RegistryDestinationIds.INBOX,
                            RegistryDestinationIds.ANYTIME,
                            RegistryDestinationIds.STARRED,
                        )
                        val inboxPositions = state.inboxTasks.map { it.position }
                        val taskPositions = state.tasks.map { it.position }
                        TaskHomeContent(
                            completeTitle = completeTitle,
                            emptyTitle = emptyTitle,
                            emptyDescription = emptyDescription,
                            inboxBandTitle = inboxTitle,
                            todayTitle = todayTitle,
                            todayTint = MaterialTheme.colorScheme.secondary,
                            fadedTitle = fadedTitle,
                            showFadedIndicator = location.destinationId != RegistryDestinationIds.FADED,
                            isDarkTheme = isDark,
                            hasActiveTexture = appearance.hasActiveTexture,
                            headerContent = sectionHeader,
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
                            onDropTaskRow = if (state.canQuickAdd) {
                                { index, before ->
                                    quickAddDraft = defaultQuickAddDraft(location).copy(
                                        position = insertionPosition(taskPositions, index, before),
                                        useTodayPosition = isTodayList,
                                    )
                                }
                            } else null,
                            canReorder = canReorderList,
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
                                    val targetGroup = state.tasks.getOrNull(index)?.group?.targetLocationKey
                                    val newPositions = reorderPositions(taskPositions, index, before, ids.size)
                                    homeViewModel.reorderTasks(
                                        ids = ids,
                                        positions = newPositions,
                                        useTodayPosition = isTodayList,
                                        targetGroupKey = targetGroup,
                                    )
                                }
                            } else null,
                            onReorderGroupHeader = if (canReorderList) {
                                { ids, targetLocationKey ->
                                    val firstInGroupPos = state.tasks
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
                            } else null,
                        )
                    }
                }
            }

            // Round Magic Plus orb (matches iPhone `MagicPlusOrb`): visible on
            // creatable smart lists, areas and projects; hides during multi-select,
            // while a snackbar is up, or when the software keyboard is showing.
            if (canCreateHere && !selecting && !snackbarVisible && !imeVisible && !reorderDrag.isDragging) {
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
                icon = actionMenuIcon(id),
            )
        }.takeIf { it.isNotEmpty() }
    }
}

private fun actionMenuIcon(actionId: String): TaskMenuActionIcon = when (actionId) {
    RegistryActionIds.TASK_WHEN -> TaskMenuActionIcon.When
    RegistryActionIds.TASK_MOVE -> TaskMenuActionIcon.Move
    RegistryActionIds.TASK_TAGS -> TaskMenuActionIcon.Tags
    RegistryActionIds.TASK_DEADLINE -> TaskMenuActionIcon.Deadline
    RegistryActionIds.TASK_TOGGLE_STAR -> TaskMenuActionIcon.Star
    RegistryActionIds.TASK_OPEN -> TaskMenuActionIcon.Open
    RegistryActionIds.TASK_DUPLICATE -> TaskMenuActionIcon.Duplicate
    RegistryActionIds.TASK_SHARE -> TaskMenuActionIcon.Share
    RegistryActionIds.TASK_SELECT -> TaskMenuActionIcon.Select
    RegistryActionIds.TASK_DELETE -> TaskMenuActionIcon.Delete
    RegistryActionIds.TASK_RESTORE -> TaskMenuActionIcon.Restore
    RegistryActionIds.TASK_ACCEPT_REVIEW,
    RegistryActionIds.TASK_KEEP_FADED -> TaskMenuActionIcon.Check
    RegistryActionIds.TASK_LET_GO_FADED -> TaskMenuActionIcon.Cancel
    else -> TaskMenuActionIcon.None
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
