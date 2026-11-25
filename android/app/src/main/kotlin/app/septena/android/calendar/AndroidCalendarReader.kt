package app.septena.android.calendar

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CalendarContract
import androidx.core.content.ContextCompat
import app.septena.ui.CalendarAgendaRow
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

data class DeviceCalendarInfo(
    val id: Long,
    val name: String,
    val accountName: String,
    val color: Int,
)

data class CalendarAgendaEvent(
    val id: String,
    val title: String,
    val day: LocalDate,
    val startMillis: Long,
    val isAllDay: Boolean,
    val calendarName: String,
)

/**
 * Read-only Android Calendar provider bridge (feature `calendar.events`).
 * Mirrors Apple `CalendarBridge` + `CalendarEventRow`: never writes events,
 * respects `READ_CALENDAR` permission and synced `calendarHiddenTitles`.
 */
object AndroidCalendarReader {
    fun hasPermission(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED

    fun listCalendars(context: Context): List<DeviceCalendarInfo> {
        if (!hasPermission(context)) return emptyList()
        val projection = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
            CalendarContract.Calendars.ACCOUNT_NAME,
            CalendarContract.Calendars.CALENDAR_COLOR,
        )
        val out = mutableListOf<DeviceCalendarInfo>()
        runCatching {
            context.contentResolver.query(
                CalendarContract.Calendars.CONTENT_URI,
                projection,
                "${CalendarContract.Calendars.VISIBLE} = 1",
                null,
                "${CalendarContract.Calendars.CALENDAR_DISPLAY_NAME} ASC",
            )?.use { cursor ->
                val idIdx = cursor.getColumnIndex(CalendarContract.Calendars._ID)
                val nameIdx = cursor.getColumnIndex(CalendarContract.Calendars.CALENDAR_DISPLAY_NAME)
                val acctIdx = cursor.getColumnIndex(CalendarContract.Calendars.ACCOUNT_NAME)
                val colorIdx = cursor.getColumnIndex(CalendarContract.Calendars.CALENDAR_COLOR)
                while (cursor.moveToNext()) {
                    val id = if (idIdx >= 0) cursor.getLong(idIdx) else continue
                    val name = (if (nameIdx >= 0) cursor.getString(nameIdx) else null)
                        ?.trim().takeUnless { it.isNullOrEmpty() } ?: continue
                    val acct = (if (acctIdx >= 0) cursor.getString(acctIdx) else null).orEmpty()
                    val color = if (colorIdx >= 0) cursor.getInt(colorIdx) else 0
                    out += DeviceCalendarInfo(id = id, name = name, accountName = acct, color = color)
                }
            }
        }
        return out
    }

