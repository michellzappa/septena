package app.septena.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.unit.dp
import kotlin.math.abs
import kotlin.math.hypot

/** What kind of drop target the dragged Magic Plus orb is hovering. Matches iOS `MagicPlusDropKind`. */
sealed interface MagicPlusDropKind {
    /** Between two rows in a list (offers both top and bottom edges). */
    data object TaskRow : MagicPlusDropKind

    /** Under a section, band, or heading header (inserts first in that section). */
    data object TaskSection : MagicPlusDropKind

    /** A full container target (e.g. a Lists Homepage smart-list pill, Area, or Project row). */
    data object Container : MagicPlusDropKind
}

data class MagicPlusActiveTarget(
    val id: String,
    val kind: MagicPlusDropKind,
    val before: Boolean,
)

/**
 * Live coordinator for the Magic Plus orb drag (mirrors iOS `MagicPlusDragState`
 * in `TaskListChrome.swift`): tracks registered row and section bounds without
 * triggering recomposition on scroll, merges touching edges within 16 dp into
 * one insertion slot, applies 10 dp hysteresis, and cancels inside 48 dp of
 * the orb's resting socket.
 */
@Stable
class MagicPlusDragState {
    private data class Zone(
        val id: String,
        val kind: MagicPlusDropKind,
        val topY: Float,
        val bottomY: Float,
        val leftX: Float = Float.NEGATIVE_INFINITY,
        val rightX: Float = Float.POSITIVE_INFINITY,
        val onDrop: (before: Boolean) -> Unit,
    )

    private data class Gap(
        val y: Float,
        val id: String,
        val kind: MagicPlusDropKind,
        val before: Boolean,
        /** Row top (0) wins over section bottom (1), which wins over row bottom (2). */
        val rank: Int,
    )

    var isDragging by mutableStateOf(false)
        private set

    var isOverCancelSocket by mutableStateOf(false)
        private set

    var activeTarget by mutableStateOf<MagicPlusActiveTarget?>(null)
        private set

    /** Resting orb center in root coordinates (px). */
    var homeCenter: Offset = Offset.Zero

    /** Invoked when released outside the cancel socket on a list with no registered zones. */
    var fallbackDrop: (() -> Unit)? = null

    /** Non-observed registry so scrolling rows never recompose the list. */
    private val zones = mutableMapOf<String, Zone>()

    fun register(
        id: String,
        kind: MagicPlusDropKind,
        topY: Float,
        bottomY: Float,
        leftX: Float = Float.NEGATIVE_INFINITY,
        rightX: Float = Float.POSITIVE_INFINITY,
        onDrop: (before: Boolean) -> Unit,
    ) {
        if (bottomY <= topY) return
        zones[id] = Zone(
            id = id,
            kind = kind,
            topY = topY,
            bottomY = bottomY,
            leftX = leftX,
            rightX = rightX,
            onDrop = onDrop,
        )
    }

    fun unregister(id: String) {
        zones.remove(id)
        if (activeTarget?.id == id) activeTarget = null
    }

    fun beginDrag(location: Offset, density: Float, onHapticTick: () -> Unit) {
        isDragging = true
        isOverCancelSocket = false
        activeTarget = null
        onHapticTick()
        resolveTarget(location, density, onHapticTick)
    }

    fun updateDrag(location: Offset, density: Float, onHapticTick: () -> Unit) {
        if (!isDragging) return
        resolveTarget(location, density, onHapticTick)
    }

    fun endDrag(location: Offset, density: Float) {
        if (!isDragging) return
        resolveTarget(location, density, onHapticTick = {})
        val hit = if (isOverCancelSocket) null else activeTarget
        val action = hit?.let { zones[it.id]?.onDrop }
        isDragging = false
        isOverCancelSocket = false
        activeTarget = null
        when {
            hit != null && action != null -> action(hit.before)
            !isOverHome(location, density) -> fallbackDrop?.invoke()
        }
    }

    fun cancel() {
        isDragging = false
        isOverCancelSocket = false
        activeTarget = null
    }

    /** Clears stale zones when navigating between lists. */
    fun reset() {
        cancel()
        zones.clear()
    }

    private fun isOverHome(location: Offset, density: Float): Boolean {
        if (homeCenter == Offset.Zero) return false
        return hypot(location.x - homeCenter.x, location.y - homeCenter.y) < HOME_RADIUS_DP * density
    }

    private fun resolveTarget(location: Offset, density: Float, onHapticTick: () -> Unit) {
        val inCancelZone = homeCenter != Offset.Zero &&
            hypot(location.x - homeCenter.x, location.y - homeCenter.y) < CANCEL_RADIUS_DP * density
        if (inCancelZone) {
            if (!isOverCancelSocket) onHapticTick()
            isOverCancelSocket = true
            activeTarget = null
            return
        }
        isOverCancelSocket = false

        val containerHit = zones.values.firstOrNull { zone ->
            zone.kind == MagicPlusDropKind.Container &&
                location.x in zone.leftX..zone.rightX &&
                location.y in zone.topY..zone.bottomY
        }
        if (containerHit != null) {
            if (activeTarget?.id != containerHit.id) {
                onHapticTick()
                activeTarget = MagicPlusActiveTarget(containerHit.id, MagicPlusDropKind.Container, before = true)
            }
            return
        }

        val gaps = insertionPoints(density)
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
        if (openIndex != null && openIndex != bestIndex) {
            val openDistance = abs(gaps[openIndex].y - probeY)
            if (openDistance - bestDistance < HYSTERESIS_DP * density) return
        }
        if (bestIndex == openIndex) return
        val winner = gaps[bestIndex]
        onHapticTick()
        activeTarget = MagicPlusActiveTarget(winner.id, winner.kind, winner.before)
    }

