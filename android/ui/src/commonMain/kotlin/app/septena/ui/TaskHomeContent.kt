package app.septena.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.sp
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

/** Read-only device calendar event rendered above Today / Upcoming (mirrors iOS `CalendarEventRow`). */
data class CalendarAgendaRow(
    val id: String,
    val title: String,
    val timeLabel: String? = null,
    val isAllDay: Boolean = false,
    val dayLabel: String? = null,
    /** ISO day (`YYYY-MM-DD`) used to weave Upcoming events into chronological date buckets. */
    val dayIso: String? = null,
)

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
    /** The task is in a shared project, so its row menu offers Assign To. */
    val canAssign: Boolean = false,
    /** Who does the task, when that is another member of its shared project. */
    val assigneeName: String? = null,
    val subtitle: String? = null,
    val isCompleted: Boolean = false,
    val isOnToday: Boolean = false,
    val isStarred: Boolean = false,
    val isFaded: Boolean = false,
    /** An agent handed the task over for the user to check, so its row menu offers Accept. */
    val isInReview: Boolean = false,
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
    /** Scheduled start time / range (e.g. `"14:00"` or `"14:00–15:00"`, feature `task.times`). */
    val timeSlotText: String? = null,
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
    /** On-device filing suggestion target title shown as a one-tap capsule on Inbox rows (#368). */
    val filingSuggestionLabel: String? = null,
    /** Full untruncated agent review note (`endStateNote` or fallback) for Review's Finished work rows (#412). */
    val reviewNote: String? = null,
    /** Single-line Review metadata (`Area › Project · asked {ago} · artifact`). */
    val reviewMeta: String? = null,
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

/** Icon kind for task row context-menu items (matches iOS `UIContextMenu` trailing symbols). */
enum class TaskMenuActionIcon {
    None,
    Do,
    When,
    Move,
    Tags,
    Deadline,
    Star,
    Open,
    AddReference,
    Duplicate,
    Share,
    Select,
    Delete,
    Restore,
    Check,
    Cancel,
    Assign,
}

data class TaskRowMenuAction(
    val id: String,
    val title: String,
    val isDestructive: Boolean = false,
    val selectedTitle: String? = null,
    val unselectedTitle: String? = null,
    /** Shows only on a task that can be assigned ([TaskListItem.canAssign]). */
    val needsAssignees: Boolean = false,
    /** Shows only on a task handed over for review ([TaskListItem.isInReview]). */
    val needsReview: Boolean = false,
    /** Shows only on a faded task ([TaskListItem.isFaded]). */
    val needsFaded: Boolean = false,
    val icon: TaskMenuActionIcon = TaskMenuActionIcon.None,
) {
    fun appliesTo(task: TaskListItem): Boolean =
        (task.canAssign || !needsAssignees) && (task.isInReview || !needsReview) && (task.isFaded || !needsFaded)
}

