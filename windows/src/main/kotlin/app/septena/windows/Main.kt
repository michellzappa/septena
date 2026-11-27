package app.septena.windows

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import app.septena.core.RegistryCatalog
import app.septena.core.QuickFindSearch
import app.septena.core.QuickFindTarget
import app.septena.core.SystemDayClock
import app.septena.core.TaskRecord
import app.septena.core.asTaskRecord
import app.septena.core.generated.RegistryActionIds
import app.septena.core.generated.RegistryDestinationIds
import app.septena.core.generated.RegistryPlacesScreenIds
import app.septena.core.generated.RegistryPromptIds
import app.septena.core.generated.RegistrySurfaceIds
import app.septena.core.stringValue
import app.septena.ui.TaskHomeContent
import app.septena.ui.TaskMenuActionIcon
import app.septena.ui.TaskRowMenuAction
import app.septena.windows.platform.DesktopHost
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.nio.file.Files
import java.util.Locale

fun main() {
    val host = DesktopHost.current()
    val directory = Files.createTempDirectory("septena-spike-")
    val clock = SystemDayClock()
    val transport = FixtureTransport(clock)
    try {
        SpikeWorkspace(directory.resolve("tasks.db"), transport, clock, host.identity).use { workspace ->
            application(exitProcessOnExit = false) {
                var busy by remember { mutableStateOf(false) }
                var findRequests by remember { mutableStateOf(0) }
                Window(
                    onCloseRequest = { if (!busy) exitApplication() },
                    title = "Septena Spike",
                    onPreviewKeyEvent = { event ->
                        if (!busy && event.opensQuickFind()) {
                            findRequests++
                            true
                        } else false
                    },
                ) {
                    MaterialTheme {
                        Surface(Modifier.fillMaxSize()) {
                            DesktopTasks(workspace, transport, findRequests, onBusyChange = { busy = it })
                        }
                    }
                }
            }
        }
    } finally {
        directory.toFile().deleteRecursively()
    }
}

private data class NameEditor(
    val title: String,
    val fieldLabel: String,
    val confirmTitle: String,
    val initialValue: String = "",
    val save: suspend (String) -> DesktopLocation?,
)

