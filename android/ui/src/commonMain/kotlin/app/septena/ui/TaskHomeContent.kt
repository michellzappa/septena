package app.septena.ui

import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.BorderStroke
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

enum class TaskSignalTone { Muted, Overdue, Star }

/** One trailing signal of a row: a glyph (icons.json ID), a short text, or both. */
data class TaskRowSignal(
    val icon: String?,
    val text: String? = null,
    /** Accessibility label of the glyph. */
    val label: String = "",
    val tone: TaskSignalTone = TaskSignalTone.Muted,
)

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
    val signals: List<TaskRowSignal> = emptyList(),
    val tags: List<String> = emptyList(),
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

data class TaskRowMenuAction(
    val id: String,
    val title: String,
    val isDestructive: Boolean = false,
    val selectedTitle: String? = null,
    val unselectedTitle: String? = null,
    /** Icon ID (icons.json) shown before the title. */
    val icon: String? = null,
)

/** Portable task-list surface. Platform hosts provide registry copy and bind actions to their mutators. */
@Composable
fun TaskHomeContent(
    completeTitle: String,
    emptyTitle: String,
    emptyDescription: String,
    inboxBandTitle: String,
    inboxBandIcon: String?,
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
    /** Icon ID (icons.json) of the row menu button. */
    rowMenuIcon: String? = null,
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
                    TaskGroupHeader(
                        title = inboxBandTitle,
                        icon = inboxBandIcon,
                        modifier = Modifier.padding(
                            start = LocalTaskListStyle.current.pageGutter,
                            top = 12.dp,
                            bottom = 6.dp,
                        ),
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
                    rowMenuIcon = rowMenuIcon,
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
                rowMenuIcon = rowMenuIcon,
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
    rowMenuIcon: String?,
    onTaskAction: (String, String) -> Unit,
) {
    itemsIndexed(tasks, key = { _, task -> "$keyPrefix:${task.id}" }) { index, task ->
        val group = task.groupTitle
        val startsGroup = index == 0 || tasks[index - 1].groupTitle != group
        val endsGroup = index == tasks.lastIndex || tasks[index + 1].groupTitle != group
        Column(modifier = Modifier.animateItem()) {
            if (group != null && startsGroup) {
                TaskGroupHeader(
                    title = group,
                    modifier = Modifier.fillMaxWidth().padding(
                        start = LocalTaskListStyle.current.pageGutter,
                        end = LocalTaskListStyle.current.pageGutter,
                        top = 20.dp,
                        bottom = 6.dp,
                    ),
                )
            }
            Column(
                modifier = Modifier.taskCardSlice(
                    first = startsGroup,
                    last = endsGroup,
                    selected = task.id in selection.selectedIds,
                ),
            ) {
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
                    rowMenuIcon = rowMenuIcon,
                    onTaskAction = onTaskAction,
                )
                if (!endsGroup) {
                    HorizontalDivider(
                        modifier = Modifier.padding(start = 48.dp),
                        color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.55f),
                    )
                }
            }
        }
    }
}

