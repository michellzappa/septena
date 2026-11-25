package app.septena.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.septena.android.AndroidAppGraph
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.SyncRecord
import app.septena.core.TaskConversation
import app.septena.core.TaskPageBlockKinds
import app.septena.core.TaskPageDepths
import app.septena.core.TaskProvenance
import app.septena.core.TaskTimeSlot
import app.septena.core.WireTimestamp
import app.septena.core.booleanValue
import app.septena.core.generated.RegistryActionIds
import app.septena.core.generated.RegistryDestinationIds
import app.septena.core.generated.RegistryEntities
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityLimits
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.generated.RegistrySurfaceIds
import app.septena.core.generated.RegistryTaskAttributeIds
import app.septena.core.generated.RegistryTaskDetail
import app.septena.core.stringValue
import app.septena.ui.AgentSparkleBubbleGlyph
import app.septena.ui.BellSmallGlyph
import app.septena.ui.CalendarSmallGlyph
import app.septena.ui.CheckmarkGlyph
import app.septena.ui.ChevronDownGlyph
import app.septena.ui.ChevronLeftGlyph
import app.septena.ui.ChevronRightGlyph
import app.septena.ui.CloseSmallGlyph
import app.septena.ui.DeadlineFlagGlyph
import app.septena.ui.PlusSmallGlyph
import app.septena.ui.RepeatSmallGlyph
import app.septena.ui.SeptenaGlyph
import app.septena.ui.SeptenaIconKind
import app.septena.ui.SeptenaTaskCheckbox
import app.septena.ui.StarGlyph
import app.septena.ui.TagSmallGlyph
import app.septena.ui.TaskCardMetrics
import app.septena.ui.TaskCardPosition
import app.septena.ui.TaskCardSlice
import app.septena.ui.cardPosition
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
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

private data class TagLine(val id: String, val name: String)

private data class TaskDetailData(
    val task: SyncRecord,
    val areas: List<DetailListItem>,
    val projects: List<DetailListItem>,
    val checklist: List<ChecklistLine>,
    val tags: List<TagLine>,
    /** The task's conversation hands it to the user for review (`needs_verify`). */
    val needsReview: Boolean = false,
)

private data class RepeatUnitOption(val value: String, val title: String)
private data class RepeatChoice(val value: Int, val title: String, val shortTitle: String? = null)

private val CHECKLIST_TITLE_MAX_LENGTH = RegistryEntities.all
    .getValue(RegistryEntityNames.CHECKLIST_ITEM)
    .columns
    .getValue(RegistryEntityFields.ChecklistItem.TITLE)
    .max ?: RegistryEntityLimits.TEXT_MAX

private val SUPPORTED_DETAIL_ATTRIBUTES = setOf(
    RegistryTaskAttributeIds.WHEN,
    RegistryTaskAttributeIds.DEADLINE,
    RegistryTaskAttributeIds.REMINDER,
    RegistryTaskAttributeIds.LIST,
    RegistryTaskAttributeIds.TAGS,
    RegistryTaskAttributeIds.REPEAT,
)

