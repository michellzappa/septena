package app.septena.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import app.septena.android.AndroidAppGraph
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.generated.RegistryActionIds
import app.septena.core.generated.RegistryPlacesScreenIds
import app.septena.core.generated.RegistryPromptIds
import app.septena.core.generated.RegistryTaskAttributeIds
import app.septena.core.stringValue
import app.septena.ui.ChevronRightGlyph
import app.septena.ui.MoreDotsGlyph
import app.septena.ui.PlusGlyph
import app.septena.ui.ProjectProgressRingGlyph
import app.septena.ui.TaskCardMetrics
import app.septena.ui.TaskCardPosition
import app.septena.ui.TaskCardRow
import app.septena.ui.TaskCardSlice
import app.septena.ui.TaskListItem
import app.septena.ui.TaskRowMenuAction
import app.septena.ui.TaskSelection
import app.septena.ui.cardPosition
import app.septena.ui.headingReorderDragSource
import app.septena.ui.headingReorderDrop
import app.septena.ui.insertionPosition
import app.septena.ui.magicPlusRowDrop
import app.septena.ui.magicPlusSectionDrop
import app.septena.ui.rememberTaskContainerDropTarget
import app.septena.ui.reorderPositions
import app.septena.ui.taskListMotion
import app.septena.ui.taskReorderRowDrop
import app.septena.ui.taskReorderSectionDrop

