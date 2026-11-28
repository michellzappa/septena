package app.septena.android.ui

import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import app.septena.android.AndroidAppGraph
import app.septena.core.DoSession
import app.septena.core.DoStamp
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.SyncRecord
import app.septena.core.TaskAddedVia
import app.septena.core.TaskStore
import app.septena.core.WireTimestamp
import app.septena.core.booleanValue
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityLimits
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.longValue
import app.septena.core.stringValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset

/** Parsed preview of a `septena_export_version: 1` JSON backup (matches Apple `TaskJSONTransfer`). */
data class ParsedTransferEnvelope(
    val version: Int,
    val section: String,
    val areas: List<Map<String, JsonValue>>,
    val projects: List<Map<String, JsonValue>>,
    val tasks: List<Map<String, JsonValue>>,
    val tags: List<Map<String, JsonValue>>,
    val checklistItems: List<Map<String, JsonValue>>,
    val doSessions: List<Map<String, JsonValue>> = emptyList(),
    val skippedCount: Int,
) {
    val supportedCount: Int
        get() = areas.size + projects.size + tasks.size + tags.size + checklistItems.size + doSessions.size
}

/**
 * Pure JSON / Markdown / CSV export & JSON import matching Apple `SeptaskDataTransfer.swift`
 * (feature `data.import-export`, #370). Uses the exact `septena_export_version: 1` envelope.
 */
object TaskDataTransferCodec {
    const val ENVELOPE_VERSION = 1L
    private const val DO_SESSION_TABLE = "do_session"
    private const val DO_SESSION_TASK_KEY = "taskID"

    suspend fun exportJson(store: TaskStore, now: Instant, appVersion: String = "0.1.0"): String {
        val areas = store.records(RegistryEntityNames.AREA).filter { it.deletedAt == null }
        val projects = store.records(RegistryEntityNames.PROJECT).filter { it.deletedAt == null }
        val tasks = store.records(RegistryEntityNames.TASK).filter { it.deletedAt == null }
        val checklistItems = store.records(RegistryEntityNames.CHECKLIST_ITEM).filter { it.deletedAt == null }
        val taskRefs = store.records(RegistryEntityNames.TASK_REF).filter { it.deletedAt == null }
        val doSessions = store.records(RegistryEntityNames.DO_SESSION).filter { it.deletedAt == null }
        val tags = store.records(RegistryEntityNames.TAG).filter { it.deletedAt == null }

        fun rowObject(r: SyncRecord): JsonValue.ObjectValue {
            val map = linkedMapOf<String, JsonValue>("id" to JsonValue.StringValue(r.id))
            r.fields.forEach { (k, v) -> if (v !== JsonValue.Null) map[k] = v }
            r.updatedAt?.let { map["updatedAt"] = JsonValue.StringValue(it) }
            return JsonValue.ObjectValue(map)
        }

        val tables = linkedMapOf<String, JsonValue>(
            "area" to JsonValue.ArrayValue(areas.map(::rowObject)),
            "project" to JsonValue.ArrayValue(projects.map(::rowObject)),
            "task" to JsonValue.ArrayValue(tasks.map(::rowObject)),
            "checklist_item" to JsonValue.ArrayValue(checklistItems.map(::rowObject)),
            "task_ref" to JsonValue.ArrayValue(taskRefs.map(::rowObject)),
            DO_SESSION_TABLE to JsonValue.ArrayValue(doSessions.map(::doSessionObject)),
            "tag" to JsonValue.ArrayValue(tags.map(::rowObject)),
        )
        return JsonValue.ObjectValue(
            linkedMapOf(
                "septena_export_version" to JsonValue.IntegerValue(ENVELOPE_VERSION),
                "section" to JsonValue.StringValue("tasks"),
                "exported_at" to JsonValue.StringValue(WireTimestamp.format(now)),
                "app_version" to JsonValue.StringValue(appVersion),
                "tables" to JsonValue.ObjectValue(tables),
            ),
        ).canonicalJson()
    }

