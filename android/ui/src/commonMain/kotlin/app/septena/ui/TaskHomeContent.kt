package app.septena.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

/**
 * Portable view model for a task row (iOS `TaskRow` parity).
 * [agentName] is set when an agent added the task (`task.provenance`); the row
 * draws the dialogue-with-sparkles icon (`AgentSparkleBubbleGlyph`) instead of
 * plain text, keeping the agent's name as accessibility copy.
 */
data class TaskListItem(
    val id: String,
    val title: String,
    val agentName: String? = null,
    val subtitle: String? = null,
    val isCompleted: Boolean = false,
    val isOnToday: Boolean = false,
    val isStarred: Boolean = false,
    val isFaded: Boolean = false,
    /** Row opacity from the fade fill (1 = full strength), as on iOS. */
    val opacity: Float = 1f,
    /** Structured group header (area/project/agent stage); separates icon/emoji from title for alignment. */
    val group: TaskGroupHeader? = null,
    /** Legacy plain group title fallback (used if [group] is null). */
    val groupTitle: String? = null,
    /** Sort position in the current list, used by Magic Plus drag-and-drop insertion. */
    val position: Double? = null,
    /** Deadline label ("Today", "Overdue", or short future date). */
    val deadlineText: String? = null,
    /** True when the core (`deadlineRed`) marks this deadline red (due today or overdue). */
    val deadlineIsRed: Boolean = false,
    /** True for a future deadline (renders flag + date); false for red Today / Overdue. */
    val deadlineShowsFlag: Boolean = false,
    /** Scheduled When date (shown when no deadline is displayed and not covered by Today). */
    val scheduledText: String? = null,
    /** Completed/archived date for Logbook / Recently Deleted rows. */
    val completedDateText: String? = null,
    /** Checklist progress summary (`done/total`). Zero chrome when [checklistTotal] == 0. */
    val checklistDone: Int = 0,
    val checklistTotal: Int = 0,
    /** Resolved live tag names on this task. */
    val tagNames: List<String> = emptyList(),
    /** Compact timed reminder label (e.g. "9:00 AM" or "Tomorrow 9:00 AM"). */
    val reminderText: String? = null,
    val reminderIsPastDue: Boolean = false,
    val isRepeating: Boolean = false,
    val hasNotes: Boolean = false,
    val hasAttachments: Boolean = false,
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

/**
 * Tap opens the task (or toggles selection while multi-select is active).
 * Long-press opens the task's context menu, matching iOS (`Select` inside the
 * menu enters multi-select mode).
 */
@OptIn(ExperimentalFoundationApi::class)
fun Modifier.selectableTaskRow(
    taskId: String,
    selection: TaskSelection,
    onOpen: (String) -> Unit,
    onMenu: () -> Unit,
): Modifier = combinedClickable(
    onClick = { if (selection.isActive) selection.onToggle(taskId) else onOpen(taskId) },
    onLongClick = { if (selection.isActive) selection.onToggle(taskId) else onMenu() },
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
    fadedTitle: String = "",
    showFadedIndicator: Boolean = false,
    isDarkTheme: Boolean = false,
    hasActiveTexture: Boolean = false,
    headerContent: (@Composable () -> Unit)? = null,
    selection: TaskSelection = TaskSelection(),
    onComplete: (String) -> Unit,
    onOpenTask: (String) -> Unit,
    onTaskAction: (String, String) -> Unit,
    onOpenGroupTarget: ((String) -> Unit)? = null,
    onDropInboxHeader: (() -> Unit)? = null,
    onDropInboxRow: ((index: Int, before: Boolean) -> Unit)? = null,
    onDropTaskRow: ((index: Int, before: Boolean) -> Unit)? = null,
) {
    Column(
        modifier = modifier.fillMaxSize(),
    ) {
        errorMessage?.let {
            Text(
                text = it,
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(horizontal = TaskCardMetrics.HeaderLeading, vertical = 4.dp),
            )
        }

        LazyColumn(
            modifier = Modifier.weight(1f).fillMaxWidth(),
            contentPadding = PaddingValues(bottom = 96.dp),
        ) {
            if (headerContent != null) {
                item(key = "list-screen-header") {
                    headerContent()
                }
            }

            if (isToday && inboxTasks.isNotEmpty()) {
                item(key = "inbox-band-title") {
                    TaskGroupHeaderRow(
                        header = TaskGroupHeader(
                            key = "inbox-band",
                            title = inboxBandTitle,
                            iconKind = SeptenaIconKind.Inbox,
                        ),
                        modifier = Modifier.magicPlusSectionDrop(
                            id = "mp-inbox-header",
                            enabled = onDropInboxHeader != null,
                            onDrop = { onDropInboxHeader?.invoke() },
                        ),
                    )
                }
                taskCardRows(
                    tasks = inboxTasks,
                    keyPrefix = "inbox",
                    completeTitle = completeTitle,
                    canComplete = canComplete,
                    todayTitle = todayTitle,
                    todayTint = todayTint,
                    fadedTitle = fadedTitle,
                    showTodayIndicator = false,
                    showFadedIndicator = false,
                    isDark = isDarkTheme,
                    hasActiveTexture = hasActiveTexture,
                    onComplete = onComplete,
                    onOpenTask = onOpenTask,
                    rowMenuGroups = rowMenuGroups,
                    rowMenuAccessibilityLabel = rowMenuAccessibilityLabel,
                    selection = selection,
                    onTaskAction = onTaskAction,
                    onOpenGroupTarget = onOpenGroupTarget,
                    onDropRow = onDropInboxRow,
                )
            }

            if (hasLoaded && tasks.isEmpty() && inboxTasks.isEmpty() && emptyTitle.isNotBlank()) {
                item(key = "empty-state") {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 32.dp, vertical = 48.dp),
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

            taskCardRows(
                tasks = tasks,
                keyPrefix = "task",
                completeTitle = completeTitle,
                canComplete = canComplete,
                todayTitle = todayTitle,
                todayTint = todayTint,
                fadedTitle = fadedTitle,
                showTodayIndicator = !isToday,
                showFadedIndicator = showFadedIndicator,
                isDark = isDarkTheme,
                hasActiveTexture = hasActiveTexture,
                onComplete = onComplete,
                onOpenTask = onOpenTask,
                rowMenuGroups = rowMenuGroups,
                rowMenuAccessibilityLabel = rowMenuAccessibilityLabel,
                selection = selection,
                onTaskAction = onTaskAction,
                onOpenGroupTarget = onOpenGroupTarget,
                onDropRow = onDropTaskRow,
            )
        }
    }
}

private fun TaskListItem.resolvedGroup(): TaskGroupHeader? =
    group ?: groupTitle?.let { TaskGroupHeader(key = it, title = it) }

private fun LazyListScope.taskCardRows(
    tasks: List<TaskListItem>,
    keyPrefix: String,
    completeTitle: String,
    canComplete: Boolean,
    todayTitle: String,
    todayTint: Color,
    fadedTitle: String,
    showTodayIndicator: Boolean,
    showFadedIndicator: Boolean,
    isDark: Boolean,
    hasActiveTexture: Boolean,
    onComplete: (String) -> Unit,
    onOpenTask: (String) -> Unit,
    rowMenuGroups: List<List<TaskRowMenuAction>>,
    rowMenuAccessibilityLabel: String,
    selection: TaskSelection,
    onTaskAction: (String, String) -> Unit,
    onOpenGroupTarget: ((String) -> Unit)?,
    onDropRow: ((index: Int, before: Boolean) -> Unit)?,
) {
    // Compute contiguous card runs so each group paints continuous rounded glass card slices.
    val positions = computeCardPositions(tasks)

    itemsIndexed(tasks, key = { _, task -> "$keyPrefix:${task.id}" }) { index, task ->
        val header = task.resolvedGroup()
        val prevHeader = tasks.getOrNull(index - 1)?.resolvedGroup()
        if (header != null && header.key != prevHeader?.key) {
            val target = header.targetLocationKey
            TaskGroupHeaderRow(
                header = header,
                onClick = if (target != null && onOpenGroupTarget != null) {
                    { onOpenGroupTarget(target) }
                } else null,
            )
        }
        TaskCardRow(
            task = task,
            position = positions[index],
            completeTitle = completeTitle,
            canComplete = canComplete,
            todayTitle = todayTitle,
            todayTint = todayTint,
            fadedTitle = fadedTitle,
            showTodayIndicator = showTodayIndicator,
            showFadedIndicator = showFadedIndicator,
            isDark = isDark,
            hasActiveTexture = hasActiveTexture,
            onComplete = onComplete,
            onOpenTask = onOpenTask,
            rowMenuGroups = rowMenuGroups,
            rowMenuAccessibilityLabel = rowMenuAccessibilityLabel,
            selection = selection,
            onTaskAction = onTaskAction,
            dropModifier = Modifier.magicPlusRowDrop(
                id = "mp-$keyPrefix-${task.id}",
                enabled = onDropRow != null,
                onDrop = { before -> onDropRow?.invoke(index, before) },
            ),
        )
    }
}

/** Splits [tasks] into contiguous runs sharing the same group key and computes each row's card slice position. */
fun computeCardPositions(tasks: List<TaskListItem>): List<TaskCardPosition> {
    if (tasks.isEmpty()) return emptyList()
    val result = ArrayList<TaskCardPosition>(tasks.size)
    var runStart = 0
    while (runStart < tasks.size) {
        val runKey = tasks[runStart].resolvedGroup()?.key
        var runEnd = runStart + 1
        while (runEnd < tasks.size && tasks[runEnd].resolvedGroup()?.key == runKey) {
            runEnd += 1
        }
        val runSize = runEnd - runStart
        for (offset in 0 until runSize) {
            result += cardPosition(offset, runSize)
        }
        runStart = runEnd
    }
    return result
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
            MoreDotsGlyph(tint = MaterialTheme.colorScheme.onSurfaceVariant)
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
