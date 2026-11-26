package app.septena.android.ui

import android.text.format.DateFormat
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DatePicker
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberTimePickerState
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.septena.core.DateBoardGroups
import app.septena.core.DateBoardRowKinds
import app.septena.core.RegistryCatalog
import app.septena.core.TaskTimeSlot
import app.septena.core.generated.RegistryDestinationIds
import app.septena.core.generated.RegistryTaskDetail
import app.septena.ui.CalendarSmallGlyph
import app.septena.ui.ClockSmallGlyph
import app.septena.ui.CloseSmallGlyph
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
 * The date board, embedded in its attribute row or sheet: a seven-day strip
 * starting today, then the registry's rows in three groups with a divider
 * between them: pick (the strip, Pick another date), refine (on When: Add time /
 * inline start-time + duration controls) and remove (Clear). Every date
 * pick commits and folds the row through the caller; time-slot edits apply live
 * without closing the board (matching iOS `DatePickerSheet`).
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
    startTime: String? = null,
    durationMinutes: Int? = null,
    onTimeSlotChange: ((String?, Int?) -> Unit)? = null,
) {
    val current = remember(initialDay) { initialDay?.let { runCatching { LocalDate.parse(it.take(10)) }.getOrNull() } }
    // Repeat is its own attribute row on the task page, and Add time needs a
    // time handler. The filter runs before the dividers, so an empty group
    // draws none.
    val rows = remember(attribute, languageTag, onTimeSlotChange != null) {
        RegistryCatalog.dateBoardRows(attribute, languageTag = languageTag).filter { row ->
            when (row.kind) {
                DateBoardRowKinds.REPEAT_RULE -> false
                DateBoardRowKinds.TIME -> onTimeSlotChange != null
                else -> true
            }
        }
    }
    val locale = Locale.forLanguageTag(languageTag)
    val isBeyondStrip = current != null && (current < today || current >= today.plusDays(STRIP_DAYS))
    var showsCalendar by remember { mutableStateOf(false) }
    var showTimeControls by remember(startTime) { mutableStateOf(startTime != null) }
    var timePickerOpen by remember { mutableStateOf(false) }
    val dividerColor = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.35f)
    val mutedInk = MaterialTheme.colorScheme.onSurfaceVariant

    DayStrip(
        today = today,
        current = current,
        locale = locale,
        todayLabel = RegistryCatalog.destinationTitle(RegistryDestinationIds.TODAY, languageTag).orEmpty(),
        enabled = enabled,
        onSelect = { onSelect(it.toString()) },
    )
    // The strip opens the first group; a divider goes where the group changes.
    var previousGroup = DateBoardGroups.PICK
    rows.forEach { row ->
        if (row.group != previousGroup) {
            HorizontalDivider(
                modifier = Modifier.padding(horizontal = 14.dp, vertical = 4.dp),
                thickness = 0.5.dp,
                color = dividerColor,
            )
            previousGroup = row.group
        }
        when (row.kind) {
            DateBoardRowKinds.CALENDAR -> {
                // A value past the strip is named on this row, so the board
                // always shows what the task has now.
                val label = current?.takeIf { isBeyondStrip }
                    ?.let { RegistryCatalog.dateBoardCalendarLabel(formatShort(it, locale), languageTag) }
                    ?: row.label
                BoardRow(
                    label = label,
                    enabled = enabled,
                    icon = { CalendarSmallGlyph(tint = mutedInk, size = 15.dp) },
                    onClick = { showsCalendar = !showsCalendar },
                )
                if (showsCalendar) MonthCalendar(current, enabled, onSelect)
            }
            DateBoardRowKinds.TIME -> if (onTimeSlotChange != null) {
                val timeControlsOpen = showTimeControls || startTime != null
                if (!timeControlsOpen) {
                    BoardRow(
                        label = row.label,
                        enabled = enabled,
                        icon = { ClockSmallGlyph(tint = mutedInk, size = 15.dp) },
                        onClick = {
                            showTimeControls = true
                            onTimeSlotChange(TaskTimeSlot.DEFAULT_START_TIME, durationMinutes)
                        },
                    )
                } else {
                    TimeSlotControls(
                        startTime = startTime ?: TaskTimeSlot.DEFAULT_START_TIME,
                        durationMinutes = durationMinutes,
                        languageTag = languageTag,
                        enabled = enabled,
                        onOpenTimePicker = { timePickerOpen = true },
                        onSelectDuration = { presetMinutes ->
                            val next = if (durationMinutes == presetMinutes) null else presetMinutes
                            onTimeSlotChange(startTime ?: TaskTimeSlot.DEFAULT_START_TIME, next)
                        },
                        onClearTime = {
                            showTimeControls = false
                            onTimeSlotChange(null, null)
                        },
                    )
                }
            }
            DateBoardRowKinds.CLEAR -> BoardRow(
                label = row.label,
                enabled = enabled,
                icon = { CloseSmallGlyph(tint = mutedInk, size = 14.dp) },
                onClick = onClear,
            )
            else -> Unit
        }
    }

    if (timePickerOpen && onTimeSlotChange != null) {
        TimeSlotPickerDialog(
            initialTime = startTime ?: TaskTimeSlot.DEFAULT_START_TIME,
            languageTag = languageTag,
            onDismiss = { timePickerOpen = false },
            onConfirm = { picked ->
                timePickerOpen = false
                onTimeSlotChange(picked, durationMinutes)
            },
        )
    }
}