/** Detail content for an area or project, aligned with iOS AreaDetailView / ProjectDetailView. */
@Composable
fun AreasProjectsScreen(
    graph: AndroidAppGraph,
    destination: AreasProjectsDestination,
    modifier: Modifier = Modifier,
    starredOnly: Boolean = false,
    completeTitle: String = "",
    todayTitle: String = "",
    fadedTitle: String = "",
    headerContent: (@Composable () -> Unit)? = null,
    onComplete: (String) -> Unit = {},
    onOpenProject: (String) -> Unit = {},
    onOpenTask: (String) -> Unit = {},
    rowMenuGroups: List<List<TaskRowMenuAction>> = emptyList(),
    rowMenuAccessibilityLabel: String = "",
    onTaskAction: (String, String) -> Unit = { _, _ -> },
    selection: TaskSelection = TaskSelection(),
    newSectionTrigger: Int = 0,
    onLeftProject: () -> Unit = {},
    onMagicPlusDrop: ((QuickAddDraft) -> Unit)? = null,
    expandedTaskId: String? = null,
    expandedTaskContent: (@Composable (task: TaskListItem, position: TaskCardPosition, modifier: Modifier) -> Unit)? = null,
) {
    val factory = remember(graph) { AreasProjectsViewModel.Factory(graph) }
    val viewModel: AreasProjectsViewModel = viewModel(key = destination.key, factory = factory)
    val state by viewModel.state.collectAsStateWithLifecycle()
    val languageTag = LocalConfiguration.current.locales[0].toLanguageTag()
    val isDark = LocalSeptenaDarkTheme.current
    val hasActiveTexture = LocalAppearance.current.hasActiveTexture
    val todayTint = MaterialTheme.colorScheme.secondary
    val mutedInk = MaterialTheme.colorScheme.onSurfaceVariant
    val accent = MaterialTheme.colorScheme.primary
    var dialog by remember { mutableStateOf<PlacesDialog?>(null) }
    var shareOpen by rememberSaveable(destination.key) { mutableStateOf(false) }
    var emojiPickerOpen by rememberSaveable(destination.key) { mutableStateOf(false) }
    var notesDraft by rememberSaveable(destination.key) { mutableStateOf("") }
    // The text the draft was loaded from: what a save was made from (§5a of the sharing spec).
    var notesBase by rememberSaveable(destination.key) { mutableStateOf("") }
    var notesFocused by remember(destination.key) { mutableStateOf(false) }

    LaunchedEffect(destination) { viewModel.select(destination) }
    // A row in its inline foldout keeps its place in a sorted page until it closes (LIST_SORT_SPEC §6).
    LaunchedEffect(expandedTaskId) { viewModel.setPinnedTask(expandedTaskId) }
    LaunchedEffect(state.destination, state.notes) {
        if (!notesFocused) {
            notesDraft = state.notes
            notesBase = state.notes
        }
    }
    LaunchedEffect(newSectionTrigger) {
        if (newSectionTrigger > 0 && destination is AreasProjectsDestination.Project) {
            dialog = PlacesDialog.CreateSection
        }
    }

    val latestNotesDraft by rememberUpdatedState(notesDraft)
    val latestNotesBase by rememberUpdatedState(notesBase)
    DisposableEffect(destination.key) {
        onDispose {
            if (latestNotesDraft != latestNotesBase) {
                viewModel.saveNotes(latestNotesDraft, latestNotesBase)
            }
        }
    }

    // Shared-project person filter: null = all, "" = unassigned (Nobody), else member id.
    var assigneeFilter by remember(destination.key) { mutableStateOf<String?>(null) }
    fun matchesAssignee(row: PlaceTaskRow): Boolean = when (val f = assigneeFilter) {
        null -> true
        "" -> row.assignedTo.isNullOrBlank()
        else -> row.assignedTo == f
    }

    val visibleAreaTasks = remember(state.areaTasks, starredOnly) {
        if (starredOnly) state.areaTasks.filter(PlaceTaskRow::isStarred) else state.areaTasks
    }
    val visibleUnsectioned = remember(state.unsectionedTasks, starredOnly, assigneeFilter) {
        state.unsectionedTasks.filter { (!starredOnly || it.isStarred) && matchesAssignee(it) }
    }
    val visibleSections = remember(state.sections, starredOnly, assigneeFilter) {
        state.sections.map { section ->
            section.copy(tasks = section.tasks.filter { (!starredOnly || it.isStarred) && matchesAssignee(it) })
        }
    }
    val orderedPlaceDragIds = remember(selection.selectedIds, visibleAreaTasks, visibleUnsectioned, visibleSections) {
        if (!selection.isActive) emptyList()
        else (visibleAreaTasks + visibleUnsectioned + visibleSections.flatMap(PlaceSectionRow::tasks))
            .map(PlaceTaskRow::id)
            .filter { it in selection.selectedIds }
    }

    Column(modifier = modifier.fillMaxSize()) {
        if (state.isLoading) {
            headerContent?.invoke()
            CircularProgressIndicator(modifier = Modifier.padding(24.dp))
        } else {
            // A new place starts with fresh row positions (see TaskHomeContent).
            val listState = key(destination.key) { rememberLazyListState() }
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(bottom = 96.dp),
            ) {
                if (headerContent != null) {
                    item(key = "place-screen-header") {
                        headerContent()
                    }
                }

                // Borderless glass Notes card (auto-saves on blur & leave, quiet Save link while dirty).
                item(key = "place-notes") {
                    val notesLabel = surfaceText(RegistryTaskAttributeIds.NOTES, "label", languageTag)
                    val notesDirty = notesDraft != notesBase
                    val saveNotes = {
                        viewModel.saveNotes(notesDraft, notesBase)
                        notesBase = notesDraft
                    }
                    TaskCardSlice(
                        position = TaskCardPosition.Solo,
                        isSelected = false,
                        isDark = isDark,
                        hasActiveTexture = hasActiveTexture,
                    ) {
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = TaskCardMetrics.ContentInset, vertical = 10.dp),
                        ) {
                            key(destination.key) {
                                PlaceNotesField(
                                    value = notesDraft,
                                    onValueChange = { notesDraft = it },
                                    label = notesLabel,
                                    languageTag = languageTag,
                                    focused = notesFocused,
                                    onFocusedChange = { focused ->
                                        if (notesFocused && !focused) {
                                            if (notesDraft != notesBase) {
                                                saveNotes()
                                            } else {
                                                // Nothing typed: show what came in meanwhile.
                                                notesDraft = state.notes
                                                notesBase = state.notes
                                            }
                                        }
                                        notesFocused = focused
                                    },
                                )
                            }
                            if (notesDirty) {
                                Row(
                                    modifier = Modifier.fillMaxWidth().padding(top = 6.dp),
                                    horizontalArrangement = Arrangement.End,
                                ) {
                                    Text(
                                        text = actionTitle(RegistryActionIds.PLACE_SAVE_NOTES, languageTag),
                                        fontSize = 13.sp,
                                        fontWeight = FontWeight.SemiBold,
                                        color = accent,
                                        modifier = Modifier
                                            .clip(RoundedCornerShape(6.dp))
                                            .clickable { saveNotes() }
                                            .padding(horizontal = 6.dp, vertical = 2.dp),
                                    )
                                }
                            }
                        }
                    }
                }

                // Emoji, then the page's ⋯ menu (New Project or New Section, Rename, Share Project), as on iPhone and Mac.
                item(key = "place-actions") {
                    var menuOpen by remember(destination.key) { mutableStateOf(false) }
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = TaskCardMetrics.Margin, vertical = 2.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        if (destination is AreasProjectsDestination.Area) {
                            AreaEmojiButton(
                                emoji = state.emoji,
                                accessibilityLabel = actionTitle(RegistryActionIds.AREA_CHANGE_EMOJI, languageTag),
                                onClick = { emojiPickerOpen = true },
                            )
                        }
                        Spacer(modifier = Modifier.weight(1f))
                        Box {
                            val newTitle = actionTitle(
                                if (destination is AreasProjectsDestination.Area) {
                                    RegistryActionIds.AREA_NEW_PROJECT
                                } else {
                                    RegistryActionIds.SECTION_NEW
                                },
                                languageTag,
                            )
                            val renameTitle = actionTitle(destination.renameAction(), languageTag)
                            IconButton(
                                onClick = { menuOpen = true },
                                modifier = Modifier
                                    .size(32.dp)
                                    .semantics { contentDescription = "$newTitle, $renameTitle" },
                            ) {
                                MoreDotsGlyph(tint = mutedInk.copy(alpha = 0.72f), size = 16.dp)
                            }
                            DropdownMenu(
                                expanded = menuOpen,
                                onDismissRequest = { menuOpen = false },
                                shape = RoundedCornerShape(14.dp),
                                containerColor = if (isDark) MaterialTheme.colorScheme.surfaceContainerHigh else Color(0xF7FFFFFF),
                                tonalElevation = 0.dp,
                                shadowElevation = 10.dp,
                                modifier = Modifier.width(210.dp),
                            ) {
                                PlaceMenuItem(
                                    title = newTitle,
                                    onClick = {
                                        menuOpen = false
                                        dialog = if (destination is AreasProjectsDestination.Area) {
                                            PlacesDialog.CreateProject
                                        } else {
                                            PlacesDialog.CreateSection
                                        }
                                    },
                                )
                                PlaceMenuItem(
                                    title = renameTitle,
                                    onClick = {
                                        menuOpen = false
                                        dialog = PlacesDialog.RenamePlace(state.title)
                                    },
                                )
                                if (destination is AreasProjectsDestination.Project) {
                                    PlaceMenuItem(
                                        title = RegistryCatalog.submenuTitle("sidebar.project", "moveToArea", languageTag).orEmpty(),
                                        onClick = {
                                            menuOpen = false
                                            dialog = PlacesDialog.MoveToArea
                                        },
                                    )
                                    PlaceMenuItem(
                                        title = actionTitle(RegistryActionIds.PROJECT_SHARE, languageTag),
                                        onClick = {
                                            menuOpen = false
                                            shareOpen = true
                                        },
                                    )
                                }
                            }
                        }
                    }
                }

                if (destination is AreasProjectsDestination.Project) {
                    state.share?.let { share ->
                        item(key = "project-assignee-filter") {
                            androidx.compose.foundation.lazy.LazyRow(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = TaskCardMetrics.Margin, vertical = 2.dp),
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                            ) {
                                items(share.members.size, key = { share.members[it].id }) { idx ->
                                    val member = share.members[idx]
                                    val selected = assigneeFilter == member.id
                                    androidx.compose.material3.FilterChip(
                                        selected = selected,
                                        onClick = { assigneeFilter = if (selected) null else member.id },
                                        label = { Text(if (member.id == share.me) sharingCopy(SharingCopy.you, languageTag) else member.name) },
                                    )
                                }
                                item(key = "assignee-nobody") {
                                    val selected = assigneeFilter == ""
                                    androidx.compose.material3.FilterChip(
                                        selected = selected,
                                        onClick = { assigneeFilter = if (selected) null else "" },
                                        label = { Text(sharingCopy(SharingCopy.nobody, languageTag)) },
                                    )
                                }
                            }
                        }
                    }
                }

                if (destination is AreasProjectsDestination.Area) {
                    item(key = "projects-heading") {
                        Text(
                            text = surfaceText(RegistryPlacesScreenIds.AREA_PROJECTS_HEADING, "label", languageTag),
                            fontSize = 18.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = MaterialTheme.colorScheme.onSurface,
                            modifier = taskListMotion()
                                .fillMaxWidth()
                                .padding(
                                    start = TaskCardMetrics.HeaderLeading,
                                    end = TaskCardMetrics.Margin,
                                    top = 14.dp,
                                    bottom = 6.dp,
                                ),
                        )
                    }
                    if (state.projects.isEmpty()) {
                        item(key = "projects-empty") {
                            Text(
                                text = surfaceText(RegistryPlacesScreenIds.EMPTY_AREA_PROJECTS, "title", languageTag),
                                style = MaterialTheme.typography.bodyMedium,
                                color = mutedInk,
                                modifier = taskListMotion().padding(horizontal = TaskCardMetrics.HeaderLeading, vertical = 4.dp),
                            )
                        }
                    } else {
                        itemsIndexed(state.projects, key = { _, it -> "project:${it.id}" }) { index, project ->
                            val (dropMod, isDropTargeted) = rememberTaskContainerDropTarget(
                                id = "reorder-area-project-${project.id}",
                                enabled = true,
                                onDrop = { ids -> viewModel.moveTasksToProject(ids, project.id) },
                            )
                            TaskCardSlice(
                                position = cardPosition(index, state.projects.size + 1),
                                isSelected = isDropTargeted,
                                isDark = isDark,
                                hasActiveTexture = hasActiveTexture,
                                modifier = taskListMotion().then(dropMod),
                            ) {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(TaskCardMetrics.IconTextGap),
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clickable { onOpenProject(project.id) }
                                        .padding(horizontal = TaskCardMetrics.ContentInset, vertical = 11.dp),
                                ) {
                                    Box(
                                        contentAlignment = Alignment.Center,
                                        modifier = Modifier.width(TaskCardMetrics.LeadingColumnWidth),
                                    ) {
                                        ProjectProgressRingGlyph(
                                            progress = project.progress,
                                            tint = mutedInk,
                                            size = 17.dp,
                                        )
                                    }
                                    Text(
                                        text = project.title,
                                        fontSize = 16.sp,
                                        lineHeight = 20.sp,
                                        fontWeight = FontWeight.SemiBold,
                                        color = MaterialTheme.colorScheme.onSurface,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                        modifier = Modifier.weight(1f),
                                    )
                                    project.share?.let { SharedProjectMark(it, languageTag, tint = mutedInk.copy(alpha = 0.7f)) }
                                    if (project.openCount > 0) {
                                        Text(
                                            text = project.openCount.toString(),
                                            fontSize = 13.5.sp,
                                            color = mutedInk.copy(alpha = 0.78f),
                                            style = TextStyle(fontFeatureSettings = "tnum"),
                                        )
                                    }
                                    ChevronRightGlyph(
                                        tint = mutedInk.copy(alpha = 0.55f),
                                        size = 13.dp,
                                    )
                                }
                            }
                        }
                    }
                    // Foot of the project card: the "New Project" add line (#706), also when
                    // the area has no projects yet. Same create as the ⋯ menu item.
                    item(key = "area-new-project") {
                        val newProjectTitle = actionTitle(RegistryActionIds.AREA_NEW_PROJECT, languageTag)
                        TaskCardSlice(
                            position = cardPosition(state.projects.size, state.projects.size + 1),
                            isSelected = false,
                            isDark = isDark,
                            hasActiveTexture = hasActiveTexture,
                            modifier = taskListMotion(),
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(TaskCardMetrics.IconTextGap),
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable(onClickLabel = newProjectTitle) { dialog = PlacesDialog.CreateProject }
                                    .padding(horizontal = TaskCardMetrics.ContentInset, vertical = 11.dp),
                            ) {
                                Box(
                                    contentAlignment = Alignment.Center,
                                    modifier = Modifier.width(TaskCardMetrics.LeadingColumnWidth),
                                ) {
                                    PlusGlyph(tint = mutedInk, size = 15.dp)
                                }
                                Text(
                                    text = newProjectTitle,
                                    fontSize = 16.sp,
                                    lineHeight = 20.sp,
                                    color = mutedInk,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    modifier = Modifier.weight(1f),
                                )
                            }
                        }
                    }
                    item(key = "area-tasks-heading") {
                        Text(
                            text = surfaceText(RegistryPlacesScreenIds.TASKS_HEADING, "label", languageTag),
                            fontSize = 18.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = MaterialTheme.colorScheme.onSurface,
                            modifier = taskListMotion()
                                .fillMaxWidth()
                                .magicPlusSectionDrop(
                                    id = "mp-area-tasks-${destination.id}",
                                    enabled = onMagicPlusDrop != null,
                                    onDrop = {
                                        onMagicPlusDrop?.invoke(
                                            QuickAddDraft(
                                                areaId = destination.id,
                                                position = visibleAreaTasks.firstOrNull()?.position?.let { it - 1.0 },
                                            ),
                                        )
                                    },
                                )
                                .taskReorderSectionDrop(
                                    id = "reorder-area-tasks-${destination.id}",
                                    enabled = true,
                                    onDrop = { ids ->
                                        val topPos = visibleAreaTasks.firstOrNull()?.position ?: 0.0
                                        val newPositions = List(ids.size) { i -> topPos - (ids.size - i).toDouble() }
                                        viewModel.reorderTasks(ids, newPositions)
                                    },
                                )
                                .padding(
                                    start = TaskCardMetrics.HeaderLeading,
                                    end = TaskCardMetrics.Margin,
                                    top = 14.dp,
                                    bottom = 6.dp,
                                ),
                        )
                    }
                    if (visibleAreaTasks.isEmpty()) {
                        item(key = "area-tasks-empty") {
                            Text(
                                text = surfaceText(RegistryPlacesScreenIds.EMPTY_AREA_TASKS, "title", languageTag),
                                style = MaterialTheme.typography.bodyMedium,
                                color = mutedInk,
                                modifier = taskListMotion().padding(horizontal = TaskCardMetrics.HeaderLeading, vertical = 4.dp),
                            )
                        }
                    } else {
                        val areaPositions = visibleAreaTasks.map(PlaceTaskRow::position)
                        itemsIndexed(visibleAreaTasks, key = { _, it -> "task:${it.id}" }) { index, task ->
                            val slicePosition = cardPosition(index, visibleAreaTasks.size)
                            if (expandedTaskId == task.id && expandedTaskContent != null) {
                                expandedTaskContent(task.item, slicePosition, taskListMotion())
                            } else {
                                PlaceTaskItem(
                                    task = task,
                                    position = slicePosition,
                                    completeTitle = completeTitle,
                                    todayTitle = todayTitle,
                                    todayTint = todayTint,
                                    fadedTitle = fadedTitle,
                                    isDark = isDark,
                                    hasActiveTexture = hasActiveTexture,
                                    rowMenuGroups = rowMenuGroups,
                                    rowMenuAccessibilityLabel = rowMenuAccessibilityLabel,
                                    selection = selection,
                                    onComplete = onComplete,
                                    onOpenTask = onOpenTask,
                                    onTaskAction = onTaskAction,
                                    canReorder = true,
                                    orderedDragIds = orderedPlaceDragIds,
                                    dropModifier = taskListMotion()
                                        .magicPlusRowDrop(
                                            id = "mp-area-row-${task.id}",
                                            enabled = onMagicPlusDrop != null,
                                            onDrop = { before ->
                                                onMagicPlusDrop?.invoke(
                                                    QuickAddDraft(
                                                        areaId = destination.id,
                                                        position = insertionPosition(areaPositions, index, before),
                                                    ),
                                                )
                                            },
                                        )
                                        .taskReorderRowDrop(
                                            id = "reorder-area-row-${task.id}",
                                            taskId = task.id,
                                            // A sorted page does not reorder between rows; heading drops still work.
                                            enabled = !state.isSorted,
                                            onDrop = { ids, before ->
                                                val newPositions = reorderPositions(areaPositions, index, before, ids.size)
                                                viewModel.reorderTasks(ids, newPositions)
                                            },
                                        ),
                                )
                            }
                        }
                    }
                }

                if (destination is AreasProjectsDestination.Project) {
                    item(key = "project-tasks-heading") {
                        Text(
                            text = surfaceText(RegistryPlacesScreenIds.TASKS_HEADING, "label", languageTag),
                            fontSize = 18.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = MaterialTheme.colorScheme.onSurface,
                            modifier = taskListMotion()
                                .fillMaxWidth()
                                .magicPlusSectionDrop(
                                    id = "mp-project-tasks-${destination.id}",
                                    enabled = onMagicPlusDrop != null,
                                    onDrop = {
                                        onMagicPlusDrop?.invoke(
                                            QuickAddDraft(
                                                projectId = destination.id,
                                                position = visibleUnsectioned.firstOrNull()?.position?.let { it - 1.0 },
                                            ),
                                        )
                                    },
                                )
                                .taskReorderSectionDrop(
                                    id = "reorder-project-tasks-${destination.id}",
                                    enabled = true,
                                    onDrop = { ids ->
                                        val topPos = visibleUnsectioned.firstOrNull()?.position ?: 0.0
                                        val positions = List(ids.size) { i -> topPos - (ids.size - i).toDouble() }
                                        viewModel.reorderTasks(ids, positions, targetHeadingId = null, updateHeading = true)
                                    },
                                )
                                .padding(
                                    start = TaskCardMetrics.HeaderLeading,
                                    end = TaskCardMetrics.Margin,
                                    top = 14.dp,
                                    bottom = 6.dp,
                                ),
                        )
                    }
                    if (visibleUnsectioned.isEmpty() && visibleSections.isEmpty()) {
                        item(key = "project-tasks-empty") {
                            Text(
                                text = surfaceText(RegistryPlacesScreenIds.EMPTY_PROJECT_TASKS, "title", languageTag),
                                style = MaterialTheme.typography.bodyMedium,
                                color = mutedInk,
                                modifier = taskListMotion().padding(horizontal = TaskCardMetrics.HeaderLeading, vertical = 4.dp),
                            )
                        }
                    }
                    if (visibleUnsectioned.isNotEmpty()) {
                        val projectPositions = visibleUnsectioned.map(PlaceTaskRow::position)
                        itemsIndexed(visibleUnsectioned, key = { _, it -> "task:${it.id}" }) { index, task ->
                            val slicePosition = cardPosition(index, visibleUnsectioned.size)
                            if (expandedTaskId == task.id && expandedTaskContent != null) {
                                expandedTaskContent(task.item, slicePosition, taskListMotion())
                            } else {
                                PlaceTaskItem(
                                    task = task,
                                    position = slicePosition,
                                    completeTitle = completeTitle,
                                    todayTitle = todayTitle,
                                    todayTint = todayTint,
                                    fadedTitle = fadedTitle,
                                    isDark = isDark,
                                    hasActiveTexture = hasActiveTexture,
                                    rowMenuGroups = rowMenuGroups,
                                    rowMenuAccessibilityLabel = rowMenuAccessibilityLabel,
                                    selection = selection,
                                    onComplete = onComplete,
                                    onOpenTask = onOpenTask,
                                    onTaskAction = onTaskAction,
                                    canReorder = true,
                                    orderedDragIds = orderedPlaceDragIds,
                                    dropModifier = taskListMotion()
                                        .magicPlusRowDrop(
                                            id = "mp-project-row-${task.id}",
                                            enabled = onMagicPlusDrop != null,
                                            onDrop = { before ->
                                                onMagicPlusDrop?.invoke(
                                                    QuickAddDraft(
                                                        projectId = destination.id,
                                                        position = insertionPosition(projectPositions, index, before),
                                                    ),
                                                )
                                            },
                                        )
                                        .taskReorderRowDrop(
                                            id = "reorder-project-row-${task.id}",
                                            taskId = task.id,
                                            // A sorted page does not reorder between rows; heading drops still work.
                                            enabled = !state.isSorted,
                                            onDrop = { ids, before ->
                                                val newPositions = reorderPositions(projectPositions, index, before, ids.size)
                                                viewModel.reorderTasks(ids, newPositions, targetHeadingId = null, updateHeading = true)
                                            },
                                        ),
                                )
                            }
                        }
                    }
                    item(key = "sections-heading") {
                        Text(
                            text = surfaceText(RegistryPlacesScreenIds.SECTIONS_HEADING, "label", languageTag),
                            fontSize = 18.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = MaterialTheme.colorScheme.onSurface,
                            modifier = taskListMotion().padding(
                                start = TaskCardMetrics.HeaderLeading,
                                end = TaskCardMetrics.Margin,
                                top = 14.dp,
                                bottom = 4.dp,
                            ),
                        )
                    }
                    if (visibleSections.isEmpty()) {
                        item(key = "project-sections-empty") {
                            Text(
                                text = surfaceText(RegistryPlacesScreenIds.EMPTY_PROJECT_SECTIONS, "title", languageTag),
                                style = MaterialTheme.typography.bodyMedium,
                                color = mutedInk,
                                modifier = taskListMotion().padding(horizontal = TaskCardMetrics.HeaderLeading, vertical = 4.dp),
                            )
                        }
                    } else {
                        visibleSections.forEach { section ->
                            placeSection(
                                projectId = destination.id,
                                section = section,
                                languageTag = languageTag,
                                completeTitle = completeTitle,
                                todayTitle = todayTitle,
                                todayTint = todayTint,
                                fadedTitle = fadedTitle,
                                isDark = isDark,
                                hasActiveTexture = hasActiveTexture,
                                onComplete = onComplete,
                                onOpenTask = onOpenTask,
                                rowMenuGroups = rowMenuGroups,
                                rowMenuAccessibilityLabel = rowMenuAccessibilityLabel,
                                selection = selection,
                                onTaskAction = onTaskAction,
                                onRename = { dialog = PlacesDialog.RenameSection(section.id, section.title) },
                                onDelete = { dialog = PlacesDialog.DeleteSection(section.id) },
                                onMagicPlusDrop = onMagicPlusDrop,
                                orderedDragIds = orderedPlaceDragIds,
                                reorderBetweenRows = !state.isSorted,
                                onReorderToSection = { ids, newPositions ->
                                    viewModel.reorderTasks(ids, newPositions, targetHeadingId = section.id, updateHeading = true)
                                },
                                // Headings reorder by drag in a sorted project too (LIST_SORT_SPEC §6).
                                onReorderHeadings = { ids -> viewModel.reorderSections(ids, beforeHeadingId = section.id) },
                                expandedTaskId = expandedTaskId,
                                expandedTaskContent = expandedTaskContent,
                            )
                        }
                        // The slot after the last section: a heading dropped here moves to the end.
                        item(key = "sections-end") {
                            Spacer(
                                modifier = taskListMotion()
                                    .fillMaxWidth()
                                    .height(16.dp)
                                    .headingReorderDrop(
                                        id = "reorder-heading-end-${destination.id}",
                                        headingId = null,
                                        onDrop = { ids -> viewModel.reorderSections(ids, beforeHeadingId = null) },
                                    ),
                            )
                        }
                    }
                }
            }
        }
    }

    if (emojiPickerOpen && destination is AreasProjectsDestination.Area) {
        AreaEmojiPickerSheet(
            initialEmoji = state.emoji,
            languageTag = languageTag,
            onDismissRequest = { emojiPickerOpen = false },
            onSelect = viewModel::setAreaEmoji,
        )
    }

    if (shareOpen && destination is AreasProjectsDestination.Project) {
        ShareProjectDialog(
            graph = graph,
            projectId = destination.id,
            languageTag = languageTag,
            onDismiss = { shareOpen = false },
            onEnded = onLeftProject,
        )
    }

    state.errorMessage?.let { message ->
        AlertDialog(
            onDismissRequest = viewModel::clearError,
            title = { Text(errorPromptText("title", languageTag)) },
            text = { Text(RegistryCatalog.localizedString(message, languageTag) ?: message) },
            confirmButton = {
                TextButton(onClick = viewModel::clearError) { Text(errorPromptText("confirmTitle", languageTag)) }
            },
        )
    }

    when (val active = dialog) {
        null -> Unit
        PlacesDialog.CreateProject -> TextEntryDialog(
            promptId = RegistryPromptIds.NEW_PROJECT,
            languageTag = languageTag,
            onDismiss = { dialog = null },
            onConfirm = { viewModel.createProject(it); dialog = null },
        )
        PlacesDialog.CreateSection -> TextEntryDialog(
            promptId = RegistryPromptIds.NEW_SECTION,
            languageTag = languageTag,
            onDismiss = { dialog = null },
            onConfirm = { viewModel.createSection(it); dialog = null },
        )
        is PlacesDialog.RenamePlace -> TextEntryDialog(
            promptId = destination.renamePrompt(),
            languageTag = languageTag,
            initialValue = active.title,
            onDismiss = { dialog = null },
            onConfirm = { viewModel.renameSelected(it); dialog = null },
        )
        is PlacesDialog.RenameSection -> TextEntryDialog(
            promptId = RegistryPromptIds.RENAME_SECTION,
            languageTag = languageTag,
            initialValue = active.title,
            onDismiss = { dialog = null },
            onConfirm = { viewModel.renameSection(active.id, it); dialog = null },
        )
        is PlacesDialog.DeleteSection -> DeleteSectionDialog(
            languageTag = languageTag,
            onDismiss = { dialog = null },
            onConfirm = { viewModel.deleteSection(active.id); dialog = null },
        )
        PlacesDialog.MoveToArea -> MoveProjectToAreaDialog(
            areas = state.availableAreas,
            currentAreaId = state.currentAreaId,
            languageTag = languageTag,
            onDismiss = { dialog = null },
            onPick = { areaId ->
                dialog = null
                if (areaId != state.currentAreaId) {
                    viewModel.moveProjectToArea(areaId)
                }
            },
        )
    }
}

