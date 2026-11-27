package app.septena.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.abs
import kotlin.math.roundToInt

/** Drop target kind for an active task reorder / re-home drag (mirrors `DRAG_AND_DROP.md`). */
sealed interface TaskReorderDropKind {
    /** Reorder between two task rows (draws 6dp insertion mark on top or bottom edge). */
    data object TaskRow : TaskReorderDropKind

    /** Drop under a section / group header (draws 6dp insertion mark under header). */
    data object SectionHeader : TaskReorderDropKind

    /** Drop onto a container row such as an Area's Project card (wears selection fill). */
    data object ContainerRow : TaskReorderDropKind

    /**
     * A slot between two project headings, at the top edge of the zone. Only a
     * heading drag sees it; the heading's section moves with it.
     */
    data object HeadingSlot : TaskReorderDropKind
}

/** What a drag carries. A zone only answers the payload it accepts. */
enum class TaskDragPayload {
    /** Task rows: reorder, file under a heading, re-home. */
    Tasks,

    /** Project headings: reorder among the project's headings (`docs/DRAG_AND_DROP.md`). */
    Headings,
}

data class TaskReorderActiveTarget(
    val id: String,
    val kind: TaskReorderDropKind,
    val before: Boolean,
)

/**
 * Live coordinator for in-list task drag-to-reorder and container re-home drops.
 * Uses the exact same landing mark and edge-merge hysteresis as [MagicPlusDragState]
 * (`docs/DRAG_AND_DROP.md` — "One landing mark").
 */
@Stable
class TaskReorderDragState {
    private data class Zone(
        val id: String,
        val kind: TaskReorderDropKind,
        val rect: Rect,
        val ownerTaskId: String?,
        val accepts: TaskDragPayload,
        val onDrop: (ids: List<String>, before: Boolean) -> Unit,
    )

    private data class Gap(
        val y: Float,
        val id: String,
        val kind: TaskReorderDropKind,
        val before: Boolean,
        val rank: Int,
    )

    var isDragging by mutableStateOf(false)
        private set

    var draggedIds by mutableStateOf<List<String>>(emptyList())
        private set

    var draggedTitle by mutableStateOf("")
        private set

    var draggedPayload by mutableStateOf(TaskDragPayload.Tasks)
        private set

    var pointerRoot by mutableStateOf(Offset.Zero)
        private set

    var activeTarget by mutableStateOf<TaskReorderActiveTarget?>(null)
        private set

    private val zones = mutableMapOf<String, Zone>()

    fun register(
        id: String,
        kind: TaskReorderDropKind,
        rect: Rect,
        ownerTaskId: String? = null,
        accepts: TaskDragPayload = TaskDragPayload.Tasks,
        onDrop: (ids: List<String>, before: Boolean) -> Unit,
    ) {
        if (rect.height <= 0f || rect.width <= 0f) return
        zones[id] = Zone(id = id, kind = kind, rect = rect, ownerTaskId = ownerTaskId, accepts = accepts, onDrop = onDrop)
    }

    fun unregister(id: String) {
        zones.remove(id)
        if (activeTarget?.id == id) activeTarget = null
    }

    fun beginDrag(
        ids: List<String>,
        primaryTitle: String,
        location: Offset,
        density: Float,
        onHapticTick: () -> Unit,
        payload: TaskDragPayload = TaskDragPayload.Tasks,
    ) {
        if (ids.isEmpty()) return
        draggedIds = ids
        draggedTitle = primaryTitle
        draggedPayload = payload
        pointerRoot = location
        isDragging = true
        activeTarget = null
        onHapticTick()
        resolveTarget(location, density, onHapticTick)
    }

    fun updateDrag(location: Offset, density: Float, onHapticTick: () -> Unit) {
        if (!isDragging) return
        pointerRoot = location
        resolveTarget(location, density, onHapticTick)
    }

    fun endDrag(location: Offset, density: Float) {
        if (!isDragging) return
        pointerRoot = location
        resolveTarget(location, density, onHapticTick = {})
        val hit = activeTarget
        val ids = draggedIds
        val action = hit?.let { zones[it.id]?.onDrop }
        clearState()
        if (hit != null && action != null && ids.isNotEmpty()) {
            action(ids, hit.before)
        }
    }

    fun cancel() {
        clearState()
    }

    fun reset() {
        clearState()
        zones.clear()
    }

