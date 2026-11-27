package app.septena.android.ui

import android.content.Context
import android.content.pm.PackageManager
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import app.septena.android.AndroidAppGraph
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.generated.RegistryPromptIds
import app.septena.core.stringValue
import app.septena.transport.AccessHttpException
import app.septena.transport.AgentConnection
import app.septena.transport.PairCode
import app.septena.transport.PairingRequest
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import kotlinx.coroutines.launch

/**
 * Surface `sign_in_approval` (Settings ▸ Account ▸ Devices, signed in only): a row that opens
 * [ApproveSignInDialog]. Same as Apple `SeptaskSignInApprovalSection`. Sign-in methods are
 * their own surface on the Account page (`sign_in_methods`).
 */
@Composable
internal fun SignInApprovalSection(graph: AndroidAppGraph, signedIn: Boolean, languageTag: String) {
    if (!signedIn) return
    var open by remember { mutableStateOf(false) }
    ListItem(
        headlineContent = { Text(approvalCopy("title", languageTag), color = MaterialTheme.colorScheme.primary) },
        modifier = Modifier.fillMaxWidth().clickable { open = true },
    )
    SectionFooter(approvalCopy("footer", languageTag))
    if (open) {
        ApproveSignInDialog(graph = graph, languageTag = languageTag, onDismiss = { open = false })
    }
}

/**
 * Surface `claude_connector` (Settings ▸ Agents): the setup and first prompts,
 * the connector URL, and the code field for the browser's code. Same as Apple
 * `SeptaskClaudePairingSections`; the agent tools row is the page's next section.
 */
@Composable
internal fun ClaudeConnectorSection(graph: AndroidAppGraph, signedIn: Boolean, languageTag: String) {
    val context = LocalContext.current
    var copied by remember { mutableStateOf<String?>(null) }
    fun copy(id: String, text: String) {
        copyToClipboard(context, connectorCopy(id, languageTag), text)
        copied = id
    }

    if (!signedIn) {
        SectionHeader(connectorCopy("signInHeader", languageTag))
        SectionFooter(connectorCopy("signInBody", languageTag))
    }
    val prompts = (RegistryCatalog.document("surfaces").fields["firstRun"] as? JsonValue.ObjectValue)
        ?.fields?.get("prompts") as? JsonValue.ObjectValue
    val setupPrompt = registryText(prompts?.fields?.get("setup").stringValue(), languageTag)
    val firstPrompt = registryText(prompts?.fields?.get("first").stringValue(), languageTag)
    CopyRow(
        connectorCopy("connectorUrl", languageTag),
        copied == "connectorUrl",
        languageTag,
        supporting = CONNECTOR_URL,
        monospacedSupporting = true,
    ) { copy("connectorUrl", CONNECTOR_URL) }
    CopyRow(
        connectorCopy("setupPrompt", languageTag),
        copied == "setupPrompt",
        languageTag,
        supporting = connectorCopy("setupPromptDetail", languageTag),
    ) { copy("setupPrompt", setupPrompt) }
    CopyRow(
        connectorCopy("firstPrompt", languageTag),
        copied == "firstPrompt",
        languageTag,
        supporting = connectorCopy("firstPromptDetail", languageTag),
    ) { copy("firstPrompt", firstPrompt) }
    SectionFooter(connectorCopy("connectorUrlDetail", languageTag))
    SectionHeader(connectorCopy("approveHeader", languageTag))
    PairingCodeField(graph, signedIn, languageTag)
    SectionFooter(connectorCopy("footer", languageTag))
}

