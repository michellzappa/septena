package app.septena.android.ui

import android.content.Context
import android.content.Intent
import android.text.format.DateUtils
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.septena.android.AndroidAppGraph
import app.septena.core.JsonValue
import app.septena.core.ProjectShare
import app.septena.core.RegistryCatalog
import app.septena.core.ShareMember
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.generated.RegistrySettingKeys
import app.septena.core.stringValue
import app.septena.transport.AccessHttpException
import app.septena.transport.SeptenaShareClient
import app.septena.transport.ShareInvite
import app.septena.transport.SharePreview
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// Shared projects (docs/PROJECT_SHARING_SPEC.md §8). All copy comes from surfaces.json `sharing`.

private val sharing: JsonValue.ObjectValue?
    get() = RegistryCatalog.document("surfaces").fields["sharing"] as? JsonValue.ObjectValue

private fun sharingTitle(languageTag: String): String =
    registryText(sharing?.fields?.get("title").stringValue(), languageTag)

/** The ids of surfaces.json `sharing.copy`: an entry's name is its id, except `name`, which every enum owns. */
@Suppress("EnumEntryName")
internal enum class SharingCopy(private val key: String? = null) {
    intro,
    memberName("name"),
    start,
    members,
    owner,
    you,
    invite,
    inviteNote,
    invites,
    expires,
    revoke,
    remove,
    stop,
    stopDetail,
    leave,
    leaveDetail,
    joinTitle,
    joinLink,
    joinDetail,
    sharedBy,
    join,
    invalid,
    full,
    signInFirst,
    failed,
    nobody,
    ;

    val id: String get() = key ?: name
}

/** One line of surfaces.json `sharing.copy`, localized. */
internal fun sharingCopy(id: SharingCopy, languageTag: String): String {
    val entries = (sharing?.fields?.get("copy") as? JsonValue.ArrayValue)?.values.orEmpty()
    val entry = entries.firstOrNull { (it as? JsonValue.ObjectValue)?.fields?.get("id").stringValue() == id.id }
        as? JsonValue.ObjectValue
    return registryText(entry?.fields?.get("label").stringValue(), languageTag)
}

/** What to tell the user about a failed sharing call. A plan limit shows its upsell (registry/plans.json). */
private fun sharingError(failure: Throwable, languageTag: String): String {
    val http = failure as? AccessHttpException
    return when {
        http?.statusCode == 402 -> upsellText("share_create", languageTag) ?: sharingCopy(SharingCopy.failed, languageTag)
        http?.errorCode == "share_full" -> sharingCopy(SharingCopy.full, languageTag)
        http?.statusCode == 404 -> sharingCopy(SharingCopy.invalid, languageTag)
        else -> sharingCopy(SharingCopy.failed, languageTag)
    }
}

private fun upsellText(id: String, languageTag: String): String? {
    val upsells = (RegistryCatalog.document("plans").fields["upsells"] as? JsonValue.ArrayValue)?.values.orEmpty()
    val upsell = upsells.firstOrNull { (it as? JsonValue.ObjectValue)?.fields?.get("id").stringValue() == id }
        as? JsonValue.ObjectValue ?: return null
    return listOf("title", "detail")
        .map { registryText(upsell.fields[it].stringValue(), languageTag) }
        .filter(String::isNotBlank)
        .joinToString("\n")
}

private fun shareLink(context: Context, url: String, title: String) {
    val intent = Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_TEXT, url)
    }
    context.startActivity(Intent.createChooser(intent, title))
}

/** The synced profile name, to fill the name field with. */
private suspend fun profileName(graph: AndroidAppGraph): String = withContext(Dispatchers.IO) {
    runCatching { graph.syncedSettings.value(RegistrySettingKeys.WELCOME_NAME).stringValue() }.getOrNull().orEmpty()
}

private enum class ShareConfirm { Stop, Leave }

/**
 * Share Project: starts sharing a private project, or shows who is in a shared one. The owner invites, removes
 * and stops sharing; a member can leave. Same sheet as iPhone and Mac. [onEnded] runs after the project left
 * this account.
 */
