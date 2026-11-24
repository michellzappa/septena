package app.septena.android.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TaskHistoryEdgeTest {
    @Test
    fun historyEdgeReadsRegistryPlansCopy() {
        val note = historyEdgeUpsell("history_edge", "en")
        assertNotNull(note)
        assertEquals("history_edge", note!!.id)
        assertTrue(note.title.isNotEmpty())
        assertTrue(note.detail.contains("30"))
    }

    @Test
    fun historyEdgeIgnoresAbsentOrOtherUpsells() {
        assertNull(historyEdgeUpsell(null, "en"))
        assertNull(historyEdgeUpsell("second_device", "en"))
    }
}
