package app.septena.windows

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
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
import app.septena.core.TaskRecord
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.nio.file.Files

fun main() {
    val directory = Files.createTempDirectory("septena-spike-")
    val transport = FixtureTransport()
    try {
        SpikeWorkspace(directory.resolve("tasks.db"), transport).use { workspace ->
            application(exitProcessOnExit = false) {
                val scope = rememberCoroutineScope()
                var tasks by remember { mutableStateOf(emptyList<TaskRecord>()) }
                var title by remember { mutableStateOf("") }
                var status by remember { mutableStateOf("Loading fixture") }
                var online by remember { mutableStateOf(true) }
                var busy by remember { mutableStateOf(false) }

                fun work(action: suspend () -> String, onSuccess: () -> Unit = {}) {
                    if (busy) return
                    busy = true
                    scope.launch {
                        try {
                            val (message, rows) = withContext(Dispatchers.IO) {
                                val message = action()
                                message to workspace.tasks()
                            }
                            tasks = rows
                            status = message
                            onSuccess()
                        } catch (cancelled: CancellationException) {
                            throw cancelled
                        } catch (failure: Exception) {
                            status = failure.message ?: "The operation failed"
                        } finally {
                            busy = false
                        }
                    }
                }

                LaunchedEffect(Unit) {
                    work({ workspace.sync(); "Example task pulled" })
                }

                Window(onCloseRequest = { if (!busy) exitApplication() }, title = "Septena Spike") {
                    MaterialTheme {
                        Surface(Modifier.fillMaxSize()) {
                            Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                                Text("Task sync fixture", style = MaterialTheme.typography.headlineSmall)
                                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    Button(enabled = !busy, onClick = {
                                        online = !online
                                        transport.online = online
                                        status = if (online) "Fixture online" else "Fixture offline"
                                    }) { Text(if (online) "Go offline" else "Go online") }
                                    Button(enabled = !busy, onClick = {
                                        work({
                                            val result = workspace.sync()
                                            "Task writes sent: ${result.pushedOperations}"
                                        })
                                    }) { Text("Sync") }
                                }
                                Text(status)
                                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    OutlinedTextField(
                                        value = title,
                                        onValueChange = { title = it },
                                        enabled = !busy,
                                        singleLine = true,
                                        label = { Text("Task title") },
                                    )
                                    Button(enabled = !busy && title.isNotBlank(), onClick = {
                                        val newTitle = title
                                        work({ workspace.add(newTitle); "Task saved to the outbox" }, { title = "" })
                                    }) { Text("Add task") }
                                }
                                LazyColumn(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                    items(tasks, key = { it.id }) { Text(it.title) }
                                }
                            }
                        }
                    }
                }
            }
        }
    } finally {
        directory.toFile().deleteRecursively()
    }
}
