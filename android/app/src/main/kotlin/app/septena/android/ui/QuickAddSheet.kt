package app.septena.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ListItem
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.generated.RegistryActionIds
import app.septena.core.generated.RegistryDestinationIds
import app.septena.core.generated.RegistryTaskAttributeIds
import app.septena.core.generated.RegistryTaskDetail
import app.septena.core.stringValue
import app.septena.ui.DoGlyph
import java.time.LocalDate

/**
 * The Quick Add sheet: title, notes, then the registry's draft attributes
 * (`taskAttributes` that are not editOnly) that Android can edit here: When,
 * deadline, Favorite and list. Tags are editOnly, so they stay on the task
 * page, as on iPhone. An empty list files to the Inbox.
 */
@Composable
@OptIn(ExperimentalMaterial3Api::class)
fun QuickAddSheet(
    today: LocalDate,
    errorMessage: String?,
    areas: List<TaskHomeNavigationItem>,
    projects: List<TaskHomeNavigationItem>,
    languageTag: String,
    initialDraft: QuickAddDraft = QuickAddDraft(),
    onDismiss: () -> Unit,
    onAdd: (QuickAddDraft) -> Unit,
    /** Add and Do, for work that is not on the list yet. Null hides it. */
    onAddAndDo: ((QuickAddDraft) -> Unit)? = null,
) {
    val labels = remember(languageTag) { TaskFormLabels.fromRegistry(languageTag) }
    val attributes = remember(languageTag) { RegistryCatalog.taskAttributes(languageTag).filterNot { it.editOnly } }
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var draft by rememberSaveable(initialDraft, stateSaver = QuickAddDraftSaver) { mutableStateOf(initialDraft) }
    var openAttribute by rememberSaveable { mutableStateOf<String?>(null) }
    val titleFocus = remember { FocusRequester() }
    val canAdd = draft.title.isNotBlank()
    val submit: () -> Unit = { if (canAdd) onAdd(draft) }
    val toggle: (String) -> Unit = { id -> openAttribute = if (openAttribute == id) null else id }

    LaunchedEffect(Unit) { runCatching { titleFocus.requestFocus() } }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(bottom = 24.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TextButton(onClick = onDismiss) { Text(labels.cancel) }
                Text(
                    text = labels.sheetTitle,
                    style = MaterialTheme.typography.titleMedium,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.weight(1f).padding(horizontal = 8.dp),
                )
                TextButton(onClick = submit, enabled = canAdd) { Text(labels.add) }
            }
            errorMessage?.let {
                Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(horizontal = 16.dp))
            }
            OutlinedTextField(
                value = draft.title,
                onValueChange = { draft = draft.copy(title = it) },
                label = { Text(labels.title) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { submit() }),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 4.dp)
                    .focusRequester(titleFocus),
            )
            attributes.forEach { attribute ->
                when (attribute.id) {
                    RegistryTaskAttributeIds.NOTES -> OutlinedTextField(
                        value = draft.notes,
                        onValueChange = { draft = draft.copy(notes = it) },
                        label = { Text(attribute.label) },
                        minLines = 2,
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                    )
                    RegistryTaskAttributeIds.WHEN -> {
                        FormValueRow(
                            label = attribute.label,
                            value = draft.whenDay?.let { formatDay(it, languageTag) } ?: labels.noDate,
                            onClick = { toggle(attribute.id) },
                        )
                        if (openAttribute == attribute.id) {
                            TaskDateBoard(
                                attribute = attribute.id,
                                initialDay = draft.whenDay,
                                today = today,
                                languageTag = languageTag,
                                enabled = true,
                                onSelect = { day -> draft = draft.copy(whenDay = day); openAttribute = null },
                                onClear = { draft = draft.copy(whenDay = null); openAttribute = null },
                            )
                        }
                    }
                    RegistryTaskAttributeIds.DEADLINE -> {
                        FormValueRow(
                            label = attribute.label,
                            value = draft.deadline?.let { formatDay(it, languageTag) } ?: labels.noDate,
                            onClick = { toggle(attribute.id) },
                        )
                        if (openAttribute == attribute.id) {
                            TaskDateBoard(
                                attribute = attribute.id,
                                initialDay = draft.deadline,
                                today = today,
                                languageTag = languageTag,
                                enabled = true,
                                onSelect = { day -> draft = draft.copy(deadline = day); openAttribute = null },
                                onClear = { draft = draft.copy(deadline = null); openAttribute = null },
                            )
                        }
                    }
                    RegistryTaskAttributeIds.STAR -> ListItem(
                        headlineContent = { Text(attribute.label) },
                        trailingContent = { Switch(checked = draft.starred, onCheckedChange = null) },
                        modifier = Modifier.fillMaxWidth().toggleable(
                            value = draft.starred,
                            role = Role.Switch,
                            onValueChange = { draft = draft.copy(starred = it) },
                        ),
                    )
                    RegistryTaskAttributeIds.LIST -> FormValueRow(
                        label = attribute.label,
                        value = listTitle(draft.areaId, draft.projectId, areas, projects) ?: labels.inbox,
                        onClick = { openAttribute = attribute.id },
                    )
                    // Paste, reminder and repeat have no draft editor on Android yet.
                    else -> Unit
                }
            }
            onAddAndDo?.let { addAndDo ->
                val title = remember(languageTag) {
                    RegistryCatalog.actionTitle(RegistryActionIds.DO_ADD_AND_DO, languageTag = languageTag).orEmpty()
                }
                TextButton(
                    onClick = { addAndDo(draft) },
                    enabled = canAdd,
                    modifier = Modifier.padding(horizontal = 8.dp),
                ) {
                    DoGlyph(tint = LocalContentColor.current, size = 18.dp)
                    Text(title, modifier = Modifier.padding(start = 8.dp))
                }
            }
        }
    }

    if (openAttribute == RegistryTaskAttributeIds.LIST) {
        TaskListPickerDialog(
            title = attributes.firstOrNull { it.id == RegistryTaskAttributeIds.LIST }?.label.orEmpty(),
            areaId = draft.areaId,
            projectId = draft.projectId,
            areas = areas,
            projects = projects,
            labels = labels,
            onDismiss = { openAttribute = null },
            onPick = { areaId, projectId ->
                draft = draft.copy(areaId = areaId, projectId = projectId)
                openAttribute = null
            },
        )
    }
}

