package app.septena.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.ListItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

data class TaskListItem(val id: String, val title: String)

/** Portable task-list surface. Platform hosts provide registry copy and bind actions to their mutators. */
@Composable
fun TaskHomeContent(
    destinationTitle: String,
    quickAddTitle: String,
    completeTitle: String,
    emptyTitle: String,
    tasks: List<TaskListItem>,
    canQuickAdd: Boolean,
    canComplete: Boolean,
    draftTitle: String,
    errorMessage: String?,
    onDraftTitleChange: (String) -> Unit,
    onQuickAdd: () -> Unit,
    onComplete: (String) -> Unit,
    /** Host-owned controls under the title (destination picker, sync status). */
    header: @Composable () -> Unit = {},
) {
    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 20.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(destinationTitle)
        header()

        if (canQuickAdd) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                OutlinedTextField(
                    value = draftTitle,
                    onValueChange = onDraftTitleChange,
                    modifier = Modifier.weight(1f),
                    singleLine = true,
                    label = { Text(quickAddTitle) },
                )
                Button(enabled = draftTitle.isNotBlank(), onClick = onQuickAdd) {
                    Text(quickAddTitle)
                }
            }
        }

        errorMessage?.let { Text(it) }

        if (tasks.isEmpty()) {
            Text(emptyTitle)
        } else {
            LazyColumn(modifier = Modifier.fillMaxSize()) {
                items(tasks, key = TaskListItem::id) { task ->
                    ListItem(
                        headlineContent = { Text(task.title) },
                        trailingContent = if (canComplete) {
                            { Button(onClick = { onComplete(task.id) }) { Text(completeTitle) } }
                        } else {
                            null
                        },
                    )
                }
            }
        }
    }
}
