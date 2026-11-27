package app.septena.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput

/**
 * While an inline task editor is open, every other row, header and surface of
 * the list fades back, and a tap on one folds the editor instead of running its
 * own action (Apple `InlineEditDimmedModifier`, TaskListChrome.swift).
 */
@Immutable
data class InlineEditDim(
    val isActive: Boolean = false,
    val onDismiss: () -> Unit = {},
)

val LocalInlineEditDim = compositionLocalOf { InlineEditDim() }

/** Apple's dimmed opacity for the rest of the list while an inline editor is open. */
private const val INLINE_EDIT_DIM_ALPHA = 0.32f
private const val INLINE_EDIT_DIM_MILLIS = 180

/**
 * Fades this item while [LocalInlineEditDim] is active and turns a tap on it into
 * "fold the editor". A drag still scrolls the list: only the press and the tap
 * are taken, so the row's own buttons never see them.
 */
fun Modifier.inlineEditDimmed(): Modifier = composed {
    val dim = LocalInlineEditDim.current
    val fade by animateFloatAsState(
        targetValue = if (dim.isActive) INLINE_EDIT_DIM_ALPHA else 1f,
        animationSpec = tween(INLINE_EDIT_DIM_MILLIS),
        label = "inlineEditDim",
    )
    val faded = this.graphicsLayer { alpha = fade }
    if (!dim.isActive) return@composed faded
    val onDismiss by rememberUpdatedState(dim.onDismiss)
    faded.pointerInput(Unit) {
        val slop = viewConfiguration.touchSlop
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
            down.consume()
            while (true) {
                val event = awaitPointerEvent(PointerEventPass.Initial)
                val change = event.changes.firstOrNull { it.id == down.id } ?: break
                if ((change.position - down.position).getDistance() > slop) break
                if (!change.pressed) {
                    change.consume()
                    onDismiss()
                    break
                }
            }
        }
    }
}
