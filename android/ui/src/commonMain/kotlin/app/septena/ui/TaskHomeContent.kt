package app.septena.ui

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
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

/** [agentName] is set when an agent added the task (`task.provenance`); the row names it. */
data class TaskListItem(val id: String, val title: String, val agentName: String? = null)

/** Portable task-list surface. Platform hosts provide registry copy and bind actions to their mutators. */
@Composable
fun TaskHomeContent(
    quickAddTitle: String,
    completeTitle: String,
    emptyTitle: String,
    inboxBandTitle: String,
    isToday: Boolean,
    inboxTasks: List<TaskListItem>,
    tasks: List<TaskListItem>,
    canQuickAdd: Boolean,
    canComplete: Boolean,
    draftTitle: String,
    errorMessage: String?,
    modifier: Modifier = Modifier,
    onDraftTitleChange: (String) -> Unit,
    onQuickAdd: () -> Unit,
    onComplete: (String) -> Unit,
    onOpenTask: (String) -> Unit,
) {
    Column(
        modifier = modifier.fillMaxSize().padding(horizontal = 12.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (canQuickAdd && !isToday) {
            QuickAddRow(quickAddTitle, draftTitle, onDraftTitleChange, onQuickAdd)
        }

        errorMessage?.let { Text(it) }

        LazyColumn(
            modifier = Modifier.weight(1f),
            contentPadding = PaddingValues(bottom = 24.dp),
        ) {
            if (isToday && (inboxTasks.isNotEmpty() || canQuickAdd)) {
                item(key = "inbox-band-title") {
                    Text(
                        text = inboxBandTitle,
                        style = MaterialTheme.typography.titleSmall,
                        modifier = Modifier.padding(start = 16.dp, top = 8.dp, bottom = 4.dp),
                    )
                }
            }
            if (isToday && inboxTasks.isNotEmpty()) {
                items(inboxTasks, key = TaskListItem::id) { task ->
                    TaskRow(task, completeTitle, canComplete, onComplete, onOpenTask)
                }
            }
            if (isToday && canQuickAdd) {
                item(key = "inbox-capture") {
                    QuickAddRow(quickAddTitle, draftTitle, onDraftTitleChange, onQuickAdd)
                }
            }
            if (!canQuickAdd && tasks.isEmpty() && inboxTasks.isEmpty() && emptyTitle.isNotBlank()) {
                item(key = "empty-state") {
                    Text(
                        text = emptyTitle,
                        style = MaterialTheme.typography.bodyLarge,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 20.dp),
                    )
                }
            }
            items(tasks, key = TaskListItem::id) { task ->
                TaskRow(task, completeTitle, canComplete, onComplete, onOpenTask)
            }
        }
    }
}

@Composable
private fun QuickAddRow(
    quickAddTitle: String,
    draftTitle: String,
    onDraftTitleChange: (String) -> Unit,
    onQuickAdd: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        OutlinedTextField(
            value = draftTitle,
            onValueChange = onDraftTitleChange,
            modifier = Modifier.weight(1f),
            singleLine = true,
            label = { Text(quickAddTitle) },
        )
        TextButton(enabled = draftTitle.isNotBlank(), onClick = onQuickAdd) {
            Text(quickAddTitle)
        }
    }
}

@Composable
private fun TaskRow(
    task: TaskListItem,
    completeTitle: String,
    canComplete: Boolean,
    onComplete: (String) -> Unit,
    onOpenTask: (String) -> Unit,
) {
    ListItem(
        modifier = Modifier.fillMaxWidth().clickable { onOpenTask(task.id) },
        headlineContent = { Text(task.title, style = MaterialTheme.typography.bodyLarge) },
        // Permanent provenance marker. Apple rows show the registry glyph
        // (`task.added_by_agent`); Android has no icon set yet (no Material
        // icons dependency), so the row shows the agent's name as quiet text.
        trailingContent = task.agentName?.let { name ->
            {
                Text(
                    name,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
        leadingContent = if (canComplete) {
            {
                Checkbox(
                    checked = false,
                    onCheckedChange = { onComplete(task.id) },
                    modifier = Modifier.semantics { contentDescription = completeTitle },
                )
            }
        } else {
            null
        },
    )
}
