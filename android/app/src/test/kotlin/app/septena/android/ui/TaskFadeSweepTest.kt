package app.septena.android.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset

class TaskFadeSweepTest {
    @Test
    fun sweepAnchorFindsMostRecentSunday() {
        // 2026-11-25 is Wednesday; most recent Sunday is 2026-11-22.
        val wed = Instant.parse("2026-11-25T10:00:00Z")
        assertEquals(LocalDate.of(2026, 11, 22), FadeSweepRules.mostRecentSweepAnchor(wed, ZoneOffset.UTC, sweepWeekday = 1))

        val sun = Instant.parse("2026-11-22T09:00:00Z")
        assertEquals(LocalDate.of(2026, 11, 22), FadeSweepRules.mostRecentSweepAnchor(sun, ZoneOffset.UTC, sweepWeekday = 1))
    }

    @Test
    fun sweepIsDueOnlyOnSundayWithUnsweptFadedTasks() {
        val sunday = Instant.parse("2026-11-22T10:00:00Z")
        val monday = Instant.parse("2026-11-23T10:00:00Z")
        val faded = listOf(Instant.parse("2026-11-20T08:00:00Z"))

        assertTrue(FadeSweepRules.isSweepDue(sunday, lastSweepAt = null, dismissedWeek = null, fadedDates = faded, zoneId = ZoneOffset.UTC))
        assertFalse(FadeSweepRules.isSweepDue(monday, lastSweepAt = null, dismissedWeek = null, fadedDates = faded, zoneId = ZoneOffset.UTC))
        assertFalse(
            FadeSweepRules.isSweepDue(
                sunday,
                lastSweepAt = Instant.parse("2026-11-22T08:00:00Z"),
                dismissedWeek = null,
                fadedDates = faded,
                zoneId = ZoneOffset.UTC,
            ),
        )
        assertFalse(
            FadeSweepRules.isSweepDue(
                sunday,
                lastSweepAt = null,
                dismissedWeek = LocalDate.of(2026, 11, 22),
                fadedDates = faded,
                zoneId = ZoneOffset.UTC,
            ),
        )
    }

    @Test
    fun sweepReasonFormatsAgeDateStateAndList() {
        val now = Instant.parse("2026-11-25T12:00:00Z")
        val old = Instant.parse("2026-11-01T12:00:00Z")
        val reason = FadeSweepRules.sweepReason(
            touchedAt = old,
            createdAt = old,
            created = null,
            listName = "Work",
            scheduled = null,
            now = now,
            zoneId = ZoneOffset.UTC,
        )
        assertEquals("24 days without activity · No date · Work", reason)
    }
}
