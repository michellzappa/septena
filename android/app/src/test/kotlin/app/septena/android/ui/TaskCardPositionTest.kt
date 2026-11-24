package app.septena.android.ui

import app.septena.ui.SeptenaIconKind
import app.septena.ui.TaskCardPosition
import app.septena.ui.TaskGroupHeader
import app.septena.ui.TaskListItem
import app.septena.ui.computeCardPositions
import org.junit.Assert.assertEquals
import org.junit.Test

class TaskCardPositionTest {
    @Test
    fun singleRowIsSolo() {
        assertEquals(listOf(TaskCardPosition.Solo), computeCardPositions(listOf(TaskListItem("1", "One"))))
    }

    @Test
    fun contiguousGroupsSplitIntoIndependentCards() {
        val work = TaskGroupHeader(key = "area:work", title = "Work", iconKind = SeptenaIconKind.Area, emoji = "💼")
        val home = TaskGroupHeader(key = "area:home", title = "Home", iconKind = SeptenaIconKind.Area, emoji = "🏡")
        val rows = listOf(
            TaskListItem("1", "A", group = work),
            TaskListItem("2", "B", group = work),
            TaskListItem("3", "C", group = work),
            TaskListItem("4", "D", group = home),
        )
        assertEquals(
            listOf(
                TaskCardPosition.Top,
                TaskCardPosition.Middle,
                TaskCardPosition.Bottom,
                TaskCardPosition.Solo,
            ),
            computeCardPositions(rows),
        )
    }
}
