package app.septena.android.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import app.septena.core.JsonValue
import app.septena.core.RegistryActionContext
import app.septena.core.RegistryActionResolver
import app.septena.core.RegistryCatalog
import app.septena.core.generated.RegistryActionIds
import app.septena.core.generated.RegistryDestinationIds
import app.septena.core.generated.RegistryPlatformIds
import app.septena.core.generated.RegistryPromptIds
import app.septena.core.stringValue
import app.septena.ui.AreaDotGlyph
import app.septena.ui.CheckmarkGlyph
import app.septena.ui.ChevronRightGlyph
import app.septena.ui.LocalMagicPlusDrag
import app.septena.ui.MagicPlusDragState
import app.septena.ui.MagicPlusInsertEdge
import app.septena.ui.ProjectProgressRingGlyph
import app.septena.ui.SELECTION_WASH_ALPHA
import app.septena.ui.SeptenaGlyph
import app.septena.ui.SeptenaIconKind
import app.septena.ui.TaskCardMetrics
import app.septena.ui.TaskCardPosition
import app.septena.ui.TaskCardSlice
import app.septena.ui.cardPosition
import app.septena.ui.rememberMagicPlusListInsert
import kotlinx.coroutines.launch

private val SIDEBAR_ROW_HEIGHT = 42.dp
private val TILE_GUTTER = 10.dp
private val PROJECT_LINE_INSET = 28.dp
private const val AREA_CARD_GAP_DP = 14f

internal sealed interface HomeMagicDraft {
    data class Area(val index: Int) : HomeMagicDraft
    data class Project(val areaId: String?, val index: Int) : HomeMagicDraft
}

/**
 * Full-screen mobile homepage (Things / iOS `SidebarRootView` root screen):
 * - Top bar with Search + Settings (no hamburger drawer on phone).
 * - 2-column grid of half-width smart-list pills with icons and bold counts.
 * - Compact grouped glass-ish cards for standalone projects, each Area with its
 *   collapsible nested projects, and bottom smart lists with counts.
 * - Floating circular Magic Plus orb: tap opens New Project / New Area / Join Shared;
 *   drag drops an inline New Area (at area level) or New Project (inside an area or loose).
 */
@Composable
@OptIn(ExperimentalMaterial3Api::class)
internal fun ListsHomePage(
    state: TaskHomeUiState,
    languageTag: String,
    quickFindTitle: String,
    settingsTitle: String,
    quickAddTitle: String,
    onSelectLocation: (TaskHomeLocation) -> Unit,
    onSetAreaEmoji: (String, String?) -> Unit,
    onQuickFind: () -> Unit,
    onOpenSettings: () -> Unit,
    onCreateArea: (String, Int?) -> Unit,
    onCreateProject: (String, String?, Int?) -> Unit,
    onMoveProjectToArea: (String, String?) -> Unit = { _, _ -> },
    onRenameArea: (String, String) -> Unit = { _, _ -> },
    onRenameProject: (String, String) -> Unit = { _, _ -> },
    onDeleteArea: (String) -> Unit = {},
    onDeleteProject: (String) -> Unit = {},
    onReorderAreas: (List<String>) -> Unit = {},
    onReorderProjects: (List<String>) -> Unit = {},
    onJoinShared: () -> Unit,
    onShareProject: (String) -> Unit,
    onRefresh: (suspend () -> Unit)? = null,
) {
    val isDark = LocalSeptenaDarkTheme.current
    val appearance = LocalAppearance.current
    val canvasBackground = if (isDark) {
        MaterialTheme.colorScheme.background
    } else {
        MaterialTheme.colorScheme.surfaceContainerLow
    }
    var createMenuOpen by remember { mutableStateOf(false) }
    var newAreaDialogOpen by remember { mutableStateOf(false) }
    var newProjectInitialAreaId by remember { mutableStateOf<String?>(null) }
    var newProjectDialogOpen by remember { mutableStateOf(false) }
    var magicDraft by remember { mutableStateOf<HomeMagicDraft?>(null) }
    val pullScope = rememberCoroutineScope()
    var isPullRefreshing by remember { mutableStateOf(false) }
    val magicPlusDrag = remember { MagicPlusDragState() }
    magicPlusDrag.fallbackDrop = { magicDraft = HomeMagicDraft.Area(state.areas.size) }

    val areaOptions = remember(state.areas) {
        state.areas.mapNotNull { item ->
            val area = item.location as? TaskHomeLocation.Area ?: return@mapNotNull null
            PlaceAreaOption(id = area.id, title = item.title.orEmpty(), emoji = item.emoji)
        }
    }
    val newProjectTitle = RegistryCatalog.actionTitle(RegistryActionIds.SIDEBAR_NEW_PROJECT, languageTag = languageTag)
        .orEmpty()
    val joinSharedTitle = RegistryCatalog.actionTitle(RegistryActionIds.SIDEBAR_JOIN_SHARED, languageTag = languageTag)
        .orEmpty()
    val newAreaTitle = RegistryCatalog.actionTitle(RegistryActionIds.SIDEBAR_NEW_AREA, languageTag = languageTag)
        .orEmpty()

    CompositionLocalProvider(LocalMagicPlusDrag provides magicPlusDrag) {
        Box(modifier = Modifier.fillMaxSize().background(canvasBackground)) {
            HeaderWashBackdrop()
            Scaffold(
                containerColor = Color.Transparent,
                topBar = {
                    TopAppBar(
                        colors = TopAppBarDefaults.topAppBarColors(
                            containerColor = Color.Transparent,
                            scrolledContainerColor = Color.Transparent,
                        ),
                        title = {},
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
                                SeptenaGlyph(
                                    kind = SeptenaIconKind.Settings,
                                    tint = MaterialTheme.colorScheme.onSurface,
                                    size = 21.dp,
                                )
                            }
                        },
                    )
                },
            ) { contentPadding ->
                PullToRefreshBox(
                    isRefreshing = isPullRefreshing,
                    onRefresh = {
                        val refresh = onRefresh ?: return@PullToRefreshBox
                        if (!isPullRefreshing) {
                            isPullRefreshing = true
                            pullScope.launch {
                                try {
                                    refresh()
                                } finally {
                                    isPullRefreshing = false
                                }
                            }
                        }
                    },
                    modifier = Modifier.fillMaxSize().padding(contentPadding),
                ) {
                    ListsHomeContent(
                        state = state,
                        languageTag = languageTag,
                        settingsTitle = settingsTitle,
                        isDark = isDark,
                        hasActiveTexture = appearance.hasActiveTexture,
                        highlightSelection = false,
                        showSettingsRow = false,
                        magicDraft = magicDraft,
                        onOpenMagicDraft = { magicDraft = it },
                        onCommitMagicDraft = { draft, name ->
                            magicDraft = null
                            when (draft) {
                                is HomeMagicDraft.Area -> onCreateArea(name, draft.index)
                                is HomeMagicDraft.Project -> onCreateProject(name, draft.areaId, draft.index)
                            }
                        },
                        onCancelMagicDraft = { magicDraft = null },
                        onSelect = onSelectLocation,
                        onSetAreaEmoji = onSetAreaEmoji,
                        onNewProjectInArea = { areaId ->
                            newProjectInitialAreaId = areaId
                            newProjectDialogOpen = true
                        },
                        onMoveProjectToArea = onMoveProjectToArea,
                        onRenameArea = onRenameArea,
                        onRenameProject = onRenameProject,
                        onDeleteArea = onDeleteArea,
                        onDeleteProject = onDeleteProject,
                        onReorderAreas = onReorderAreas,
                        onReorderProjects = onReorderProjects,
                        onOpenSettings = onOpenSettings,
                        onShareProject = onShareProject,
                        onJoinShared = onJoinShared,
                        modifier = Modifier.fillMaxSize(),
                    )
                }
            }

            if (magicDraft == null) {
                Box(
                    modifier = Modifier
                        .align(Alignment.BottomEnd)
                        .navigationBarsPadding()
                        .padding(end = 16.dp, bottom = 16.dp),
                ) {
                    MagicPlusOrb(
                        drag = magicPlusDrag,
                        isViewingProject = false,
                        accessibilityLabel = quickAddTitle,
                        languageTag = languageTag,
                        onNewTask = { createMenuOpen = true },
                        onNewSection = {},
                    )
                    DropdownMenu(
                        expanded = createMenuOpen,
                        onDismissRequest = { createMenuOpen = false },
                    ) {
                        if (newProjectTitle.isNotEmpty()) {
                            DropdownMenuItem(
                                text = { Text(newProjectTitle) },
                                onClick = {
                                    createMenuOpen = false
                                    newProjectInitialAreaId = null
                                    newProjectDialogOpen = true
                                },
                            )
                        }
                        if (newAreaTitle.isNotEmpty()) {
                            DropdownMenuItem(
                                text = { Text(newAreaTitle) },
                                onClick = {
                                    createMenuOpen = false
                                    newAreaDialogOpen = true
                                },
                            )
                        }
                        if (joinSharedTitle.isNotEmpty()) {
                            DropdownMenuItem(
                                text = { Text(joinSharedTitle) },
                                onClick = {
                                    createMenuOpen = false
                                    onJoinShared()
                                },
                            )
                        }
                    }
                }
            }
        }
    }

    if (newAreaDialogOpen) {
        HomeNameEntryDialog(
            promptId = RegistryPromptIds.NEW_AREA,
            languageTag = languageTag,
            onDismiss = { newAreaDialogOpen = false },
            onConfirm = { name ->
                newAreaDialogOpen = false
                onCreateArea(name, null)
            },
        )
    }

    if (newProjectDialogOpen) {
        NewProjectDialog(
            areas = areaOptions,
            initialAreaId = newProjectInitialAreaId,
            languageTag = languageTag,
            onDismiss = { newProjectDialogOpen = false },
            onConfirm = { name, areaId ->
                newProjectDialogOpen = false
                onCreateProject(name, areaId, null)
            },
        )
    }
}

