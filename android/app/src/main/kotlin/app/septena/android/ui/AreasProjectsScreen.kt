package app.septena.android.ui

import app.septena.ui.TaskRow
import app.septena.ui.TaskListItem
import app.septena.ui.TaskGroupHeader
import app.septena.core.generated.RegistryDestinationIds
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.HorizontalDivider
import androidx.compose.foundation.lazy.itemsIndexed
import app.septena.ui.taskCardSlice
import app.septena.ui.RegistryIcon
import app.septena.ui.LocalTaskListStyle
import androidx.compose.material3.ListItemDefaults
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import app.septena.android.AndroidAppGraph
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.stringValue
import app.septena.core.generated.RegistryActionIds
import app.septena.core.generated.RegistryIconIds
import app.septena.core.generated.RegistryPlacesScreenIds
import app.septena.core.generated.RegistryPromptIds
import app.septena.core.generated.RegistryTaskAttributeIds
import app.septena.ui.TaskSelection
import app.septena.ui.TaskRowMenuAction

/** Detail content for an area or project. The shell owns navigation and routes callbacks to these details. */
@Composable
fun AreasProjectsScreen(
    graph: AndroidAppGraph,
    destination: AreasProjectsDestination,
    modifier: Modifier = Modifier,
    onOpenProject: (String) -> Unit = {},
    onOpenTask: (String) -> Unit = {},
    rowMenuGroups: List<List<TaskRowMenuAction>> = emptyList(),
    rowMenuAccessibilityLabel: String = "",
    onTaskAction: (String, String) -> Unit = { _, _ -> },
    selection: TaskSelection = TaskSelection(),
    onComplete: (String) -> Unit = {},
) {
    val factory = remember(graph) { AreasProjectsViewModel.Factory(graph) }
    val viewModel: AreasProjectsViewModel = viewModel(key = destination.key, factory = factory)
    val state by viewModel.state.collectAsStateWithLifecycle()
    val languageTag = LocalConfiguration.current.locales[0].toLanguageTag()
    var dialog by remember { mutableStateOf<PlacesDialog?>(null) }
    var emojiPickerOpen by rememberSaveable(destination.key) { mutableStateOf(false) }
    var notesDraft by rememberSaveable(destination.key) { mutableStateOf("") }
    var areaTaskDraft by rememberSaveable(destination.key) { mutableStateOf("") }
    var projectTaskDraft by rememberSaveable(destination.key) { mutableStateOf("") }
    var sectionTaskDrafts by remember(destination.key) { mutableStateOf(emptyMap<String, String>()) }

    val rows = PlaceRowContext(
        completeTitle = actionTitle(RegistryActionIds.TASK_TOGGLE_COMPLETE, languageTag),
        todayTitle = RegistryCatalog.destinationTitle(RegistryDestinationIds.TODAY, languageTag).orEmpty(),
        onComplete = onComplete,
        onOpenTask = onOpenTask,
        rowMenuGroups = rowMenuGroups,
        rowMenuAccessibilityLabel = rowMenuAccessibilityLabel,
        selection = selection,
        onTaskAction = onTaskAction,
    )

    LaunchedEffect(destination) { viewModel.select(destination) }
    LaunchedEffect(state.destination, state.notes) { notesDraft = state.notes }

    Column(modifier = modifier.fillMaxSize()) {
        if (state.isLoading) {
            CircularProgressIndicator(modifier = Modifier.padding(24.dp))
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(horizontal = LocalTaskListStyle.current.pageGutter, vertical = 12.dp),
            ) {
                item(key = "place-title") {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        if (destination is AreasProjectsDestination.Area) {
                            AreaEmojiButton(
                                emoji = state.emoji,
                                accessibilityLabel = actionTitle(RegistryActionIds.AREA_CHANGE_EMOJI, languageTag),
                                onClick = { emojiPickerOpen = true },
                            )
                        }
                        Text(
                            state.title,
                            style = MaterialTheme.typography.headlineMedium,
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.weight(1f),
                        )
                        TextButton(onClick = { dialog = PlacesDialog.RenamePlace(state.title) }) {
                            Text(actionTitle(destination.renameAction(), languageTag))
                        }
                    }
                }
                item(key = "place-notes") {
                    OutlinedTextField(
                        value = notesDraft,
                        onValueChange = { notesDraft = it },
                        modifier = Modifier.fillMaxWidth(),
                        label = { Text(surfaceText(RegistryTaskAttributeIds.NOTES, "label", languageTag)) },
                        minLines = 2,
                    )
                }
                item(key = "save-notes") {
                    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                        TextButton(onClick = { viewModel.saveNotes(notesDraft) }) {
                            Text(actionTitle(RegistryActionIds.PLACE_SAVE_NOTES, languageTag))
                        }
                    }
                }

                if (destination is AreasProjectsDestination.Area) {
                    item(key = "projects-heading") {
                        TaskGroupHeader(surfaceText(RegistryPlacesScreenIds.AREA_PROJECTS_HEADING, "label", languageTag), Modifier.padding(top = 18.dp, bottom = 6.dp))
                    }
                    item(key = "new-project") {
                        Button(onClick = { dialog = PlacesDialog.CreateProject }) {
                            Text(actionTitle(RegistryActionIds.AREA_NEW_PROJECT, languageTag))
                        }
                    }
                    if (state.projects.isEmpty()) {
                        item(key = "projects-empty") {
                            Text(surfaceText(RegistryPlacesScreenIds.EMPTY_AREA_PROJECTS, "title", languageTag))
                        }
                    } else {
                        items(state.projects, key = { "project:${it.id}" }) { project ->
                            ListItem(
                                headlineContent = { Text(project.title) },
                                leadingContent = {
                                    RegistryIcon(
                                        RegistryIconIds.PLACE_PROJECT,
                                        contentDescription = null,
                                        tint = glyphTint(RegistryIconIds.PLACE_PROJECT),
                                    )
                                },
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .taskCardSlice(first = true, last = true, gutter = 0.dp)
                                    .clickable { onOpenProject(project.id) },
                                colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                            )
                        }
                    }
                    item(key = "area-tasks-heading") {
                        TaskGroupHeader(surfaceText(RegistryPlacesScreenIds.TASKS_HEADING, "label", languageTag), Modifier.padding(top = 18.dp, bottom = 6.dp))
                    }
                    item(key = "area-quick-add") {
                        QuickAddRow(
                            draft = areaTaskDraft,
                            onDraftChange = { areaTaskDraft = it },
                            title = actionTitle(RegistryActionIds.APP_QUICK_ADD, languageTag),
                            onAdd = {
                                viewModel.createTask(areaTaskDraft)
                                areaTaskDraft = ""
                            },
                        )
                    }
                    if (state.areaTasks.isEmpty()) {
                        item(key = "area-tasks-empty") {
                            Text(surfaceText(RegistryPlacesScreenIds.EMPTY_AREA_TASKS, "title", languageTag))
                        }
                    } else {
                        itemsIndexed(state.areaTasks, key = { _, it -> "task:${it.id}" }) { index, task ->
                            PlaceTaskItem(task, rows, first = index == 0, last = index == state.areaTasks.lastIndex)
                        }
                    }
                }

                if (destination is AreasProjectsDestination.Project) {
                    item(key = "sections-heading") {
                        TaskGroupHeader(surfaceText(RegistryPlacesScreenIds.SECTIONS_HEADING, "label", languageTag), Modifier.padding(top = 18.dp, bottom = 6.dp))
                    }
                    item(key = "new-section") {
                        Button(onClick = { dialog = PlacesDialog.CreateSection }) {
                            Text(actionTitle(RegistryActionIds.SECTION_NEW, languageTag))
                        }
                    }
                    item(key = "project-tasks-heading") {
                        TaskGroupHeader(surfaceText(RegistryPlacesScreenIds.TASKS_HEADING, "label", languageTag), Modifier.padding(top = 18.dp, bottom = 6.dp))
                    }
                    item(key = "project-quick-add") {
                        QuickAddRow(
                            draft = projectTaskDraft,
                            onDraftChange = { projectTaskDraft = it },
                            title = actionTitle(RegistryActionIds.APP_QUICK_ADD, languageTag),
                            onAdd = {
                                viewModel.createTask(projectTaskDraft)
                                projectTaskDraft = ""
                            },
                        )
                    }
                    if (state.unsectionedTasks.isEmpty() && state.sections.isEmpty()) {
                        item(key = "project-tasks-empty") {
                            Text(surfaceText(RegistryPlacesScreenIds.EMPTY_PROJECT_TASKS, "title", languageTag))
                        }
                    }
                    if (state.unsectionedTasks.isNotEmpty()) {
                        itemsIndexed(state.unsectionedTasks, key = { _, it -> "task:${it.id}" }) { index, task ->
                            PlaceTaskItem(task, rows, first = index == 0, last = index == state.unsectionedTasks.lastIndex)
                        }
                    }
                    if (state.sections.isEmpty()) {
                        item(key = "project-sections-empty") {
                            Text(surfaceText(RegistryPlacesScreenIds.EMPTY_PROJECT_SECTIONS, "title", languageTag))
                        }
                    } else {
                        items(state.sections, key = { "section:${it.id}" }) { section ->
                            PlaceSectionBlock(
                                section = section,
                                languageTag = languageTag,
                                taskDraft = sectionTaskDrafts[section.id].orEmpty(),
                                onTaskDraftChange = { value -> sectionTaskDrafts = sectionTaskDrafts + (section.id to value) },
                                onAddTask = {
                                    viewModel.createTask(sectionTaskDrafts[section.id].orEmpty(), section.id)
                                    sectionTaskDrafts = sectionTaskDrafts + (section.id to "")
                                },
                                rows = rows,
                                onRename = { dialog = PlacesDialog.RenameSection(section.id, section.title) },
                                onDelete = { dialog = PlacesDialog.DeleteSection(section.id) },
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
private fun QuickAddRow(
    draft: String,
    onDraftChange: (String) -> Unit,
    title: String,
    onAdd: () -> Unit,
) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        OutlinedTextField(
            value = draft,
            onValueChange = onDraftChange,
            modifier = Modifier.weight(1f),
            singleLine = true,
            label = { Text(title) },
        )
        Button(enabled = draft.isNotBlank(), onClick = onAdd) { Text(title) }
    }
}

/** What a place's task rows need from the shell. */
private class PlaceRowContext(
    val completeTitle: String,
    val todayTitle: String,
    val onComplete: (String) -> Unit,
    val onOpenTask: (String) -> Unit,
    val rowMenuGroups: List<List<TaskRowMenuAction>>,
    val rowMenuAccessibilityLabel: String,
    val selection: TaskSelection,
    val onTaskAction: (String, String) -> Unit,
)

/** The shared task row, on its own card: the place's gutter is the list padding. */
@Composable
private fun PlaceTaskItem(task: TaskListItem, rows: PlaceRowContext, first: Boolean, last: Boolean) {
    Column(
        modifier = Modifier.taskCardSlice(
            first = first,
            last = last,
            selected = task.id in rows.selection.selectedIds,
            gutter = 0.dp,
        ),
    ) {
        TaskRow(
            task = task,
            completeTitle = rows.completeTitle,
            canComplete = true,
            todayTitle = rows.todayTitle,
            todayTint = MaterialTheme.colorScheme.secondary,
            showTodayIndicator = true,
            onComplete = rows.onComplete,
            onOpenTask = rows.onOpenTask,
            rowMenuGroups = rows.rowMenuGroups,
            rowMenuAccessibilityLabel = rows.rowMenuAccessibilityLabel,
            selection = rows.selection,
            rowMenuIcon = RegistryIconIds.ACTION_MORE,
            onTaskAction = rows.onTaskAction,
        )
        if (!last) {
            HorizontalDivider(
                modifier = Modifier.padding(start = 48.dp),
                color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.55f),
            )
        }
    }
}

@Composable
private fun PlaceSectionBlock(
    section: PlaceSectionRow,
    languageTag: String,
    taskDraft: String,
    onTaskDraftChange: (String) -> Unit,
    onAddTask: () -> Unit,
    rows: PlaceRowContext,
    onRename: () -> Unit,
    onDelete: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            TaskGroupHeader(section.title, Modifier.weight(1f).padding(top = 18.dp, bottom = 6.dp))
            TextButton(onClick = onRename) {
                Text(actionTitle(RegistryActionIds.SECTION_RENAME, languageTag))
            }
            TextButton(onClick = onDelete) {
                Text(actionTitle(RegistryActionIds.SECTION_DELETE, languageTag))
            }
        }
        if (section.tasks.isEmpty()) {
            Text(surfaceText(RegistryPlacesScreenIds.EMPTY_SECTION_TASKS, "title", languageTag), modifier = Modifier.padding(start = 12.dp))
        } else {
            Column {
                section.tasks.forEachIndexed { index, task ->
                    PlaceTaskItem(task, rows, first = index == 0, last = index == section.tasks.lastIndex)
                }
            }
        }
        QuickAddRow(
            draft = taskDraft,
            onDraftChange = onTaskDraftChange,
            title = actionTitle(RegistryActionIds.SECTION_NEW_TASK, languageTag),
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