    private fun insertionPoints(density: Float): List<Gap> {
        val points = mutableListOf<Gap>()
        for (zone in zones.values) {
            when (zone.kind) {
                MagicPlusDropKind.TaskRow -> {
                    points += Gap(zone.topY, zone.id, zone.kind, before = true, rank = 0)
                    points += Gap(zone.bottomY, zone.id, zone.kind, before = false, rank = 2)
                }
                MagicPlusDropKind.TaskSection -> {
                    points += Gap(zone.bottomY, zone.id, zone.kind, before = true, rank = 1)
                }
                MagicPlusDropKind.Container -> Unit
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
        const val CANCEL_RADIUS_DP = 48f
        const val HOME_RADIUS_DP = 40f
        const val MERGE_CLUSTER_DP = 16f
        const val HYSTERESIS_DP = 10f
    }
}

/**
 * Computes a task's insertion [position] immediately before or after [index]
 * in an ordered list of neighbor positions.
 */
fun insertionPosition(positions: List<Double?>, index: Int, before: Boolean): Double {
    val target = positions.getOrNull(index)
    val neighbor = positions.getOrNull(if (before) index - 1 else index + 1)
    return when {
        target != null && neighbor != null -> (target + neighbor) / 2.0
        target != null -> if (before) target - 1.0 else target + 1.0
        neighbor != null -> if (before) neighbor + 1.0 else neighbor - 1.0
        else -> if (before) index - 0.5 else index + 0.5
    }
}

/** Active Magic Plus drag coordinator, or null on hosts that do not use it. */
val LocalMagicPlusDrag = compositionLocalOf<MagicPlusDragState?> { null }

/** Brand tint for the insertion mark (Persimmon under Colorful, else the chosen accent). */
val LocalMagicPlusColor = compositionLocalOf { Color.Unspecified }

/** Registers a task row as a Magic Plus drop target and draws the insertion mark over its edge. */
fun Modifier.magicPlusRowDrop(
    id: String,
    enabled: Boolean,
    onDrop: (before: Boolean) -> Unit,
): Modifier = composed {
    val drag = LocalMagicPlusDrag.current
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
        label = "magicPlusRowMark",
    )
    this
        .onGloballyPositioned { coords ->
            val rect = coords.boundsInRoot()
            drag.register(id, MagicPlusDropKind.TaskRow, rect.top, rect.bottom, onDrop = onDrop)
        }
        .drawInsertionMark(tint, markAlpha, atTop = hoveredBefore == true, visible = hoveredBefore != null)
}

/** Registers a section or band header as a Magic Plus drop target; draws the mark under it. */
fun Modifier.magicPlusSectionDrop(
    id: String,
    enabled: Boolean = true,
    onDrop: () -> Unit,
): Modifier = composed {
    val drag = LocalMagicPlusDrag.current
    val tint = LocalMagicPlusColor.current
    if (drag == null || !enabled) return@composed this

    DisposableEffect(drag, id) {
        onDispose { drag.unregister(id) }
    }
    val isTargeted = drag.isDragging && drag.activeTarget?.id == id
    val markAlpha by animateFloatAsState(
        targetValue = if (isTargeted) 1f else 0f,
        animationSpec = tween(durationMillis = 120),
        label = "magicPlusSectionMark",
    )
    this
        .onGloballyPositioned { coords ->
            val rect = coords.boundsInRoot()
            drag.register(id, MagicPlusDropKind.TaskSection, rect.top, rect.bottom) { _ -> onDrop() }
        }
        .drawInsertionMark(tint, markAlpha, atTop = false, visible = isTargeted)
}

/**
 * Registers a container tile/row (e.g. a Lists Homepage smart-list pill, Area, or Project)
 * as a Magic Plus drop target and returns whether it is currently hovered so the caller can
 * highlight it with `SELECTION_WASH_ALPHA`.
 */
@androidx.compose.runtime.Composable
fun rememberMagicPlusContainerDrop(
    id: String,
    enabled: Boolean,
    onDrop: () -> Unit,
): Pair<Modifier, Boolean> {
    val drag = LocalMagicPlusDrag.current
    if (drag == null || !enabled) return Modifier to false

    DisposableEffect(drag, id) {
        onDispose { drag.unregister(id) }
    }
    val isTargeted = drag.isDragging && drag.activeTarget?.id == id
    val mod = Modifier.onGloballyPositioned { coords ->
        val rect = coords.boundsInRoot()
        drag.register(
            id = id,
            kind = MagicPlusDropKind.Container,
            topY = rect.top,
            bottomY = rect.bottom,
            leftX = rect.left,
            rightX = rect.right,
        ) { _ -> onDrop() }
    }
    return mod to isTargeted
}

private fun Modifier.drawInsertionMark(
    tint: Color,
    alpha: Float,
    atTop: Boolean,
    visible: Boolean,
): Modifier = drawWithContent {
    drawContent()
    if (!visible || alpha <= 0.01f || tint == Color.Unspecified) return@drawWithContent
    val heightPx = INSERTION_MARK_HEIGHT_DP.dp.toPx()
    val marginPx = INSERTION_MARK_MARGIN_DP.dp.toPx()
    val widthPx = (size.width - marginPx * 2f).coerceAtLeast(0f)
    val y = if (atTop) -heightPx / 2f else size.height - heightPx / 2f
    val radius = heightPx / 2f
    drawRoundRect(
        color = tint.copy(alpha = alpha),
        topLeft = Offset(marginPx, y),
        size = Size(widthPx, heightPx),
        cornerRadius = CornerRadius(radius, radius),
    )
}

private const val INSERTION_MARK_HEIGHT_DP = 6f
private const val INSERTION_MARK_MARGIN_DP = 16f