/**
 * Tablet permanent sidebar hosting `ListsHomeContent` together with its own
 * draggable Magic Plus orb (mirroring iPad's `sidebarSplit`).
 */
@Composable
internal fun TabletSidebarPane(
    state: TaskHomeUiState,
    languageTag: String,
    settingsTitle: String,
    quickAddTitle: String,
    isDark: Boolean,
    hasActiveTexture: Boolean,
    onSelect: (TaskHomeLocation) -> Unit,
    onSetAreaEmoji: (String, String?) -> Unit,
    onOpenSettings: () -> Unit,
    onCreateArea: (String, Int?) -> Unit,
    onCreateProject: (String, String?, Int?) -> Unit,
    onMoveProjectToArea: (String, String?) -> Unit,
    onRenameArea: (String, String) -> Unit,
    onRenameProject: (String, String) -> Unit,
    onDeleteArea: (String) -> Unit,
    onDeleteProject: (String) -> Unit,
    onReorderAreas: (List<String>) -> Unit,
    onReorderProjects: (List<String>) -> Unit,
    onShareProject: (String) -> Unit,
    onJoinShared: () -> Unit,
) {
    val magicPlusDrag = remember { MagicPlusDragState() }
    var magicDraft by remember { mutableStateOf<HomeMagicDraft?>(null) }
    var createMenuOpen by remember { mutableStateOf(false) }
    var newAreaDialogOpen by remember { mutableStateOf(false) }
    var newProjectInitialAreaId by remember { mutableStateOf<String?>(null) }
    var newProjectDialogOpen by remember { mutableStateOf(false) }

    magicPlusDrag.fallbackDrop = { magicDraft = HomeMagicDraft.Area(state.areas.size) }

    val activeAreaId = remember(state.location, state.projects) {
        when (val loc = state.location) {
            is TaskHomeLocation.Area -> loc.id
            is TaskHomeLocation.Project -> state.projects.firstOrNull {
                (it.location as? TaskHomeLocation.Project)?.id == loc.id
            }?.parentAreaId
            else -> null
        }
    }
    val areaOptions = remember(state.areas) {
        state.areas.mapNotNull { item ->
            val area = item.location as? TaskHomeLocation.Area ?: return@mapNotNull null
            PlaceAreaOption(id = area.id, title = item.title.orEmpty(), emoji = item.emoji)
        }
    }
    val newProjectTitle = RegistryCatalog.actionTitle(RegistryActionIds.SIDEBAR_NEW_PROJECT, languageTag = languageTag).orEmpty()
    val newAreaTitle = RegistryCatalog.actionTitle(RegistryActionIds.SIDEBAR_NEW_AREA, languageTag = languageTag).orEmpty()
    val joinSharedTitle = RegistryCatalog.actionTitle(RegistryActionIds.SIDEBAR_JOIN_SHARED, languageTag = languageTag).orEmpty()

    CompositionLocalProvider(LocalMagicPlusDrag provides magicPlusDrag) {
        Box(modifier = Modifier.fillMaxSize().padding(top = 8.dp)) {
            ListsHomeContent(
                state = state,
                languageTag = languageTag,
                settingsTitle = settingsTitle,
                isDark = isDark,
                hasActiveTexture = hasActiveTexture,
                highlightSelection = true,
                showSettingsRow = true,
                magicDraft = magicDraft,
                onOpenMagicDraft = { magicDraft = it },
                onCommitMagicDraft = { draft, name ->
                    magicDraft = null
                    when (draft) {
                        is HomeMagicDraft.Area -> onCreateArea(name, draft.index)
                        is HomeMagicDraft.Project -> onCreateProject(name, draft.areaId, draft.index)
                    }
                },
                onCancelMagicDraft = { magicDraft = null },
                onSelect = onSelect,
                onSetAreaEmoji = onSetAreaEmoji,
                onNewProjectInArea = { areaId ->
                    newProjectInitialAreaId = areaId
                    newProjectDialogOpen = true
                },
                onMoveProjectToArea = onMoveProjectToArea,
                onRenameArea = onRenameArea,
                onRenameProject = onRenameProject,
                onDeleteArea = onDeleteArea,
                onDeleteProject = onDeleteProject,
                onReorderAreas = onReorderAreas,
                onReorderProjects = onReorderProjects,
                onOpenSettings = onOpenSettings,
                onShareProject = onShareProject,
                onJoinShared = onJoinShared,
                modifier = Modifier.fillMaxSize(),
            )

            if (magicDraft == null) {
                Box(
                    modifier = Modifier
                        .align(Alignment.BottomEnd)
                        .navigationBarsPadding()
                        .padding(end = 14.dp, bottom = 14.dp),
                ) {
                    MagicPlusOrb(
                        drag = magicPlusDrag,
                        isViewingProject = false,
                        accessibilityLabel = quickAddTitle,
                        languageTag = languageTag,
                        onNewTask = { createMenuOpen = true },
                        onNewSection = {},
                    )
                    DropdownMenu(
                        expanded = createMenuOpen,
                        onDismissRequest = { createMenuOpen = false },
                    ) {
                        if (newProjectTitle.isNotEmpty()) {
                            DropdownMenuItem(
                                text = { Text(newProjectTitle) },
                                onClick = {
                                    createMenuOpen = false
                                    newProjectInitialAreaId = activeAreaId
                                    newProjectDialogOpen = true
                                },
                            )
                        }
                        if (newAreaTitle.isNotEmpty()) {
                            DropdownMenuItem(
                                text = { Text(newAreaTitle) },
                                onClick = {
                                    createMenuOpen = false
                                    newAreaDialogOpen = true
                                },
                            )
                        }
                        if (joinSharedTitle.isNotEmpty()) {
                            DropdownMenuItem(
                                text = { Text(joinSharedTitle) },
                                onClick = {
                                    createMenuOpen = false
                                    onJoinShared()
                                },
                            )
                        }
                    }
                }
            }
        }
    }

    if (newAreaDialogOpen) {
        HomeNameEntryDialog(
            promptId = RegistryPromptIds.NEW_AREA,
            languageTag = languageTag,
            onDismiss = { newAreaDialogOpen = false },
            onConfirm = { name ->
                newAreaDialogOpen = false
                onCreateArea(name, null)
            },
        )
    }

    if (newProjectDialogOpen) {
        NewProjectDialog(
            areas = areaOptions,
            initialAreaId = newProjectInitialAreaId,
            languageTag = languageTag,
            onDismiss = { newProjectDialogOpen = false },
            onConfirm = { name, areaId ->
                newProjectDialogOpen = false
                onCreateProject(name, areaId, null)
            },
        )
    }
}