@Composable
private fun DesktopTasks(
    workspace: SpikeWorkspace,
    transport: FixtureTransport,
    findRequests: Int,
    onBusyChange: (Boolean) -> Unit,
) {
    val scope = rememberCoroutineScope()
    val languageTag = remember { Locale.getDefault().toLanguageTag() }
    val today = DesktopLocation.Smart(RegistryDestinationIds.TODAY)
    var destination by remember { mutableStateOf<DesktopLocation>(today) }
    var lists by remember { mutableStateOf(DesktopTaskLists()) }
    var editor by remember { mutableStateOf<NameEditor?>(null) }
    var editingTask by remember { mutableStateOf<Pair<TaskRecord, DesktopConversation>?>(null) }
    var movingTask by remember { mutableStateOf<String?>(null) }
    var quickFind by remember { mutableStateOf<QuickFindSearch?>(null) }
    var status by remember { mutableStateOf("Loading fixture") }
    var error by remember { mutableStateOf<String?>(null) }
    var online by remember { mutableStateOf(true) }
    var busy by remember { mutableStateOf(false) }
    var loaded by remember { mutableStateOf(false) }
    val undo by workspace.undoState.collectAsState()

    fun <T> work(action: suspend () -> T, refresh: Boolean = true, onSuccess: (T) -> Unit = {}) {
        if (busy) return
        busy = true
        onBusyChange(true)
        error = null
        scope.launch {
            try {
                val (result, rows) = withContext(Dispatchers.IO) {
                    val result = action()
                    result to if (refresh) workspace.lists(languageTag) else null
                }
                if (rows != null) {
                    lists = rows
                    if (destination !is DesktopLocation.Smart && rows.places.place(destination) == null) {
                        destination = today
                    }
                    loaded = true
                }
                onSuccess(result)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                error = failure.message ?: localized("Could not save changes.", languageTag)
            } finally {
                busy = false
                onBusyChange(false)
            }
        }
    }

    fun openEditor(value: NameEditor) {
        error = null
        editor = value
    }

    fun openTask(id: String, hit: QuickFindTarget.Task? = null) {
        work({
            checkNotNull(workspace.task(id)?.takeIf { it.deletedAt == null }) {
                localized("Task is no longer available.", languageTag)
            }.asTaskRecord() to workspace.conversation(id)
        }, refresh = false) { selected ->
            hit?.let { target -> quickFindTaskLocation(target, selected.first, lists)?.let { destination = it } }
            editingTask = selected
        }
    }

    fun openQuickFind() {
        if (!loaded || editor != null || editingTask != null || movingTask != null || quickFind != null) return
        work({ workspace.quickFindSnapshot() }, refresh = false) { quickFind = it }
    }

    LaunchedEffect(Unit) {
        work({ workspace.sync() }) { status = "Fixture connected" }
    }
    LaunchedEffect(findRequests) {
        if (findRequests > 0) openQuickFind()
    }

    val smart = destination as? DesktopLocation.Smart
    val place = lists.places.place(destination)
    val project = when (val selected = destination) {
        is DesktopLocation.Project -> selected
        is DesktopLocation.Section -> DesktopLocation.Project(selected.projectId)
        else -> null
    }
    val outline = lists.places.outline()
    val isToday = destination == today
    val rows = lists.rows(destination)
    val inbox = if (isToday) lists.inbox else emptyList()
    val newTaskTitle = actionTitle(RegistryActionIds.APP_NEW_TASK, languageTag)
    val canAdd = loaded && (place != null || smart?.let { RegistryCatalog.destinationSupportsInlineCreate(it.id) } == true)
    val moveTitle = actionTitle(RegistryActionIds.TASK_MOVE, languageTag)
    val moveAction = TaskRowMenuAction(RegistryActionIds.TASK_MOVE, moveTitle, icon = TaskMenuActionIcon.Move)

    Row(Modifier.fillMaxSize()) {
        Column(Modifier.width(212.dp).padding(8.dp)) {
            LazyColumn(Modifier.weight(1f)) {
                items(desktopDestinations, key = { "smart:$it" }) { id ->
                    val target = DesktopLocation.Smart(id)
                    NavigationDrawerItem(
                        selected = target == destination,
                        onClick = { destination = target },
                        label = { Text(RegistryCatalog.destinationTitle(id, languageTag).orEmpty()) },
                    )
                }
                items(outline, key = { it.location.key() }) { item ->
                    NavigationDrawerItem(
                        selected = item.location == destination,
                        onClick = { destination = item.location },
                        label = { Text(item.title) },
                        modifier = Modifier.padding(start = placeIndent(item).dp),
                    )
                }
            }
            TextButton(enabled = loaded && !busy, onClick = {
                openEditor(placeEditor(RegistryPromptIds.NEW_AREA, languageTag, save = workspace::addArea))
            }) { Text(actionTitle(RegistryActionIds.SIDEBAR_NEW_AREA, languageTag)) }
            TextButton(enabled = loaded && !busy, onClick = {
                val area = destination as? DesktopLocation.Area
                openEditor(placeEditor(RegistryPromptIds.NEW_PROJECT, languageTag) { title ->
                    workspace.addProject(title, area)
                })
            }) { Text(actionTitle(RegistryActionIds.SIDEBAR_NEW_PROJECT, languageTag)) }
        }
        Column(Modifier.weight(1f).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (place != null) {
                Text(place.title, style = MaterialTheme.typography.headlineSmall)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                TextButton(enabled = loaded && !busy, onClick = { openQuickFind() }) {
                    Text(actionTitle(RegistryActionIds.APP_QUICK_FIND, languageTag))
                }
                if (canAdd) {
                    Button(enabled = !busy, onClick = {
                        val target = destination
                        openEditor(NameEditor(newTaskTitle, localized("Title", languageTag), localized("Add", languageTag)) { title ->
                            workspace.add(title, target)
                            null
                        })
                    }) { Text(newTaskTitle) }
                }
                if (project != null) {
                    TextButton(enabled = !busy, onClick = {
                        openEditor(placeEditor(RegistryPromptIds.NEW_SECTION, languageTag) { title ->
                            workspace.addSection(title, project)
                        })
                    }) { Text(actionTitle(RegistryActionIds.SECTION_NEW, languageTag)) }
                }
                if (place != null) {
                    TextButton(enabled = !busy, onClick = {
                        val prompt = when (place.location) {
                            is DesktopLocation.Area -> RegistryPromptIds.RENAME_AREA
                            is DesktopLocation.Project -> RegistryPromptIds.RENAME_PROJECT
                            is DesktopLocation.Section -> RegistryPromptIds.RENAME_SECTION
                            is DesktopLocation.Smart -> error("Expected an area, project, or section")
                        }
                        openEditor(placeEditor(prompt, languageTag, place.title) { title ->
                            workspace.renamePlace(place.location, title)
                            null
                        })
                    }) { Text(localized("Rename", languageTag)) }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(enabled = !busy, onClick = {
                    online = !online
                    transport.online = online
                    error = null
                    status = if (online) "Fixture online" else "Fixture offline"
                }) { Text(if (online) "Go offline" else "Go online") }
                TextButton(enabled = !busy, onClick = {
                    work({ workspace.sync() }) { status = "Writes sent: ${it.pushedOperations}" }
                }) { Text("Sync") }
                TextButton(enabled = !busy && undo.canUndo, onClick = {
                    work({ workspace.undo() }) { changed ->
                        if (changed) status = "Undo saved to the outbox"
                    }
                }) { Text(actionTitle(RegistryActionIds.APP_UNDO, languageTag)) }
            }
            if (loaded) {
                val pauseLabel = RegistryCatalog.actionTitle(
                    RegistryActionIds.APP_PAUSE_AGENTS,
                    if (lists.agentsPaused) "activeTitle" else "title",
                    languageTag,
                ).orEmpty()
                TextButton(enabled = !busy, onClick = {
                    val pause = !lists.agentsPaused
                    work({ workspace.setAgentsPaused(pause) })
                }) { Text(pauseLabel) }
            }
            Text(status, style = MaterialTheme.typography.bodySmall)
            TaskHomeContent(
                completeTitle = actionTitle(RegistryActionIds.TASK_TOGGLE_COMPLETE, languageTag),
                emptyTitle = emptyTitleFor(destination, languageTag),
                emptyDescription = smart?.let { RegistryCatalog.destinationEmptyDetail(it.id, languageTag) }.orEmpty(),
                inboxBandTitle = RegistryCatalog.destinationTitle(RegistryDestinationIds.INBOX, languageTag).orEmpty(),
                todayTitle = RegistryCatalog.destinationTitle(RegistryDestinationIds.TODAY, languageTag).orEmpty(),
                todayTint = MaterialTheme.colorScheme.secondary,
                hasLoaded = loaded,
                isToday = isToday,
                isUpcoming = smart?.id == RegistryDestinationIds.UPCOMING,
                inboxTasks = inbox,
                tasks = rows,
                canQuickAdd = canAdd,
                canComplete = true,
                errorMessage = error,
                rowMenuGroups = listOf(listOf(moveAction)),
                rowMenuAccessibilityLabel = surfaceLabel(RegistrySurfaceIds.TASK_ROW_MENU, "accessibilityLabel", languageTag),
                listKey = destination,
                onComplete = { id ->
                    work({
                        checkNotNull(workspace.complete(id)) { localized("Task is no longer available.", languageTag) }
                    }) { status = "Task saved to the outbox" }
                },
                onOpenTask = { id -> openTask(id) },
                onTaskAction = { id, action ->
                    if (!busy && action == RegistryActionIds.TASK_MOVE) {
                        error = null
                        movingTask = id
                    }
                },
                onOpenGroupTarget = project?.let { current -> { id -> destination = DesktopLocation.Section(current.id, id) } },
            )
        }
    }

    quickFind?.let { search ->
        DesktopQuickFind(search, languageTag, onClose = { quickFind = null }) { target ->
            quickFind = null
            when (target) {
                is QuickFindTarget.Area -> destination = DesktopLocation.Area(target.areaId)
                is QuickFindTarget.Project -> destination = DesktopLocation.Project(target.projectId)
                is QuickFindTarget.Task -> openTask(target.taskId, target)
            }
        }
    }
    editor?.let { edit ->
        EditNameDialog(edit, busy, error, languageTag, onDismiss = { editor = null }) { value ->
            work({ edit.save(value) }) { next ->
                if (next != null) destination = next
                editor = null
                status = "Saved to the outbox"
            }
        }
    }
    editingTask?.let { (task, thread) ->
        DesktopTaskEditor(
            task, thread, workspace.today(), workspace.now(), languageTag, busy, error, onDismiss = { editingTask = null },
        ) { change, done ->
            work({
                val updated = when (change) {
                    is DesktopTaskEdit.Text -> workspace.saveText(task, change.title, change.notes)
                    is DesktopTaskEdit.When -> workspace.setWhen(task.id, change.day, change.mode)
                    is DesktopTaskEdit.Deadline -> workspace.setDeadline(task.id, change.day)
                    is DesktopTaskEdit.Repeat -> workspace.setRepeat(task.id, change.rule, change.paused)
                    is DesktopTaskEdit.Conversation -> {
                        workspace.changeConversation(task.id, change.edit)
                        checkNotNull(workspace.task(task.id)).asTaskRecord()
                    }
                }
                updated to workspace.conversation(task.id)
            }) { updated ->
                editingTask = updated
                status = "Task saved to the outbox"
                done()
            }
        }
    }
    movingTask?.let { id ->
        MoveTaskDialog(outline, busy, error, languageTag, onDismiss = { movingTask = null }) { target ->
            work({ workspace.move(id, target) }) {
                movingTask = null
                status = "Task saved to the outbox"
            }
        }
    }
}

@Composable
private fun EditNameDialog(
    edit: NameEditor,
    busy: Boolean,
    error: String?,
    languageTag: String,
    onDismiss: () -> Unit,
    onSave: (String) -> Unit,
) {
    var title by remember(edit) { mutableStateOf(edit.initialValue) }
    AlertDialog(
        onDismissRequest = { if (!busy) onDismiss() },
        title = { Text(edit.title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = title,
                    onValueChange = { title = it },
                    enabled = !busy,
                    singleLine = true,
                    label = { Text(edit.fieldLabel) },
                    modifier = Modifier.fillMaxWidth(),
                )
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            Button(
                enabled = !busy && title.isNotBlank() && title.trim() != edit.initialValue,
                onClick = { onSave(title) },
            ) { Text(edit.confirmTitle) }
        },
        dismissButton = {
            TextButton(enabled = !busy, onClick = onDismiss) { Text(localized("Cancel", languageTag)) }
        },
    )
}

@Composable
private fun MoveTaskDialog(
    places: List<DesktopPlace>,
    busy: Boolean,
    error: String?,
    languageTag: String,
    onDismiss: () -> Unit,
    onMove: (DesktopLocation) -> Unit,
) {
    val inbox = DesktopPlace(
        DesktopLocation.Smart(RegistryDestinationIds.INBOX),
        RegistryCatalog.destinationTitle(RegistryDestinationIds.INBOX, languageTag).orEmpty(),
    )
    AlertDialog(
        onDismissRequest = { if (!busy) onDismiss() },
        title = { Text(actionTitle(RegistryActionIds.TASK_MOVE, languageTag)) },
        text = {
            Column {
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                LazyColumn(Modifier.heightIn(max = 320.dp)) {
                    items(listOf(inbox) + places, key = { it.location.key() }) { destination ->
                        ListItem(
                            headlineContent = { Text(destination.title) },
                            modifier = Modifier
                                .clickable(enabled = !busy) { onMove(destination.location) }
                                .padding(start = placeIndent(destination).dp),
                        )
                    }
                }
            }
        },
        confirmButton = {
            TextButton(enabled = !busy, onClick = onDismiss) { Text(localized("Cancel", languageTag)) }
        },
    )
}

private fun placeIndent(place: DesktopPlace): Int = when {
    place.location is DesktopLocation.Section -> 28
    place.areaId != null -> 14
    else -> 0
}

private fun emptyTitleFor(location: DesktopLocation, languageTag: String): String = when (location) {
    is DesktopLocation.Smart -> RegistryCatalog.destinationEmptyTitle(location.id, languageTag).orEmpty()
    is DesktopLocation.Area -> surfaceLabel(RegistryPlacesScreenIds.EMPTY_AREA_TASKS, "title", languageTag)
    is DesktopLocation.Project -> surfaceLabel(RegistryPlacesScreenIds.EMPTY_PROJECT_TASKS, "title", languageTag)
    is DesktopLocation.Section -> surfaceLabel(RegistryPlacesScreenIds.EMPTY_SECTION_TASKS, "title", languageTag)
}

private fun placeEditor(
    prompt: String,
    languageTag: String,
    initialValue: String = "",
    save: suspend (String) -> DesktopLocation?,
): NameEditor = NameEditor(
    title = surfaceLabel(prompt, "title", languageTag),
    fieldLabel = surfaceLabel(prompt, "placeholder", languageTag),
    confirmTitle = surfaceLabel(prompt, "confirmTitle", languageTag),
    initialValue = initialValue,
    save = save,
)

private fun surfaceLabel(id: String, field: String, languageTag: String): String =
    RegistryCatalog.surface(id)?.get(field).stringValue()?.let { localized(it, languageTag) }.orEmpty()

private fun actionTitle(id: String, languageTag: String): String =
    RegistryCatalog.actionTitle(id, languageTag = languageTag).orEmpty()

private fun localized(label: String, languageTag: String): String =
    RegistryCatalog.localizedString(label, languageTag) ?: label
