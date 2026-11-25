package app.septena.android.ui

import android.content.Context
import android.widget.Toast
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import app.septena.android.AndroidAppGraph
import app.septena.android.sync.SyncState
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.RejectedSyncOperation
import app.septena.core.SyncOperation
import app.septena.core.generated.RegistrySettingKeys
import app.septena.core.generated.RegistryTaskPageBlockIds
import app.septena.core.stringValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** What a custom settings surface may read and change. Built once by [SettingsScreen]. */
internal class SettingsSurfaceEnv(
    val graph: AndroidAppGraph,
    val plans: PlanSettingsModel,
    val syncState: SyncState,
    val signedIn: Boolean,
    val values: Map<String, JsonValue>,
    val onValueChange: (String, JsonValue) -> Unit,
)

/** The custom surfaces this file renders; the others stay in SettingsScreen or their own files. */
internal val SETTINGS_SURFACES = setOf(
    "about_header", "open_source", "send_feedback", "privacy_explainer", "ai_explainer",
    "mcp_skills", "sync_diagnostics", "smart_lists_editor", "plus_offer", "calendar_detail",
    "reset_first_run", DELETE_ACCOUNT,
    "sign_in_approval", "claude_connector", "import_export",
)

@Composable
internal fun SettingsCustomSurface(
    surface: String,
    label: String?,
    detail: String?,
    env: SettingsSurfaceEnv,
    languageTag: String,
) {
    val context = LocalContext.current
    when (surface) {
        "about_header" -> AboutHeader(label, detail, context)
        "open_source" -> OpenSourceRow(label, detail) { openUrl(context, REPO_URL) }
        "send_feedback" -> ActionRow(label) {
            if (!openUrl(context, FEEDBACK_URL)) {
                copyToClipboard(context, label.orEmpty(), FEEDBACK_EMAIL)
                Toast.makeText(context, FEEDBACK_EMAIL, Toast.LENGTH_SHORT).show()
            }
        }
        "privacy_explainer" -> detail?.let { Text(it, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) }
        "ai_explainer" -> ExpandableRow(label) { AiExplainer(appName(context), languageTag) }
        // `reset_get_started` is omitted on Android until Android renders the Get Started notice.
        // This device only: the synced `onboardedAt` stays, so other devices are not asked again (as on iOS).
        "reset_first_run" -> ActionRow(label) { env.graph.firstRun.showAgain() }
        DELETE_ACCOUNT -> DeleteAccountRow(env.graph, env.signedIn, languageTag)
        "mcp_skills" -> ExpandableRow(label) { SkillBrief(env.graph, languageTag) }
        "sync_diagnostics" -> SyncDiagnostics(env.graph, label, detail, languageTag)
        "smart_lists_editor" -> SmartListsEditor(env.values, languageTag, env.onValueChange)
        "plus_offer" -> {
            LaunchedEffect(env.signedIn) { env.plans.refresh(env.signedIn) }
            PlusOffer(env.plans, languageTag)
        }
        "calendar_detail" -> CalendarFeedSection(env.graph, env.signedIn, env.values, env.onValueChange, languageTag)
        "sign_in_approval" -> SignInApprovalSection(env.graph, env.signedIn, languageTag)
        "claude_connector" -> ClaudeConnectorSection(env.graph, env.signedIn, languageTag)
        "import_export" -> DataTransferSection(env.graph, languageTag)
    }
}