    /** The keys of Apple's `doSessionDict`. */
    private fun doSessionObject(r: SyncRecord): JsonValue.ObjectValue {
        val map = linkedMapOf<String, JsonValue>("id" to JsonValue.StringValue(r.id))
        for ((field, value) in r.fields) {
            if (value === JsonValue.Null) continue
            when (field) {
                RegistryEntityFields.DoSession.TASK_ID -> map[DO_SESSION_TASK_KEY] = value
                RegistryEntityFields.DoSession.LAPSED ->
                    map[field] = JsonValue.BooleanValue(DoSession.from(r)?.lapsed == true)
                else -> map[field] = value
            }
        }
        return JsonValue.ObjectValue(map)
    }

    /**
     * The row that an import writes, or null when it cannot come back. An
     * imported Do is history, so an open one ends where it started (as Apple).
     */
    private fun importedDoSession(row: Map<String, JsonValue>, taskId: String): Map<String, JsonValue>? {
        fun stamp(field: String): JsonValue.StringValue? =
            (row[field] as? JsonValue.StringValue)?.takeIf { DoStamp.instant(it.value) != null }
        val started = stamp(RegistryEntityFields.DoSession.STARTED_AT) ?: return null
        val ended = stamp(RegistryEntityFields.DoSession.ENDED_AT)
        val exit = row[RegistryEntityFields.DoSession.EXIT].stringValue()
            ?.takeIf { it in RegistryEntityEnums.all.getValue("doExit") }
        return buildMap {
            put(RegistryEntityFields.DoSession.TASK_ID, JsonValue.StringValue(taskId))
            put(RegistryEntityFields.DoSession.STARTED_AT, started)
            row[RegistryEntityFields.DoSession.PLANNED_MINUTES].longValue()?.let {
                put(
                    RegistryEntityFields.DoSession.PLANNED_MINUTES,
                    JsonValue.IntegerValue(it.coerceIn(1L, RegistryEntityLimits.DO_PLANNED_MINUTES_MAX)),
                )
            }
            stamp(RegistryEntityFields.DoSession.CONFIRMED_AT)?.let { put(RegistryEntityFields.DoSession.CONFIRMED_AT, it) }
            put(RegistryEntityFields.DoSession.ENDED_AT, ended ?: started)
            put(RegistryEntityFields.DoSession.EXIT, JsonValue.StringValue(exit ?: RegistryEntityEnums.DoExit.STOPPED))
            put(
                RegistryEntityFields.DoSession.LAPSED,
                JsonValue.BooleanValue(ended == null || row[RegistryEntityFields.DoSession.LAPSED].booleanValue() == true),
            )
            row[RegistryEntityFields.DoSession.NOTE].stringValue()?.takeIf(String::isNotBlank)?.let {
                put(
                    RegistryEntityFields.DoSession.NOTE,
                    JsonValue.StringValue(it.take(RegistryEntityLimits.DO_NOTE_MAX.toInt())),
                )
            }
            row[RegistryEntityFields.DoSession.SOURCE_CLIENT]?.stringValue()?.takeIf(String::isNotBlank)?.let {
                put(RegistryEntityFields.DoSession.SOURCE_CLIENT, JsonValue.StringValue(it))
            }
        }
    }

