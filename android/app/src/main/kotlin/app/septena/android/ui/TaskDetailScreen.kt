package app.septena.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.septena.android.AndroidAppGraph
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.SyncRecord
import app.septena.core.WireTimestamp
import app.septena.core.booleanValue
import app.septena.core.generated.RegistryActionIds
import app.septena.core.generated.RegistryDestinationIds
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityLimits
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.generated.RegistryEntities
import app.septena.core.generated.RegistryTaskDetail
import app.septena.core.stringValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

private data class DetailListItem(
    val id: String,
    val title: String,
    val parentAreaId: String? = null,
)

private data class ChecklistLine(
    val id: String,
    val title: String,
    val checked: Boolean,
    val position: Double,
)

private data class TaskDetailData(
    val task: SyncRecord,
    val areas: List<DetailListItem>,
    val projects: List<DetailListItem>,
    val checklist: List<ChecklistLine>,
)

private data class RepeatUnitOption(val value: String, val title: String)
private data class RepeatChoice(val value: Int, val title: String, val shortTitle: String? = null)

private val CHECKLIST_TITLE_MAX_LENGTH = RegistryEntities.all
    .getValue(RegistryEntityNames.CHECKLIST_ITEM)
    .columns
    .getValue(RegistryEntityFields.ChecklistItem.TITLE)
    .max ?: RegistryEntityLimits.TEXT_MAX

