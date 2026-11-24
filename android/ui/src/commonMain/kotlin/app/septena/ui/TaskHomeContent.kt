package app.septena.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp

/** [agentName] is set when an agent added the task (`task.provenance`); the row names it. */
data class TaskListItem(
    val id: String,
    val title: String,
    val agentName: String? = null,
    val subtitle: String? = null,
    val isCompleted: Boolean = false,
    val isOnToday: Boolean = false,
    val isStarred: Boolean = false,
    /** Row opacity from the fade fill (1 = full strength), as on iOS. */
    val opacity: Float = 1f,
    /** A section heading shown above this row when it differs from the row before (Agent stages). */
    val groupTitle: String? = null,
)

/**
 * Multi-select state a host hands to a task list. A long-press starts the
 * selection with that row; while any row is selected, a tap adds or removes a
 * row instead of opening it. The host owns the ids and the action bar.
 */
data class TaskSelection(
    val selectedIds: Set<String> = emptySet(),
    /** False where the registry offers no Select (Recently Deleted): long-press opens the row menu there. */
    val enabled: Boolean = false,
    /** Accessibility label of the selection checkbox (registry copy). */
    val toggleLabel: String = "",
    val onToggle: (String) -> Unit = {},
) {
    val isActive: Boolean get() = selectedIds.isNotEmpty()
}

/** Tap opens the task, or toggles it while a selection is active; long-press selects it. */
@OptIn(ExperimentalFoundationApi::class)
fun Modifier.selectableTaskRow(
    taskId: String,
    selection: TaskSelection,
    onOpen: (String) -> Unit,
    onMenu: () -> Unit,
): Modifier = combinedClickable(
    onClick = { if (selection.isActive) selection.onToggle(taskId) else onOpen(taskId) },
    onLongClick = { if (selection.enabled) selection.onToggle(taskId) else onMenu() },
)

/** The selection wash on a selected row: the accent at low strength, ink stays normal. */
const val SELECTION_WASH_ALPHA = 0.14f

data class TaskRowMenuAction(
    val id: String,
    val title: String,
    val isDestructive: Boolean = false,
    val selectedTitle: String? = null,
    val unselectedTitle: String? = null,
)