/**
 * Shared iOS-matched Lists home / sidebar body (used on mobile homepage AND
 * tablet permanent sidebar): 2-column top smart-list pills with bold counts,
 * then compact 42dp grouped glass cards for projects, areas (with collapsible
 * nested projects), and bottom smart lists.
 */
@Composable
internal fun ListsHomeContent(
    state: TaskHomeUiState,
    languageTag: String,
    settingsTitle: String,
    isDark: Boolean,
    hasActiveTexture: Boolean,
    highlightSelection: Boolean,
    showSettingsRow: Boolean,
    onSelect: (TaskHomeLocation) -> Unit,
    onSetAreaEmoji: (String, String?) -> Unit,
    onOpenSettings: () -> Unit,
    onShareProject: (String) -> Unit,
    onJoinShared: () -> Unit,
    magicDraft: HomeMagicDraft? = null,
    onOpenMagicDraft: ((HomeMagicDraft) -> Unit)? = null,
    onCommitMagicDraft: ((HomeMagicDraft, String) -> Unit)? = null,
    onCancelMagicDraft: (() -> Unit)? = null,
    onNewProjectInArea: ((String) -> Unit)? = null,
    onMoveProjectToArea: ((String, String?) -> Unit)? = null,
    onRenameArea: ((String, String) -> Unit)? = null,
    onRenameProject: ((String, String) -> Unit)? = null,
    onDeleteArea: ((String) -> Unit)? = null,
    onDeleteProject: ((String) -> Unit)? = null,
    onReorderAreas: ((List<String>) -> Unit)? = null,
    onReorderProjects: ((List<String>) -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val todayTint = MaterialTheme.colorScheme.secondary
    val mutedIcon = MaterialTheme.colorScheme.onSurfaceVariant
    var collapsedAreaIds by rememberSaveable { mutableStateOf(emptySet<String>()) }
    var emojiTargetArea by remember { mutableStateOf<Pair<String, String?>?>(null) }
    var moveTargetProject by remember { mutableStateOf<Pair<String, String?>?>(null) }
    var renameTarget by remember { mutableStateOf<Triple<Boolean, String, String>?>(null) }

    val areaIds = remember(state.areas) {
        state.areas.mapNotNull { (it.location as? TaskHomeLocation.Area)?.id }.toSet()
    }
    val orderedAreaIds = remember(state.areas) {
        state.areas.mapNotNull { (it.location as? TaskHomeLocation.Area)?.id }
    }
    val areaOptions = remember(state.areas) {
        state.areas.mapNotNull { item ->
            val area = item.location as? TaskHomeLocation.Area ?: return@mapNotNull null
            PlaceAreaOption(id = area.id, title = item.title.orEmpty(), emoji = item.emoji)
        }
    }
    val projectsByArea = remember(state.projects) {
        state.projects.groupBy { it.parentAreaId }
    }
    val standaloneProjects = remember(state.projects, areaIds) {
        state.projects.filter { it.parentAreaId == null || it.parentAreaId !in areaIds }
    }
    val topTilePairs = remember(state.topSmartLists) {
        state.topSmartLists.chunked(2)
    }
    val changeEmojiAvailable = remember {
        val menuActions = RegistryCatalog.menuActionIds("sidebar.area")
        RegistryActionIds.AREA_CHANGE_EMOJI in menuActions &&
            RegistryActionResolver.isAvailable(
                RegistryActionIds.AREA_CHANGE_EMOJI,
                RegistryActionContext(RegistryPlatformIds.ANDROID, null, selectedCount = 1),
            )
    }
    val newAreaLabel = remember(languageTag) {
        RegistryCatalog.actionTitle(RegistryActionIds.SIDEBAR_NEW_AREA, languageTag = languageTag).orEmpty()
    }
    val newProjectLabel = remember(languageTag) {
        RegistryCatalog.actionTitle(RegistryActionIds.SIDEBAR_NEW_PROJECT, languageTag = languageTag).orEmpty()
    }
    val changeEmojiTitle = remember(languageTag) {
        RegistryCatalog.actionTitle(RegistryActionIds.AREA_CHANGE_EMOJI, languageTag = languageTag).orEmpty()
    }
    val magicEnabled = onOpenMagicDraft != null
    val hasAreas = state.areas.isNotEmpty()

    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(top = 4.dp, bottom = 96.dp),
    ) {
        // 1. 2-column grid of half-width smart-list pills (iOS `smartListGrid`).
        if (topTilePairs.isNotEmpty()) {
            item(key = "smart-list-pills") {
                Column(
                    verticalArrangement = Arrangement.spacedBy(TILE_GUTTER),
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = TaskCardMetrics.Margin)
                        .padding(bottom = TaskCardMetrics.GroupGap),
                ) {
                    topTilePairs.forEach { pair ->
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(TILE_GUTTER),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            pair.forEach { item ->
                                val loc = item.location as TaskHomeLocation.SmartList
                                val title = RegistryCatalog.destinationTitle(loc.destinationId, languageTag).orEmpty()
                                val kind = destinationIconKind(loc.destinationId)
                                val iconTint = if (loc.destinationId == RegistryDestinationIds.TODAY) todayTint else mutedIcon
                                SmartListPillTile(
                                    iconKind = kind,
                                    iconTint = iconTint,
                                    title = title,
                                    count = item.count,
                                    isSelected = highlightSelection && state.location == loc,
                                    isDark = isDark,
                                    hasActiveTexture = hasActiveTexture,
                                    onClick = { onSelect(loc) },
                                    modifier = Modifier.weight(1f),
                                )
                            }
                            if (pair.size == 1) {
                                Spacer(modifier = Modifier.weight(1f))
                            }
                        }
                    }
                }
            }
        }

        // 2. Standalone top-level projects card (if any, or while drafting a loose project).
        val looseDraft = (magicDraft as? HomeMagicDraft.Project)?.takeIf { it.areaId == null }
        val looseCount = standaloneProjects.size + if (looseDraft != null) 1 else 0
        if (looseCount > 0) {
            val looseIds = standaloneProjects.mapNotNull { (it.location as? TaskHomeLocation.Project)?.id }
            val draftSlotIdx = looseDraft?.index?.coerceIn(0, standaloneProjects.size)
            val totalRows = looseCount
            for (slotIdx in 0 until totalRows) {
                if (draftSlotIdx != null && slotIdx == draftSlotIdx) {
                    item(key = "magic-draft-loose") {
                        HomeMagicDraftRow(
                            isArea = false,
                            position = cardPosition(slotIdx, totalRows),
                            languageTag = languageTag,
                            isDark = isDark,
                            hasActiveTexture = hasActiveTexture,
                            onCommit = { name -> onCommitMagicDraft?.invoke(looseDraft, name) },
                            onCancel = { onCancelMagicDraft?.invoke() },
                        )
                    }
                } else {
                    val itemIdx = if (draftSlotIdx != null && slotIdx > draftSlotIdx) slotIdx - 1 else slotIdx
                    val item = standaloneProjects[itemIdx]
                    val proj = item.location as TaskHomeLocation.Project
                    val isLastOverall = !hasAreas && itemIdx == standaloneProjects.lastIndex && magicDraft == null
                    item(key = "loose-project:${proj.id}") {
                        val (topMod, topTargeted) = rememberMagicPlusListInsert(
                            id = "mp-home-loose-top",
                            edge = MagicPlusInsertEdge.Top,
                            isArea = false,
                            label = newProjectLabel,
                            enabled = magicEnabled && itemIdx == 0,
                            onDrop = { onOpenMagicDraft?.invoke(HomeMagicDraft.Project(null, 0)) },
                        )
                        val (bottomMod, bottomTargeted) = rememberMagicPlusListInsert(
                            id = "mp-home-proj-${proj.id}",
                            edge = MagicPlusInsertEdge.Bottom,
                            isArea = false,
                            label = newProjectLabel,
                            enabled = magicEnabled,
                            onDrop = { onOpenMagicDraft?.invoke(HomeMagicDraft.Project(null, itemIdx + 1)) },
                        )
                        val (tailMod, tailTargeted) = rememberMagicPlusListInsert(
                            id = "mp-home-area-end",
                            edge = MagicPlusInsertEdge.BelowGap(AREA_CARD_GAP_DP),
                            isArea = true,
                            label = newAreaLabel,
                            enabled = magicEnabled && isLastOverall,
                            onDrop = { onOpenMagicDraft?.invoke(HomeMagicDraft.Area(state.areas.size)) },
                        )
                        Box(
                            modifier = Modifier
                                .zIndex(if (topTargeted || bottomTargeted || tailTargeted) 10f else 0f)
                                .then(topMod)
                                .then(bottomMod)
                                .then(tailMod),
                        ) {
                            CompactSidebarProjectRow(
                                item = item,
                                position = cardPosition(slotIdx, totalRows),
                                isSelected = highlightSelection && state.location == item.location,
                                isDark = isDark,
                                hasActiveTexture = hasActiveTexture,
                                canMoveUp = onReorderProjects != null && itemIdx > 0,
                                canMoveDown = onReorderProjects != null && itemIdx < standaloneProjects.lastIndex,
                                onClick = { onSelect(item.location) },
                                onRename = { renameTarget = Triple(false, proj.id, item.title.orEmpty()) },
                                onMoveToArea = { moveTargetProject = proj.id to null },
                                onMoveUp = {
                                    val reordered = looseIds.toMutableList()
                                    val moved = reordered.removeAt(itemIdx)
                                    reordered.add(itemIdx - 1, moved)
                                    onReorderProjects?.invoke(reordered)
                                },
                                onMoveDown = {
                                    val reordered = looseIds.toMutableList()
                                    val moved = reordered.removeAt(itemIdx)
                                    reordered.add(itemIdx + 1, moved)
                                    onReorderProjects?.invoke(reordered)
                                },
                                onShare = { onShareProject(proj.id) },
                                onDelete = if (item.share == null && onDeleteProject != null) {
                                    { onDeleteProject(proj.id) }
                                } else {
                                    null
                                },
                                languageTag = languageTag,
                            )
                            if (topTargeted) {
                                MagicPlusInsertBar(
                                    isArea = false,
                                    label = newProjectLabel,
                                    lineInset = PROJECT_LINE_INSET,
                                    modifier = Modifier.align(Alignment.TopStart),
                                )
                            }
                            if (bottomTargeted) {
                                MagicPlusInsertBar(
                                    isArea = false,
                                    label = newProjectLabel,
                                    lineInset = PROJECT_LINE_INSET,
                                    modifier = Modifier.align(Alignment.BottomStart),
                                )
                            }
                            if (tailTargeted) {
                                MagicPlusInsertBar(
                                    isArea = true,
                                    label = newAreaLabel,
                                    lineInset = 0.dp,
                                    modifier = Modifier.align(Alignment.BottomStart).offset(y = (AREA_CARD_GAP_DP / 2f).dp),
                                )
                            }
                        }
                    }
                }
            }
        }

        // 3. One grouped card per Area (area header row + collapsible active projects underneath),
        //    with inline Magic Plus Area draft spliced at its exact index.
        val areaDraft = magicDraft as? HomeMagicDraft.Area
        val areaDraftSlot = areaDraft?.index?.coerceIn(0, state.areas.size)
        val totalAreaSlots = state.areas.size + if (areaDraft != null) 1 else 0
        for (slotIdx in 0 until totalAreaSlots) {
            if (areaDraftSlot != null && slotIdx == areaDraftSlot) {
                item(key = "magic-draft-area") {
                    HomeMagicDraftRow(
                        isArea = true,
                        position = TaskCardPosition.Solo,
                        languageTag = languageTag,
                        isDark = isDark,
                        hasActiveTexture = hasActiveTexture,
                        onCommit = { name -> onCommitMagicDraft?.invoke(areaDraft, name) },
                        onCancel = { onCancelMagicDraft?.invoke() },
                    )
                }
                continue
            }
            val areaIndex = if (areaDraftSlot != null && slotIdx > areaDraftSlot) slotIdx - 1 else slotIdx
            val areaItem = state.areas[areaIndex]
            val area = areaItem.location as? TaskHomeLocation.Area ?: continue
            val areaTitle = areaItem.title.orEmpty()
            val projectInAreaLabel = "$newProjectLabel in $areaTitle"
            val childProjects = projectsByArea[area.id].orEmpty()
            val childIds = childProjects.mapNotNull { (it.location as? TaskHomeLocation.Project)?.id }
            val collapsed = area.id in collapsedAreaIds
            val visibleChildren = if (collapsed) emptyList() else childProjects
            val areaProjDraft = (magicDraft as? HomeMagicDraft.Project)?.takeIf { it.areaId == area.id }
            val draftChildIdx = areaProjDraft?.index?.coerceIn(0, visibleChildren.size)
            val visibleChildSlots = visibleChildren.size + if (areaProjDraft != null) 1 else 0
            val cardRowCount = 1 + visibleChildSlots
            val isLastArea = areaIndex == state.areas.lastIndex && areaDraftSlot != state.areas.size

            item(key = "area:${area.id}") {
                val (topMod, topTargeted) = rememberMagicPlusListInsert(
                    id = "mp-home-area-top-${area.id}",
                    edge = MagicPlusInsertEdge.Top,
                    isArea = true,
                    label = newAreaLabel,
                    enabled = magicEnabled,
                    onDrop = { onOpenMagicDraft?.invoke(HomeMagicDraft.Area(areaIndex)) },
                )
                val (bottomMod, bottomTargeted) = rememberMagicPlusListInsert(
                    id = "mp-home-area-${area.id}",
                    edge = MagicPlusInsertEdge.Bottom,
                    isArea = false,
                    label = projectInAreaLabel,
                    enabled = magicEnabled,
                    onDrop = {
                        collapsedAreaIds = collapsedAreaIds - area.id
                        onOpenMagicDraft?.invoke(HomeMagicDraft.Project(area.id, 0))
                    },
                )
                val (tailMod, tailTargeted) = rememberMagicPlusListInsert(
                    id = "mp-home-area-end",
                    edge = MagicPlusInsertEdge.BelowGap(AREA_CARD_GAP_DP),
                    isArea = true,
                    label = newAreaLabel,
                    enabled = magicEnabled && isLastArea && visibleChildSlots == 0,
                    onDrop = { onOpenMagicDraft?.invoke(HomeMagicDraft.Area(state.areas.size)) },
                )
                Box(
                    modifier = Modifier
                        .zIndex(if (topTargeted || bottomTargeted || tailTargeted) 10f else 0f)
                        .then(topMod)
                        .then(bottomMod)
                        .then(tailMod),
                ) {
                    CompactSidebarAreaRow(
                        item = areaItem,
                        position = cardPosition(0, cardRowCount),
                        isSelected = highlightSelection && state.location == area,
                        isDark = isDark,
                        hasActiveTexture = hasActiveTexture,
                        hasProjects = childProjects.isNotEmpty(),
                        collapsed = collapsed,
                        canChangeEmoji = changeEmojiAvailable,
                        changeEmojiTitle = changeEmojiTitle,
                        canMoveUp = onReorderAreas != null && areaIndex > 0,
                        canMoveDown = onReorderAreas != null && areaIndex < state.areas.lastIndex,
                        languageTag = languageTag,
                        onClick = { onSelect(area) },
                        onToggleCollapse = {
                            collapsedAreaIds = if (collapsed) collapsedAreaIds - area.id else collapsedAreaIds + area.id
                        },
                        onNewProjectHere = onNewProjectInArea?.let { fn -> { fn(area.id) } },
                        onRename = { renameTarget = Triple(true, area.id, areaTitle) },
                        onOpenEmojiPicker = { emojiTargetArea = area.id to areaItem.emoji },
                        onMoveUp = {
                            val reordered = orderedAreaIds.toMutableList()
                            val moved = reordered.removeAt(areaIndex)
                            reordered.add(areaIndex - 1, moved)
                            onReorderAreas?.invoke(reordered)
                        },
                        onMoveDown = {
                            val reordered = orderedAreaIds.toMutableList()
                            val moved = reordered.removeAt(areaIndex)
                            reordered.add(areaIndex + 1, moved)
                            onReorderAreas?.invoke(reordered)
                        },
                        onDelete = onDeleteArea?.let { fn -> { fn(area.id) } },
                    )
                    if (topTargeted) {
                        MagicPlusInsertBar(
                            isArea = true,
                            label = newAreaLabel,
                            lineInset = 0.dp,
                            modifier = Modifier.align(Alignment.TopStart).offset(y = (-AREA_CARD_GAP_DP / 2f).dp),
                        )
                    }
                    if (bottomTargeted) {
                        MagicPlusInsertBar(
                            isArea = false,
                            label = projectInAreaLabel,
                            lineInset = PROJECT_LINE_INSET,
                            modifier = Modifier.align(Alignment.BottomStart),
                        )
                    }
                    if (tailTargeted) {
                        MagicPlusInsertBar(
                            isArea = true,
                            label = newAreaLabel,
                            lineInset = 0.dp,
                            modifier = Modifier.align(Alignment.BottomStart).offset(y = (AREA_CARD_GAP_DP / 2f).dp),
                        )
                    }
                }
            }

            for (childSlot in 0 until visibleChildSlots) {
                if (draftChildIdx != null && childSlot == draftChildIdx) {
                    item(key = "magic-draft-proj:${area.id}") {
                        HomeMagicDraftRow(
                            isArea = false,
                            position = cardPosition(childSlot + 1, cardRowCount),
                            languageTag = languageTag,
                            isDark = isDark,
                            hasActiveTexture = hasActiveTexture,
                            onCommit = { name -> onCommitMagicDraft?.invoke(areaProjDraft, name) },
                            onCancel = { onCancelMagicDraft?.invoke() },
                        )
                    }
                } else {
                    val childIdx = if (draftChildIdx != null && childSlot > draftChildIdx) childSlot - 1 else childSlot
                    val projectItem = visibleChildren[childIdx]
                    val proj = projectItem.location as TaskHomeLocation.Project
                    val isLastRowInLastCard = isLastArea && childSlot == visibleChildSlots - 1
                    item(key = "area-project:${proj.id}") {
                        val (bottomMod, bottomTargeted) = rememberMagicPlusListInsert(
                            id = "mp-home-proj-${proj.id}",
                            edge = MagicPlusInsertEdge.Bottom,
                            isArea = false,
                            label = projectInAreaLabel,
                            enabled = magicEnabled,
                            onDrop = { onOpenMagicDraft?.invoke(HomeMagicDraft.Project(area.id, childIdx + 1)) },
                        )
                        val (tailMod, tailTargeted) = rememberMagicPlusListInsert(
                            id = "mp-home-area-end",
                            edge = MagicPlusInsertEdge.BelowGap(AREA_CARD_GAP_DP),
                            isArea = true,
                            label = newAreaLabel,
                            enabled = magicEnabled && isLastRowInLastCard,
                            onDrop = { onOpenMagicDraft?.invoke(HomeMagicDraft.Area(state.areas.size)) },
                        )
                        Box(
                            modifier = Modifier
                                .zIndex(if (bottomTargeted || tailTargeted) 10f else 0f)
                                .then(bottomMod)
                                .then(tailMod),
                        ) {
                            CompactSidebarProjectRow(
                                item = projectItem,
                                position = cardPosition(childSlot + 1, cardRowCount),
                                isSelected = highlightSelection && state.location == projectItem.location,
                                isDark = isDark,
                                hasActiveTexture = hasActiveTexture,
                                canMoveUp = onReorderProjects != null && childIdx > 0,
                                canMoveDown = onReorderProjects != null && childIdx < childProjects.lastIndex,
                                onClick = { onSelect(projectItem.location) },
                                onRename = { renameTarget = Triple(false, proj.id, projectItem.title.orEmpty()) },
                                onMoveToArea = { moveTargetProject = proj.id to area.id },
                                onMoveUp = {
                                    val reordered = childIds.toMutableList()
                                    val moved = reordered.removeAt(childIdx)
                                    reordered.add(childIdx - 1, moved)
                                    onReorderProjects?.invoke(reordered)
                                },
                                onMoveDown = {
                                    val reordered = childIds.toMutableList()
                                    val moved = reordered.removeAt(childIdx)
                                    reordered.add(childIdx + 1, moved)
                                    onReorderProjects?.invoke(reordered)
                                },
                                onShare = { onShareProject(proj.id) },
                                onDelete = if (projectItem.share == null && onDeleteProject != null) {
                                    { onDeleteProject(proj.id) }
                                } else {
                                    null
                                },
                                languageTag = languageTag,
                            )
                            if (bottomTargeted) {
                                MagicPlusInsertBar(
                                    isArea = false,
                                    label = projectInAreaLabel,
                                    lineInset = PROJECT_LINE_INSET,
                                    modifier = Modifier.align(Alignment.BottomStart),
                                )
                            }
                            if (tailTargeted) {
                                MagicPlusInsertBar(
                                    isArea = true,
                                    label = newAreaLabel,
                                    lineInset = 0.dp,
                                    modifier = Modifier.align(Alignment.BottomStart).offset(y = (AREA_CARD_GAP_DP / 2f).dp),
                                )
                            }
                        }
                    }
                }
            }
        }

        // 4. Bottom smart lists card (Logbook, etc. — exact iOS `.bottom`).
        if (state.bottomSmartLists.isNotEmpty()) {
            itemsIndexed(
                state.bottomSmartLists,
                key = { _, it -> "bottom-smart:${(it.location as TaskHomeLocation.SmartList).destinationId}" },
            ) { index, item ->
                val loc = item.location as TaskHomeLocation.SmartList
                val title = RegistryCatalog.destinationTitle(loc.destinationId, languageTag).orEmpty()
                val kind = destinationIconKind(loc.destinationId)
                val iconTint = if (loc.destinationId == RegistryDestinationIds.TODAY) todayTint else mutedIcon
                CompactSidebarSmartRow(
                    iconKind = kind,
                    iconTint = iconTint,
                    title = title,
                    count = item.count,
                    position = cardPosition(index, state.bottomSmartLists.size),
                    isSelected = highlightSelection && state.location == loc,
                    isDark = isDark,
                    hasActiveTexture = hasActiveTexture,
                    onClick = { onSelect(loc) },
                    // Bottom smart lists always draw the title in secondary ink
                    // (docs/DesignSpec.md, "Sidebar ink").
                    titleColor = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        // 5. Settings row on permanent tablet sidebar (mobile has Settings gear in the top bar).
        if (showSettingsRow) {
            item(key = "sidebar-join-shared") {
                CompactSidebarSmartRow(
                    iconKind = SeptenaIconKind.People,
                    iconTint = mutedIcon,
                    title = RegistryCatalog.actionTitle(RegistryActionIds.SIDEBAR_JOIN_SHARED, languageTag = languageTag).orEmpty(),
                    count = null,
                    position = TaskCardPosition.Top,
                    isSelected = false,
                    isDark = isDark,
                    hasActiveTexture = hasActiveTexture,
                    onClick = onJoinShared,
                )
            }
            item(key = "sidebar-settings") {
                CompactSidebarSmartRow(
                    iconKind = SeptenaIconKind.Settings,
                    iconTint = mutedIcon,
                    title = settingsTitle,
                    count = null,
                    position = TaskCardPosition.Bottom,
                    isSelected = false,
                    isDark = isDark,
                    hasActiveTexture = hasActiveTexture,
                    onClick = onOpenSettings,
                )
            }
        }
    }

    emojiTargetArea?.let { (areaId, currentEmoji) ->
        AreaEmojiPickerSheet(
            initialEmoji = currentEmoji,
            languageTag = languageTag,
            onDismissRequest = { emojiTargetArea = null },
            onSelect = { emoji -> onSetAreaEmoji(areaId, emoji) },
        )
    }

    moveTargetProject?.let { (projectId, currentAreaId) ->
        MoveProjectToAreaDialog(
            areas = areaOptions,
            currentAreaId = currentAreaId,
            languageTag = languageTag,
            onDismiss = { moveTargetProject = null },
            onPick = { targetAreaId ->
                moveTargetProject = null
                if (targetAreaId != currentAreaId) {
                    onMoveProjectToArea?.invoke(projectId, targetAreaId)
                }
            },
        )
    }

    renameTarget?.let { (isArea, id, currentTitle) ->
        HomeNameEntryDialog(
            promptId = if (isArea) RegistryPromptIds.RENAME_AREA else RegistryPromptIds.RENAME_PROJECT,
            languageTag = languageTag,
            initialValue = currentTitle,
            onDismiss = { renameTarget = null },
            onConfirm = { newName ->
                renameTarget = null
                if (isArea) onRenameArea?.invoke(id, newName) else onRenameProject?.invoke(id, newName)
            },
        )
    }
}

/**
 * Self-explanatory insertion bar + pill label drawn over a homepage/sidebar edge while
 * dragging Magic Plus, telling the user live whether releasing here creates an Area or a
 * Project (and inside which Area).
 */
@Composable
private fun MagicPlusInsertBar(
    isArea: Boolean,
    label: String,
    lineInset: Dp,
    modifier: Modifier = Modifier,
) {
    val colors = LocalMagicPlusColors.current
    val fill = if (colors.fill != Color.Unspecified) colors.fill else MaterialTheme.colorScheme.primary
    val ink = if (colors.ink != Color.Unspecified) colors.ink else MaterialTheme.colorScheme.onPrimary
    Box(
        contentAlignment = Alignment.CenterStart,
        modifier = modifier
            .fillMaxWidth()
            .padding(
                start = TaskCardMetrics.Margin + lineInset,
                end = TaskCardMetrics.Margin,
            ),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(4.dp)
                .clip(CircleShape)
                .background(fill),
        )
        if (label.isNotBlank()) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(5.dp),
                modifier = Modifier
                    .clip(CircleShape)
                    .background(fill)
                    .padding(horizontal = 8.dp, vertical = 2.5.dp),
            ) {
                Box(
                    modifier = Modifier
                        .size(if (isArea) 5.5.dp else 7.dp)
                        .clip(CircleShape)
                        .then(
                            if (isArea) Modifier.background(ink)
                            else Modifier.border(1.5.dp, ink, CircleShape),
                        ),
                )
                Text(
                    text = label,
                    fontSize = 11.sp,
                    lineHeight = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = ink,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

/** Inline draft row opened directly in the dropped homepage/sidebar slot. */
@Composable
private fun HomeMagicDraftRow(
    isArea: Boolean,
    position: TaskCardPosition,
    languageTag: String,
    isDark: Boolean,
    hasActiveTexture: Boolean,
    onCommit: (String) -> Unit,
    onCancel: () -> Unit,
) {
    val promptId = if (isArea) RegistryPromptIds.NEW_AREA else RegistryPromptIds.NEW_PROJECT
    val placeholder = remember(promptId, languageTag) {
        val raw = RegistryCatalog.surface(promptId)?.fields?.get("placeholder").stringValue().orEmpty()
        RegistryCatalog.localizedString(raw, languageTag) ?: raw
    }
    var title by remember { mutableStateOf("") }
    val focusRequester = remember { FocusRequester() }
    LaunchedEffect(Unit) { focusRequester.requestFocus() }

    val submit: () -> Unit = {
        val trimmed = title.trim()
        if (trimmed.isNotEmpty()) onCommit(trimmed) else onCancel()
    }

    TaskCardSlice(
        position = position,
        isSelected = false,
        isDark = isDark,
        hasActiveTexture = hasActiveTexture,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = SIDEBAR_ROW_HEIGHT)
                .padding(horizontal = TaskCardMetrics.ContentInset, vertical = 6.dp),
        ) {
            Box(contentAlignment = Alignment.Center, modifier = Modifier.width(24.dp)) {
                if (isArea) {
                    AreaDotGlyph(
                        tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.55f),
                        size = 18.dp,
                    )
                } else {
                    ProjectProgressRingGlyph(
                        progress = 0f,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.78f),
                        size = 17.dp,
                    )
                }
            }
            Box(modifier = Modifier.weight(1f)) {
                if (title.isEmpty()) {
                    Text(
                        text = placeholder,
                        fontSize = if (isArea) 16.sp else 15.5.sp,
                        fontWeight = if (isArea) FontWeight.SemiBold else FontWeight.Normal,
                        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.65f),
                        maxLines = 1,
                    )
                }
                BasicTextField(
                    value = title,
                    onValueChange = { title = it },
                    singleLine = true,
                    textStyle = TextStyle(
                        fontSize = if (isArea) 16.sp else 15.5.sp,
                        lineHeight = 20.sp,
                        fontWeight = if (isArea) FontWeight.SemiBold else FontWeight.Normal,
                        color = MaterialTheme.colorScheme.onSurface,
                    ),
                    cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { submit() }),
                    modifier = Modifier
                        .fillMaxWidth()
                        .focusRequester(focusRequester),
                )
            }
            if (title.isNotBlank()) {
                TextButton(onClick = submit) {
                    Text(
                        text = RegistryCatalog.surface(promptId)?.fields?.get("confirmTitle").stringValue()
                            ?.let { RegistryCatalog.localizedString(it, languageTag) ?: it }
                            .orEmpty(),
                    )
                }
            } else {
                TextButton(onClick = onCancel) {
                    Text(
                        text = (RegistryCatalog.document("surfaces").fields["prompts"] as? JsonValue.ObjectValue)
                            ?.fields?.get("cancelTitle").stringValue()
                            ?.let { RegistryCatalog.localizedString(it, languageTag) ?: it }
                            .orEmpty(),
                    )
                }
            }
        }
    }
}

