package app.septena.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.septena.android.AndroidAppGraph
import app.septena.core.JsonValue
import app.septena.core.NotesBase
import app.septena.core.RegistryCatalog
import app.septena.core.TaskPageBlockKinds
import app.septena.core.TaskPageDepths
import app.septena.core.TaskTimeSlot
import app.septena.core.WireTimestamp
import app.septena.core.booleanValue
import app.septena.core.generated.RegistryActionIds
import app.septena.core.generated.RegistryDestinationIds
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityLimits
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.generated.RegistryTaskAttributeIds
import app.septena.core.generated.RegistryTaskDetail
import app.septena.core.longValue
import app.septena.core.stringValue
import app.septena.ui.AgentSparkleBubbleGlyph
import app.septena.ui.AttachmentSmallGlyph
import app.septena.ui.BellSmallGlyph
import app.septena.ui.CalendarSmallGlyph
import app.septena.ui.ChecklistSmallGlyph
import app.septena.ui.ChevronUpGlyph
import app.septena.ui.DeadlineFlagGlyph
import app.septena.ui.OpenTaskPageGlyph
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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.time.ZoneId

/**
 * Things-style expand-in-place task foldout (`TaskPageDepths.INLINE`, ADR 0029):
 * renders inline inside the row's glass card slice with checkbox, title, notes,
 * inline checklist/references/attachments, and a horizontal pill rail that opens
 * the same pickers as the full page in sheets. Folding or opening the full page
 * autosaves pending text edits first.
 */
