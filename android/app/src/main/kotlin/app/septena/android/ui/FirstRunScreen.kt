package app.septena.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.septena.android.AndroidAppGraph
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.generated.RegistryPlatformIds
import app.septena.core.generated.RegistryTaskDetail
import app.septena.core.stringValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// The first run on Android, as on iOS (`SeptaskFirstRunView`): every step, its copy, its platforms and what
// each button does come from registry/surfaces.json `firstRun`. This file renders a step by its `kind` and
// runs the closed set of button actions the registry may name; it holds no copy of its own (ADR 0015).
// A step limited to other platforms (`platforms`), or whose `featureId` does not ship on Android, is
// skipped. "choices" steps (the Apple importers) have no Android action, so they are skipped too.

private data class FirstRunButton(val title: String, val action: String)

private data class FirstRunPoint(val title: String, val detail: String)

private data class FirstRunStep(
    val id: String,
    val kind: String,
    val title: String,
    val body: String,
    val footnote: String?,
    val returningTitle: String?,
    val returningBody: String?,
    val skipWhen: String?,
    val requires: String?,
    val platforms: List<String>,
    val featureId: String?,
    val points: List<FirstRunPoint>,
    val instructions: List<String>,
    val primary: FirstRunButton?,
    val secondary: FirstRunButton?,
    val tertiary: FirstRunButton?,
    /** Replaces [secondary] once the step's work is done (Claude is paired). */
    val afterDone: FirstRunButton?,
)

/**
 * The first-run button actions Android runs. The account step's sign-in action needs no entry: that step
 * renders the sign-in panel in place of its primary button. The Apple importers never reach a button here.
 */
private val SUPPORTED_ACTIONS = setOf("next", "finish", "copySetupPrompt", "copyFirstPrompt")

/** The step kinds this file draws. */
private val RENDERED_KINDS = setOf("intro", "account", "connectAgent", "finish")

private val firstRun: JsonValue.ObjectValue?
    get() = RegistryCatalog.document("surfaces").fields["firstRun"] as? JsonValue.ObjectValue

private fun firstRunSteps(languageTag: String): List<FirstRunStep> {
    fun text(value: JsonValue?): String = registryText(value.stringValue(), languageTag)
    fun optText(value: JsonValue?): String? = value.stringValue()?.let { registryText(it, languageTag) }
    fun strings(value: JsonValue?): List<String> =
        (value as? JsonValue.ArrayValue)?.values.orEmpty().mapNotNull(JsonValue?::stringValue)
    fun button(value: JsonValue?): FirstRunButton? {
        val fields = (value as? JsonValue.ObjectValue)?.fields ?: return null
        val action = fields["action"].stringValue() ?: return null
        return FirstRunButton(text(fields["title"]), action)
    }
    val steps = (firstRun?.fields?.get("steps") as? JsonValue.ArrayValue)?.values.orEmpty()
    return steps.mapNotNull { raw ->
        val f = (raw as? JsonValue.ObjectValue)?.fields ?: return@mapNotNull null
        FirstRunStep(
            id = f["id"].stringValue() ?: return@mapNotNull null,
            kind = f["kind"].stringValue().orEmpty(),
            title = text(f["title"]),
            body = text(f["body"]),
            footnote = optText(f["footnote"]),
            returningTitle = optText(f["returningTitle"]),
            returningBody = optText(f["returningBody"]),
            skipWhen = f["skipWhen"].stringValue(),
            requires = f["requires"].stringValue(),
            platforms = strings(f["platforms"]),
            featureId = f["featureId"].stringValue(),
            points = (f["points"] as? JsonValue.ArrayValue)?.values.orEmpty().mapNotNull { point ->
                val p = (point as? JsonValue.ObjectValue)?.fields ?: return@mapNotNull null
                FirstRunPoint(text(p["title"]), text(p["detail"]))
            },
            instructions = strings(f["instructions"]).map { registryText(it, languageTag) },
            primary = button(f["primary"]),
            secondary = button(f["secondary"]),
            tertiary = button(f["tertiary"]),
            afterDone = button(f["afterDone"]),
        )
    }
}

