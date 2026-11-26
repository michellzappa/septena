package app.septena.windows

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import app.septena.core.JsonValue
import app.septena.core.RecurrenceRule
import app.septena.core.RecurrenceRules
import app.septena.core.RegistryCatalog
import app.septena.core.TaskMutator
import app.septena.core.TaskRecord
import app.septena.core.booleanValue
import app.septena.core.formatUpcomingDayHeader
import app.septena.core.generated.RegistryActionIds
import app.septena.core.generated.RegistryDestinationIds
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields.Task
import app.septena.core.generated.RegistryPromptIds
import app.septena.core.generated.RegistryTaskDetail
import app.septena.core.stringValue
import app.septena.sharedcore.RescheduleMode
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset

internal sealed interface DesktopTaskEdit {
    data class Text(val title: String, val notes: String) : DesktopTaskEdit
    data class When(val day: LocalDate?, val mode: RescheduleMode) : DesktopTaskEdit
    data class Deadline(val day: LocalDate?) : DesktopTaskEdit
    data class Repeat(val rule: RecurrenceRule?, val paused: Boolean) : DesktopTaskEdit
}

private enum class TaskEditorPanel { Details, When, Deadline, Repeat, Reschedule }

@Composable
internal fun DesktopTaskEditor(
    task: TaskRecord,
    today: LocalDate,
    languageTag: String,
    busy: Boolean,
    error: String?,
    onDismiss: () -> Unit,
    onEdit: (DesktopTaskEdit, () -> Unit) -> Unit,
) {
    var panel by remember(task.id) { mutableStateOf(TaskEditorPanel.Details) }
    var rescheduleDay by remember(task.id) { mutableStateOf<LocalDate?>(null) }
    var title by remember(task.id) { mutableStateOf(task.title) }
    val currentNotes = task.fields[Task.NOTES].stringValue().orEmpty()
    var notes by remember(task.id) { mutableStateOf(currentNotes) }
    val copy = remember(languageTag) { TaskEditorCopy(languageTag) }
    val scheduled = dayFromField(task.fields[Task.SCHEDULED])
    val whenDay = if (task.fields[Task.TODAY].booleanValue() == true) today else scheduled
    val deadline = dayFromField(task.fields[Task.DEADLINE])
    val rule = RecurrenceRules.fromFields(task.fields)
    val paused = task.fields[Task.RECURRENCE_PAUSED].booleanValue() == true
    val canUseFixed = scheduled != null || dayFromField(task.fields[Task.RECURRENCE_ANCHOR_DATE]) != null
    val back = { panel = TaskEditorPanel.Details }
    val done = copy.label("Done")
    val cancel = copy.control(RegistryTaskDetail.Controls.CANCEL)

    when (panel) {
        TaskEditorPanel.Details -> AlertDialog(
            onDismissRequest = { if (!busy) onDismiss() },
            title = { Text(copy.title) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = title,
                        onValueChange = { title = it },
                        singleLine = true,
                        enabled = !busy,
                        label = { Text(copy.field(RegistryTaskDetail.Fields.TITLE)) },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    OutlinedTextField(
                        value = notes,
                        onValueChange = { notes = it },
                        minLines = 3,
                        maxLines = 6,
                        enabled = !busy,
                        label = { Text(copy.field(RegistryTaskDetail.Fields.NOTES)) },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    EditorAttribute(copy.field(RegistryTaskDetail.Fields.WHEN), copy.dayLabel(whenDay, today), !busy) {
                        panel = TaskEditorPanel.When
                    }
                    EditorAttribute(copy.field(RegistryTaskDetail.Fields.DEADLINE), copy.dayLabel(deadline, today), !busy) {
                        panel = TaskEditorPanel.Deadline
                    }
                    val repeatLabel = rule?.let { "${it.interval} ${copy.units[it.unit].orEmpty()}" }.orEmpty()
                    EditorAttribute(copy.field(RegistryTaskDetail.Fields.REPEAT), repeatLabel, !busy) {
                        panel = TaskEditorPanel.Repeat
                    }
                    EditorError(error)
                }
            },
            confirmButton = {
                val changed = title.trim() != task.title || notes != currentNotes
                Button(enabled = !busy && title.isNotBlank(), onClick = {
                    if (changed) onEdit(DesktopTaskEdit.Text(title, notes), onDismiss) else onDismiss()
                }) { Text(if (changed) copy.label("Save") else done) }
            },
            dismissButton = { TextButton(enabled = !busy, onClick = onDismiss) { Text(cancel) } },
        )
        TaskEditorPanel.When, TaskEditorPanel.Deadline -> {
            val editingWhen = panel == TaskEditorPanel.When
            DateEditor(
                title = copy.field(if (editingWhen) RegistryTaskDetail.Fields.WHEN else RegistryTaskDetail.Fields.DEADLINE),
                initialDay = if (editingWhen) whenDay else deadline,
                today = today,
                copy = copy,
                enabled = !busy,
                error = error,
                onBack = back,
            ) { day ->
                if (!editingWhen) {
                    onEdit(DesktopTaskEdit.Deadline(day), back)
                } else if (TaskMutator.needsFixedRepeatReschedulePrompt(task.fields, day?.toString())) {
                    rescheduleDay = day
                    panel = TaskEditorPanel.Reschedule
                } else {
                    onEdit(DesktopTaskEdit.When(day, RescheduleMode.MAKE_EXCEPTION), back)
                }
            }
        }
        TaskEditorPanel.Repeat -> RepeatEditor(rule, paused, canUseFixed, copy, !busy, error, back) { edit ->
            onEdit(edit, back)
        }
        TaskEditorPanel.Reschedule -> {
            val prompt = RegistryCatalog.surface(RegistryPromptIds.RESCHEDULE_FIXED_REPEAT)
            val options = (prompt?.get("options") as? JsonValue.ArrayValue)?.values.orEmpty()
                .mapNotNull { it as? JsonValue.ObjectValue }
                .associate { it["id"].stringValue().orEmpty() to copy.label(it["title"].stringValue().orEmpty()) }
            AlertDialog(
                onDismissRequest = { if (!busy) back() },
                title = { Text(copy.label(prompt?.get("title").stringValue().orEmpty())) },
                text = {
                    Column {
                        Text(copy.label(prompt?.get("message").stringValue().orEmpty()))
                        EditorError(error)
                    }
                },
                confirmButton = {
                    Button(enabled = !busy, onClick = {
                        onEdit(DesktopTaskEdit.When(rescheduleDay, RescheduleMode.UPDATE_RULE), back)
                    }) { Text(options["updateRule"].orEmpty()) }
                },
                dismissButton = {
                    Row {
                        TextButton(enabled = !busy, onClick = back) { Text(cancel) }
                        TextButton(enabled = !busy, onClick = {
                            onEdit(DesktopTaskEdit.When(rescheduleDay, RescheduleMode.MAKE_EXCEPTION), back)
                        }) { Text(options["exception"].orEmpty()) }
                    }
                },
            )
        }
    }
}

