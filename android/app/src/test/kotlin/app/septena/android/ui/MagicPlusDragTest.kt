package app.septena.android.ui

import androidx.compose.ui.geometry.Offset
import app.septena.ui.MagicPlusDragState
import app.septena.ui.MagicPlusDropKind
import app.septena.ui.MagicPlusInsertEdge
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

    @Test
    fun homepageListInsertSeparatesAreaAndProjectSlots() {
        val drag = MagicPlusDragState()
        drag.homeCenter = Offset(300f, 900f)
        val hits = mutableListOf<String>()
        drag.register(
            id = "proj-end",
            kind = MagicPlusDropKind.ListInsert(MagicPlusInsertEdge.Bottom, isArea = false, label = "New Project in Admin"),
            topY = 100f,
            bottomY = 144f,
        ) { hits += "proj-end" }
        drag.register(
            id = "area-before-home",
            kind = MagicPlusDropKind.ListInsert(MagicPlusInsertEdge.Top, isArea = true, label = "New Area"),
            topY = 158f,
            bottomY = 202f,
        ) { hits += "area-before-home" }
        drag.register(
            id = "home-first-proj",
            kind = MagicPlusDropKind.ListInsert(MagicPlusInsertEdge.Bottom, isArea = false, label = "New Project in Home"),
            topY = 158f,
            bottomY = 202f,
        ) { hits += "home-first-proj" }

        // Near bottom of Admin's last project → Project in Admin.
        drag.beginDrag(Offset(150f, 138f), density = 1f, onHapticTick = {})
        assertEquals("proj-end", drag.activeTarget?.id)
        assertEquals(false, drag.activeTarget?.isArea)
        assertEquals("New Project in Admin", drag.activeTarget?.label)

        // Move across the 14dp card gap to the top of Home → New Area.
        drag.updateDrag(Offset(150f, 162f), density = 1f, onHapticTick = {})
        assertEquals("area-before-home", drag.activeTarget?.id)
        assertEquals(true, drag.activeTarget?.isArea)
        assertEquals("New Area", drag.activeTarget?.label)

        // Move down into Home → New Project in Home.
        drag.updateDrag(Offset(150f, 196f), density = 1f, onHapticTick = {})
        assertEquals("home-first-proj", drag.activeTarget?.id)
        assertEquals(false, drag.activeTarget?.isArea)

        drag.endDrag(Offset(150f, 196f), density = 1f)
        assertEquals(listOf("home-first-proj"), hits)
    }
}