/** Keeps a half-typed task through a rotation. */
private val QuickAddDraftSaver: Saver<QuickAddDraft, Any> = listSaver<QuickAddDraft, Any?>(
    save = {
        listOf(
            it.title, it.notes, it.whenDay, it.deadline, it.starred,
            it.areaId, it.projectId, it.headingId, it.today, it.position, it.useTodayPosition,
        )
    },
    restore = {
        QuickAddDraft(
            title = it[0] as String,
            notes = it[1] as String,
            whenDay = it[2] as String?,
            deadline = it[3] as String?,
            starred = it[4] as Boolean,
            areaId = it[5] as String?,
            projectId = it[6] as String?,
            headingId = it[7] as String?,
            today = it[8] as Boolean,
            position = it[9] as Double?,
            useTodayPosition = it[10] as Boolean,
        )
    },
)

@Composable
private fun FormValueRow(label: String, value: String, onClick: () -> Unit) {
    ListItem(
        headlineContent = { Text(label) },
        trailingContent = { Text(value, color = MaterialTheme.colorScheme.onSurfaceVariant) },
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick),
    )
}

/** When for a selection: the shared date board in a sheet. [onPick] gets null for Clear. */
@Composable
@OptIn(ExperimentalMaterial3Api::class)
fun TaskWhenSheet(
    today: LocalDate,
    languageTag: String,
    onDismiss: () -> Unit,
    onPick: (String?) -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
    ) {
        Column(modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(bottom = 24.dp)) {
            TaskDateBoard(
                attribute = RegistryTaskAttributeIds.WHEN,
                initialDay = null,
                today = today,
                languageTag = languageTag,
                enabled = true,
                onSelect = onPick,
                onClear = { onPick(null) },
            )
        }
    }
}