/** One row of a place's or a section's menu. */
@Composable
private fun PlaceMenuItem(title: String, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        Text(
            text = title,
            fontSize = 15.sp,
            color = MaterialTheme.colorScheme.onSurface,
        )
    }
}

@Composable
private fun PlaceTaskItem(
    task: PlaceTaskRow,
    position: TaskCardPosition,
    completeTitle: String,
    todayTitle: String,
    todayTint: Color,
    fadedTitle: String,
    isDark: Boolean,
    hasActiveTexture: Boolean,
    rowMenuGroups: List<List<TaskRowMenuAction>>,
    rowMenuAccessibilityLabel: String,
    selection: TaskSelection,
    onComplete: (String) -> Unit,
    onOpenTask: (String) -> Unit,
    onTaskAction: (String, String) -> Unit,
    dropModifier: Modifier = Modifier,
    canReorder: Boolean = false,
    orderedDragIds: List<String> = emptyList(),
) {
    TaskCardRow(
        task = task.item,
        position = position,
        completeTitle = completeTitle,
        canComplete = true,
        todayTitle = todayTitle,
        todayTint = todayTint,
        fadedTitle = fadedTitle,
        showTodayIndicator = true,
        showFadedIndicator = true,
        isDark = isDark,
        hasActiveTexture = hasActiveTexture,
        onComplete = onComplete,
        onOpenTask = onOpenTask,
        rowMenuGroups = rowMenuGroups,
        rowMenuAccessibilityLabel = rowMenuAccessibilityLabel,
        selection = selection,
        onTaskAction = onTaskAction,
        dropModifier = dropModifier,
        canReorder = canReorder,
        orderedDragIds = orderedDragIds,
    )
}