/** Portable task-list surface. Platform hosts provide registry copy and bind actions to their mutators. */
@Composable
fun TaskHomeContent(
    completeTitle: String,
    emptyTitle: String,
    emptyDescription: String,
    inboxBandTitle: String,
    todayTitle: String,
    todayTint: Color,
    hasLoaded: Boolean,
    isToday: Boolean,
    inboxTasks: List<TaskListItem>,
    tasks: List<TaskListItem>,
    canQuickAdd: Boolean,
    canComplete: Boolean,
    errorMessage: String?,
    rowMenuGroups: List<List<TaskRowMenuAction>>,
    rowMenuAccessibilityLabel: String,
    modifier: Modifier = Modifier,
    selection: TaskSelection = TaskSelection(),
    onComplete: (String) -> Unit,
    onOpenTask: (String) -> Unit,
    onTaskAction: (String, String) -> Unit,
) {
    Column(
        modifier = modifier.fillMaxSize().padding(vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        errorMessage?.let { Text(it) }

        LazyColumn(
            modifier = Modifier.weight(1f).fillMaxWidth(),
            contentPadding = PaddingValues(bottom = 24.dp),
        ) {
            if (isToday && inboxTasks.isNotEmpty()) {
                item(key = "inbox-band-title") {
                    Text(
                        text = inboxBandTitle,
                        style = MaterialTheme.typography.titleSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(start = 16.dp, top = 12.dp, bottom = 4.dp),
                    )
                }
            }
            if (isToday) {
                taskRows(
                    tasks = inboxTasks,
                    keyPrefix = "inbox",
                    completeTitle = completeTitle,
                    canComplete = canComplete,
                    todayTitle = todayTitle,
                    todayTint = todayTint,
                    showTodayIndicator = false,
                    onComplete = onComplete,
                    onOpenTask = onOpenTask,
                    rowMenuGroups = rowMenuGroups,
                    rowMenuAccessibilityLabel = rowMenuAccessibilityLabel,
                    selection = selection,
                    onTaskAction = onTaskAction,
                )
            }
            if (hasLoaded && !canQuickAdd && tasks.isEmpty() && inboxTasks.isEmpty() && emptyTitle.isNotBlank()) {
                item(key = "empty-state") {
                    Column(
                        modifier = Modifier.fillParentMaxSize().padding(horizontal = 32.dp, vertical = 24.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Text(
                            text = emptyTitle,
                            style = MaterialTheme.typography.titleMedium,
                            textAlign = TextAlign.Center,
                        )
                        if (emptyDescription.isNotBlank()) {
                            Text(
                                text = emptyDescription,
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                textAlign = TextAlign.Center,
                            )
                        }
                    }
                }
            }
            taskRows(
                tasks = tasks,
                keyPrefix = "task",
                completeTitle = completeTitle,
                canComplete = canComplete,
                todayTitle = todayTitle,
                todayTint = todayTint,
                showTodayIndicator = !isToday,
                onComplete = onComplete,
                onOpenTask = onOpenTask,
                rowMenuGroups = rowMenuGroups,
                rowMenuAccessibilityLabel = rowMenuAccessibilityLabel,
                selection = selection,
                onTaskAction = onTaskAction,
            )
        }
    }
}

private fun LazyListScope.taskRows(
    tasks: List<TaskListItem>,
    keyPrefix: String,
    completeTitle: String,
    canComplete: Boolean,
    todayTitle: String,
    todayTint: Color,
    showTodayIndicator: Boolean,
    onComplete: (String) -> Unit,
    onOpenTask: (String) -> Unit,
    rowMenuGroups: List<List<TaskRowMenuAction>>,
    rowMenuAccessibilityLabel: String,
    selection: TaskSelection,
    onTaskAction: (String, String) -> Unit,
) {
    itemsIndexed(tasks, key = { _, task -> "$keyPrefix:${task.id}" }) { index, task ->
        val group = task.groupTitle
        if (group != null && (index == 0 || tasks[index - 1].groupTitle != group)) {
            Text(
                text = group,
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 20.dp, bottom = 6.dp),
            )
        }
        TaskRow(
            task = task,
            completeTitle = completeTitle,
            canComplete = canComplete,
            todayTitle = todayTitle,
            todayTint = todayTint,
            showTodayIndicator = showTodayIndicator,
            onComplete = onComplete,
            onOpenTask = onOpenTask,
            rowMenuGroups = rowMenuGroups,
            rowMenuAccessibilityLabel = rowMenuAccessibilityLabel,
            selection = selection,
            onTaskAction = onTaskAction,
        )
        if (index < tasks.lastIndex) {
            HorizontalDivider(
                modifier = Modifier.padding(start = 72.dp, end = 16.dp),
                color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.55f),
            )
        }
    }
}