    suspend fun exportMarkdown(store: TaskStore): String {
        val areas = store.records(RegistryEntityNames.AREA).filter { it.deletedAt == null }
        val projects = store.records(RegistryEntityNames.PROJECT).filter { it.deletedAt == null }
        val tasks = store.records(RegistryEntityNames.TASK).filter { it.deletedAt == null }
        val areaTitles = areas.associate { it.id to (it.fields[RegistryEntityFields.Area.TITLE].stringValue() ?: it.id) }
        val projectTitles = projects.associate { it.id to (it.fields[RegistryEntityFields.Project.TITLE].stringValue() ?: it.id) }

        val sb = StringBuilder()
        sb.appendLine("# Septena Tasks")
        sb.appendLine()
        val grouped = tasks.groupBy { r ->
            val proj = r.fields[RegistryEntityFields.Task.PROJECT].stringValue()?.let(projectTitles::get)
            val area = r.fields[RegistryEntityFields.Task.AREA].stringValue()?.let(areaTitles::get)
            when {
                area != null && proj != null -> "$area › $proj"
                proj != null -> proj
                area != null -> area
                // The exported file is English on every device, as the Apple export is.
                else -> "Inbox" // septena-lint:allow registry-owned-literal
            }
        }
        for ((section, rows) in grouped) {
            sb.appendLine("## $section")
            sb.appendLine()
            for (r in rows) {
                val status = r.fields[RegistryEntityFields.Task.STATUS].stringValue()
                val mark = if (status == RegistryEntityEnums.TaskStatus.DONE) "x" else " "
                val title = r.fields[RegistryEntityFields.Task.TITLE].stringValue().orEmpty()
                val meta = listOfNotNull(
                    r.fields[RegistryEntityFields.Task.SCHEDULED].stringValue()?.let { "when:$it" },
                    r.fields[RegistryEntityFields.Task.DEADLINE].stringValue()?.let { "due:$it" },
                ).joinToString(" ")
                val suffix = if (meta.isEmpty()) "" else " ($meta)"
                sb.appendLine("- [$mark] $title$suffix")
                val notes = r.fields[RegistryEntityFields.Task.NOTES].stringValue()?.trim().orEmpty()
                if (notes.isNotEmpty()) {
                    notes.lines().forEach { line -> sb.appendLine("  > $line") }
                }
            }
            sb.appendLine()
        }
        return sb.toString()
    }

    suspend fun exportCsv(store: TaskStore): String {
        val areas = store.records(RegistryEntityNames.AREA).filter { it.deletedAt == null }
            .associate { it.id to (it.fields[RegistryEntityFields.Area.TITLE].stringValue() ?: it.id) }
        val projects = store.records(RegistryEntityNames.PROJECT).filter { it.deletedAt == null }
            .associate { it.id to (it.fields[RegistryEntityFields.Project.TITLE].stringValue() ?: it.id) }
        val tasks = store.records(RegistryEntityNames.TASK).filter { it.deletedAt == null }

        val sb = StringBuilder()
        sb.appendLine("id,title,status,area,project,today,scheduled,deadline,starred,notes")
        for (r in tasks) {
            val f = r.fields
            val cols = listOf(
                r.id,
                f[RegistryEntityFields.Task.TITLE].stringValue().orEmpty(),
                f[RegistryEntityFields.Task.STATUS].stringValue().orEmpty(),
                f[RegistryEntityFields.Task.AREA].stringValue()?.let(areas::get).orEmpty(),
                f[RegistryEntityFields.Task.PROJECT].stringValue()?.let(projects::get).orEmpty(),
                (f[RegistryEntityFields.Task.TODAY].booleanValue() == true).toString(),
                f[RegistryEntityFields.Task.SCHEDULED].stringValue().orEmpty(),
                f[RegistryEntityFields.Task.DEADLINE].stringValue().orEmpty(),
                (f[RegistryEntityFields.Task.STARRED].booleanValue() == true).toString(),
                f[RegistryEntityFields.Task.NOTES].stringValue().orEmpty(),
            )
            sb.appendLine(cols.joinToString(",", transform = ::csvEscape))
        }
        return sb.toString()
    }

    fun csvEscape(value: String): String {
        if (!value.any { it == ',' || it == '"' || it == '\n' || it == '\r' }) return value
        return "\"" + value.replace("\"", "\"\"") + "\""
    }

