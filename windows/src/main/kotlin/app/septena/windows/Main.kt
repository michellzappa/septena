package app.septena.windows

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
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
import app.septena.core.SystemDayClock
import app.septena.core.generated.RegistryActionIds
import app.septena.core.generated.RegistryDestinationIds
import app.septena.ui.TaskHomeContent
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.nio.file.Files
import java.util.Locale

fun main() {
    val directory = Files.createTempDirectory("septena-spike-")
    val clock = SystemDayClock()
    val transport = FixtureTransport(clock)
    try {
        SpikeWorkspace(directory.resolve("tasks.db"), transport, clock).use { workspace ->
            application(exitProcessOnExit = false) {
                var busy by remember { mutableStateOf(false) }
                Window(onCloseRequest = { if (!busy) exitApplication() }, title = "Septena Spike") {
                    MaterialTheme {
                        Surface(Modifier.fillMaxSize()) {
                            DesktopTasks(workspace, transport, onBusyChange = { busy = it })
                        }
                    }
                }
            }
        }
    } finally {
        directory.toFile().deleteRecursively()
    }
}

private data class EditTask(val title: String = "", val id: String? = null)

@Composable
private fun DesktopTasks(workspace: SpikeWorkspace, transport: FixtureTransport, onBusyChange: (Boolean) -> Unit) {
    val scope = rememberCoroutineScope()
    val languageTag = remember { Locale.getDefault().toLanguageTag() }
    var destination by remember { mutableStateOf(RegistryDestinationIds.TODAY) }
    var lists by remember { mutableStateOf(DesktopTaskLists()) }
    var editor by remember { mutableStateOf<EditTask?>(null) }
    var status by remember { mutableStateOf("Loading fixture") }
    var error by remember { mutableStateOf<String?>(null) }
    var online by remember { mutableStateOf(true) }
    var busy by remember { mutableStateOf(false) }
    var loaded by remember { mutableStateOf(false) }

    fun work(onSuccess: () -> Unit = {}, action: suspend () -> String?) {
        if (busy) return
        busy = true
        onBusyChange(true)
        error = null
        scope.launch {
            try {
                val (message, rows) = withContext(Dispatchers.IO) {
                    val message = action()
                    message to workspace.lists(languageTag)
                }
                lists = rows
                status = message ?: status
                loaded = true
                onSuccess()
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

    LaunchedEffect(Unit) {
        work {
            workspace.sync()
            "Fixture connected"
        }
    }

    val isToday = destination == RegistryDestinationIds.TODAY
    val rows = lists.rows(destination)
    val inbox = if (isToday) lists.inbox else emptyList()
    val newTaskTitle = RegistryCatalog.actionTitle(RegistryActionIds.APP_NEW_TASK, languageTag = languageTag).orEmpty()
    val canAdd = loaded && RegistryCatalog.destinationSupportsInlineCreate(destination)

    Row(Modifier.fillMaxSize()) {
        Column(Modifier.width(160.dp).padding(8.dp)) {
            for (id in desktopDestinations) {
                NavigationDrawerItem(
                    selected = id == destination,
                    onClick = { destination = id },
                    label = { Text(RegistryCatalog.destinationTitle(id, languageTag).orEmpty()) },
                )
            }
        }
        Column(Modifier.weight(1f).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (canAdd) {
                    Button(enabled = !busy, onClick = {
                        error = null
                        editor = EditTask()
                    }) { Text(newTaskTitle) }
                }
                TextButton(enabled = !busy, onClick = {
                    online = !online
                    transport.online = online
                    error = null
                    status = if (online) "Fixture online" else "Fixture offline"
                }) { Text(if (online) "Go offline" else "Go online") }
                TextButton(enabled = !busy, onClick = {
                    work {
                        val result = workspace.sync()
                        "Task writes sent: ${result.pushedOperations}"
                    }
                }) { Text("Sync") }
            }
            Text(status, style = MaterialTheme.typography.bodySmall)
            TaskHomeContent(
                completeTitle = RegistryCatalog.actionTitle(
                    RegistryActionIds.TASK_TOGGLE_COMPLETE,
                    languageTag = languageTag,
                ).orEmpty(),
                emptyTitle = RegistryCatalog.destinationEmptyTitle(destination, languageTag).orEmpty(),
                emptyDescription = RegistryCatalog.destinationEmptyDetail(destination, languageTag).orEmpty(),
                inboxBandTitle = RegistryCatalog.destinationTitle(RegistryDestinationIds.INBOX, languageTag).orEmpty(),
                todayTitle = RegistryCatalog.destinationTitle(RegistryDestinationIds.TODAY, languageTag).orEmpty(),
                todayTint = MaterialTheme.colorScheme.secondary,
                hasLoaded = loaded,
                isToday = isToday,
                isUpcoming = destination == RegistryDestinationIds.UPCOMING,
                inboxTasks = inbox,
                tasks = rows,
                canQuickAdd = canAdd,
                canComplete = true,
                errorMessage = error,
                rowMenuGroups = emptyList(),
                rowMenuAccessibilityLabel = "",
                listKey = destination,
                onComplete = { id ->
                    work {
                        checkNotNull(workspace.complete(id)) { localized("Task is no longer available.", languageTag) }
                        null
                    }
                },
                onOpenTask = { id ->
                    if (!busy) {
                        val row = (rows + inbox).firstOrNull { it.id == id }
                        if (row != null) {
                            error = null
                            editor = EditTask(row.title, row.id)
                        }
                    }
                },
                onTaskAction = { _, _ -> },
            )
        }
    }

    editor?.let { task ->
        var title by remember(task) { mutableStateOf(task.title) }
        AlertDialog(
            onDismissRequest = { if (!busy) editor = null },
            title = { Text(if (task.id == null) newTaskTitle else localized("Task Details", languageTag)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = title,
                        onValueChange = { title = it },
                        enabled = !busy,
                        singleLine = true,
                        label = { Text(localized("Title", languageTag)) },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                }
            },
            confirmButton = {
                Button(
                    enabled = !busy && title.isNotBlank() && title.trim() != task.title,
                    onClick = {
                        val editedTitle = title
                        work(onSuccess = { editor = null }) {
                            if (task.id == null) {
                                workspace.add(editedTitle, today = isToday)
                            } else {
                                checkNotNull(workspace.rename(task.id, editedTitle)) {
                                    localized("Task is no longer available.", languageTag)
                                }
                            }
                            "Task saved to the outbox"
                        }
                    },
                ) { Text(localized(if (task.id == null) "Add" else "Save", languageTag)) }
            },
            dismissButton = {
                TextButton(enabled = !busy, onClick = { editor = null }) { Text(localized("Cancel", languageTag)) }
            },
        )
    }
}

private fun localized(label: String, languageTag: String): String =
    RegistryCatalog.localizedString(label, languageTag) ?: label