@Composable
internal fun ShareProjectDialog(
    graph: AndroidAppGraph,
    projectId: String,
    languageTag: String,
    onDismiss: () -> Unit,
    onEnded: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val signedIn by graph.credentials.signedIn.collectAsStateWithLifecycle()
    val dataVersion by graph.sync.dataVersion.collectAsStateWithLifecycle()
    var loaded by remember { mutableStateOf(false) }
    var share by remember { mutableStateOf<ProjectShare?>(null) }
    var invites by remember { mutableStateOf<List<ShareInvite>>(emptyList()) }
    var name by remember { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var confirm by remember { mutableStateOf<ShareConfirm?>(null) }
    fun copy(id: SharingCopy) = sharingCopy(id, languageTag)

    LaunchedEffect(Unit) { name = profileName(graph) }
    // The row is the first answer, offline too. A row that says "private" does not undo a share just made.
    LaunchedEffect(dataVersion) {
        val stored = withContext(Dispatchers.IO) {
            ProjectShare.of(graph.taskStore.record(RegistryEntityNames.PROJECT, projectId))
        }
        if (stored != null) share = stored
        loaded = true
    }

    suspend fun refresh(shareId: String) {
        val details = graph.shares.details(shareId)
        share = details.share
        invites = details.invites
    }

    fun run(block: suspend () -> Unit) {
        if (working) return
        working = true
        error = null
        scope.launch {
            try {
                block()
            } catch (failure: Exception) {
                if (failure is CancellationException) throw failure
                error = sharingError(failure, languageTag)
            } finally {
                working = false
            }
        }
    }

    val shareId = share?.id
    LaunchedEffect(shareId, signedIn) {
        if (shareId == null || !signedIn) return@LaunchedEffect
        try {
            refresh(shareId)
        } catch (failure: Exception) {
            if (failure is CancellationException) throw failure
            error = sharingError(failure, languageTag)
        }
    }

    val current = share
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(sharingTitle(languageTag)) },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                when {
                    !signedIn -> Text(copy(SharingCopy.signInFirst))
                    !loaded -> CircularProgressIndicator()
                    current == null -> {
                        Text(copy(SharingCopy.intro))
                        NameField(name, copy(SharingCopy.memberName), enabled = !working) { name = it }
                        TextButton(
                            enabled = !working && name.isNotBlank(),
                            onClick = {
                                run {
                                    // What was typed offline goes up before the project is copied.
                                    graph.sync.syncAndWait()
                                    share = graph.shares.create(projectId, name.trim())
                                    graph.sync.requestSync()
                                }
                            },
                        ) { Text(copy(SharingCopy.start)) }
                    }
                    else -> {
                        SharingHeading(copy(SharingCopy.members))
                        current.members.forEach { member ->
                            val notes = listOfNotNull(
                                copy(SharingCopy.you).takeIf { member.id == current.me },
                                copy(SharingCopy.owner).takeIf { member.isOwner },
                            )
                            SharingRow(
                                text = memberLabel(member, notes),
                                action = copy(SharingCopy.remove).takeIf { current.isOwner && !member.isOwner },
                                enabled = !working,
                                onAction = {
                                    run {
                                        graph.shares.endMembership(current.id, member.id)
                                        refresh(current.id)
                                        graph.sync.requestSync()
                                    }
                                },
                            )
                        }
                        if (current.isOwner) {
                            TextButton(
                                enabled = !working,
                                onClick = {
                                    run {
                                        val made = graph.shares.invite(current.id)
                                        invites = invites + made.invite
                                        shareLink(context, made.url, copy(SharingCopy.invite))
                                    }
                                },
                            ) { Text(copy(SharingCopy.invite)) }
                            Text(
                                copy(SharingCopy.inviteNote),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            if (invites.isNotEmpty()) {
                                SharingHeading(copy(SharingCopy.invites))
                                invites.forEach { invite ->
                                    val day = DateUtils.formatDateTime(context, invite.expiresAtMs, DateUtils.FORMAT_SHOW_DATE)
                                    SharingRow(
                                        text = "${copy(SharingCopy.expires)} $day",
                                        action = copy(SharingCopy.revoke),
                                        enabled = !working,
                                        onAction = {
                                            run {
                                                graph.shares.revokeInvite(current.id, invite.id)
                                                invites = invites - invite
                                            }
                                        },
                                    )
                                }
                            }
                        }
                        val ending = if (current.isOwner) ShareConfirm.Stop else ShareConfirm.Leave
                        TextButton(enabled = !working, onClick = { confirm = ending }) {
                            Text(
                                copy(if (current.isOwner) SharingCopy.stop else SharingCopy.leave),
                                color = MaterialTheme.colorScheme.error,
                            )
                        }
                    }
                }
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text(promptConfirmTitle(languageTag)) } },
    )

    confirm?.let { ending ->
        val shared = share ?: return@let
        AlertDialog(
            onDismissRequest = { confirm = null },
            title = { Text(copy(if (ending == ShareConfirm.Stop) SharingCopy.stop else SharingCopy.leave)) },
            text = { Text(copy(if (ending == ShareConfirm.Stop) SharingCopy.stopDetail else SharingCopy.leaveDetail)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirm = null
                        run {
                            when (ending) {
                                ShareConfirm.Stop -> graph.shares.stop(shared.id)
                                ShareConfirm.Leave -> graph.shares.endMembership(shared.id, shared.me)
                            }
                            graph.sync.requestSync()
                            onDismiss()
                            if (ending == ShareConfirm.Leave) onEnded()
                        }
                    },
                ) {
                    Text(
                        copy(if (ending == ShareConfirm.Stop) SharingCopy.stop else SharingCopy.leave),
                        color = MaterialTheme.colorScheme.error,
                    )
                }
            },
            dismissButton = { TextButton(onClick = { confirm = null }) { Text(promptCancelTitle(languageTag)) } },
        )
    }
}

/**
 * Join a Shared Project: paste the invite link (or arrive with its [initialToken]), see the project and who
 * shares it, then join. A link alone never joins anything.
 */