@Composable
private fun EditorAttribute(label: String, value: String, enabled: Boolean, onClick: () -> Unit) {
    OutlinedButton(enabled = enabled, onClick = onClick, modifier = Modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(label)
            if (value.isNotEmpty()) Text(value)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DateEditor(
    title: String,
    initialDay: LocalDate?,
    today: LocalDate,
    copy: TaskEditorCopy,
    enabled: Boolean,
    error: String?,
    onBack: () -> Unit,
    onPick: (LocalDate?) -> Unit,
) {
    val displayed = initialDay ?: today
    val state = rememberDatePickerState(
        initialSelectedDateMillis = initialDay?.atStartOfDay(ZoneOffset.UTC)?.toInstant()?.toEpochMilli(),
        initialDisplayedMonthMillis = displayed.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli(),
        yearRange = minOf(1900, displayed.year)..maxOf(2100, displayed.year),
    )
    DatePickerDialog(
        onDismissRequest = { if (enabled) onBack() },
        confirmButton = {
            val selection = state.selectedDateMillis
            TextButton(enabled = enabled && selection != null, onClick = {
                selection?.let { onPick(Instant.ofEpochMilli(it).atZone(ZoneOffset.UTC).toLocalDate()) }
            }) { Text(copy.control(RegistryTaskDetail.Controls.SELECT_DATE)) }
        },
        dismissButton = {
            TextButton(enabled = enabled, onClick = onBack) { Text(copy.control(RegistryTaskDetail.Controls.CANCEL)) }
        },
    ) {
        Text(title, modifier = Modifier.padding(start = 24.dp, top = 12.dp), style = MaterialTheme.typography.titleMedium)
        DatePicker(state = state, title = null)
        Row(Modifier.padding(horizontal = 12.dp)) {
            TextButton(enabled = enabled, onClick = { onPick(today) }) { Text(copy.todayTitle) }
            TextButton(enabled = enabled, onClick = { onPick(today.plusDays(1)) }) { Text(copy.tomorrowTitle) }
            TextButton(enabled = enabled && initialDay != null, onClick = { onPick(null) }) {
                Text(copy.control(RegistryTaskDetail.Controls.NO_DATE))
            }
        }
        EditorError(error)
    }
}

@Composable
private fun RepeatEditor(
    original: RecurrenceRule?,
    originallyPaused: Boolean,
    canUseFixed: Boolean,
    copy: TaskEditorCopy,
    enabled: Boolean,
    error: String?,
    onBack: () -> Unit,
    onSave: (DesktopTaskEdit.Repeat) -> Unit,
) {
    val base = original ?: RecurrenceRule(RegistryEntityEnums.RecurrenceUnit.WEEK)
    var unit by remember { mutableStateOf(base.unit) }
    var interval by remember { mutableStateOf(base.interval.toString()) }
    var afterCompletion by remember { mutableStateOf(base.afterCompletion) }
    var paused by remember { mutableStateOf(originallyPaused) }
    var menuOpen by remember { mutableStateOf(false) }
    val intervalValue = interval.toIntOrNull()?.takeIf { it in 1..99 }
    AlertDialog(
        onDismissRequest = { if (enabled) onBack() },
        title = { Text(copy.field(RegistryTaskDetail.Fields.REPEAT)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(
                        value = interval,
                        onValueChange = { interval = it.filter(Char::isDigit).take(2) },
                        label = { Text(copy.field(RegistryTaskDetail.Fields.INTERVAL)) },
                        modifier = Modifier.weight(1f),
                        singleLine = true,
                        enabled = enabled,
                    )
                    Column {
                        OutlinedButton(enabled = enabled, onClick = { menuOpen = true }) { Text(copy.units[unit].orEmpty()) }
                        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                            for ((value, label) in copy.units) {
                                DropdownMenuItem(text = { Text(label) }, onClick = {
                                    unit = value
                                    menuOpen = false
                                })
                            }
                        }
                    }
                }
                EditorToggle(copy.field(RegistryTaskDetail.Fields.AFTER_COMPLETION), afterCompletion, enabled) {
                    afterCompletion = it
                }
                if (!afterCompletion && !canUseFixed) Text(copy.control(RegistryTaskDetail.Controls.NO_SCHEDULE_FOR_FIXED))
                EditorToggle(copy.action(RegistryActionIds.TASK_PAUSE_RESUME_REPEAT), paused, enabled) { paused = it }
                if (original != null) {
                    TextButton(enabled = enabled, onClick = { onSave(DesktopTaskEdit.Repeat(null, false)) }) {
                        Text(copy.label("Remove"))
                    }
                }
                EditorError(error)
            }
        },
        confirmButton = {
            Button(enabled = enabled && intervalValue != null && (afterCompletion || canUseFixed), onClick = {
                if (intervalValue != null) onSave(
                    DesktopTaskEdit.Repeat(base.copy(unit = unit, interval = intervalValue, afterCompletion = afterCompletion), paused),
                )
            }) { Text(copy.label("Save")) }
        },
        dismissButton = {
            TextButton(enabled = enabled, onClick = onBack) { Text(copy.control(RegistryTaskDetail.Controls.CANCEL)) }
        },
    )
}