/** Standalone task-detail surface. The shell owns routing and supplies [onBack]. */
@Composable
@OptIn(ExperimentalMaterial3Api::class)
fun TaskDetailScreen(
    graph: AndroidAppGraph,
    taskId: String,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val languageTag = LocalConfiguration.current.locales[0].toLanguageTag()
    val labels = remember(languageTag) { TaskDetailLabels.fromRegistry(languageTag) }
    val dataVersion by graph.sync.dataVersion.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val checklistDrafts = remember(taskId) { mutableStateMapOf<String, String>() }
    var focusedChecklistId by remember(taskId) { mutableStateOf<String?>(null) }

    var data by remember(taskId) { mutableStateOf<TaskDetailData?>(null) }
    var hasLoaded by remember(taskId) { mutableStateOf(false) }
    var titleDraft by remember(taskId) { mutableStateOf("") }
    var notesDraft by remember(taskId) { mutableStateOf("") }
    var textIsDirty by remember(taskId) { mutableStateOf(false) }
    var saving by remember(taskId) { mutableStateOf(false) }
    var saveFailed by remember(taskId) { mutableStateOf(false) }
    var showWhenPicker by remember(taskId) { mutableStateOf(false) }
    var showDeadlinePicker by remember(taskId) { mutableStateOf(false) }

    LaunchedEffect(graph, taskId, dataVersion) {
        val loaded = withContext(Dispatchers.IO) { loadTaskDetail(graph, taskId) }
        data = loaded
        hasLoaded = true
        if (loaded != null && !textIsDirty) {
            titleDraft = loaded.task.fields[RegistryEntityFields.Task.TITLE].stringValue().orEmpty()
            notesDraft = loaded.task.fields[RegistryEntityFields.Task.NOTES].stringValue().orEmpty()
        }
        if (loaded != null) {
            loaded.checklist.forEach { item ->
                if (item.id != focusedChecklistId) checklistDrafts[item.id] = item.title
            }
            checklistDrafts.keys.retainAll(loaded.checklist.map(ChecklistLine::id).toSet())
        }
    }

    suspend fun saveTextFields(): Boolean {
        val current = data ?: return false
        if (current.task.deletedAt != null) {
            textIsDirty = false
            return true
        }
        val title = titleDraft.trim()
        if (title.isEmpty()) {
            saveFailed = true
            return false
        }
        val currentTitle = current.task.fields[RegistryEntityFields.Task.TITLE].stringValue().orEmpty()
        val currentNotes = current.task.fields[RegistryEntityFields.Task.NOTES].stringValue().orEmpty()
        val notes = notesDraft.trim()
        val titleChanged = title != currentTitle
        val notesChanged = notes != currentNotes
        if (!titleChanged && !notesChanged) {
            textIsDirty = false
            saveFailed = false
            return true
        }
        val changes = buildMap<String, JsonValue> {
            if (titleChanged) put(RegistryEntityFields.Task.TITLE, JsonValue.StringValue(title))
            if (notesChanged) put(RegistryEntityFields.Task.NOTES, JsonValue.stringOrNull(notes.ifEmpty { null }))
        }
        withContext(Dispatchers.IO) {
            graph.captureTaskEdit(taskId) {
                check(graph.taskMutator.updateFields(taskId, changes) != null)
            }
        }
        textIsDirty = false
        saveFailed = false
        graph.sync.noteLocalChange()
        graph.sync.requestSync()
        return true
    }

    fun saveAndLeave() {
        if (saving) return
        scope.launch {
            saving = true
            val saved = runCatching { saveTextFields() }.getOrElse { false }
            saving = false
            if (saved) onBack() else saveFailed = true
        }
    }

    fun handleBack() {
        if (data == null) onBack() else saveAndLeave()
    }

    BackHandler(enabled = true, onBack = ::handleBack)

    val taskFields = data?.task?.fields.orEmpty()
    val deleted = data?.task?.deletedAt != null
    val scheduled = taskFields[RegistryEntityFields.Task.SCHEDULED].stringValue()
    val isToday = taskFields[RegistryEntityFields.Task.TODAY].booleanValue() == true
    val whenValue = when {
        isToday -> RegistryCatalog.destinationTitle(RegistryDestinationIds.TODAY, languageTag).orEmpty()
        scheduled != null -> formatDay(scheduled, languageTag)
        else -> labels.noDate
    }
    val deadline = taskFields[RegistryEntityFields.Task.DEADLINE].stringValue()
    val repeatUnit = taskFields[RegistryEntityFields.Task.RECURRENCE_UNIT].stringValue()
    val repeatInterval = taskFields[RegistryEntityFields.Task.RECURRENCE_INTERVAL].longValue() ?: 1L
    val repeatAfterCompletion = repeatUnit == null ||
        (taskFields[RegistryEntityFields.Task.RECURRENCE_AFTER_COMPLETION].booleanValue() ?: true)
    val recurrencePaused = taskFields[RegistryEntityFields.Task.RECURRENCE_PAUSED].booleanValue() == true
    val recurrenceWeekdays = ((taskFields[RegistryEntityFields.Task.RECURRENCE_WEEKDAYS] as? JsonValue.ArrayValue)
        ?.values.orEmpty()).mapNotNull { it.longValue()?.toInt() }.toSet()
    val recurrenceMonthDay = taskFields[RegistryEntityFields.Task.RECURRENCE_MONTH_DAY].longValue()?.toInt()
    val recurrenceOrdinal = (taskFields[RegistryEntityFields.Task.RECURRENCE_ORDINAL_WEEKDAY] as? JsonValue.ObjectValue)
        ?.let { fields ->
            val ordinal = fields.fields["ordinal"].longValue()?.toInt() ?: return@let null
            val weekday = fields.fields["weekday"].longValue()?.toInt() ?: return@let null
            ordinal to weekday
        }
    val selectedProjectId = taskFields[RegistryEntityFields.Task.PROJECT].stringValue()
    val selectedProject = data?.projects?.firstOrNull { it.id == selectedProjectId }
    val selectedAreaId = taskFields[RegistryEntityFields.Task.AREA].stringValue()
        ?: selectedProject?.parentAreaId
    val selectedArea = data?.areas?.firstOrNull { it.id == selectedAreaId }
    val saveAction = RegistryCatalog.actionTitle(RegistryActionIds.TASK_DETAIL_SAVE, languageTag = languageTag).orEmpty()
    val repeatPauseAction = RegistryCatalog.actionTitle(
        RegistryActionIds.TASK_PAUSE_RESUME_REPEAT,
        field = if (recurrencePaused) "activeTitle" else "title",
        languageTag = languageTag,
    ).orEmpty()
    val addChecklistAction = RegistryCatalog.actionTitle(
        RegistryActionIds.TASK_ADD_CHECKLIST_ITEM,
        languageTag = languageTag,
    ).orEmpty()
    val toggleChecklistAction = RegistryCatalog.actionTitle(
        RegistryActionIds.TASK_TOGGLE_CHECKLIST_ITEM,
        languageTag = languageTag,
    ).orEmpty()
    val deleteChecklistAction = RegistryCatalog.actionTitle(
        RegistryActionIds.TASK_DELETE_CHECKLIST_ITEM,
        languageTag = languageTag,
    ).orEmpty()
    val savedTask = data?.task
    val canEdit = savedTask != null && !deleted && !saving

    fun write(block: suspend () -> Unit) {
        if (!canEdit) return
        scope.launch {
            saving = true
            saveFailed = false
            runCatching {
                withContext(Dispatchers.IO) {
                    graph.captureTaskEdit(taskId, block)
                }
            }.onSuccess {
                graph.sync.noteLocalChange()
                graph.sync.requestSync()
            }.onFailure {
                saveFailed = true
            }
            saving = false
        }
    }

    fun setWhen(day: String?) {
        write { check(graph.taskMutator.setWhen(taskId, day) != null) }
    }

    fun setRepeat(
        unit: String?,
        interval: Long = repeatInterval,
        afterCompletion: Boolean = repeatAfterCompletion,
        weekdays: Set<Int> = recurrenceWeekdays,
        monthDay: Int? = recurrenceMonthDay,
        ordinalWeekday: Pair<Int, Int>? = recurrenceOrdinal,
    ) {
        val existing = savedTask ?: return
        val currentScheduled = existing.fields[RegistryEntityFields.Task.SCHEDULED].stringValue()
        val changes = if (unit == null) {
            linkedMapOf(
                RegistryEntityFields.Task.RECURRENCE_UNIT to JsonValue.Null,
                RegistryEntityFields.Task.RECURRENCE_INTERVAL to JsonValue.Null,
                RegistryEntityFields.Task.RECURRENCE_AFTER_COMPLETION to JsonValue.BooleanValue(false),
                RegistryEntityFields.Task.RECURRENCE_PAUSED to JsonValue.BooleanValue(false),
                RegistryEntityFields.Task.RECURRENCE_SERIES_ID to JsonValue.Null,
                RegistryEntityFields.Task.RECURRENCE_ANCHOR_DATE to JsonValue.Null,
                RegistryEntityFields.Task.RECURRENCE_WEEKDAYS to JsonValue.Null,
                RegistryEntityFields.Task.RECURRENCE_MONTH_DAY to JsonValue.Null,
                RegistryEntityFields.Task.RECURRENCE_ORDINAL_WEEKDAY to JsonValue.Null,
            )
        } else {
            val fixed = !afterCompletion
            val usesWeekdays = fixed && unit == RegistryEntityEnums.RecurrenceUnit.WEEK
            val usesMonthRules = fixed && (unit == RegistryEntityEnums.RecurrenceUnit.MONTH || unit == RegistryEntityEnums.RecurrenceUnit.YEAR)
            linkedMapOf(
                RegistryEntityFields.Task.RECURRENCE_UNIT to JsonValue.StringValue(unit),
                RegistryEntityFields.Task.RECURRENCE_INTERVAL to JsonValue.IntegerValue(interval.coerceIn(1L, 99L)),
                RegistryEntityFields.Task.RECURRENCE_AFTER_COMPLETION to JsonValue.BooleanValue(afterCompletion),
                RegistryEntityFields.Task.RECURRENCE_PAUSED to JsonValue.BooleanValue(
                    existing.fields[RegistryEntityFields.Task.RECURRENCE_PAUSED].booleanValue() ?: false,
                ),
                RegistryEntityFields.Task.RECURRENCE_SERIES_ID to JsonValue.StringValue(
                    existing.fields[RegistryEntityFields.Task.RECURRENCE_SERIES_ID].stringValue() ?: taskId,
                ),
                RegistryEntityFields.Task.RECURRENCE_ANCHOR_DATE to JsonValue.stringOrNull(
                    if (fixed) {
                        existing.fields[RegistryEntityFields.Task.RECURRENCE_ANCHOR_DATE].stringValue()
                            ?: currentScheduled
                    } else {
                        null
                    },
                ),
                RegistryEntityFields.Task.RECURRENCE_WEEKDAYS to if (usesWeekdays && weekdays.isNotEmpty()) {
                    JsonValue.ArrayValue(weekdays.sorted().map { JsonValue.IntegerValue(it.toLong()) })
                } else JsonValue.Null,
                RegistryEntityFields.Task.RECURRENCE_MONTH_DAY to if (usesMonthRules && monthDay != null) {
                    JsonValue.IntegerValue(monthDay.toLong())
                } else JsonValue.Null,
                RegistryEntityFields.Task.RECURRENCE_ORDINAL_WEEKDAY to if (usesMonthRules && ordinalWeekday != null) {
                    JsonValue.ObjectValue(
                        mapOf(
                            "ordinal" to JsonValue.IntegerValue(ordinalWeekday.first.toLong()),
                            "weekday" to JsonValue.IntegerValue(ordinalWeekday.second.toLong()),
                        ),
                    )
                } else JsonValue.Null,
            )
        }
        write { check(graph.taskMutator.updateFields(taskId, changes) != null) }
    }

    fun chooseArea(areaId: String?) {
        write {
            check(
                graph.taskMutator.updateFields(
                    taskId,
                    mapOf(
                        RegistryEntityFields.Task.AREA to JsonValue.stringOrNull(areaId),
                        RegistryEntityFields.Task.PROJECT to JsonValue.Null,
                    ),
                ) != null,
            )
        }
    }

    fun setRepeatPaused(paused: Boolean) {
        write {
            check(
                graph.taskMutator.updateFields(
                    taskId,
                    mapOf(RegistryEntityFields.Task.RECURRENCE_PAUSED to JsonValue.BooleanValue(paused)),
                ) != null,
            )
        }
    }

    fun chooseProject(projectId: String?) {
        write {
            check(
                graph.taskMutator.updateFields(
                    taskId,
                    mapOf(
                        RegistryEntityFields.Task.AREA to JsonValue.stringOrNull(if (projectId == null) selectedAreaId else null),
                        RegistryEntityFields.Task.PROJECT to JsonValue.stringOrNull(projectId),
                    ),
                ) != null,
            )
        }
    }

    fun saveChecklistTitle(item: ChecklistLine) {
        val title = checklistDrafts[item.id]?.trim().orEmpty()
        if (title == item.title) return
        write {
            check(
                graph.registryEntityMutator.update(
                    RegistryEntityNames.CHECKLIST_ITEM,
                    item.id,
                    mapOf(RegistryEntityFields.ChecklistItem.TITLE to JsonValue.StringValue(title)),
                ) != null,
            )
        }
    }

    fun saveTaskText() {
        if (saving) return
        scope.launch {
            saving = true
            val result = runCatching { saveTextFields() }
            saveFailed = result.isFailure || result.getOrNull() == false
            saving = false
        }
    }

    Scaffold(
        modifier = modifier.fillMaxSize(),
        topBar = {
            TopAppBar(
                title = { Text(labels.title) },
                navigationIcon = {
                    TextButton(onClick = ::handleBack, enabled = !saving) {
                        Text(labels.back)
                    }
                },
                actions = {
                    TextButton(onClick = ::saveTaskText, enabled = data != null && !saving && titleDraft.isNotBlank()) {
                        Text(saveAction)
                    }
                },
            )
        },
    ) { padding ->
        if (!hasLoaded) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
        } else if (data == null) {
            Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                Text(labels.taskUnavailable)
            }
        } else {
            Box(Modifier.fillMaxSize().padding(padding)) {
                Column(
                modifier = Modifier
                    .widthIn(max = 720.dp)
                    .fillMaxWidth()
                    .align(Alignment.TopCenter)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                OutlinedTextField(
                    value = titleDraft,
                    onValueChange = {
                        titleDraft = it.take(RegistryEntityLimits.TEXT_MAX.toInt())
                        textIsDirty = true
                        saveFailed = false
                    },
                    label = { Text(labels.field(RegistryTaskDetail.Fields.TITLE)) },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    enabled = canEdit,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next),
                )

                OutlinedTextField(
                    value = notesDraft,
                    onValueChange = {
                        notesDraft = it.take(RegistryEntityLimits.NOTES_MAX.toInt())
                        textIsDirty = true
                        saveFailed = false
                    },
                    label = { Text(labels.field(RegistryTaskDetail.Fields.NOTES)) },
                    modifier = Modifier.fillMaxWidth(),
                    minLines = 3,
                    maxLines = 8,
                    enabled = canEdit,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Default),
                )

                if (saveFailed) {
                    Text(labels.saveError, color = MaterialTheme.colorScheme.error)
                }

                HorizontalDivider()
                DateValueRow(
                    label = labels.field(RegistryTaskDetail.Fields.WHEN),
                    value = whenValue,
                    selectLabel = labels.selectDate,
                    clearLabel = labels.clear,
                    enabled = canEdit,
                    onSelect = { showWhenPicker = true },
                    onClear = { setWhen(null) },
                )
                DateValueRow(
                    label = labels.field(RegistryTaskDetail.Fields.DEADLINE),
                    value = deadline?.let { formatDay(it, languageTag) } ?: labels.noDate,
                    selectLabel = labels.selectDate,
                    clearLabel = labels.clear,
                    enabled = canEdit,
                    onSelect = { showDeadlinePicker = true },
                    onClear = { write { check(graph.taskMutator.setDeadline(taskId, null) != null) } },
                )

                SelectorRow(
                    label = labels.field(RegistryTaskDetail.Fields.AREA),
                    value = selectedArea?.title ?: labels.noArea,
                    noneTitle = labels.noArea,
                    choices = data?.areas.orEmpty(),
                    enabled = canEdit,
                    onSelect = ::chooseArea,
                )
                SelectorRow(
                    label = labels.field(RegistryTaskDetail.Fields.PROJECT),
                    value = selectedProject?.title ?: labels.noProject,
                    noneTitle = labels.noProject,
                    choices = data?.projects.orEmpty(),
                    enabled = canEdit,
                    onSelect = ::chooseProject,
                )

                HorizontalDivider()
                RepeatEditor(
                    labels = labels,
                    units = labels.repeatUnits,
                    selectedUnit = repeatUnit,
                    interval = repeatInterval,
                    afterCompletion = repeatAfterCompletion,
                    paused = recurrencePaused,
                    pauseAction = repeatPauseAction,
                    weekdays = labels.weekdays,
                    monthlyRules = labels.monthlyRules,
                    calendarWeekdays = labels.calendarWeekdays,
                    ordinals = labels.ordinals,
                    selectedWeekdays = recurrenceWeekdays,
                    monthDay = recurrenceMonthDay,
                    ordinalWeekday = recurrenceOrdinal,
                    hasScheduledDate = scheduled != null,
                    enabled = canEdit,
                    onToggle = { enabled ->
                        if (enabled) setRepeat(repeatUnit ?: RegistryEntityEnums.RecurrenceUnit.WEEK)
                        else setRepeat(null)
                    },
                    onUnitChange = { setRepeat(it) },
                    onIntervalChange = { setRepeat(repeatUnit, it) },
                    onAfterCompletionChange = { setRepeat(repeatUnit, repeatInterval, it) },
                    onWeekdaysChange = { setRepeat(repeatUnit, repeatInterval, false, it, null, null) },
                    onMonthDayChange = { setRepeat(repeatUnit, repeatInterval, false, emptySet(), it, null) },
                    onOrdinalWeekdayChange = { setRepeat(repeatUnit, repeatInterval, false, emptySet(), null, it) },
                    onMonthRuleChange = { mode ->
                        val date = (scheduled ?: graph.clock.today(graph.clock.now()).toString()).let(LocalDate::parse)
                        val day = date.dayOfMonth
                        val weekday = date.dayOfWeek.value % 7 + 1
                        val ordinal = minOf(4, ((day - 1) / 7) + 1)
                        when (mode) {
                            "anchor" -> setRepeat(repeatUnit, repeatInterval, false, emptySet(), null, null)
                            "dayOfMonth" -> setRepeat(repeatUnit, repeatInterval, false, emptySet(), recurrenceMonthDay ?: day, null)
                            "ordinal" -> setRepeat(
                                repeatUnit,
                                repeatInterval,
                                false,
                                emptySet(),
                                null,
                                recurrenceOrdinal ?: (ordinal to weekday),
                            )
                        }
                    },
                    onPauseToggle = ::setRepeatPaused,
                )

                HorizontalDivider()
                Text(labels.field(RegistryTaskDetail.Fields.CHECKLIST), style = MaterialTheme.typography.titleMedium)
                data?.checklist.orEmpty().forEach { item ->
                    ChecklistRow(
                        item = item,
                        title = checklistDrafts[item.id] ?: item.title,
                        emptyTitle = labels.field(RegistryTaskDetail.Fields.CHECKLIST_ITEM),
                        toggleLabel = toggleChecklistAction,
                        deleteLabel = deleteChecklistAction,
                        enabled = canEdit,
                        onTitleChange = { checklistDrafts[item.id] = it.take(CHECKLIST_TITLE_MAX_LENGTH.toInt()) },
                        onFocusChange = { focused ->
                            focusedChecklistId = if (focused) item.id else focusedChecklistId.takeUnless { it == item.id }
                        },
                        onCommitTitle = { saveChecklistTitle(item) },
                        onToggle = { checked ->
                            val checkedAt = if (checked) WireTimestamp.format(graph.clock.now()) else null
                            write {
                                check(
                                    graph.registryEntityMutator.update(
                                        RegistryEntityNames.CHECKLIST_ITEM,
                                        item.id,
                                        mapOf(
                                            RegistryEntityFields.ChecklistItem.CHECKED to JsonValue.BooleanValue(checked),
                                            RegistryEntityFields.ChecklistItem.CHECKED_AT to JsonValue.stringOrNull(checkedAt),
                                        ),
                                    ) != null,
                                )
                            }
                        },
                        onDelete = {
                            write { check(graph.registryEntityMutator.delete(RegistryEntityNames.CHECKLIST_ITEM, item.id) != null) }
                        },
                    )
                }
                TextButton(
                    onClick = {
                        val nextPosition = data?.checklist.orEmpty().maxOfOrNull(ChecklistLine::position)?.plus(1.0) ?: 0.0
                        write {
                            val item = graph.registryEntityMutator.create(
                                RegistryEntityNames.CHECKLIST_ITEM,
                                mapOf(
                                    RegistryEntityFields.ChecklistItem.TASK_ID to JsonValue.StringValue(taskId),
                                    RegistryEntityFields.ChecklistItem.TITLE to JsonValue.StringValue(""),
                                    RegistryEntityFields.ChecklistItem.POSITION to JsonValue.DecimalValue(nextPosition),
                                ),
                            )
                            checklistDrafts[item.id] = ""
                        }
                    },
                    enabled = canEdit && data?.checklist.orEmpty().size.toLong() < RegistryEntityLimits.MAX_CHECKLIST_ITEMS_PER_TASK,
                    modifier = Modifier.align(Alignment.Start),
                ) { Text(addChecklistAction) }
                }
            }
        }
    }

    if (showWhenPicker) {
        TaskDatePickerDialog(
            label = labels.field(RegistryTaskDetail.Fields.WHEN),
            selectLabel = labels.selectDate,
            clearLabel = labels.clear,
            initialDay = scheduled ?: if (isToday) graph.clock.today(graph.clock.now()).toString() else null,
            cancelLabel = labels.cancel,
            onDismiss = { showWhenPicker = false },
            onSelect = { day -> showWhenPicker = false; setWhen(day) },
            onClear = { showWhenPicker = false; setWhen(null) },
        )
    }
    if (showDeadlinePicker) {
        TaskDatePickerDialog(
            label = labels.field(RegistryTaskDetail.Fields.DEADLINE),
            selectLabel = labels.selectDate,
            clearLabel = labels.clear,
            initialDay = deadline,
            cancelLabel = labels.cancel,
            onDismiss = { showDeadlinePicker = false },
            onSelect = { day ->
                showDeadlinePicker = false
                write { check(graph.taskMutator.setDeadline(taskId, day) != null) }
            },
            onClear = { showDeadlinePicker = false; write { check(graph.taskMutator.setDeadline(taskId, null) != null) } },
        )
    }
}