@Composable
private fun BoardRow(
    label: String,
    enabled: Boolean,
    icon: @Composable () -> Unit,
    onClick: () -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 10.dp),
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier.width(22.dp),
        ) {
            icon()
        }
        Spacer(modifier = Modifier.width(10.dp))
        Text(
            text = label,
            fontSize = 15.sp,
            lineHeight = 20.sp,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun TimeSlotControls(
    startTime: String,
    durationMinutes: Int?,
    languageTag: String,
    enabled: Boolean,
    onOpenTimePicker: () -> Unit,
    onSelectDuration: (Int) -> Unit,
    onClearTime: () -> Unit,
) {
    val accent = MaterialTheme.colorScheme.primary
    val mutedInk = MaterialTheme.colorScheme.onSurfaceVariant
    val timeLabel = remember(languageTag) { RegistryCatalog.localizedString("Time", languageTag) ?: "Time" }
    val clearLabel = remember(languageTag) { RegistryCatalog.localizedString("Clear", languageTag) ?: "Clear" }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 14.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier.width(22.dp),
            ) {
                ClockSmallGlyph(tint = accent, size = 15.dp)
            }
            Spacer(modifier = Modifier.width(10.dp))
            Text(
                text = timeLabel,
                fontSize = 15.sp,
                lineHeight = 20.sp,
                color = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.weight(1f),
            )
            Box(
                modifier = Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .background(accent.copy(alpha = 0.14f))
                    .clickable(enabled = enabled, role = Role.Button, onClick = onOpenTimePicker)
                    .padding(horizontal = 10.dp, vertical = 5.dp),
            ) {
                Text(
                    text = TaskTimeSlot.format(startTime, durationMinutes) ?: startTime,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = accent,
                )
            }
            Spacer(modifier = Modifier.width(10.dp))
            Text(
                text = clearLabel,
                fontSize = 13.sp,
                color = mutedInk,
                modifier = Modifier
                    .clip(RoundedCornerShape(6.dp))
                    .clickable(enabled = enabled, role = Role.Button, onClick = onClearTime)
                    .padding(horizontal = 6.dp, vertical = 4.dp),
            )
        }

        Row(
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 32.dp),
        ) {
            TaskTimeSlot.quickDurations.forEach { preset ->
                val isSelected = durationMinutes == preset.minutes
                Box(
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(
                            if (isSelected) accent.copy(alpha = 0.16f) else Color.Transparent,
                        )
                        .border(
                            width = 0.75.dp,
                            color = if (isSelected) accent.copy(alpha = 0.50f) else mutedInk.copy(alpha = 0.30f),
                            shape = CircleShape,
                        )
                        .clickable(enabled = enabled, role = Role.Button) { onSelectDuration(preset.minutes) }
                        .padding(horizontal = 11.dp, vertical = 4.dp),
                ) {
                    Text(
                        text = preset.label,
                        fontSize = 12.5.sp,
                        fontWeight = if (isSelected) FontWeight.SemiBold else FontWeight.Normal,
                        color = if (isSelected) accent else mutedInk,
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TimeSlotPickerDialog(
    initialTime: String,
    languageTag: String,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    val context = LocalContext.current
    val (initialHour, initialMinute) = remember(initialTime) { TaskTimeSlot.parse(initialTime) ?: (9 to 0) }
    val state = rememberTimePickerState(
        initialHour = initialHour,
        initialMinute = initialMinute,
        is24Hour = DateFormat.is24HourFormat(context),
    )
    val cancelLabel = remember(languageTag) {
        RegistryCatalog.localizedString("Cancel", languageTag) ?: "Cancel"
    }
    val doneLabel = remember(languageTag) {
        val surface = RegistryCatalog.surface(RegistryTaskDetail.ID)
        val raw = (surface?.fields?.get("controls") as? app.septena.core.JsonValue.ObjectValue)
            ?.fields?.get(RegistryTaskDetail.Controls.REMINDER_SET)
            ?.let { (it as? app.septena.core.JsonValue.StringValue)?.value }
        raw?.let { RegistryCatalog.localizedString(it, languageTag) ?: it } ?: "Set"
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(onClick = { onConfirm(TaskTimeSlot.hhmm(state.hour, state.minute)) }) {
                Text(doneLabel)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(cancelLabel)
            }
        },
        text = {
            TimePicker(state = state)
        },
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
    val accent = MaterialTheme.colorScheme.primary
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        for (offset in 0 until STRIP_DAYS) {
            val day = today.plusDays(offset)
            val isCurrent = day == current
            val ground = when {
                isCurrent -> accent.copy(alpha = 0.16f)
                day.dayOfWeek == DayOfWeek.SATURDAY || day.dayOfWeek == DayOfWeek.SUNDAY ->
                    MaterialTheme.colorScheme.onSurface.copy(alpha = 0.045f)
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
                    text = if (offset == 0L) todayLabel else day.dayOfWeek.getDisplayName(TextStyle.SHORT, locale),
                    style = MaterialTheme.typography.labelSmall,
                    color = if (isCurrent) accent else MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.clearAndSetSemantics {},
                )
                Text(
                    text = day.dayOfMonth.toString(),
                    style = MaterialTheme.typography.titleMedium.copy(
                        fontWeight = if (isCurrent) FontWeight.SemiBold else FontWeight.Normal,
                    ),
                    color = if (isCurrent) accent else MaterialTheme.colorScheme.onSurface,
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