/** A section's header and its task rows, each its own list item, so a completed task moves only the rows below it. */
private fun LazyListScope.placeSection(
    projectId: String,
    section: PlaceSectionRow,
    languageTag: String,
    completeTitle: String,
    todayTitle: String,
    todayTint: Color,
    fadedTitle: String,
    isDark: Boolean,
    hasActiveTexture: Boolean,
    onComplete: (String) -> Unit,
    onOpenTask: (String) -> Unit,
    rowMenuGroups: List<List<TaskRowMenuAction>>,
    rowMenuAccessibilityLabel: String,
    selection: TaskSelection,
    onTaskAction: (String, String) -> Unit,
    onRename: () -> Unit,
    onDelete: () -> Unit,
    onMagicPlusDrop: ((QuickAddDraft) -> Unit)? = null,
    orderedDragIds: List<String> = emptyList(),
    onReorderToSection: (ids: List<String>, positions: List<Double>) -> Unit = { _, _ -> },
    /** A heading drag dropped just above this section's heading. */
    onReorderHeadings: (ids: List<String>) -> Unit = {},
    /** False on a sorted page: a drop between two rows does not reorder. */
    reorderBetweenRows: Boolean = true,
    expandedTaskId: String? = null,
    expandedTaskContent: (@Composable (task: TaskListItem, position: TaskCardPosition, modifier: Modifier) -> Unit)? = null,
) {
    item(key = "section:${section.id}") {
        PlaceSectionHeader(
            projectId = projectId,
            section = section,
            languageTag = languageTag,
            isDark = isDark,
            onRename = onRename,
            onDelete = onDelete,
            onMagicPlusDrop = onMagicPlusDrop,
            onReorderToSection = onReorderToSection,
            onReorderHeadings = onReorderHeadings,
            modifier = taskListMotion(),
        )
    }
    if (section.tasks.isEmpty()) {
        item(key = "section-empty:${section.id}") {
            Text(
                text = surfaceText(RegistryPlacesScreenIds.EMPTY_SECTION_TASKS, "title", languageTag),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = taskListMotion().padding(horizontal = TaskCardMetrics.HeaderLeading, vertical = 4.dp),
            )
        }
    } else {
        val sectionPositions = section.tasks.map(PlaceTaskRow::position)
        itemsIndexed(section.tasks, key = { _, it -> "task:${it.id}" }) { index, task ->
            val slicePosition = cardPosition(index, section.tasks.size)
            if (expandedTaskId == task.id && expandedTaskContent != null) {
                expandedTaskContent(task.item, slicePosition, taskListMotion())
            } else {
                PlaceTaskItem(
                    task = task,
                    position = slicePosition,
                    completeTitle = completeTitle,
                    todayTitle = todayTitle,
                    todayTint = todayTint,
                    fadedTitle = fadedTitle,
                    isDark = isDark,
                    hasActiveTexture = hasActiveTexture,
                    rowMenuGroups = rowMenuGroups,
                    rowMenuAccessibilityLabel = rowMenuAccessibilityLabel,
                    selection = selection,
                    onComplete = onComplete,
                    onOpenTask = onOpenTask,
                    onTaskAction = onTaskAction,
                    canReorder = true,
                    orderedDragIds = orderedDragIds,
                    dropModifier = taskListMotion()
                        .magicPlusRowDrop(
                            id = "mp-section-row-${task.id}",
                            enabled = onMagicPlusDrop != null,
                            onDrop = { before ->
                                onMagicPlusDrop?.invoke(
                                    QuickAddDraft(
                                        projectId = projectId,
                                        headingId = section.id,
                                        position = insertionPosition(sectionPositions, index, before),
                                    ),
                                )
                            },
                        )
                        .taskReorderRowDrop(
                            id = "reorder-section-row-${task.id}",
                            taskId = task.id,
                            enabled = reorderBetweenRows,
                            onDrop = { ids, before ->
                                val newPositions = reorderPositions(sectionPositions, index, before, ids.size)
                                onReorderToSection(ids, newPositions)
                            },
                        ),
                )
            }
        }
    }
}