@Composable
private fun DateValueRow(
    label: String,
    value: String,
    selectLabel: String,
    clearLabel: String,
    enabled: Boolean,
    onSelect: () -> Unit,
    onClear: () -> Unit,
) {
    ListItem(
        headlineContent = { Text(label) },
        supportingContent = { Text(value) },
        trailingContent = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onSelect, enabled = enabled) { Text(selectLabel) }
                TextButton(onClick = onClear, enabled = enabled) { Text(clearLabel) }
            }
        },
    )
}

@Composable
private fun SelectorRow(
    label: String,
    value: String,
    noneTitle: String,
    choices: List<DetailListItem>,
    enabled: Boolean,
    onSelect: (String?) -> Unit,
) {
    var expanded by remember(label) { mutableStateOf(false) }
    ListItem(
        headlineContent = { Text(label) },
        supportingContent = { Text(value) },
        trailingContent = {
            Box {
                TextButton(onClick = { expanded = true }, enabled = enabled) { Text(value) }
                DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                    DropdownMenuItem(
                        text = { Text(noneTitle) },
                        onClick = { expanded = false; onSelect(null) },
                    )
                    choices.forEach { choice ->
                        DropdownMenuItem(
                            text = { Text(choice.title) },
                            onClick = { expanded = false; onSelect(choice.id) },
                        )
                    }
                }
            }
        },
    )
}

