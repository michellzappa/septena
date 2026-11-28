package app.septena.android.ui

import android.content.Context
import android.os.Build
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import app.septena.android.AndroidAppGraph
import app.septena.android.sync.SyncState
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.generated.RegistryLinks
import app.septena.core.stringValue
import app.septena.transport.SeptenaSupportClient
import app.septena.transport.SupportDiagnostics
import app.septena.transport.SupportMessage
import app.septena.transport.SupportSendException
import app.septena.ui.ChevronLeftGlyph
import java.text.DateFormat
import java.util.Date
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// Contact Support (ADR 0054, docs/SUPPORT_SPEC.md §4): the same screen, fields, order and words as
// Apple's SupportView. Copy comes from registry surfaces.json `support`.

/** The Settings surface id (`settings.json` `contact_support`). */
internal const val CONTACT_SUPPORT = "contact_support"

/** surfaces.json `support`. */
private val supportSurface: JsonValue.ObjectValue?
    get() = RegistryCatalog.document("surfaces").fields["support"] as? JsonValue.ObjectValue

/** The ids of surfaces.json `support.copy`. */
@Suppress("EnumEntryName")
internal enum class SupportCopy {
    helpHint, helpLink, messageLabel, messagePlaceholder, emailFieldLabel, emailDetail, diagnosticsLabel,
    diagnosticsDetail, send, sending, sent, sendFailed, sendAgain, noMessages, fromYou, fromSeptena,
    emailRequired, tooManyMessages, unreadReply, closeTitle,
}

internal fun supportTitle(languageTag: String): String =
    registryText(supportSurface?.fields?.get("title").stringValue(), languageTag)

internal fun supportCopy(id: SupportCopy, languageTag: String): String {
    val entries = (supportSurface?.fields?.get("copy") as? JsonValue.ArrayValue)?.values.orEmpty()
    val entry = entries.firstOrNull { (it as? JsonValue.ObjectValue)?.fields?.get("id").stringValue() == id.name }
        as? JsonValue.ObjectValue
    return registryText(entry?.fields?.get("label").stringValue(), languageTag)
}

private sealed interface SendState {
    data object Idle : SendState
    data object Sending : SendState
    data object Sent : SendState
    data class Failed(val reason: SupportSendException.Reason) : SendState
}

/** What "Include diagnostics" adds (spec §4). Never task content. */
private fun diagnostics(context: Context, signedIn: Boolean, syncState: SyncState): SupportDiagnostics {
    val info = runCatching { context.packageManager.getPackageInfo(context.packageName, 0) }.getOrNull()
    return SupportDiagnostics(
        platform = "android",
        osVersion = Build.VERSION.RELEASE,
        deviceModel = Build.MODEL,
        appVersion = info?.versionName,
        build = info?.longVersionCode,
        signedIn = signedIn,
        lastSyncAt = (syncState as? SyncState.Synced)?.at?.toString(),
        lastSyncError = (syncState as? SyncState.Failed)?.message,
    )
}

/** Settings ▸ About ▸ Contact Support: the row, with a dot while a reply is unread. */
@Composable
internal fun ContactSupportRow(label: String?, env: SettingsSurfaceEnv, languageTag: String) {
    val title = label ?: return
    var open by rememberSaveable { mutableStateOf(false) }
    var unread by remember { mutableStateOf(0) }
    LaunchedEffect(open) {
        if (!open) {
            unread = runCatching {
                withContext(Dispatchers.IO) { env.graph.support.conversation(env.graph.supportKeys.key()).unread }
            }.getOrDefault(unread)
        }
    }
    val dotLabel = supportCopy(SupportCopy.unreadReply, languageTag)
    ListItem(
        headlineContent = { Text(title, color = MaterialTheme.colorScheme.primary) },
        trailingContent = if (unread > 0) {
            {
                Box(
                    Modifier
                        .size(8.dp)
                        .background(MaterialTheme.colorScheme.primary, CircleShape)
                        .semantics { contentDescription = dotLabel },
                )
            }
        } else {
            null
        },
        modifier = Modifier.fillMaxWidth().clickable { open = true },
    )
    if (open) {
        Dialog(
            onDismissRequest = { open = false },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            ContactSupportScreen(env.graph, env.signedIn, env.syncState, languageTag, onClose = { open = false })
        }
    }
}

