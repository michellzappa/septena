package app.septena.android.ui

import app.septena.core.formatUpcomingDayHeader
import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.LocalDate

class UpcomingDateGroupingTest {
    private val today = LocalDate.of(2026, 11, 25) // Wednesday

    @Test
    fun formatUpcomingDayHeaderMatchesAppleScheduleHeaderLabel() {
        assertEquals("Today", formatUpcomingDayHeader(today, today, "en-US"))
        assertEquals("Tomorrow", formatUpcomingDayHeader(today.plusDays(1), today, "en-US"))
        assertEquals("Friday", formatUpcomingDayHeader(today.plusDays(2), today, "en-US"))
        assertEquals("Tuesday", formatUpcomingDayHeader(today.plusDays(6), today, "en-US"))
        assertEquals("Wed, Dec 2", formatUpcomingDayHeader(today.plusDays(7), today, "en-US"))
        assertEquals("Fri, Jan 1, 2027", formatUpcomingDayHeader(LocalDate.of(2027, 1, 1), today, "en-US"))
    }

    @Test
    fun formatUpcomingDayHeaderLocalizesToPtBr() {
        assertEquals("Hoje", formatUpcomingDayHeader(today, today, "pt-BR"))
        assertEquals("Amanhã", formatUpcomingDayHeader(today.plusDays(1), today, "pt-BR"))
    }
}