@Composable
private fun RepeatEditor(
    labels: TaskDetailLabels,
    units: List<RepeatUnitOption>,
    selectedUnit: String?,
    interval: Long,
    afterCompletion: Boolean,
    paused: Boolean,
    pauseAction: String,
    weekdays: List<RepeatChoice>,
    monthlyRules: List<RepeatUnitOption>,
    calendarWeekdays: List<RepeatChoice>,
    ordinals: List<RepeatChoice>,
    selectedWeekdays: Set<Int>,
    monthDay: Int?,
    ordinalWeekday: Pair<Int, Int>?,
    hasScheduledDate: Boolean,
    enabled: Boolean,
    onToggle: (Boolean) -> Unit,
    onUnitChange: (String) -> Unit,
    onIntervalChange: (Long) -> Unit,
    onAfterCompletionChange: (Boolean) -> Unit,
    onWeekdaysChange: (Set<Int>) -> Unit,
    onMonthDayChange: (Int) -> Unit,
    onOrdinalWeekdayChange: (Pair<Int, Int>) -> Unit,
    onMonthRuleChange: (String) -> Unit,
    onPauseToggle: (Boolean) -> Unit,
) {
    var unitMenuOpen by remember { mutableStateOf(false) }
    var monthRuleMenuOpen by remember { mutableStateOf(false) }
    var dayMenuOpen by remember { mutableStateOf(false) }
    var ordinalMenuOpen by remember { mutableStateOf(false) }
    var weekdayMenuOpen by remember { mutableStateOf(false) }
    var customOptionsOpen by remember(selectedUnit) { mutableStateOf(selectedWeekdays.isNotEmpty() || monthDay != null || ordinalWeekday != null) }
    var intervalDraft by remember(selectedUnit) { mutableStateOf(interval.toString()) }
    var intervalFocused by remember(selectedUnit) { mutableStateOf(false) }

    LaunchedEffect(selectedUnit, interval) {
        if (!intervalFocused) intervalDraft = interval.toString()
    }

    val monthRule = when {
        ordinalWeekday != null -> "ordinal"
        monthDay != null -> "dayOfMonth"
        else -> "anchor"
    }
    val selectedOrdinal = ordinals.firstOrNull { it.value == ordinalWeekday?.first }
    val selectedWeekday = calendarWeekdays.firstOrNull { it.value == ordinalWeekday?.second }
    val selectedMonthDayTitle = when (monthDay) {
        -1 -> labels.control(RegistryTaskDetail.Controls.LAST_DAY)
        null -> labels.control(RegistryTaskDetail.Controls.DAY_OF_MONTH)
        else -> monthDay.toString()
    }

    fun commitInterval() {
        val parsed = intervalDraft.toLongOrNull()
        if (parsed != null && parsed in 1L..99L) onIntervalChange(parsed)
        else intervalDraft = interval.toString()
    }

    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        ListItem(
            headlineContent = { Text(labels.field(RegistryTaskDetail.Fields.REPEAT)) },
            trailingContent = {
                Switch(
                    checked = selectedUnit != null,
                    onCheckedChange = onToggle,
                    enabled = enabled,
                )
            },
        )
        if (selectedUnit != null) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                OutlinedTextField(
                    value = intervalDraft,
                    onValueChange = { value ->
                        if (value.all { it.isDigit() } && value.length <= 2) {
                            intervalDraft = value
                            value.toLongOrNull()?.takeIf { it in 1L..99L }?.let(onIntervalChange)
                        }
                    },
                    label = { Text(labels.field(RegistryTaskDetail.Fields.INTERVAL)) },
                    enabled = enabled,
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { commitInterval() }),
                    modifier = Modifier.weight(1f).onFocusChanged { focus ->
                        if (intervalFocused && !focus.isFocused) commitInterval()
                        intervalFocused = focus.isFocused
                    },
                )
                Box {
                    TextButton(onClick = { unitMenuOpen = true }, enabled = enabled) {
                        Text(units.firstOrNull { it.value == selectedUnit }?.title.orEmpty())
                    }
                    DropdownMenu(expanded = unitMenuOpen, onDismissRequest = { unitMenuOpen = false }) {
                        units.forEach { unit ->
                            DropdownMenuItem(
                                text = { Text(unit.title) },
                                onClick = { unitMenuOpen = false; onUnitChange(unit.value) },
                            )
                        }
                    }
                }
            }
            ListItem(
                headlineContent = { Text(labels.field(RegistryTaskDetail.Fields.AFTER_COMPLETION)) },
                trailingContent = {
                    Switch(
                        checked = !hasScheduledDate || afterCompletion,
                        onCheckedChange = onAfterCompletionChange,
                        enabled = enabled && hasScheduledDate,
                    )
                },
            )
            if (selectedUnit != null && !afterCompletion && hasScheduledDate &&
                selectedUnit in setOf(RegistryEntityEnums.RecurrenceUnit.WEEK, RegistryEntityEnums.RecurrenceUnit.MONTH, RegistryEntityEnums.RecurrenceUnit.YEAR)
            ) {
                TextButton(onClick = { customOptionsOpen = !customOptionsOpen }, enabled = enabled) {
                    Text(labels.control(if (customOptionsOpen) RegistryTaskDetail.Controls.HIDE_CUSTOM_OPTIONS else RegistryTaskDetail.Controls.CUSTOM_OPTIONS))
                }
                if (customOptionsOpen && selectedUnit == RegistryEntityEnums.RecurrenceUnit.WEEK) {
                    Row(
                        modifier = Modifier.horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        weekdays.forEach { day ->
                            FilterChip(
                                selected = day.value in selectedWeekdays,
                                onClick = {
                                    onWeekdaysChange(if (day.value in selectedWeekdays) selectedWeekdays - day.value else selectedWeekdays + day.value)
                                },
                                label = { Text(day.shortTitle.orEmpty()) },
                                enabled = enabled,
                                modifier = Modifier.semantics { contentDescription = day.title },
                            )
                        }
                    }
                    FilterChip(
                        selected = selectedWeekdays == setOf(2, 3, 4, 5, 6),
                        onClick = { onWeekdaysChange(setOf(2, 3, 4, 5, 6)) },
                        label = { Text(labels.control(RegistryTaskDetail.Controls.WEEKDAYS)) },
                        enabled = enabled,
                    )
                }
                if (customOptionsOpen && selectedUnit in setOf(RegistryEntityEnums.RecurrenceUnit.MONTH, RegistryEntityEnums.RecurrenceUnit.YEAR)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(labels.control(RegistryTaskDetail.Controls.MONTHLY_RULE))
                        Box {
                            TextButton(onClick = { monthRuleMenuOpen = true }, enabled = enabled) {
                                Text(monthlyRules.firstOrNull { it.value == monthRule }?.title.orEmpty())
                            }
                            DropdownMenu(expanded = monthRuleMenuOpen, onDismissRequest = { monthRuleMenuOpen = false }) {
                                monthlyRules.forEach { rule ->
                                    DropdownMenuItem(
                                        text = { Text(rule.title) },
                                        onClick = { monthRuleMenuOpen = false; onMonthRuleChange(rule.value) },
                                    )
                                }
                            }
                        }
                    }
                    if (monthRule == "dayOfMonth") {
                        Box {
                            TextButton(onClick = { dayMenuOpen = true }, enabled = enabled) {
                                Text(selectedMonthDayTitle)
                            }
                            DropdownMenu(expanded = dayMenuOpen, onDismissRequest = { dayMenuOpen = false }) {
                                (1..31).forEach { day ->
                                    DropdownMenuItem(
                                        text = { Text(day.toString()) },
                                        onClick = { dayMenuOpen = false; onMonthDayChange(day) },
                                    )
                                }
                                DropdownMenuItem(
                                    text = { Text(labels.control(RegistryTaskDetail.Controls.LAST_DAY)) },
                                    onClick = { dayMenuOpen = false; onMonthDayChange(-1) },
                                )
                            }
                        }
                    }
                    if (monthRule == "ordinal") {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(labels.control(RegistryTaskDetail.Controls.ON_THE))
                            Box {
                                TextButton(onClick = { ordinalMenuOpen = true }, enabled = enabled) {
                                    Text(selectedOrdinal?.title ?: labels.control(RegistryTaskDetail.Controls.ORDINAL))
                                }
                                DropdownMenu(expanded = ordinalMenuOpen, onDismissRequest = { ordinalMenuOpen = false }) {
                                    ordinals.forEach { ordinal ->
                                        DropdownMenuItem(
                                            text = { Text(ordinal.title) },
                                            onClick = {
                                                ordinalMenuOpen = false
                                                onOrdinalWeekdayChange(ordinal.value to (ordinalWeekday?.second ?: calendarWeekdays.firstOrNull()?.value ?: 1))
                                            },
                                        )
                                    }
                                }
                            }
                            Box {
                                TextButton(onClick = { weekdayMenuOpen = true }, enabled = enabled) {
                                    Text(selectedWeekday?.title ?: calendarWeekdays.firstOrNull()?.title.orEmpty())
                                }
                                DropdownMenu(expanded = weekdayMenuOpen, onDismissRequest = { weekdayMenuOpen = false }) {
                                    calendarWeekdays.forEach { day ->
                                        DropdownMenuItem(
                                            text = { Text(day.title) },
                                            onClick = {
                                                weekdayMenuOpen = false
                                                onOrdinalWeekdayChange((ordinalWeekday?.first ?: ordinals.firstOrNull()?.value ?: 1) to day.value)
                                            },
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if (selectedUnit != null) {
                TextButton(onClick = { onPauseToggle(!paused) }, enabled = enabled) {
                    Text(pauseAction)
                }
            }
            if (selectedUnit != null && !hasScheduledDate) {
                Text(labels.control(RegistryTaskDetail.Controls.NO_SCHEDULE_FOR_FIXED), style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

@Composable
private fun ChecklistRow(
    item: ChecklistLine,
    title: String,
    emptyTitle: String,
    toggleLabel: String,
    deleteLabel: String,
    enabled: Boolean,
    onTitleChange: (String) -> Unit,
    onFocusChange: (Boolean) -> Unit,
    onCommitTitle: () -> Unit,
    onToggle: (Boolean) -> Unit,
    onDelete: () -> Unit,
) {
    var wasFocused by remember(item.id) { mutableStateOf(false) }
    Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Checkbox(
                checked = item.checked,
                onCheckedChange = onToggle,
                enabled = enabled,
                modifier = Modifier.semantics { contentDescription = "$toggleLabel: $title" },
            )
            OutlinedTextField(
                value = title,
                onValueChange = onTitleChange,
                label = { Text(item.title.ifEmpty { emptyTitle }) },
                enabled = enabled,
                singleLine = true,
                textStyle = MaterialTheme.typography.bodyLarge.copy(
                    textDecoration = if (item.checked) TextDecoration.LineThrough else TextDecoration.None,
                ),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { onCommitTitle() }),
                modifier = Modifier
                    .weight(1f)
                    .onFocusChanged { focus ->
                        onFocusChange(focus.isFocused)
                        if (wasFocused && !focus.isFocused) onCommitTitle()
                        wasFocused = focus.isFocused
                    },
            )
        }
        TextButton(onClick = onDelete, enabled = enabled, modifier = Modifier.align(Alignment.End)) {
            Text(deleteLabel)
        }
    }
}

@Composable
@OptIn(ExperimentalMaterial3Api::class)
private fun TaskDatePickerDialog(
    label: String,
    selectLabel: String,
    clearLabel: String,
    initialDay: String?,
    cancelLabel: String,
    onDismiss: () -> Unit,
    onSelect: (String) -> Unit,
    onClear: () -> Unit,
) {
    val initialMillis = initialDay?.let(::dayToEpochMillis)
    val datePickerState = rememberDatePickerState(initialSelectedDateMillis = initialMillis)
    DatePickerDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            TextButton(
                onClick = {
                    datePickerState.selectedDateMillis?.let { millis ->
                        onSelect(Instant.ofEpochMilli(millis).atZone(ZoneOffset.UTC).toLocalDate().toString())
                    }
                },
                enabled = datePickerState.selectedDateMillis != null,
            ) { Text(selectLabel) }
        },
        dismissButton = {
            Row {
                TextButton(onClick = onClear) { Text(clearLabel) }
                TextButton(onClick = onDismiss) { Text(cancelLabel) }
            }
        },
    ) {
        DatePicker(state = datePickerState, title = { Text(label) })
    }
}

private data class TaskDetailLabels(
    val title: String,
    val back: String,
    val cancel: String,
    val saveError: String,
    val taskUnavailable: String,
    val noDate: String,
    val noArea: String,
    val noProject: String,
    val clear: String,
    val selectDate: String,
    val repeatUnits: List<RepeatUnitOption>,
    val weekdays: List<RepeatChoice>,
    val calendarWeekdays: List<RepeatChoice>,
    val monthlyRules: List<RepeatUnitOption>,
    val ordinals: List<RepeatChoice>,
    private val fields: Map<String, String>,
    private val controls: Map<String, String>,
) {
    fun field(id: String): String = fields[id].orEmpty()
    fun control(id: String): String = controls[id].orEmpty()

    companion object {
        fun fromRegistry(languageTag: String): TaskDetailLabels {
            val detail = RegistryCatalog.surface(RegistryTaskDetail.ID)
            val fields = (detail?.fields?.get("fields") as? JsonValue.ObjectValue)?.fields.orEmpty()
                .mapNotNull { (id, raw) -> raw.stringValue()?.let { id to localize(it, languageTag) } }
                .toMap()
            val controls = (detail?.fields?.get("controls") as? JsonValue.ObjectValue)?.fields.orEmpty()
                .mapNotNull { (id, raw) -> raw.stringValue()?.let { id to localize(it, languageTag) } }
                .toMap()
            val units = (detail?.fields?.get("repeatUnits") as? JsonValue.ArrayValue)?.values.orEmpty()
                .mapNotNull { raw ->
                    val option = raw as? JsonValue.ObjectValue ?: return@mapNotNull null
                    val value = option.fields["value"].stringValue() ?: return@mapNotNull null
                    val title = option.fields["title"].stringValue()?.let { localize(it, languageTag) }
                        ?: return@mapNotNull null
                    RepeatUnitOption(value, title)
                }
            fun repeatChoices(key: String, hasShortTitle: Boolean = false): List<RepeatChoice> =
                (detail?.fields?.get(key) as? JsonValue.ArrayValue)?.values.orEmpty()
                    .mapNotNull { raw ->
                        val option = raw as? JsonValue.ObjectValue ?: return@mapNotNull null
                        val value = option.fields["value"].longValue()?.toInt() ?: return@mapNotNull null
                        val title = option.fields["title"].stringValue()?.let { localize(it, languageTag) }
                            ?: return@mapNotNull null
                        val shortTitle = if (hasShortTitle) {
                            option.fields["shortTitle"].stringValue()?.let { localize(it, languageTag) }
                        } else null
                        RepeatChoice(value, title, shortTitle)
                    }
            val monthlyRules = (detail?.fields?.get("monthlyRules") as? JsonValue.ArrayValue)?.values.orEmpty()
                .mapNotNull { raw ->
                    val option = raw as? JsonValue.ObjectValue ?: return@mapNotNull null
                    val value = option.fields["value"].stringValue() ?: return@mapNotNull null
                    val title = option.fields["title"].stringValue()?.let { localize(it, languageTag) }
                        ?: return@mapNotNull null
                    RepeatUnitOption(value, title)
                }
            return TaskDetailLabels(
                title = detail?.fields?.get("title")?.stringValue()?.let { localize(it, languageTag) }.orEmpty(),
                back = controls[RegistryTaskDetail.Controls.BACK].orEmpty(),
                cancel = controls[RegistryTaskDetail.Controls.CANCEL].orEmpty(),
                saveError = controls[RegistryTaskDetail.Controls.SAVE_ERROR].orEmpty(),
                taskUnavailable = controls[RegistryTaskDetail.Controls.TASK_UNAVAILABLE].orEmpty(),
                noDate = controls[RegistryTaskDetail.Controls.NO_DATE].orEmpty(),
                noArea = controls[RegistryTaskDetail.Controls.NO_AREA].orEmpty(),
                noProject = controls[RegistryTaskDetail.Controls.NO_PROJECT].orEmpty(),
                clear = controls[RegistryTaskDetail.Controls.CLEAR].orEmpty(),
                selectDate = controls[RegistryTaskDetail.Controls.SELECT_DATE].orEmpty(),
                repeatUnits = units,
                weekdays = repeatChoices("weekdays", hasShortTitle = true),
                calendarWeekdays = repeatChoices("calendarWeekdays"),
                monthlyRules = monthlyRules,
                ordinals = repeatChoices("ordinals"),
                fields = fields,
                controls = controls,
            )
        }

        private fun localize(value: String, languageTag: String): String =
            RegistryCatalog.localizedString(value, languageTag) ?: value
    }
}

private suspend fun loadTaskDetail(graph: AndroidAppGraph, taskId: String): TaskDetailData? {
    val task = graph.taskStore.record(RegistryEntityNames.TASK, taskId) ?: return null
    val areas = graph.taskStore.records(RegistryEntityNames.AREA)
        .filter { it.deletedAt == null }
        .mapNotNull { row ->
            row.fields[RegistryEntityFields.Area.TITLE].stringValue()?.let { title ->
                DetailListItem(row.id, title)
            }
        }
        .sortedBy { it.title.lowercase() }
    val projects = graph.taskStore.records(RegistryEntityNames.PROJECT)
        .filter { it.deletedAt == null }
        .mapNotNull { row ->
            row.fields[RegistryEntityFields.Project.TITLE].stringValue()?.let { title ->
                DetailListItem(
                    row.id,
                    title,
                    row.fields[RegistryEntityFields.Project.AREA].stringValue(),
                )
            }
        }
    val checklist = graph.taskStore.records(RegistryEntityNames.CHECKLIST_ITEM)
        .asSequence()
        .filter { it.deletedAt == null }
        .filter { it.fields[RegistryEntityFields.ChecklistItem.TASK_ID].stringValue() == taskId }
        .map { row ->
            ChecklistLine(
                id = row.id,
                title = row.fields[RegistryEntityFields.ChecklistItem.TITLE].stringValue().orEmpty(),
                checked = row.fields[RegistryEntityFields.ChecklistItem.CHECKED].booleanValue() == true,
                position = row.fields[RegistryEntityFields.ChecklistItem.POSITION].numberValue() ?: 0.0,
            )
        }
        .sortedBy { it.title.lowercase() }
        .sortedBy(ChecklistLine::position)
        .toList()
    return TaskDetailData(task, areas, projects, checklist)
}

private fun formatDay(day: String, languageTag: String): String = runCatching {
    DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)
        .withLocale(Locale.forLanguageTag(languageTag))
        .format(LocalDate.parse(day.take(10)))
}.getOrDefault(day)

private fun dayToEpochMillis(day: String): Long? =
    runCatching { LocalDate.parse(day.take(10)).atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli() }.getOrNull()

private fun JsonValue?.longValue(): Long? = when (this) {
    is JsonValue.IntegerValue -> value
    is JsonValue.DecimalValue -> value.toLong()
    else -> null
}

private fun JsonValue?.numberValue(): Double? = when (this) {
    is JsonValue.IntegerValue -> value.toDouble()
    is JsonValue.DecimalValue -> value
    else -> null
}
