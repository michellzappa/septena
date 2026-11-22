package app.septena.android.ui

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.septena.android.AndroidAppGraph
import app.septena.android.sync.SyncState
import app.septena.core.JsonValue
import app.septena.core.RegistryActionContext
import app.septena.core.RegistryActionResolver
import app.septena.core.RegistryCatalog
import app.septena.core.TaskSnapshot
import app.septena.core.TaskViewRules
import app.septena.core.generated.RegistryActionIds
import app.septena.core.generated.RegistryDestinationIds
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.generated.RegistryPlatformIds
import app.septena.ui.TaskHomeContent
import app.septena.ui.TaskListItem
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/** The destinations `TaskViewRules.membership` computes; titles come from the registry. */
private val DESTINATIONS = listOf(
    RegistryDestinationIds.TODAY,
    RegistryDestinationIds.INBOX,
    RegistryDestinationIds.UPCOMING,
    RegistryDestinationIds.ANYTIME,
)

@Composable
fun TaskHomeScreen(graph: AndroidAppGraph) {
    var destination by remember { mutableStateOf(RegistryDestinationIds.TODAY) }
    var tasks by remember { mutableStateOf(emptyList<PositionedTask>()) }
    var draftTitle by remember { mutableStateOf("") }
    var writeError by remember { mutableStateOf<String?>(null) }
    val syncState by graph.sync.state.collectAsStateWithLifecycle()
    val dataVersion by graph.sync.dataVersion.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val languageTag = LocalConfiguration.current.locales[0].toLanguageTag()
    val addAction = RegistryActionIds.APP_QUICK_ADD
    val completeAction = RegistryActionIds.TASK_TOGGLE_COMPLETE
    val canQuickAdd = RegistryActionResolver.isAvailable(
        addAction,
        RegistryActionContext(platform = RegistryPlatformIds.ANDROID, destinationId = destination, selectedCount = 0),
    )
    val canComplete = RegistryActionResolver.isAvailable(
        completeAction,
        RegistryActionContext(platform = RegistryPlatformIds.ANDROID, destinationId = destination, selectedCount = 1),
    )

    LaunchedEffect(destination, dataVersion) {
        tasks = withContext(Dispatchers.IO) { loadTasks(graph, destination) }
    }

    fun afterLocalWrite() {
        graph.sync.noteLocalChange()
        graph.sync.requestSync()
    }

    TaskHomeContent(
        destinationTitle = RegistryCatalog.destinationTitle(destination, languageTag).orEmpty(),
        quickAddTitle = RegistryCatalog.actionTitle(addAction, languageTag = languageTag).orEmpty(),
        completeTitle = RegistryCatalog.actionTitle(completeAction, languageTag = languageTag).orEmpty(),
        emptyTitle = RegistryCatalog.destinationEmptyTitle(destination, languageTag).orEmpty(),
        tasks = tasks.map(PositionedTask::item),
        canQuickAdd = canQuickAdd,
        canComplete = canComplete,
        draftTitle = draftTitle,
        errorMessage = writeError,
        onDraftTitleChange = { draftTitle = it },
        onQuickAdd = {
            val title = draftTitle
            scope.launch {
                runCatching { withContext(Dispatchers.IO) { graph.taskMutator.create(title) } }
                    .onSuccess {
                        draftTitle = ""
                        writeError = null
                        afterLocalWrite()
                    }
                    .onFailure { writeError = it.message ?: "Could not save the task" }
            }
        },
        onComplete = { id ->
            scope.launch {
                runCatching { withContext(Dispatchers.IO) { graph.taskMutator.complete(id) } }
                    .onSuccess {
                        writeError = null
                        afterLocalWrite()
                    }
                    .onFailure { writeError = it.message ?: "Could not complete the task" }
            }
        },
        header = {
            Row(
                modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                DESTINATIONS.forEach { id ->
                    FilterChip(
                        selected = id == destination,
                        onClick = { destination = id },
                        label = { Text(RegistryCatalog.destinationTitle(id, languageTag) ?: id) },
                    )
                }
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(syncState.label(), modifier = Modifier.weight(1f))
                TextButton(
                    enabled = syncState !is SyncState.Syncing,
                    onClick = { graph.sync.requestSync() },
                ) { Text("Sync") }
                TextButton(onClick = { scope.launch { graph.credentials.signOut() } }) { Text("Sign out") }
            }
        },
    )
}

private suspend fun loadTasks(graph: AndroidAppGraph, destination: String): List<PositionedTask> {
    val now = graph.clock.now()
    val today = graph.clock.today(now)
    val positionField = if (destination == RegistryDestinationIds.TODAY) {
        RegistryEntityFields.Task.TODAY_POSITION
    } else {
        RegistryEntityFields.Task.POSITION
    }
    return graph.taskStore.records(RegistryEntityNames.TASK)
        .asSequence()
        .filter { it.deletedAt == null }
        .mapNotNull { record ->
            val snapshot = runCatching { TaskSnapshot.from(record) }.getOrNull() ?: return@mapNotNull null
            if (snapshot.isHeading) return@mapNotNull null
            if (TaskViewRules.membership(snapshot, today, now).matchesView[destination] != true) return@mapNotNull null
            PositionedTask(
                item = TaskListItem(record.id, snapshot.title),
                position = record.fields[positionField].numberValue()
                    ?: record.fields[RegistryEntityFields.Task.POSITION].numberValue(),
            )
        }
        .sortedWith(compareBy<PositionedTask>({ it.position ?: Double.MAX_VALUE }, { it.item.title.lowercase() }))
        .toList()
}

private val TIME = DateTimeFormatter.ofPattern("HH:mm").withZone(ZoneId.systemDefault())

private fun SyncState.label(): String = when (this) {
    SyncState.Idle -> "Not synced yet"
    SyncState.Syncing -> "Syncing…"
    is SyncState.Synced -> "Synced ${TIME.format(at)}"
    is SyncState.Failed -> "Sync failed: $message"
    SyncState.NeedsSignIn -> "Sign in again to sync"
}

private data class PositionedTask(val item: TaskListItem, val position: Double?)

private fun JsonValue?.numberValue(): Double? = when (this) {
    is JsonValue.IntegerValue -> value.toDouble()
    is JsonValue.DecimalValue -> value
    else -> null
}