/**
 * Half-width smart-list pill tile matching iOS `SmartListTile`:
 * icon top-left, big bold tabular count top-right, title bottom-left.
 */
@Composable
private fun SmartListPillTile(
    iconKind: SeptenaIconKind,
    iconTint: Color,
    title: String,
    count: Int?,
    isSelected: Boolean,
    isDark: Boolean,
    hasActiveTexture: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val shape = RoundedCornerShape(TaskCardMetrics.Radius)
    val fill = when {
        isSelected -> MaterialTheme.colorScheme.primary.copy(alpha = SELECTION_WASH_ALPHA)
        isDark -> MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = if (hasActiveTexture) 0.74f else 0.88f)
        else -> Color.White.copy(alpha = if (hasActiveTexture) 0.78f else 0.92f)
    }
    val rim = when {
        isSelected -> MaterialTheme.colorScheme.primary.copy(alpha = 0.28f)
        isDark -> Color.White.copy(alpha = if (hasActiveTexture) 0.10f else 0.07f)
        hasActiveTexture -> Color.White.copy(alpha = 0.65f)
        else -> MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.36f)
    }

    Column(
        verticalArrangement = Arrangement.SpaceBetween,
        modifier = modifier
            .heightIn(min = 76.dp)
            .clip(shape)
            .background(fill, shape)
            .border(0.65.dp, rim, shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
    ) {
        Row(
            verticalAlignment = Alignment.Top,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Box(
                contentAlignment = Alignment.CenterStart,
                modifier = Modifier.size(26.dp),
            ) {
                SeptenaGlyph(kind = iconKind, tint = iconTint, size = 21.dp)
            }
            Spacer(modifier = Modifier.weight(1f))
            if (count != null) {
                Text(
                    text = count.toString(),
                    style = TextStyle(
                        fontSize = 24.sp,
                        lineHeight = 26.sp,
                        fontWeight = FontWeight.Bold,
                        fontFeatureSettings = "tnum",
                    ),
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                )
            }
        }
        Spacer(modifier = Modifier.height(6.dp))
        Text(
            text = title,
            fontSize = 15.sp,
            lineHeight = 18.sp,
            fontWeight = FontWeight.Normal,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun CompactSidebarAreaRow(
    item: TaskHomeNavigationItem,
    position: TaskCardPosition,
    isSelected: Boolean,
    isDark: Boolean,
    hasActiveTexture: Boolean,
    hasProjects: Boolean,
    collapsed: Boolean,
    canChangeEmoji: Boolean,
    changeEmojiTitle: String,
    canMoveUp: Boolean,
    canMoveDown: Boolean,
    languageTag: String,
    onClick: () -> Unit,
    onToggleCollapse: () -> Unit,
    onNewProjectHere: (() -> Unit)?,
    onRename: () -> Unit,
    onOpenEmojiPicker: () -> Unit,
    onMoveUp: () -> Unit,
    onMoveDown: () -> Unit,
    onDelete: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    var menuExpanded by remember { mutableStateOf(false) }

    TaskCardSlice(
        position = position,
        isSelected = isSelected,
        isDark = isDark,
        hasActiveTexture = hasActiveTexture,
        modifier = modifier,
    ) {
        Box {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = SIDEBAR_ROW_HEIGHT)
                    .combinedClickable(
                        onClick = onClick,
                        onLongClick = { menuExpanded = true },
                    )
                    .padding(horizontal = TaskCardMetrics.ContentInset, vertical = 6.dp),
            ) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier.width(24.dp),
                ) {
                    if (item.emoji != null) {
                        Text(text = item.emoji, fontSize = 17.sp, lineHeight = 20.sp)
                    } else {
                        AreaDotGlyph(
                            tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.55f),
                            size = 18.dp,
                        )
                    }
                }
                Text(
                    text = item.title.orEmpty(),
                    fontSize = 16.sp,
                    lineHeight = 20.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                if (hasProjects) {
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier
                            .size(28.dp)
                            .clip(CircleShape)
                            .clickable(onClick = onToggleCollapse),
                    ) {
                        ChevronRightGlyph(
                            tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.55f),
                            size = 12.dp,
                            modifier = Modifier.rotate(if (collapsed) 0f else 90f),
                        )
                    }
                }
                SidebarCountText(item.count)
            }

            DropdownMenu(
                expanded = menuExpanded,
                onDismissRequest = { menuExpanded = false },
            ) {
                if (onNewProjectHere != null) {
                    DropdownMenuItem(
                        text = {
                            Text(RegistryCatalog.actionTitle(RegistryActionIds.AREA_NEW_PROJECT, languageTag = languageTag).orEmpty())
                        },
                        onClick = {
                            menuExpanded = false
                            onNewProjectHere()
                        },
                    )
                }
                DropdownMenuItem(
                    text = {
                        Text(RegistryCatalog.actionTitle(RegistryActionIds.AREA_RENAME, languageTag = languageTag).orEmpty())
                    },
                    onClick = {
                        menuExpanded = false
                        onRename()
                    },
                )
                if (canChangeEmoji) {
                    DropdownMenuItem(
                        text = { Text(changeEmojiTitle) },
                        onClick = {
                            menuExpanded = false
                            onOpenEmojiPicker()
                        },
                    )
                }
                if (canMoveUp) {
                    DropdownMenuItem(
                        text = {
                            Text(RegistryCatalog.actionTitle(RegistryActionIds.AREA_MOVE_UP, languageTag = languageTag).orEmpty())
                        },
                        onClick = {
                            menuExpanded = false
                            onMoveUp()
                        },
                    )
                }
                if (canMoveDown) {
                    DropdownMenuItem(
                        text = {
                            Text(RegistryCatalog.actionTitle(RegistryActionIds.AREA_MOVE_DOWN, languageTag = languageTag).orEmpty())
                        },
                        onClick = {
                            menuExpanded = false
                            onMoveDown()
                        },
                    )
                }
                if (onDelete != null) {
                    HorizontalDivider()
                    DropdownMenuItem(
                        text = {
                            Text(
                                text = RegistryCatalog.actionTitle(RegistryActionIds.AREA_DELETE, languageTag = languageTag).orEmpty(),
                                color = MaterialTheme.colorScheme.error,
                            )
                        },
                        onClick = {
                            menuExpanded = false
                            onDelete()
                        },
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun CompactSidebarProjectRow(
    item: TaskHomeNavigationItem,
    position: TaskCardPosition,
    isSelected: Boolean,
    isDark: Boolean,
    hasActiveTexture: Boolean,
    canMoveUp: Boolean,
    canMoveDown: Boolean,
    onClick: () -> Unit,
    onRename: () -> Unit,
    onMoveToArea: () -> Unit,
    onMoveUp: () -> Unit,
    onMoveDown: () -> Unit,
    onShare: () -> Unit,
    onDelete: (() -> Unit)?,
    languageTag: String,
    modifier: Modifier = Modifier,
) {
    var menuExpanded by remember { mutableStateOf(false) }

    TaskCardSlice(
        position = position,
        isSelected = isSelected,
        isDark = isDark,
        hasActiveTexture = hasActiveTexture,
        modifier = modifier,
    ) {
        Box {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = SIDEBAR_ROW_HEIGHT)
                    .combinedClickable(onClick = onClick, onLongClick = { menuExpanded = true })
                    .padding(horizontal = TaskCardMetrics.ContentInset, vertical = 6.dp),
            ) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier.width(24.dp),
                ) {
                    ProjectProgressRingGlyph(
                        progress = item.progress,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.78f),
                        size = 17.dp,
                    )
                }
                Text(
                    text = item.title.orEmpty(),
                    fontSize = 15.5.sp,
                    lineHeight = 20.sp,
                    fontWeight = FontWeight.Normal,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                item.share?.let {
                    SharedProjectMark(it, languageTag, tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f))
                }
                SidebarCountText(item.count)
            }
            DropdownMenu(expanded = menuExpanded, onDismissRequest = { menuExpanded = false }) {
                DropdownMenuItem(
                    text = {
                        Text(RegistryCatalog.actionTitle(RegistryActionIds.PROJECT_RENAME, languageTag = languageTag).orEmpty())
                    },
                    onClick = {
                        menuExpanded = false
                        onRename()
                    },
                )
                DropdownMenuItem(
                    text = {
                        Text(RegistryCatalog.submenuTitle("sidebar.project", "moveToArea", languageTag).orEmpty())
                    },
                    onClick = {
                        menuExpanded = false
                        onMoveToArea()
                    },
                )
                if (canMoveUp) {
                    DropdownMenuItem(
                        text = {
                            Text(RegistryCatalog.actionTitle(RegistryActionIds.PROJECT_MOVE_UP, languageTag = languageTag).orEmpty())
                        },
                        onClick = {
                            menuExpanded = false
                            onMoveUp()
                        },
                    )
                }
                if (canMoveDown) {
                    DropdownMenuItem(
                        text = {
                            Text(RegistryCatalog.actionTitle(RegistryActionIds.PROJECT_MOVE_DOWN, languageTag = languageTag).orEmpty())
                        },
                        onClick = {
                            menuExpanded = false
                            onMoveDown()
                        },
                    )
                }
                DropdownMenuItem(
                    text = { Text(RegistryCatalog.actionTitle(RegistryActionIds.PROJECT_SHARE, languageTag = languageTag).orEmpty()) },
                    onClick = {
                        menuExpanded = false
                        onShare()
                    },
                )
                if (onDelete != null) {
                    HorizontalDivider()
                    DropdownMenuItem(
                        text = {
                            Text(
                                text = RegistryCatalog.actionTitle(RegistryActionIds.PROJECT_DELETE, languageTag = languageTag).orEmpty(),
                                color = MaterialTheme.colorScheme.error,
                            )
                        },
                        onClick = {
                            menuExpanded = false
                            onDelete()
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun CompactSidebarSmartRow(
    iconKind: SeptenaIconKind,
    iconTint: Color,
    title: String,
    count: Int?,
    position: TaskCardPosition,
    isSelected: Boolean,
    isDark: Boolean,
    hasActiveTexture: Boolean,
    onClick: () -> Unit,
    titleColor: Color = MaterialTheme.colorScheme.onSurface,
) {
    TaskCardSlice(
        position = position,
        isSelected = isSelected,
        isDark = isDark,
        hasActiveTexture = hasActiveTexture,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = SIDEBAR_ROW_HEIGHT)
                .clickable(onClick = onClick)
                .padding(horizontal = TaskCardMetrics.ContentInset, vertical = 6.dp),
        ) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier.width(24.dp),
            ) {
                SeptenaGlyph(kind = iconKind, tint = iconTint, size = 18.dp)
            }
            Text(
                text = title,
                fontSize = 16.sp,
                lineHeight = 20.sp,
                fontWeight = FontWeight.Normal,
                color = titleColor,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            SidebarCountText(count)
        }
    }
}

@Composable
private fun SidebarCountText(count: Int?) {
    if (count == null || count <= 0) return
    Text(
        text = count.toString(),
        style = TextStyle(
            fontSize = 14.sp,
            lineHeight = 18.sp,
            fontFeatureSettings = "tnum",
        ),
        color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.72f),
        maxLines = 1,
    )
}

@Composable
private fun HomeNameEntryDialog(
    promptId: String,
    languageTag: String,
    initialValue: String = "",
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    val promptFields = remember(promptId) { RegistryCatalog.surface(promptId)?.fields.orEmpty() }
    val promptsDoc = remember { RegistryCatalog.document("surfaces").fields["prompts"] as? JsonValue.ObjectValue }
    fun loc(raw: String?): String = raw?.let { RegistryCatalog.localizedString(it, languageTag) ?: it }.orEmpty()
    val title = remember(promptFields, languageTag) { loc(promptFields["title"].stringValue()) }
    val placeholder = remember(promptFields, languageTag) { loc(promptFields["placeholder"].stringValue()) }
    val confirmTitle = remember(promptFields, languageTag) { loc(promptFields["confirmTitle"].stringValue()) }
    val cancelTitle = remember(promptsDoc, languageTag) { loc(promptsDoc?.fields?.get("cancelTitle").stringValue()) }
    var value by remember(promptId, initialValue) { mutableStateOf(initialValue) }
    val focusRequester = remember { FocusRequester() }
    LaunchedEffect(Unit) { focusRequester.requestFocus() }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            OutlinedTextField(
                value = value,
                onValueChange = { value = it },
                label = { Text(placeholder) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { if (value.isNotBlank()) onConfirm(value) }),
                modifier = Modifier.focusRequester(focusRequester),
            )
        },
        confirmButton = {
            TextButton(enabled = value.isNotBlank(), onClick = { onConfirm(value) }) {
                Text(confirmTitle)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(cancelTitle) }
        },
    )
}

