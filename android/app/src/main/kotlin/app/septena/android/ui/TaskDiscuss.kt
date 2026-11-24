package app.septena.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.septena.android.AndroidAppGraph
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.SyncRecord
import app.septena.core.TaskConversation
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryTaskAttributeIds
import app.septena.core.generated.RegistryTaskDetail
import app.septena.core.stringValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// The parts of the task conversation that Apple `ConversationCard` and the Discuss
// pill draw around the transcript. TaskConversationSection.kt owns the transcript.

/** The user's Claude has the task, with or without a turn yet. */
internal val TaskConversation.isHandedToClaude: Boolean
    get() = assignee == RegistryEntityEnums.ConvoAssignee.CLAUDE

/**
 * Discuss, before a conversation exists. Apple answers with the on-device model and
 * only parks a task for Claude when Where AI runs admits it and Claude is connected.
 * Android has no on-device model, so Claude is the only provider: Discuss hands the
 * task to it, under the same two conditions. An unknown connection hands over nothing.
 */
@Composable
internal fun DiscussStart(
    graph: AndroidAppGraph,
    taskId: String,
    isTaskOpen: Boolean,
    canWrite: Boolean,
    languageTag: String,
) {
    val signedIn by graph.credentials.signedIn.collectAsStateWithLifecycle()
    if (!isTaskOpen || !signedIn || !aiModeAdmitsClaude(currentAiMode(graph))) return
    val attribute = remember(languageTag) { RegistryCatalog.surface(RegistryTaskAttributeIds.DISCUSS)?.fields.orEmpty() }
    val scope = rememberCoroutineScope()
    var working by remember(taskId) { mutableStateOf(false) }
    var problem by remember(taskId) { mutableStateOf<String?>(null) }

    fun start() {
        if (working || !canWrite) return
        working = true
        problem = null
        scope.launch {
            try {
                if (graph.access.access().connections.isEmpty()) {
                    problem = detailControl(RegistryTaskDetail.Controls.CONVERSATION_CONNECT_FIRST, languageTag)
                } else {
                    withContext(Dispatchers.IO) {
                        graph.conversationMutator.update(
                            taskId,
                            mapOf(
                                RegistryEntityFields.Convo.ASSIGNEE to
                                    JsonValue.StringValue(RegistryEntityEnums.ConvoAssignee.CLAUDE),
                            ),
                        )
                        graph.taskMutator.touch(taskId)
                    }
                    graph.sync.noteLocalChange()
                    graph.sync.requestSync()
                }
            } catch (failure: CancellationException) {
                throw failure
            } catch (_: Exception) {
                problem = detailControl(RegistryTaskDetail.Controls.CONVERSATION_CHECK_FAILED, languageTag)
            } finally {
                working = false
            }
        }
    }

    Column(modifier = Modifier.padding(top = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        OutlinedButton(onClick = ::start, enabled = canWrite && !working) {
            Text(registryText(attribute[if (working) "workingLabel" else "label"].stringValue(), languageTag))
        }
        problem?.let {
            Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
        }
    }
}

/**
 * The user's turn: appended, then what Apple `appendConvoTurn` and `touch` also write.
 * A chosen answer to a confirm step becomes the confirmed intent, and answering stamps
 * the fade clock (docs/TASK_FADE_SPEC.md §3).
 */
internal suspend fun appendUserTurn(graph: AndroidAppGraph, taskId: String, fields: Map<String, JsonValue>) {
    graph.conversationMutator.appendTurn(taskId, fields)
    val chosen = fields["chosen"].stringValue()
    if (chosen != null && fields["step"].stringValue() == RegistryEntityEnums.ConvoTurnStep.CONFIRM) {
        graph.conversationMutator.update(
            taskId,
            mapOf(
                RegistryEntityFields.Convo.CONFIRMED_INTENT to
                    JsonValue.StringValue(fields["note"].stringValue() ?: chosen),
            ),
        )
    }
    graph.taskMutator.touch(taskId)
}

/** What the agent produced (`convo.artifact`): its title, its text and its references. */
@Composable
internal fun ConversationArtifact(record: SyncRecord) {
    val artifact = record.fields[RegistryEntityFields.Convo.ARTIFACT] as? JsonValue.ObjectValue ?: return
    val title = artifact.fields["title"].stringValue() ?: return
    val body = artifact.fields["body"].stringValue().orEmpty()
    val refs = (artifact.fields["refs"] as? JsonValue.ArrayValue)?.values.orEmpty().mapNotNull { it.stringValue() }
    val context = LocalContext.current
    OutlinedCard(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(title, style = MaterialTheme.typography.labelLarge)
            if (body.isNotBlank()) Text(body, style = MaterialTheme.typography.bodySmall)
            refs.forEach { ref ->
                val link = isWebLink(ref)
                Text(
                    ref,
                    style = MaterialTheme.typography.bodySmall,
                    color = if (link) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = if (link) Modifier.clickable { openUrl(context, ref) } else Modifier,
                )
            }
        }
    }
}

