package app.septena.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Fill
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * Shared leading-grid and card geometry matching iOS `TaskCardMetrics` + `Theme`:
 * one center X (`HeaderLeading + LeadingColumnWidth / 2`) for the Today sun,
 * section icons, area emojis, project rings, and task checkboxes; and one text X
 * (`HeaderLeading + LeadingColumnWidth + IconTextGap`) for the screen title,
 * area/project group headers, and task titles.
 */
object TaskCardMetrics {
    val Margin: Dp = 16.dp
    val ContentInset: Dp = 12.dp
    val HeaderLeading: Dp = Margin + ContentInset
    val LeadingColumnWidth: Dp = 28.dp
    val IconTextGap: Dp = 10.dp
    val Radius: Dp = 14.dp
    val GroupGap: Dp = 10.dp
    val TitleInsetInCard: Dp = ContentInset + LeadingColumnWidth + IconTextGap
}

/** A row's position inside a continuous glass-ish task card (mirrors iOS `TaskCardPosition`). */
enum class TaskCardPosition {
    Solo,
    Top,
    Middle,
    Bottom;

    fun shape(): RoundedCornerShape {
        val top = if (this == Top || this == Solo) TaskCardMetrics.Radius else 0.dp
        val bottom = if (this == Bottom || this == Solo) TaskCardMetrics.Radius else 0.dp
        return RoundedCornerShape(topStart = top, topEnd = top, bottomEnd = bottom, bottomStart = bottom)
    }

    val hasBottomDivider: Boolean get() = this == Top || this == Middle
    val trailingGap: Dp get() = if (this == Bottom || this == Solo) TaskCardMetrics.GroupGap else 0.dp
}

fun cardPosition(index: Int, count: Int): TaskCardPosition = when {
    count <= 1 -> TaskCardPosition.Solo
    index == 0 -> TaskCardPosition.Top
    index == count - 1 -> TaskCardPosition.Bottom
    else -> TaskCardPosition.Middle
}

/** Icon family for list headers, group headers, nav dropdown, and sidebar. */
enum class SeptenaIconKind {
    None,
    Today,
    Inbox,
    Review,
    Agent,
    Upcoming,
    Repeating,
    Anytime,
    Starred,
    Faded,
    Logbook,
    RecentlyDeleted,
    Area,
    Project,
    Settings,
}

/** Group header shown above a card of related tasks (area, project, Inbox band, or agent stage). */
data class TaskGroupHeader(
    val key: String,
    val title: String,
    val iconKind: SeptenaIconKind = SeptenaIconKind.None,
    val emoji: String? = null,
    val targetLocationKey: String? = null,
)

/**
 * Translucent glass-ish card slice matching iOS `TaskCardChrome`: continuous
 * rounded corners on the outer card edges, frosted surface over the canvas &
 * Header Wash, crisp hairline rim, top specular sheen, and inset row dividers.
 */
@Composable
fun TaskCardSlice(
    position: TaskCardPosition,
    isSelected: Boolean,
    isDark: Boolean,
    hasActiveTexture: Boolean,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val shape = position.shape()
    val cardFill = when {
        isSelected -> MaterialTheme.colorScheme.primary.copy(alpha = SELECTION_WASH_ALPHA)
        isDark -> MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = if (hasActiveTexture) 0.74f else 0.86f)
        else -> Color.White.copy(alpha = if (hasActiveTexture) 0.76f else 0.90f)
    }
    val rimColor = when {
        isSelected -> MaterialTheme.colorScheme.primary.copy(alpha = 0.28f)
        isDark -> Color.White.copy(alpha = if (hasActiveTexture) 0.10f else 0.07f)
        hasActiveTexture -> Color.White.copy(alpha = 0.65f)
        else -> MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.40f)
    }
    val topSheen = if (!isSelected && (position == TaskCardPosition.Top || position == TaskCardPosition.Solo)) {
        Color.White.copy(alpha = if (isDark) 0.12f else 0.72f)
    } else {
        Color.Transparent
    }
    val dividerColor = MaterialTheme.colorScheme.outlineVariant.copy(alpha = if (isDark) 0.34f else 0.45f)

    Box(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = TaskCardMetrics.Margin)
            .padding(bottom = position.trailingGap)
            .clip(shape)
            .background(cardFill, shape)
            .border(width = 0.65.dp, color = rimColor, shape = shape)
            .drawWithContent {
                drawContent()
                if (topSheen.alpha > 0f) {
                    drawLine(
                        color = topSheen,
                        start = Offset(0f, 0.5.dp.toPx()),
                        end = Offset(size.width, 0.5.dp.toPx()),
                        strokeWidth = 0.75.dp.toPx(),
                    )
                }
                if (position.hasBottomDivider && !isSelected) {
                    val y = size.height - 0.35.dp.toPx()
                    drawLine(
                        color = dividerColor,
                        start = Offset(TaskCardMetrics.TitleInsetInCard.toPx(), y),
                        end = Offset(size.width - TaskCardMetrics.ContentInset.toPx(), y),
                        strokeWidth = 0.5.dp.toPx(),
                    )
                }
            },
    ) {
        content()
    }
}

/**
 * Custom iOS-aligned checkbox: slightly smaller (`17.dp`) and calmer, lower-contrast
 * stroke than Material's default Checkbox, optically centered inside
 * [TaskCardMetrics.LeadingColumnWidth].
 */
@Composable
fun SeptenaTaskCheckbox(
    checked: Boolean,
    enabled: Boolean,
    accessibilityLabel: String,
    isDark: Boolean,
    isSelectionCircle: Boolean = false,
    onToggle: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val fillColor = MaterialTheme.colorScheme.primary
    val checkColor = MaterialTheme.colorScheme.onPrimary
    val strokeColor = MaterialTheme.colorScheme.onSurface.copy(
        alpha = when {
            !enabled && !checked -> 0.16f
            isDark -> 0.34f
            else -> 0.28f
        },
    )
    val interactionSource = remember { MutableInteractionSource() }
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .width(TaskCardMetrics.LeadingColumnWidth)
            .height(30.dp)
            .semantics { contentDescription = accessibilityLabel }
            .clickable(
                enabled = enabled,
                role = Role.Checkbox,
                interactionSource = interactionSource,
                indication = null,
                onClick = onToggle,
            ),
    ) {
        Canvas(modifier = Modifier.size(17.dp)) {
            val strokePx = 1.35.dp.toPx()
            val inset = strokePx / 2f
            val boxSize = Size(size.width - strokePx, size.height - strokePx)
            if (isSelectionCircle) {
                val radius = (size.minDimension - strokePx) / 2f
                val center = Offset(size.width / 2f, size.height / 2f)
                if (checked) {
                    drawCircle(color = fillColor, radius = size.minDimension / 2f, center = center)
                } else {
                    drawCircle(color = strokeColor, radius = radius, center = center, style = Stroke(width = strokePx))
                }
            } else {
                val corner = CornerRadius(4.5.dp.toPx(), 4.5.dp.toPx())
                if (checked) {
                    drawRoundRect(color = fillColor, cornerRadius = corner)
                } else {
                    drawRoundRect(
                        color = strokeColor,
                        topLeft = Offset(inset, inset),
                        size = boxSize,
                        cornerRadius = corner,
                        style = Stroke(width = strokePx),
                    )
                }
            }
            if (checked) {
                val checkPath = Path().apply {
                    moveTo(size.width * 0.26f, size.height * 0.52f)
                    lineTo(size.width * 0.43f, size.height * 0.69f)
                    lineTo(size.width * 0.75f, size.height * 0.33f)
                }
                drawPath(
                    path = checkPath,
                    color = checkColor,
                    style = Stroke(width = 1.8.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round),
                )
            }
        }
    }
}