/**
 * New Project dialog with auto-focused title and a pre-selected Area picker
 * matching iOS `NewProjectSheet`.
 */
@Composable
private fun NewProjectDialog(
    areas: List<PlaceAreaOption>,
    initialAreaId: String?,
    languageTag: String,
    onDismiss: () -> Unit,
    onConfirm: (String, String?) -> Unit,
) {
    val promptId = RegistryPromptIds.NEW_PROJECT
    val promptFields = remember { RegistryCatalog.surface(promptId)?.fields.orEmpty() }
    val promptsDoc = remember { RegistryCatalog.document("surfaces").fields["prompts"] as? JsonValue.ObjectValue }
    fun loc(raw: String?): String = raw?.let { RegistryCatalog.localizedString(it, languageTag) ?: it }.orEmpty()
    val title = remember(promptFields, languageTag) { loc(promptFields["title"].stringValue()) }
    val placeholder = remember(promptFields, languageTag) { loc(promptFields["placeholder"].stringValue()) }
    val confirmTitle = remember(promptFields, languageTag) { loc(promptFields["confirmTitle"].stringValue()) }
    val cancelTitle = remember(promptsDoc, languageTag) { loc(promptsDoc?.fields?.get("cancelTitle").stringValue()) }

    var name by remember { mutableStateOf("") }
    var selectedAreaId by remember(initialAreaId) { mutableStateOf(initialAreaId) }
    val focusRequester = remember { FocusRequester() }
    LaunchedEffect(Unit) { focusRequester.requestFocus() }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(
                verticalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.verticalScroll(rememberScrollState()),
            ) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text(placeholder) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { if (name.isNotBlank()) onConfirm(name, selectedAreaId) }),
                    modifier = Modifier.fillMaxWidth().focusRequester(focusRequester),
                )
                if (areas.isNotEmpty()) {
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        AreaPickerOptionRow(
                            title = RegistryCatalog.localizedString("No Area", languageTag) ?: "No Area",
                            emoji = null,
                            isNone = true,
                            selected = selectedAreaId == null,
                            onClick = { selectedAreaId = null },
                        )
                        areas.forEach { area ->
                            AreaPickerOptionRow(
                                title = area.title,
                                emoji = area.emoji,
                                isNone = false,
                                selected = selectedAreaId == area.id,
                                onClick = { selectedAreaId = area.id },
                            )
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(enabled = name.isNotBlank(), onClick = { onConfirm(name, selectedAreaId) }) {
                Text(confirmTitle)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(cancelTitle) }
        },
    )
}

