package app.septena.android.calendar

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneOffset

class AndroidCalendarAgendaTest {
    private val day1 = LocalDate.of(2026, 11, 25)
    private val day2 = LocalDate.of(2026, 11, 26)

    private fun millis(day: LocalDate, hour: Int, minute: Int): Long =
        LocalDateTime.of(day.year, day.month, day.dayOfMonth, hour, minute)
            .toInstant(ZoneOffset.UTC)
            .toEpochMilli()

    @Test
    fun filtersHiddenCalendarsSortsAllDayFirstAndFallsBackBlankTitle() {
        val events = listOf(
            CalendarAgendaEvent("e-late", "Dinner", day1, millis(day1, 19, 0), isAllDay = false, calendarName = "Personal"),
            CalendarAgendaEvent("e-hidden", "Holiday", day1, millis(day1, 0, 0), isAllDay = true, calendarName = "Holidays"),
            CalendarAgendaEvent("e-blank", "   ", day1, millis(day1, 9, 0), isAllDay = false, calendarName = "Work"),
            CalendarAgendaEvent("e-allday", "Offsite", day1, millis(day1, 0, 0), isAllDay = true, calendarName = "Work"),
            CalendarAgendaEvent("e-day2", "Flight", day2, millis(day2, 8, 30), isAllDay = false, calendarName = "Personal"),
        )
        val rows = AndroidCalendarReader.formatAgendaRows(
            events = events,
            hiddenTitles = setOf("holidays"),
            includeDayLabel = true,
            languageTag = "en-US",
            zoneId = ZoneOffset.UTC,
        )
        assertEquals(4, rows.size)
        assertEquals("e-allday", rows[0].id)
        assertTrue(rows[0].isAllDay)
        assertNull(rows[0].timeLabel)
        assertEquals("e-blank", rows[1].id)
        assertEquals("Event", rows[1].title)
        assertEquals("e-late", rows[2].id)
        assertEquals("e-day2", rows[3].id)
        assertTrue(rows[3].dayLabel.orEmpty().contains("26"))
    }
}
