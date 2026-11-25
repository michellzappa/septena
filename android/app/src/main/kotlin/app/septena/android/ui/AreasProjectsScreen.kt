package app.septena.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
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
import app.septena.ui.PlusSmallGlyph
import app.septena.ui.ProjectProgressRingGlyph
import app.septena.ui.TaskCardMetrics
import app.septena.ui.TaskCardPosition
import app.septena.ui.TaskCardRow
import app.septena.ui.TaskCardSlice
import app.septena.ui.TaskRowMenuAction
import app.septena.ui.TaskSelection
import app.septena.ui.cardPosition
import app.septena.ui.insertionPosition
import app.septena.ui.magicPlusRowDrop
import app.septena.ui.magicPlusSectionDrop
import app.septena.ui.rememberTaskContainerDropTarget
import app.septena.ui.reorderPositions
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
    onMagicPlusDrop: ((QuickAddDraft) -> Unit)? = null,
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
    var emojiPickerOpen by rememberSaveable(destination.key) { mutableStateOf(false) }
    var notesDraft by rememberSaveable(destination.key) { mutableStateOf("") }
    var notesFocused by remember(destination.key) { mutableStateOf(false) }
    var areaTaskDraft by rememberSaveable(destination.key) { mutableStateOf("") }
    var projectTaskDraft by rememberSaveable(destination.key) { mutableStateOf("") }
    var sectionTaskDrafts by remember(destination.key) { mutableStateOf(emptyMap<String, String>()) }

    LaunchedEffect(destination) { viewModel.select(destination) }
    LaunchedEffect(state.destination, state.notes) {
        if (!notesFocused) notesDraft = state.notes
    }
    LaunchedEffect(newSectionTrigger) {
        if (newSectionTrigger > 0 && destination is AreasProjectsDestination.Project) {
            dialog = PlacesDialog.CreateSection
        }
    }

    val latestNotesDraft by rememberUpdatedState(notesDraft)
    val latestSavedNotes by rememberUpdatedState(state.notes)
    DisposableEffect(destination.key) {
        onDispose {
            if (latestNotesDraft != latestSavedNotes) {
                viewModel.saveNotes(latestNotesDraft)
            }
        }
    }

    val visibleAreaTasks = remember(state.areaTasks, starredOnly) {
        if (starredOnly) state.areaTasks.filter(PlaceTaskRow::isStarred) else state.areaTasks
    }
    val visibleUnsectioned = remember(state.unsectionedTasks, starredOnly) {
        if (starredOnly) state.unsectionedTasks.filter(PlaceTaskRow::isStarred) else state.unsectionedTasks
    }
    val visibleSections = remember(state.sections, starredOnly) {
        if (starredOnly) {
            state.sections.map { it.copy(tasks = it.tasks.filter(PlaceTaskRow::isStarred)) }
        } else {
            state.sections
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
            LazyColumn(
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
                    val notesDirty = notesDraft != state.notes
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
                            Box(modifier = Modifier.fillMaxWidth()) {
                                if (notesDraft.isEmpty()) {
                                    Text(
                                        text = notesLabel,
                                        fontSize = 14.5.sp,
                                        lineHeight = 20.sp,
                                        color = mutedInk.copy(alpha = 0.55f),
                                    )
                                }
                                BasicTextField(
                                    value = notesDraft,
                                    onValueChange = { notesDraft = it },
                                    textStyle = MaterialTheme.typography.bodyMedium.copy(
                                        fontSize = 14.5.sp,
                                        lineHeight = 20.sp,
                                        color = MaterialTheme.colorScheme.onSurface,
                                    ),
                                    cursorBrush = SolidColor(accent),
                                    minLines = 1,
                                    maxLines = 8,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .semantics { contentDescription = notesLabel }
                                        .onFocusChanged { focus ->
                                            if (notesFocused && !focus.isFocused && notesDraft != state.notes) {
                                                viewModel.saveNotes(notesDraft)
                                            }
                                            notesFocused = focus.isFocused
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
                                            .clickable { viewModel.saveNotes(notesDraft) }
                                            .padding(horizontal = 6.dp, vertical = 2.dp),
                                    )
                                }
                            }
                        }
                    }
                }

                // Quiet action pills row (Emoji / Rename / + Project or + Section).
                item(key = "place-actions") {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = TaskCardMetrics.Margin, vertical = 2.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        if (destination is AreasProjectsDestination.Area) {
                            AreaEmojiButton(
                                emoji = state.emoji,
                                accessibilityLabel = actionTitle(RegistryActionIds.AREA_CHANGE_EMOJI, languageTag),
                                onClick = { emojiPickerOpen = true },
                            )
                            PlaceActionChip(
                                label = actionTitle(RegistryActionIds.AREA_NEW_PROJECT, languageTag),
                                isDark = isDark,
                                onClick = { dialog = PlacesDialog.CreateProject },
                            )
                        } else {
                            PlaceActionChip(
                                label = actionTitle(RegistryActionIds.SECTION_NEW, languageTag),
                                isDark = isDark,
                                onClick = { dialog = PlacesDialog.CreateSection },
                            )
                        }
                        PlaceActionChip(
                            label = actionTitle(destination.renameAction(), languageTag),
                            isDark = isDark,
                            onClick = { dialog = PlacesDialog.RenamePlace(state.title) },
                        )
                    }
                }

                if (destination is AreasProjectsDestination.Area) {
                    item(key = "projects-heading") {
                        Text(
                            text = surfaceText(RegistryPlacesScreenIds.AREA_PROJECTS_HEADING, "label", languageTag),
                            fontSize = 18.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = MaterialTheme.colorScheme.onSurface,
                            modifier = Modifier
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
                                modifier = Modifier.padding(horizontal = TaskCardMetrics.HeaderLeading, vertical = 4.dp),
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
                                position = cardPosition(index, state.projects.size),
                                isSelected = isDropTargeted,
                                isDark = isDark,
                                hasActiveTexture = hasActiveTexture,
                                modifier = dropMod,
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
                    item(key = "area-tasks-heading") {
                        Text(
                            text = surfaceText(RegistryPlacesScreenIds.TASKS_HEADING, "label", languageTag),
                            fontSize = 18.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = MaterialTheme.colorScheme.onSurface,
                            modifier = Modifier
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
                                modifier = Modifier.padding(horizontal = TaskCardMetrics.HeaderLeading, vertical = 4.dp),
                            )
                        }
                    } else {
                        val areaPositions = visibleAreaTasks.map(PlaceTaskRow::position)
                        itemsIndexed(visibleAreaTasks, key = { _, it -> "task:${it.id}" }) { index, task ->
                            PlaceTaskItem(
                                task = task,
                                position = cardPosition(index, visibleAreaTasks.size),
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
                                dropModifier = Modifier
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
                                        enabled = true,
                                        onDrop = { ids, before ->
                                            val newPositions = reorderPositions(areaPositions, index, before, ids.size)
                                            viewModel.reorderTasks(ids, newPositions)
                                        },
                                    ),
                            )
                        }
                    }
                    item(key = "area-quick-add") {
                        InlineGlassQuickAddRow(
                            draft = areaTaskDraft,
                            onDraftChange = { areaTaskDraft = it },
                            placeholder = actionTitle(RegistryActionIds.APP_QUICK_ADD, languageTag),
                            isDark = isDark,
                            hasActiveTexture = hasActiveTexture,
                            onAdd = {
                                viewModel.createTask(areaTaskDraft)
                                areaTaskDraft = ""
                            },
                        )
                    }
                }

                if (destination is AreasProjectsDestination.Project) {
                    item(key = "project-tasks-heading") {
                        Text(
                            text = surfaceText(RegistryPlacesScreenIds.TASKS_HEADING, "label", languageTag),
                            fontSize = 18.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = MaterialTheme.colorScheme.onSurface,
                            modifier = Modifier
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
                                modifier = Modifier.padding(horizontal = TaskCardMetrics.HeaderLeading, vertical = 4.dp),
                            )
                        }
                    }
                    if (visibleUnsectioned.isNotEmpty()) {
                        val projectPositions = visibleUnsectioned.map(PlaceTaskRow::position)
                        itemsIndexed(visibleUnsectioned, key = { _, it -> "task:${it.id}" }) { index, task ->
                            PlaceTaskItem(
                                task = task,
                                position = cardPosition(index, visibleUnsectioned.size),
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
                                dropModifier = Modifier
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
                                        enabled = true,
                                        onDrop = { ids, before ->
                                            val newPositions = reorderPositions(projectPositions, index, before, ids.size)
                                            viewModel.reorderTasks(ids, newPositions, targetHeadingId = null, updateHeading = true)
                                        },
                                    ),
                            )
                        }
                    }
                    item(key = "project-quick-add") {
                        InlineGlassQuickAddRow(
                            draft = projectTaskDraft,
                            onDraftChange = { projectTaskDraft = it },
                            placeholder = actionTitle(RegistryActionIds.APP_QUICK_ADD, languageTag),
                            isDark = isDark,
                            hasActiveTexture = hasActiveTexture,
                            onAdd = {
                                viewModel.createTask(projectTaskDraft)
                                projectTaskDraft = ""
                            },
                        )
                    }
                    item(key = "sections-heading") {
                        Text(
                            text = surfaceText(RegistryPlacesScreenIds.SECTIONS_HEADING, "label", languageTag),
                            fontSize = 18.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = MaterialTheme.colorScheme.onSurface,
                            modifier = Modifier.padding(
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
                                modifier = Modifier.padding(horizontal = TaskCardMetrics.HeaderLeading, vertical = 4.dp),
                            )
                        }
                    } else {
                        items(visibleSections, key = { "section:${it.id}" }) { section ->
                            PlaceSectionBlock(
                                projectId = destination.id,
                                section = section,
                                languageTag = languageTag,
                                completeTitle = completeTitle,
                                todayTitle = todayTitle,
                                todayTint = todayTint,
                                fadedTitle = fadedTitle,
                                isDark = isDark,
                                hasActiveTexture = hasActiveTexture,
                                taskDraft = sectionTaskDrafts[section.id].orEmpty(),
                                onTaskDraftChange = { value -> sectionTaskDrafts = sectionTaskDrafts + (section.id to value) },
                                onAddTask = {
                                    viewModel.createTask(sectionTaskDrafts[section.id].orEmpty(), section.id)
                                    sectionTaskDrafts = sectionTaskDrafts + (section.id to "")
                                },
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
                                onReorderToSection = { ids, newPositions ->
                                    viewModel.reorderTasks(ids, newPositions, targetHeadingId = section.id, updateHeading = true)
                                },
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
    }
}

@Composable
private fun PlaceActionChip(
    label: String,
    isDark: Boolean,
    onClick: () -> Unit,
) {
    val bg = if (isDark) Color.White.copy(alpha = 0.08f) else Color.White.copy(alpha = 0.72f)
    val border = if (isDark) Color.White.copy(alpha = 0.12f) else MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.45f)
    Box(
        modifier = Modifier
            .clip(CircleShape)
            .background(bg)
            .border(0.65.dp, border, CircleShape)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 6.dp),
    ) {
        Text(
            text = label,
            fontSize = 13.sp,
            fontWeight = FontWeight.Medium,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
        )
    }
}