/**
 * Section/Area/Project group header aligned to the shared leading grid:
 * icon/emoji centers over task checkboxes; larger semibold title starts at the
 * exact task-title X (mirrors iOS `groupHeaderBody` + `sectionGroupHeaderTitleStyle`).
 */
@Composable
fun TaskGroupHeaderRow(
    header: TaskGroupHeader,
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null,
) {
    val clickableModifier = if (onClick != null) {
        Modifier.clickable(onClick = onClick)
    } else {
        Modifier
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(TaskCardMetrics.IconTextGap),
        modifier = modifier
            .fillMaxWidth()
            .then(clickableModifier)
            .padding(
                start = TaskCardMetrics.HeaderLeading,
                end = TaskCardMetrics.Margin,
                top = 18.dp,
                bottom = 7.dp,
            ),
    ) {
        val hasLeadingGlyph = header.emoji != null || header.iconKind != SeptenaIconKind.None
        if (hasLeadingGlyph) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier.width(TaskCardMetrics.LeadingColumnWidth),
            ) {
                if (header.emoji != null) {
                    Text(
                        text = header.emoji,
                        fontSize = 18.sp,
                        lineHeight = 20.sp,
                    )
                } else {
                    SeptenaGlyph(
                        kind = header.iconKind,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        size = if (header.iconKind == SeptenaIconKind.Project) 16.dp else 18.dp,
                    )
                }
            }
        }
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
            modifier = Modifier.weight(1f),
        ) {
            Text(
                text = header.title,
                fontSize = 18.sp,
                lineHeight = 22.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (onClick != null) {
                ChevronRightGlyph(
                    tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.55f),
                    size = 13.dp,
                )
            }
        }
    }
}

