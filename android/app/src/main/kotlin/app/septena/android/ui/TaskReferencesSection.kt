package app.septena.android.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.septena.android.AndroidAppGraph
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.TaskRefAddResult
import app.septena.core.TaskRefOffer
import app.septena.core.TaskRefOffers
import app.septena.core.TaskRefRecord
import app.septena.core.TaskRefResolver
import app.septena.core.TaskRefTarget
import app.septena.core.generated.RegistryActionIds
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityLimits
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.generated.RegistrySurfaceIds
import app.septena.core.longValue
import app.septena.core.stringValue
import app.septena.ui.PlusSmallGlyph
import app.septena.ui.TaskCardMetrics
import app.septena.ui.TaskCardSlice
import app.septena.ui.cardPosition
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Task References block (`taskPage.references`, `docs/TASK_REFERENCES_SPEC.md` §8):
 * glass card slices with tap-to-open and a long-press context menu (Open / Copy
 * link / Remove), the links of the task's text that are not references yet as
 * faint rows, and an Add Reference row, which a task without references has too.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun TaskReferencesSection(
    graph: AndroidAppGraph,
    taskId: String,
    heading: String?,
    canEdit: Boolean,
    taskTitle: String,
    taskNotes: String,
    showAddDialog: Boolean,
    onShowAddDialogChange: (Boolean) -> Unit,
    onOpenTask: (String) -> Unit,
) {
    val languageTag = LocalConfiguration.current.locales[0].toLanguageTag()
    val context = LocalContext.current
    val isDark = LocalSeptenaDarkTheme.current
    val hasActiveTexture = LocalAppearance.current.hasActiveTexture
    val dataVersion by graph.sync.dataVersion.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()

    var refs by remember(taskId) { mutableStateOf<List<TaskRefRecord>>(emptyList()) }
    var loaded by remember(taskId) { mutableStateOf(false) }
    var suggestions by remember(taskId) { mutableStateOf<List<TaskRefOffer>>(emptyList()) }
    var liveTaskIds by remember(taskId) { mutableStateOf<Set<String>>(emptySet()) }

    LaunchedEffect(graph, taskId, dataVersion) {
        val (loadedRefs, loadedTaskIds) = withContext(Dispatchers.IO) {
            val allRefs = graph.taskRefs(taskId)
            val ids = graph.taskStore.records(RegistryEntityNames.TASK)
                .filter { it.deletedAt == null }
                .mapTo(HashSet()) { it.id }
            allRefs to ids
        }
        refs = loadedRefs
        liveTaskIds = loadedTaskIds
        loaded = true
    }

    val surface = remember(languageTag) { RegistryCatalog.surface(RegistrySurfaceIds.TASK_REFERENCES)?.fields.orEmpty() }
    val addCopy = (surface["add"] as? JsonValue.ObjectValue)?.fields.orEmpty()
    val suggestionCopy = (addCopy["suggestions"] as? JsonValue.ObjectValue)?.fields.orEmpty()
    val suggestionFormat = registryText(suggestionCopy["format"].stringValue(), languageTag)
    val maxSuggestions = suggestionCopy["max"].longValue()?.toInt() ?: 0

    LaunchedEffect(refs, loaded, taskTitle, taskNotes, maxSuggestions) {
        if (!loaded) return@LaunchedEffect
        // A half-typed link is not a suggestion: wait for a pause.
        delay(SUGGESTION_PAUSE_MS)
        suggestions = withContext(Dispatchers.Default) {
            TaskRefOffers.suggestions(taskTitle, taskNotes, refs, maxSuggestions)
        }
    }

    val kindsMap = (surface["kinds"] as? JsonValue.ObjectValue)?.fields.orEmpty()
    val otherKindLabel = registryText((surface["otherKind"] as? JsonValue.ObjectValue)?.fields?.get("label").stringValue(), languageTag)
    val addTitle = remember(languageTag) {
        RegistryCatalog.actionTitle(RegistryActionIds.TASK_ADD_REFERENCE, languageTag = languageTag).orEmpty()
    }
    val openTitle = remember(languageTag) {
        RegistryCatalog.actionTitle(RegistryActionIds.TASK_REFERENCE_OPEN, languageTag = languageTag).orEmpty()
    }
    val copyLinkTitle = remember(languageTag) {
        RegistryCatalog.actionTitle(RegistryActionIds.TASK_REFERENCE_COPY_LINK, languageTag = languageTag).orEmpty()
    }
    val removeTitle = remember(languageTag) {
        RegistryCatalog.actionTitle(RegistryActionIds.TASK_REFERENCE_REMOVE, languageTag = languageTag).orEmpty()
    }

    if (showAddDialog) {
        AddReferenceDialog(
            graph = graph,
            taskId = taskId,
            draftTitle = taskTitle,
            draftNotes = taskNotes,
            onDismiss = { onShowAddDialogChange(false) },
        )
    }

    if (refs.isEmpty() && !canEdit) return

    val accent = MaterialTheme.colorScheme.primary
    val mutedInk = MaterialTheme.colorScheme.onSurfaceVariant
    val canAddMore = canEdit && refs.size < RegistryEntityLimits.MAX_REFS_PER_TASK.toInt()
    val shownSuggestions = if (canAddMore) suggestions.filter { offer -> refs.none { it.key == offer.key } } else emptyList()
    val totalSlices = refs.size + shownSuggestions.size + if (canAddMore) 1 else 0

    fun takeSuggestion(offer: TaskRefOffer) {
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching { graph.taskRefMutator.add(taskId, offer.input) }.getOrDefault(TaskRefAddResult.Failed)
            }
            if (result is TaskRefAddResult.Added) {
                graph.sync.noteLocalChange()
                graph.sync.requestSync()
            }
        }
    }

    heading?.let {
        Text(
            text = it,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            color = mutedInk,
            modifier = Modifier.padding(start = TaskCardMetrics.HeaderLeading, top = 12.dp, bottom = 6.dp),
        )
    }

    refs.forEachIndexed { index, ref ->
        val kindObj = kindsMap[ref.kind] as? JsonValue.ObjectValue
        val kindLabel = registryText(kindObj?.fields?.get("label").stringValue(), languageTag)
            .ifBlank { otherKindLabel }
        val target = remember(ref, liveTaskIds) {
            TaskRefResolver.target(ref) { id -> id in liveTaskIds }
        }
        val rolePrefix = when (ref.role) {
            RegistryEntityEnums.TaskRefRole.BLOCKED_BY -> registryText(
                ((surface["roles"] as? JsonValue.ObjectValue)?.fields?.get("blocked_by") as? JsonValue.ObjectValue)
                    ?.fields?.get("label").stringValue(),
                languageTag,
            )
            RegistryEntityEnums.TaskRefRole.FOLLOW_UP -> registryText(
                ((surface["roles"] as? JsonValue.ObjectValue)?.fields?.get("follow_up") as? JsonValue.ObjectValue)
                    ?.fields?.get("label").stringValue(),
                languageTag,
            )
            RegistryEntityEnums.TaskRefRole.FROM -> registryText(
                (surface["createdFrom"] as? JsonValue.ObjectValue)?.fields?.get("format").stringValue(),
                languageTag,
            ).replace("{name}", kindLabel).takeIf(String::isNotBlank)
            else -> null
        }
        val title = ref.displayTitle(kindLabel)
        val subtitle = listOfNotNull(rolePrefix, ref.displaySubtitle() ?: kindLabel.takeIf { it != title })
            .joinToString(" · ")
            .takeIf(String::isNotBlank)
        var menuOpen by remember(ref.id) { mutableStateOf(false) }

        fun openTarget() {
            when (target) {
                is TaskRefTarget.Url -> openUrl(context, target.url)
                is TaskRefTarget.Task -> onOpenTask(target.taskId)
                null -> Unit
            }
        }

        TaskCardSlice(
            position = cardPosition(index, totalSlices),
            isSelected = false,
            isDark = isDark,
            hasActiveTexture = hasActiveTexture,
        ) {
            Box(modifier = Modifier.fillMaxWidth()) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .combinedClickable(
                            onClick = ::openTarget,
                            onLongClick = { menuOpen = true },
                        )
                        .padding(horizontal = TaskCardMetrics.ContentInset, vertical = 11.dp),
                ) {
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier.width(TaskCardMetrics.LeadingColumnWidth),
                    ) {
                        Text(
                            text = kindGlyph(ref.kind),
                            fontSize = 15.sp,
                            color = if (target != null) accent else mutedInk,
                        )
                    }
                    Spacer(modifier = Modifier.width(TaskCardMetrics.IconTextGap))
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(2.dp),
                    ) {
                        Text(
                            text = title,
                            fontSize = 15.sp,
                            lineHeight = 20.sp,
                            color = MaterialTheme.colorScheme.onSurface,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                        if (subtitle != null) {
                            Text(
                                text = subtitle,
                                fontSize = 12.5.sp,
                                lineHeight = 16.sp,
                                color = mutedInk,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }

                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    if (target != null) {
                        DropdownMenuItem(
                            text = { Text(openTitle) },
                            onClick = { menuOpen = false; openTarget() },
                        )
                    }
                    if (target is TaskRefTarget.Url) {
                        DropdownMenuItem(
                            text = { Text(copyLinkTitle) },
                            onClick = {
                                menuOpen = false
                                copyToClipboard(context, copyLinkTitle, target.url)
                            },
                        )
                    }
                    if (canEdit) {
                        DropdownMenuItem(
                            text = { Text(removeTitle, color = MaterialTheme.colorScheme.error) },
                            onClick = {
                                menuOpen = false
                                scope.launch {
                                    runCatching {
                                        withContext(Dispatchers.IO) {
                                            graph.registryEntityMutator.delete(RegistryEntityNames.TASK_REF, ref.id)
                                        }
                                    }.onSuccess {
                                        graph.sync.noteLocalChange()
                                        graph.sync.requestSync()
                                    }
                                }
                            },
                        )
                    }
                }
            }
        }
    }

    shownSuggestions.forEachIndexed { index, offer ->
        val label = suggestionFormat.replace("{name}", offer.title)
        TaskCardSlice(
            position = cardPosition(refs.size + index, totalSlices),
            isSelected = false,
            isDark = isDark,
            hasActiveTexture = hasActiveTexture,
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .combinedClickable(onClickLabel = label, onClick = { takeSuggestion(offer) })
                    .padding(horizontal = TaskCardMetrics.ContentInset, vertical = 12.dp),
            ) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier.width(TaskCardMetrics.LeadingColumnWidth),
                ) {
                    PlusSmallGlyph(tint = mutedInk.copy(alpha = 0.7f), size = 13.dp)
                }
                Spacer(modifier = Modifier.width(TaskCardMetrics.IconTextGap))
                Text(
                    text = offer.title,
                    fontSize = 14.sp,
                    lineHeight = 20.sp,
                    color = mutedInk,
                    maxLines = 1,
                    overflow = TextOverflow.MiddleEllipsis,
                )
            }
        }
    }

    if (canAddMore) {
        TaskCardSlice(
            position = cardPosition(refs.size + shownSuggestions.size, totalSlices),
            isSelected = false,
            isDark = isDark,
            hasActiveTexture = hasActiveTexture,
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .combinedClickable(onClick = { onShowAddDialogChange(true) })
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
                    text = addTitle,
                    fontSize = 15.sp,
                    lineHeight = 20.sp,
                    color = accent,
                )
            }
        }
    }
}