/** Calm translucent glass inline `+ New task` input matching iOS card rhythm. */
@Composable
private fun InlineGlassQuickAddRow(
    draft: String,
    onDraftChange: (String) -> Unit,
    placeholder: String,
    isDark: Boolean,
    hasActiveTexture: Boolean,
    onAdd: () -> Unit,
) {
    val accent = MaterialTheme.colorScheme.primary
    val mutedInk = MaterialTheme.colorScheme.onSurfaceVariant
    TaskCardSlice(
        position = TaskCardPosition.Solo,
        isSelected = false,
        isDark = isDark,
        hasActiveTexture = hasActiveTexture,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = TaskCardMetrics.ContentInset, vertical = 10.dp),
        ) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier.width(TaskCardMetrics.LeadingColumnWidth),
            ) {
                PlusSmallGlyph(tint = if (draft.isNotBlank()) accent else mutedInk.copy(alpha = 0.7f), size = 14.dp)
            }
            Spacer(modifier = Modifier.width(TaskCardMetrics.IconTextGap))
            Box(modifier = Modifier.weight(1f)) {
                if (draft.isEmpty()) {
                    Text(
                        text = placeholder,
                        fontSize = 15.sp,
                        lineHeight = 20.sp,
                        color = mutedInk.copy(alpha = 0.60f),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                BasicTextField(
                    value = draft,
                    onValueChange = onDraftChange,
                    singleLine = true,
                    textStyle = MaterialTheme.typography.bodyLarge.copy(
                        fontSize = 15.sp,
                        lineHeight = 20.sp,
                        color = MaterialTheme.colorScheme.onSurface,
                    ),
                    cursorBrush = SolidColor(accent),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { if (draft.isNotBlank()) onAdd() }),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            if (draft.isNotBlank()) {
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = placeholder,
                    fontSize = 13.5.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = accent,
                    modifier = Modifier
                        .clip(RoundedCornerShape(8.dp))
                        .clickable(onClick = onAdd)
                        .padding(horizontal = 8.dp, vertical = 4.dp),
                )
            }
        }
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

@Composable
private fun PlaceSectionBlock(
    projectId: String,
    section: PlaceSectionRow,
    languageTag: String,
    completeTitle: String,
    todayTitle: String,
    todayTint: Color,
    fadedTitle: String,
    isDark: Boolean,
    hasActiveTexture: Boolean,
    taskDraft: String,
    onTaskDraftChange: (String) -> Unit,
    onAddTask: () -> Unit,
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
) {
    var menuOpen by remember(section.id) { mutableStateOf(false) }
    val mutedInk = MaterialTheme.colorScheme.onSurfaceVariant
    val destructiveRed = if (isDark) Color(0xFFFF453A) else Color(0xFFFF3B30)
    val menuBg = if (isDark) MaterialTheme.colorScheme.surfaceContainerHigh else Color(0xF7FFFFFF)

    Column {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
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
        if (section.tasks.isEmpty()) {
            Text(
                text = surfaceText(RegistryPlacesScreenIds.EMPTY_SECTION_TASKS, "title", languageTag),
                style = MaterialTheme.typography.bodyMedium,
                color = mutedInk,
                modifier = Modifier.padding(horizontal = TaskCardMetrics.HeaderLeading, vertical = 4.dp),
            )
        } else {
            val sectionPositions = section.tasks.map(PlaceTaskRow::position)
            section.tasks.forEachIndexed { index, task ->
                PlaceTaskItem(
                    task = task,
                    position = cardPosition(index, section.tasks.size),
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
                    dropModifier = Modifier
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
                            enabled = true,
                            onDrop = { ids, before ->
                                val newPositions = reorderPositions(sectionPositions, index, before, ids.size)
                                onReorderToSection(ids, newPositions)
                            },
                        ),
                )
            }
        }
        InlineGlassQuickAddRow(
            draft = taskDraft,
            onDraftChange = onTaskDraftChange,
            placeholder = actionTitle(RegistryActionIds.SECTION_NEW_TASK, languageTag),
            isDark = isDark,
            hasActiveTexture = hasActiveTexture,
            onAdd = onAddTask,
        )
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