/** The Contact Support form. [initialText] starts the message, as the beta's "Send a note" does. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ContactSupportScreen(
    graph: AndroidAppGraph,
    signedIn: Boolean,
    syncState: SyncState,
    languageTag: String,
    onClose: () -> Unit,
    initialText: String = "",
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var messages by remember { mutableStateOf<List<SupportMessage>>(emptyList()) }
    var text by rememberSaveable { mutableStateOf(initialText) }
    var email by rememberSaveable { mutableStateOf("") }
    var includeDiagnostics by rememberSaveable { mutableStateOf(false) }
    var sendState by remember { mutableStateOf<SendState>(SendState.Idle) }
    val needsEmail = !signedIn
    fun copy(id: SupportCopy) = supportCopy(id, languageTag)

    LaunchedEffect(Unit) {
        runCatching {
            withContext(Dispatchers.IO) {
                val key = graph.supportKeys.key()
                val conversation = graph.support.conversation(key)
                messages = conversation.messages
                if (conversation.unread > 0) graph.support.markRead(key)
            }
        }
    }

    val canSend = sendState != SendState.Sending && text.isNotBlank() && (!needsEmail || email.isNotBlank())

    fun send() {
        if (!canSend) return
        sendState = SendState.Sending
        scope.launch {
            val outcome = runCatching {
                withContext(Dispatchers.IO) {
                    graph.support.send(
                        messageId = UUID.randomUUID().toString().lowercase(),
                        text = text.trim().take(SeptenaSupportClient.MESSAGE_MAX_CHARS),
                        email = if (needsEmail) email.trim() else null,
                        diagnostics = if (includeDiagnostics) diagnostics(context, signedIn, syncState) else null,
                        supportKey = graph.supportKeys.key(),
                    )
                }
            }
            outcome.onSuccess { stored ->
                if (messages.none { it.id == stored.id }) messages = messages + stored
                text = ""
                sendState = SendState.Sent
            }.onFailure { error ->
                sendState = SendState.Failed((error as? SupportSendException)?.reason ?: SupportSendException.Reason.FAILED)
            }
        }
    }

    Scaffold(
        modifier = Modifier.fillMaxSize(),
        topBar = {
            TopAppBar(
                title = { Text(supportTitle(languageTag)) },
                navigationIcon = {
                    IconButton(
                        onClick = onClose,
                        modifier = Modifier.semantics { contentDescription = copy(SupportCopy.closeTitle) },
                    ) {
                        ChevronLeftGlyph(tint = MaterialTheme.colorScheme.onSurface)
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(padding)
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (messages.isEmpty()) {
                Text(copy(SupportCopy.noMessages), color = MaterialTheme.colorScheme.onSurfaceVariant)
            } else {
                messages.forEach { message -> SupportMessageRow(message, languageTag) }
            }
            HorizontalDivider()

            ListItem(
                headlineContent = { Text(copy(SupportCopy.helpLink), color = MaterialTheme.colorScheme.primary) },
                supportingContent = { Text(copy(SupportCopy.helpHint)) },
                trailingContent = { Text("↗", color = MaterialTheme.colorScheme.onSurfaceVariant) },
                modifier = Modifier.fillMaxWidth().clickable { openUrl(context, RegistryLinks.HELP) },
            )

            OutlinedTextField(
                value = text,
                onValueChange = {
                    text = it.take(SeptenaSupportClient.MESSAGE_MAX_CHARS)
                    if (sendState != SendState.Sending) sendState = SendState.Idle
                },
                label = { Text(copy(SupportCopy.messageLabel)) },
                placeholder = { Text(copy(SupportCopy.messagePlaceholder)) },
                minLines = 4,
                maxLines = 12,
                modifier = Modifier.fillMaxWidth(),
            )
            if (needsEmail) {
                OutlinedTextField(
                    value = email,
                    onValueChange = { email = it },
                    label = { Text(copy(SupportCopy.emailFieldLabel)) },
                    supportingText = { Text(copy(SupportCopy.emailDetail)) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            ListItem(
                headlineContent = { Text(copy(SupportCopy.diagnosticsLabel)) },
                supportingContent = { Text(copy(SupportCopy.diagnosticsDetail)) },
                trailingContent = { Switch(checked = includeDiagnostics, onCheckedChange = { includeDiagnostics = it }) },
                modifier = Modifier.fillMaxWidth().clickable { includeDiagnostics = !includeDiagnostics },
            )

            Button(onClick = ::send, enabled = canSend, modifier = Modifier.fillMaxWidth()) {
                if (sendState == SendState.Sending) {
                    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(8.dp))
                    Text(copy(SupportCopy.sending))
                } else {
                    Text(copy(SupportCopy.send))
                }
            }

            when (val state = sendState) {
                SendState.Sent -> Text(copy(SupportCopy.sent), color = MaterialTheme.colorScheme.onSurfaceVariant)
                is SendState.Failed -> Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    val reason = when (state.reason) {
                        SupportSendException.Reason.EMAIL_REQUIRED -> copy(SupportCopy.emailRequired)
                        SupportSendException.Reason.RATE_LIMITED -> copy(SupportCopy.tooManyMessages)
                        SupportSendException.Reason.FAILED -> copy(SupportCopy.sendFailed)
                    }
                    Text(reason, color = MaterialTheme.colorScheme.error)
                    TextButton(onClick = ::send, enabled = canSend) { Text(copy(SupportCopy.sendAgain)) }
                }
                SendState.Idle, SendState.Sending -> Unit
            }
        }
    }
}

@Composable
private fun SupportMessageRow(message: SupportMessage, languageTag: String) {
    val who = if (message.isReply) {
        val septena = supportCopy(SupportCopy.fromSeptena, languageTag)
        message.authorName?.let { "$septena · $it" } ?: septena
    } else {
        supportCopy(SupportCopy.fromYou, languageTag)
    }
    val time = remember(message.createdAtMs) {
        DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(message.createdAtMs))
    }
    Column(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                who,
                style = MaterialTheme.typography.labelMedium,
                color = if (message.isReply) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.weight(1f),
            )
            Text(time, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Text(message.text)
    }
}
