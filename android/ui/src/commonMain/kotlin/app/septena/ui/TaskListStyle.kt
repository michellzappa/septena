package app.septena.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * The task list look the platform theme resolves from registry/tokens.json
 * (`taskCard`, `spacing`, `selection`). This module has no registry access.
 */
data class TaskListStyle(
    /** Fill of a task card. Translucent while a header texture is on. */
    val cardFill: Color,
    /** The one selection treatment of a list row: the accent wash over the card. */
    val selectionFill: Color,
    /** Star glyph on a starred row (`todayAccent`). */
    val starTint: Color,
    val cardRadius: Dp,
    val pageGutter: Dp,
    val groupGap: Dp,
)

val LocalTaskListStyle = staticCompositionLocalOf<TaskListStyle> { error("No TaskListStyle: use the app theme") }

/**
 * One row's slice of a task card (iPhone `taskCardChrome`): a run of rows
 * shares one rounded card inside the page gutter, with a gap below the run.
 */
@Composable
fun Modifier.taskCardSlice(
    first: Boolean,
    last: Boolean,
    selected: Boolean = false,
    gutter: Dp = LocalTaskListStyle.current.pageGutter,
): Modifier {
    val style = LocalTaskListStyle.current
    val top = if (first) style.cardRadius else 0.dp
    val bottom = if (last) style.cardRadius else 0.dp
    return this
        .padding(start = gutter, end = gutter, bottom = if (last) style.groupGap else 0.dp)
        .clip(RoundedCornerShape(topStart = top, topEnd = top, bottomStart = bottom, bottomEnd = bottom))
        .background(style.cardFill)
        .then(if (selected) Modifier.background(style.selectionFill) else Modifier)
}
