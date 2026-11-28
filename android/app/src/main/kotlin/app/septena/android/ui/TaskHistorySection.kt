package app.septena.android.ui

import android.text.format.DateUtils
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.septena.android.AndroidAppGraph
import app.septena.android.doing.DoCopy
import app.septena.core.DoSession
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.TaskProvenance
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.generated.RegistrySettingKeys
import app.septena.core.generated.RegistryTaskDetail
import app.septena.core.stringValue
import app.septena.transport.TaskChange
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.ZoneId

/** One line of the History list: what changed, then who and when. Same model as iOS `TaskHistoryRow`. */
internal data class TaskHistoryRow(
    val rev: Long,
    val at: Instant?,
    val who: String,
    val byAgent: Boolean,
    /** What changed, one short phrase per change. Never empty. */
    val lines: List<String>,
)

/** One upsell note from `registry/plans.json` `upsells` (same shape as iOS `RegistryPlanNote`). */
internal data class PlanUpsellNote(
    val id: String,
    val title: String,
    val detail: String,
)

private const val HISTORY_EDGE_UPSELL_ID = "history_edge"

/**
 * The quiet last line under History when the server says the free plan's
 * window hid older changes (`TaskHistory.edgeUpsell` on Apple, spec §3.2).
 * The server judges; returns null otherwise.
 */
internal fun historyEdgeUpsell(upsellId: String?, languageTag: String): PlanUpsellNote? {
    if (upsellId != HISTORY_EDGE_UPSELL_ID) return null
    val upsells = (RegistryCatalog.document("plans").fields["upsells"] as? JsonValue.ArrayValue)
        ?.values
        .orEmpty()
    val match = upsells
        .filterIsInstance<JsonValue.ObjectValue>()
        .firstOrNull { it.fields["id"].stringValue() == HISTORY_EDGE_UPSELL_ID }
        ?: return null
    val title = registryText(match.fields["title"].stringValue(), languageTag)
    val detail = registryText(match.fields["detail"].stringValue(), languageTag)
    if (title.isEmpty()) return null
    return PlanUpsellNote(id = HISTORY_EDGE_UPSELL_ID, title = title, detail = detail)
}

private sealed interface HistoryState {
    data object Loading : HistoryState
    data object Failed : HistoryState
    data class Loaded(
        val rows: List<TaskHistoryRow>,
        val edge: PlanUpsellNote?,
        val edgeSeen: Boolean,
    ) : HistoryState
}

/**
 * The task's change history from the task backend's change log (feature
 * `task.history`, block `taskPage.history`). It mounts only when its row folds
 * open, so opening a task never waits on the network, and each open reads the
 * log again (iOS `TaskHistoryPanel`).
 */
@Composable
internal fun TaskHistoryList(
    graph: AndroidAppGraph,
    taskId: String,
    languageTag: String,
    control: (String) -> String,
) {
    var state by remember(taskId) { mutableStateOf<HistoryState>(HistoryState.Loading) }
    var showingPlus by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val dataVersion by graph.sync.dataVersion.collectAsStateWithLifecycle()
    var sessions by remember(taskId) { mutableStateOf<List<DoSession>>(emptyList()) }

    LaunchedEffect(graph, taskId, dataVersion) {
        sessions = withContext(Dispatchers.IO) { graph.doSessions.history(taskId) }
    }

    LaunchedEffect(graph, taskId) {
        state = HistoryState.Loading
        state = try {
            val page = graph.taskBackend.history(taskId)
            val (titles, seenUpsells) = withContext(Dispatchers.IO) {
                listTitles(graph) to upsellsSeen(graph)
            }
            val edge = historyEdgeUpsell(page.upsell, languageTag)
            HistoryState.Loaded(
                rows = TaskHistoryText(control, languageTag).rows(page.changes) { titles[it] },
                edge = edge,
                edgeSeen = edge != null && edge.id in seenUpsells,
            )
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            HistoryState.Failed
        }
    }

    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (sessions.isNotEmpty()) {
            val copy = remember(languageTag) { DoCopy(languageTag) }
            sessions.forEach { DoSessionRow(it, copy, languageTag) }
        }
        when (val current = state) {
            HistoryState.Loading -> CircularProgressIndicator()
            HistoryState.Failed -> HistoryNote(control(RegistryTaskDetail.Controls.HISTORY_LOAD_FAILED))
            is HistoryState.Loaded -> if (current.rows.isEmpty() && current.edge == null) {
                if (sessions.isEmpty()) HistoryNote(control(RegistryTaskDetail.Controls.HISTORY_EMPTY))
            } else {
                val now = System.currentTimeMillis()
                current.rows.forEach { row -> HistoryRowView(row, now) }
                current.edge?.let { edge ->
                    HistoryEdgeLine(
                        edge = edge,
                        seen = current.edgeSeen,
                        languageTag = languageTag,
                        onSeePlus = {
                            if (!current.edgeSeen) {
                                state = current.copy(edgeSeen = true)
                            }
                            showingPlus = true
                            scope.launch {
                                runCatching { withContext(Dispatchers.IO) { markUpsellSeen(graph, edge.id) } }
                            }
                        },
                    )
                }
            }
        }
    }

    if (showingPlus) {
        HistoryPlusSheet(
            graph = graph,
            languageTag = languageTag,
            onDismiss = { showingPlus = false },
        )
    }
}

