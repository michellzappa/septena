package app.septena.windows

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.selection.selectable
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isAltPressed
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isMetaPressed
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import app.septena.core.JsonValue
import app.septena.core.QuickFindCopy
import app.septena.core.QuickFindResult
import app.septena.core.QuickFindSearch
import app.septena.core.QuickFindTarget
import app.septena.core.RegistryCatalog
import app.septena.core.TaskRecord
import app.septena.core.generated.RegistryActionIds
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.stringValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

private data class FindResponse(
    val query: String,
    val hits: List<QuickFindResult> = emptyList(),
    val error: String? = null,
)

@Composable
internal fun DesktopQuickFind(
    search: QuickFindSearch,
    languageTag: String,
    onClose: () -> Unit,
    onChoose: (QuickFindTarget) -> Unit,
) {
    val copy = remember(languageTag) { QuickFindCopy.fromRegistry(languageTag) }
    val focus = remember { FocusRequester() }
    val listState = rememberLazyListState()
    var query by remember { mutableStateOf("") }
    var response by remember { mutableStateOf<FindResponse?>(null) }
    var selected by remember { mutableStateOf(0) }
    val current = response?.takeIf { it.query == query }
    val hits = current?.hits.orEmpty()

    LaunchedEffect(Unit) { focus.requestFocus() }
    LaunchedEffect(query) {
        if (query.isBlank()) return@LaunchedEffect
        val request = query
        delay(100)
        response = try {
            FindResponse(request, withContext(Dispatchers.Default) { search.search(request) })
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            FindResponse(request, error = failure.message ?: (RegistryCatalog.localizedString("Error", languageTag) ?: "Error"))
        }
    }
    LaunchedEffect(hits, selected) {
        if (selected in hits.indices && listState.layoutInfo.visibleItemsInfo.none { it.index == selected }) {
            listState.scrollToItem(selected)
        }
    }

    AlertDialog(
        onDismissRequest = onClose,
        title = { Text(copy.title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = query,
                    onValueChange = {
                        response = null
                        selected = 0
                        query = it
                    },
                    label = { Text(copy.searchPrompt) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth().focusRequester(focus).onPreviewKeyEvent { event ->
                        if (event.type != KeyEventType.KeyDown || hits.isEmpty() ||
                            event.isCtrlPressed || event.isAltPressed || event.isShiftPressed || event.isMetaPressed
                        ) return@onPreviewKeyEvent false
                        when (event.key) {
                            Key.DirectionDown -> {
                                selected = (selected + 1).coerceAtMost(hits.lastIndex)
                                true
                            }
                            Key.DirectionUp -> {
                                selected = (selected - 1).coerceAtLeast(0)
                                true
                            }
                            Key.Enter -> {
                                hits.getOrNull(selected)?.let { onChoose(it.target) }
                                true
                            }
                            else -> false
                        }
                    },
                )
                Box(Modifier.fillMaxWidth().height(268.dp), contentAlignment = Alignment.TopCenter) {
                    when {
                        query.isBlank() -> FindMessage(copy.emptyTitle, copy.emptyDetail)
                        current == null -> CircularProgressIndicator(Modifier.size(24.dp))
                        current.error != null -> Text(current.error, color = MaterialTheme.colorScheme.error)
                        hits.isEmpty() -> FindMessage(copy.noResultsTitle, copy.noResultsDetail)
                        else -> LazyColumn(state = listState, modifier = Modifier.fillMaxWidth()) {
                            itemsIndexed(hits, key = { _, result -> result.id }) { index, result ->
                                val subtitle = copy.subtitleFor(result, languageTag)
                                ListItem(
                                    headlineContent = { Text(result.title) },
                                    supportingContent = subtitle?.let { { Text(it) } },
                                    colors = ListItemDefaults.colors(
                                        containerColor = if (selected == index) {
                                            MaterialTheme.colorScheme.secondaryContainer
                                        } else Color.Transparent,
                                    ),
                                    modifier = Modifier.selectable(
                                        selected = selected == index,
                                        role = Role.Button,
                                        onClick = { onChoose(result.target) },
                                    ),
                                )
                            }
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onClose) { Text(copy.backTitle) } },
    )
}

@Composable
private fun FindMessage(title: String, detail: String) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(title, style = MaterialTheme.typography.titleMedium)
        Text(detail, style = MaterialTheme.typography.bodyMedium)
    }
}

internal fun quickFindTaskLocation(
    target: QuickFindTarget.Task,
    task: TaskRecord,
    lists: DesktopTaskLists,
): DesktopLocation? {
    target.projectId?.let { projectId ->
        val headingId = task.fields[RegistryEntityFields.Task.HEADING].stringValue()
        if (headingId != null) {
            val heading = DesktopLocation.Section(projectId, headingId)
            if (lists.places.place(heading) != null) return heading
        }
        val project = DesktopLocation.Project(projectId)
        if (lists.places.place(project) != null) return project
    }
    target.areaId?.let { areaId ->
        val area = DesktopLocation.Area(areaId)
        if (lists.places.place(area) != null) return area
    }
    val id = target.destinationId ?: return null
    if (id !in desktopDestinations) return null
    val visible = lists.rows(id).any { it.id == task.id } || lists.inbox.any { it.id == task.id }
    return DesktopLocation.Smart(id).takeIf { visible }
}

private data class QuickFindBinding(val key: Key, val shifted: Boolean)

private val quickFindBindings by lazy {
    val shortcut = RegistryCatalog.action(RegistryActionIds.APP_QUICK_FIND)?.get("shortcut") as? JsonValue.ObjectValue
    val alternates = (shortcut?.get("alternates") as? JsonValue.ArrayValue)?.values.orEmpty()
    (listOfNotNull(shortcut) + alternates.filterIsInstance<JsonValue.ObjectValue>()).mapNotNull { entry ->
        val key = when (entry["key"].stringValue()) {
            "k" -> Key.K
            "f" -> Key.F
            else -> return@mapNotNull null
        }
        val modifiers = (entry["modifiers"] as? JsonValue.ArrayValue)?.values.orEmpty()
            .mapNotNull { it.stringValue() }.toSet()
        when (modifiers) {
            setOf("primary") -> QuickFindBinding(key, shifted = false)
            setOf("primary", "shift") -> QuickFindBinding(key, shifted = true)
            else -> null
        }
    }
}

internal fun KeyEvent.opensQuickFind(): Boolean =
    type == KeyEventType.KeyDown && isCtrlPressed && !isAltPressed && !isMetaPressed &&
        quickFindBindings.any { it.key == key && it.shifted == isShiftPressed }