/**
 * Move Project to Area picker shared by the homepage/sidebar and Project detail,
 * with the project's current Area unmistakably pre-selected.
 */
@Composable
internal fun MoveProjectToAreaDialog(
    areas: List<PlaceAreaOption>,
    currentAreaId: String?,
    languageTag: String,
    onDismiss: () -> Unit,
    onPick: (String?) -> Unit,
) {
    val promptsDoc = remember { RegistryCatalog.document("surfaces").fields["prompts"] as? JsonValue.ObjectValue }
    val cancelTitle = remember(promptsDoc, languageTag) {
        promptsDoc?.fields?.get("cancelTitle").stringValue()
            ?.let { RegistryCatalog.localizedString(it, languageTag) ?: it }
            .orEmpty()
    }
    val title = remember(languageTag) {
        RegistryCatalog.submenuTitle("sidebar.project", "moveToArea", languageTag).orEmpty()
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(
                verticalArrangement = Arrangement.spacedBy(2.dp),
                modifier = Modifier.verticalScroll(rememberScrollState()),
            ) {
                AreaPickerOptionRow(
                    title = RegistryCatalog.localizedString("No Area", languageTag) ?: "No Area",
                    emoji = null,
                    isNone = true,
                    selected = currentAreaId == null,
                    onClick = { onPick(null) },
                )
                areas.forEach { area ->
                    AreaPickerOptionRow(
                        title = area.title,
                        emoji = area.emoji,
                        isNone = false,
                        selected = currentAreaId == area.id,
                        onClick = { onPick(area.id) },
                    )
                }
            }
        },
        confirmButton = {},
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(cancelTitle) }
        },
    )
}

@Composable
private fun AreaPickerOptionRow(
    title: String,
    emoji: String?,
    isNone: Boolean,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val shape = RoundedCornerShape(10.dp)
    val bg = if (selected) {
        MaterialTheme.colorScheme.primary.copy(alpha = SELECTION_WASH_ALPHA)
    } else {
        Color.Transparent
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(bg, shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 9.dp),
    ) {
        Box(contentAlignment = Alignment.Center, modifier = Modifier.width(22.dp)) {
            when {
                isNone -> SeptenaGlyph(
                    kind = SeptenaIconKind.Inbox,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    size = 16.dp,
                )
                emoji != null -> Text(text = emoji, fontSize = 15.sp)
                else -> AreaDotGlyph(
                    tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.65f),
                    size = 15.dp,
                )
            }
        }
        Text(
            text = title,
            fontSize = 15.sp,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (selected) {
            CheckmarkGlyph(tint = MaterialTheme.colorScheme.primary, size = 15.dp)
        }
    }
}