@Composable
@OptIn(ExperimentalFoundationApi::class)
private fun TaskRow(
    task: TaskListItem,
    completeTitle: String,
    canComplete: Boolean,
    todayTitle: String,
    todayTint: Color,
    showTodayIndicator: Boolean,
    onComplete: (String) -> Unit,
    onOpenTask: (String) -> Unit,
    rowMenuGroups: List<List<TaskRowMenuAction>>,
    rowMenuAccessibilityLabel: String,
    selection: TaskSelection,
    onTaskAction: (String, String) -> Unit,
) {
    val showToday = showTodayIndicator && task.isOnToday && !task.isCompleted
    var menuExpanded by remember(task.id) { mutableStateOf(false) }
    val selecting = selection.isActive
    val selected = task.id in selection.selectedIds
    ListItem(
        colors = if (selected) {
            ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.primary.copy(alpha = SELECTION_WASH_ALPHA))
        } else {
            ListItemDefaults.colors()
        },
        modifier = Modifier.fillMaxWidth().alpha(task.opacity).selectableTaskRow(
            taskId = task.id,
            selection = selection,
            onOpen = onOpenTask,
            onMenu = { menuExpanded = true },
        ),
        headlineContent = {
            Text(
                text = task.title,
                style = MaterialTheme.typography.bodyLarge.copy(
                    textDecoration = if (task.isCompleted) TextDecoration.LineThrough else TextDecoration.None,
                ),
                color = if (task.isCompleted) MaterialTheme.colorScheme.onSurfaceVariant
                else MaterialTheme.colorScheme.onSurface,
            )
        },
        supportingContent = if (task.subtitle != null) {
            {
                Text(
                    task.subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                )
            }
        } else {
            null
        },
        trailingContent = if (showToday || task.agentName != null || (rowMenuGroups.isNotEmpty() && !selecting)) {
            {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    if (showToday) {
                        Surface(color = todayTint.copy(alpha = 0.16f), shape = CircleShape) {
                            Text(
                                text = todayTitle,
                                style = MaterialTheme.typography.labelSmall,
                                color = todayTint,
                                modifier = Modifier.padding(horizontal = 9.dp, vertical = 4.dp),
                            )
                        }
                    }
                    task.agentName?.let { name ->
                        Text(
                            name,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    if (rowMenuGroups.isNotEmpty() && !selecting) {
                        TaskRowActionsMenu(
                            groups = rowMenuGroups.map { group ->
                                group.map { action ->
                                    if (action.selectedTitle != null || action.unselectedTitle != null) action.copy(
                                        title = if (task.isStarred) action.selectedTitle ?: action.title
                                        else action.unselectedTitle ?: action.title,
                                    ) else action
                                }
                            },
                            accessibilityLabel = rowMenuAccessibilityLabel,
                            expanded = menuExpanded,
                            onExpandedChange = { menuExpanded = it },
                            onAction = { id -> onTaskAction(task.id, id) },
                        )
                    }
                }
            }
        } else {
            null
        },
        leadingContent = if (selecting) {
            {
                Checkbox(
                    checked = selected,
                    onCheckedChange = { selection.onToggle(task.id) },
                    modifier = Modifier.semantics { contentDescription = selection.toggleLabel },
                )
            }
        } else if (canComplete || task.isCompleted) {
            {
                Checkbox(
                    checked = task.isCompleted,
                    enabled = canComplete && !task.isCompleted,
                    onCheckedChange = { checked -> if (checked) onComplete(task.id) },
                    colors = CheckboxDefaults.colors(
                        checkedColor = MaterialTheme.colorScheme.primary,
                        checkmarkColor = MaterialTheme.colorScheme.onPrimary,
                    ),
                    modifier = Modifier.semantics { contentDescription = completeTitle },
                )
            }
        } else {
            null
        },
    )
}

@Composable
fun TaskRowActionsMenu(
    groups: List<List<TaskRowMenuAction>>,
    accessibilityLabel: String,
    expanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
    onAction: (String) -> Unit,
) {
    Column {
        IconButton(
            onClick = { onExpandedChange(true) },
            modifier = Modifier.semantics { contentDescription = accessibilityLabel },
        ) {
            Text("⋮", style = MaterialTheme.typography.titleLarge)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { onExpandedChange(false) }) {
            groups.forEachIndexed { index, group ->
                if (index > 0) HorizontalDivider()
                group.forEach { action ->
                    DropdownMenuItem(
                        text = {
                            Text(
                                text = action.title,
                                color = if (action.isDestructive) MaterialTheme.colorScheme.error
                                else MaterialTheme.colorScheme.onSurface,
                            )
                        },
                        onClick = {
                            onExpandedChange(false)
                            onAction(action.id)
                        },
                    )
                }
            }
        }
    }
}