@Composable
private fun PlaceSectionHeader(
    projectId: String,
    section: PlaceSectionRow,
    languageTag: String,
    isDark: Boolean,
    onRename: () -> Unit,
    onDelete: () -> Unit,
    onMagicPlusDrop: ((QuickAddDraft) -> Unit)?,
    onReorderToSection: (ids: List<String>, positions: List<Double>) -> Unit,
    onReorderHeadings: (ids: List<String>) -> Unit,
    modifier: Modifier = Modifier,
) {
    var menuOpen by remember(section.id) { mutableStateOf(false) }
    val mutedInk = MaterialTheme.colorScheme.onSurfaceVariant
    val destructiveRed = if (isDark) Color(0xFFFF453A) else Color(0xFFFF3B30)
    val menuBg = if (isDark) MaterialTheme.colorScheme.surfaceContainerHigh else Color(0xF7FFFFFF)

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .magicPlusSectionDrop(
                id = "mp-heading-${section.id}",
                enabled = onMagicPlusDrop != null,
                onDrop = {
                    onMagicPlusDrop?.invoke(
                        QuickAddDraft(
                            projectId = projectId,
                            headingId = section.id,
                            position = section.tasks.firstOrNull()?.position?.let { it - 1.0 },
                        ),
                    )
                },
            )
            .taskReorderSectionDrop(
                id = "reorder-heading-${section.id}",
                enabled = true,
                onDrop = { ids ->
                    val topPos = section.tasks.firstOrNull()?.position ?: 0.0
                    val positions = List(ids.size) { i -> topPos - (ids.size - i).toDouble() }
                    onReorderToSection(ids, positions)
                },
            )
            // A heading drag lands above this heading; long-press and slide the header to move the section.
            .headingReorderDrop(
                id = "reorder-heading-slot-${section.id}",
                headingId = section.id,
                onDrop = onReorderHeadings,
            )
            .headingReorderDragSource(headingId = section.id, title = section.title)
            .padding(
                start = TaskCardMetrics.HeaderLeading,
                end = TaskCardMetrics.Margin,
                top = 14.dp,
                bottom = 4.dp,
            ),
    ) {
        Text(
            text = section.title,
            fontSize = 18.sp,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        Box {
            IconButton(
                onClick = { menuOpen = true },
                modifier = Modifier.size(32.dp),
            ) {
                MoreDotsGlyph(tint = mutedInk.copy(alpha = 0.72f), size = 16.dp)
            }
            DropdownMenu(
                expanded = menuOpen,
                onDismissRequest = { menuOpen = false },
                shape = RoundedCornerShape(14.dp),
                containerColor = menuBg,
                tonalElevation = 0.dp,
                shadowElevation = 10.dp,
                modifier = Modifier.width(210.dp),
            ) {
                if (onMagicPlusDrop != null) {
                    PlaceMenuItem(
                        title = actionTitle(RegistryActionIds.SECTION_NEW_TASK, languageTag),
                        onClick = {
                            menuOpen = false
                            onMagicPlusDrop(QuickAddDraft(projectId = projectId, headingId = section.id))
                        },
                    )
                }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable {
                            menuOpen = false
                            onRename()
                        }
                        .padding(horizontal = 16.dp, vertical = 10.dp),
                ) {
                    Text(
                        text = actionTitle(RegistryActionIds.SECTION_RENAME, languageTag),
                        fontSize = 15.sp,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                }
                HorizontalDivider(
                    thickness = 0.5.dp,
                    color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f),
                )
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable {
                            menuOpen = false
                            onDelete()
                        }
                        .padding(horizontal = 16.dp, vertical = 10.dp),
                ) {
                    Text(
                        text = actionTitle(RegistryActionIds.SECTION_DELETE, languageTag),
                        fontSize = 15.sp,
                        color = destructiveRed,
                    )
                }
            }
        }
    }
}