/** Whether this step shows on Android in the current sign-in state (`applies` on iOS). */
private fun FirstRunStep.applies(signedIn: Boolean): Boolean {
    if (platforms.isNotEmpty() && RegistryPlatformIds.ANDROID !in platforms) return false
    featureId?.let { id ->
        if (RegistryCatalog.capabilityStatus(id) !in setOf("ships", "partial")) return false
    }
    if (skipWhen == "signedIn" && signedIn) return false
    if (requires == "signedIn" && !signedIn) return false
    if (kind !in RENDERED_KINDS) return false
    return true
}

private fun firstRunPrompt(key: String, languageTag: String): String {
    val prompts = firstRun?.fields?.get("prompts") as? JsonValue.ObjectValue
    return registryText(prompts?.fields?.get(key).stringValue(), languageTag)
}

private fun firstRunChrome(id: String, languageTag: String): String {
    val chrome = (firstRun?.fields?.get("chrome") as? JsonValue.ArrayValue)?.values.orEmpty()
    val entry = chrome.firstOrNull { (it as? JsonValue.ObjectValue)?.fields?.get("id").stringValue() == id }
        as? JsonValue.ObjectValue
    return registryText(entry?.fields?.get("label").stringValue(), languageTag)
}

/** The first-run flow. Finishing or closing it stamps the first run as done (`FirstRunState.markComplete`). */
@Composable
fun FirstRunScreen(graph: AndroidAppGraph) {
    val context = LocalContext.current
    val languageTag = LocalConfiguration.current.locales[0].toLanguageTag()
    val scope = rememberCoroutineScope()
    val signedIn by graph.credentials.signedIn.collectAsStateWithLifecycle()
    val steps = remember(languageTag) { firstRunSteps(languageTag) }
    var currentId by rememberSaveable { mutableStateOf(steps.firstOrNull()?.id.orEmpty()) }
    val history = remember { mutableStateListOf<String>() }
    /** Sign-in found an account that already finished its first run. */
    var returning by rememberSaveable { mutableStateOf(false) }
    var checkingAccount by remember { mutableStateOf(false) }
    /** Steps whose work is done: they show `afterDone`. */
    val doneSteps = remember { mutableStateListOf<String>() }
    /** The copy action that ran last on this step; its button reads "Copied", as on iOS. */
    var copiedAction by remember(currentId) { mutableStateOf<String?>(null) }
    val step = steps.firstOrNull { it.id == currentId } ?: return

    val backTitle = RegistryCatalog.surface(RegistryTaskDetail.ID)
        ?.fields?.get("controls")?.let { it as? JsonValue.ObjectValue }?.fields?.get("back")
        .stringValue().let { registryText(it, languageTag) }

    fun advance() {
        val index = steps.indexOfFirst { it.id == currentId }
        if (index < 0) return
        val next = steps.drop(index + 1).firstOrNull { it.applies(graph.credentials.signedIn.value) } ?: steps.last()
        if (next.id == currentId) return
        history.add(currentId)
        currentId = next.id
    }

    fun finish() {
        scope.launch { withContext(Dispatchers.IO) { graph.firstRun.markComplete(graph) } }
    }

    fun perform(action: String) {
        when (action) {
            "next" -> advance()
            "finish" -> finish()
            "copySetupPrompt" -> {
                copyToClipboard(context, step.title, firstRunPrompt("setup", languageTag))
                copiedAction = action
            }
            "copyFirstPrompt" -> {
                copyToClipboard(context, step.title, firstRunPrompt("first", languageTag))
                copiedAction = action
            }
        }
    }

    // Signed in on the account step: pull, then carry on, or jump to the "Welcome back" finish when the
    // account already finished its first run on another device or already holds tasks.
    LaunchedEffect(signedIn, step.kind) {
        if (!signedIn || step.kind != "account") return@LaunchedEffect
        checkingAccount = true
        runCatching { withContext(Dispatchers.IO) { graph.sync.syncAndWait() } }
        val established = withContext(Dispatchers.IO) { graph.firstRun.accountIsEstablished() }
        checkingAccount = false
        if (established) {
            returning = true
            history.add(currentId)
            currentId = steps.last().id
        } else {
            advance()
        }
    }

    // Back skips a step that no longer applies: the account step once signed in would only advance again.
    fun previousIndex(): Int = history.indexOfLast { id -> steps.firstOrNull { it.id == id }?.applies(signedIn) == true }
    val copiedTitle = settingsCopy(CLAUDE_CONNECTOR, "copied", languageTag)
    fun buttonTitle(button: FirstRunButton): String = if (button.action == copiedAction) copiedTitle else button.title
    val canGoBack = step.kind != "finish" && previousIndex() >= 0
    fun goBack() {
        val index = previousIndex()
        if (index < 0) return
        val target = history[index]
        while (history.size > index) history.removeAt(history.lastIndex)
        currentId = target
    }
    BackHandler(enabled = canGoBack, onBack = ::goBack)

    Column(modifier = Modifier.fillMaxSize()) {
        Row(
            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(horizontal = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (canGoBack) {
                TextButton(onClick = ::goBack) { Text(backTitle) }
            }
            Spacer(Modifier.weight(1f))
            // Closing counts as finished, so the first run never traps the user (as on iOS).
            // Settings ▸ About ▸ Show Welcome Again brings it back.
            if (step.kind != "finish") {
                TextButton(onClick = ::finish) { Text(firstRunChrome("close", languageTag)) }
            }
        }
        Column(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            val title = if (returning) step.returningTitle ?: step.title else step.title
            val body = if (returning) step.returningBody ?: step.body else step.body
            Text(
                title,
                style = MaterialTheme.typography.headlineMedium,
                fontWeight = FontWeight.Bold,
                textAlign = TextAlign.Center,
            )
            if (body.isNotEmpty()) {
                Text(
                    body,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                )
            }
            StepContent(
                step = step,
                graph = graph,
                languageTag = languageTag,
                signedIn = signedIn,
                checkingAccount = checkingAccount,
                buttonTitle = ::buttonTitle,
                perform = ::perform,
                onDone = { if (step.id !in doneSteps) doneSteps.add(step.id) },
            )
        }
        StepButtons(step, done = step.id in doneSteps, checkingAccount, ::buttonTitle, ::perform)
    }
}

@Composable
private fun StepContent(
    step: FirstRunStep,
    graph: AndroidAppGraph,
    languageTag: String,
    signedIn: Boolean,
    checkingAccount: Boolean,
    buttonTitle: (FirstRunButton) -> String,
    perform: (String) -> Unit,
    onDone: () -> Unit,
) {
    when (step.kind) {
        "intro" -> Column(
            modifier = Modifier.widthIn(max = 460.dp).fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            for (point in step.points) {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(point.title, style = MaterialTheme.typography.titleMedium)
                    Text(point.detail, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        "account" -> if (checkingAccount) {
            CircularProgressIndicator()
        } else {
            DeviceSignInPanel(
                graph = graph,
                languageTag = languageTag,
                startTitle = step.primary?.title ?: deviceSignInCopy("start", languageTag),
            )
        }
        // The code field is the one on Settings ▸ Connect Claude. Its approval dialog ticks the Get started
        // step itself (`completeConnectAgentStep`), so this step only marks itself done.
        "connectAgent" -> Column(
            modifier = Modifier.widthIn(max = 460.dp).fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            step.instructions.forEachIndexed { index, line ->
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("${index + 1}.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(line)
                }
            }
            step.tertiary?.takeIf { it.action in SUPPORTED_ACTIONS }?.let { tertiary ->
                OutlinedButton(onClick = { perform(tertiary.action) }) { Text(buttonTitle(tertiary)) }
            }
            PairingCodeField(graph, signedIn, languageTag, onApproved = onDone)
        }
    }
}

@Composable
private fun StepButtons(
    step: FirstRunStep,
    done: Boolean,
    checkingAccount: Boolean,
    buttonTitle: (FirstRunButton) -> String,
    perform: (String) -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // The account step's primary button is the sign-in panel's own first button.
        if (step.kind != "account") {
            step.primary?.takeIf { it.action in SUPPORTED_ACTIONS }?.let { primary ->
                Button(
                    onClick = { perform(primary.action) },
                    modifier = Modifier.widthIn(max = 400.dp).fillMaxWidth(),
                ) { Text(buttonTitle(primary)) }
            }
        }
        val secondaryButton = if (done) step.afterDone ?: step.secondary else step.secondary
        secondaryButton?.takeIf { it.action in SUPPORTED_ACTIONS }?.let { secondary ->
            TextButton(onClick = { perform(secondary.action) }, enabled = !checkingAccount) { Text(secondary.title) }
        }
        step.footnote?.let {
            Text(
                it,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
                modifier = Modifier.widthIn(max = 400.dp),
            )
        }
    }
}