/**
 * Whose move it is when no question and no review waits: the handoff button, the end
 * state, or the agent's status with Stop and Resume. Same order as Apple `ConversationCard`.
 */
@Composable
internal fun ConversationStatus(
    record: SyncRecord,
    conversation: TaskConversation,
    stopTitle: String,
    enabled: Boolean,
    languageTag: String,
    onToggleStopped: () -> Unit,
) {
    val handoff = record.fields[RegistryEntityFields.Convo.HANDOFF] as? JsonValue.ObjectValue
    when {
        handoff != null -> Handoff(handoff)
        conversation.isTerminal -> {
            val wontDo = conversation.endState == RegistryEntityEnums.ConvoEndState.WONT_DO
            Column {
                Text(
                    detailControl(
                        if (wontDo) RegistryTaskDetail.Controls.CONVERSATION_WONT_DO else RegistryTaskDetail.Controls.CONVERSATION_RESOLVED,
                        languageTag,
                    ),
                    style = MaterialTheme.typography.bodyMedium,
                )
                conversation.endStateNote?.takeIf(String::isNotBlank)?.let {
                    Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        else -> Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            val status = when {
                conversation.stoppedAt != null -> RegistryTaskDetail.Controls.CONVERSATION_STOPPED
                conversation.isClaimed() -> RegistryTaskDetail.Controls.CONVERSATION_WORKING
                else -> RegistryTaskDetail.Controls.CONVERSATION_WAITING
            }
            Text(
                detailControl(status, languageTag),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.weight(1f),
            )
            TextButton(onClick = onToggleStopped, enabled = enabled) { Text(stopTitle) }
        }
    }
}

/** The agent's done bar (`convo.acceptance`), apart from the task's own completion. */
@Composable
internal fun ConversationAcceptance(record: SyncRecord, languageTag: String) {
    val acceptance = record.fields[RegistryEntityFields.Convo.ACCEPTANCE].stringValue()?.takeIf(String::isNotBlank) ?: return
    HorizontalDivider()
    Text(
        detailControl(RegistryTaskDetail.Controls.CONVERSATION_DONE_WHEN, languageTag).replace("{acceptance}", acceptance),
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

/** The human last mile: opens a link, an email or a call; plain text when it has no action. */
@Composable
private fun Handoff(handoff: JsonValue.ObjectValue) {
    val context = LocalContext.current
    val instruction = handoff.fields["instruction"].stringValue().orEmpty()
    val payload = handoff.fields["payload"].stringValue()?.takeIf(String::isNotBlank)
    val url = when (handoff.fields["actionType"].stringValue()) {
        // An agent writes the payload: only web links open, never another app's scheme.
        RegistryEntityEnums.ConvoHandoffActionType.OPEN_URL -> payload?.takeIf(::isWebLink)
        RegistryEntityEnums.ConvoHandoffActionType.COMPOSE -> payload?.let { "mailto:$it" }
        RegistryEntityEnums.ConvoHandoffActionType.CALL -> payload?.let { "tel:$it" }
        RegistryEntityEnums.ConvoHandoffActionType.NONE -> null
        else -> null
    }
    if (url == null) {
        Text(instruction, style = MaterialTheme.typography.bodyMedium)
    } else {
        Button(onClick = { openUrl(context, url) }, modifier = Modifier.fillMaxWidth()) { Text(instruction) }
    }
}

private fun isWebLink(text: String): Boolean = text.startsWith("https://") || text.startsWith("http://")

/** A label from surfaces.json `taskDetail.controls`. */
private fun detailControl(key: String, languageTag: String): String {
    val controls = RegistryCatalog.surface(RegistryTaskDetail.ID)?.fields?.get("controls") as? JsonValue.ObjectValue
    return registryText(controls?.fields?.get(key).stringValue(), languageTag)
}
