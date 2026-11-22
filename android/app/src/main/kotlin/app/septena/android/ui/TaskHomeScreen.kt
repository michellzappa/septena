package app.septena.android.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalConfiguration
import app.septena.android.AndroidAppGraph
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
import kotlinx.coroutines.launch

@Composable
fun TaskHomeScreen(graph: AndroidAppGraph) {
    var tasks by remember { mutableStateOf(emptyList<PositionedTask>()) }
    var draftTitle by remember { mutableStateOf("") }
    var writeError by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val languageTag = LocalConfiguration.current.locales[0].toLanguageTag()
    val addAction = RegistryActionIds.APP_QUICK_ADD
    val completeAction = RegistryActionIds.TASK_TOGGLE_COMPLETE
    val canQuickAdd = RegistryActionResolver.isAvailable(
        addAction,
        RegistryActionContext(platform = RegistryPlatformIds.ANDROID, destinationId = RegistryDestinationIds.TODAY, selectedCount = 0),
    )
    val canComplete = RegistryActionResolver.isAvailable(
        completeAction,
        RegistryActionContext(platform = RegistryPlatformIds.ANDROID, destinationId = RegistryDestinationIds.TODAY, selectedCount = 1),
    )

    suspend fun refresh() {
        val now = graph.clock.now()
        val today = graph.clock.today(now)
        tasks = graph.taskStore.records(RegistryEntityNames.TASK)
            .asSequence()
            .filter { it.deletedAt == null }
            .mapNotNull { record ->
                val snapshot = TaskSnapshot.from(record)
                if (TaskViewRules.membership(snapshot, today, now).matchesView["today"] != true) return@mapNotNull null
                PositionedTask(
                    item = TaskListItem(record.id, snapshot.title),
                    position = record.fields[RegistryEntityFields.Task.TODAY_POSITION].numberValue()
                        ?: record.fields[RegistryEntityFields.Task.POSITION].numberValue(),
                )
            }
            .sortedWith(compareBy<PositionedTask>({ it.position ?: Double.MAX_VALUE }, { it.item.title.lowercase() }))
            .toList()
    }

    LaunchedEffect(graph.taskStore) { refresh() }

    TaskHomeContent(
        destinationTitle = RegistryCatalog.destinationTitle(RegistryDestinationIds.TODAY, languageTag).orEmpty(),
        quickAddTitle = RegistryCatalog.actionTitle(addAction, languageTag = languageTag).orEmpty(),
        completeTitle = RegistryCatalog.actionTitle(completeAction, languageTag = languageTag).orEmpty(),
        emptyTitle = RegistryCatalog.destinationEmptyTitle(RegistryDestinationIds.TODAY, languageTag).orEmpty(),
        tasks = tasks.map(PositionedTask::item),
        canQuickAdd = canQuickAdd,
        canComplete = canComplete,
        draftTitle = draftTitle,
        errorMessage = writeError,
        onDraftTitleChange = { draftTitle = it },
        onQuickAdd = {
            val title = draftTitle
            scope.launch {
                runCatching { graph.taskMutator.create(title) }
                    .onSuccess {
                        draftTitle = ""
                        writeError = null
                        refresh()
                    }
                    .onFailure { writeError = it.message ?: "Could not save the task" }
            }
        },
        onComplete = { id ->
            scope.launch {
                runCatching { graph.taskMutator.complete(id) }
                    .onSuccess {
                        writeError = null
                        refresh()
                    }
                    .onFailure { writeError = it.message ?: "Could not complete the task" }
            }
        },
    )
}

private data class PositionedTask(val item: TaskListItem, val position: Double?)

private fun JsonValue?.numberValue(): Double? = when (this) {
    is JsonValue.IntegerValue -> value.toDouble()
    is JsonValue.DecimalValue -> value
    else -> null
}
