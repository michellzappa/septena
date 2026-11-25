package app.septena.android.ui

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.view.HapticFeedbackConstants
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import app.septena.android.AndroidAppGraph
import app.septena.android.doing.DoController
import app.septena.android.doing.DoCopy
import app.septena.android.doing.DoState
import app.septena.core.RegistryCatalog
import app.septena.core.generated.RegistryActionIds
import app.septena.core.generated.RegistryEntityLimits
import app.septena.ui.CalendarSmallGlyph
import app.septena.ui.CheckmarkGlyph
import app.septena.ui.ClockSmallGlyph
import app.septena.ui.DoGlyph
import app.septena.ui.DoHereGlyph
import app.septena.ui.DoStopGlyph
import app.septena.ui.PlusSmallGlyph
import app.septena.ui.TaskCardMetrics
import app.septena.ui.TaskCardPosition
import app.septena.ui.TaskCardSlice
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.time.Instant

/**
 * One task, full over the app, on the device where the user started it
 * (docs/DO_SPEC.md §4). Back and Show List leave the screen, not the Do.
 */
@Composable
internal fun DoScreen(
    graph: AndroidAppGraph,
    doing: DoState,
    quickAddTitle: String,
    onQuickAdd: () -> Unit,
    onOpenTask: (String) -> Unit,
) {
    val languageTag = LocalConfiguration.current.locales[0].toLanguageTag()
    val copy = remember(languageTag) { DoCopy(languageTag) }
    val dataVersion by graph.sync.dataVersion.collectAsStateWithLifecycle()
    val view = LocalView.current
    var lastNote by remember(doing.sessionId) { mutableStateOf<String?>(null) }
    var historyLoaded by remember(doing.sessionId) { mutableStateOf(false) }
    var pickingLater by rememberSaveable(doing.sessionId) { mutableStateOf(false) }

    LaunchedEffect(graph, doing.sessionId, dataVersion) {
        lastNote = withContext(Dispatchers.IO) {
            graph.doSessions.history(doing.taskId).firstNotNullOfOrNull { it.note }
        }
        historyLoaded = true
    }
    LaunchedEffect(graph) {
        graph.doing.plannedEndReached.collect { view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS) }
    }

    TaskDetailScreen(
        graph = graph,
        taskId = doing.taskId,
        onBack = graph.doing::showList,
        onOpenTask = onOpenTask,
        doPage = DoPage(
            showListTitle = doActionTitle(RegistryActionIds.DO_SHOW_LIST, languageTag),
            actions = {
                IconButton(
                    onClick = onQuickAdd,
                    modifier = Modifier.semantics { contentDescription = quickAddTitle },
                ) {
                    PlusSmallGlyph(tint = MaterialTheme.colorScheme.onSurface, size = 20.dp)
                }
            },
            aboveTitle = {
                lastNote?.let { note ->
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = TaskCardMetrics.HeaderLeading, vertical = 8.dp),
                        verticalArrangement = Arrangement.spacedBy(2.dp),
                    ) {
                        Text(
                            text = copy.lastTimeTitle,
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Text(text = note, style = MaterialTheme.typography.bodyLarge)
                    }
                }
            },
            belowTitle = { task ->
                DoTimeRow(graph, doing, copy, ownDuration = task.durationMinutes)
                val needsFirstStep = historyLoaded && lastNote == null && task.isOpen && !task.hasNotesOrChecklist
                if (needsFirstStep && aiModeAdmitsClaude(currentAiMode(graph))) {
                    DoFirstStep(graph, doing.taskId, copy.firstStepTitle, canWrite = task.canWrite)
                }
            },
            exits = { save ->
                DoExits(
                    languageTag = languageTag,
                    onDone = { save { graph.doing.done(doing) } },
                    onStop = { save { graph.doing.stop(doing) } },
                    onLater = { save { pickingLater = true } },
                )
            },
        ),
    )

    if (pickingLater) {
        DoLaterSheet(graph, doing, languageTag, onDismiss = { pickingLater = false })
    }
}