@Composable
private fun CopyRow(
    title: String,
    copied: Boolean,
    languageTag: String,
    supporting: String? = null,
    monospacedSupporting: Boolean = false,
    onCopy: () -> Unit,
) {
    ListItem(
        headlineContent = { Text(title) },
        supportingContent = supporting?.let {
            {
                Text(
                    it,
                    fontFamily = if (monospacedSupporting) FontFamily.Monospace else null,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        },
        trailingContent = {
            TextButton(onClick = onCopy) {
                Text(connectorCopy(if (copied) "copied" else "copy", languageTag))
            }
        },
        modifier = Modifier.fillMaxWidth(),
    )
}

/**
 * The code field for a sign-in code on Settings ▸ Agents. Continue opens
 * [ApproveSignInDialog], which looks the code up and shows who asks before the user
 * approves; a device code typed here reads "Sign in on <device>?", never "Connect Claude".
 */
@Composable
internal fun PairingCodeField(graph: AndroidAppGraph, signedIn: Boolean, languageTag: String, onApproved: () -> Unit = {}) {
    var code by remember { mutableStateOf("") }
    var reviewing by remember { mutableStateOf<String?>(null) }
    fun review() {
        if (!signedIn) return
        PairCode.normalized(code)?.let { reviewing = it }
    }
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        OutlinedTextField(
            value = code,
            onValueChange = { code = it.take(MAX_CODE_INPUT) },
            label = { Text(connectorCopy("codePlaceholder", languageTag)) },
            singleLine = true,
            enabled = signedIn,
            textStyle = MaterialTheme.typography.bodyLarge.copy(fontFamily = FontFamily.Monospace),
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters, imeAction = ImeAction.Go),
            keyboardActions = KeyboardActions(onGo = { review() }),
            modifier = Modifier.weight(1f),
        )
        TextButton(onClick = ::review, enabled = signedIn && PairCode.normalized(code) != null) {
            Text(approvalCopy("continue", languageTag))
        }
    }
    if (signedIn) {
        ScanCodeButton(languageTag, modifier = Modifier.padding(horizontal = 16.dp)) { scanned -> reviewing = scanned }
    }
    reviewing?.let { initial ->
        ApproveSignInDialog(
            graph = graph,
            languageTag = languageTag,
            initialCode = initial,
            onDismiss = { reviewing = null },
            onApproved = {
                code = ""
                onApproved()
            },
        )
    }
}

private sealed interface ApprovalStep {
    data object Enter : ApprovalStep
    data object Checking : ApprovalStep
    data class Confirm(val request: PairingRequest, val approving: Boolean) : ApprovalStep
    data class Done(val request: PairingRequest) : ApprovalStep
    data class Failed(val message: String) : ApprovalStep
}

/**
 * Approving a sign-in code (ADR 0016), one flow for both kinds of code, so the user
 * always sees who asks and what they get before anything is approved. Enter or scan
 * the code, the app looks it up (`POST /v1/pair/inspect`), the user confirms, then
 * the app approves it for exactly that kind (`POST /v1/pair/approve`). A connector
 * code also takes the agent's name and the agent it replaces. Same flow as Apple
 * `SeptaskApproveSignInFlow`.
 */