@Composable
private fun EditorToggle(label: String, value: Boolean, enabled: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().toggleable(value, enabled = enabled, role = Role.Checkbox, onValueChange = onChange),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Checkbox(checked = value, enabled = enabled, onCheckedChange = null, modifier = Modifier.padding(8.dp))
        Text(label)
    }
}

@Composable
private fun EditorError(error: String?) {
    error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
}

private class TaskEditorCopy(private val languageTag: String) {
    private val surface = RegistryCatalog.surface(RegistryTaskDetail.ID)
    val title = label(surface?.get("title").stringValue().orEmpty())
    val todayTitle = RegistryCatalog.destinationTitle(RegistryDestinationIds.TODAY, languageTag).orEmpty()
    val tomorrowTitle = RegistryCatalog.tomorrowLabel(languageTag)
    val units = (surface?.get("repeatUnits") as? JsonValue.ArrayValue)?.values.orEmpty()
        .mapNotNull { it as? JsonValue.ObjectValue }
        .associate { it["value"].stringValue().orEmpty() to label(it["title"].stringValue().orEmpty()) }

    fun field(id: String): String = nested("fields", id)
    fun control(id: String): String = nested("controls", id)
    fun action(id: String): String = RegistryCatalog.actionTitle(id, languageTag = languageTag).orEmpty()
    fun label(value: String): String = RegistryCatalog.localizedString(value, languageTag) ?: value
    fun dayLabel(day: LocalDate?, today: LocalDate): String =
        day?.let { formatUpcomingDayHeader(it, today, languageTag) } ?: control(RegistryTaskDetail.Controls.NO_DATE)

    private fun nested(key: String, id: String): String =
        label((surface?.get(key) as? JsonValue.ObjectValue)?.get(id).stringValue().orEmpty())
}

private fun dayFromField(field: JsonValue?): LocalDate? =
    field.stringValue()?.let { runCatching { LocalDate.parse(it.take(10)) }.getOrNull() }