/**
 * Canonical iOS-aligned task row inside a glass-ish card slice:
 * - Leading checkbox centered vertically with the title line on the shared grid.
 * - Full iOS trailing metadata order: Today/Faded pill -> Deadline/Date ->
 *   Checklist `done/total` -> Reminder bell+time -> Repeat -> Gold Star ->
 *   Notes -> Attachment -> Dialogue-with-sparkles agent provenance -> subtle `⋮`.
 * - Quiet second line aligned to the title X for subtitle (project/area) and
 *   compact outlined tag pills so titles never crush on narrow phones.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun TaskCardRow(
    task: TaskListItem,
    position: TaskCardPosition,
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
    dropModifier: Modifier = Modifier,
) {
    val showTodayPill = showTodayIndicator && task.isOnToday && !task.isCompleted && !task.isFaded
    val showFadedPill = showFadedIndicator && task.isFaded && !task.isCompleted
    var menuExpanded by remember(task.id) { mutableStateOf(false) }
    val selecting = selection.isActive
    val selected = task.id in selection.selectedIds
    val mutedInk = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.80f)
    val overdueRed = if (isDark) Color(0xFFFF453A) else Color(0xFFFF3B30)
    val showSubtitleLine = task.subtitle != null || task.tagNames.isNotEmpty()
    val hasLeadingSlot = selecting || canComplete || task.isCompleted

    TaskCardSlice(
        position = position,
        isSelected = selected,
        isDark = isDark,
        hasActiveTexture = hasActiveTexture,
        modifier = dropModifier,
    ) {
        Box {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .alpha(task.opacity)
                    .selectableTaskRow(
                        taskId = task.id,
                        selection = selection,
                        onOpen = onOpenTask,
                        onMenu = { if (rowMenuGroups.isNotEmpty()) menuExpanded = true },
                    )
                    .padding(
                        horizontal = TaskCardMetrics.ContentInset,
                        vertical = 10.dp,
                    ),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (hasLeadingSlot) {
                        if (selecting) {
                            SeptenaTaskCheckbox(
                                checked = selected,
                                enabled = true,
                                accessibilityLabel = selection.toggleLabel,
                                isDark = isDark,
                                isSelectionCircle = true,
                                onToggle = { selection.onToggle(task.id) },
                            )
                        } else {
                            SeptenaTaskCheckbox(
                                checked = task.isCompleted,
                                enabled = canComplete && !task.isCompleted,
                                accessibilityLabel = completeTitle,
                                isDark = isDark,
                                onToggle = { if (!task.isCompleted) onComplete(task.id) },
                            )
                        }
                        Spacer(modifier = Modifier.width(TaskCardMetrics.IconTextGap))
                    }

                    Text(
                        text = task.title,
                        style = MaterialTheme.typography.bodyLarge.copy(
                            fontSize = 16.sp,
                            lineHeight = 21.sp,
                            textDecoration = if (task.isCompleted) TextDecoration.LineThrough else TextDecoration.None,
                        ),
                        color = if (task.isCompleted) {
                            MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.72f)
                        } else {
                            MaterialTheme.colorScheme.onSurface
                        },
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )

                    // Trailing metadata cluster (exact iOS order; row menu lives on long-press).
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        modifier = Modifier.padding(start = 8.dp),
                    ) {
                        if (showTodayPill) {
                            StatusGlassPill(
                                label = todayTitle,
                                iconKind = SeptenaIconKind.Today,
                                iconTint = todayTint,
                                isDark = isDark,
                            )
                        } else if (showFadedPill && fadedTitle.isNotEmpty()) {
                            StatusGlassPill(
                                label = fadedTitle,
                                iconKind = SeptenaIconKind.Faded,
                                iconTint = mutedInk,
                                isDark = isDark,
                            )
                        }

                        // Deadline / Scheduled / Completed date.
                        when {
                            task.deadlineText != null -> {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(3.dp),
                                ) {
                                    if (task.deadlineShowsFlag) {
                                        DeadlineFlagGlyph(tint = mutedInk, size = 11.dp)
                                    }
                                    Text(
                                        text = task.deadlineText,
                                        fontSize = 12.sp,
                                        lineHeight = 14.sp,
                                        fontWeight = if (task.deadlineIsRed) FontWeight.SemiBold else FontWeight.Normal,
                                        color = if (task.deadlineIsRed) overdueRed else mutedInk,
                                        maxLines = 1,
                                    )
                                }
                            }
                            task.scheduledText != null -> {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(3.dp),
                                ) {
                                    CalendarSmallGlyph(tint = mutedInk, size = 11.dp)
                                    Text(
                                        text = task.scheduledText,
                                        fontSize = 12.sp,
                                        lineHeight = 14.sp,
                                        color = mutedInk,
                                        maxLines = 1,
                                    )
                                }
                            }
                            task.completedDateText != null -> {
                                Text(
                                    text = task.completedDateText,
                                    fontSize = 12.sp,
                                    lineHeight = 14.sp,
                                    color = mutedInk,
                                    maxLines = 1,
                                )
                            }
                        }

                        // Scheduled time slot (`14:00` or `14:00–15:00`, feature `task.times`).
                        if (!task.isCompleted && task.timeSlotText != null) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(2.dp),
                            ) {
                                ClockSmallGlyph(tint = mutedInk, size = 11.dp)
                                Text(
                                    text = task.timeSlotText,
                                    fontSize = 11.5.sp,
                                    lineHeight = 13.sp,
                                    color = mutedInk,
                                    maxLines = 1,
                                )
                            }
                        }

                        // Checklist summary (`done/total`).
                        if (task.checklistTotal > 0) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(2.dp),
                            ) {
                                ChecklistSmallGlyph(tint = mutedInk, size = 11.dp)
                                Text(
                                    text = "${task.checklistDone}/${task.checklistTotal}",
                                    fontSize = 11.5.sp,
                                    lineHeight = 13.sp,
                                    color = mutedInk,
                                    maxLines = 1,
                                )
                            }
                        }

                        // Timed reminder badge (bell + time; red when past due).
                        task.reminderText?.let { reminder ->
                            val bellTint = if (task.reminderIsPastDue) overdueRed else mutedInk
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(2.dp),
                            ) {
                                BellSmallGlyph(tint = bellTint, size = 11.dp)
                                Text(
                                    text = reminder,
                                    fontSize = 11.5.sp,
                                    lineHeight = 13.sp,
                                    fontWeight = if (task.reminderIsPastDue) FontWeight.Medium else FontWeight.Normal,
                                    color = bellTint,
                                    maxLines = 1,
                                )
                            }
                        }

                        // Repeat glyph.
                        if (task.isRepeating) {
                            RepeatSmallGlyph(tint = mutedInk, size = 12.dp)
                        }

                        // Starred indicator (gold star).
                        if (task.isStarred) {
                            StarGlyph(filled = true, tint = todayTint, size = 12.dp)
                        }

                        // Notes glyph (suppressed when agent-authored, matching iOS).
                        if (task.hasNotes && task.agentName == null) {
                            NotesSmallGlyph(tint = mutedInk, size = 11.dp)
                        }

                        // Attachment indicator.
                        if (task.hasAttachments) {
                            AttachmentSmallGlyph(tint = mutedInk, size = 11.dp)
                        }

                        // Agent provenance: dialogue bubble with sparkles (iOS `text.bubble.badge.sparkles`).
                        task.agentName?.let { name ->
                            AgentSparkleBubbleGlyph(
                                tint = mutedInk,
                                size = 14.dp,
                                modifier = Modifier.semantics { contentDescription = name },
                            )
                        }
                    }
                }

                if (showSubtitleLine) {
                    val startPad = if (hasLeadingSlot) {
                        TaskCardMetrics.LeadingColumnWidth + TaskCardMetrics.IconTextGap
                    } else {
                        0.dp
                    }
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(start = startPad, top = 3.dp),
                    ) {
                        task.subtitle?.let { sub ->
                            Text(
                                text = sub,
                                fontSize = 12.5.sp,
                                lineHeight = 16.sp,
                                color = mutedInk,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.align(Alignment.CenterVertically),
                            )
                        }
                        val visibleTags = task.tagNames.take(2)
                        val overflowCount = (task.tagNames.size - visibleTags.size).coerceAtLeast(0)
                        visibleTags.forEach { tag ->
                            TagOutlineChip(text = tag, tint = mutedInk)
                        }
                        if (overflowCount > 0) {
                            Text(
                                text = "+$overflowCount",
                                fontSize = 11.sp,
                                lineHeight = 14.sp,
                                color = mutedInk,
                                modifier = Modifier.align(Alignment.CenterVertically),
                            )
                        }
                    }
                }
            }

            if (rowMenuGroups.isNotEmpty() && !selecting) {
                SeptenaContextMenu(
                    expanded = menuExpanded,
                    onDismissRequest = { menuExpanded = false },
                    isDark = isDark,
                    groups = rowMenuGroups,
                    isTaskStarred = task.isStarred,
                    accessibilityLabel = rowMenuAccessibilityLabel,
                    onAction = { actionId -> onTaskAction(task.id, actionId) },
                )
            }
        }
    }
}

@Composable
private fun StatusGlassPill(
    label: String,
    iconKind: SeptenaIconKind,
    iconTint: Color,
    isDark: Boolean,
) {
    val bg = if (isDark) {
        Color.White.copy(alpha = 0.08f)
    } else {
        MaterialTheme.colorScheme.onSurface.copy(alpha = 0.05f)
    }
    val border = if (isDark) {
        Color.White.copy(alpha = 0.12f)
    } else {
        MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f)
    }
    Surface(
        color = bg,
        shape = CircleShape,
        modifier = Modifier.border(0.5.dp, border, CircleShape),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(3.dp),
            modifier = Modifier.padding(horizontal = 7.dp, vertical = 2.dp),
        ) {
            SeptenaGlyph(kind = iconKind, tint = iconTint, size = 10.dp)
            Text(
                text = label,
                fontSize = 11.sp,
                lineHeight = 13.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun TagOutlineChip(text: String, tint: Color) {
    Box(
        modifier = Modifier
            .border(0.75.dp, tint.copy(alpha = 0.35f), CircleShape)
            .padding(horizontal = 6.dp, vertical = 1.dp),
    ) {
        Text(
            text = text,
            fontSize = 11.sp,
            lineHeight = 14.sp,
            color = tint,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/**
 * iOS-style floating context menu (`UIContextMenu`): wider (`248.dp`), compact
 * `38.dp` rows, `14.dp` rounded glass-ish container, recessed `6.dp` section
 * separators, hairline inner dividers, and trailing icons on every action.
 */