/** The last group of a list, which the user folds (Review's Faded). Its rows carry no group header. */
data class CollapsibleTaskGroup(
    val header: TaskGroupHeader,
    val tasks: List<TaskListItem>,
    val isExpanded: Boolean,
    val onToggle: () -> Unit,
    /** Shown above the rows while the group is open. */
    val banner: (@Composable () -> Unit)? = null,
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
    isUpcoming: Boolean = false,
    upcomingDayLabelForIso: ((String) -> String)? = null,
    inboxTasks: List<TaskListItem>,
    tasks: List<TaskListItem>,
    calendarEvents: List<CalendarAgendaRow> = emptyList(),
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
    onDropGroupHeader: ((targetLocationKey: String) -> Unit)? = null,
    canReorder: Boolean = false,
    onReorderInboxHeader: ((ids: List<String>) -> Unit)? = null,
    onReorderInboxRow: ((ids: List<String>, index: Int, before: Boolean) -> Unit)? = null,
    onReorderTaskRow: ((ids: List<String>, index: Int, before: Boolean) -> Unit)? = null,
    onReorderGroupHeader: ((ids: List<String>, targetLocationKey: String) -> Unit)? = null,
    onApplyFilingSuggestion: ((String) -> Unit)? = null,
    reviewAcceptTitle: String = "",
    reviewSendBackTitle: String = "",
    onAcceptReview: ((String) -> Unit)? = null,
    onSendBackReview: ((String) -> Unit)? = null,
    collapsibleGroup: CollapsibleTaskGroup? = null,
) {
    val orderedSelectionIds = if (selection.isActive) {
        (inboxTasks + tasks).map(TaskListItem::id).filter { it in selection.selectedIds }
    } else {
        emptyList()
    }
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

            if (!isUpcoming && calendarEvents.isNotEmpty()) {
                itemsIndexed(calendarEvents, key = { _, event -> "cal:${event.id}" }) { index, event ->
                    val prevDay = calendarEvents.getOrNull(index - 1)?.dayLabel
                    val showDayHeader = event.dayLabel != null && event.dayLabel != prevDay
                    val slicePos = calendarSlicePosition(calendarEvents, index)
                    if (showDayHeader && event.dayLabel != null) {
                        Text(
                            text = event.dayLabel,
                            fontSize = 12.5.sp,
                            lineHeight = 16.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(
                                start = TaskCardMetrics.HeaderLeading,
                                end = TaskCardMetrics.Margin,
                                top = if (index == 0) 4.dp else 10.dp,
                                bottom = 4.dp,
                            ),
                        )
                    }
                    CalendarAgendaCardRow(
                        event = event,
                        position = slicePos,
                        isDark = isDarkTheme,
                        hasActiveTexture = hasActiveTexture,
                    )
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
                        modifier = Modifier
                            .magicPlusSectionDrop(
                                id = "mp-inbox-header",
                                enabled = onDropInboxHeader != null,
                                onDrop = { onDropInboxHeader?.invoke() },
                            )
                            .taskReorderSectionDrop(
                                id = "reorder-inbox-header",
                                enabled = canReorder && onReorderInboxHeader != null,
                                onDrop = { ids -> onReorderInboxHeader?.invoke(ids) },
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
                    canReorder = canReorder && onReorderInboxRow != null,
                    orderedDragIds = orderedSelectionIds,
                    onReorderRow = onReorderInboxRow,
                    onReorderGroupHeader = null,
                    onApplyFilingSuggestion = onApplyFilingSuggestion,
                )
            }

            val hasUpcomingAgenda = isUpcoming && calendarEvents.isNotEmpty()
            if (hasLoaded && tasks.isEmpty() && inboxTasks.isEmpty() && collapsibleGroup == null &&
                !hasUpcomingAgenda && emptyTitle.isNotBlank()
            ) {
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

            if (isUpcoming) {
                // Chronological date buckets merging the union of task days and calendar event days
                // (mirrors Apple `TaskListView.groupedUpcomingItems` and `SeptaskKitTaskList.upcomingBuckets`).
                val tasksByDay = linkedMapOf<String, MutableList<Pair<Int, TaskListItem>>>()
                tasks.forEachIndexed { index, task ->
                    val iso = task.resolvedGroup()?.key?.removePrefix("day:") ?: return@forEachIndexed
                    tasksByDay.getOrPut(iso) { mutableListOf() }.add(index to task)
                }
                val eventsByDay = linkedMapOf<String, MutableList<CalendarAgendaRow>>()
                calendarEvents.forEach { event ->
                    val iso = event.dayIso ?: return@forEach
                    eventsByDay.getOrPut(iso) { mutableListOf() }.add(event)
                }
                val sortedDays = (tasksByDay.keys + eventsByDay.keys).sorted()
                for (dayIso in sortedDays) {
                    val dayTasks = tasksByDay[dayIso].orEmpty()
                    val dayEvents = eventsByDay[dayIso].orEmpty()
                    val targetKey = "day:$dayIso"
                    val headerLabel = dayTasks.firstOrNull()?.second?.resolvedGroup()?.title
                        ?: upcomingDayLabelForIso?.invoke(dayIso)
                        ?: dayEvents.firstOrNull()?.dayLabel
                        ?: dayIso
                    val dayHeader = TaskGroupHeader(
                        key = targetKey,
                        title = headerLabel,
                        iconKind = SeptenaIconKind.Upcoming,
                        targetLocationKey = targetKey,
                    )
                    item(key = "upcoming-header:$dayIso") {
                        val headerModifier = Modifier
                            .then(
                                if (onDropGroupHeader != null) {
                                    Modifier.magicPlusSectionDrop(
                                        id = "mp-group-upcoming-$targetKey",
                                        enabled = true,
                                        onDrop = { onDropGroupHeader(targetKey) },
                                    )
                                } else {
                                    Modifier
                                },
                            )
                            .then(
                                if (canReorder && onReorderGroupHeader != null) {
                                    Modifier.taskReorderSectionDrop(
                                        id = "reorder-group-upcoming-$targetKey",
                                        enabled = true,
                                        onDrop = { ids -> onReorderGroupHeader(ids, targetKey) },
                                    )
                                } else {
                                    Modifier
                                },
                            )
                        // Date headers are non-tappable (matching Apple `groupedUpcomingItems`).
                        TaskGroupHeaderRow(
                            header = dayHeader,
                            modifier = headerModifier,
                            onClick = null,
                        )
                    }
                    if (dayEvents.isNotEmpty()) {
                        itemsIndexed(dayEvents, key = { _, event -> "cal:$dayIso:${event.id}" }) { idx, event ->
                            CalendarAgendaCardRow(
                                event = event,
                                position = cardPosition(idx, dayEvents.size),
                                isDark = isDarkTheme,
                                hasActiveTexture = hasActiveTexture,
                            )
                        }
                    }
                    if (dayTasks.isNotEmpty()) {
                        val slicePositions = List(dayTasks.size) { i -> cardPosition(i, dayTasks.size) }
                        itemsIndexed(dayTasks, key = { _, (_, task) -> "task:${task.id}" }) { localIdx, (globalIdx, task) ->
                            TaskCardRow(
                                task = task,
                                position = slicePositions[localIdx],
                                completeTitle = completeTitle,
                                canComplete = canComplete,
                                todayTitle = todayTitle,
                                todayTint = todayTint,
                                fadedTitle = fadedTitle,
                                showTodayIndicator = false,
                                showFadedIndicator = showFadedIndicator,
                                isDark = isDarkTheme,
                                hasActiveTexture = hasActiveTexture,
                                onComplete = onComplete,
                                onOpenTask = onOpenTask,
                                rowMenuGroups = rowMenuGroups,
                                rowMenuAccessibilityLabel = rowMenuAccessibilityLabel,
                                selection = selection,
                                onTaskAction = onTaskAction,
                                canReorder = canReorder && onReorderTaskRow != null,
                                orderedDragIds = orderedSelectionIds,
                                onApplyFilingSuggestion = onApplyFilingSuggestion,
                                dropModifier = Modifier
                                    .magicPlusRowDrop(
                                        id = "mp-task-${task.id}",
                                        enabled = onDropTaskRow != null,
                                        onDrop = { before -> onDropTaskRow?.invoke(globalIdx, before) },
                                    )
                                    .taskReorderRowDrop(
                                        id = "reorder-task-${task.id}",
                                        taskId = task.id,
                                        enabled = canReorder && onReorderTaskRow != null,
                                        onDrop = { ids, before -> onReorderTaskRow?.invoke(ids, globalIdx, before) },
                                    ),
                            )
                        }
                    }
                }
            } else {
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
                    onDropGroupHeader = onDropGroupHeader,
                    canReorder = canReorder && onReorderTaskRow != null,
                    orderedDragIds = orderedSelectionIds,
                    onReorderRow = onReorderTaskRow,
                    onReorderGroupHeader = onReorderGroupHeader,
                    onApplyFilingSuggestion = onApplyFilingSuggestion,
                    reviewAcceptTitle = reviewAcceptTitle,
                    reviewSendBackTitle = reviewSendBackTitle,
                    onAcceptReview = onAcceptReview,
                    onSendBackReview = onSendBackReview,
                )
            }

            collapsibleGroup?.let { group ->
                item(key = "collapsible-header:${group.header.key}") {
                    TaskGroupHeaderRow(
                        header = group.header,
                        isExpanded = group.isExpanded,
                        onClick = group.onToggle,
                    )
                }
                if (group.isExpanded) {
                    group.banner?.let { banner ->
                        item(key = "collapsible-banner:${group.header.key}") { banner() }
                    }
                    taskCardRows(
                        tasks = group.tasks,
                        keyPrefix = group.header.key,
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
                        onOpenGroupTarget = null,
                        onDropRow = null,
                    )
                }
            }
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
    onDropGroupHeader: ((targetLocationKey: String) -> Unit)? = null,
    canReorder: Boolean = false,
    orderedDragIds: List<String> = emptyList(),
    onReorderRow: ((ids: List<String>, index: Int, before: Boolean) -> Unit)? = null,
    onReorderGroupHeader: ((ids: List<String>, targetLocationKey: String) -> Unit)? = null,
    onApplyFilingSuggestion: ((String) -> Unit)? = null,
    reviewAcceptTitle: String = "",
    reviewSendBackTitle: String = "",
    onAcceptReview: ((String) -> Unit)? = null,
    onSendBackReview: ((String) -> Unit)? = null,
) {
    // Compute contiguous card runs so each group paints continuous rounded glass card slices.
    val positions = computeCardPositions(tasks)

    itemsIndexed(tasks, key = { _, task -> "$keyPrefix:${task.id}" }) { index, task ->
        val header = task.resolvedGroup()
        val prevHeader = tasks.getOrNull(index - 1)?.resolvedGroup()
        if (header != null && header.key != prevHeader?.key) {
            val target = header.targetLocationKey
            val headerModifier = Modifier
                .then(
                    if (target != null && onDropGroupHeader != null) {
                        Modifier.magicPlusSectionDrop(
                            id = "mp-group-$keyPrefix-${header.key}",
                            enabled = true,
                            onDrop = { onDropGroupHeader(target) },
                        )
                    } else {
                        Modifier
                    },
                )
                .then(
                    if (target != null && canReorder && onReorderGroupHeader != null) {
                        Modifier.taskReorderSectionDrop(
                            id = "reorder-group-$keyPrefix-${header.key}",
                            enabled = true,
                            onDrop = { ids -> onReorderGroupHeader(ids, target) },
                        )
                    } else {
                        Modifier
                    },
                )
            TaskGroupHeaderRow(
                header = header,
                modifier = headerModifier,
                onClick = if (target != null && onOpenGroupTarget != null) {
                    { onOpenGroupTarget(target) }
                } else null,
            )
        }
        if (task.reviewNote != null && onAcceptReview != null && onSendBackReview != null) {
            ReviewTaskCardRow(
                task = task,
                position = positions[index],
                acceptTitle = reviewAcceptTitle,
                sendBackTitle = reviewSendBackTitle,
                isDark = isDark,
                hasActiveTexture = hasActiveTexture,
                rowMenuGroups = rowMenuGroups,
                rowMenuAccessibilityLabel = rowMenuAccessibilityLabel,
                selection = selection,
                onOpenTask = onOpenTask,
                onAccept = onAcceptReview,
                onSendBack = onSendBackReview,
                onTaskAction = onTaskAction,
            )
        } else {
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
                canReorder = canReorder,
                orderedDragIds = orderedDragIds,
                onApplyFilingSuggestion = onApplyFilingSuggestion,
                dropModifier = Modifier
                    .magicPlusRowDrop(
                        id = "mp-$keyPrefix-${task.id}",
                        enabled = onDropRow != null,
                        onDrop = { before -> onDropRow?.invoke(index, before) },
                    )
                    .taskReorderRowDrop(
                        id = "reorder-$keyPrefix-${task.id}",
                        taskId = task.id,
                        enabled = canReorder && onReorderRow != null,
                        onDrop = { ids, before -> onReorderRow?.invoke(ids, index, before) },
                    ),
            )
        }
    }
}