/** One task row, as the iPhone row reads: checkbox, title with its place below, trailing signals. */
@Composable
fun TaskRow(
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
    rowMenuIcon: String?,
    onTaskAction: (String, String) -> Unit,
) {
    val showToday = showTodayIndicator && task.isOnToday && !task.isCompleted
    var menuExpanded by remember(task.id) { mutableStateOf(false) }
    val selecting = selection.isActive
    val muted = MaterialTheme.colorScheme.onSurfaceVariant
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .alpha(task.opacity)
            .selectableTaskRow(
                taskId = task.id,
                selection = selection,
                onOpen = onOpenTask,
                onMenu = { menuExpanded = true },
            )
            .heightIn(min = 48.dp)
            .padding(end = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Material keeps a 48dp touch target around the 18dp box, so the box and
        // the title line up with the iPhone columns.
        when {
            selecting -> Checkbox(
                checked = task.id in selection.selectedIds,
                onCheckedChange = { selection.onToggle(task.id) },
                modifier = Modifier.semantics { contentDescription = selection.toggleLabel },
            )
            canComplete || task.isCompleted -> Checkbox(
                checked = task.isCompleted,
                enabled = canComplete && !task.isCompleted,
                onCheckedChange = { checked -> if (checked) onComplete(task.id) },
                colors = CheckboxDefaults.colors(
                    checkedColor = MaterialTheme.colorScheme.primary,
                    checkmarkColor = MaterialTheme.colorScheme.onPrimary,
                ),
                modifier = Modifier.semantics { contentDescription = completeTitle },
            )
            else -> Spacer(Modifier.width(16.dp))
        }
        Column(
            modifier = Modifier.weight(1f).padding(vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                text = task.title,
                style = MaterialTheme.typography.bodyLarge.copy(
                    textDecoration = if (task.isCompleted) TextDecoration.LineThrough else TextDecoration.None,
                ),
                color = if (task.isCompleted) muted else MaterialTheme.colorScheme.onSurface,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            task.subtitle?.let { place ->
                Text(
                    place,
                    style = MaterialTheme.typography.bodySmall,
                    color = muted,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Row(
            modifier = Modifier.padding(start = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            if (showToday) {
                Surface(color = todayTint.copy(alpha = 0.16f), shape = CircleShape) {
                    Text(
                        text = todayTitle,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurface,
                        modifier = Modifier.padding(horizontal = 7.dp, vertical = 3.dp),
                    )
                }
            }
            task.signals.forEach { SignalView(it) }
            task.tags.take(MAX_ROW_TAGS).forEach { tag ->
                Surface(
                    color = Color.Transparent,
                    shape = CircleShape,
                    border = BorderStroke(0.75.dp, muted.copy(alpha = 0.28f)),
                ) {
                    Text(
                        tag,
                        style = MaterialTheme.typography.labelSmall,
                        color = muted,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.widthIn(max = 72.dp).padding(horizontal = 6.dp, vertical = 2.dp),
                    )
                }
            }
            if (task.tags.size > MAX_ROW_TAGS) {
                Text("+${task.tags.size - MAX_ROW_TAGS}", style = MaterialTheme.typography.labelSmall, color = muted)
            }
            task.agentName?.let { name ->
                Text(name, style = MaterialTheme.typography.labelSmall, color = muted, maxLines = 1)
            }
            // iPhone opens the menu with a long press. Here a long press selects
            // (Android convention), so the row keeps a quiet menu button.
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
                    icon = rowMenuIcon,
                    expanded = menuExpanded,
                    onExpandedChange = { menuExpanded = it },
                    onAction = { id -> onTaskAction(task.id, id) },
                )
            }
        }
    }
}

private const val MAX_ROW_TAGS = 2

@Composable
private fun SignalView(signal: TaskRowSignal) {
    val tint = when (signal.tone) {
        TaskSignalTone.Muted -> MaterialTheme.colorScheme.onSurfaceVariant
        TaskSignalTone.Overdue -> MaterialTheme.colorScheme.error
        TaskSignalTone.Star -> LocalTaskListStyle.current.starTint
    }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
        RegistryIcon(signal.icon, contentDescription = signal.label.ifEmpty { null }, tint = tint, size = 13.dp)
        signal.text?.let {
            Text(
                it,
                style = MaterialTheme.typography.labelSmall,
                fontWeight = if (signal.tone == TaskSignalTone.Overdue) FontWeight.SemiBold else FontWeight.Normal,
                color = tint,
                maxLines = 1,
            )
        }
    }
}

/** A group heading above a card (iPhone `sectionGroupHeaderTitleStyle`, 18pt semibold). */
@Composable
fun TaskGroupHeader(title: String, modifier: Modifier = Modifier, icon: String? = null) {
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        RegistryIcon(icon, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant, size = 16.dp)
        Text(title, fontSize = 18.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
    }
}

@Composable
fun TaskRowActionsMenu(
    groups: List<List<TaskRowMenuAction>>,
    accessibilityLabel: String,
    expanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
    onAction: (String) -> Unit,
    icon: String? = null,
) {
    Column {
        IconButton(onClick = { onExpandedChange(true) }) {
            RegistryIcon(icon, contentDescription = accessibilityLabel)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { onExpandedChange(false) }) {
            groups.forEachIndexed { index, group ->
                if (index > 0) HorizontalDivider()
                group.forEach { action ->
                    DropdownMenuItem(
                        leadingIcon = action.icon?.let { id ->
                            {
                                RegistryIcon(
                                    id,
                                    contentDescription = null,
                                    tint = if (action.isDestructive) MaterialTheme.colorScheme.error
                                    else MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        },
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