    fun parseEnvelope(rawJson: String): Result<ParsedTransferEnvelope> = runCatching {
        val root = JsonValue.parse(rawJson) as? JsonValue.ObjectValue
            ?: error("That file isn’t valid JSON.")
        val version = (root.fields["septena_export_version"] as? JsonValue.IntegerValue)?.value?.toInt()
            ?: error("Missing the Septena export header.")
        if (version > ENVELOPE_VERSION.toInt()) {
            error("Export version $version is newer than this version of Septena understands.")
        }
        val section = root.fields["section"].stringValue()
            ?: error("Missing the Septena export header.")
        val tables = (root.fields["tables"] as? JsonValue.ObjectValue)?.fields
            ?: error("Missing the Septena export tables.")

        fun rowsOf(key: String): List<Map<String, JsonValue>> =
            (tables[key] as? JsonValue.ArrayValue)?.values.orEmpty()
                .mapNotNull { (it as? JsonValue.ObjectValue)?.fields }

        val supportedKeys = setOf(
            "area", "project", "task", "tag", "checklist_item", "task_ref", DO_SESSION_TABLE, "task_attachment",
        )
        val skipped = tables.entries
            .filter { it.key !in supportedKeys }
            .sumOf { (_, v) -> (v as? JsonValue.ArrayValue)?.values?.size ?: 0 }

        ParsedTransferEnvelope(
            version = version,
            section = section,
            areas = rowsOf("area"),
            projects = rowsOf("project"),
            tasks = rowsOf("task"),
            tags = rowsOf("tag"),
            checklistItems = rowsOf("checklist_item"),
            doSessions = rowsOf(DO_SESSION_TABLE),
            skippedCount = skipped,
        )
    }

    /** Imports areas, projects, and tasks through the normal mutators so every row syncs cleanly. */
    suspend fun applyEnvelope(graph: AndroidAppGraph, envelope: ParsedTransferEnvelope): Int {
        var imported = 0
        val areaIdMap = linkedMapOf<String, String>()
        val existingAreas = graph.taskStore.records(RegistryEntityNames.AREA)
            .filter { it.deletedAt == null }
            .associateBy { it.fields[RegistryEntityFields.Area.TITLE].stringValue()?.lowercase().orEmpty() }

        for (row in envelope.areas) {
            val title = row["title"].stringValue()?.trim()?.takeIf(String::isNotEmpty) ?: continue
            val srcId = row["id"].stringValue()
            val match = existingAreas[title.lowercase()]
            val targetId = if (match != null) {
                match.id
            } else {
                val fields = linkedMapOf<String, JsonValue>(RegistryEntityFields.Area.TITLE to JsonValue.StringValue(title))
                row["emoji"].stringValue()?.takeIf(String::isNotBlank)?.let {
                    fields[RegistryEntityFields.Area.EMOJI] = JsonValue.StringValue(it)
                }
                imported += 1
                graph.registryEntityMutator.create(RegistryEntityNames.AREA, fields).id
            }
            if (srcId != null) areaIdMap[srcId] = targetId
        }

        val projectIdMap = linkedMapOf<String, String>()
        val existingProjects = graph.taskStore.records(RegistryEntityNames.PROJECT)
            .filter { it.deletedAt == null }
            .associateBy { it.fields[RegistryEntityFields.Project.TITLE].stringValue()?.lowercase().orEmpty() }

        for (row in envelope.projects) {
            val title = row["title"].stringValue()?.trim()?.takeIf(String::isNotEmpty) ?: continue
            val srcId = row["id"].stringValue()
            val match = existingProjects[title.lowercase()]
            val targetId = if (match != null) {
                match.id
            } else {
                val fields = linkedMapOf<String, JsonValue>(RegistryEntityFields.Project.TITLE to JsonValue.StringValue(title))
                row["area"].stringValue()?.let(areaIdMap::get)?.let {
                    fields[RegistryEntityFields.Project.AREA] = JsonValue.StringValue(it)
                }
                row["notes"].stringValue()?.takeIf(String::isNotBlank)?.let {
                    fields[RegistryEntityFields.Project.NOTES] = JsonValue.StringValue(it)
                }
                imported += 1
                graph.registryEntityMutator.create(RegistryEntityNames.PROJECT, fields).id
            }
            if (srcId != null) projectIdMap[srcId] = targetId
        }

        val taskIdMap = linkedMapOf<String, String>()
        val existingTaskIds = graph.taskStore.records(RegistryEntityNames.TASK).mapTo(HashSet()) { it.id }
        for (row in envelope.tasks) {
            val srcId = row["id"].stringValue()
            if (srcId != null && srcId in existingTaskIds) {
                taskIdMap[srcId] = srcId
                continue
            }
            val title = row["title"].stringValue()?.trim()?.takeIf(String::isNotEmpty) ?: continue
            val projId = row["project"].stringValue()?.let(projectIdMap::get)
            val areaId = if (projId == null) row["area"].stringValue()?.let(areaIdMap::get) else null
            val created = graph.taskMutator.create(
                title = title,
                notes = row["notes"].stringValue(),
                area = areaId,
                project = projId,
                today = row["today"].booleanValue() == true,
                scheduled = row["scheduled"].stringValue(),
                deadline = row["deadline"].stringValue(),
                addedVia = TaskAddedVia.IMPORT,
            )
            if (row["starred"].booleanValue() == true) {
                graph.taskMutator.setStarred(created.id, true)
            }
            if (row["status"].stringValue() == RegistryEntityEnums.TaskStatus.DONE) {
                graph.taskMutator.complete(created.id)
            }
            if (srcId != null) taskIdMap[srcId] = created.id
            imported += 1
        }

        for (row in envelope.doSessions) {
            val id = row["id"].stringValue() ?: continue
            val taskId = (row[DO_SESSION_TASK_KEY] ?: row[RegistryEntityFields.DoSession.TASK_ID]).stringValue()
                ?.let(taskIdMap::get) ?: continue
            val fields = importedDoSession(row, taskId) ?: continue
            if (graph.doSessions.importEnded(id, fields)) imported += 1
        }
        return imported
    }
}

