package app.septena.android.ui

import android.text.format.DateUtils
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.septena.android.AndroidAppGraph
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.generated.RegistryActionIds
import app.septena.core.generated.RegistryPromptIds
import app.septena.core.stringValue
import app.septena.transport.AccessDevice
import app.septena.transport.AccountAccess
import app.septena.transport.AgentConnection
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/**
 * The account's devices and agents, as the server reports them (`GET /v1/access`).
 * Settings ▸ Account ▸ Devices reads `devices`; Settings ▸ AI & Agents ▸ Agents reads
 * `connections` and `agents.count`. Same model as iOS `AgentRoster` and
 * `SeptaskDevicesAccessPane`.
 */
internal class AccessSettingsModel(
    private val graph: AndroidAppGraph,
    private val scope: CoroutineScope,
) {
    /** Null until the first answer from the server, and while signed out. */
    var access by mutableStateOf<AccountAccess?>(null)
        private set
    var loading by mutableStateOf(false)
        private set
    var error by mutableStateOf<String?>(null)
        private set

    suspend fun refresh(signedIn: Boolean) {
        if (!signedIn) {
            access = null
            error = null
            return
        }
        loading = true
        try {
            access = graph.access.access()
            error = null
        } catch (failure: Exception) {
            if (failure is kotlinx.coroutines.CancellationException) throw failure
            error = failure.message ?: failure.toString()
        } finally {
            loading = false
        }
    }

    fun signOut(device: AccessDevice) = perform { graph.access.signOutDevice(device.sid) }

    fun disconnect(agent: AgentConnection) = perform { graph.access.disconnect(agent.id) }

    /** An empty name gives the agent its client's name back. */
    fun rename(agent: AgentConnection, name: String) = perform {
        graph.access.renameAgent(agent.id, name.trim().ifEmpty { null })
    }

    private fun perform(action: suspend () -> Unit) {
        scope.launch {
            var failed: String? = null
            try {
                action()
            } catch (failure: Exception) {
                if (failure is kotlinx.coroutines.CancellationException) throw failure
                failed = failure.message ?: failure.toString()
            }
            refresh(signedIn = true)
            if (failed != null) error = failed
        }
    }

    /** The AI & Agents row status (`statusKey: agentsStatus`): "3 agents", or null until loaded. */
    fun agentsStatus(languageTag: String): String? =
        access?.let { countPhrase(AGENTS_PHRASE, it.agentCount, languageTag) }

    companion object {
        const val AGENTS_STATUS_KEY = "agentsStatus"
        const val AGENTS_PAGE = "agents"
        const val DEVICES_PAGE = "devices_access"
        private const val AGENTS_PHRASE = "agents"
    }
}