    private fun clearState() {
        isDragging = false
        draggedIds = emptyList()
        draggedTitle = ""
        draggedPayload = TaskDragPayload.Tasks
        activeTarget = null
    }

    private fun resolveTarget(location: Offset, density: Float, onHapticTick: () -> Unit) {
        val draggedSet = draggedIds.toSet()

        // 1. Direct container hits (e.g., dropping tasks onto a Project row inside an Area) take priority.
        val containerHit = zones.values.firstOrNull { zone ->
            zone.accepts == draggedPayload &&
                zone.kind == TaskReorderDropKind.ContainerRow &&
                location.x in zone.rect.left..zone.rect.right &&
                location.y in zone.rect.top..zone.rect.bottom
        }
        if (containerHit != null) {
            if (activeTarget?.id != containerHit.id) {
                onHapticTick()
                activeTarget = TaskReorderActiveTarget(containerHit.id, TaskReorderDropKind.ContainerRow, before = true)
            }
            return
        }

        // 2. Insertion gaps along task rows & section headers.
        val gaps = insertionPoints(density, draggedSet)
        if (gaps.isEmpty()) {
            activeTarget = null
            return
        }
        val probeY = location.y
        val openIndex = activeTarget?.let { target ->
            gaps.indexOfFirst { it.id == target.id && it.before == target.before }.takeIf { it >= 0 }
        }
        var bestIndex = 0
        var bestDistance = Float.POSITIVE_INFINITY
        for (i in gaps.indices) {
            val d = abs(gaps[i].y - probeY)
            if (d < bestDistance) {
                bestDistance = d
                bestIndex = i
            }
        }
        if (bestDistance > MAX_SNAP_DP * density) {
            activeTarget = null
            return
        }
        if (openIndex != null && openIndex != bestIndex) {
            val openDistance = abs(gaps[openIndex].y - probeY)
            if (openDistance - bestDistance < HYSTERESIS_DP * density) return
        }
        if (bestIndex == openIndex) return
        val winner = gaps[bestIndex]
        onHapticTick()
        activeTarget = TaskReorderActiveTarget(winner.id, winner.kind, winner.before)
    }

    private fun insertionPoints(density: Float, draggedSet: Set<String>): List<Gap> {
        val points = mutableListOf<Gap>()
        for (zone in zones.values) {
            if (zone.accepts != draggedPayload) continue
            if (zone.ownerTaskId != null && zone.ownerTaskId in draggedSet) continue
            when (zone.kind) {
                TaskReorderDropKind.TaskRow -> {
                    points += Gap(zone.rect.top, zone.id, zone.kind, before = true, rank = 0)
                    points += Gap(zone.rect.bottom, zone.id, zone.kind, before = false, rank = 2)
                }
                TaskReorderDropKind.SectionHeader -> {
                    points += Gap(zone.rect.bottom, zone.id, zone.kind, before = true, rank = 1)
                }
                TaskReorderDropKind.HeadingSlot -> {
                    points += Gap(zone.rect.top, zone.id, zone.kind, before = true, rank = 1)
                }
                TaskReorderDropKind.ContainerRow -> Unit
            }
        }
        points.sortBy(Gap::y)
        val mergePx = MERGE_CLUSTER_DP * density
        val merged = mutableListOf<Gap>()
        var clusterStart = Float.NEGATIVE_INFINITY
        for (point in points) {
            val last = merged.lastOrNull()
            if (last != null && point.y - clusterStart < mergePx) {
                if (point.rank < last.rank) merged[merged.lastIndex] = point
            } else {
                merged += point
                clusterStart = point.y
            }
        }
        return merged
    }

    private companion object {
        const val MERGE_CLUSTER_DP = 16f
        const val HYSTERESIS_DP = 10f
        const val MAX_SNAP_DP = 72f
    }
}

/**
 * Computes strictly ascending positions for [count] moved tasks landing immediately
 * before or after [targetIndex] in [positions], preserving their relative order.
 */
