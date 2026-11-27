package app.septena.android.ui

import android.view.HapticFeedbackConstants
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import app.septena.core.RegistryCatalog
import app.septena.core.generated.RegistryActionIds
import app.septena.ui.MagicPlusDragState
import kotlin.math.hypot

/**
 * Floating circular Magic Plus orb at the bottom-right corner, matching iPhone's
 * `MagicPlusOrb` (`SeptaskRootView.swift`):
 * - Solid 58 dp circle in Persimmon under Colorful (else the user's fruit accent)
 *   with `+` and 3×2 tactile grip dots beneath it.
 * - Tap creates a task; on a Project page it opens a two-row menu (New Task,
 *   New Section).
 * - Instant drag (8 dp slop, no hold delay) hides the orb, reveals a circular
 *   cancel socket (`×`) in its resting spot, and draws the insertion mark over
 *   the nearest row gap or section header.
 */
@Composable
internal fun MagicPlusOrb(
    drag: MagicPlusDragState,
    isViewingProject: Boolean,
    accessibilityLabel: String,
    languageTag: String,
    onNewTask: () -> Unit,
    onNewSection: () -> Unit,
    modifier: Modifier = Modifier,
    /** On an area page a tap opens New Task / New Project in Area (iPhone `opensQuickMenuOnTap`). */
    isViewingArea: Boolean = false,
    onNewProjectInArea: () -> Unit = {},
) {
    val opensMenuOnTap = isViewingProject || isViewingArea
    val colors = LocalMagicPlusColors.current
    val fill = if (colors.fill != Color.Unspecified) colors.fill else MaterialTheme.colorScheme.primary
    val ink = if (colors.ink != Color.Unspecified) colors.ink else MaterialTheme.colorScheme.onPrimary
    val view = LocalView.current
    val density = LocalDensity.current.density
    val dragSlopPx = with(LocalDensity.current) { DRAG_SLOP_DP.dp.toPx() }

    var showingMenu by remember { mutableStateOf(false) }
    var isPressed by remember { mutableStateOf(false) }
    var popTick by remember { mutableIntStateOf(0) }
    var orbRootOrigin by remember { mutableStateOf(Offset.Zero) }

    val popScale = remember { Animatable(1f) }
    LaunchedEffect(popTick) {
        if (popTick == 0) return@LaunchedEffect
        popScale.animateTo(1.14f, tween(durationMillis = 100))
        popScale.animateTo(
            1f,
            spring(dampingRatio = Spring.DampingRatioMediumBouncy, stiffness = Spring.StiffnessMedium),
        )
    }

    val pressScale by animateFloatAsState(
        targetValue = if (isPressed && !drag.isDragging) 0.88f else 1f,
        animationSpec = spring(dampingRatio = 0.6f, stiffness = Spring.StiffnessMediumLow),
        label = "magicPlusPressScale",
    )
    val orbAlpha by animateFloatAsState(
        targetValue = if (drag.isDragging) 0f else 1f,
        animationSpec = tween(durationMillis = 160),
        label = "magicPlusOrbAlpha",
    )
    val orbDragScale by animateFloatAsState(
        targetValue = if (drag.isDragging) 0.75f else 1f,
        animationSpec = tween(durationMillis = 160),
        label = "magicPlusOrbDragScale",
    )
    val cancelAlpha by animateFloatAsState(
        targetValue = if (drag.isDragging) 1f else 0f,
        animationSpec = tween(durationMillis = 160),
        label = "magicPlusCancelAlpha",
    )
    val cancelScale by animateFloatAsState(
        targetValue = when {
            !drag.isDragging -> 0.75f
            drag.isOverCancelSocket -> 1.08f
            else -> 0.94f
        },
        animationSpec = tween(durationMillis = 150),
        label = "magicPlusCancelScale",
    )

    val hapticTick: () -> Unit = {
        view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
    }

    val newTaskTitle = remember(languageTag) {
        RegistryCatalog.actionTitle(RegistryActionIds.APP_NEW_TASK, languageTag = languageTag).orEmpty()
    }
    val newSectionTitle = remember(languageTag) {
        RegistryCatalog.actionTitle(RegistryActionIds.SECTION_NEW, languageTag = languageTag).orEmpty()
    }
    val newProjectInAreaTitle = remember(languageTag) {
        RegistryCatalog.actionTitle(RegistryActionIds.AREA_NEW_PROJECT, languageTag = languageTag).orEmpty()
    }

    Box(
        modifier = modifier
            .size(ORB_SIZE_DP.dp)
            .onGloballyPositioned { coords ->
                val origin = coords.positionInRoot()
                orbRootOrigin = origin
                drag.homeCenter = Offset(
                    x = origin.x + coords.size.width / 2f,
                    y = origin.y + coords.size.height / 2f,
                )
            }
            .semantics {
                contentDescription = accessibilityLabel
                role = Role.Button
            }
            .pointerInput(drag, opensMenuOnTap, onNewTask) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    val downPos = down.position
                    var dragging = false
                    isPressed = true
                    try {
                        while (true) {
                            val event = awaitPointerEvent()
                            val change = event.changes.firstOrNull { it.id == down.id } ?: break
                            if (!change.pressed) {
                                if (dragging) {
                                    change.consume()
                                    drag.endDrag(orbRootOrigin + change.position, density)
                                } else {
                                    view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                                    popTick += 1
                                    if (opensMenuOnTap) showingMenu = true else onNewTask()
                                }
                                break
                            }
                            val moved = hypot(change.position.x - downPos.x, change.position.y - downPos.y)
                            if (!dragging && moved >= dragSlopPx) {
                                dragging = true
                                showingMenu = false
                                drag.beginDrag(orbRootOrigin + change.position, density, hapticTick)
                            }
                            if (dragging) {
                                change.consume()
                                drag.updateDrag(orbRootOrigin + change.position, density, hapticTick)
                            }
                        }
                    } finally {
                        isPressed = false
                        if (dragging && drag.isDragging) drag.cancel()
                    }
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        // Resting "+" orb — round Persimmon/accent circle with subtle gradient, rim and 3×2 grip dots.
        val highlight = Color(
            red = (fill.red + 0.08f).coerceAtMost(1f),
            green = (fill.green + 0.08f).coerceAtMost(1f),
            blue = (fill.blue + 0.08f).coerceAtMost(1f),
            alpha = 1f,
        )
        Box(
            modifier = Modifier
                .size(ORB_SIZE_DP.dp)
                .scale(pressScale * popScale.value * orbDragScale)
                .alpha(orbAlpha)
                .shadow(elevation = 10.dp, shape = CircleShape, clip = false)
                .clip(CircleShape)
                .background(Brush.verticalGradient(listOf(highlight, fill)))
                .border(0.75.dp, ink.copy(alpha = 0.22f), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            MagicPlusGlyph(ink = ink)
        }

        // Cancel drop socket — appears in the resting corner while dragging.
        val cancelBg = if (drag.isOverCancelSocket) {
            MaterialTheme.colorScheme.error.copy(alpha = 0.22f)
        } else {
            MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.92f)
        }
        val cancelBorder = if (drag.isOverCancelSocket) {
            MaterialTheme.colorScheme.error.copy(alpha = 0.55f)
        } else {
            MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.65f)
        }
        val cancelInk = if (drag.isOverCancelSocket) {
            MaterialTheme.colorScheme.error
        } else {
            MaterialTheme.colorScheme.onSurfaceVariant
        }
        Box(
            modifier = Modifier
                .size(ORB_SIZE_DP.dp)
                .scale(cancelScale)
                .alpha(cancelAlpha)
                .clip(CircleShape)
                .background(cancelBg)
                .border(1.dp, cancelBorder, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            CancelGlyph(ink = cancelInk)
        }

        if (opensMenuOnTap) {
            DropdownMenu(
                expanded = showingMenu,
                onDismissRequest = { showingMenu = false },
            ) {
                DropdownMenuItem(
                    text = { Text(newTaskTitle) },
                    onClick = {
                        showingMenu = false
                        onNewTask()
                    },
                )
                DropdownMenuItem(
                    text = { Text(if (isViewingProject) newSectionTitle else newProjectInAreaTitle) },
                    onClick = {
                        showingMenu = false
                        if (isViewingProject) onNewSection() else onNewProjectInArea()
                    },
                )
            }
        }
    }
}

