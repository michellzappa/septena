package app.septena.core

import app.septena.core.generated.RegistryDestinationIds
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale

/** Upcoming day header matching the shared short and long date labels used by the task lists. */
fun formatUpcomingDayHeader(
    day: LocalDate,
    today: LocalDate,
    languageTag: String = Locale.getDefault().toLanguageTag(),
): String {
    val diff = ChronoUnit.DAYS.between(today, day)
    if (diff == 0L) {
        return RegistryCatalog.destinationTitle(RegistryDestinationIds.TODAY, languageTag).orEmpty()
    }
    if (diff == 1L) {
        return RegistryCatalog.tomorrowLabel(languageTag)
    }
    val locale = Locale.forLanguageTag(languageTag)
    val pattern = if (diff in 2L..6L) "EEEE" else if (day.year == today.year) "EEE, MMM d" else "EEE, MMM d, yyyy"
    val formatted = DateTimeFormatter.ofPattern(pattern, locale).format(day)
    return formatted.replaceFirstChar { ch -> if (ch.isLowerCase()) ch.titlecase(locale) else ch.toString() }
}
