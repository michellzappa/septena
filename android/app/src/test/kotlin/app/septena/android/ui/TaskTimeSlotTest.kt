package app.septena.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TaskTimeSlotTest {
    @Test
    fun parsesValidClockTimesAndRejectsMalformed() {
        assertEquals(9 to 0, TaskTimeSlot.parse("09:00"))
        assertEquals(23 to 59, TaskTimeSlot.parse("23:59"))
        assertEquals(0 to 0, TaskTimeSlot.parse("00:00"))
        assertNull(TaskTimeSlot.parse(null))
        assertNull(TaskTimeSlot.parse(""))
        assertNull(TaskTimeSlot.parse("9:00"))
        assertNull(TaskTimeSlot.parse("24:00"))
        assertNull(TaskTimeSlot.parse("12:60"))
        assertNull(TaskTimeSlot.parse("12-30"))
    }

    @Test
    fun formatsStartOnlyAndDurationRanges() {
        assertEquals("14:00", TaskTimeSlot.format("14:00", null))
        assertEquals("14:00", TaskTimeSlot.format("14:00", 0))
        assertEquals("14:00", TaskTimeSlot.format("14:00", 4))
        assertEquals("14:00–14:15", TaskTimeSlot.format("14:00", 15))
        assertEquals("14:00–15:00", TaskTimeSlot.format("14:00", 60))
        assertEquals("23:30–00:30", TaskTimeSlot.format("23:30", 60))
        assertNull(TaskTimeSlot.format(null, 30))
    }

    @Test
    fun hhmmClampsAndZeroPads() {
        assertEquals("00:05", TaskTimeSlot.hhmm(0, 5))
        assertEquals("23:59", TaskTimeSlot.hhmm(29, 99))
        assertEquals("00:00", TaskTimeSlot.hhmm(-1, -4))
    }

    @Test
    fun quickDurationsMatchApplePresets() {
        assertEquals(listOf(15, 30, 60, 120), TaskTimeSlot.quickDurations.map { it.minutes })
        assertEquals(listOf("15m", "30m", "1h", "2h"), TaskTimeSlot.quickDurations.map { it.label })
    }
}