/** Surface `access_devices`: every app install signed in to the account. */
@Composable
internal fun AccessDevicesList(model: AccessSettingsModel, signedIn: Boolean, languageTag: String) {
    if (!signedIn) return
    var pending by remember { mutableStateOf<AccessDevice?>(null) }
    val signOutTitle = RegistryCatalog.actionTitle(RegistryActionIds.ACCOUNT_SIGN_OUT, languageTag = languageTag).orEmpty()
    val devices = model.access?.devices
    if (devices == null) {
        if (model.loading) CircularProgressIndicator(modifier = Modifier.padding(16.dp))
    } else {
        devices.forEach { device ->
            ListItem(
                headlineContent = { Text(AccessCopyPending.deviceName(device.client)) },
                supportingContent = { Text(AccessCopyPending.activeLine(device)) },
                trailingContent = {
                    if (device.current) {
                        Text(AccessCopyPending.CURRENT_DEVICE, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    } else {
                        TextButton(onClick = { pending = device }) {
                            Text(signOutTitle, color = MaterialTheme.colorScheme.error)
                        }
                    }
                },
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
    AccessError(model)
    pending?.let { device ->
        AlertDialog(
            onDismissRequest = { pending = null },
            title = { Text(AccessCopyPending.signOutDeviceTitle(AccessCopyPending.deviceName(device.client))) },
            text = { Text(AccessCopyPending.SIGN_OUT_DEVICE_MESSAGE) },
            confirmButton = {
                TextButton(onClick = {
                    pending = null
                    model.signOut(device)
                }) { Text(signOutTitle, color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { pending = null }) { Text(promptChrome("cancelTitle", languageTag)) }
            },
        )
    }
}

/** Surface `access_agents`: the count row, then every connected agent with rename and disconnect. */
@Composable
internal fun AccessAgentsList(model: AccessSettingsModel, signedIn: Boolean, languageTag: String) {
    if (!signedIn) return
    var renaming by remember { mutableStateOf<AgentConnection?>(null) }
    var draftName by remember { mutableStateOf("") }
    var pendingDisconnect by remember { mutableStateOf<AgentConnection?>(null) }
    val renamePrompt = remember(languageTag) { registryPrompt(RegistryPromptIds.RENAME_AGENT, languageTag) }
    val disconnectTitle = registryPrompt(RegistryPromptIds.DISCONNECT_AGENT, languageTag).confirmTitle
    val access = model.access

    ListItem(
        headlineContent = { Text(settingsSectionHeader(AccessSettingsModel.AGENTS_PAGE, AGENTS_SECTION, languageTag)) },
        trailingContent = {
            when {
                access != null -> Text(
                    model.agentsStatus(languageTag).orEmpty(),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                model.loading -> CircularProgressIndicator()
            }
        },
        modifier = Modifier.fillMaxWidth(),
    )
    access?.connections.orEmpty().forEach { agent ->
        ListItem(
            headlineContent = { Text(agent.name) },
            supportingContent = { Text(AccessCopyPending.agentDetailLine(agent)) },
            trailingContent = {
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    TextButton(onClick = {
                        draftName = agent.name
                        renaming = agent
                    }) { Text(renamePrompt.confirmTitle) }
                    TextButton(onClick = { pendingDisconnect = agent }) {
                        Text(disconnectTitle, color = MaterialTheme.colorScheme.error)
                    }
                }
            },
            modifier = Modifier.fillMaxWidth(),
        )
    }
    AccessError(model)

    renaming?.let { agent ->
        AlertDialog(
            onDismissRequest = { renaming = null },
            title = { Text(renamePrompt.title) },
            text = {
                OutlinedTextField(
                    value = draftName,
                    onValueChange = { draftName = it.take(MAX_AGENT_NAME) },
                    label = { Text(renamePrompt.placeholder) },
                    singleLine = true,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    renaming = null
                    model.rename(agent, draftName)
                }) { Text(renamePrompt.confirmTitle) }
            },
            dismissButton = {
                TextButton(onClick = { renaming = null }) { Text(promptChrome("cancelTitle", languageTag)) }
            },
        )
    }
    pendingDisconnect?.let { agent ->
        val copy = registryPrompt(RegistryPromptIds.DISCONNECT_AGENT, languageTag, name = agent.name)
        AlertDialog(
            onDismissRequest = { pendingDisconnect = null },
            title = { Text(copy.title) },
            text = { Text(copy.message) },
            confirmButton = {
                TextButton(onClick = {
                    pendingDisconnect = null
                    model.disconnect(agent)
                }) { Text(copy.confirmTitle, color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = {
                TextButton(onClick = { pendingDisconnect = null }) { Text(promptChrome("cancelTitle", languageTag)) }
            },
        )
    }
}

@Composable
private fun AccessError(model: AccessSettingsModel) {
    model.error?.let { message ->
        Text(
            message,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.error,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
        )
    }
}

/**
 * Copy that has no registry entry yet (issue #260): the device list and the agent
 * detail line. iOS spells the same words inline in `SeptaskDevicesAccessPane` and
 * `SeptaskAgentsPane`. Move each into `registry/` when #260 lands.
 */
private object AccessCopyPending {
    const val CURRENT_DEVICE = "Current device"
    const val SIGN_OUT_DEVICE_MESSAGE =
        "That device stops syncing within the hour. Its tasks stay on it until you sign in there again."

    fun signOutDeviceTitle(name: String) = "Sign out $name?"

    /** A device's `X-Septena-Client` name, in words (same mapping as iOS `deviceName`). */
    fun deviceName(client: String?): String = when {
        client == "septask-ios" -> "iPhone or iPad"
        client == "septask-mac" -> "Mac"
        client == "septask-watch" -> "Apple Watch"
        client != null && client.contains("android") -> "Android"
        client != null && client.contains("web") -> "Browser"
        !client.isNullOrEmpty() -> client
        else -> "Unknown device"
    }

    fun activeLine(device: AccessDevice): String {
        val seen = relativeTime(device.lastSeenMs)
        return if (device.syncing) "Active $seen" else "Active $seen · not syncing"
    }

    /** "Claude Code · Last used 2 hours ago"; only "Last used …" when the agent keeps its client's name. */
    fun agentDetailLine(agent: AgentConnection): String {
        val used = "Last used ${relativeTime(agent.lastUsedMs)}"
        return if (agent.name == agent.clientName) used else "${agent.clientName} · $used"
    }
}

private fun relativeTime(ms: Long): String =
    DateUtils.getRelativeTimeSpanString(ms, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS).toString()

private data class AccessPrompt(val title: String, val message: String, val placeholder: String, val confirmTitle: String)

/** A prompt from surfaces.json `prompts` by ID, with `{name}` filled in. */
private fun registryPrompt(id: String, languageTag: String, name: String = ""): AccessPrompt {
    val fields = RegistryCatalog.surface(id)?.fields.orEmpty()
    fun text(key: String) = fields[key].stringValue().accessLocalized(languageTag).replace("{name}", name)
    return AccessPrompt(text("title"), text("message"), text("placeholder"), text("confirmTitle"))
}

/** Shared prompt chrome (surfaces.json `prompts.cancelTitle`). */
private fun promptChrome(field: String, languageTag: String): String {
    val prompts = RegistryCatalog.document("surfaces").fields["prompts"] as? JsonValue.ObjectValue
    return prompts?.fields?.get(field).stringValue().accessLocalized(languageTag)
}

private fun settingsSectionHeader(pageId: String, sectionId: String, languageTag: String): String {
    val pages = (RegistryCatalog.document("settings").fields["pages"] as? JsonValue.ArrayValue)?.values.orEmpty()
    val page = pages.firstOrNull { (it as? JsonValue.ObjectValue)?.fields?.get("id").stringValue() == pageId }
        as? JsonValue.ObjectValue
    val sections = (page?.fields?.get("sections") as? JsonValue.ArrayValue)?.values.orEmpty()
    val section = sections.firstOrNull { (it as? JsonValue.ObjectValue)?.fields?.get("id").stringValue() == sectionId }
        as? JsonValue.ObjectValue
    return section?.fields?.get("header").stringValue().accessLocalized(languageTag)
}

/**
 * A count phrase from surfaces.json `prompts.countPhrases` ("3 agents"). The
 * localization entry for the `other` form holds the plural forms per language.
 */
internal fun countPhrase(id: String, count: Int, languageTag: String): String {
    val prompts = RegistryCatalog.document("surfaces").fields["prompts"] as? JsonValue.ObjectValue
    val phrases = (prompts?.fields?.get("countPhrases") as? JsonValue.ArrayValue)?.values.orEmpty()
    val phrase = phrases.firstOrNull { (it as? JsonValue.ObjectValue)?.fields?.get("id").stringValue() == id }
        as? JsonValue.ObjectValue
    val label = phrase?.fields?.get("label") as? JsonValue.ObjectValue ?: return count.toString()
    val other = label.fields["other"].stringValue().orEmpty()
    val forms = localizedPluralForms(other, languageTag) ?: label
    val form = (if (count == 1) forms.fields["one"].stringValue() else null)
        ?: forms.fields["other"].stringValue()
        ?: other
    return form.replace("{count}", count.toString())
}

private fun localizedPluralForms(key: String, languageTag: String): JsonValue.ObjectValue? {
    val translations = RegistryCatalog.document("localizations")
    val locale = translations.fields.keys.firstOrNull { it.equals(languageTag, ignoreCase = true) }
        ?: translations.fields.keys.firstOrNull {
            it.substringBefore('-').equals(languageTag.substringBefore('-'), ignoreCase = true)
        }
    fun forms(tag: String?): JsonValue.ObjectValue? {
        val table = tag?.let { translations.fields[it] } as? JsonValue.ObjectValue ?: return null
        val entry = table.fields[key] as? JsonValue.ObjectValue ?: return null
        return entry.fields["forms"] as? JsonValue.ObjectValue
    }
    return forms(locale) ?: forms("en")
}

private fun String?.accessLocalized(languageTag: String): String =
    this?.let { RegistryCatalog.localizedString(it, languageTag) ?: it }.orEmpty()

private const val AGENTS_SECTION = "agents"
private const val MAX_AGENT_NAME = 40