@Composable
internal fun ApproveSignInDialog(
    graph: AndroidAppGraph,
    languageTag: String,
    initialCode: String = "",
    onDismiss: () -> Unit,
    onApproved: (PairingRequest) -> Unit = {},
) {
    val scope = rememberCoroutineScope()
    var code by remember { mutableStateOf(initialCode) }
    var step by remember { mutableStateOf<ApprovalStep>(ApprovalStep.Enter) }
    var agentName by remember { mutableStateOf("") }
    var replaces by remember { mutableStateOf<String?>(null) }
    var agents by remember { mutableStateOf<List<AgentConnection>>(emptyList()) }

    fun check() {
        val normalized = PairCode.normalized(code) ?: return
        step = ApprovalStep.Checking
        scope.launch {
            step = try {
                val request = graph.access.inspectPairing(normalized)
                code = normalized
                if (request.isConnector) {
                    agentName = request.client
                    replaces = null
                    agents = runCatching { graph.access.access().connections }.getOrDefault(emptyList())
                }
                ApprovalStep.Confirm(request, approving = false)
            } catch (failure: Exception) {
                if (failure is kotlinx.coroutines.CancellationException) throw failure
                ApprovalStep.Failed(approvalErrorMessage(failure, languageTag))
            }
        }
    }

    fun approve(request: PairingRequest) {
        step = ApprovalStep.Confirm(request, approving = true)
        scope.launch {
            step = try {
                graph.access.approvePairing(
                    code = code,
                    kind = request.kind,
                    agentName = if (request.isConnector) agentName else null,
                    replaces = if (request.isConnector) replaces else null,
                )
                // The approval stands even when the Get started tick does not land.
                if (request.isConnector) runCatching { completeConnectAgentStep(graph) }
                onApproved(request)
                ApprovalStep.Done(request)
            } catch (failure: Exception) {
                if (failure is kotlinx.coroutines.CancellationException) throw failure
                ApprovalStep.Failed(approvalErrorMessage(failure, languageTag))
            }
        }
    }

    LaunchedEffect(Unit) {
        if (initialCode.isNotEmpty()) check()
    }

    val current = step
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(approvalCopy("title", languageTag)) },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                when (current) {
                    ApprovalStep.Enter -> {
                        OutlinedTextField(
                            value = code,
                            onValueChange = { code = it.take(MAX_CODE_INPUT) },
                            placeholder = { Text(approvalCopy("codePlaceholder", languageTag)) },
                            singleLine = true,
                            textStyle = MaterialTheme.typography.titleLarge.copy(
                                fontFamily = FontFamily.Monospace,
                                textAlign = TextAlign.Center,
                            ),
                            keyboardOptions = KeyboardOptions(
                                capitalization = KeyboardCapitalization.Characters,
                                autoCorrectEnabled = false,
                                imeAction = ImeAction.Go,
                            ),
                            keyboardActions = KeyboardActions(onGo = { check() }),
                            modifier = Modifier.fillMaxWidth(),
                        )
                        Text(
                            approvalCopy("enterFooter", languageTag),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        // A scan fills the code and goes straight to the same confirmation.
                        ScanCodeButton(languageTag) { scanned ->
                            code = scanned
                            check()
                        }
                    }
                    ApprovalStep.Checking -> Progress(approvalCopy("checking", languageTag))
                    is ApprovalStep.Confirm -> {
                        RequestSummary(current.request, languageTag)
                        Text(
                            approvalCopy("safetyFooter", languageTag),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        if (current.request.isConnector) {
                            AgentFields(
                                name = agentName,
                                onNameChange = { agentName = it.take(MAX_AGENT_NAME) },
                                agents = agents,
                                replaces = replaces,
                                onReplacesChange = { replaces = it },
                                enabled = !current.approving,
                                languageTag = languageTag,
                            )
                        }
                        if (current.approving) Progress(approvalCopy("approving", languageTag))
                    }
                    is ApprovalStep.Done -> Text(
                        doneText(current.request, languageTag),
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    is ApprovalStep.Failed -> Text(current.message, color = MaterialTheme.colorScheme.error)
                }
            }
        },
        confirmButton = {
            when (current) {
                ApprovalStep.Enter -> TextButton(onClick = ::check, enabled = PairCode.normalized(code) != null) {
                    Text(approvalCopy("continue", languageTag))
                }
                is ApprovalStep.Confirm -> if (!current.approving) {
                    TextButton(onClick = { approve(current.request) }) {
                        Text(approvalCopy("approve", languageTag), fontWeight = FontWeight.SemiBold)
                    }
                }
                is ApprovalStep.Done -> TextButton(onClick = onDismiss) { Text(approvalCopy("done", languageTag)) }
                is ApprovalStep.Failed -> TextButton(onClick = {
                    code = ""
                    step = ApprovalStep.Enter
                }) { Text(approvalCopy("tryAnother", languageTag)) }
                ApprovalStep.Checking -> Unit
            }
        },
        dismissButton = {
            when (current) {
                is ApprovalStep.Confirm -> if (!current.approving) {
                    TextButton(onClick = onDismiss) { Text(approvalCopy("dontApprove", languageTag)) }
                }
                is ApprovalStep.Done -> Unit
                else -> TextButton(onClick = onDismiss) { Text(promptCancelTitle(languageTag)) }
            }
        },
    )
}