@Composable
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
internal fun TaskInlineFoldout(
    graph: AndroidAppGraph,
    taskId: String,
    fallbackTitle: String,
    fallbackCompleted: Boolean,
    position: TaskCardPosition,
    isDark: Boolean,
    hasActiveTexture: Boolean,
    onOpenFullPage: (String) -> Unit,
    onCollapse: () -> Unit,
    modifier: Modifier = Modifier,
    /**
     * An inline-create draft (InlineDraft.kt): the title field takes focus,
     * Return with a blank title folds, and a fold with nothing typed purges it.
     */
    isDraft: Boolean = false,
    /**
     * True while the host still shows this row expanded. A lazy list disposes a
     * row that scrolls off screen; that is not a fold, so a draft is kept.
     */
    isStillOpen: () -> Boolean = { false },
) {
    val languageTag = LocalConfiguration.current.locales[0].toLanguageTag()
    val labels = remember(languageTag) { TaskDetailLabels.fromRegistry(languageTag) }
    val attributes = remember(languageTag) { RegistryCatalog.taskAttributes(languageTag) }
    val inlineBlocks = remember(languageTag) {
        RegistryCatalog.taskPageBlocks(TaskPageDepths.INLINE, languageTag = languageTag)
    }
    val dataVersion by graph.sync.dataVersion.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()

    var data by remember(taskId) { mutableStateOf<TaskDetailData?>(null) }
    var titleDraft by remember(taskId) { mutableStateOf(fallbackTitle) }
    var notesDraft by remember(taskId) { mutableStateOf("") }
    var titleBase by remember(taskId) { mutableStateOf(fallbackTitle) }
    var notesBase by remember(taskId) { mutableStateOf("") }
    var textIsDirty by remember(taskId) { mutableStateOf(false) }
    var saving by remember(taskId) { mutableStateOf(false) }
    var saveFailed by remember(taskId) { mutableStateOf(false) }
    var openSheet by remember(taskId) { mutableStateOf<String?>(null) }
    var tagFilterDraft by remember(taskId) { mutableStateOf("") }
    var pendingRescheduleDay by remember(taskId) { mutableStateOf<String?>(null) }
    var checklistOpened by remember(taskId) { mutableStateOf(false) }
    var attachmentsOpened by remember(taskId) { mutableStateOf(false) }
    val checklistDrafts = remember(taskId) { mutableStateMapOf<String, String>() }
    var focusedChecklistId by remember(taskId) { mutableStateOf<String?>(null) }

    LaunchedEffect(graph, taskId, dataVersion) {
        val loaded = withContext(Dispatchers.IO) { loadTaskDetail(graph, taskId) }
        data = loaded
        if (loaded != null && !textIsDirty) {
            titleDraft = loaded.task.fields[RegistryEntityFields.Task.TITLE].stringValue().orEmpty()
            notesDraft = loaded.task.fields[RegistryEntityFields.Task.NOTES].stringValue().orEmpty()
            titleBase = titleDraft
            notesBase = notesDraft
        }
        if (loaded != null) {
            loaded.checklist.forEach { item ->
                if (item.id != focusedChecklistId) checklistDrafts[item.id] = item.title
            }
            checklistDrafts.keys.retainAll(loaded.checklist.map(ChecklistLine::id).toSet())
        }
    }

    // Opening a faded task keeps it once per visit (docs/TASK_FADE_SPEC.md §4).
    var keptOnOpen by rememberSaveable(taskId) { mutableStateOf(false) }
    LaunchedEffect(graph, taskId) {
        if (keptOnOpen) return@LaunchedEffect
        keptOnOpen = true
        val kept = withContext(Dispatchers.IO) { runCatching { graph.keepFadedOnOpen(taskId) }.getOrDefault(false) }
        if (kept) {
            graph.sync.noteLocalChange()
            graph.sync.requestSync()
        }
    }

    suspend fun persistTextSnapshot(
        snapshot: TaskDetailData?,
        rawTitle: String,
        rawNotes: String,
        baseTitle: String,
        baseNotes: String,
    ): Boolean {
        val current = snapshot ?: return true
        if (current.task.deletedAt != null) return true
        val title = rawTitle.trim()
        if (title.isEmpty()) return false
        val currentTitle = current.task.fields[RegistryEntityFields.Task.TITLE].stringValue().orEmpty()
        if (isDraft && currentTitle.isBlank()) {
            // The draft's first title: tokens, `# Heading`, and the deferred push (InlineDraft.kt).
            val commit = withContext(Dispatchers.IO) { graph.commitInlineDraft(taskId, title, rawNotes) }
            graph.sync.noteLocalChange()
            graph.sync.requestSync()
            return commit != InlineDraftCommit.NoChange
        }
        val currentNotes = current.task.fields[RegistryEntityFields.Task.NOTES].stringValue().orEmpty()
        val notes = rawNotes.trim()
        val titleChanged = title != currentTitle && title != baseTitle.trim()
        val notesChanged = notes != currentNotes && notes != baseNotes.trim()
        if (!titleChanged && !notesChanged) return true
        val changes = buildMap<String, JsonValue> {
            if (titleChanged) put(RegistryEntityFields.Task.TITLE, JsonValue.StringValue(title))
            if (notesChanged) put(RegistryEntityFields.Task.NOTES, JsonValue.stringOrNull(notes.ifEmpty { null }))
        }
        withContext(Dispatchers.IO) {
            graph.captureTaskEdit(taskId) {
                check(
                    graph.taskMutator.updateFields(
                        taskId,
                        changes,
                        notesBase = NotesBase(baseNotes.ifEmpty { null }),
                    ) != null,
                )
            }
        }
        graph.sync.noteLocalChange()
        graph.sync.requestSync()
        return true
    }

    suspend fun saveTextFields(): Boolean {
        val ok = persistTextSnapshot(data, titleDraft, notesDraft, titleBase, notesBase)
        if (ok) {
            titleBase = titleDraft.trim()
            notesBase = notesDraft.trim()
            textIsDirty = false
            saveFailed = false
        } else {
            saveFailed = true
        }
        return ok
    }

    val latestData by rememberUpdatedState(data)
    val latestTitle by rememberUpdatedState(titleDraft)
    val latestNotes by rememberUpdatedState(notesDraft)
    val latestTitleBase by rememberUpdatedState(titleBase)
    val latestNotesBase by rememberUpdatedState(notesBase)
    val latestDirty by rememberUpdatedState(textIsDirty)

    // Folding by tapping another row or leaving the list autosaves pending text edits.
    DisposableEffect(taskId) {
        onDispose {
            if (isDraft && latestTitle.isBlank() && !isStillOpen()) {
                // Nothing typed: drop the draft. It never left this device.
                graph.launch {
                    if (runCatching { graph.discardInlineDraftIfEmpty(taskId) }.getOrDefault(false)) {
                        graph.sync.noteLocalChange()
                    }
                }
            } else if (latestDirty) {
                val snap = latestData
                val t = latestTitle
                val n = latestNotes
                val tb = latestTitleBase
                val nb = latestNotesBase
                graph.launch { runCatching { persistTextSnapshot(snap, t, n, tb, nb) } }
            }
        }
    }

    fun saveThen(then: () -> Unit) {
        // A blank draft folds at once; the fold drops it (Apple: blank Return only closes).
        if (!textIsDirty || data == null || (isDraft && titleDraft.isBlank())) {
            then()
            return
        }
        if (saving) return
        scope.launch {
            saving = true
            val saved = runCatching { saveTextFields() }.getOrElse { false }
            saving = false
            if (saved) then() else saveFailed = true
        }
    }

    fun handleCollapse() = saveThen(onCollapse)
    fun handleOpenFullPage() = saveThen { onOpenFullPage(taskId) }

    BackHandler(enabled = openSheet == null, onBack = ::handleCollapse)

    val titleFocus = remember(taskId) { FocusRequester() }

    val taskFields = data?.task?.fields.orEmpty()
    val deleted = data?.task?.deletedAt != null
    val status = taskFields[RegistryEntityFields.Task.STATUS].stringValue()
    val isCompleted = if (data != null) status == RegistryEntityEnums.TaskStatus.DONE else fallbackCompleted
    val isStarred = taskFields[RegistryEntityFields.Task.STARRED].booleanValue() == true
    val scheduled = taskFields[RegistryEntityFields.Task.SCHEDULED].stringValue()
    val isToday = taskFields[RegistryEntityFields.Task.TODAY].booleanValue() == true
    val startTime = taskFields[RegistryEntityFields.Task.START_TIME].stringValue()
    val durationMinutes = taskFields[RegistryEntityFields.Task.DURATION_MINUTES].longValue()?.toInt()
    val timeSlotText = TaskTimeSlot.format(startTime, durationMinutes)
    val todayDate = graph.clock.today(graph.clock.now())
    val todayLabel = RegistryCatalog.destinationTitle(RegistryDestinationIds.TODAY, languageTag).orEmpty()
    val tomorrowLabel = RegistryCatalog.tomorrowLabel(languageTag)
    val whenDateText = when {
        isToday -> todayLabel
        scheduled != null -> runCatching { LocalDate.parse(scheduled.take(10)) }.getOrNull()
            ?.let { formatShortLocalDay(it, todayDate, todayLabel, tomorrowLabel, languageTag) }
            ?: formatDay(scheduled, languageTag)
        else -> null
    }
    val whenShortValue = when {
        whenDateText != null && timeSlotText != null -> "$whenDateText · $timeSlotText"
        whenDateText != null -> whenDateText
        timeSlotText != null -> timeSlotText
        else -> null
    }
    val deadline = taskFields[RegistryEntityFields.Task.DEADLINE].stringValue()
    val deadlineIsOverdue = deadline?.let {
        runCatching { !LocalDate.parse(it.take(10)).isAfter(todayDate) }.getOrDefault(false)
    } ?: false
    val deadlineShortValue = deadline?.let {
        runCatching { LocalDate.parse(it.take(10)) }.getOrNull()
            ?.let { d -> formatShortLocalDay(d, todayDate, todayLabel, tomorrowLabel, languageTag) }
            ?: formatDay(it, languageTag)
    }
    val reminderAt = taskFields[RegistryEntityFields.Task.REMINDER_AT].stringValue()
    val reminderMode = taskFields[RegistryEntityFields.Task.REMINDER_MODE].stringValue()
    val reminderShortValue = reminderAt?.let {
        formatReminder(
            reminderAt = it,
            reminderMode = reminderMode,
            snoozedUntil = taskFields[RegistryEntityFields.Task.REMINDER_SNOOZED_UNTIL].stringValue(),
            today = todayDate,
            languageTag = languageTag,
        )
    }
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
    val repeatSummary = labels.repeatUnits.firstOrNull { it.value == repeatUnit }?.title?.let { unitTitle ->
        if (repeatInterval > 1L) "$repeatInterval × $unitTitle" else unitTitle
    }
    val selectedProjectId = taskFields[RegistryEntityFields.Task.PROJECT].stringValue()
    val selectedProject = data?.projects?.firstOrNull { it.id == selectedProjectId }
    val selectedAreaId = taskFields[RegistryEntityFields.Task.AREA].stringValue()
        ?: selectedProject?.parentAreaId
    val selectedArea = data?.areas?.firstOrNull { it.id == selectedAreaId }
    val listShortValue = selectedProject?.title ?: selectedArea?.title

    // A draft's title tokens, offered while the draft has no stored title yet and only
    // for fields still unset (Apple `detectedTokens` / `isUnset`). `# Name` in a project
    // makes a heading instead, so it offers nothing.
    val storedTitle = taskFields[RegistryEntityFields.Task.TITLE].stringValue().orEmpty()
    val rawAreaId = taskFields[RegistryEntityFields.Task.AREA].stringValue()
    val draftTokens = if (!isDraft || data == null || storedTitle.isNotBlank() ||
        (selectedProjectId != null && InlineTitleTokens.headingTitle(titleDraft.trim()) != null)
    ) {
        emptyList()
    } else {
        InlineTitleTokens.detect(
            raw = titleDraft,
            projects = data?.projects.orEmpty().map { it.id to it.title },
            areas = data?.areas.orEmpty().map { it.id to it.title },
            today = todayDate,
        ).filter { token ->
            when (token.kind) {
                InlineTitleTokens.Kind.Today, InlineTitleTokens.Kind.Date -> !isToday && scheduled == null
                InlineTitleTokens.Kind.Project -> selectedProjectId == null
                InlineTitleTokens.Kind.Area -> rawAreaId == null && selectedProjectId == null
            }
        }
    }
    val tomorrowLabel = RegistryCatalog.tomorrowLabel(languageTag)
    val chipDayFormat = remember(languageTag) {
        java.time.format.DateTimeFormatter.ofPattern("MMM d", java.util.Locale.forLanguageTag(languageTag))
    }
    fun tokenLabel(token: InlineTitleTokens.Detected): String = when (token.kind) {
        InlineTitleTokens.Kind.Today -> todayLabel
        InlineTitleTokens.Kind.Date -> when (token.day) {
            todayDate -> todayLabel
            todayDate.plusDays(1) -> tomorrowLabel
            else -> token.day?.let(chipDayFormat::format).orEmpty()
        }
        InlineTitleTokens.Kind.Project, InlineTitleTokens.Kind.Area -> token.title.orEmpty()
    }
    val selectedTagIds = (taskFields[RegistryEntityFields.Task.TAGS] as? JsonValue.ArrayValue)
        ?.values?.mapNotNull { it.stringValue() }.orEmpty()
    val selectedTagNames = data?.tags.orEmpty().filter { it.id in selectedTagIds }.map(TagLine::name)
    val tagsShortValue = when (selectedTagNames.size) {
        0 -> null
        1 -> selectedTagNames[0]
        else -> "${selectedTagNames[0]} +${selectedTagNames.size - 1}"
    }
    val checklistItems = data?.checklist.orEmpty()
    val checklistDone = checklistItems.count(ChecklistLine::checked)
    val checklistSummary = if (checklistItems.isNotEmpty()) "$checklistDone/${checklistItems.size}" else null
    val attachmentCount = data?.attachmentCount ?: 0

    val savedTask = data?.task
    val canEdit = savedTask != null && !deleted && !saving
    // A new draft opens with the keyboard on its title (Apple focuses deferred-create drafts only).
    // Keyed on the load: the field takes focus once it can be edited.
    val draftCanFocus = isDraft && savedTask != null && !deleted
    LaunchedEffect(taskId, draftCanFocus) {
        if (draftCanFocus) runCatching { titleFocus.requestFocus() }
    }
    val completeAction = RegistryCatalog.actionTitle(RegistryActionIds.TASK_TOGGLE_COMPLETE, languageTag = languageTag).orEmpty()
    val openAction = RegistryCatalog.actionTitle(RegistryActionIds.TASK_OPEN, languageTag = languageTag).orEmpty()
    val collapseAction = RegistryCatalog.actionTitle(RegistryActionIds.DO_DONE, languageTag = languageTag).orEmpty()
    val addChecklistAction = RegistryCatalog.actionTitle(RegistryActionIds.TASK_ADD_CHECKLIST_ITEM, languageTag = languageTag).orEmpty()
    val toggleChecklistAction = RegistryCatalog.actionTitle(RegistryActionIds.TASK_TOGGLE_CHECKLIST_ITEM, languageTag = languageTag).orEmpty()
    val deleteChecklistAction = RegistryCatalog.actionTitle(RegistryActionIds.TASK_DELETE_CHECKLIST_ITEM, languageTag = languageTag).orEmpty()
    val repeatPauseAction = RegistryCatalog.actionTitle(
        RegistryActionIds.TASK_PAUSE_RESUME_REPEAT,
        field = if (recurrencePaused) "activeTitle" else "title",
        languageTag = languageTag,
    ).orEmpty()

    val accent = MaterialTheme.colorScheme.primary
    val todayGold = MaterialTheme.colorScheme.secondary
    val mutedInk = MaterialTheme.colorScheme.onSurfaceVariant
    val overdueRed = if (isDark) Color(0xFFFF453A) else Color(0xFFFF3B30)

    fun save(gesture: suspend () -> Unit) {
        if (!canEdit) return
        scope.launch {
            saving = true
            saveFailed = false
            runCatching {
                withContext(Dispatchers.IO) { gesture() }
            }.onSuccess {
                graph.sync.noteLocalChange()
                graph.sync.requestSync()
            }.onFailure {
                saveFailed = true
            }
            saving = false
        }
    }

    fun write(block: suspend () -> Unit) = save { graph.captureTaskEdit(taskId, mutation = block) }

    fun writeChecklist(block: suspend () -> Unit) = save {
        block()
        graph.touchTask(taskId)
    }

    /** Applies a chip's field to the draft and takes its words out of the title (Apple `applyToken`). */
    fun applyDraftToken(token: InlineTitleTokens.Detected) {
        save {
            when (token.kind) {
                InlineTitleTokens.Kind.Today -> check(graph.taskMutator.setToday(taskId, enabled = true) != null)
                InlineTitleTokens.Kind.Date -> token.day?.let { check(graph.taskMutator.setWhen(taskId, it.toString()) != null) }
                InlineTitleTokens.Kind.Project ->
                    check(graph.taskMutator.moveToList(taskId, area = null, project = token.id) != null)
                InlineTitleTokens.Kind.Area ->
                    check(graph.taskMutator.moveToList(taskId, area = token.id, project = null) != null)
            }
        }
        titleDraft = InlineTitleTokens.removing(token.phrase, titleDraft)
        textIsDirty = true
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
            save { check(graph.completeTask(taskId)) }
            onCollapse()
        }
    }

    fun toggleStarred() = write { check(graph.taskMutator.setStarred(taskId, !isStarred) != null) }

    fun setWhen(
        day: String?,
        mode: app.septena.sharedcore.RescheduleMode = app.septena.sharedcore.RescheduleMode.MAKE_EXCEPTION,
    ) = write { check(graph.taskMutator.setWhen(taskId, day, mode) != null) }

    fun setTimeSlot(start: String?, duration: Int?) {
        val zone = start?.let { ZoneId.systemDefault().id }
        write { check(graph.taskMutator.setTimeSlot(taskId, start, duration?.toLong(), zone) != null) }
    }

    fun setDeadline(day: String?) = write { check(graph.taskMutator.setDeadline(taskId, day) != null) }

    fun setReminder(at: String?, mode: String?) = write { check(graph.taskMutator.setReminder(taskId, at, mode) != null) }

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

    fun setTag(tagId: String, selected: Boolean) {
        write {
            val currentTask = graph.taskStore.record(RegistryEntityNames.TASK, taskId) ?: error("Task is unavailable")
            val currentIds = (currentTask.fields[RegistryEntityFields.Task.TAGS] as? JsonValue.ArrayValue)
                ?.values?.mapNotNull { it.stringValue() }.orEmpty()
            val nextIds = if (selected) (currentIds + tagId).distinct() else currentIds - tagId
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
                }
            }.onSuccess {
                tagFilterDraft = ""
                graph.sync.noteLocalChange()
                graph.sync.requestSync()
            }.onFailure { saveFailed = true }
            saving = false
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
                    } else null,
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

    fun setRepeatPaused(paused: Boolean) = write {
        check(
            graph.taskMutator.updateFields(
                taskId,
                mapOf(RegistryEntityFields.Task.RECURRENCE_PAUSED to JsonValue.BooleanValue(paused)),
            ) != null,
        )
    }

    fun addChecklistItem() {
        if (!canEdit) return
        if (checklistItems.size.toLong() >= RegistryEntityLimits.MAX_CHECKLIST_ITEMS_PER_TASK) return
        val nextPosition = checklistItems.maxOfOrNull(ChecklistLine::position)?.plus(1.0) ?: 0.0
        writeChecklist {
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

    fun saveChecklistTitle(item: ChecklistLine) {
        val title = checklistDrafts[item.id]?.trim().orEmpty()
        if (title == item.title) return
        writeChecklist {
            check(
                graph.registryEntityMutator.update(
                    RegistryEntityNames.CHECKLIST_ITEM,
                    item.id,
                    mapOf(RegistryEntityFields.ChecklistItem.TITLE to JsonValue.StringValue(title)),
                ) != null,
            )
        }
    }

    pendingRescheduleDay?.let { day ->
        RescheduleFixedRepeatDialog(
            languageTag = languageTag,
            onPickMode = { mode ->
                pendingRescheduleDay = null
                setWhen(day, mode)
            },
            onDismiss = { pendingRescheduleDay = null },
        )
    }

    val blockKinds = remember(inlineBlocks) { inlineBlocks.map { it.kind }.toSet() }
    val showChecklistBlock = TaskPageBlockKinds.CHECKLIST in blockKinds && (checklistOpened || checklistItems.isNotEmpty())
    val showAttachmentsBlock = TaskPageBlockKinds.ATTACHMENTS in blockKinds && attachmentsOpened
    val showReferencesBlock = TaskPageBlockKinds.REFERENCES in blockKinds && savedTask != null
    val canAddMoreChecklist = checklistItems.size.toLong() < RegistryEntityLimits.MAX_CHECKLIST_ITEMS_PER_TASK

    TaskCardSlice(
        position = position,
        isSelected = false,
        isDark = isDark,
        hasActiveTexture = hasActiveTexture,
        modifier = modifier,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = TaskCardMetrics.ContentInset, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (TaskPageBlockKinds.HEADER in blockKinds) {
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
                                fontSize = 16.sp,
                                lineHeight = 21.sp,
                                fontWeight = FontWeight.Medium,
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
                            textStyle = MaterialTheme.typography.bodyLarge.copy(
                                fontSize = 16.sp,
                                lineHeight = 21.sp,
                                fontWeight = FontWeight.Medium,
                                color = if (isCompleted) mutedInk.copy(alpha = 0.72f) else MaterialTheme.colorScheme.onSurface,
                                textDecoration = if (isCompleted) TextDecoration.LineThrough else TextDecoration.None,
                            ),
                            cursorBrush = SolidColor(accent),
                            maxLines = 4,
                            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                            keyboardActions = KeyboardActions(onDone = { handleCollapse() }),
                            modifier = Modifier
                                .fillMaxWidth()
                                .focusRequester(titleFocus)
                                .semantics { contentDescription = labels.field(RegistryTaskDetail.Fields.TITLE) },
                        )
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        IconButton(
                            onClick = ::handleOpenFullPage,
                            enabled = !saving,
                            modifier = Modifier
                                .size(34.dp)
                                .semantics { contentDescription = openAction },
                        ) {
                            OpenTaskPageGlyph(tint = mutedInk, size = 16.dp)
                        }
                        IconButton(
                            onClick = ::handleCollapse,
                            enabled = !saving,
                            modifier = Modifier
                                .size(34.dp)
                                .semantics { contentDescription = collapseAction },
                        ) {
                            ChevronUpGlyph(tint = mutedInk, size = 15.dp)
                        }
                    }
                }
            }

            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = TaskCardMetrics.LeadingColumnWidth + TaskCardMetrics.IconTextGap),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                if (draftTokens.isNotEmpty()) {
                    // Tap-to-apply chips for what the draft's title names (Apple `quickEntryChips`).
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        draftTokens.forEach { token ->
                            InlineAttributePill(
                                label = tokenLabel(token),
                                isSet = false,
                                isActive = false,
                                isDark = isDark,
                                enabled = canEdit,
                                tint = accent,
                                icon = { tint ->
                                    when (token.kind) {
                                        InlineTitleTokens.Kind.Today ->
                                            SeptenaGlyph(kind = SeptenaIconKind.Today, tint = tint, size = 13.dp)
                                        InlineTitleTokens.Kind.Date -> CalendarSmallGlyph(tint = tint, size = 13.dp)
                                        InlineTitleTokens.Kind.Project ->
                                            SeptenaGlyph(kind = SeptenaIconKind.Project, tint = tint, size = 13.dp)
                                        InlineTitleTokens.Kind.Area ->
                                            SeptenaGlyph(kind = SeptenaIconKind.Area, tint = tint, size = 13.dp)
                                    }
                                },
                                onClick = { applyDraftToken(token) },
                            )
                        }
                    }
                }

                if (TaskPageBlockKinds.NOTES in blockKinds) {
                    val notesLabel = labels.field(RegistryTaskDetail.Fields.NOTES)
                    Box(modifier = Modifier.fillMaxWidth()) {
                        if (notesDraft.isEmpty()) {
                            Text(
                                text = notesLabel,
                                fontSize = 14.5.sp,
                                lineHeight = 20.sp,
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
                            textStyle = MaterialTheme.typography.bodyMedium.copy(
                                fontSize = 14.5.sp,
                                lineHeight = 20.sp,
                                color = MaterialTheme.colorScheme.onSurface,
                            ),
                            cursorBrush = SolidColor(accent),
                            minLines = 1,
                            maxLines = 6,
                            modifier = Modifier
                                .fillMaxWidth()
                                .semantics { contentDescription = notesLabel },
                        )
                    }
                }

                if (showChecklistBlock) {
                    Column(
                        modifier = Modifier.fillMaxWidth(),
                        verticalArrangement = Arrangement.spacedBy(2.dp),
                    ) {
                        checklistItems.forEach { item ->
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
                                    writeChecklist {
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
                                    writeChecklist { check(graph.registryEntityMutator.delete(RegistryEntityNames.CHECKLIST_ITEM, item.id) != null) }
                                },
                                horizontalPadding = 0.dp,
                            )
                        }
                        if (canEdit && canAddMoreChecklist) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable(onClick = ::addChecklistItem)
                                    .padding(vertical = 6.dp),
                            ) {
                                Box(
                                    contentAlignment = Alignment.Center,
                                    modifier = Modifier.width(TaskCardMetrics.LeadingColumnWidth),
                                ) {
                                    PlusSmallGlyph(tint = accent, size = 14.dp)
                                }
                                Spacer(modifier = Modifier.width(TaskCardMetrics.IconTextGap))
                                Text(
                                    text = addChecklistAction,
                                    fontSize = 14.sp,
                                    lineHeight = 18.sp,
                                    color = accent,
                                )
                            }
                        }
                    }
                }

                if (showReferencesBlock) {
                    TaskReferencesSection(
                        graph = graph,
                        taskId = taskId,
                        heading = null,
                        canEdit = canEdit,
                        taskTitle = titleDraft,
                        taskNotes = notesDraft,
                        showAddDialog = false,
                        onShowAddDialogChange = {},
                        onOpenTask = { targetId -> saveThen { onOpenFullPage(targetId) } },
                        embedded = true,
                    )
                }

                if (TaskPageBlockKinds.ATTRIBUTES in blockKinds) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        attributes.forEach { attribute ->
                            when (attribute.id) {
                                RegistryTaskAttributeIds.WHEN -> InlineAttributePill(
                                    label = whenShortValue ?: attribute.label,
                                    isSet = whenShortValue != null,
                                    isActive = openSheet == RegistryTaskAttributeIds.WHEN,
                                    isDark = isDark,
                                    enabled = canEdit,
                                    tint = if (isToday) todayGold else accent,
                                    icon = { tint ->
                                        if (isToday) {
                                            SeptenaGlyph(kind = SeptenaIconKind.Today, tint = tint, size = 13.dp)
                                        } else {
                                            CalendarSmallGlyph(tint = tint, size = 13.dp)
                                        }
                                    },
                                    onClick = { openSheet = RegistryTaskAttributeIds.WHEN },
                                )

                                RegistryTaskAttributeIds.DEADLINE -> InlineAttributePill(
                                    label = deadlineShortValue ?: attribute.label,
                                    isSet = deadline != null,
                                    isActive = openSheet == RegistryTaskAttributeIds.DEADLINE,
                                    isDark = isDark,
                                    enabled = canEdit,
                                    tint = if (deadlineIsOverdue) overdueRed else accent,
                                    icon = { tint -> DeadlineFlagGlyph(tint = tint, size = 12.dp) },
                                    onClick = { openSheet = RegistryTaskAttributeIds.DEADLINE },
                                )

                                RegistryTaskAttributeIds.REMINDER -> InlineAttributePill(
                                    label = reminderShortValue ?: attribute.label,
                                    isSet = reminderAt != null,
                                    isActive = openSheet == RegistryTaskAttributeIds.REMINDER,
                                    isDark = isDark,
                                    enabled = canEdit,
                                    tint = accent,
                                    icon = { tint -> BellSmallGlyph(tint = tint, size = 12.dp) },
                                    onClick = { openSheet = RegistryTaskAttributeIds.REMINDER },
                                )

                                RegistryTaskAttributeIds.REPEAT -> InlineAttributePill(
                                    label = repeatSummary ?: attribute.label,
                                    isSet = repeatUnit != null,
                                    isActive = openSheet == RegistryTaskAttributeIds.REPEAT,
                                    isDark = isDark,
                                    enabled = canEdit,
                                    tint = accent,
                                    icon = { tint -> RepeatSmallGlyph(tint = tint, size = 12.dp) },
                                    onClick = {
                                        if (repeatUnit == null) setRepeat(RegistryEntityEnums.RecurrenceUnit.WEEK)
                                        openSheet = RegistryTaskAttributeIds.REPEAT
                                    },
                                )

                                RegistryTaskAttributeIds.STAR -> InlineAttributePill(
                                    label = attribute.label,
                                    isSet = isStarred,
                                    isActive = false,
                                    isDark = isDark,
                                    enabled = canEdit,
                                    tint = todayGold,
                                    icon = { tint -> StarGlyph(filled = isStarred, tint = tint, size = 13.dp) },
                                    onClick = ::toggleStarred,
                                )

                                RegistryTaskAttributeIds.LIST -> InlineAttributePill(
                                    label = listShortValue ?: attribute.label,
                                    isSet = listShortValue != null,
                                    isActive = openSheet == RegistryTaskAttributeIds.LIST,
                                    isDark = isDark,
                                    enabled = canEdit,
                                    tint = accent,
                                    icon = { tint ->
                                        SeptenaGlyph(
                                            kind = if (selectedProject != null) SeptenaIconKind.Project else SeptenaIconKind.Area,
                                            tint = tint,
                                            size = 13.dp,
                                        )
                                    },
                                    onClick = { openSheet = RegistryTaskAttributeIds.LIST },
                                )

                                RegistryTaskAttributeIds.TAGS -> InlineAttributePill(
                                    label = tagsShortValue ?: attribute.label,
                                    isSet = selectedTagNames.isNotEmpty(),
                                    isActive = openSheet == RegistryTaskAttributeIds.TAGS,
                                    isDark = isDark,
                                    enabled = canEdit,
                                    tint = accent,
                                    icon = { tint -> TagSmallGlyph(tint = tint, size = 12.dp) },
                                    onClick = { openSheet = RegistryTaskAttributeIds.TAGS },
                                )

                                RegistryTaskAttributeIds.CHECKLIST -> if (TaskPageBlockKinds.CHECKLIST in blockKinds) {
                                    InlineAttributePill(
                                        label = checklistSummary ?: attribute.label,
                                        isSet = checklistItems.isNotEmpty(),
                                        isActive = showChecklistBlock,
                                        isDark = isDark,
                                        enabled = canEdit,
                                        tint = accent,
                                        icon = { tint -> ChecklistSmallGlyph(tint = tint, size = 12.dp) },
                                        onClick = {
                                            if (showChecklistBlock) {
                                                addChecklistItem()
                                            } else {
                                                checklistOpened = true
                                                if (checklistItems.isEmpty()) addChecklistItem()
                                            }
                                        },
                                    )
                                }

                                RegistryTaskAttributeIds.ATTACHMENTS -> if (TaskPageBlockKinds.ATTACHMENTS in blockKinds) {
                                    InlineAttributePill(
                                        label = if (attachmentCount > 0) attachmentCount.toString() else attribute.label,
                                        isSet = attachmentCount > 0,
                                        isActive = attachmentsOpened,
                                        isDark = isDark,
                                        enabled = canEdit,
                                        tint = accent,
                                        icon = { tint -> AttachmentSmallGlyph(tint = tint, size = 12.dp) },
                                        onClick = { attachmentsOpened = !attachmentsOpened },
                                    )
                                }

                                RegistryTaskAttributeIds.DISCUSS -> InlineAttributePill(
                                    label = attribute.label,
                                    isSet = false,
                                    isActive = false,
                                    isDark = isDark,
                                    enabled = !saving,
                                    tint = accent,
                                    icon = { tint -> AgentSparkleBubbleGlyph(tint = tint, size = 13.dp) },
                                    onClick = ::handleOpenFullPage,
                                )

                                else -> Unit
                            }
                        }
                    }
                }

                if (showAttachmentsBlock && savedTask != null) {
                    TaskAttachmentsSection(
                        graph = graph,
                        taskId = taskId,
                        heading = null,
                        canEdit = canEdit,
                        control = labels::control,
                        embedded = true,
                    )
                }

                if (saveFailed) {
                    Text(
                        text = labels.saveError,
                        color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        }
    }

    openSheet?.let { sheetAttr ->
        val sheetLabel = attributes.firstOrNull { it.id == sheetAttr }?.label.orEmpty()
        ModalBottomSheet(
            onDismissRequest = { openSheet = null },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .navigationBarsPadding()
                    .padding(bottom = 24.dp),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                ) {
                    Text(
                        text = sheetLabel,
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.weight(1f),
                    )
                    if (sheetAttr == RegistryTaskAttributeIds.REPEAT) {
                        Switch(
                            checked = repeatUnit != null,
                            onCheckedChange = { on ->
                                if (on) setRepeat(repeatUnit ?: RegistryEntityEnums.RecurrenceUnit.WEEK)
                                else {
                                    setRepeat(null)
                                    openSheet = null
                                }
                            },
                            enabled = canEdit,
                        )
                    }
                }
                HorizontalDivider(
                    thickness = 0.5.dp,
                    color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f),
                )
                when (sheetAttr) {
                    RegistryTaskAttributeIds.WHEN -> TaskDateBoard(
                        attribute = RegistryTaskAttributeIds.WHEN,
                        initialDay = scheduled ?: if (isToday) todayDate.toString() else null,
                        today = todayDate,
                        languageTag = languageTag,
                        enabled = canEdit,
                        onSelect = { day ->
                            openSheet = null
                            if (app.septena.core.TaskMutator.needsFixedRepeatReschedulePrompt(taskFields, day)) {
                                pendingRescheduleDay = day
                            } else {
                                setWhen(day)
                            }
                        },
                        onClear = { openSheet = null; setWhen(null) },
                        startTime = startTime,
                        durationMinutes = durationMinutes,
                        onTimeSlotChange = { start, dur -> setTimeSlot(start, dur) },
                    )

                    RegistryTaskAttributeIds.DEADLINE -> TaskDateBoard(
                        attribute = RegistryTaskAttributeIds.DEADLINE,
                        initialDay = deadline,
                        today = todayDate,
                        languageTag = languageTag,
                        enabled = canEdit,
                        onSelect = { day -> openSheet = null; setDeadline(day) },
                        onClear = { openSheet = null; setDeadline(null) },
                    )

                    RegistryTaskAttributeIds.REMINDER -> TaskReminderPicker(
                        graph = graph,
                        reminderAt = reminderAt,
                        reminderMode = reminderMode,
                        enabled = canEdit,
                        control = labels::control,
                        onSet = { at, mode -> openSheet = null; setReminder(at, mode) },
                        onClear = { openSheet = null; setReminder(null, null) },
                    )

                    RegistryTaskAttributeIds.REPEAT -> if (repeatUnit != null) {
                        Spacer(modifier = Modifier.size(8.dp))
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

                    RegistryTaskAttributeIds.LIST -> {
                        Text(
                            text = labels.field(RegistryTaskDetail.Fields.AREA),
                            fontSize = 12.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = mutedInk,
                            modifier = Modifier.padding(horizontal = 14.dp, vertical = 6.dp),
                        )
                        ChoiceRow(
                            title = labels.noArea,
                            selected = selectedAreaId == null,
                            enabled = canEdit,
                            onClick = { openSheet = null; moveToArea(null) },
                        )
                        data?.areas.orEmpty().forEach { area ->
                            ChoiceRow(
                                title = area.title,
                                selected = area.id == selectedAreaId,
                                enabled = canEdit,
                                onClick = { openSheet = null; moveToArea(area.id) },
                            )
                        }
                        Text(
                            text = labels.field(RegistryTaskDetail.Fields.PROJECT),
                            fontSize = 12.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = mutedInk,
                            modifier = Modifier.padding(start = 14.dp, end = 14.dp, top = 8.dp, bottom = 4.dp),
                        )
                        ChoiceRow(
                            title = labels.noProject,
                            selected = selectedProjectId == null,
                            enabled = canEdit,
                            onClick = { openSheet = null; moveToProject(null) },
                        )
                        data?.projects.orEmpty().forEach { project ->
                            ChoiceRow(
                                title = project.title,
                                selected = project.id == selectedProjectId,
                                enabled = canEdit,
                                onClick = { openSheet = null; moveToProject(project.id) },
                            )
                        }
                    }

                    RegistryTaskAttributeIds.TAGS -> {
                        val tagLabels = taskTagPickerLabels(languageTag)
                        Spacer(modifier = Modifier.size(8.dp))
                        OutlinedTextField(
                            value = tagFilterDraft,
                            onValueChange = { tagFilterDraft = it.take(RegistryEntityLimits.TAG_NAME_MAX.toInt()) },
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
                                modifier = Modifier.padding(horizontal = 14.dp, vertical = 6.dp),
                            ) {
                                filteredTags.forEach { tag ->
                                    FilterChip(
                                        selected = tag.id in selectedTagIds,
                                        onClick = { setTag(tag.id, tag.id !in selectedTagIds) },
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
            }
        }
    }
}

@Composable
private fun InlineAttributePill(
    label: String,
    isSet: Boolean,
    isActive: Boolean,
    isDark: Boolean,
    enabled: Boolean,
    tint: Color,
    icon: @Composable (Color) -> Unit,
    onClick: () -> Unit,
) {
    val mutedInk = MaterialTheme.colorScheme.onSurfaceVariant
    val bg = when {
        isActive -> tint.copy(alpha = if (isDark) 0.24f else 0.16f)
        isSet -> tint.copy(alpha = if (isDark) 0.16f else 0.11f)
        isDark -> Color.White.copy(alpha = 0.08f)
        else -> MaterialTheme.colorScheme.onSurface.copy(alpha = 0.055f)
    }
    val rim = when {
        isActive || isSet -> tint.copy(alpha = if (isDark) 0.36f else 0.26f)
        isDark -> Color.White.copy(alpha = 0.11f)
        else -> MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f)
    }
    val contentTint = if (isSet || isActive) tint else mutedInk
    Surface(
        color = bg,
        shape = CircleShape,
        modifier = Modifier
            .clip(CircleShape)
            .border(0.6.dp, rim, CircleShape)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
        ) {
            icon(contentTint)
            Text(
                text = label,
                fontSize = 12.5.sp,
                lineHeight = 15.sp,
                fontWeight = if (isSet || isActive) FontWeight.Medium else FontWeight.Normal,
                color = if (isSet || isActive) MaterialTheme.colorScheme.onSurface else mutedInk,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}
