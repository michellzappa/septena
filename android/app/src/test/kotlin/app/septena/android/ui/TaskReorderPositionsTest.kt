package app.septena.android.ui

import app.septena.ui.reorderPositions
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TaskReorderPositionsTest {
    @Test
    fun singleItemMatchesMidpointInsertion() {
        val pos = reorderPositions(listOf(1.0, 2.0, 3.0), targetIndex = 1, before = true, count = 1)
        assertEquals(listOf(1.5), pos)
    }

    @Test
    fun multiItemPreservesStrictAscendingOrderBetweenNeighbors() {
        val pos = reorderPositions(listOf(1.0, 2.0, 5.0), targetIndex = 2, before = true, count = 3)
        assertEquals(3, pos.size)
        assertTrue(pos[0] > 2.0 && pos[0] < pos[1] && pos[1] < pos[2] && pos[2] < 5.0)
    }

    @Test
    fun multiItemBeforeFirstRowPreservesRelativeOrder() {
        val pos = reorderPositions(listOf(0.0, 1.0), targetIndex = 0, before = true, count = 3)
        assertEquals(listOf(-3.0, -2.0, -1.0), pos)
    }

    @Test
    fun multiItemAfterLastRowPreservesRelativeOrder() {
        val pos = reorderPositions(listOf(0.0, 1.0), targetIndex = 1, before = false, count = 2)
        assertEquals(listOf(2.0, 3.0), pos)
    }
}