@Composable
fun SeptenaContextMenu(
    expanded: Boolean,
    onDismissRequest: () -> Unit,
    isDark: Boolean,
    groups: List<List<TaskRowMenuAction>>,
    isTaskStarred: Boolean,
    accessibilityLabel: String,
    onAction: (String) -> Unit,
) {
    val menuBg = if (isDark) {
        MaterialTheme.colorScheme.surfaceContainerHigh
    } else {
        Color(0xF7FFFFFF)
    }
    val separatorBand = if (isDark) {
        Color.Black.copy(alpha = 0.28f)
    } else {
        MaterialTheme.colorScheme.onSurface.copy(alpha = 0.06f)
    }
    val rowDivider = MaterialTheme.colorScheme.outlineVariant.copy(alpha = if (isDark) 0.32f else 0.42f)
    val destructiveRed = if (isDark) Color(0xFFFF453A) else Color(0xFFFF3B30)

    DropdownMenu(
        expanded = expanded,
        onDismissRequest = onDismissRequest,
        shape = RoundedCornerShape(14.dp),
        containerColor = menuBg,
        tonalElevation = 0.dp,
        shadowElevation = 10.dp,
        modifier = Modifier
            .width(248.dp)
            .semantics { contentDescription = accessibilityLabel },
    ) {
        groups.forEachIndexed { groupIndex, group ->
            if (groupIndex > 0) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(6.dp)
                        .background(separatorBand),
                )
            }
            group.forEachIndexed { itemIndex, action ->
                if (itemIndex > 0) {
                    HorizontalDivider(thickness = 0.5.dp, color = rowDivider)
                }
                val label = if (action.selectedTitle != null || action.unselectedTitle != null) {
                    if (isTaskStarred) action.selectedTitle ?: action.title
                    else action.unselectedTitle ?: action.title
                } else {
                    action.title
                }
                val ink = if (action.isDestructive) destructiveRed else MaterialTheme.colorScheme.onSurface
                val iconTint = if (action.isDestructive) destructiveRed else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.85f)
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable {
                            onDismissRequest()
                            onAction(action.id)
                        }
                        .padding(horizontal = 16.dp, vertical = 9.dp),
                ) {
                    Text(
                        text = label,
                        fontSize = 15.5.sp,
                        lineHeight = 20.sp,
                        color = ink,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    if (action.icon != TaskMenuActionIcon.None) {
                        Spacer(modifier = Modifier.width(12.dp))
                        Box(
                            contentAlignment = Alignment.Center,
                            modifier = Modifier.size(20.dp),
                        ) {
                            TaskMenuActionGlyph(
                                icon = action.icon,
                                tint = iconTint,
                                isStarFilled = isTaskStarred,
                                size = 17.dp,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun TaskMenuActionGlyph(
    icon: TaskMenuActionIcon,
    tint: Color,
    isStarFilled: Boolean,
    size: Dp,
) {
    when (icon) {
        TaskMenuActionIcon.None -> Unit
        TaskMenuActionIcon.When -> CalendarSmallGlyph(tint = tint, size = size)
        TaskMenuActionIcon.Move -> SeptenaGlyph(kind = SeptenaIconKind.Area, tint = tint, size = size)
        TaskMenuActionIcon.Deadline -> DeadlineFlagGlyph(tint = tint, size = size)
        TaskMenuActionIcon.Star -> StarGlyph(filled = isStarFilled, tint = tint, size = size)
        TaskMenuActionIcon.Select -> ChecklistSmallGlyph(tint = tint, size = size)
        TaskMenuActionIcon.Delete -> SeptenaGlyph(kind = SeptenaIconKind.RecentlyDeleted, tint = tint, size = size)
        TaskMenuActionIcon.Restore -> RepeatSmallGlyph(tint = tint, size = size)
        TaskMenuActionIcon.Check -> CheckmarkGlyph(tint = tint, size = size)
        TaskMenuActionIcon.Tags -> TagSmallGlyph(tint = tint, size = size)
        TaskMenuActionIcon.Open -> Canvas(modifier = Modifier.size(size)) {
            val w = this.size.width
            val h = this.size.height
            val stroke = (w * 0.095f).coerceAtLeast(1.3.dp.toPx())
            drawRoundRect(
                color = tint,
                topLeft = Offset(w * 0.14f, h * 0.24f),
                size = Size(w * 0.62f, h * 0.62f),
                cornerRadius = CornerRadius(w * 0.14f, w * 0.14f),
                style = Stroke(width = stroke),
            )
            drawLine(tint, Offset(w * 0.46f, h * 0.54f), Offset(w * 0.86f, h * 0.14f), strokeWidth = stroke, cap = StrokeCap.Round)
            val arrow = Path().apply {
                moveTo(w * 0.62f, h * 0.14f)
                lineTo(w * 0.86f, h * 0.14f)
                lineTo(w * 0.86f, h * 0.38f)
            }
            drawPath(arrow, tint, style = Stroke(width = stroke, cap = StrokeCap.Round, join = StrokeJoin.Round))
        }
        TaskMenuActionIcon.Duplicate -> Canvas(modifier = Modifier.size(size)) {
            val w = this.size.width
            val h = this.size.height
            val stroke = (w * 0.095f).coerceAtLeast(1.3.dp.toPx())
            val r = CornerRadius(w * 0.12f, w * 0.12f)
            drawRoundRect(
                color = tint,
                topLeft = Offset(w * 0.32f, h * 0.32f),
                size = Size(w * 0.56f, h * 0.56f),
                cornerRadius = r,
                style = Stroke(width = stroke),
            )
            val back = Path().apply {
                moveTo(w * 0.32f, h * 0.68f)
                lineTo(w * 0.18f, h * 0.68f)
                quadraticTo(w * 0.12f, h * 0.68f, w * 0.12f, h * 0.62f)
                lineTo(w * 0.12f, h * 0.18f)
                quadraticTo(w * 0.12f, h * 0.12f, w * 0.18f, h * 0.12f)
                lineTo(w * 0.62f, h * 0.12f)
                quadraticTo(w * 0.68f, h * 0.12f, w * 0.68f, h * 0.18f)
                lineTo(w * 0.68f, h * 0.32f)
            }
            drawPath(back, tint, style = Stroke(width = stroke, cap = StrokeCap.Round, join = StrokeJoin.Round))
        }
        TaskMenuActionIcon.Share -> Canvas(modifier = Modifier.size(size)) {
            val w = this.size.width
            val h = this.size.height
            val stroke = (w * 0.095f).coerceAtLeast(1.3.dp.toPx())
            drawLine(tint, Offset(w * 0.50f, h * 0.60f), Offset(w * 0.50f, h * 0.14f), strokeWidth = stroke, cap = StrokeCap.Round)
            val arrow = Path().apply {
                moveTo(w * 0.32f, h * 0.32f)
                lineTo(w * 0.50f, h * 0.14f)
                lineTo(w * 0.68f, h * 0.32f)
            }
            drawPath(arrow, tint, style = Stroke(width = stroke, cap = StrokeCap.Round, join = StrokeJoin.Round))
            val box = Path().apply {
                moveTo(w * 0.30f, h * 0.42f)
                lineTo(w * 0.18f, h * 0.42f)
                lineTo(w * 0.18f, h * 0.86f)
                lineTo(w * 0.82f, h * 0.86f)
                lineTo(w * 0.82f, h * 0.42f)
                lineTo(w * 0.70f, h * 0.42f)
            }
            drawPath(box, tint, style = Stroke(width = stroke, cap = StrokeCap.Round, join = StrokeJoin.Round))
        }
        TaskMenuActionIcon.Cancel -> Canvas(modifier = Modifier.size(size)) {
            val w = this.size.width
            val h = this.size.height
            val stroke = (w * 0.10f).coerceAtLeast(1.4.dp.toPx())
            drawLine(tint, Offset(w * 0.24f, h * 0.24f), Offset(w * 0.76f, h * 0.76f), strokeWidth = stroke, cap = StrokeCap.Round)
            drawLine(tint, Offset(w * 0.76f, h * 0.24f), Offset(w * 0.24f, h * 0.76f), strokeWidth = stroke, cap = StrokeCap.Round)
        }
    }
}

// MARK: - Crisp KMP Canvas glyphs (matches iOS SF Symbols cleanly without extra dependencies)

/**
 * Dialogue bubble with sparkles (`text.bubble.badge.sparkles` on iOS) for
 * agent-authored task provenance.
 */
@Composable
fun AgentSparkleBubbleGlyph(
    tint: Color,
    size: Dp = 15.dp,
    modifier: Modifier = Modifier,
) {
    Canvas(modifier = modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height
        val stroke = (w * 0.095f).coerceAtLeast(1.1.dp.toPx())

        // Speech bubble body occupying lower-left ~78% so sparkles sit cleanly top-right.
        val left = w * 0.08f
        val top = h * 0.22f
        val right = w * 0.78f
        val bottom = h * 0.78f
        val r = w * 0.14f
        val bubble = Path().apply {
            moveTo(left + r, top)
            lineTo(right - r, top)
            quadraticTo(right, top, right, top + r)
            lineTo(right, bottom - r)
            quadraticTo(right, bottom, right - r, bottom)
            lineTo(left + w * 0.26f, bottom)
            lineTo(left + w * 0.08f, h * 0.93f)
            lineTo(left + w * 0.12f, bottom)
            lineTo(left + r, bottom)
            quadraticTo(left, bottom, left, bottom - r)
            lineTo(left, top + r)
            quadraticTo(left, top, left + r, top)
            close()
        }
        drawPath(
            path = bubble,
            color = tint,
            style = Stroke(width = stroke, cap = StrokeCap.Round, join = StrokeJoin.Round),
        )

        // Two tiny dialogue text bars inside bubble.
        val lineStroke = (stroke * 0.85f).coerceAtLeast(1.dp.toPx())
        drawLine(
            color = tint,
            start = Offset(left + w * 0.14f, top + (bottom - top) * 0.38f),
            end = Offset(right - w * 0.14f, top + (bottom - top) * 0.38f),
            strokeWidth = lineStroke,
            cap = StrokeCap.Round,
        )
        drawLine(
            color = tint,
            start = Offset(left + w * 0.14f, top + (bottom - top) * 0.65f),
            end = Offset(right - w * 0.28f, top + (bottom - top) * 0.65f),
            strokeWidth = lineStroke,
            cap = StrokeCap.Round,
        )

        // Primary 4-point sparkle at top-right.
        drawFourPointSparkle(
            center = Offset(w * 0.80f, h * 0.22f),
            radius = w * 0.17f,
            color = tint,
        )
        // Tiny companion sparkle beside it.
        drawFourPointSparkle(
            center = Offset(w * 0.58f, h * 0.11f),
            radius = w * 0.09f,
            color = tint,
        )
    }
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawFourPointSparkle(
    center: Offset,
    radius: Float,
    color: Color,
) {
    val inner = radius * 0.28f
    val path = Path().apply {
        moveTo(center.x, center.y - radius)
        quadraticTo(center.x + inner * 0.4f, center.y - inner * 0.4f, center.x + radius, center.y)
        quadraticTo(center.x + inner * 0.4f, center.y + inner * 0.4f, center.x, center.y + radius)
        quadraticTo(center.x - inner * 0.4f, center.y + inner * 0.4f, center.x - radius, center.y)
        quadraticTo(center.x - inner * 0.4f, center.y - inner * 0.4f, center.x, center.y - radius)
        close()
    }
    drawPath(path = path, color = color, style = Fill)
}

@Composable
fun StarGlyph(
    filled: Boolean,
    tint: Color,
    size: Dp = 20.dp,
    modifier: Modifier = Modifier,
) {
    Canvas(modifier = modifier.size(size)) {
        val cx = this.size.width / 2f
        val cy = this.size.height / 2f
        val outerR = this.size.minDimension * 0.45f
        val innerR = outerR * 0.43f
        val path = Path()
        for (i in 0 until 10) {
            val angle = -PI / 2.0 + i * (PI / 5.0)
            val r = if (i % 2 == 0) outerR else innerR
            val x = cx + (cos(angle) * r).toFloat()
            val y = cy + (sin(angle) * r).toFloat()
            if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        path.close()
        if (filled) {
            drawPath(path = path, color = tint, style = Fill)
        } else {
            val stroke = (this.size.minDimension * 0.085f).coerceAtLeast(1.3.dp.toPx())
            drawPath(
                path = path,
                color = tint,
                style = Stroke(width = stroke, cap = StrokeCap.Round, join = StrokeJoin.Round),
            )
        }
    }
}

@Composable
fun DeadlineFlagGlyph(tint: Color, size: Dp = 12.dp, modifier: Modifier = Modifier) {
    Canvas(modifier = modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height
        val stroke = (w * 0.12f).coerceAtLeast(1.1.dp.toPx())
        drawLine(tint, Offset(w * 0.22f, h * 0.14f), Offset(w * 0.22f, h * 0.90f), strokeWidth = stroke, cap = StrokeCap.Round)
        val flag = Path().apply {
            moveTo(w * 0.22f, h * 0.16f)
            lineTo(w * 0.84f, h * 0.16f)
            lineTo(w * 0.70f, h * 0.38f)
            lineTo(w * 0.84f, h * 0.58f)
            lineTo(w * 0.22f, h * 0.58f)
            close()
        }
        drawPath(flag, color = tint, style = Fill)
    }
}

@Composable
fun ClockSmallGlyph(tint: Color, size: Dp = 12.dp, modifier: Modifier = Modifier) {
    Canvas(modifier = modifier.size(size)) {
        val cx = this.size.width / 2f
        val cy = this.size.height / 2f
        val r = this.size.minDimension * 0.40f
        val stroke = (this.size.minDimension * 0.11f).coerceAtLeast(1.1.dp.toPx())
        drawCircle(tint, radius = r, center = Offset(cx, cy), style = Stroke(width = stroke))
        drawLine(tint, Offset(cx, cy), Offset(cx, cy - r * 0.56f), strokeWidth = stroke, cap = StrokeCap.Round)
        drawLine(tint, Offset(cx, cy), Offset(cx + r * 0.42f, cy + r * 0.22f), strokeWidth = stroke, cap = StrokeCap.Round)
    }
}

@Composable
fun TagSmallGlyph(tint: Color, size: Dp = 14.dp, modifier: Modifier = Modifier) {
    Canvas(modifier = modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height
        val stroke = (w * 0.095f).coerceAtLeast(1.2.dp.toPx())
        val tag = Path().apply {
            moveTo(w * 0.14f, h * 0.14f)
            lineTo(w * 0.52f, h * 0.14f)
            lineTo(w * 0.88f, h * 0.50f)
            lineTo(w * 0.50f, h * 0.88f)
            lineTo(w * 0.14f, h * 0.52f)
            close()
        }
        drawPath(tag, tint, style = Stroke(width = stroke, cap = StrokeCap.Round, join = StrokeJoin.Round))
        drawCircle(tint, radius = w * 0.075f, center = Offset(w * 0.34f, h * 0.34f))
    }
}

@Composable
fun PlusSmallGlyph(tint: Color, size: Dp = 14.dp, modifier: Modifier = Modifier) {
    Canvas(modifier = modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height
        val stroke = (w * 0.12f).coerceAtLeast(1.4.dp.toPx())
        drawLine(tint, Offset(w * 0.50f, h * 0.18f), Offset(w * 0.50f, h * 0.82f), strokeWidth = stroke, cap = StrokeCap.Round)
        drawLine(tint, Offset(w * 0.18f, h * 0.50f), Offset(w * 0.82f, h * 0.50f), strokeWidth = stroke, cap = StrokeCap.Round)
    }
}

@Composable
fun CloseSmallGlyph(tint: Color, size: Dp = 14.dp, modifier: Modifier = Modifier) {
    Canvas(modifier = modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height
        val stroke = (w * 0.12f).coerceAtLeast(1.4.dp.toPx())
        drawLine(tint, Offset(w * 0.24f, h * 0.24f), Offset(w * 0.76f, h * 0.76f), strokeWidth = stroke, cap = StrokeCap.Round)
        drawLine(tint, Offset(w * 0.76f, h * 0.24f), Offset(w * 0.24f, h * 0.76f), strokeWidth = stroke, cap = StrokeCap.Round)
    }
}

@Composable
fun CalendarSmallGlyph(tint: Color, size: Dp = 12.dp, modifier: Modifier = Modifier) {
    Canvas(modifier = modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height
        val stroke = (w * 0.11f).coerceAtLeast(1.dp.toPx())
        drawRoundRect(
            color = tint,
            topLeft = Offset(w * 0.12f, h * 0.22f),
            size = Size(w * 0.76f, h * 0.66f),
            cornerRadius = CornerRadius(w * 0.14f, w * 0.14f),
            style = Stroke(width = stroke),
        )
        drawLine(tint, Offset(w * 0.14f, h * 0.44f), Offset(w * 0.86f, h * 0.44f), strokeWidth = stroke)
        drawLine(tint, Offset(w * 0.34f, h * 0.10f), Offset(w * 0.34f, h * 0.28f), strokeWidth = stroke, cap = StrokeCap.Round)
        drawLine(tint, Offset(w * 0.66f, h * 0.10f), Offset(w * 0.66f, h * 0.28f), strokeWidth = stroke, cap = StrokeCap.Round)
    }
}

@Composable
fun ChecklistSmallGlyph(tint: Color, size: Dp = 12.dp, modifier: Modifier = Modifier) {
    Canvas(modifier = modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height
        val stroke = (w * 0.12f).coerceAtLeast(1.dp.toPx())
        // Top check + line.
        val check = Path().apply {
            moveTo(w * 0.10f, h * 0.32f)
            lineTo(w * 0.22f, h * 0.44f)
            lineTo(w * 0.40f, h * 0.20f)
        }
        drawPath(check, tint, style = Stroke(width = stroke, cap = StrokeCap.Round, join = StrokeJoin.Round))
        drawLine(tint, Offset(w * 0.50f, h * 0.32f), Offset(w * 0.90f, h * 0.32f), strokeWidth = stroke, cap = StrokeCap.Round)
        // Bottom dot + line.
        drawCircle(tint, radius = w * 0.08f, center = Offset(w * 0.24f, h * 0.72f))
        drawLine(tint, Offset(w * 0.50f, h * 0.72f), Offset(w * 0.90f, h * 0.72f), strokeWidth = stroke, cap = StrokeCap.Round)
    }
}

@Composable
fun BellSmallGlyph(tint: Color, size: Dp = 12.dp, modifier: Modifier = Modifier) {
    Canvas(modifier = modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height
        val bell = Path().apply {
            moveTo(w * 0.50f, h * 0.12f)
            cubicTo(w * 0.26f, h * 0.12f, w * 0.22f, h * 0.34f, w * 0.22f, h * 0.56f)
            lineTo(w * 0.12f, h * 0.74f)
            lineTo(w * 0.88f, h * 0.74f)
            lineTo(w * 0.78f, h * 0.56f)
            cubicTo(w * 0.78f, h * 0.34f, w * 0.74f, h * 0.12f, w * 0.50f, h * 0.12f)
            close()
        }
        drawPath(bell, tint, style = Fill)
        drawCircle(tint, radius = w * 0.11f, center = Offset(w * 0.50f, h * 0.84f))
    }
}

@Composable
fun RepeatSmallGlyph(tint: Color, size: Dp = 12.dp, modifier: Modifier = Modifier) {
    Canvas(modifier = modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height
        val stroke = (w * 0.12f).coerceAtLeast(1.1.dp.toPx())
        val pad = w * 0.16f
        drawArc(
            color = tint,
            startAngle = -50f,
            sweepAngle = 290f,
            useCenter = false,
            topLeft = Offset(pad, pad),
            size = Size(w - pad * 2f, h - pad * 2f),
            style = Stroke(width = stroke, cap = StrokeCap.Round),
        )
        // Arrowhead near top-right.
        val head = Path().apply {
            moveTo(w * 0.64f, h * 0.14f)
            lineTo(w * 0.84f, h * 0.22f)
            lineTo(w * 0.74f, h * 0.40f)
        }
        drawPath(head, tint, style = Stroke(width = stroke, cap = StrokeCap.Round, join = StrokeJoin.Round))
    }
}

@Composable
fun NotesSmallGlyph(tint: Color, size: Dp = 12.dp, modifier: Modifier = Modifier) {
    Canvas(modifier = modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height
        val stroke = (w * 0.12f).coerceAtLeast(1.1.dp.toPx())
        drawLine(tint, Offset(w * 0.12f, h * 0.24f), Offset(w * 0.88f, h * 0.24f), strokeWidth = stroke, cap = StrokeCap.Round)
        drawLine(tint, Offset(w * 0.12f, h * 0.50f), Offset(w * 0.88f, h * 0.50f), strokeWidth = stroke, cap = StrokeCap.Round)
        drawLine(tint, Offset(w * 0.12f, h * 0.76f), Offset(w * 0.60f, h * 0.76f), strokeWidth = stroke, cap = StrokeCap.Round)
    }
}

@Composable
fun AttachmentSmallGlyph(tint: Color, size: Dp = 12.dp, modifier: Modifier = Modifier) {
    Canvas(modifier = modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height
        val stroke = (w * 0.11f).coerceAtLeast(1.dp.toPx())
        val clip = Path().apply {
            moveTo(w * 0.68f, h * 0.34f)
            lineTo(w * 0.36f, h * 0.66f)
            quadraticTo(w * 0.24f, h * 0.78f, w * 0.36f, h * 0.86f)
            quadraticTo(w * 0.46f, h * 0.92f, w * 0.56f, h * 0.82f)
            lineTo(w * 0.84f, h * 0.54f)
            quadraticTo(w * 0.94f, h * 0.40f, w * 0.80f, h * 0.26f)
            quadraticTo(w * 0.66f, h * 0.12f, w * 0.52f, h * 0.26f)
            lineTo(w * 0.24f, h * 0.54f)
        }
        drawPath(clip, tint, style = Stroke(width = stroke, cap = StrokeCap.Round, join = StrokeJoin.Round))
    }
}

@Composable
fun ChevronDownGlyph(tint: Color, size: Dp = 16.dp, modifier: Modifier = Modifier) {
    Canvas(modifier = modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height
        val stroke = (w * 0.13f).coerceAtLeast(1.5.dp.toPx())
        val path = Path().apply {
            moveTo(w * 0.22f, h * 0.36f)
            lineTo(w * 0.50f, h * 0.66f)
            lineTo(w * 0.78f, h * 0.36f)
        }
        drawPath(path, tint, style = Stroke(width = stroke, cap = StrokeCap.Round, join = StrokeJoin.Round))
    }
}

@Composable
fun ChevronRightGlyph(tint: Color, size: Dp = 14.dp, modifier: Modifier = Modifier) {
    Canvas(modifier = modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height
        val stroke = (w * 0.14f).coerceAtLeast(1.4.dp.toPx())
        val path = Path().apply {
            moveTo(w * 0.34f, h * 0.20f)
            lineTo(w * 0.68f, h * 0.50f)
            lineTo(w * 0.34f, h * 0.80f)
        }
        drawPath(path, tint, style = Stroke(width = stroke, cap = StrokeCap.Round, join = StrokeJoin.Round))
    }
}

@Composable
fun ChevronLeftGlyph(tint: Color, size: Dp = 22.dp, modifier: Modifier = Modifier) {
    Canvas(modifier = modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height
        val stroke = (w * 0.10f).coerceAtLeast(2.dp.toPx())
        val path = Path().apply {
            moveTo(w * 0.62f, h * 0.20f)
            lineTo(w * 0.32f, h * 0.50f)
            lineTo(w * 0.62f, h * 0.80f)
        }
        drawPath(path, tint, style = Stroke(width = stroke, cap = StrokeCap.Round, join = StrokeJoin.Round))
    }
}

/** Circular project progress glyph matching iOS `ProjectProgressIcon`: ring + inner pie fill. */
@Composable
fun ProjectProgressRingGlyph(
    progress: Float,
    tint: Color,
    size: Dp = 17.dp,
    modifier: Modifier = Modifier,
) {
    Canvas(modifier = modifier.size(size)) {
        val stroke = (this.size.minDimension * 0.105f).coerceAtLeast(1.4.dp.toPx())
        val radius = this.size.minDimension * 0.40f
        val center = Offset(this.size.width / 2f, this.size.height / 2f)
        drawCircle(color = tint, radius = radius, center = center, style = Stroke(width = stroke))
        val clamped = progress.coerceIn(0f, 1f)
        if (clamped > 0.01f) {
            val innerPad = (this.size.minDimension / 2f) - (radius - stroke * 1.15f)
            val innerDiameter = (this.size.minDimension - innerPad * 2f).coerceAtLeast(0f)
            drawArc(
                color = tint,
                startAngle = -90f,
                sweepAngle = clamped * 360f,
                useCenter = true,
                topLeft = Offset(innerPad, innerPad),
                size = Size(innerDiameter, innerDiameter),
            )
        }
    }
}

/** Muted filled dot for an Area with no custom emoji, matching iOS `AreaIcon`. */
@Composable
fun AreaDotGlyph(tint: Color, size: Dp = 18.dp, modifier: Modifier = Modifier) {
    Canvas(modifier = modifier.size(size)) {
        drawCircle(
            color = tint,
            radius = this.size.minDimension * 0.22f,
            center = Offset(this.size.width / 2f, this.size.height / 2f),
        )
    }
}

@Composable
fun MoreDotsGlyph(tint: Color, size: Dp = 16.dp, modifier: Modifier = Modifier) {
    Canvas(modifier = modifier.size(size)) {
        val cx = this.size.width / 2f
        val r = (this.size.minDimension * 0.085f).coerceAtLeast(1.2.dp.toPx())
        drawCircle(tint, radius = r, center = Offset(cx, this.size.height * 0.24f))
        drawCircle(tint, radius = r, center = Offset(cx, this.size.height * 0.50f))
        drawCircle(tint, radius = r, center = Offset(cx, this.size.height * 0.76f))
    }
}

@Composable
fun CheckmarkGlyph(tint: Color, size: Dp = 16.dp, modifier: Modifier = Modifier) {
    Canvas(modifier = modifier.size(size)) {
        val w = this.size.width
        val h = this.size.height
        val stroke = (w * 0.13f).coerceAtLeast(1.6.dp.toPx())
        val path = Path().apply {
            moveTo(w * 0.18f, h * 0.52f)
            lineTo(w * 0.42f, h * 0.74f)
            lineTo(w * 0.84f, h * 0.26f)
        }
        drawPath(path, tint, style = Stroke(width = stroke, cap = StrokeCap.Round, join = StrokeJoin.Round))
    }
}

/** Destination / section / place icon matching iOS SF Symbols cleanly across KMP. */
@Composable
fun SeptenaGlyph(
    kind: SeptenaIconKind,
    tint: Color,
    size: Dp = 20.dp,
    modifier: Modifier = Modifier,
) {
    when (kind) {
        SeptenaIconKind.None -> Spacer(modifier = modifier.size(size))
        SeptenaIconKind.Starred -> StarGlyph(filled = true, tint = tint, size = size, modifier = modifier)
        SeptenaIconKind.Upcoming -> CalendarSmallGlyph(tint = tint, size = size, modifier = modifier)
        SeptenaIconKind.Repeating -> RepeatSmallGlyph(tint = tint, size = size, modifier = modifier)
        SeptenaIconKind.Agent -> AgentSparkleBubbleGlyph(tint = tint, size = size, modifier = modifier)
        SeptenaIconKind.Logbook -> CheckmarkGlyph(tint = tint, size = size, modifier = modifier)
        SeptenaIconKind.Today -> Canvas(modifier = modifier.size(size)) {
            val cx = this.size.width / 2f
            val cy = this.size.height / 2f
            val coreR = this.size.minDimension * 0.23f
            val innerRay = this.size.minDimension * 0.34f
            val outerRay = this.size.minDimension * 0.46f
            val stroke = (this.size.minDimension * 0.095f).coerceAtLeast(1.4.dp.toPx())
            drawCircle(tint, radius = coreR, center = Offset(cx, cy))
            for (i in 0 until 8) {
                val a = i * (PI / 4.0)
                val ca = cos(a).toFloat()
                val sa = sin(a).toFloat()
                drawLine(
                    color = tint,
                    start = Offset(cx + ca * innerRay, cy + sa * innerRay),
                    end = Offset(cx + ca * outerRay, cy + sa * outerRay),
                    strokeWidth = stroke,
                    cap = StrokeCap.Round,
                )
            }
        }
        SeptenaIconKind.Inbox -> Canvas(modifier = modifier.size(size)) {
            val w = this.size.width
            val h = this.size.height
            val stroke = (w * 0.09f).coerceAtLeast(1.4.dp.toPx())
            val tray = Path().apply {
                moveTo(w * 0.20f, h * 0.24f)
                lineTo(w * 0.80f, h * 0.24f)
                lineTo(w * 0.90f, h * 0.56f)
                lineTo(w * 0.90f, h * 0.80f)
                lineTo(w * 0.10f, h * 0.80f)
                lineTo(w * 0.10f, h * 0.56f)
                close()
            }
            drawPath(tray, tint, style = Stroke(width = stroke, cap = StrokeCap.Round, join = StrokeJoin.Round))
            val dip = Path().apply {
                moveTo(w * 0.12f, h * 0.56f)
                lineTo(w * 0.35f, h * 0.56f)
                lineTo(w * 0.42f, h * 0.67f)
                lineTo(w * 0.58f, h * 0.67f)
                lineTo(w * 0.65f, h * 0.56f)
                lineTo(w * 0.88f, h * 0.56f)
            }
            drawPath(dip, tint, style = Stroke(width = stroke, cap = StrokeCap.Round, join = StrokeJoin.Round))
        }
        SeptenaIconKind.Review -> Canvas(modifier = modifier.size(size)) {
            val w = this.size.width
            val h = this.size.height
            val stroke = (w * 0.09f).coerceAtLeast(1.4.dp.toPx())
            val eye = Path().apply {
                moveTo(w * 0.10f, h * 0.50f)
                quadraticTo(w * 0.50f, h * 0.14f, w * 0.90f, h * 0.50f)
                quadraticTo(w * 0.50f, h * 0.86f, w * 0.10f, h * 0.50f)
                close()
            }
            drawPath(eye, tint, style = Stroke(width = stroke, join = StrokeJoin.Round))
            drawCircle(tint, radius = w * 0.14f, center = Offset(w * 0.50f, h * 0.50f))
        }
        SeptenaIconKind.Anytime -> Canvas(modifier = modifier.size(size)) {
            val w = this.size.width
            val h = this.size.height
            val stroke = (w * 0.09f).coerceAtLeast(1.4.dp.toPx())
            drawRoundRect(
                color = tint,
                topLeft = Offset(w * 0.14f, h * 0.38f),
                size = Size(w * 0.72f, h * 0.44f),
                cornerRadius = CornerRadius(w * 0.12f, w * 0.12f),
                style = Stroke(width = stroke),
            )
            drawLine(tint, Offset(w * 0.24f, h * 0.26f), Offset(w * 0.76f, h * 0.26f), strokeWidth = stroke, cap = StrokeCap.Round)
            drawLine(tint, Offset(w * 0.32f, h * 0.15f), Offset(w * 0.68f, h * 0.15f), strokeWidth = stroke, cap = StrokeCap.Round)
        }
        SeptenaIconKind.Faded -> Canvas(modifier = modifier.size(size)) {
            val stroke = (this.size.minDimension * 0.095f).coerceAtLeast(1.4.dp.toPx())
            val dash = (this.size.minDimension * 0.18f).coerceAtLeast(3.dp.toPx())
            drawCircle(
                color = tint,
                radius = this.size.minDimension * 0.38f,
                center = Offset(this.size.width / 2f, this.size.height / 2f),
                style = Stroke(
                    width = stroke,
                    cap = StrokeCap.Round,
                    pathEffect = PathEffect.dashPathEffect(floatArrayOf(dash, dash * 0.85f)),
                ),
            )
        }
        SeptenaIconKind.RecentlyDeleted -> Canvas(modifier = modifier.size(size)) {
            val w = this.size.width
            val h = this.size.height
            val stroke = (w * 0.09f).coerceAtLeast(1.4.dp.toPx())
            drawLine(tint, Offset(w * 0.18f, h * 0.26f), Offset(w * 0.82f, h * 0.26f), strokeWidth = stroke, cap = StrokeCap.Round)
            drawLine(tint, Offset(w * 0.38f, h * 0.16f), Offset(w * 0.62f, h * 0.16f), strokeWidth = stroke, cap = StrokeCap.Round)
            val bin = Path().apply {
                moveTo(w * 0.26f, h * 0.26f)
                lineTo(w * 0.31f, h * 0.84f)
                lineTo(w * 0.69f, h * 0.84f)
                lineTo(w * 0.74f, h * 0.26f)
            }
            drawPath(bin, tint, style = Stroke(width = stroke, cap = StrokeCap.Round, join = StrokeJoin.Round))
        }
        SeptenaIconKind.Area -> Canvas(modifier = modifier.size(size)) {
            val w = this.size.width
            val h = this.size.height
            val stroke = (w * 0.09f).coerceAtLeast(1.4.dp.toPx())
            val folder = Path().apply {
                moveTo(w * 0.12f, h * 0.26f)
                lineTo(w * 0.42f, h * 0.26f)
                lineTo(w * 0.50f, h * 0.36f)
                lineTo(w * 0.88f, h * 0.36f)
                lineTo(w * 0.88f, h * 0.78f)
                lineTo(w * 0.12f, h * 0.78f)
                close()
            }
            drawPath(folder, tint, style = Stroke(width = stroke, cap = StrokeCap.Round, join = StrokeJoin.Round))
        }
        SeptenaIconKind.Project -> Canvas(modifier = modifier.size(size)) {
            val stroke = (this.size.minDimension * 0.11f).coerceAtLeast(1.5.dp.toPx())
            drawCircle(
                color = tint,
                radius = this.size.minDimension * 0.38f,
                center = Offset(this.size.width / 2f, this.size.height / 2f),
                style = Stroke(width = stroke),
            )
        }
        SeptenaIconKind.Settings -> Canvas(modifier = modifier.size(size)) {
            val stroke = (this.size.minDimension * 0.085f).coerceAtLeast(1.4.dp.toPx())
            val cx = this.size.width / 2f
            val cy = this.size.height / 2f
            val innerR = this.size.minDimension * 0.16f
            val midR = this.size.minDimension * 0.30f
            val outerR = this.size.minDimension * 0.44f
            drawCircle(tint, radius = innerR, center = Offset(cx, cy), style = Stroke(width = stroke))
            drawCircle(tint, radius = midR, center = Offset(cx, cy), style = Stroke(width = stroke))
            for (i in 0 until 8) {
                val a = i * (PI / 4.0)
                val ca = cos(a).toFloat()
                val sa = sin(a).toFloat()
                drawLine(
                    tint,
                    Offset(cx + ca * midR, cy + sa * midR),
                    Offset(cx + ca * outerR, cy + sa * outerR),
                    strokeWidth = stroke * 1.15f,
                    cap = StrokeCap.Round,
                )
            }
        }
    }
}