fun reorderPositions(
    positions: List<Double?>,
    targetIndex: Int,
    before: Boolean,
    count: Int,
): List<Double> {
    if (count <= 0) return emptyList()
    if (count == 1) return listOf(insertionPosition(positions, targetIndex, before))
    val target = positions.getOrNull(targetIndex)
    val neighbor = positions.getOrNull(if (before) targetIndex - 1 else targetIndex + 1)
    return when {
        target != null && neighbor != null -> {
            val low = minOf(target, neighbor)
            val high = maxOf(target, neighbor)
            val step = (high - low) / (count + 1).toDouble()
            List(count) { i -> low + step * (i + 1) }
        }
        target != null -> if (before) {
            val start = target - count.toDouble()
            List(count) { i -> start + i.toDouble() }
        } else {
            List(count) { i -> target + (i + 1).toDouble() }
        }
        neighbor != null -> if (before) {
            List(count) { i -> neighbor + (i + 1).toDouble() }
        } else {
            val start = neighbor - count.toDouble()
            List(count) { i -> start + i.toDouble() }
        }
        else -> {
            val base = if (before) targetIndex - count.toDouble() else targetIndex + 1.0
            List(count) { i -> base + i.toDouble() }
        }
    }
}

/** Apple's `TaskOrder.gap`: the spacing between manual positions. */
const val TASK_ORDER_GAP: Double = 1024.0

/**
 * Apple's `TaskOrder.positions(count:above:below:)`: [count] ascending slots
 * between two neighbor keys (either may be absent). A slot never lands on 0,
 * because `position == 0` means "never ordered".
 */
fun taskOrderPositions(count: Int, above: Double?, below: Double?): List<Double> {
    if (count <= 0) return emptyList()
    val slots: List<Double>
    val nudge: Double
    when {
        above != null && below != null -> {
            val step = (below - above) / (count + 1).toDouble()
            slots = List(count) { i -> above + step * (i + 1) }
            nudge = step / 2
        }
        above != null -> {
            slots = List(count) { i -> above + TASK_ORDER_GAP * (i + 1) }
            nudge = TASK_ORDER_GAP / 2
        }
        below != null -> {
            slots = List(count) { i -> below - TASK_ORDER_GAP * (count - i) }
            nudge = -TASK_ORDER_GAP / 2
        }
        else -> {
            slots = List(count) { i -> TASK_ORDER_GAP * (i + 1) }
            nudge = 0.0
        }
    }
    return if (slots.any { it == 0.0 }) slots.map { it + nudge } else slots
}

/**
 * The position writes for a heading reorder, the same rule as Apple's
 * `TaskListView.handleHeadingDrop` → `applyManualOrder`.
 *
 * [headings] is the project's headings in the order the page shows them, with
 * their stored positions. [movedIds] land just above [beforeHeadingId], or at
 * the end when it is null. The moved headings take midpoint slots between
 * their new neighbors. When a neighbor has no usable key (null or the unset 0)
 * or the slots do not fit strictly between them, every heading is renumbered
 * `base + gap * i` in the new order, and a 0 becomes `gap / 2`. Only changed
 * positions are returned. An empty result means nothing to write.
 */
fun headingReorderPositions(
    headings: List<Pair<String, Double?>>,
    movedIds: List<String>,
    beforeHeadingId: String?,
): List<Pair<String, Double>> {
    val moved = movedIds.filter { id -> headings.any { it.first == id } }.distinct()
    if (moved.isEmpty()) return emptyList()
    if (beforeHeadingId != null && beforeHeadingId in moved) return emptyList()
    val movedSet = moved.toSet()
    val remaining = headings.filter { it.first !in movedSet }
    val insertion = if (beforeHeadingId == null) {
        remaining.size
    } else {
        remaining.indexOfFirst { it.first == beforeHeadingId }.takeIf { it >= 0 } ?: return emptyList()
    }
    val current = headings.toMap()
    fun usable(p: Double?): Double? = p?.takeIf { it != 0.0 }

    val aboveRow = remaining.getOrNull(insertion - 1)
    val belowRow = remaining.getOrNull(insertion)
    val above = usable(aboveRow?.second)
    val below = usable(belowRow?.second)
    val keysKnown = (aboveRow == null || above != null) && (belowRow == null || below != null)
    if (keysKnown) {
        val slots = taskOrderPositions(moved.size, above, below)
        val strictlyPlaced = slots.zipWithNext().all { (a, b) -> a < b } &&
            (above == null || slots.first() > above) &&
            (below == null || slots.last() < below)
        if (strictlyPlaced) {
            return moved.zip(slots).filter { (id, pos) -> current[id] != pos }
        }
    }
    val final = remaining.map { it.first }.toMutableList().apply { addAll(insertion, moved) }
    val base = usable(remaining.firstOrNull()?.second) ?: TASK_ORDER_GAP
    return final.mapIndexed { i, id ->
        val pos = base + TASK_ORDER_GAP * i
        id to (if (pos == 0.0) TASK_ORDER_GAP / 2 else pos)
    }.filter { (id, pos) -> current[id] != pos }
}

