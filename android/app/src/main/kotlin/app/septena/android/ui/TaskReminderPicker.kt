package app.septena.android.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.text.format.DateFormat
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.DatePicker
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimeInput
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import app.septena.android.AndroidAppGraph
import app.septena.android.reminders.ReminderTime
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryTaskDetail
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.temporal.ChronoUnit
import java.util.Locale

/**
 * The Reminder picker of the task page (#362), Android's form of Apple's
 * `ReminderPickerSheet`: quick presets, a date and a time, the fixed time zone
 * option and Clear. It folds open in the Reminder row like every other
 * attribute picker. The first saved reminder asks for the notification
 * permission (Android 13 and later), never app launch.
 */
@Composable
@OptIn(ExperimentalMaterial3Api::class)
internal fun TaskReminderPicker(
    graph: AndroidAppGraph,
    reminderAt: String?,
    reminderMode: String?,
    enabled: Boolean,
    control: (String) -> String,
    onSet: (reminderAt: String, mode: String) -> Unit,
    onClear: () -> Unit,
) {
    val context = LocalContext.current
    val zone = ZoneId.systemDefault()
    var notificationsOn by remember { mutableStateOf(graph.reminders.notificationsEnabled()) }
    var exactOn by remember { mutableStateOf(graph.reminders.canScheduleExact()) }
    // Back from system Settings: read both switches again.
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        notificationsOn = graph.reminders.notificationsEnabled()
        exactOn = graph.reminders.canScheduleExact()
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        notificationsOn = graph.reminders.notificationsEnabled()
    }

    val now = LocalDateTime.ofInstant(graph.clock.now(), zone).truncatedTo(ChronoUnit.MINUTES)
    val presets = reminderPresets(now).map { (id, at) -> control(id) to at }
    val current = reminderAt?.let { ReminderTime.resolve(it, reminderMode, zone) }
        ?.let { LocalDateTime.ofInstant(it, zone) }
    val initial = current ?: presets.firstOrNull()?.second ?: now.plusHours(1)
    var fixed by remember(reminderAt) { mutableStateOf(reminderMode == RegistryEntityEnums.ReminderMode.FIXED) }
    val dateState = rememberDatePickerState(
        initialSelectedDateMillis = initial.toLocalDate().atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli(),
    )
    val timeState = rememberTimePickerState(
        initialHour = initial.hour,
        initialMinute = initial.minute,
        is24Hour = DateFormat.is24HourFormat(context),
    )

    fun commit(at: LocalDateTime) {
        val mode = if (fixed) RegistryEntityEnums.ReminderMode.FIXED else RegistryEntityEnums.ReminderMode.FLOATING
        onSet(ReminderTime.wireValue(at, mode, zone), mode)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            permission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (reminderAt != null && !notificationsOn) {
            SettingsLink(control(RegistryTaskDetail.Controls.REMINDER_NOTIFICATIONS_OFF)) {
                context.startActivity(
                    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                        .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName),
                )
            }
        } else if (reminderAt != null && !exactOn && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            SettingsLink(control(RegistryTaskDetail.Controls.REMINDER_EXACT_ALARMS_OFF)) {
                context.startActivity(
                    Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:${context.packageName}")),
                )
            }
        }

        Row(
            modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            presets.forEach { (title, at) ->
                FilterChip(selected = false, onClick = { commit(at) }, label = { Text(title) }, enabled = enabled)
            }
        }

        Text(control(RegistryTaskDetail.Controls.REMINDER_REMIND_AT), style = MaterialTheme.typography.titleSmall)
        DatePicker(state = dateState, showModeToggle = false, title = null, headline = null)
        TimeInput(state = timeState)
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(control(RegistryTaskDetail.Controls.REMINDER_FIXED_TIME_ZONE))
            Switch(checked = fixed, onCheckedChange = { fixed = it }, enabled = enabled)
        }
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            if (reminderAt != null) {
                TextButton(onClick = onClear, enabled = enabled) {
                    Text(control(RegistryTaskDetail.Controls.REMINDER_CLEAR))
                }
            }
            TextButton(
                onClick = {
                    val day = dateState.selectedDateMillis
                        ?.let { Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate() }
                        ?: initial.toLocalDate()
                    commit(LocalDateTime.of(day, LocalTime.of(timeState.hour, timeState.minute)))
                },
                enabled = enabled,
            ) { Text(control(RegistryTaskDetail.Controls.REMINDER_SET)) }
        }
    }
}

@Composable
private fun SettingsLink(text: String, onClick: () -> Unit) {
    Text(
        text,
        color = MaterialTheme.colorScheme.error,
        style = MaterialTheme.typography.bodyMedium,
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 8.dp),
    )
}

/** Apple's quick presets: in 1 hour, tonight 18:00 (while 15 minutes or more away), tomorrow 09:00. */
private fun reminderPresets(now: LocalDateTime): List<Pair<String, LocalDateTime>> = buildList {
    add(RegistryTaskDetail.Controls.REMINDER_IN_ONE_HOUR to now.plusHours(1))
    val tonight = now.toLocalDate().atTime(18, 0)
    if (tonight.isAfter(now.plusMinutes(15))) add(RegistryTaskDetail.Controls.REMINDER_TONIGHT to tonight)
    add(RegistryTaskDetail.Controls.REMINDER_TOMORROW to now.toLocalDate().plusDays(1).atTime(9, 0))
}

/** The Reminder row's value: when the reminder fires next (a snooze wins), in the device zone. */
internal fun formatReminder(
    reminderAt: String,
    reminderMode: String?,
    snoozedUntil: String?,
    today: LocalDate,
    languageTag: String,
): String {
    val zone = ZoneId.systemDefault()
    val fire = snoozedUntil?.let { runCatching { Instant.parse(it) }.getOrNull() }
        ?: ReminderTime.resolve(reminderAt, reminderMode, zone)
        ?: return reminderAt
    val local = fire.atZone(zone)
    val locale = Locale.forLanguageTag(languageTag)
    return if (local.toLocalDate() == today) {
        DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withLocale(locale).format(local)
    } else {
        DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT).withLocale(locale).format(local)
    }
}