@Composable
private fun TextEntryDialog(
    promptId: String,
    languageTag: String,
    initialValue: String = "",
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    val prompt = remember(promptId, languageTag) { textPrompt(promptId, languageTag) }
    var value by remember(promptId, initialValue) { mutableStateOf(initialValue) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(prompt.title) },
        text = {
            OutlinedTextField(
                value = value,
                onValueChange = { value = it },
                label = { Text(prompt.placeholder) },
                singleLine = true,
            )
        },
        confirmButton = {
            TextButton(enabled = value.isNotBlank(), onClick = { onConfirm(value) }) {
                Text(prompt.confirmTitle)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(promptsText("cancelTitle", languageTag)) }
        },
    )
}

@Composable
private fun DeleteSectionDialog(
    languageTag: String,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    val copy = remember(languageTag) { surfacePrompt(RegistryPromptIds.DELETE_SECTION, languageTag) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(copy.title) },
        text = { Text(copy.message) },
        confirmButton = {
            TextButton(onClick = onConfirm) { Text(copy.confirmTitle) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(promptsText("cancelTitle", languageTag)) }
        },
    )
}

private sealed interface PlacesDialog {
    data object CreateProject : PlacesDialog
    data object CreateSection : PlacesDialog
    data object MoveToArea : PlacesDialog
    data class RenamePlace(val title: String) : PlacesDialog
    data class RenameSection(val id: String, val title: String) : PlacesDialog
    data class DeleteSection(val id: String) : PlacesDialog
}