/** Bold `+` above 3×2 tactile grip dots (matches iPhone `MagicPlusOrb`). */
@Composable
private fun MagicPlusGlyph(ink: Color) {
    Canvas(modifier = Modifier.size(34.dp)) {
        val centerX = size.width / 2f
        val plusCenterY = size.height * 0.40f
        val arm = 8.5.dp.toPx()
        val stroke = 2.6.dp.toPx()
        drawLine(
            color = ink,
            start = Offset(centerX - arm, plusCenterY),
            end = Offset(centerX + arm, plusCenterY),
            strokeWidth = stroke,
            cap = StrokeCap.Round,
        )
        drawLine(
            color = ink,
            start = Offset(centerX, plusCenterY - arm),
            end = Offset(centerX, plusCenterY + arm),
            strokeWidth = stroke,
            cap = StrokeCap.Round,
        )
        // 3×2 tactile grip dots beneath `+` signaling drag.
        val dotRadius = 1.25.dp.toPx()
        val dx = 5.5.dp.toPx()
        val dy = 5.0.dp.toPx()
        val firstRowY = plusCenterY + arm + 5.0.dp.toPx()
        val dotColor = ink.copy(alpha = 0.55f)
        for (row in 0..1) {
            val y = firstRowY + row * dy
            for (col in -1..1) {
                drawCircle(
                    color = dotColor,
                    radius = dotRadius,
                    center = Offset(centerX + col * dx, y),
                )
            }
        }
    }
}

/** Crisp `×` inside the cancel drop socket. */
@Composable
private fun CancelGlyph(ink: Color) {
    Canvas(modifier = Modifier.size(18.dp)) {
        val inset = 2.dp.toPx()
        val stroke = 2.2.dp.toPx()
        drawLine(
            color = ink,
            start = Offset(inset, inset),
            end = Offset(size.width - inset, size.height - inset),
            strokeWidth = stroke,
            cap = StrokeCap.Round,
        )
        drawLine(
            color = ink,
            start = Offset(size.width - inset, inset),
            end = Offset(inset, size.height - inset),
            strokeWidth = stroke,
            cap = StrokeCap.Round,
        )
    }
}

private const val ORB_SIZE_DP = 58
private const val DRAG_SLOP_DP = 8f