/** The floating Do (docs/DO_SPEC.md §4.2): the title and the time, in picture-in-picture. */
@Composable
internal fun DoFloat(graph: AndroidAppGraph) {
    val ui by graph.doing.ui.collectAsStateWithLifecycle()
    val doing = ui.current?.takeIf { ui.isFullHere }
    val languageTag = LocalConfiguration.current.locales[0].toLanguageTag()
    val copy = remember(languageTag) { DoCopy(languageTag) }
    Surface(modifier = Modifier.fillMaxSize()) {
        if (doing != null) {
            Column(
                modifier = Modifier.padding(12.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterVertically),
            ) {
                Text(
                    text = doing.title,
                    style = MaterialTheme.typography.titleSmall,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    text = copy.length(doing.minutes(doNow(graph, doing))),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

/** The time, up or down to the planned end. A tap sets the length. Never red. */
@Composable
private fun DoTimeRow(graph: AndroidAppGraph, doing: DoState, copy: DoCopy, ownDuration: Int?) {
    val context = LocalContext.current
    var menuOpen by remember { mutableStateOf(false) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}
    val time = copy.length(doing.minutes(doNow(graph, doing)))
    val options = remember(copy, ownDuration) {
        val own = ownDuration?.takeIf { it in 1..RegistryEntityLimits.DO_PLANNED_MINUTES_MAX.toInt() }
        (copy.lengths + listOfNotNull(own)).distinct().sorted()
    }

    fun pick(minutes: Int?) {
        menuOpen = false
        graph.doing.setLength(doing, minutes)
        // Only a length has an end to signal, so only a length asks for alerts.
        if (minutes != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            permission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    Box(modifier = Modifier.padding(horizontal = TaskCardMetrics.HeaderLeading)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier
                .clickable(onClickLabel = copy.lengthTitle) { menuOpen = true }
                .padding(vertical = 10.dp),
        ) {
            ClockSmallGlyph(tint = MaterialTheme.colorScheme.onSurfaceVariant, size = 16.dp)
            Text(
                text = time,
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
            Text(
                text = copy.lengthTitle,
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
            )
            (listOf<Int?>(null) + options).forEach { minutes ->
                DropdownMenuItem(
                    text = { Text(minutes?.let(copy::lengthOption) ?: copy.noLengthTitle) },
                    trailingIcon = if (minutes == doing.plannedMinutes) {
                        { CheckmarkGlyph(tint = MaterialTheme.colorScheme.primary, size = 16.dp) }
                    } else null,
                    onClick = { pick(minutes) },
                )
            }
        }
    }
}

/** Asks for the first step when the task has nothing to start from. A tap opens Discuss. It never blocks. */
@Composable
private fun DoFirstStep(graph: AndroidAppGraph, taskId: String, title: String, canWrite: Boolean) {
    var open by rememberSaveable(taskId) { mutableStateOf(false) }
    TaskCardSlice(
        position = TaskCardPosition.Solo,
        isSelected = false,
        isDark = LocalSeptenaDarkTheme.current,
        hasActiveTexture = LocalAppearance.current.hasActiveTexture,
        modifier = Modifier.padding(vertical = 8.dp),
    ) {
        Column(modifier = Modifier.fillMaxWidth()) {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyLarge,
                modifier = Modifier.fillMaxWidth().clickable { open = !open }.padding(14.dp),
            )
            if (open) {
                Box(modifier = Modifier.padding(start = 14.dp, end = 14.dp, bottom = 14.dp)) {
                    TaskConversationSection(
                        graph = graph,
                        taskId = taskId,
                        isTaskOpen = true,
                        canWrite = canWrite,
                    )
                }
            }
        }
    }
}

@Composable
private fun DoExits(languageTag: String, onDone: () -> Unit, onStop: () -> Unit, onLater: () -> Unit) {
    Box(modifier = Modifier.fillMaxWidth().navigationBarsPadding().imePadding(), contentAlignment = Alignment.Center) {
        Column(
            modifier = Modifier
                .widthIn(max = 720.dp)
                .fillMaxWidth()
                .padding(horizontal = TaskCardMetrics.Margin, vertical = 10.dp),
        ) {
            Button(onClick = onDone, modifier = Modifier.fillMaxWidth()) {
                Text(doActionTitle(RegistryActionIds.DO_DONE, languageTag))
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                OutlinedButton(onClick = onStop, modifier = Modifier.weight(1f)) {
                    DoStopGlyph(tint = LocalContentColor.current, size = 16.dp)
                    Spacer(modifier = Modifier.padding(start = 6.dp))
                    Text(doActionTitle(RegistryActionIds.DO_STOP, languageTag), maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                OutlinedButton(onClick = onLater, modifier = Modifier.weight(1f)) {
                    CalendarSmallGlyph(tint = LocalContentColor.current, size = 16.dp)
                    Spacer(modifier = Modifier.padding(start = 6.dp))
                    Text(doActionTitle(RegistryActionIds.DO_LATER, languageTag), maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}

/** Later is the one When picker. Only a saved date ends the Do. */
@Composable
private fun DoLaterSheet(graph: AndroidAppGraph, doing: DoState, languageTag: String, onDismiss: () -> Unit) {
    TaskWhenSheet(
        today = graph.clock.today(graph.clock.now()),
        languageTag = languageTag,
        onDismiss = onDismiss,
        onPick = { day ->
            onDismiss()
            graph.doing.later(doing, day)
        },
    )
}

/**
 * The notice of a Do that this device does not show in full (§5): one quiet
 * line. A tap offers the exits and Do Here. A stale Do asks once (§2.2).
 */
@Composable
internal fun DoNoticeCard(
    graph: AndroidAppGraph,
    doing: DoState,
    languageTag: String,
    isDark: Boolean,
    hasActiveTexture: Boolean,
    modifier: Modifier = Modifier,
) {
    val copy = remember(languageTag) { DoCopy(languageTag) }
    var menuOpen by remember(doing.sessionId) { mutableStateOf(false) }
    var pickingLater by rememberSaveable(doing.sessionId) { mutableStateOf(false) }
    TaskCardSlice(
        position = TaskCardPosition.Solo,
        isSelected = false,
        isDark = isDark,
        hasActiveTexture = hasActiveTexture,
        modifier = modifier,
    ) {
        if (doing.isStale) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = TaskCardMetrics.ContentInset, vertical = 10.dp),
            ) {
                Text(text = copy.stale(doing.title), style = MaterialTheme.typography.bodyLarge)
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    DoTextButton(RegistryActionIds.DO_DONE, languageTag) { graph.doing.done(doing) }
                    DoTextButton(RegistryActionIds.DO_STOP, languageTag) { graph.doing.stop(doing) }
                    DoTextButton(RegistryActionIds.DO_CONFIRM, languageTag) { graph.doing.confirm(doing) }
                }
            }
        } else {
            Box {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(TaskCardMetrics.IconTextGap),
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { menuOpen = true }
                        .padding(horizontal = TaskCardMetrics.ContentInset, vertical = 12.dp),
                ) {
                    DoGlyph(tint = MaterialTheme.colorScheme.onSurfaceVariant, size = 18.dp)
                    Text(
                        text = copy.notice(doing.title),
                        style = MaterialTheme.typography.bodyLarge,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    Text(
                        text = copy.length(doing.minutes(doNow(graph, doing))),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    val tint = MaterialTheme.colorScheme.onSurfaceVariant
                    DoMenuItem(RegistryActionIds.DO_DONE, languageTag, { CheckmarkGlyph(tint = tint) }) {
                        menuOpen = false
                        graph.doing.done(doing)
                    }
                    DoMenuItem(RegistryActionIds.DO_STOP, languageTag, { DoStopGlyph(tint = tint) }) {
                        menuOpen = false
                        graph.doing.stop(doing)
                    }
                    DoMenuItem(RegistryActionIds.DO_LATER, languageTag, { CalendarSmallGlyph(tint = tint, size = 16.dp) }) {
                        menuOpen = false
                        pickingLater = true
                    }
                    DoMenuItem(RegistryActionIds.DO_HERE, languageTag, { DoHereGlyph(tint = tint) }) {
                        menuOpen = false
                        graph.doing.showHere()
                    }
                }
            }
        }
    }
    if (pickingLater) {
        DoLaterSheet(graph, doing, languageTag, onDismiss = { pickingLater = false })
    }
}

/** After Stop for Now: one optional line. Closing it is fine. */
@Composable
internal fun DoStopNoteDialog(controller: DoController, sessionId: String, languageTag: String) {
    val copy = remember(languageTag) { DoCopy(languageTag) }
    var note by rememberSaveable(sessionId) { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = { controller.answerStopNote(null) },
        title = { Text(copy.stopNoteTitle) },
        text = {
            OutlinedTextField(
                value = note,
                onValueChange = { note = it.take(RegistryEntityLimits.DO_NOTE_MAX.toInt()) },
                maxLines = 4,
                modifier = Modifier.fillMaxWidth().semantics { contentDescription = copy.stopNoteTitle },
            )
        },
        confirmButton = {
            TextButton(onClick = { controller.answerStopNote(note) }, enabled = note.isNotBlank()) {
                Text(copy.stopNoteSave)
            }
        },
        dismissButton = {
            TextButton(onClick = { controller.answerStopNote(null) }) { Text(copy.stopNoteSkip) }
        },
    )
}

@Composable
private fun DoTextButton(actionId: String, languageTag: String, onClick: () -> Unit) {
    TextButton(onClick = onClick) { Text(doActionTitle(actionId, languageTag)) }
}

@Composable
private fun DoMenuItem(actionId: String, languageTag: String, icon: @Composable () -> Unit, onClick: () -> Unit) {
    DropdownMenuItem(text = { Text(doActionTitle(actionId, languageTag)) }, leadingIcon = icon, onClick = onClick)
}

/** The clock of a Do surface: one step a minute, on the minute of the start. */
@Composable
private fun doNow(graph: AndroidAppGraph, doing: DoState): Instant {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var now by remember(doing) { mutableStateOf(graph.clock.now()) }
    LaunchedEffect(doing, lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                now = graph.clock.now()
                val into = Math.floorMod(now.toEpochMilli() - doing.startedAt.toEpochMilli(), 60_000L)
                delay(60_000L - into + 20L)
            }
        }
    }
    return now
}

private fun doActionTitle(actionId: String, languageTag: String): String =
    RegistryCatalog.actionTitle(actionId, languageTag = languageTag).orEmpty()