@Composable
private fun Progress(label: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        CircularProgressIndicator(modifier = Modifier.padding(2.dp))
        Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** Who asks and what they get, before the user approves. */
@Composable
private fun RequestSummary(request: PairingRequest, languageTag: String) {
    val (title, detail) = if (request.isConnector) {
        approvalCopy("confirmConnector", languageTag, request.client) to approvalCopy("detailConnector", languageTag, request.client)
    } else {
        approvalCopy("confirmDevice", languageTag, request.client) to approvalCopy("detailDevice", languageTag, request.client)
    }
    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
        Text(detail, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
    }
}

/** A connector code: the agent's name, and the agent it replaces (prompts `nameAgent`, `agentReplaces`). */
@Composable
private fun AgentFields(
    name: String,
    onNameChange: (String) -> Unit,
    agents: List<AgentConnection>,
    replaces: String?,
    onReplacesChange: (String?) -> Unit,
    enabled: Boolean,
    languageTag: String,
) {
    val namePrompt = RegistryCatalog.surface(RegistryPromptIds.NAME_AGENT)?.fields.orEmpty()
    val replacesPrompt = RegistryCatalog.surface(RegistryPromptIds.AGENT_REPLACES)?.fields.orEmpty()
    Text(registryText(namePrompt["title"].stringValue(), languageTag), style = MaterialTheme.typography.titleSmall)
    OutlinedTextField(
        value = name,
        onValueChange = onNameChange,
        label = { Text(registryText(namePrompt["placeholder"].stringValue(), languageTag)) },
        singleLine = true,
        enabled = enabled,
        modifier = Modifier.fillMaxWidth(),
    )
    if (agents.isEmpty()) return
    val newAgentTitle = ((replacesPrompt["options"] as? JsonValue.ArrayValue)?.values?.firstOrNull() as? JsonValue.ObjectValue)
        ?.fields?.get("title").stringValue()
    var expanded by remember { mutableStateOf(false) }
    val selected = agents.firstOrNull { it.id == replaces }?.name ?: registryText(newAgentTitle, languageTag)
    Column {
        Text(registryText(replacesPrompt["title"].stringValue(), languageTag), style = MaterialTheme.typography.titleSmall)
        OutlinedButton(onClick = { expanded = true }, enabled = enabled, modifier = Modifier.fillMaxWidth()) {
            Text(selected)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            DropdownMenuItem(
                text = { Text(registryText(newAgentTitle, languageTag)) },
                onClick = {
                    expanded = false
                    onReplacesChange(null)
                },
            )
            agents.forEach { agent ->
                DropdownMenuItem(
                    text = { Text(agent.name) },
                    onClick = {
                        expanded = false
                        onReplacesChange(agent.id)
                    },
                )
            }
        }
        Text(
            registryText(replacesPrompt["message"].stringValue(), languageTag),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/**
 * The Scan Code button next to a code field. It opens the Google Play services code
 * scanner, which needs no camera permission and ships no model in the app. Hidden on
 * a device without a camera, where the field is the only way. A scan only fills in
 * the code; the confirmation always follows.
 */
@Composable
internal fun ScanCodeButton(languageTag: String, modifier: Modifier = Modifier, onCode: (String) -> Unit) {
    val context = LocalContext.current
    if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)) return
    val prompt = RegistryCatalog.surface(RegistryPromptIds.SCAN_SIGN_IN_CODE)?.fields.orEmpty()
    var problem by remember { mutableStateOf<String?>(null) }
    OutlinedButton(
        onClick = {
            problem = null
            startCodeScan(
                context,
                onCode = { raw ->
                    val scanned = PairCode.fromScan(raw)
                    if (scanned != null) onCode(scanned) else problem = approvalCopy("invalidCode", languageTag)
                },
                onUnavailable = {
                    problem = registryText(
                        RegistryCatalog.surface(RegistryPromptIds.CAMERA_UNAVAILABLE)?.fields?.get("title").stringValue(),
                        languageTag,
                    )
                },
            )
        },
        modifier = modifier,
    ) {
        Text(registryText(prompt["confirmTitle"].stringValue(), languageTag))
    }
    problem?.let {
        Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error, modifier = modifier)
    }
}

private fun startCodeScan(context: Context, onCode: (String) -> Unit, onUnavailable: () -> Unit) {
    val options = GmsBarcodeScannerOptions.Builder()
        .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
        .build()
    GmsBarcodeScanning.getClient(context, options).startScan()
        .addOnSuccessListener { barcode -> barcode.rawValue?.let(onCode) }
        .addOnFailureListener { onUnavailable() }
}

private fun doneText(request: PairingRequest, languageTag: String): String =
    if (request.isConnector) approvalCopy("doneConnector", languageTag) else approvalCopy("doneDevice", languageTag, request.client)

/** The server's refusal in words (same three codes as Apple), else the failure's own message. */
private fun approvalErrorMessage(failure: Exception, languageTag: String): String =
    when ((failure as? AccessHttpException)?.errorCode) {
        "invalid_code" -> approvalCopy("invalidCode", languageTag)
        "code_used" -> approvalCopy("codeUsed", languageTag)
        "too_many_attempts" -> approvalCopy("tooManyAttempts", languageTag)
        else -> failure.message ?: failure.toString()
    }

private fun approvalCopy(id: String, languageTag: String, client: String = ""): String =
    settingsCopy(SIGN_IN_APPROVAL, id, languageTag, "client" to client)

private fun connectorCopy(id: String, languageTag: String): String = settingsCopy(CLAUDE_CONNECTOR, id, languageTag)

private const val SIGN_IN_APPROVAL = "sign_in_approval"
internal const val CLAUDE_CONNECTOR = "claude_connector"
private const val CONNECTOR_URL = "https://api.septena.app/mcp"
private const val MAX_CODE_INPUT = 32
private const val MAX_AGENT_NAME = 40
