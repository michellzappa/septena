package app.septena.android.ui

import android.text.format.DateFormat
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DatePicker
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.septena.core.DateBoardRowKinds
import app.septena.core.RegistryCatalog
import app.septena.core.generated.RegistryDestinationIds
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.util.Locale

/** Today and the next six days: the same window as the Apple strips. */
private const val STRIP_DAYS = 7L

/**
 * The date board, embedded in its attribute row: a seven-day strip that starts
 * today, then the registry's rows (Tomorrow, Pick another date, Clear). Every
 * row has the same shape, and every pick commits and folds the row through the
 * caller. The Repeat and time rows do not show here: on Android, Repeat is the
 * next attribute row of the task page, and there is no time editor yet.
 */
@Composable
internal fun TaskDateBoard(
    attribute: String,
    initialDay: String?,
    today: LocalDate,
    languageTag: String,
    enabled: Boolean,
    onSelect: (String) -> Unit,
    onClear: () -> Unit,
) {
    val current = remember(initialDay) { initialDay?.let { runCatching { LocalDate.parse(it.take(10)) }.getOrNull() } }
    val rows = remember(attribute, languageTag) {
        RegistryCatalog.dateBoardRows(attribute, languageTag = languageTag)
    }
    val locale = Locale.forLanguageTag(languageTag)
    val isBeyondStrip = current != null && (current < today || current >= today.plusDays(STRIP_DAYS))
    var showsCalendar by remember { mutableStateOf(false) }

    DayStrip(
        today = today,
        current = current,
        locale = locale,
        todayLabel = RegistryCatalog.destinationTitle(RegistryDestinationIds.TODAY, languageTag).orEmpty(),
        enabled = enabled,
        onSelect = { onSelect(it.toString()) },
    )
    HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
    rows.forEach { row ->
        when (row.kind) {
            DateBoardRowKinds.TOMORROW -> BoardRow(row.label, enabled) { onSelect(today.plusDays(1).toString()) }
            DateBoardRowKinds.CALENDAR -> {
                // A value past the strip is named on this row, so the board
                // always shows what the task has now.
                val label = current?.takeIf { isBeyondStrip }
                    ?.let { RegistryCatalog.dateBoardCalendarLabel(formatShort(it, locale), languageTag) }
                    ?: row.label
                BoardRow(label, enabled) { showsCalendar = !showsCalendar }
                if (showsCalendar) MonthCalendar(current, enabled, onSelect)
            }
            DateBoardRowKinds.CLEAR -> BoardRow(row.label, enabled, onClear)
            // A kind with no Android renderer yet: skip.
            else -> Unit
        }
    }
}

@Composable
private fun BoardRow(label: String, enabled: Boolean, onClick: () -> Unit) {
    ListItem(
        headlineContent = { Text(label) },
        modifier = Modifier.fillMaxWidth().clickable(enabled = enabled, role = Role.Button, onClick = onClick),
    )
}

@Composable
private fun DayStrip(
    today: LocalDate,
    current: LocalDate?,
    locale: Locale,
    todayLabel: String,
    enabled: Boolean,
    onSelect: (LocalDate) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        for (offset in 0 until STRIP_DAYS) {
            val day = today.plusDays(offset)
            val isCurrent = day == current
            val ground = when {
                isCurrent -> MaterialTheme.colorScheme.secondaryContainer
                day.dayOfWeek == DayOfWeek.SATURDAY || day.dayOfWeek == DayOfWeek.SUNDAY ->
                    MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
                else -> Color.Transparent
            }
            val description = DateTimeFormatter
                .ofPattern(DateFormat.getBestDateTimePattern(locale, "EEEEMMMd"), locale)
                .format(day)
            Column(
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(10.dp))
                    .background(ground)
                    .clickable(enabled = enabled, role = Role.Button) { onSelect(day) }
                    .semantics {
                        contentDescription = description
                        selected = isCurrent
                    }
                    .padding(vertical = 8.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    if (offset == 0L) todayLabel else day.dayOfWeek.getDisplayName(TextStyle.SHORT, locale),
                    style = MaterialTheme.typography.labelSmall,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.clearAndSetSemantics {},
                )
                Text(
                    day.dayOfMonth.toString(),
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.clearAndSetSemantics {},
                )
            }
        }
    }
}

/** The month calendar, for a day past the strip. A pick of a day commits it. */
@Composable
@OptIn(ExperimentalMaterial3Api::class)
private fun MonthCalendar(current: LocalDate?, enabled: Boolean, onSelect: (String) -> Unit) {
    val initialMillis = remember(current) { current?.atStartOfDay(ZoneOffset.UTC)?.toInstant()?.toEpochMilli() }
    val datePickerState = rememberDatePickerState(initialSelectedDateMillis = initialMillis)
    val selectedMillis = datePickerState.selectedDateMillis
    LaunchedEffect(selectedMillis) {
        if (enabled && selectedMillis != null && selectedMillis != initialMillis) {
            onSelect(Instant.ofEpochMilli(selectedMillis).atZone(ZoneOffset.UTC).toLocalDate().toString())
        }
    }
    DatePicker(
        state = datePickerState,
        title = null,
        showModeToggle = false,
    )
}

private fun formatShort(day: LocalDate, locale: Locale): String =
    DateTimeFormatter.ofPattern(DateFormat.getBestDateTimePattern(locale, "EEEMMMd"), locale).format(day)