val LocalTaskReorderDrag = compositionLocalOf<TaskReorderDragState?> { null }

/** Registers a task row as a task-reorder drop target and draws the canonical 6dp insertion mark. */
fun Modifier.taskReorderRowDrop(
    id: String,
    taskId: String,
    enabled: Boolean,
    onDrop: (ids: List<String>, before: Boolean) -> Unit,
): Modifier = composed {
    val drag = LocalTaskReorderDrag.current
    val tint = LocalMagicPlusColor.current
    if (drag == null || !enabled) return@composed this

    DisposableEffect(drag, id) {
        onDispose { drag.unregister(id) }
    }
    val target = drag.activeTarget
    val hoveredBefore = if (drag.isDragging && target?.id == id) target.before else null
    val markAlpha by animateFloatAsState(
        targetValue = if (hoveredBefore != null) 1f else 0f,
        animationSpec = tween(durationMillis = 120),
        label = "taskReorderRowMark",
    )
    this
        .onGloballyPositioned { coords ->
            drag.register(id, TaskReorderDropKind.TaskRow, coords.boundsInRoot(), ownerTaskId = taskId, onDrop = onDrop)
        }
        .drawInsertionMark(tint, markAlpha, atTop = hoveredBefore == true, visible = hoveredBefore != null)
}

/** Registers a group / section header as a task-reorder drop target; draws the 6dp mark below it. */
fun Modifier.taskReorderSectionDrop(
    id: String,
    enabled: Boolean = true,
    onDrop: (ids: List<String>) -> Unit,
): Modifier = composed {
    val drag = LocalTaskReorderDrag.current
    val tint = LocalMagicPlusColor.current
    if (drag == null || !enabled) return@composed this

    DisposableEffect(drag, id) {
        onDispose { drag.unregister(id) }
    }
    val isTargeted = drag.isDragging && drag.activeTarget?.id == id
    val markAlpha by animateFloatAsState(
        targetValue = if (isTargeted) 1f else 0f,
        animationSpec = tween(durationMillis = 120),
        label = "taskReorderSectionMark",
    )
    this
        .onGloballyPositioned { coords ->
            drag.register(id, TaskReorderDropKind.SectionHeader, coords.boundsInRoot()) { ids, _ -> onDrop(ids) }
        }
        .drawInsertionMark(tint, markAlpha, atTop = false, visible = isTargeted)
}

/**
 * Registers a project heading's slot for a heading drag: the drop lands just
 * above [headingId] (or at the end of the headings when it is null). Draws the
 * same 6dp insertion mark, on the zone's top edge. [headingId] is also the
 * zone's owner, so the dragged heading does not offer its own slot.
 */
fun Modifier.headingReorderDrop(
    id: String,
    headingId: String?,
    enabled: Boolean = true,
    onDrop: (ids: List<String>) -> Unit,
): Modifier = composed {
    val drag = LocalTaskReorderDrag.current
    val tint = LocalMagicPlusColor.current
    if (drag == null || !enabled) return@composed this

    DisposableEffect(drag, id) {
        onDispose { drag.unregister(id) }
    }
    val isTargeted = drag.isDragging && drag.activeTarget?.id == id
    val markAlpha by animateFloatAsState(
        targetValue = if (isTargeted) 1f else 0f,
        animationSpec = tween(durationMillis = 120),
        label = "headingReorderMark",
    )
    this
        .onGloballyPositioned { coords ->
            drag.register(
                id,
                TaskReorderDropKind.HeadingSlot,
                coords.boundsInRoot(),
                ownerTaskId = headingId,
                accepts = TaskDragPayload.Headings,
            ) { ids, _ -> onDrop(ids) }
        }
        .drawInsertionMark(tint, markAlpha, atTop = true, visible = isTargeted)
}

/**
 * Makes a project heading draggable: long-press, then slide, as a task row.
 * The drag carries [TaskDragPayload.Headings], so only heading slots answer it.
 */