private const val SUGGESTION_PAUSE_MS = 500L

/** The task's references, in order. Reads the store: never on the main thread. */
private suspend fun AndroidAppGraph.taskRefs(taskId: String): List<TaskRefRecord> =
    taskStore.records(RegistryEntityNames.TASK_REF)
        .mapNotNull(TaskRefRecord::from)
        .filter { it.taskId == taskId }
        .sortedWith(compareBy<TaskRefRecord>({ it.position ?: Double.MAX_VALUE }, { it.id }))

/**
 * Paste a link, or take one that is in the task's title or notes already. The
 * task page passes its unsaved text; the row menu reads the stored task.
 */
@Composable
internal fun AddReferenceDialog(
    graph: AndroidAppGraph,
    taskId: String,
    onDismiss: () -> Unit,
    draftTitle: String? = null,
    draftNotes: String? = null,
) {
    val languageTag = LocalConfiguration.current.locales[0].toLanguageTag()
    val surface = remember { RegistryCatalog.surface(RegistrySurfaceIds.TASK_REFERENCES)?.fields.orEmpty() }
    var offers by remember(taskId) { mutableStateOf<List<TaskRefOffer>>(emptyList()) }
    LaunchedEffect(graph, taskId, draftTitle, draftNotes) {
        offers = withContext(Dispatchers.IO) {
            val task = graph.taskStore.record(RegistryEntityNames.TASK, taskId)?.fields.orEmpty()
            TaskRefOffers.of(
                title = draftTitle ?: task[RegistryEntityFields.Task.TITLE].stringValue().orEmpty(),
                notes = draftNotes ?: task[RegistryEntityFields.Task.NOTES].stringValue(),
                existing = graph.taskRefs(taskId),
            )
        }
    }
    val scope = rememberCoroutineScope()
    var input by remember { mutableStateOf("") }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }

    val addObj = (surface["add"] as? JsonValue.ObjectValue)?.fields.orEmpty()
    val offersTitle = registryText((addObj["offers"] as? JsonValue.ObjectValue)?.fields?.get("title").stringValue(), languageTag)
    val placeholder = registryText(addObj["placeholder"].stringValue(), languageTag)
    val confirmTitle = registryText(addObj["confirmTitle"].stringValue(), languageTag)
    val invalidMsg = registryText((addObj["invalid"] as? JsonValue.ObjectValue)?.fields?.get("message").stringValue(), languageTag)
    val limitMsg = registryText((addObj["limitReached"] as? JsonValue.ObjectValue)?.fields?.get("format").stringValue(), languageTag)
        .replace("{count}", RegistryEntityLimits.MAX_REFS_PER_TASK.toString())
        .ifBlank { "This task already has ${RegistryEntityLimits.MAX_REFS_PER_TASK} references." }
    val failedMsg = registryText((addObj["failed"] as? JsonValue.ObjectValue)?.fields?.get("message").stringValue(), languageTag)
    val title = RegistryCatalog.actionTitle(RegistryActionIds.TASK_ADD_REFERENCE, languageTag = languageTag).orEmpty()
    val cancelLabel = RegistryCatalog.localizedString("Cancel", languageTag) ?: "Cancel"

    fun submit(text: String = input) {
        if (busy || text.isBlank()) return
        busy = true
        errorMessage = null
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching { graph.taskRefMutator.add(taskId, text) }.getOrDefault(TaskRefAddResult.Failed)
            }
            busy = false
            when (result) {
                is TaskRefAddResult.Added -> {
                    graph.sync.noteLocalChange()
                    graph.sync.requestSync()
                    onDismiss()
                }
                is TaskRefAddResult.Existing -> onDismiss()
                TaskRefAddResult.Invalid -> errorMessage = invalidMsg
                TaskRefAddResult.LimitReached -> errorMessage = limitMsg
                TaskRefAddResult.Failed -> errorMessage = failedMsg
            }
        }
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = input,
                    onValueChange = { input = it; errorMessage = null },
                    placeholder = { Text(placeholder) },
                    singleLine = true,
                    enabled = !busy,
                    keyboardOptions = KeyboardOptions(
                        keyboardType = KeyboardType.Uri,
                        imeAction = ImeAction.Done,
                    ),
                    keyboardActions = KeyboardActions(onDone = { submit() }),
                    modifier = Modifier.fillMaxWidth(),
                )
                errorMessage?.let {
                    Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                }
                if (offers.isNotEmpty()) {
                    Text(
                        text = offersTitle,
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Column(modifier = Modifier.heightIn(max = 220.dp).verticalScroll(rememberScrollState())) {
                        offers.forEach { offer ->
                            Text(
                                text = "${kindGlyph(offer.kind)}  ${offer.title}",
                                fontSize = 15.sp,
                                maxLines = 1,
                                overflow = TextOverflow.MiddleEllipsis,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable(enabled = !busy) { submit(offer.input) }
                                    .padding(vertical = 12.dp),
                            )
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = { submit() }, enabled = !busy && input.isNotBlank()) {
                Text(confirmTitle)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, enabled = !busy) {
                Text(cancelLabel)
            }
        },
    )
}

private fun kindGlyph(kind: String): String = when (kind) {
    "email", "thread" -> "✉"
    "issue" -> "#"
    "event" -> "◷"
    "task" -> "✓"
    "door" -> "◇"
    "file" -> "▤"
    else -> "↗"
}