    fun loadAgendaRows(
        context: Context,
        startDay: LocalDate,
        dayCount: Int,
        hiddenTitles: Set<String>,
        includeDayLabel: Boolean,
        languageTag: String = Locale.getDefault().toLanguageTag(),
        zoneId: ZoneId = ZoneId.systemDefault(),
    ): List<CalendarAgendaRow> {
        if (!hasPermission(context) || dayCount <= 0) return emptyList()
        val endDay = startDay.plusDays(dayCount.toLong() - 1L)
        // Query with a 1-day buffer on each side so UTC all-day rows are never clipped by timezone offset.
        val queryStartMillis = startDay.minusDays(1).atStartOfDay(zoneId).toInstant().toEpochMilli()
        val queryEndMillis = endDay.plusDays(2).atStartOfDay(zoneId).toInstant().toEpochMilli()

        val projection = arrayOf(
            CalendarContract.Instances.EVENT_ID,
            CalendarContract.Instances.TITLE,
            CalendarContract.Instances.BEGIN,
            CalendarContract.Instances.END,
            CalendarContract.Instances.ALL_DAY,
            CalendarContract.Instances.CALENDAR_DISPLAY_NAME,
            CalendarContract.Instances.SELF_ATTENDEE_STATUS,
        )
        val rawEvents = mutableListOf<CalendarAgendaEvent>()
        runCatching {
            CalendarContract.Instances.query(
                context.contentResolver,
                projection,
                queryStartMillis,
                queryEndMillis,
            )?.use { cursor ->
                val eventIdIdx = cursor.getColumnIndex(CalendarContract.Instances.EVENT_ID)
                val titleIdx = cursor.getColumnIndex(CalendarContract.Instances.TITLE)
                val beginIdx = cursor.getColumnIndex(CalendarContract.Instances.BEGIN)
                val endIdx = cursor.getColumnIndex(CalendarContract.Instances.END)
                val allDayIdx = cursor.getColumnIndex(CalendarContract.Instances.ALL_DAY)
                val calNameIdx = cursor.getColumnIndex(CalendarContract.Instances.CALENDAR_DISPLAY_NAME)
                val statusIdx = cursor.getColumnIndex(CalendarContract.Instances.SELF_ATTENDEE_STATUS)

                while (cursor.moveToNext()) {
                    val status = if (statusIdx >= 0) cursor.getInt(statusIdx) else 0
                    if (status == CalendarContract.Attendees.ATTENDEE_STATUS_DECLINED) continue
                    val eventId = if (eventIdIdx >= 0) cursor.getLong(eventIdIdx) else 0L
                    val title = (if (titleIdx >= 0) cursor.getString(titleIdx) else null)
                        ?.trim().takeUnless { it.isNullOrEmpty() } ?: "Event"
                    val begin = if (beginIdx >= 0) cursor.getLong(beginIdx) else continue
                    val end = if (endIdx >= 0) cursor.getLong(endIdx) else begin
                    val isAllDay = (if (allDayIdx >= 0) cursor.getInt(allDayIdx) else 0) == 1
                    val calName = (if (calNameIdx >= 0) cursor.getString(calNameIdx) else null).orEmpty()

                    if (isAllDay) {
                        val firstDay = Instant.ofEpochMilli(begin).atZone(ZoneOffset.UTC).toLocalDate()
                        val lastExclusive = Instant.ofEpochMilli(end).atZone(ZoneOffset.UTC).toLocalDate()
                        val lastDay = if (lastExclusive.isAfter(firstDay)) lastExclusive.minusDays(1) else firstDay
                        var day = maxOf(firstDay, startDay)
                        val clampedEnd = minOf(lastDay, endDay)
                        while (!day.isAfter(clampedEnd)) {
                            rawEvents += CalendarAgendaEvent(
                                id = "evt:$eventId:$day:allday",
                                title = title,
                                day = day,
                                startMillis = begin,
                                isAllDay = true,
                                calendarName = calName,
                            )
                            day = day.plusDays(1)
                        }
                    } else {
                        val eventDay = Instant.ofEpochMilli(begin).atZone(zoneId).toLocalDate()
                        if (!eventDay.isBefore(startDay) && !eventDay.isAfter(endDay)) {
                            rawEvents += CalendarAgendaEvent(
                                id = "evt:$eventId@$begin",
                                title = title,
                                day = eventDay,
                                startMillis = begin,
                                isAllDay = false,
                                calendarName = calName,
                            )
                        }
                    }
                }
            }
        }
        return formatAgendaRows(
            events = rawEvents,
            hiddenTitles = hiddenTitles,
            includeDayLabel = includeDayLabel,
            languageTag = languageTag,
            zoneId = zoneId,
        )
    }

    internal fun formatAgendaRows(
        events: List<CalendarAgendaEvent>,
        hiddenTitles: Set<String>,
        includeDayLabel: Boolean,
        languageTag: String,
        zoneId: ZoneId,
    ): List<CalendarAgendaRow> {
        val hiddenLower = hiddenTitles.mapTo(HashSet()) { it.trim().lowercase() }
        val locale = Locale.forLanguageTag(languageTag)
        val timeFmt = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withLocale(locale)
        val dayFmt = DateTimeFormatter.ofPattern("EEE, MMM d", locale)
        return events
            .filter { it.calendarName.trim().lowercase() !in hiddenLower }
            .distinctBy { it.id }
            .sortedWith(
                compareBy<CalendarAgendaEvent>(
                    { it.day },
                    { if (it.isAllDay) 0 else 1 },
                    { it.startMillis },
                    { it.title.lowercase() },
                ),
            )
            .map { event ->
                val timeLabel = if (event.isAllDay) {
                    null
                } else {
                    timeFmt.format(Instant.ofEpochMilli(event.startMillis).atZone(zoneId))
                }
                CalendarAgendaRow(
                    id = event.id,
                    title = event.title.trim().ifEmpty { "Event" },
                    timeLabel = timeLabel,
                    isAllDay = event.isAllDay,
                    dayLabel = if (includeDayLabel) dayFmt.format(event.day) else null,
                    dayIso = event.day.toString(),
                )
            }
    }
}