private data class EntryPrompt(val title: String, val placeholder: String, val confirmTitle: String)
private data class ConfirmPrompt(val title: String, val message: String, val confirmTitle: String)

private fun textPrompt(id: String, languageTag: String): EntryPrompt {
    val prompt = RegistryCatalog.surface(id)?.fields.orEmpty()
    return EntryPrompt(
        title = prompt["title"].stringValue().registryLocalized(languageTag),
        placeholder = prompt["placeholder"].stringValue().registryLocalized(languageTag),
        confirmTitle = prompt["confirmTitle"].stringValue().registryLocalized(languageTag),
    )
}

private fun surfacePrompt(id: String, languageTag: String): ConfirmPrompt {
    val prompt = RegistryCatalog.surface(id)?.fields.orEmpty()
    return ConfirmPrompt(
        title = prompt["title"].stringValue().registryLocalized(languageTag),
        message = prompt["message"].stringValue().registryLocalized(languageTag),
        confirmTitle = prompt["confirmTitle"].stringValue().registryLocalized(languageTag),
    )
}

private fun surfaceText(id: String, field: String, languageTag: String): String {
    val value = RegistryCatalog.surface(id)?.fields?.get(field).stringValue().orEmpty()
    return value.registryLocalized(languageTag)
}

private val registryPrompts: JsonValue.ObjectValue?
    get() = RegistryCatalog.document("surfaces").fields["prompts"] as? JsonValue.ObjectValue