@Composable
internal fun JoinSharedProjectDialog(
    graph: AndroidAppGraph,
    languageTag: String,
    initialToken: String? = null,
    onDismiss: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val signedIn by graph.credentials.signedIn.collectAsStateWithLifecycle()
    var link by remember { mutableStateOf("") }
    var name by remember { mutableStateOf("") }
    var preview by remember { mutableStateOf<SharePreview?>(null) }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val token = initialToken ?: SeptenaShareClient.inviteToken(link)
    fun copy(id: SharingCopy) = sharingCopy(id, languageTag)

    LaunchedEffect(Unit) { name = profileName(graph) }
    LaunchedEffect(token, signedIn) {
        preview = null
        error = null
        if (token == null || !signedIn) return@LaunchedEffect
        try {
            preview = graph.shares.preview(token)
        } catch (failure: Exception) {
            if (failure is CancellationException) throw failure
            error = sharingError(failure, languageTag)
        }
    }

    val found = preview
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(copy(SharingCopy.joinTitle)) },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (!signedIn) {
                    Text(copy(SharingCopy.signInFirst))
                } else {
                    if (initialToken == null) {
                        OutlinedTextField(
                            value = link,
                            onValueChange = { link = it },
                            label = { Text(copy(SharingCopy.joinLink)) },
                            singleLine = true,
                            enabled = !working,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                    if (found != null) {
                        Text(found.title, style = MaterialTheme.typography.titleMedium)
                        if (found.from.isNotBlank()) Text("${copy(SharingCopy.sharedBy)} ${found.from}")
                        NameField(name, copy(SharingCopy.memberName), enabled = !working) { name = it }
                        Text(
                            copy(SharingCopy.joinDetail),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    } else if (token != null && error == null) {
                        CircularProgressIndicator()
                    } else if (token == null && link.isNotBlank()) {
                        Text(copy(SharingCopy.invalid), color = MaterialTheme.colorScheme.error)
                    }
                }
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            TextButton(
                enabled = signedIn && found != null && token != null && name.isNotBlank() && !working,
                onClick = {
                    val accepted = token ?: return@TextButton
                    working = true
                    error = null
                    scope.launch {
                        try {
                            graph.shares.join(accepted, name.trim())
                            graph.sync.requestSync()
                            onDismiss()
                        } catch (failure: Exception) {
                            if (failure is CancellationException) throw failure
                            error = sharingError(failure, languageTag)
                        } finally {
                            working = false
                        }
                    }
                },
            ) { Text(copy(SharingCopy.join)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(promptCancelTitle(languageTag)) } },
    )
}

/** Assign To: nobody or one member of the task's shared project. */
@Composable
internal fun AssignTaskDialog(
    graph: AndroidAppGraph,
    taskId: String,
    title: String,
    languageTag: String,
    onDismiss: () -> Unit,
    onPick: (String?) -> Unit,
) {
    var share by remember { mutableStateOf<ProjectShare?>(null) }
    var assigned by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(taskId) {
        withContext(Dispatchers.IO) {
            val task = graph.taskStore.record(RegistryEntityNames.TASK, taskId) ?: return@withContext
            assigned = task.fields[RegistryEntityFields.Task.ASSIGNED_TO].stringValue()
            share = task.fields[RegistryEntityFields.Task.PROJECT].stringValue()
                ?.let { ProjectShare.of(graph.taskStore.record(RegistryEntityNames.PROJECT, it)) }
        }
    }
    val shared = share ?: return
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(modifier = Modifier.verticalScroll(rememberScrollState())) {
                AssigneeRow(sharingCopy(SharingCopy.nobody, languageTag), selected = shared.member(assigned.orEmpty()) == null) {
                    onPick(null)
                }
                shared.members.forEach { member ->
                    val notes = listOfNotNull(sharingCopy(SharingCopy.you, languageTag).takeIf { member.id == shared.me })
                    AssigneeRow(memberLabel(member, notes), selected = member.id == assigned) { onPick(member.id) }
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text(promptCancelTitle(languageTag)) } },
    )
}

@Composable
private fun AssigneeRow(text: String, selected: Boolean, onClick: () -> Unit) {
    Text(
        text = text,
        fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
        color = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 12.dp),
    )
}

@Composable
private fun SharingHeading(text: String) {
    Text(text, style = MaterialTheme.typography.titleSmall)
}

@Composable
private fun SharingRow(text: String, action: String?, enabled: Boolean, onAction: () -> Unit) {
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(text, modifier = Modifier.weight(1f))
        if (action != null) TextButton(enabled = enabled, onClick = onAction) { Text(action) }
    }
}

@Composable
private fun NameField(value: String, label: String, enabled: Boolean, onChange: (String) -> Unit) {
    OutlinedTextField(
        value = value,
        onValueChange = { onChange(it.take(MAX_MEMBER_NAME)) },
        label = { Text(label) },
        singleLine = true,
        enabled = enabled,
        modifier = Modifier.fillMaxWidth(),
    )
}

private fun memberLabel(member: ShareMember, notes: List<String>): String =
    if (notes.isEmpty()) member.name else "${member.name} (${notes.joinToString(", ")})"

/** The server's limit on a member's name. */
private const val MAX_MEMBER_NAME = 80