/** Settings custom surface `import_export` (`data.import-export`, #370). */
@Composable
internal fun DataTransferSection(graph: AndroidAppGraph, languageTag: String) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var pendingImport by remember { mutableStateOf<ParsedTransferEnvelope?>(null) }
    var statusMessage by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }

    val stamp = remember { LocalDate.now(ZoneOffset.UTC).toString() }
    fun copy(id: String, vararg args: Pair<String, String>) = settingsCopy(IMPORT_EXPORT, id, languageTag, *args)

    val exportJsonLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/json"),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            busy = true
            runCatching {
                val payload = withContext(Dispatchers.IO) {
                    TaskDataTransferCodec.exportJson(graph.taskStore, graph.clock.now())
                }
                withContext(Dispatchers.IO) {
                    context.contentResolver.openOutputStream(uri)?.use { it.write(payload.toByteArray()) }
                        ?: error(copy("exportFailed"))
                }
            }.onSuccess {
                statusMessage = copy("exportedJson")
            }.onFailure {
                statusMessage = it.message ?: copy("exportFailed")
            }
            busy = false
        }
    }

    val exportMdLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("text/markdown"),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            busy = true
            runCatching {
                val payload = withContext(Dispatchers.IO) { TaskDataTransferCodec.exportMarkdown(graph.taskStore) }
                withContext(Dispatchers.IO) {
                    context.contentResolver.openOutputStream(uri)?.use { it.write(payload.toByteArray()) }
                        ?: error(copy("exportFailed"))
                }
            }.onSuccess {
                statusMessage = copy("exportedMarkdown")
            }.onFailure {
                statusMessage = it.message ?: copy("exportFailed")
            }
            busy = false
        }
    }

    val exportCsvLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("text/csv"),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            busy = true
            runCatching {
                val payload = withContext(Dispatchers.IO) { TaskDataTransferCodec.exportCsv(graph.taskStore) }
                withContext(Dispatchers.IO) {
                    context.contentResolver.openOutputStream(uri)?.use { it.write(payload.toByteArray()) }
                        ?: error(copy("exportFailed"))
                }
            }.onSuccess {
                statusMessage = copy("exportedCsv")
            }.onFailure {
                statusMessage = it.message ?: copy("exportFailed")
            }
            busy = false
        }
    }

    val importJsonLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            busy = true
            val parsed = withContext(Dispatchers.IO) {
                runCatching {
                    val raw = context.contentResolver.openInputStream(uri)?.bufferedReader()?.readText()
                        ?: error(copy("importFailed"))
                    TaskDataTransferCodec.parseEnvelope(raw).getOrThrow()
                }
            }
            busy = false
            parsed.onSuccess { env ->
                pendingImport = env
                statusMessage = null
            }.onFailure {
                statusMessage = it.message ?: copy("importFailed")
            }
        }
    }

    pendingImport?.let { env ->
        AlertDialog(
            onDismissRequest = { if (!busy) pendingImport = null },
            title = { Text(copy("importDialogTitle")) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(
                        copy(
                            "importSummary",
                            "areas" to env.areas.size.toString(),
                            "projects" to env.projects.size.toString(),
                            "tasks" to env.tasks.size.toString(),
                        ),
                    )
                    if (env.skippedCount > 0) {
                        Text(
                            copy("importSkipped", "count" to env.skippedCount.toString()),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Text(
                        copy("importNote"),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            },
            confirmButton = {
                TextButton(
                    enabled = !busy,
                    onClick = {
                        scope.launch {
                            busy = true
                            val result = runCatching {
                                withContext(Dispatchers.IO) { TaskDataTransferCodec.applyEnvelope(graph, env) }
                            }
                            busy = false
                            pendingImport = null
                            result.onSuccess { count ->
                                graph.sync.noteLocalChange()
                                graph.sync.requestSync()
                                val msg = copy("importedCount", "count" to count.toString())
                                statusMessage = msg
                                Toast.makeText(context, msg, Toast.LENGTH_SHORT).show()
                            }.onFailure {
                                statusMessage = it.message ?: copy("importFailed")
                            }
                        }
                    },
                ) {
                    Text(copy("importConfirm"))
                }
            },
            dismissButton = {
                TextButton(enabled = !busy, onClick = { pendingImport = null }) {
                    Text(promptCancelTitle(languageTag))
                }
            },
        )
    }

    Column(modifier = Modifier.fillMaxWidth()) {
        ListItem(
            headlineContent = { Text(copy("exportJsonTitle"), color = MaterialTheme.colorScheme.primary) },
            supportingContent = { Text(copy("exportJsonDetail")) },
            modifier = Modifier.fillMaxWidth().clickable(enabled = !busy) {
                exportJsonLauncher.launch("septena-tasks-$stamp.json")
            },
        )
        ListItem(
            headlineContent = { Text(copy("exportMarkdownTitle"), color = MaterialTheme.colorScheme.primary) },
            supportingContent = { Text(copy("exportMarkdownDetail")) },
            modifier = Modifier.fillMaxWidth().clickable(enabled = !busy) {
                exportMdLauncher.launch("septena-tasks-$stamp.md")
            },
        )
        ListItem(
            headlineContent = { Text(copy("exportCsvTitle"), color = MaterialTheme.colorScheme.primary) },
            supportingContent = { Text(copy("exportCsvDetail")) },
            modifier = Modifier.fillMaxWidth().clickable(enabled = !busy) {
                exportCsvLauncher.launch("septena-tasks-$stamp.csv")
            },
        )
        ListItem(
            headlineContent = { Text(copy("importJsonTitle"), color = MaterialTheme.colorScheme.primary) },
            supportingContent = { Text(copy("importJsonDetail")) },
            modifier = Modifier.fillMaxWidth().clickable(enabled = !busy) {
                importJsonLauncher.launch(arrayOf("application/json", "text/plain", "*/*"))
            },
        )
        statusMessage?.let { msg ->
            Text(
                text = msg,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
            )
        }
    }
}

private const val IMPORT_EXPORT = "import_export"