/** Single read-only calendar agenda row framed inside a glass card slice (Today & Upcoming). */
@Composable
private fun CalendarAgendaCardRow(
    event: CalendarAgendaRow,
    position: TaskCardPosition,
    isDark: Boolean,
    hasActiveTexture: Boolean,
) {
    TaskCardSlice(
        position = position,
        isSelected = false,
        isDark = isDark,
        hasActiveTexture = hasActiveTexture,
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = TaskCardMetrics.ContentInset, vertical = 6.dp),
        ) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier.width(TaskCardMetrics.LeadingColumnWidth + 14.dp),
            ) {
                if (event.timeLabel != null) {
                    Text(
                        text = event.timeLabel,
                        style = TextStyle(
                            fontSize = 11.sp,
                            lineHeight = 14.sp,
                            fontFeatureSettings = "tnum",
                        ),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                    )
                }
            }
            Spacer(modifier = Modifier.width(6.dp))
            Text(
                text = event.title,
                fontSize = 13.5.sp,
                lineHeight = 18.sp,
                color = if (event.isAllDay) {
                    MaterialTheme.colorScheme.onSurfaceVariant
                } else {
                    MaterialTheme.colorScheme.onSurface
                },
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

/** Card position for a calendar agenda row, grouping rows that share the same day header. */
private fun calendarSlicePosition(events: List<CalendarAgendaRow>, index: Int): TaskCardPosition {
    val day = events[index].dayLabel
    var start = index
    while (start > 0 && events[start - 1].dayLabel == day) start -= 1
    var end = index
    while (end + 1 < events.size && events[end + 1].dayLabel == day) end += 1
    return cardPosition(index - start, end - start + 1)
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
