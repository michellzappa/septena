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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
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
import app.septena.ui.ChevronRightGlyph
import app.septena.ui.LocalMagicPlusDrag
import app.septena.ui.MagicPlusDragState
import app.septena.ui.ProjectProgressRingGlyph
import app.septena.ui.SELECTION_WASH_ALPHA
import app.septena.ui.SeptenaGlyph
import app.septena.ui.SeptenaIconKind
import app.septena.ui.TaskCardMetrics
import app.septena.ui.TaskCardPosition
import app.septena.ui.TaskCardSlice
import app.septena.ui.cardPosition
import app.septena.ui.rememberMagicPlusContainerDrop
import kotlinx.coroutines.launch

private val SIDEBAR_ROW_HEIGHT = 42.dp
private val TILE_GUTTER = 10.dp

/**
 * Full-screen mobile homepage (Things / iOS `SidebarRootView` root screen):
 * - Top bar with Search + Settings (no hamburger drawer on phone).
 * - 2-column grid of half-width smart-list pills with icons and bold counts.
 * - Compact grouped glass-ish cards for standalone projects, each Area with its
 *   collapsible nested projects, and bottom smart lists with counts.
 * - Floating circular Magic Plus button for New Task / New Project / New Area.
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
    onNewTask: (QuickAddDraft) -> Unit,
    onCreateArea: (String) -> Unit,
    onCreateProject: (String) -> Unit,
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
    var promptMode by remember { mutableStateOf<HomeCreatePrompt?>(null) }
    val pullScope = rememberCoroutineScope()
    var isPullRefreshing by remember { mutableStateOf(false) }
    val magicPlusDrag = remember { MagicPlusDragState() }
    magicPlusDrag.fallbackDrop = { onNewTask(QuickAddDraft(today = true)) }

    val newTaskTitle = RegistryCatalog.actionTitle(RegistryActionIds.APP_QUICK_ADD, languageTag = languageTag)
        ?.takeIf(String::isNotBlank) ?: quickAddTitle
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
                        onSelect = onSelectLocation,
                        onSetAreaEmoji = onSetAreaEmoji,
                        onOpenSettings = onOpenSettings,
                        onShareProject = onShareProject,
                        onJoinShared = onJoinShared,
                        onMagicPlusDropLocation = { loc ->
                            onNewTask(
                                when (loc) {
                                    is TaskHomeLocation.Area -> QuickAddDraft(areaId = loc.id)
                                    is TaskHomeLocation.Project -> QuickAddDraft(projectId = loc.id)
                                    is TaskHomeLocation.SmartList -> when (loc.destinationId) {
                                        RegistryDestinationIds.TODAY -> QuickAddDraft(today = true)
                                        RegistryDestinationIds.STARRED -> QuickAddDraft(starred = true)
                                        else -> QuickAddDraft()
                                    }
                                },
                            )
                        },
                        modifier = Modifier.fillMaxSize(),
                    )
                }
            }

            // Round Magic Plus orb on the Lists Homepage: tap opens New Task / New Project / New Area;
            // drag-and-drop onto Today / Favorites / any Area or Project opens Quick Add pre-filed there.
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
                    DropdownMenuItem(
                        text = { Text(newTaskTitle) },
                        onClick = {
                            createMenuOpen = false
                            onNewTask(QuickAddDraft(today = true))
                        },
                    )
                    if (newProjectTitle.isNotEmpty()) {
                        DropdownMenuItem(
                            text = { Text(newProjectTitle) },
                            onClick = {
                                createMenuOpen = false
                                promptMode = HomeCreatePrompt.Project
                            },
                        )
                    }
                    if (newAreaTitle.isNotEmpty()) {
                        DropdownMenuItem(
                            text = { Text(newAreaTitle) },
                            onClick = {
                                createMenuOpen = false
                                promptMode = HomeCreatePrompt.Area
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

    promptMode?.let { mode ->
        val promptId = when (mode) {
            HomeCreatePrompt.Area -> RegistryPromptIds.NEW_AREA
            HomeCreatePrompt.Project -> RegistryPromptIds.NEW_PROJECT
        }
        HomeNameEntryDialog(
            promptId = promptId,
            languageTag = languageTag,
            onDismiss = { promptMode = null },
            onConfirm = { name ->
                promptMode = null
                when (mode) {
                    HomeCreatePrompt.Area -> onCreateArea(name)
                    HomeCreatePrompt.Project -> onCreateProject(name)
                }
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
    onMagicPlusDropLocation: ((TaskHomeLocation) -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val todayTint = MaterialTheme.colorScheme.secondary
    val mutedIcon = MaterialTheme.colorScheme.onSurfaceVariant
    var collapsedAreaIds by rememberSaveable { mutableStateOf(emptySet<String>()) }
    var emojiTargetArea by remember { mutableStateOf<Pair<String, String?>?>(null) }

    val areaIds = remember(state.areas) {
        state.areas.mapNotNull { (it.location as? TaskHomeLocation.Area)?.id }.toSet()
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
    val changeEmojiTitle = remember(languageTag) {
        RegistryCatalog.actionTitle(RegistryActionIds.AREA_CHANGE_EMOJI, languageTag = languageTag).orEmpty()
    }

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
                                val canDrop = onMagicPlusDropLocation != null && loc.destinationId in setOf(
                                    RegistryDestinationIds.TODAY,
                                    RegistryDestinationIds.INBOX,
                                    RegistryDestinationIds.ANYTIME,
                                    RegistryDestinationIds.STARRED,
                                )
                                val (dropMod, isDropTargeted) = rememberMagicPlusContainerDrop(
                                    id = "mp-home-smart-${loc.destinationId}",
                                    enabled = canDrop,
                                    onDrop = { onMagicPlusDropLocation?.invoke(loc) },
                                )
                                SmartListPillTile(
                                    iconKind = kind,
                                    iconTint = iconTint,
                                    title = title,
                                    count = item.count,
                                    isSelected = (highlightSelection && state.location == loc) || isDropTargeted,
                                    isDark = isDark,
                                    hasActiveTexture = hasActiveTexture,
                                    onClick = { onSelect(loc) },
                                    modifier = Modifier.weight(1f).then(dropMod),
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

        // 2. Standalone top-level projects card (if any).
        if (standaloneProjects.isNotEmpty()) {
            itemsIndexed(standaloneProjects, key = { _, it -> "loose-project:${(it.location as TaskHomeLocation.Project).id}" }) { index, item ->
                val proj = item.location as TaskHomeLocation.Project
                val (dropMod, isDropTargeted) = rememberMagicPlusContainerDrop(
                    id = "mp-home-project-${proj.id}",
                    enabled = onMagicPlusDropLocation != null,
                    onDrop = { onMagicPlusDropLocation?.invoke(proj) },
                )
                CompactSidebarProjectRow(
                    item = item,
                    position = cardPosition(index, standaloneProjects.size),
                    isSelected = (highlightSelection && state.location == item.location) || isDropTargeted,
                    isDark = isDark,
                    hasActiveTexture = hasActiveTexture,
                    onClick = { onSelect(item.location) },
                    onShare = { onShareProject(proj.id) },
                    languageTag = languageTag,
                    modifier = dropMod,
                )
            }
        }

        // 3. One grouped card per Area (area header row + collapsible active projects underneath).
        state.areas.forEach { areaItem ->
            val area = areaItem.location as? TaskHomeLocation.Area ?: return@forEach
            val childProjects = projectsByArea[area.id].orEmpty()
            val collapsed = area.id in collapsedAreaIds
            val visibleChildren = if (collapsed) emptyList() else childProjects
            val cardRowCount = 1 + visibleChildren.size

            item(key = "area:${area.id}") {
                val (dropMod, isDropTargeted) = rememberMagicPlusContainerDrop(
                    id = "mp-home-area-${area.id}",
                    enabled = onMagicPlusDropLocation != null,
                    onDrop = { onMagicPlusDropLocation?.invoke(area) },
                )
                CompactSidebarAreaRow(
                    item = areaItem,
                    position = cardPosition(0, cardRowCount),
                    isSelected = (highlightSelection && state.location == area) || isDropTargeted,
                    isDark = isDark,
                    hasActiveTexture = hasActiveTexture,
                    hasProjects = childProjects.isNotEmpty(),
                    collapsed = collapsed,
                    canChangeEmoji = changeEmojiAvailable,
                    changeEmojiTitle = changeEmojiTitle,
                    onClick = { onSelect(area) },
                    onToggleCollapse = {
                        collapsedAreaIds = if (collapsed) collapsedAreaIds - area.id else collapsedAreaIds + area.id
                    },
                    onOpenEmojiPicker = { emojiTargetArea = area.id to areaItem.emoji },
                    modifier = dropMod,
                )
            }

            itemsIndexed(visibleChildren, key = { _, it -> "area-project:${(it.location as TaskHomeLocation.Project).id}" }) { index, projectItem ->
                val proj = projectItem.location as TaskHomeLocation.Project
                val (dropMod, isDropTargeted) = rememberMagicPlusContainerDrop(
                    id = "mp-home-project-${proj.id}",
                    enabled = onMagicPlusDropLocation != null,
                    onDrop = { onMagicPlusDropLocation?.invoke(proj) },
                )
                CompactSidebarProjectRow(
                    item = projectItem,
                    position = cardPosition(index + 1, cardRowCount),
                    isSelected = (highlightSelection && state.location == projectItem.location) || isDropTargeted,
                    isDark = isDark,
                    hasActiveTexture = hasActiveTexture,
                    onClick = { onSelect(projectItem.location) },
                    onShare = { onShareProject(proj.id) },
                    languageTag = languageTag,
                    modifier = dropMod,
                )
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
    onClick: () -> Unit,
    onToggleCollapse: () -> Unit,
    onOpenEmojiPicker: () -> Unit,
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
                        onLongClick = { if (canChangeEmoji) menuExpanded = true },
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

            if (canChangeEmoji) {
                DropdownMenu(
                    expanded = menuExpanded,
                    onDismissRequest = { menuExpanded = false },
                ) {
                    DropdownMenuItem(
                        text = { Text(changeEmojiTitle) },
                        onClick = {
                            menuExpanded = false
                            onOpenEmojiPicker()
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
    onClick: () -> Unit,
    onShare: () -> Unit,
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
                    text = { Text(RegistryCatalog.actionTitle(RegistryActionIds.PROJECT_SHARE, languageTag = languageTag).orEmpty()) },
                    onClick = {
                        menuExpanded = false
                        onShare()
                    },
                )
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
                color = MaterialTheme.colorScheme.onSurface,
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

private enum class HomeCreatePrompt { Area, Project }

@Composable
private fun HomeNameEntryDialog(
    promptId: String,
    languageTag: String,
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
    var value by remember(promptId) { mutableStateOf("") }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            OutlinedTextField(
                value = value,
                onValueChange = { value = it },
                label = { Text(placeholder) },
                singleLine = true,
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