fun Modifier.headingReorderDragSource(
    headingId: String,
    title: String,
    enabled: Boolean = true,
): Modifier = composed {
    val drag = LocalTaskReorderDrag.current
    if (drag == null || !enabled) return@composed this
    val density = LocalDensity.current.density
    val haptics = LocalHapticFeedback.current
    var origin by remember(headingId) { mutableStateOf(Offset.Zero) }
    val hapticTick: () -> Unit = { haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove) }
    this
        .onGloballyPositioned { coords -> origin = coords.positionInRoot() }
        .pointerInput(headingId, title, drag) {
            var last = Offset.Zero
            detectDragGesturesAfterLongPress(
                onDragStart = { offset ->
                    last = origin + offset
                    haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                    drag.beginDrag(
                        ids = listOf(headingId),
                        primaryTitle = title,
                        location = last,
                        density = density,
                        onHapticTick = hapticTick,
                        payload = TaskDragPayload.Headings,
                    )
                },
                onDrag = { change, _ ->
                    change.consume()
                    last = origin + change.position
                    drag.updateDrag(last, density, hapticTick)
                },
                onDragEnd = { drag.endDrag(last, density) },
                onDragCancel = { drag.cancel() },
            )
        }
}

/**
 * Registers a container row (e.g., an Area's Project card) as a drop target.
 * Returns whether the container is currently hovered so the caller can tint it
 * with `isSelected = true` (`SELECTION_WASH_ALPHA`).
 */
@Composable
fun rememberTaskContainerDropTarget(
    id: String,
    enabled: Boolean,
    onDrop: (ids: List<String>) -> Unit,
): Pair<Modifier, Boolean> {
    val drag = LocalTaskReorderDrag.current
    if (drag == null || !enabled) return Modifier to false

    DisposableEffect(drag, id) {
        onDispose { drag.unregister(id) }
    }
    val isTargeted = drag.isDragging && drag.activeTarget?.id == id
    val mod = Modifier.onGloballyPositioned { coords ->
        drag.register(id, TaskReorderDropKind.ContainerRow, coords.boundsInRoot()) { ids, _ -> onDrop(ids) }
    }
    return mod to isTargeted
}

/**
 * Floating translucent stacked-card preview following the finger during a task
 * reorder/re-home drag (mirrors iOS `TaskDragStackPreview`).
 */
@Composable
fun TaskDragStackOverlay(
    drag: TaskReorderDragState,
    isDark: Boolean,
    modifier: Modifier = Modifier,
) {
    if (!drag.isDragging || drag.draggedIds.isEmpty()) return
    val count = drag.draggedIds.size
    val cardFill = if (isDark) {
        MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.94f)
    } else {
        Color.White.copy(alpha = 0.95f)
    }
    val borderColor = if (isDark) {
        Color.White.copy(alpha = 0.16f)
    } else {
        MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.55f)
    }
    val accent = MaterialTheme.colorScheme.primary
    val onAccent = MaterialTheme.colorScheme.onPrimary

    var rootOrigin by androidx.compose.runtime.remember { mutableStateOf(Offset.Zero) }
    Box(
        modifier = modifier
            .onGloballyPositioned { coords ->
                rootOrigin = coords.boundsInRoot().topLeft
            },
    ) {
        val localX = (drag.pointerRoot.x - rootOrigin.x).roundToInt()
        val localY = (drag.pointerRoot.y - rootOrigin.y).roundToInt()
        Box(
            modifier = Modifier
                .offset { IntOffset(x = (localX - 110).coerceAtLeast(16), y = (localY - 96).coerceAtLeast(16)) }
                .widthIn(min = 160.dp, max = 260.dp),
        ) {
            if (count > 1) {
                Box(
                    modifier = Modifier
                        .matchParentSize()
                        .offset(y = 4.dp)
                        .padding(horizontal = 6.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .background(cardFill.copy(alpha = 0.72f))
                        .border(0.75.dp, borderColor, RoundedCornerShape(12.dp)),
                )
            }
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier
                    .shadow(elevation = 12.dp, shape = RoundedCornerShape(12.dp))
                    .clip(RoundedCornerShape(12.dp))
                    .background(cardFill)
                    .border(0.75.dp, borderColor, RoundedCornerShape(12.dp))
                    .padding(horizontal = 14.dp, vertical = 10.dp),
            ) {
                Text(
                    text = drag.draggedTitle,
                    fontSize = 14.5.sp,
                    fontWeight = FontWeight.Medium,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (count > 1) {
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier
                            .clip(CircleShape)
                            .background(accent)
                            .padding(horizontal = 7.dp, vertical = 2.dp),
                    ) {
                        Text(
                            text = count.toString(),
                            fontSize = 11.5.sp,
                            fontWeight = FontWeight.Bold,
                            color = onAccent,
                        )
                    }
                }
            }
        }
    }
}