/** Surface `about_header`: app name, tagline (label) and "Version {version}" (detail). */
@Composable
private fun AboutHeader(tagline: String?, detail: String?, context: Context) {
    val info = remember(context) { context.packageManager.getPackageInfo(context.packageName, 0) }
    val version = "${info.versionName.orEmpty()} (${info.longVersionCode})"
    Column(
        modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(appName(context), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
        tagline?.let { Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center) }
        detail?.let {
            Text(
                it.replace("{version}", version),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun OpenSourceRow(label: String?, detail: String?, onClick: () -> Unit) {
    val title = label ?: return
    ListItem(
        headlineContent = { Text(title) },
        supportingContent = detail?.let { { Text(it) } },
        trailingContent = { Text("↗", color = MaterialTheme.colorScheme.onSurfaceVariant) },
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick),
    )
}

@Composable
private fun ActionRow(label: String?, onClick: () -> Unit) {
    val title = label ?: return
    ListItem(
        headlineContent = { Text(title, color = MaterialTheme.colorScheme.primary) },
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick),
    )
}

/** A row that opens its content in place; iOS pushes a sheet or a page for the same surface. */
@Composable
private fun ExpandableRow(label: String?, content: @Composable () -> Unit) {
    val title = label ?: return
    var open by rememberSaveable(title) { mutableStateOf(false) }
    ListItem(
        headlineContent = { Text(title) },
        trailingContent = { Text(if (open) "⌃" else "⌄", color = MaterialTheme.colorScheme.onSurfaceVariant) },
        modifier = Modifier.fillMaxWidth().clickable { open = !open },
    )
    if (open) content()
}

/** Surface `ai_explainer`: how a task conversation moves, like iOS `AIExplainerView`. */
@Composable
private fun AiExplainer(app: String, languageTag: String) {
    fun copy(id: String) = settingsCopy(AI_EXPLAINER, id, languageTag, "app" to app)
    val selfLabel = registryText(RegistryCatalog.surface(RegistryTaskPageBlockIds.TASK_PAGE_PROVENANCE)?.fields?.get("selfLabel").stringValue(), languageTag)
    val steps = listOf(
        Pair("capture", selfLabel),
        Pair("confirm", copy("runsOnDevice")),
        Pair("lookUp", copy("runsOnDevice")),
        Pair("decide", copy("runsReaches")),
        Pair("work", copy("runsReaches")),
        Pair("handOff", selfLabel),
    )
    Column(
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(copy("intro"), style = MaterialTheme.typography.titleSmall)
        Text(copy("flowHeader"), fontWeight = FontWeight.SemiBold)
        steps.forEach { (id, runs) ->
            Column {
                Text("${copy("${id}Title")} · $runs", fontWeight = FontWeight.SemiBold)
                Text(copy("${id}Detail"), style = MaterialTheme.typography.bodySmall)
            }
        }
        Text(copy("flowFooter"), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(copy("turnHeader"), fontWeight = FontWeight.SemiBold)
        Text("● ${copy("turnYours")}")
        Text("● ${copy("turnAI")}")
        Text("● ${copy("turnDone")}")
        Text(copy("localHeader"), fontWeight = FontWeight.SemiBold)
        Text(copy("localBody"), color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(copy("privateHeader"), fontWeight = FontWeight.SemiBold)
        Text(copy("privateBody"), color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(copy("closing"), color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/**
 * Surface `mcp_skills`: the agent brief for the task tools, as the server serves it
 * (`/skill.md`, generated from the same source as the iOS pane), with a copy button.
 */
@Composable
private fun SkillBrief(graph: AndroidAppGraph, languageTag: String) {
    val context = LocalContext.current
    var brief by remember { mutableStateOf<String?>(null) }
    var failed by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        try {
            brief = graph.access.skillBrief()
        } catch (failure: Exception) {
            if (failure is kotlinx.coroutines.CancellationException) throw failure
            failed = true
        }
    }
    val text = brief
    when {
        text != null -> {
            TextButton(onClick = { copyToClipboard(context, settingsCopy(MCP_SKILLS, "copySkill", languageTag), text) }) {
                Text(settingsCopy(MCP_SKILLS, "copySkill", languageTag))
            }
            SectionFooter(settingsCopy(MCP_SKILLS, "copyFooter", languageTag))
            Text(
                text,
                style = MaterialTheme.typography.bodySmall,
                fontFamily = FontFamily.Monospace,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            )
        }
        failed -> SectionFooter(settingsCopy(MCP_SKILLS, "loadFailed", languageTag))
        else -> CircularProgressIndicator(modifier = Modifier.padding(16.dp))
    }
}

/** Surface `sync_diagnostics`: changes the server refused, newest first (iOS `SeptaskAdvancedPane`). */
@Composable
private fun SyncDiagnostics(graph: AndroidAppGraph, label: String?, detail: String?, languageTag: String) {
    var issues by remember { mutableStateOf<List<RejectedSyncOperation>?>(null) }
    LaunchedEffect(graph) {
        issues = runCatching {
            withContext(Dispatchers.IO) { graph.taskStore.notSyncedOperations() }
        }.getOrDefault(emptyList()).sortedByDescending { it.rejectedAt }
    }
    label?.let { SectionHeader(it) }
    val current = issues
    if (current != null) {
        ListItem(
            headlineContent = { Text(settingsCopy(SYNC_DIAGNOSTICS, "issues", languageTag)) },
            trailingContent = { Text(current.size.toString(), color = MaterialTheme.colorScheme.onSurfaceVariant) },
        )
        current.take(MAX_ISSUES).forEach { issue ->
            ListItem(
                headlineContent = {
                    Text(issue.operation.subject(), style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace)
                },
                supportingContent = { Text(issue.reason, style = MaterialTheme.typography.bodySmall) },
            )
        }
    }
    detail?.let { SectionFooter(it) }
}

private fun SyncOperation.subject(): String = when (this) {
    is SyncOperation.Upsert -> "$entity $id"
    is SyncOperation.Delete -> "$entity $id"
    is SyncOperation.AppendTurn -> taskId
}

internal fun appName(context: Context): String = context.applicationInfo.loadLabel(context.packageManager).toString()

private const val AI_EXPLAINER = "ai_explainer"
private const val MCP_SKILLS = "mcp_skills"
private const val SYNC_DIAGNOSTICS = "sync_diagnostics"
private const val MAX_ISSUES = 20
private const val FEEDBACK_EMAIL = "mz@envisioning.com"
private const val FEEDBACK_URL = "mailto:mz@envisioning.com?subject=Septena%20feedback"
private const val REPO_URL = "https://github.com/michellzappa/septena"
