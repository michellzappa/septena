package app.septena.android.ui

import androidx.compose.ui.geometry.Offset
import app.septena.ui.MagicPlusDragState
import app.septena.ui.MagicPlusDropKind
import app.septena.ui.insertionPosition
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MagicPlusDragTest {
    @Test
    fun insertionPositionSplitsNeighborsAndEdges() {
        val positions = listOf(10.0, 20.0, 30.0)
        assertEquals(9.0, insertionPosition(positions, 0, before = true), 1e-9)
        assertEquals(15.0, insertionPosition(positions, 0, before = false), 1e-9)
        assertEquals(15.0, insertionPosition(positions, 1, before = true), 1e-9)
        assertEquals(25.0, insertionPosition(positions, 1, before = false), 1e-9)
        assertEquals(31.0, insertionPosition(positions, 2, before = false), 1e-9)
    }

    @Test
    fun dragMergesTouchingRowsAndCancelsOverHomeSocket() {
        val drag = MagicPlusDragState()
        drag.homeCenter = Offset(300f, 800f)
        var dropped: Pair<String, Boolean>? = null
        drag.register("row-a", MagicPlusDropKind.TaskRow, topY = 100f, bottomY = 150f) { before ->
            dropped = "row-a" to before
        }
        drag.register("row-b", MagicPlusDropKind.TaskRow, topY = 150f, bottomY = 200f) { before ->
            dropped = "row-b" to before
        }

        // At y = 150 (shared boundary), row-b's top (rank 0) beats row-a's bottom (rank 2).
        drag.beginDrag(Offset(150f, 152f), density = 1f, onHapticTick = {})
        assertTrue(drag.isDragging)
        assertFalse(drag.isOverCancelSocket)
        assertEquals("row-b", drag.activeTarget?.id)
        assertEquals(true, drag.activeTarget?.before)

        // Moving onto the resting home socket cancels cleanly and drops nothing.
        drag.updateDrag(Offset(305f, 795f), density = 1f, onHapticTick = {})
        assertTrue(drag.isOverCancelSocket)
        assertNull(drag.activeTarget)
        drag.endDrag(Offset(305f, 795f), density = 1f)
        assertFalse(drag.isDragging)
        assertNull(dropped)

        // Dropping over row-b's top invokes its drop handler.
        drag.beginDrag(Offset(150f, 152f), density = 1f, onHapticTick = {})
        drag.endDrag(Offset(150f, 152f), density = 1f)
        assertEquals("row-b" to true, dropped)
    }

    @Test
    fun emptyListDropInvokesFallbackWhenOutsideHome() {
        val drag = MagicPlusDragState()
        drag.homeCenter = Offset(300f, 800f)
        var fallbackCalls = 0
        drag.fallbackDrop = { fallbackCalls += 1 }

        drag.beginDrag(Offset(150f, 300f), density = 1f, onHapticTick = {})
        drag.endDrag(Offset(150f, 300f), density = 1f)
        assertEquals(1, fallbackCalls)
    }
}