/** Standalone task-detail surface styled with iOS-aligned translucent glass cards. */
@Composable
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
fun TaskDetailScreen(
    graph: AndroidAppGraph,
    taskId: String,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    initialAttribute: String? = null,
    onOpenTask: (String) -> Unit = {},
    openSendBackInitially: Boolean = false,
) {
    val languageTag = LocalConfiguration.current.locales[0].toLanguageTag()
    val isDark = LocalSeptenaDarkTheme.current
    val hasActiveTexture = LocalAppearance.current.hasActiveTexture
    val labels = remember(languageTag) { TaskDetailLabels.fromRegistry(languageTag) }
    val attributes = remember(languageTag) { RegistryCatalog.taskAttributes(languageTag) }
    val dataVersion by graph.sync.dataVersion.collectAsStateWithLifecycle()
    val signedIn by graph.credentials.signedIn.collectAsStateWithLifecycle()
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
    // The attribute whose picker is folded open in its row on the page. One at a time.
    var openPicker by remember(taskId, initialAttribute) { mutableStateOf(initialAttribute) }
    var tagFilterDraft by remember(taskId) { mutableStateOf("") }
    var showAddReferenceDialog by remember(taskId) { mutableStateOf(false) }

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
    val status = taskFields[RegistryEntityFields.Task.STATUS].stringValue()
    val isCompleted = status == RegistryEntityEnums.TaskStatus.DONE
    val isStarred = taskFields[RegistryEntityFields.Task.STARRED].booleanValue() == true
    val scheduled = taskFields[RegistryEntityFields.Task.SCHEDULED].stringValue()
    val isToday = taskFields[RegistryEntityFields.Task.TODAY].booleanValue() == true
    val startTime = taskFields[RegistryEntityFields.Task.START_TIME].stringValue()
    val durationMinutes = taskFields[RegistryEntityFields.Task.DURATION_MINUTES].longValue()?.toInt()
    val timeSlotText = TaskTimeSlot.format(startTime, durationMinutes)
    val whenDateText = when {
        isToday -> RegistryCatalog.destinationTitle(RegistryDestinationIds.TODAY, languageTag).orEmpty()
        scheduled != null -> formatDay(scheduled, languageTag)
        else -> null
    }
    val whenValue = when {
        whenDateText != null && timeSlotText != null -> "$whenDateText · $timeSlotText"
        whenDateText != null -> whenDateText
        timeSlotText != null -> timeSlotText
        else -> labels.noDate
    }
    val whenIsSet = whenDateText != null || timeSlotText != null
    val deadline = taskFields[RegistryEntityFields.Task.DEADLINE].stringValue()
    val todayDate = graph.clock.today(graph.clock.now())
    val deadlineIsOverdue = deadline?.let {
        runCatching { !LocalDate.parse(it.take(10)).isAfter(todayDate) }.getOrDefault(false)
    } ?: false
    val reminderAt = taskFields[RegistryEntityFields.Task.REMINDER_AT].stringValue()
    val reminderMode = taskFields[RegistryEntityFields.Task.REMINDER_MODE].stringValue()
    val reminderValue = reminderAt?.let {
        formatReminder(
            reminderAt = it,
            reminderMode = reminderMode,
            snoozedUntil = taskFields[RegistryEntityFields.Task.REMINDER_SNOOZED_UNTIL].stringValue(),
            today = todayDate,
            languageTag = languageTag,
        )
    } ?: labels.control(RegistryTaskDetail.Controls.REMINDER_NONE)
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
    val completeAction = RegistryCatalog.actionTitle(RegistryActionIds.TASK_TOGGLE_COMPLETE, languageTag = languageTag).orEmpty()
    val starAction = RegistryCatalog.actionTitle(
        RegistryActionIds.TASK_TOGGLE_STAR,
        field = if (isStarred) "removeTitle" else "addTitle",
        languageTag = languageTag,
    ).orEmpty()
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
    val isTaskOpen = status == RegistryEntityEnums.TaskStatus.OPEN && !deleted
    val isReviewDepth = isTaskOpen && data?.needsReview == true
    val pageBlocks = remember(languageTag, isReviewDepth) {
        RegistryCatalog.taskPageBlocks(
            if (isReviewDepth) TaskPageDepths.REVIEW else TaskPageDepths.PAGE,
            languageTag = languageTag,
        )
    }
    val repeatSummary = labels.repeatUnits.firstOrNull { it.value == repeatUnit }?.title?.let { unitTitle ->
        if (repeatInterval > 1L) "$repeatInterval × $unitTitle" else unitTitle
    }
    val listValue = listOfNotNull(selectedArea?.title, selectedProject?.title)
        .joinToString(" · ")
        .ifEmpty { labels.noArea }
    val listIsSet = selectedArea != null || selectedProject != null
    val conversationBlock = pageBlocks.firstOrNull { it.kind == TaskPageBlockKinds.CONVERSATION }
    val conversationInAttributes = conversationBlock != null &&
        pageBlocks.any { it.kind == TaskPageBlockKinds.ATTRIBUTES }
    val discussHeading = attributes.firstOrNull { it.id == RegistryTaskAttributeIds.DISCUSS }?.label
        ?: conversationBlock?.let { RegistryCatalog.taskPageBlockHeading(it, languageTag) }

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

    fun toggleComplete() {
        if (!canEdit) return
        if (isCompleted) {
            write {
                check(
                    graph.taskMutator.updateFields(
                        taskId,
                        mapOf(
                            RegistryEntityFields.Task.STATUS to JsonValue.StringValue(RegistryEntityEnums.TaskStatus.OPEN),
                            RegistryEntityFields.Task.COMPLETED_AT to JsonValue.Null,
                        ),
                    ) != null,
                )
            }
        } else {
            write { check(graph.taskMutator.complete(taskId) != null) }
        }
    }

    fun toggleStarred() {
        write { check(graph.taskMutator.setStarred(taskId, !isStarred) != null) }
    }

    fun setWhen(day: String?) {
        write { check(graph.taskMutator.setWhen(taskId, day) != null) }
    }

    fun setTimeSlot(start: String?, duration: Int?) {
        val zone = start?.let { ZoneId.systemDefault().id }
        write { check(graph.taskMutator.setTimeSlot(taskId, start, duration?.toLong(), zone) != null) }
    }

    fun setDeadline(day: String?) {
        write { check(graph.taskMutator.setDeadline(taskId, day) != null) }
    }

    fun setReminder(reminderAt: String?, mode: String?) {
        write { check(graph.taskMutator.setReminder(taskId, reminderAt, mode) != null) }
    }

    fun setTag(tagId: String, selected: Boolean) {
        write {
            val currentTask = graph.taskStore.record(RegistryEntityNames.TASK, taskId)
                ?: error("Task is unavailable")
            val selectedIds = (currentTask.fields[RegistryEntityFields.Task.TAGS] as? JsonValue.ArrayValue)
                ?.values?.mapNotNull { it.stringValue() }.orEmpty()
            val nextIds = if (selected) (selectedIds + tagId).distinct() else selectedIds - tagId
            check(graph.taskMutator.setTags(taskId, nextIds) != null)
        }
    }

    fun createAndAssignTag() {
        val name = tagFilterDraft.trim().take(RegistryEntityLimits.TAG_NAME_MAX.toInt())
        if (name.isEmpty()) return
        scope.launch {
            saving = true
            saveFailed = false
            runCatching {
                withContext(Dispatchers.IO) {
                    val existingTag = graph.taskStore.records(RegistryEntityNames.TAG)
                        .firstOrNull { record ->
                            record.deletedAt == null &&
                                record.fields[RegistryEntityFields.Tag.NAME].stringValue()
                                    ?.equals(name, ignoreCase = true) == true
                        }
                    val tag = existingTag ?: graph.registryEntityMutator.create(
                        RegistryEntityNames.TAG,
                        mapOf(RegistryEntityFields.Tag.NAME to JsonValue.StringValue(name)),
                    )
                    graph.captureTaskEdit(taskId) {
                        val currentTask = graph.taskStore.record(RegistryEntityNames.TASK, taskId)
                            ?: error("Task is unavailable")
                        val currentIds = (currentTask.fields[RegistryEntityFields.Task.TAGS] as? JsonValue.ArrayValue)
                            ?.values?.mapNotNull { it.stringValue() }.orEmpty()
                        check(graph.taskMutator.setTags(taskId, (currentIds + tag.id).distinct()) != null)
                    }
                    tag.id
                }
            }.onSuccess {
                tagFilterDraft = ""
                graph.sync.noteLocalChange()
                graph.sync.requestSync()
            }.onFailure { saveFailed = true }
            saving = false
        }
    }

    fun openAttribute(attributeId: String) {
        if (openPicker == attributeId) {
            openPicker = null
        } else if (canEdit) {
            openPicker = attributeId
        }
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

    fun moveToArea(areaId: String?) {
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

    fun startRepeat() {
        if (!canEdit) return
        setRepeat(repeatUnit ?: RegistryEntityEnums.RecurrenceUnit.WEEK)
        openPicker = RegistryTaskAttributeIds.REPEAT
    }

    fun stopRepeat() {
        if (openPicker == RegistryTaskAttributeIds.REPEAT) openPicker = null
        setRepeat(null)
    }

    fun moveToProject(projectId: String?) {
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

    val canvasBackground = if (isDark) {
        MaterialTheme.colorScheme.background
    } else {
        MaterialTheme.colorScheme.surfaceContainerLow
    }
    val accent = MaterialTheme.colorScheme.primary
    val todayGold = MaterialTheme.colorScheme.secondary
    val mutedInk = MaterialTheme.colorScheme.onSurfaceVariant
    val overdueRed = if (isDark) Color(0xFFFF453A) else Color(0xFFFF3B30)

    Box(modifier = modifier.fillMaxSize().background(canvasBackground)) {
        HeaderWashBackdrop()
        Scaffold(
            containerColor = Color.Transparent,
            topBar = {
                TopAppBar(
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = Color.Transparent,
                        scrolledContainerColor = Color.Transparent,
                    ),
                    title = {},
                    navigationIcon = {
                        IconButton(
                            onClick = ::handleBack,
                            enabled = !saving,
                            modifier = Modifier.semantics { contentDescription = labels.back },
                        ) {
                            ChevronLeftGlyph(tint = MaterialTheme.colorScheme.onSurface)
                        }
                    },
                    actions = {
                        if (savedTask != null && !deleted) {
                            IconButton(
                                onClick = ::toggleStarred,
                                enabled = canEdit,
                                modifier = Modifier.semantics { contentDescription = starAction },
                            ) {
                                StarGlyph(
                                    filled = isStarred,
                                    tint = if (isStarred) todayGold else MaterialTheme.colorScheme.onSurface,
                                    size = 21.dp,
                                )
                            }
                        }
                        if (textIsDirty || saveFailed) {
                            TextButton(
                                onClick = ::saveTaskText,
                                enabled = data != null && !saving && titleDraft.isNotBlank(),
                            ) {
                                Text(saveAction, fontWeight = FontWeight.SemiBold)
                            }
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
                    Text(labels.taskUnavailable, color = mutedInk)
                }
            } else {
                Box(Modifier.fillMaxSize().padding(padding)) {
                    Column(
                        modifier = Modifier
                            .widthIn(max = 720.dp)
                            .fillMaxWidth()
                            .align(Alignment.TopCenter)
                            .verticalScroll(rememberScrollState())
                            .navigationBarsPadding()
                            .padding(top = 4.dp, bottom = 48.dp),
                    ) {
                        pageBlocks.forEachIndexed { blockIndex, block ->
                            val heading = RegistryCatalog.taskPageBlockHeading(block, languageTag)
                            val prevKind = pageBlocks.getOrNull(blockIndex - 1)?.kind
                            val nextKind = pageBlocks.getOrNull(blockIndex + 1)?.kind

                            when (block.kind) {
                                TaskPageBlockKinds.HEADER -> {
                                    val headerPosition = if (nextKind == TaskPageBlockKinds.NOTES) {
                                        TaskCardPosition.Top
                                    } else {
                                        TaskCardPosition.Solo
                                    }
                                    TaskCardSlice(
                                        position = headerPosition,
                                        isSelected = false,
                                        isDark = isDark,
                                        hasActiveTexture = hasActiveTexture,
                                    ) {
                                        Column(
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .padding(
                                                    horizontal = TaskCardMetrics.ContentInset,
                                                    vertical = 12.dp,
                                                ),
                                        ) {
                                            Row(
                                                verticalAlignment = Alignment.CenterVertically,
                                                modifier = Modifier.fillMaxWidth(),
                                            ) {
                                                SeptenaTaskCheckbox(
                                                    checked = isCompleted,
                                                    enabled = canEdit,
                                                    accessibilityLabel = completeAction,
                                                    isDark = isDark,
                                                    onToggle = ::toggleComplete,
                                                )
                                                Spacer(modifier = Modifier.width(TaskCardMetrics.IconTextGap))
                                                Box(modifier = Modifier.weight(1f)) {
                                                    if (titleDraft.isEmpty()) {
                                                        Text(
                                                            text = labels.field(RegistryTaskDetail.Fields.TITLE),
                                                            fontSize = 19.sp,
                                                            lineHeight = 25.sp,
                                                            fontWeight = FontWeight.SemiBold,
                                                            color = mutedInk.copy(alpha = 0.55f),
                                                        )
                                                    }
                                                    BasicTextField(
                                                        value = titleDraft,
                                                        onValueChange = {
                                                            titleDraft = it.take(RegistryEntityLimits.TEXT_MAX.toInt())
                                                            textIsDirty = true
                                                            saveFailed = false
                                                        },
                                                        enabled = canEdit,
                                                        textStyle = MaterialTheme.typography.titleMedium.copy(
                                                            fontSize = 19.sp,
                                                            lineHeight = 25.sp,
                                                            fontWeight = FontWeight.SemiBold,
                                                            color = if (isCompleted) mutedInk else MaterialTheme.colorScheme.onSurface,
                                                            textDecoration = if (isCompleted) TextDecoration.LineThrough else TextDecoration.None,
                                                        ),
                                                        cursorBrush = SolidColor(accent),
                                                        maxLines = 4,
                                                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next),
                                                        modifier = Modifier
                                                            .fillMaxWidth()
                                                            .semantics { contentDescription = labels.field(RegistryTaskDetail.Fields.TITLE) },
                                                    )
                                                }
                                            }

                                            if (isReviewDepth) {
                                                val reviewList = listOfNotNull(selectedArea?.title, selectedProject?.title)
                                                    .joinToString(" › ")
                                                if (reviewList.isNotEmpty()) {
                                                    Text(
                                                        text = reviewList,
                                                        fontSize = 13.sp,
                                                        color = mutedInk,
                                                        modifier = Modifier.padding(
                                                            start = TaskCardMetrics.LeadingColumnWidth + TaskCardMetrics.IconTextGap,
                                                            top = 4.dp,
                                                        ),
                                                    )
                                                }
                                            }
                                        }
                                    }

                                    if (saveFailed && pageBlocks.none { it.kind == TaskPageBlockKinds.NOTES }) {
                                        Text(
                                            text = labels.saveError,
                                            color = MaterialTheme.colorScheme.error,
                                            style = MaterialTheme.typography.bodySmall,
                                            modifier = Modifier.padding(horizontal = TaskCardMetrics.HeaderLeading, vertical = 4.dp),
                                        )
                                    }
                                }

                                TaskPageBlockKinds.NOTES -> {
                                    val notesPosition = if (prevKind == TaskPageBlockKinds.HEADER) {
                                        TaskCardPosition.Bottom
                                    } else {
                                        TaskCardPosition.Solo
                                    }
                                    val notesLabel = heading ?: labels.field(RegistryTaskDetail.Fields.NOTES)
                                    TaskCardSlice(
                                        position = notesPosition,
                                        isSelected = false,
                                        isDark = isDark,
                                        hasActiveTexture = hasActiveTexture,
                                    ) {
                                        Box(
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .padding(
                                                    start = TaskCardMetrics.TitleInsetInCard,
                                                    end = TaskCardMetrics.ContentInset,
                                                    top = 12.dp,
                                                    bottom = 14.dp,
                                                ),
                                        ) {
                                            if (notesDraft.isEmpty()) {
                                                Text(
                                                    text = notesLabel,
                                                    fontSize = 15.sp,
                                                    lineHeight = 21.sp,
                                                    color = mutedInk.copy(alpha = 0.55f),
                                                )
                                            }
                                            BasicTextField(
                                                value = notesDraft,
                                                onValueChange = {
                                                    notesDraft = it.take(RegistryEntityLimits.NOTES_MAX.toInt())
                                                    textIsDirty = true
                                                    saveFailed = false
                                                },
                                                enabled = canEdit,
                                                textStyle = MaterialTheme.typography.bodyLarge.copy(
                                                    fontSize = 15.sp,
                                                    lineHeight = 21.sp,
                                                    color = MaterialTheme.colorScheme.onSurface,
                                                ),
                                                cursorBrush = SolidColor(accent),
                                                minLines = 3,
                                                maxLines = 12,
                                                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Default),
                                                modifier = Modifier
                                                    .fillMaxWidth()
                                                    .semantics { contentDescription = notesLabel },
                                            )
                                        }
                                    }

                                    if (saveFailed) {
                                        Text(
                                            text = labels.saveError,
                                            color = MaterialTheme.colorScheme.error,
                                            style = MaterialTheme.typography.bodySmall,
                                            modifier = Modifier.padding(horizontal = TaskCardMetrics.HeaderLeading, vertical = 4.dp),
                                        )
                                    }
                                }

                                TaskPageBlockKinds.ATTRIBUTES -> {
                                    val renderedAttributes = attributes.filter { it.id in SUPPORTED_DETAIL_ATTRIBUTES }
                                    renderedAttributes.forEachIndexed { attrIndex, attribute ->
                                        val slicePos = cardPosition(attrIndex, renderedAttributes.size)
                                        TaskCardSlice(
                                            position = slicePos,
                                            isSelected = false,
                                            isDark = isDark,
                                            hasActiveTexture = hasActiveTexture,
                                        ) {
                                            when (attribute.id) {
                                                RegistryTaskAttributeIds.WHEN -> AttributeFoldRow(
                                                    label = labels.field(RegistryTaskDetail.Fields.WHEN),
                                                    value = whenValue,
                                                    valueColor = if (whenIsSet) accent else mutedInk,
                                                    expanded = openPicker == RegistryTaskAttributeIds.WHEN,
                                                    enabled = canEdit,
                                                    icon = {
                                                        if (isToday) {
                                                            SeptenaGlyph(kind = SeptenaIconKind.Today, tint = todayGold, size = 16.dp)
                                                        } else {
                                                            CalendarSmallGlyph(tint = if (whenIsSet) accent else mutedInk, size = 15.dp)
                                                        }
                                                    },
                                                    onToggle = { openAttribute(RegistryTaskAttributeIds.WHEN) },
                                                ) {
                                                    TaskDateBoard(
                                                        attribute = RegistryTaskAttributeIds.WHEN,
                                                        initialDay = scheduled ?: if (isToday) todayDate.toString() else null,
                                                        today = todayDate,
                                                        languageTag = languageTag,
                                                        enabled = canEdit,
                                                        onSelect = { day -> openPicker = null; setWhen(day) },
                                                        onClear = { openPicker = null; setWhen(null) },
                                                        startTime = startTime,
                                                        durationMinutes = durationMinutes,
                                                        onTimeSlotChange = { start, dur -> setTimeSlot(start, dur) },
                                                    )
                                                }

                                                RegistryTaskAttributeIds.DEADLINE -> AttributeFoldRow(
                                                    label = labels.field(RegistryTaskDetail.Fields.DEADLINE),
                                                    value = deadline?.let { formatDay(it, languageTag) } ?: labels.noDate,
                                                    valueColor = when {
                                                        deadlineIsOverdue -> overdueRed
                                                        deadline != null -> MaterialTheme.colorScheme.onSurface
                                                        else -> mutedInk
                                                    },
                                                    expanded = openPicker == RegistryTaskAttributeIds.DEADLINE,
                                                    enabled = canEdit,
                                                    icon = {
                                                        DeadlineFlagGlyph(
                                                            tint = if (deadlineIsOverdue) overdueRed else mutedInk,
                                                            size = 15.dp,
                                                        )
                                                    },
                                                    onToggle = { openAttribute(RegistryTaskAttributeIds.DEADLINE) },
                                                ) {
                                                    TaskDateBoard(
                                                        attribute = RegistryTaskAttributeIds.DEADLINE,
                                                        initialDay = deadline,
                                                        today = todayDate,
                                                        languageTag = languageTag,
                                                        enabled = canEdit,
                                                        onSelect = { day -> openPicker = null; setDeadline(day) },
                                                        onClear = { openPicker = null; setDeadline(null) },
                                                    )
                                                }

                                                RegistryTaskAttributeIds.REMINDER -> AttributeFoldRow(
                                                    label = attribute.label,
                                                    value = reminderValue,
                                                    valueColor = if (reminderAt != null) accent else mutedInk,
                                                    expanded = openPicker == RegistryTaskAttributeIds.REMINDER,
                                                    enabled = canEdit,
                                                    icon = {
                                                        BellSmallGlyph(tint = if (reminderAt != null) accent else mutedInk, size = 15.dp)
                                                    },
                                                    onToggle = { openAttribute(RegistryTaskAttributeIds.REMINDER) },
                                                ) {
                                                    TaskReminderPicker(
                                                        graph = graph,
                                                        reminderAt = reminderAt,
                                                        reminderMode = reminderMode,
                                                        enabled = canEdit,
                                                        control = labels::control,
                                                        onSet = { at, mode -> openPicker = null; setReminder(at, mode) },
                                                        onClear = { openPicker = null; setReminder(null, null) },
                                                    )
                                                }

                                                RegistryTaskAttributeIds.LIST -> AttributeFoldRow(
                                                    label = attribute.label,
                                                    value = listValue,
                                                    valueColor = if (listIsSet) MaterialTheme.colorScheme.onSurface else mutedInk,
                                                    expanded = openPicker == RegistryTaskAttributeIds.LIST,
                                                    enabled = canEdit,
                                                    icon = {
                                                        SeptenaGlyph(
                                                            kind = if (selectedProject != null) SeptenaIconKind.Project else SeptenaIconKind.Area,
                                                            tint = if (listIsSet) accent else mutedInk,
                                                            size = 16.dp,
                                                        )
                                                    },
                                                    onToggle = { openAttribute(RegistryTaskAttributeIds.LIST) },
                                                ) {
                                                    Text(
                                                        text = labels.field(RegistryTaskDetail.Fields.AREA),
                                                        fontSize = 12.sp,
                                                        fontWeight = FontWeight.SemiBold,
                                                        color = mutedInk,
                                                        modifier = Modifier.padding(horizontal = 14.dp, vertical = 4.dp),
                                                    )
                                                    ChoiceRow(
                                                        title = labels.noArea,
                                                        selected = selectedAreaId == null,
                                                        enabled = canEdit,
                                                        onClick = { openPicker = null; moveToArea(null) },
                                                    )
                                                    data?.areas.orEmpty().forEach { area ->
                                                        ChoiceRow(
                                                            title = area.title,
                                                            selected = area.id == selectedAreaId,
                                                            enabled = canEdit,
                                                            onClick = { openPicker = null; moveToArea(area.id) },
                                                        )
                                                    }
                                                    Text(
                                                        text = labels.field(RegistryTaskDetail.Fields.PROJECT),
                                                        fontSize = 12.sp,
                                                        fontWeight = FontWeight.SemiBold,
                                                        color = mutedInk,
                                                        modifier = Modifier.padding(
                                                            start = 14.dp,
                                                            end = 14.dp,
                                                            top = 8.dp,
                                                            bottom = 4.dp,
                                                        ),
                                                    )
                                                    ChoiceRow(
                                                        title = labels.noProject,
                                                        selected = selectedProjectId == null,
                                                        enabled = canEdit,
                                                        onClick = { openPicker = null; moveToProject(null) },
                                                    )
                                                    data?.projects.orEmpty().forEach { project ->
                                                        ChoiceRow(
                                                            title = project.title,
                                                            selected = project.id == selectedProjectId,
                                                            enabled = canEdit,
                                                            onClick = { openPicker = null; moveToProject(project.id) },
                                                        )
                                                    }
                                                }

                                                RegistryTaskAttributeIds.TAGS -> {
                                                    val selectedIds = (taskFields[RegistryEntityFields.Task.TAGS] as? JsonValue.ArrayValue)
                                                        ?.values?.mapNotNull { it.stringValue() }.orEmpty()
                                                    val selectedNames = data?.tags.orEmpty()
                                                        .filter { it.id in selectedIds }
                                                        .map(TagLine::name)
                                                    val tagLabels = taskTagPickerLabels(languageTag)
                                                    AttributeFoldRow(
                                                        label = attribute.label,
                                                        value = selectedNames.joinToString(", ").ifEmpty { tagLabels.emptyTitle },
                                                        valueColor = if (selectedNames.isNotEmpty()) MaterialTheme.colorScheme.onSurface else mutedInk,
                                                        expanded = openPicker == RegistryTaskAttributeIds.TAGS,
                                                        enabled = canEdit,
                                                        icon = {
                                                            TagSmallGlyph(
                                                                tint = if (selectedNames.isNotEmpty()) accent else mutedInk,
                                                                size = 15.dp,
                                                            )
                                                        },
                                                        onToggle = { openAttribute(RegistryTaskAttributeIds.TAGS) },
                                                    ) {
                                                        OutlinedTextField(
                                                            value = tagFilterDraft,
                                                            onValueChange = {
                                                                tagFilterDraft = it.take(RegistryEntityLimits.TAG_NAME_MAX.toInt())
                                                            },
                                                            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp),
                                                            singleLine = true,
                                                            label = { Text(tagLabels.filterPlaceholder) },
                                                            enabled = canEdit,
                                                        )
                                                        val filteredTags = data?.tags.orEmpty().filter { tag ->
                                                            tag.name.contains(tagFilterDraft.trim(), ignoreCase = true)
                                                        }
                                                        if (filteredTags.isNotEmpty()) {
                                                            FlowRow(
                                                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                                                                verticalArrangement = Arrangement.spacedBy(4.dp),
                                                                modifier = Modifier.padding(horizontal = 14.dp, vertical = 4.dp),
                                                            ) {
                                                                filteredTags.forEach { tag ->
                                                                    FilterChip(
                                                                        selected = tag.id in selectedIds,
                                                                        onClick = { setTag(tag.id, tag.id !in selectedIds) },
                                                                        label = { Text(tag.name) },
                                                                        enabled = canEdit && !saving,
                                                                    )
                                                                }
                                                            }
                                                        } else if (data?.tags.isNullOrEmpty()) {
                                                            Column(modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp)) {
                                                                Text(tagLabels.emptyTitle, style = MaterialTheme.typography.bodyMedium)
                                                                Text(
                                                                    tagLabels.emptyDetail,
                                                                    style = MaterialTheme.typography.bodySmall,
                                                                    color = mutedInk,
                                                                )
                                                            }
                                                        }
                                                        val duplicateTag = data?.tags.orEmpty().any {
                                                            it.name.equals(tagFilterDraft.trim(), ignoreCase = true)
                                                        }
                                                        if (tagFilterDraft.isNotBlank() && !duplicateTag) {
                                                            TextButton(
                                                                onClick = ::createAndAssignTag,
                                                                enabled = canEdit && !saving,
                                                                modifier = Modifier.align(Alignment.End).padding(end = 8.dp),
                                                            ) { Text(tagLabels.addTitle) }
                                                        }
                                                    }
                                                }

                                                RegistryTaskAttributeIds.REPEAT -> AttributeFoldRow(
                                                    label = labels.field(RegistryTaskDetail.Fields.REPEAT),
                                                    value = repeatSummary,
                                                    valueColor = if (repeatUnit != null) accent else mutedInk,
                                                    expanded = openPicker == RegistryTaskAttributeIds.REPEAT && repeatUnit != null,
                                                    enabled = canEdit,
                                                    icon = {
                                                        RepeatSmallGlyph(tint = if (repeatUnit != null) accent else mutedInk, size = 15.dp)
                                                    },
                                                    onToggle = {
                                                        if (repeatUnit == null) startRepeat()
                                                        else openAttribute(RegistryTaskAttributeIds.REPEAT)
                                                    },
                                                    trailing = {
                                                        Switch(
                                                            checked = repeatUnit != null,
                                                            onCheckedChange = { on -> if (on) startRepeat() else stopRepeat() },
                                                            enabled = canEdit,
                                                        )
                                                    },
                                                ) {
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
                                                        onUnitChange = { setRepeat(it) },
                                                        onIntervalChange = { setRepeat(repeatUnit, it) },
                                                        onAfterCompletionChange = { setRepeat(repeatUnit, repeatInterval, it) },
                                                        onWeekdaysChange = { setRepeat(repeatUnit, repeatInterval, false, it, null, null) },
                                                        onMonthDayChange = { setRepeat(repeatUnit, repeatInterval, false, emptySet(), it, null) },
                                                        onOrdinalWeekdayChange = { setRepeat(repeatUnit, repeatInterval, false, emptySet(), null, it) },
                                                        onMonthRuleChange = { mode ->
                                                            val date = (scheduled ?: todayDate.toString()).let(LocalDate::parse)
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
                                                }
                                            }
                                        }
                                    }
                                    if (conversationInAttributes) {
                                        TaskCardSlice(
                                            position = TaskCardPosition.Solo,
                                            isSelected = false,
                                            isDark = isDark,
                                            hasActiveTexture = hasActiveTexture,
                                        ) {
                                            Box(modifier = Modifier.padding(14.dp)) {
                                                TaskConversationSection(
                                                    graph = graph,
                                                    taskId = taskId,
                                                    isTaskOpen = isTaskOpen,
                                                    canWrite = canEdit,
                                                    heading = discussHeading,
                                                    openSendBackInitially = openSendBackInitially,
                                                )
                                            }
                                        }
                                    }
                                }

                                TaskPageBlockKinds.CHECKLIST -> {
                                    val checklistItems = data?.checklist.orEmpty()
                                    val canAddMore = checklistItems.size.toLong() < RegistryEntityLimits.MAX_CHECKLIST_ITEMS_PER_TASK
                                    val totalSlices = checklistItems.size + if (canAddMore) 1 else 0
                                    DetailSectionHeader(heading ?: labels.field(RegistryTaskDetail.Fields.CHECKLIST))
                                    checklistItems.forEachIndexed { index, item ->
                                        TaskCardSlice(
                                            position = cardPosition(index, totalSlices),
                                            isSelected = false,
                                            isDark = isDark,
                                            hasActiveTexture = hasActiveTexture,
                                        ) {
                                            ChecklistRow(
                                                item = item,
                                                title = checklistDrafts[item.id] ?: item.title,
                                                emptyTitle = labels.field(RegistryTaskDetail.Fields.CHECKLIST_ITEM),
                                                toggleLabel = toggleChecklistAction,
                                                deleteLabel = deleteChecklistAction,
                                                isDark = isDark,
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
                                    }
                                    if (canAddMore) {
                                        TaskCardSlice(
                                            position = cardPosition(checklistItems.size, totalSlices),
                                            isSelected = false,
                                            isDark = isDark,
                                            hasActiveTexture = hasActiveTexture,
                                        ) {
                                            Row(
                                                verticalAlignment = Alignment.CenterVertically,
                                                modifier = Modifier
                                                    .fillMaxWidth()
                                                    .clickable(enabled = canEdit) {
                                                        val nextPosition = checklistItems.maxOfOrNull(ChecklistLine::position)?.plus(1.0) ?: 0.0
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
                                                    }
                                                    .padding(horizontal = TaskCardMetrics.ContentInset, vertical = 12.dp),
                                            ) {
                                                Box(
                                                    contentAlignment = Alignment.Center,
                                                    modifier = Modifier.width(TaskCardMetrics.LeadingColumnWidth),
                                                ) {
                                                    PlusSmallGlyph(tint = accent, size = 15.dp)
                                                }
                                                Spacer(modifier = Modifier.width(TaskCardMetrics.IconTextGap))
                                                Text(
                                                    text = addChecklistAction,
                                                    fontSize = 15.sp,
                                                    lineHeight = 20.sp,
                                                    color = accent,
                                                )
                                            }
                                        }
                                    }
                                }

                                TaskPageBlockKinds.CONVERSATION -> if (!conversationInAttributes) {
                                    TaskCardSlice(
                                        position = TaskCardPosition.Solo,
                                        isSelected = false,
                                        isDark = isDark,
                                        hasActiveTexture = hasActiveTexture,
                                    ) {
                                        Box(modifier = Modifier.padding(14.dp)) {
                                            TaskConversationSection(
                                                graph = graph,
                                                taskId = taskId,
                                                isTaskOpen = isTaskOpen,
                                                canWrite = canEdit,
                                                heading = heading,
                                                openSendBackInitially = openSendBackInitially,
                                            )
                                        }
                                    }
                                }

                                TaskPageBlockKinds.ATTACHMENTS -> if (savedTask != null) {
                                    TaskAttachmentsSection(
                                        graph = graph,
                                        taskId = taskId,
                                        heading = heading,
                                        canEdit = canEdit,
                                        control = labels::control,
                                    )
                                }

                                TaskPageBlockKinds.REFERENCES -> if (savedTask != null) {
                                    TaskReferencesSection(
                                        graph = graph,
                                        taskId = taskId,
                                        heading = heading,
                                        canEdit = canEdit,
                                        taskTitle = titleDraft,
                                        taskNotes = notesDraft,
                                        showAddDialog = showAddReferenceDialog,
                                        onShowAddDialogChange = { showAddReferenceDialog = it },
                                        onOpenTask = onOpenTask,
                                    )
                                }

                                TaskPageBlockKinds.PROVENANCE -> {
                                    val source = taskFields[RegistryEntityFields.Task.SOURCE].stringValue()
                                    val isAgent = TaskProvenance.isAgentAuthored(source)
                                    val name = TaskProvenance.addedByName(
                                        source,
                                        taskFields[RegistryEntityFields.Task.SOURCE_CLIENT].stringValue(),
                                        languageTag,
                                    )
                                    val on = formatAddedOn(
                                        taskFields[RegistryEntityFields.Task.CREATED_AT].stringValue(),
                                        taskFields[RegistryEntityFields.Task.CREATED].stringValue(),
                                        languageTag,
                                    )
                                    heading?.let { DetailSectionHeader(it) }
                                    TaskCardSlice(
                                        position = TaskCardPosition.Solo,
                                        isSelected = false,
                                        isDark = isDark,
                                        hasActiveTexture = hasActiveTexture,
                                    ) {
                                        Row(
                                            verticalAlignment = Alignment.CenterVertically,
                                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .padding(horizontal = TaskCardMetrics.ContentInset, vertical = 12.dp),
                                        ) {
                                            if (isAgent) {
                                                Box(
                                                    contentAlignment = Alignment.Center,
                                                    modifier = Modifier.width(TaskCardMetrics.LeadingColumnWidth),
                                                ) {
                                                    AgentSparkleBubbleGlyph(tint = mutedInk, size = 16.dp)
                                                }
                                            }
                                            Text(
                                                text = if (on == null) name else "$name · $on",
                                                fontSize = 14.5.sp,
                                                lineHeight = 20.sp,
                                                color = mutedInk,
                                            )
                                        }
                                    }
                                }

                                TaskPageBlockKinds.HISTORY -> if (savedTask != null && signedIn) {
                                    TaskCardSlice(
                                        position = TaskCardPosition.Solo,
                                        isSelected = false,
                                        isDark = isDark,
                                        hasActiveTexture = hasActiveTexture,
                                    ) {
                                        AttributeFoldRow(
                                            label = heading.orEmpty(),
                                            value = null,
                                            valueColor = mutedInk,
                                            expanded = openPicker == RegistryTaskAttributeIds.HISTORY,
                                            enabled = canEdit,
                                            icon = {
                                                SeptenaGlyph(kind = SeptenaIconKind.Logbook, tint = mutedInk, size = 15.dp)
                                            },
                                            onToggle = { openAttribute(RegistryTaskAttributeIds.HISTORY) },
                                        ) {
                                            TaskHistoryList(
                                                graph = graph,
                                                taskId = taskId,
                                                languageTag = languageTag,
                                                control = labels::control,
                                            )
                                        }
                                    }
                                }

                                else -> Unit
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun DetailSectionHeader(title: String) {
    Text(
        text = title,
        fontSize = 18.sp,
        lineHeight = 22.sp,
        fontWeight = FontWeight.SemiBold,
        color = MaterialTheme.colorScheme.onSurface,
        modifier = Modifier.padding(
            start = TaskCardMetrics.HeaderLeading,
            end = TaskCardMetrics.Margin,
            top = 14.dp,
            bottom = 6.dp,
        ),
    )
}

/**
 * One iOS-style attribute row inside a continuous glass card slice. A tap folds
 * the attribute's picker open in-place; a second tap folds it closed (Cancel).
 */
@Composable
private fun AttributeFoldRow(
    label: String,
    value: String?,
    valueColor: Color,
    expanded: Boolean,
    enabled: Boolean,
    icon: @Composable () -> Unit,
    onToggle: () -> Unit,
    trailing: (@Composable () -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    val mutedInk = MaterialTheme.colorScheme.onSurfaceVariant
    val dividerColor = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.35f)
    Column(modifier = Modifier.fillMaxWidth()) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .clickable(enabled = enabled || expanded, onClick = onToggle)
                .padding(horizontal = TaskCardMetrics.ContentInset, vertical = 12.dp),
        ) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier.width(TaskCardMetrics.LeadingColumnWidth),
            ) {
                icon()
            }
            Spacer(modifier = Modifier.width(TaskCardMetrics.IconTextGap))
            Text(
                text = label,
                fontSize = 15.5.sp,
                lineHeight = 20.sp,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(modifier = Modifier.width(12.dp))
            if (value != null) {
                Text(
                    text = value,
                    fontSize = 14.5.sp,
                    lineHeight = 20.sp,
                    color = valueColor,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                    textAlign = androidx.compose.ui.text.style.TextAlign.End,
                )
            } else {
                Spacer(modifier = Modifier.weight(1f))
            }
            Spacer(modifier = Modifier.width(8.dp))
            if (trailing != null) {
                trailing()
            } else if (expanded) {
                ChevronDownGlyph(tint = mutedInk.copy(alpha = 0.65f), size = 14.dp)
            } else {
                ChevronRightGlyph(tint = mutedInk.copy(alpha = 0.55f), size = 13.dp)
            }
        }
        if (expanded) {
            HorizontalDivider(
                modifier = Modifier.padding(horizontal = TaskCardMetrics.ContentInset),
                thickness = 0.5.dp,
                color = dividerColor,
            )
            Column(
                modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
                content = content,
            )
        }
    }
}

/** One choice in an embedded list picker. Clean iOS checkmark row; a tap commits it. */
@Composable
private fun ChoiceRow(
    title: String,
    selected: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val accent = MaterialTheme.colorScheme.primary
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 10.dp),
    ) {
        Text(
            text = title,
            fontSize = 15.sp,
            lineHeight = 20.sp,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            color = if (selected) accent else MaterialTheme.colorScheme.onSurface,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (selected) {
            CheckmarkGlyph(tint = accent, size = 15.dp)
        }
    }
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

    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (selectedUnit != null) {
            Row(
                modifier = Modifier.fillMaxWidth(),
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
            Row(
                modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(
                    text = labels.field(RegistryTaskDetail.Fields.AFTER_COMPLETION),
                    fontSize = 15.sp,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Switch(
                    checked = !hasScheduledDate || afterCompletion,
                    onCheckedChange = onAfterCompletionChange,
                    enabled = enabled && hasScheduledDate,
                )
            }
            if (!afterCompletion && hasScheduledDate &&
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
            TextButton(onClick = { onPauseToggle(!paused) }, enabled = enabled) {
                Text(pauseAction)
            }
            if (!hasScheduledDate) {
                Text(
                    text = labels.control(RegistryTaskDetail.Controls.NO_SCHEDULE_FOR_FIXED),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
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
    isDark: Boolean,
    enabled: Boolean,
    onTitleChange: (String) -> Unit,
    onFocusChange: (Boolean) -> Unit,
    onCommitTitle: () -> Unit,
    onToggle: (Boolean) -> Unit,
    onDelete: () -> Unit,
) {
    var wasFocused by remember(item.id) { mutableStateOf(false) }
    val mutedInk = MaterialTheme.colorScheme.onSurfaceVariant
    val accent = MaterialTheme.colorScheme.primary
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = TaskCardMetrics.ContentInset, vertical = 6.dp),
    ) {
        SeptenaTaskCheckbox(
            checked = item.checked,
            enabled = enabled,
            accessibilityLabel = "$toggleLabel: $title",
            isDark = isDark,
            onToggle = { onToggle(!item.checked) },
        )
        Spacer(modifier = Modifier.width(TaskCardMetrics.IconTextGap))
        Box(modifier = Modifier.weight(1f)) {
            if (title.isEmpty()) {
                Text(
                    text = item.title.ifEmpty { emptyTitle },
                    fontSize = 15.sp,
                    lineHeight = 20.sp,
                    color = mutedInk.copy(alpha = 0.55f),
                )
            }
            BasicTextField(
                value = title,
                onValueChange = onTitleChange,
                enabled = enabled,
                singleLine = true,
                textStyle = MaterialTheme.typography.bodyLarge.copy(
                    fontSize = 15.sp,
                    lineHeight = 20.sp,
                    color = if (item.checked) mutedInk.copy(alpha = 0.72f) else MaterialTheme.colorScheme.onSurface,
                    textDecoration = if (item.checked) TextDecoration.LineThrough else TextDecoration.None,
                ),
                cursorBrush = SolidColor(accent),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { onCommitTitle() }),
                modifier = Modifier
                    .fillMaxWidth()
                    .onFocusChanged { focus ->
                        onFocusChange(focus.isFocused)
                        if (wasFocused && !focus.isFocused) onCommitTitle()
                        wasFocused = focus.isFocused
                    },
            )
        }
        if (enabled) {
            IconButton(
                onClick = onDelete,
                modifier = Modifier
                    .size(30.dp)
                    .semantics { contentDescription = deleteLabel },
            ) {
                CloseSmallGlyph(tint = mutedInk.copy(alpha = 0.65f), size = 12.dp)
            }
        }
    }
}

private data class TaskTagPickerLabels(
    val filterPlaceholder: String,
    val addTitle: String,
    val emptyTitle: String,
    val emptyDetail: String,
)

private fun taskTagPickerLabels(languageTag: String): TaskTagPickerLabels {
    val surface = RegistryCatalog.surface(RegistrySurfaceIds.TASK_TAGS_PICKER)
    fun label(field: String): String {
        val key = surface?.fields?.get(field).stringValue().orEmpty()
        return RegistryCatalog.localizedString(key, languageTag) ?: key
    }
    return TaskTagPickerLabels(
        filterPlaceholder = label("filterPlaceholder"),
        addTitle = label("addTitle"),
        emptyTitle = label("emptyTitle"),
        emptyDetail = label("emptyDetail"),
    )
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
    val tags = graph.taskStore.records(RegistryEntityNames.TAG)
        .filter { it.deletedAt == null }
        .mapNotNull { row ->
            row.fields[RegistryEntityFields.Tag.NAME].stringValue()?.let { name -> TagLine(row.id, name) }
        }
        .sortedBy { it.name.lowercase() }
    val conversation = graph.taskStore.record(RegistryEntityNames.CONVO, taskId)?.let { record ->
        TaskConversation.from(record, graph.taskStore.turns(taskId))
    }
    return TaskDetailData(task, areas, projects, checklist, tags, needsReview = conversation?.needsHumanReview == true)
}

/** When the task was added: the creation instant in the device zone, else its creation day. */
private fun formatAddedOn(createdAt: String?, created: String?, languageTag: String): String? {
    val locale = Locale.forLanguageTag(languageTag)
    createdAt?.let { stamp ->
        runCatching {
            DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)
                .withLocale(locale)
                .format(Instant.parse(stamp).atZone(ZoneId.systemDefault()))
        }.getOrNull()?.let { return it }
    }
    return created?.let { formatDay(it, languageTag) }
}

internal fun formatDay(day: String, languageTag: String): String = runCatching {
    DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)
        .withLocale(Locale.forLanguageTag(languageTag))
        .format(LocalDate.parse(day.take(10)))
}.getOrDefault(day)

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