/** One Do of the task: how it ended, its length, the note and the day. An unknown length shows none. */
@Composable
private fun DoSessionRow(session: DoSession, copy: DoCopy, languageTag: String) {
    val exit = when {
        session.endedAt == null -> copy.openExit
        else -> session.exit?.let(copy::exit)
    }
    val length = session.length?.let { copy.length(it.toMinutes()) }
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(listOfNotNull(exit, length).joinToString(" · "), style = MaterialTheme.typography.bodySmall)
        session.note?.let { HistoryNote(it) }
        Text(
            formatDay(session.startedAt.atZone(ZoneId.systemDefault()).toLocalDate().toString(), languageTag),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/**
 * A quiet last line: older changes are hidden, one tap to Plus. The detail
 * shows until the account has seen this moment; after that only the title and
 * the button stay (iOS `TaskHistoryPanel.edgeLine`, spec §7.1).
 */
@Composable
private fun HistoryEdgeLine(
    edge: PlanUpsellNote,
    seen: Boolean,
    languageTag: String,
    onSeePlus: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(
            edge.title,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (!seen && edge.detail.isNotEmpty()) {
            Text(
                edge.detail,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        TextButton(
            onClick = onSeePlus,
            contentPadding = PaddingValues(0.dp),
        ) {
            Text(
                plansText(languageTag, "paywall", "seePlus"),
                style = MaterialTheme.typography.bodySmall,
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun HistoryPlusSheet(
    graph: AndroidAppGraph,
    languageTag: String,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val plans = remember(graph) { PlanSettingsModel(graph) }
    LaunchedEffect(graph) { plans.refresh(signedIn = true) }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(bottom = 24.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Spacer(modifier = Modifier.weight(1f))
                TextButton(onClick = onDismiss) {
                    Text(plansText(languageTag, "paywall", "done"))
                }
            }
            PlusOffer(plans = plans, languageTag = languageTag)
        }
    }
}

private suspend fun upsellsSeen(graph: AndroidAppGraph): Set<String> =
    (graph.syncedSettings.value(RegistrySettingKeys.UPSELLS_SEEN) as? JsonValue.ArrayValue)
        ?.values
        ?.mapNotNull { it.stringValue() }
        ?.toSet()
        .orEmpty()

private suspend fun markUpsellSeen(graph: AndroidAppGraph, id: String) {
    val current = upsellsSeen(graph)
    if (id in current) return
    val updated = (current + id).sorted().map { JsonValue.StringValue(it) }
    graph.syncedSettingsMutator.set(RegistrySettingKeys.UPSELLS_SEEN, JsonValue.ArrayValue(updated))
    graph.sync.noteLocalChange()
    graph.sync.requestSync()
}

@Composable
private fun HistoryNote(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun HistoryRowView(row: TaskHistoryRow, now: Long) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        row.lines.forEach { Text(it, style = MaterialTheme.typography.bodySmall, maxLines = 2) }
        val whenText = row.at?.let {
            DateUtils.getRelativeTimeSpanString(it.toEpochMilli(), now, DateUtils.MINUTE_IN_MILLIS).toString()
        }
        Text(
            listOfNotNull(row.who, whenText).joinToString(" · "),
            style = MaterialTheme.typography.labelSmall,
            // An agent's change carries a heavier label, not a second color (as on iOS).
            fontWeight = if (row.byAgent) FontWeight.SemiBold else FontWeight.Normal,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** Area and project titles by id, to name the list a task moved to. */
private suspend fun listTitles(graph: AndroidAppGraph): Map<String, String> = buildMap {
    for (entity in listOf(RegistryEntityNames.AREA, RegistryEntityNames.PROJECT)) {
        val titleField = if (entity == RegistryEntityNames.AREA) RegistryEntityFields.Area.TITLE else RegistryEntityFields.Project.TITLE
        graph.taskStore.records(entity).forEach { record ->
            record.fields[titleField].stringValue()?.let { put(record.id, it) }
        }
    }
}

/**
 * The words of the History list for change-log rows. A port of iOS
 * `TaskHistory.describe`: the same fields, the same order, the same copy
 * (registry `taskDetail.controls.history*`).
 */
internal class TaskHistoryText(
    private val control: (String) -> String,
    private val languageTag: String,
) {
    fun rows(changes: List<TaskChange>, listTitle: (String) -> String?): List<TaskHistoryRow> =
        changes.mapNotNull { change ->
            val lines = describe(change, listTitle)
            if (lines.isEmpty()) return@mapNotNull null
            TaskHistoryRow(
                rev = change.rev,
                at = runCatching { Instant.parse(change.at) }.getOrNull(),
                who = who(change.actor),
                byAgent = change.actor.startsWith(MCP_PREFIX),
                lines = lines,
            )
        }

    fun who(actor: String): String {
        if (actor.startsWith(MCP_PREFIX)) {
            // `mcp:<connection name>` or `mcp:<agent>@<client>`; the legacy `mcp:claude` reads as the fallback name.
            val name = actor.removePrefix(MCP_PREFIX).substringBefore('@').trim()
            return TaskProvenance.addedByName(
                RegistryEntityEnums.TaskSource.MCP,
                name.takeUnless { it == LEGACY_AGENT },
                languageTag,
            )
        }
        return when (actor) {
            ACTOR_MAC -> control(RegistryTaskDetail.Controls.HISTORY_YOU_ON_MAC)
            ACTOR_IPHONE -> control(RegistryTaskDetail.Controls.HISTORY_YOU_ON_IPHONE)
            else -> TaskProvenance.addedByName(RegistryEntityEnums.TaskSource.APP, null, languageTag)
        }
    }

    fun describe(change: TaskChange, listTitle: (String) -> String?): List<String> {
        when (change.op) {
            OP_DELETE -> return listOf(control(RegistryTaskDetail.Controls.HISTORY_DELETED))
            OP_UPSERT -> Unit
            else -> return emptyList()
        }
        val diff = change.diff
        fun has(key: String) = diff.containsKey(key)
        fun before(key: String): JsonValue = diff[key]?.first ?: JsonValue.Null
        fun after(key: String): JsonValue = diff[key]?.second ?: JsonValue.Null
        fun text(key: String, placeholder: String, value: String) =
            control(key).replace("{$placeholder}", value)

        // A row with no earlier title or status is the insert.
        if (has(RegistryEntityFields.Task.TITLE) &&
            before(RegistryEntityFields.Task.TITLE) == JsonValue.Null &&
            before(RegistryEntityFields.Task.STATUS) == JsonValue.Null
        ) {
            return listOf(control(RegistryTaskDetail.Controls.HISTORY_CREATED))
        }

        val lines = mutableListOf<String>()
        if (has(RegistryEntityFields.Task.TITLE)) {
            lines += control(RegistryTaskDetail.Controls.HISTORY_TITLE_CHANGED)
                .replace("{old}", clip(before(RegistryEntityFields.Task.TITLE).stringValue().orEmpty()))
                .replace("{new}", clip(after(RegistryEntityFields.Task.TITLE).stringValue().orEmpty()))
        }
        if (has(RegistryEntityFields.Task.STATUS)) {
            lines += control(
                when (after(RegistryEntityFields.Task.STATUS).stringValue()) {
                    RegistryEntityEnums.TaskStatus.DONE -> RegistryTaskDetail.Controls.HISTORY_COMPLETED
                    RegistryEntityEnums.TaskStatus.CANCELLED -> RegistryTaskDetail.Controls.HISTORY_CANCELLED
                    else -> RegistryTaskDetail.Controls.HISTORY_REOPENED
                },
            )
        }
        if (has(RegistryEntityFields.Task.TODAY)) {
            lines += control(
                if (after(RegistryEntityFields.Task.TODAY) == JsonValue.BooleanValue(true)) {
                    RegistryTaskDetail.Controls.HISTORY_MOVED_TO_TODAY
                } else {
                    RegistryTaskDetail.Controls.HISTORY_REMOVED_FROM_TODAY
                },
            )
        }
        listLine(::has, ::before, ::after, listTitle)?.let { lines += it }
        if (has(RegistryEntityFields.Task.SCHEDULED)) {
            lines += after(RegistryEntityFields.Task.SCHEDULED).stringValue()
                ?.let { text(RegistryTaskDetail.Controls.HISTORY_WHEN, "day", formatDay(it, languageTag)) }
                ?: control(RegistryTaskDetail.Controls.HISTORY_WHEN_CLEARED)
        }
        if (has(RegistryEntityFields.Task.DEADLINE)) {
            lines += after(RegistryEntityFields.Task.DEADLINE).stringValue()
                ?.let { text(RegistryTaskDetail.Controls.HISTORY_DEADLINE, "day", formatDay(it, languageTag)) }
                ?: control(RegistryTaskDetail.Controls.HISTORY_DEADLINE_CLEARED)
        }
        if (has(RegistryEntityFields.Task.NOTES)) {
            val had = !before(RegistryEntityFields.Task.NOTES).stringValue().isNullOrEmpty()
            val hasNow = !after(RegistryEntityFields.Task.NOTES).stringValue().isNullOrEmpty()
            lines += control(
                when {
                    !had -> RegistryTaskDetail.Controls.HISTORY_NOTES_ADDED
                    hasNow -> RegistryTaskDetail.Controls.HISTORY_NOTES_EDITED
                    else -> RegistryTaskDetail.Controls.HISTORY_NOTES_CLEARED
                },
            )
        }
        if (REPEAT_FIELDS.any(::has)) {
            val removed = has(RegistryEntityFields.Task.RECURRENCE_UNIT) &&
                after(RegistryEntityFields.Task.RECURRENCE_UNIT) == JsonValue.Null
            lines += control(
                if (removed) RegistryTaskDetail.Controls.HISTORY_REPEAT_REMOVED else RegistryTaskDetail.Controls.HISTORY_REPEAT_CHANGED,
            )
        }
        if (has(RegistryEntityFields.Task.RECURRENCE_PAUSED)) {
            lines += control(
                if (after(RegistryEntityFields.Task.RECURRENCE_PAUSED) == JsonValue.BooleanValue(true)) {
                    RegistryTaskDetail.Controls.HISTORY_REPEAT_PAUSED
                } else {
                    RegistryTaskDetail.Controls.HISTORY_REPEAT_RESUMED
                },
            )
        }
        if (has(RegistryEntityFields.Task.REMINDER_AT)) {
            lines += control(
                if (after(RegistryEntityFields.Task.REMINDER_AT) == JsonValue.Null) {
                    RegistryTaskDetail.Controls.HISTORY_REMINDER_REMOVED
                } else {
                    RegistryTaskDetail.Controls.HISTORY_REMINDER_SET
                },
            )
        }
        if (has(RegistryEntityFields.Task.STARRED)) {
            lines += control(
                if (after(RegistryEntityFields.Task.STARRED) == JsonValue.BooleanValue(true)) {
                    RegistryTaskDetail.Controls.HISTORY_STARRED
                } else {
                    RegistryTaskDetail.Controls.HISTORY_UNSTARRED
                },
            )
        }
        // Order, Today bookkeeping, acknowledgement and provenance fields are left
        // out: they change on every reorder and mean nothing to read.
        return lines
    }

    /** Project wins over area: a task in a project shows under that project. */
    private fun listLine(
        has: (String) -> Boolean,
        before: (String) -> JsonValue,
        after: (String) -> JsonValue,
        listTitle: (String) -> String?,
    ): String? {
        val hasProject = has(RegistryEntityFields.Task.PROJECT)
        val hasArea = has(RegistryEntityFields.Task.AREA)
        if (!hasProject && !hasArea) return null
        val newId = after(RegistryEntityFields.Task.PROJECT).stringValue() ?: after(RegistryEntityFields.Task.AREA).stringValue()
        if (newId != null) {
            val name = listTitle(newId)?.let(::clip) ?: control(RegistryTaskDetail.Controls.HISTORY_ANOTHER_LIST)
            return control(RegistryTaskDetail.Controls.HISTORY_MOVED_TO).replace("{list}", name)
        }
        // The changed list was cleared. When only one of the two changed, the
        // other may still hold the task, so name what it left.
        if (hasProject != hasArea) {
            val oldId = before(if (hasProject) RegistryEntityFields.Task.PROJECT else RegistryEntityFields.Task.AREA).stringValue()
            val name = oldId?.let(listTitle)
            if (name != null) return control(RegistryTaskDetail.Controls.HISTORY_REMOVED_FROM).replace("{list}", clip(name))
        }
        return control(RegistryTaskDetail.Controls.HISTORY_MOVED_TO_INBOX)
    }

    private fun clip(text: String): String {
        val flat = text.replace('\n', ' ')
        return if (flat.length > VALUE_MAX) flat.take(VALUE_MAX - 1) + "…" else flat
    }

    private companion object {
        const val MCP_PREFIX = "mcp:"
        const val LEGACY_AGENT = "claude"
        const val ACTOR_MAC = "app:septask-mac"
        const val ACTOR_IPHONE = "app:septask-ios"
        const val OP_UPSERT = "upsert"
        const val OP_DELETE = "delete"
        const val VALUE_MAX = 40
        val REPEAT_FIELDS = listOf(
            RegistryEntityFields.Task.RECURRENCE_UNIT,
            RegistryEntityFields.Task.RECURRENCE_INTERVAL,
            RegistryEntityFields.Task.RECURRENCE_WEEKDAYS,
            RegistryEntityFields.Task.RECURRENCE_MONTH_DAY,
            RegistryEntityFields.Task.RECURRENCE_ORDINAL_WEEKDAY,
        )
    }
}
