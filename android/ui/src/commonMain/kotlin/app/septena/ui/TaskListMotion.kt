package app.septena.ui

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.lazy.LazyItemScope
import androidx.compose.ui.Modifier

private const val SHIFT_MILLIS = 320
private const val FADE_IN_MILLIS = 200
private const val FADE_OUT_MILLIS = 140

/**
 * The one motion of a task list: rows, headers and empty states slide together on one curve.
 * Put it on EVERY item that can move. An item without it jumps while its neighbors slide.
 * A leaving row fades out before the row below reaches its title.
 * The system "Remove animations" setting turns it off.
 */
fun LazyItemScope.taskListMotion(): Modifier = Modifier.animateItem(
    fadeInSpec = tween(FADE_IN_MILLIS),
    placementSpec = tween(SHIFT_MILLIS, easing = FastOutSlowInEasing),
    fadeOutSpec = tween(FADE_OUT_MILLIS),
)