/**
 * Picks where tasks live: the Inbox (no area, no project), an area or a
 * project. [onPick] gets (areaId, projectId); at most one is set.
 */
@Composable
fun TaskListPickerDialog(
    title: String,
    areaId: String?,
    projectId: String?,
    showsCurrent: Boolean = true,
    areas: List<TaskHomeNavigationItem>,
    projects: List<TaskHomeNavigationItem>,
    labels: TaskFormLabels,
    onDismiss: () -> Unit,
    onPick: (String?, String?) -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(modifier = Modifier.verticalScroll(rememberScrollState())) {
                ListChoice(labels.inbox, selected = showsCurrent && areaId == null && projectId == null) { onPick(null, null) }
                if (areas.isNotEmpty()) {
                    ListGroupTitle(labels.area)
                    areas.forEach { item ->
                        val id = (item.location as? TaskHomeLocation.Area)?.id ?: return@forEach
                        val name = listOfNotNull(item.emoji, item.title).joinToString(" ")
                        ListChoice(name, selected = projectId == null && areaId == id) { onPick(id, null) }
                    }
                }
                if (projects.isNotEmpty()) {
                    ListGroupTitle(labels.project)
                    projects.forEach { item ->
                        val id = (item.location as? TaskHomeLocation.Project)?.id ?: return@forEach
                        ListChoice(item.title.orEmpty(), selected = projectId == id) { onPick(null, id) }
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text(labels.cancel) } },
    )
}

@Composable
private fun ListGroupTitle(title: String) {
    Text(
        text = title,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(top = 12.dp, bottom = 4.dp),
    )
}

@Composable
private fun ListChoice(title: String, selected: Boolean, onClick: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected, onClick = null)
        Text(title, modifier = Modifier.padding(start = 8.dp))
    }
}

private fun listTitle(
    areaId: String?,
    projectId: String?,
    areas: List<TaskHomeNavigationItem>,
    projects: List<TaskHomeNavigationItem>,
): String? = when {
    projectId != null -> projects.firstOrNull { (it.location as? TaskHomeLocation.Project)?.id == projectId }?.title
    areaId != null -> areas.firstOrNull { (it.location as? TaskHomeLocation.Area)?.id == areaId }?.title
    else -> null
}

/** Registry copy for the Quick Add sheet and the list picker. */
data class TaskFormLabels(
    val sheetTitle: String,
    val add: String,
    val cancel: String,
    val noDate: String,
    val title: String,
    val area: String,
    val project: String,
    val inbox: String,
) {
    companion object {
        fun fromRegistry(languageTag: String): TaskFormLabels {
            val detail = RegistryCatalog.surface(RegistryTaskDetail.ID)
            fun group(name: String, key: String): String {
                val raw = (detail?.fields?.get(name) as? JsonValue.ObjectValue)?.fields?.get(key).stringValue().orEmpty()
                return RegistryCatalog.localizedString(raw, languageTag) ?: raw
            }
            fun field(key: String) = group(FIELDS, key)
            fun control(key: String) = group(CONTROLS, key)
            return TaskFormLabels(
                sheetTitle = RegistryCatalog.actionTitle(RegistryActionIds.APP_NEW_TASK, languageTag = languageTag).orEmpty(),
                add = RegistryCatalog.actionAddTitle(RegistryActionIds.APP_QUICK_ADD, languageTag).orEmpty(),
                cancel = control(RegistryTaskDetail.Controls.CANCEL),
                noDate = control(RegistryTaskDetail.Controls.NO_DATE),
                title = field(RegistryTaskDetail.Fields.TITLE),
                area = field(RegistryTaskDetail.Fields.AREA),
                project = field(RegistryTaskDetail.Fields.PROJECT),
                inbox = RegistryCatalog.destinationTitle(RegistryDestinationIds.INBOX, languageTag).orEmpty(),
            )
        }

        private const val FIELDS = "fields"
        private const val CONTROLS = "controls"
    }
}
