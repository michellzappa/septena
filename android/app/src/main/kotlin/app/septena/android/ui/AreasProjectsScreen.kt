package app.septena.android.ui

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
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import app.septena.android.AndroidAppGraph
import app.septena.core.RegistryCatalog
import app.septena.core.stringValue
import app.septena.core.generated.RegistryActionIds

/** Detail content for an area or project. The shell owns navigation and routes callbacks to these details. */
@Composable
fun AreasProjectsScreen(
    graph: AndroidAppGraph,
    destination: AreasProjectsDestination,
    modifier: Modifier = Modifier,
    onOpenProject: (String) -> Unit = {},
    onOpenTask: (String) -> Unit = {},
) {
    val factory = remember(graph) { AreasProjectsViewModel.Factory(graph) }
    val viewModel: AreasProjectsViewModel = viewModel(key = destination.key, factory = factory)
    val state by viewModel.state.collectAsStateWithLifecycle()
    val languageTag = LocalConfiguration.current.locales[0].toLanguageTag()
    var dialog by remember { mutableStateOf<PlacesDialog?>(null) }
    var notesDraft by rememberSaveable(destination.key) { mutableStateOf("") }
    var areaTaskDraft by rememberSaveable(destination.key) { mutableStateOf("") }
    var projectTaskDraft by rememberSaveable(destination.key) { mutableStateOf("") }
    var sectionTaskDrafts by remember(destination.key) { mutableStateOf(emptyMap<String, String>()) }

    LaunchedEffect(destination) { viewModel.select(destination) }
    LaunchedEffect(state.destination, state.notes) { notesDraft = state.notes }

    Column(modifier = modifier.fillMaxSize()) {
        if (state.isLoading) {
            CircularProgressIndicator(modifier = Modifier.padding(24.dp))
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                item(key = "place-title") {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text(state.title, modifier = Modifier.weight(1f))
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
                        label = { Text(localized("Notes", languageTag)) },
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
                        Text(surfaceText("areaProjectsHeading", "label", languageTag))
                    }
                    item(key = "new-project") {
                        Button(onClick = { dialog = PlacesDialog.CreateProject }) {
                            Text(actionTitle(RegistryActionIds.AREA_NEW_PROJECT, languageTag))
                        }
                    }
                    if (state.projects.isEmpty()) {
                        item(key = "projects-empty") {
                            Text(surfaceText("emptyAreaProjects", "title", languageTag))
                        }
                    } else {
                        items(state.projects, key = { "project:${it.id}" }) { project ->
                            ListItem(
                                headlineContent = { Text(project.title) },
                                modifier = Modifier.fillMaxWidth().clickable { onOpenProject(project.id) },
                            )
                        }
                    }
                    item(key = "area-tasks-heading") {
                        Text(surfaceText("tasksHeading", "label", languageTag))
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
                            Text(surfaceText("emptyAreaTasks", "title", languageTag))
                        }
                    } else {
                        items(state.areaTasks, key = { "task:${it.id}" }) { task ->
                            PlaceTaskItem(task = task, onOpenTask = onOpenTask)
                        }
                    }
                }

                if (destination is AreasProjectsDestination.Project) {
                    item(key = "sections-heading") {
                        Text(surfaceText("sectionsHeading", "label", languageTag))
                    }
                    item(key = "new-section") {
                        Button(onClick = { dialog = PlacesDialog.CreateSection }) {
                            Text(actionTitle(RegistryActionIds.SECTION_NEW, languageTag))
                        }
                    }
                    item(key = "project-tasks-heading") {
                        Text(surfaceText("tasksHeading", "label", languageTag))
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
                            Text(surfaceText("emptyProjectTasks", "title", languageTag))
                        }
                    }
                    if (state.unsectionedTasks.isNotEmpty()) {
                        items(state.unsectionedTasks, key = { "task:${it.id}" }) { task ->
                            PlaceTaskItem(task = task, onOpenTask = onOpenTask)
                        }
                    }
                    if (state.sections.isEmpty()) {
                        item(key = "project-sections-empty") {
                            Text(surfaceText("emptyProjectSections", "title", languageTag))
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
                                onOpenTask = onOpenTask,
                                onRename = { dialog = PlacesDialog.RenameSection(section.id, section.title) },
                                onDelete = { dialog = PlacesDialog.DeleteSection(section.id) },
                            )
                        }
                    }
                }
            }
        }
    }

    state.errorMessage?.let { message ->
        AlertDialog(
            onDismissRequest = viewModel::clearError,
            title = { Text(localized("Error", languageTag)) },
            text = { Text(RegistryCatalog.localizedString(message, languageTag) ?: message) },
            confirmButton = {
                TextButton(onClick = viewModel::clearError) { Text(localized("OK", languageTag)) }
            },
        )
    }

    when (val active = dialog) {
        null -> Unit
        PlacesDialog.CreateProject -> TextEntryDialog(
            promptId = "newProject",
            languageTag = languageTag,
            onDismiss = { dialog = null },
            onConfirm = { viewModel.createProject(it); dialog = null },
        )
        PlacesDialog.CreateSection -> TextEntryDialog(
            promptId = "newSection",
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
            promptId = "renameSection",
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

@Composable
private fun PlaceTaskItem(task: PlaceTaskRow, onOpenTask: (String) -> Unit) {
    ListItem(
        headlineContent = { Text(task.title) },
        modifier = Modifier.fillMaxWidth().clickable { onOpenTask(task.id) },
    )
}

@Composable
private fun PlaceSectionBlock(
    section: PlaceSectionRow,
    languageTag: String,
    taskDraft: String,
    onTaskDraftChange: (String) -> Unit,
    onAddTask: () -> Unit,
    onOpenTask: (String) -> Unit,
    onRename: () -> Unit,
    onDelete: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(section.title, modifier = Modifier.weight(1f))
            TextButton(onClick = onRename) {
                Text(actionTitle(RegistryActionIds.SECTION_RENAME, languageTag))
            }
            TextButton(onClick = onDelete) {
                Text(actionTitle(RegistryActionIds.SECTION_DELETE, languageTag))
            }
        }
        if (section.tasks.isEmpty()) {
            Text(surfaceText("emptySectionTasks", "title", languageTag), modifier = Modifier.padding(start = 12.dp))
        } else {
            section.tasks.forEach { task -> PlaceTaskItem(task, onOpenTask) }
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
            TextButton(onClick = onDismiss) { Text(localized("Cancel", languageTag)) }
        },
    )
}

@Composable
private fun DeleteSectionDialog(
    languageTag: String,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    val copy = remember(languageTag) { surfacePrompt("deleteSection", languageTag) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(copy.title) },
        text = { Text(copy.message) },
        confirmButton = {
            TextButton(onClick = onConfirm) { Text(copy.confirmTitle) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(localized("Cancel", languageTag)) }
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

private fun actionTitle(id: String, languageTag: String): String =
    RegistryCatalog.actionTitle(id, languageTag = languageTag).orEmpty()

private fun localized(value: String, languageTag: String): String =
    RegistryCatalog.localizedString(value, languageTag) ?: value

private fun String?.registryLocalized(languageTag: String): String =
    this?.let { RegistryCatalog.localizedString(it, languageTag) ?: it }.orEmpty()

private fun AreasProjectsDestination.renameAction(): String = when (this) {
    is AreasProjectsDestination.Area -> RegistryActionIds.AREA_RENAME
    is AreasProjectsDestination.Project -> RegistryActionIds.PROJECT_RENAME
}

private fun AreasProjectsDestination.renamePrompt(): String = when (this) {
    is AreasProjectsDestination.Area -> "renameArea"
    is AreasProjectsDestination.Project -> "renameProject"
}