/** Shared prompt chrome (surfaces.json `prompts.cancelTitle`, ...), which has no ID of its own. */
private fun promptsText(field: String, languageTag: String): String =
    registryPrompts?.fields?.get(field).stringValue().registryLocalized(languageTag)

/** The generic error alert copy (surfaces.json `prompts.error`). */
private fun errorPromptText(field: String, languageTag: String): String {
    val error = registryPrompts?.fields?.get("error") as? JsonValue.ObjectValue
    return error?.fields?.get(field).stringValue().registryLocalized(languageTag)
}

private fun actionTitle(id: String, languageTag: String): String =
    RegistryCatalog.actionTitle(id, languageTag = languageTag).orEmpty()

private fun String?.registryLocalized(languageTag: String): String =
    this?.let { RegistryCatalog.localizedString(it, languageTag) ?: it }.orEmpty()

private fun AreasProjectsDestination.renameAction(): String = when (this) {
    is AreasProjectsDestination.Area -> RegistryActionIds.AREA_RENAME
    is AreasProjectsDestination.Project -> RegistryActionIds.PROJECT_RENAME
}

private fun AreasProjectsDestination.renamePrompt(): String = when (this) {
    is AreasProjectsDestination.Area -> RegistryPromptIds.RENAME_AREA
    is AreasProjectsDestination.Project -> RegistryPromptIds.RENAME_PROJECT
}
