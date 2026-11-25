package app.septena.android.ui

import android.text.format.DateUtils
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.septena.android.AndroidAppGraph
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.SyncRecord
import app.septena.core.SyncTurn
import app.septena.core.TaskConversation
import app.septena.core.WireTimestamp
import app.septena.core.generated.RegistryActionIds
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.generated.RegistryPromptIds
import app.septena.core.generated.RegistryTaskPageBlockIds
import app.septena.core.stringValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant

private data class ConversationLine(
    val sequence: Long,
    val role: String,
    val step: String?,
    val question: String?,
    val options: List<String>,
    val chosen: String?,
    val otherText: String?,
    val note: String?,
    val inReplyTo: Long?,
)

private data class ConversationSectionData(
    val record: SyncRecord,
    val conversation: TaskConversation,
    val turns: List<ConversationLine>,
)

@Composable
internal fun TaskConversationSection(
    graph: AndroidAppGraph,
    taskId: String,
    isTaskOpen: Boolean,
    canWrite: Boolean,
    heading: String? = null,
    openSendBackInitially: Boolean = false,
) {
    val dataVersion by graph.sync.dataVersion.collectAsStateWithLifecycle()
    val languageTag = LocalConfiguration.current.locales[0].toLanguageTag()
    val scope = rememberCoroutineScope()
    var data by remember(taskId) { mutableStateOf<ConversationSectionData?>(null) }
    var otherVisible by remember(taskId) { mutableStateOf(false) }
    var replyVisible by remember(taskId) { mutableStateOf(false) }
    var otherText by remember(taskId) { mutableStateOf("") }
    var replyText by remember(taskId) { mutableStateOf("") }
    var sendBackVisible by remember(taskId, openSendBackInitially) { mutableStateOf(openSendBackInitially) }
    var sendBackText by remember(taskId) { mutableStateOf("") }
    var busy by remember(taskId) { mutableStateOf(false) }

    LaunchedEffect(graph, taskId, dataVersion) {
        data = withContext(Dispatchers.IO) {
            val record = graph.taskStore.record(RegistryEntityNames.CONVO, taskId)
                ?: SyncRecord(RegistryEntityNames.CONVO, taskId, emptyMap())
            val turns = graph.taskStore.turns(taskId)
            ConversationSectionData(
                record = record,
                conversation = TaskConversation.from(record, turns),
                turns = turns.sortedBy(SyncTurn::sequence).map(SyncTurn::asConversationLine),
            )
        }
    }

    val current = data ?: return
    val conversation = current.conversation
    if (!conversation.hasStarted && !conversation.isHandedToClaude) {
        DiscussStart(graph, taskId, isTaskOpen, canWrite, languageTag)
        return
    }

    val openQuestion = current.turns.lastOrNull()?.takeIf {
        it.role == RegistryEntityEnums.ConvoTurnRole.PROVIDER && it.options.isNotEmpty()
    }
    val transcript = if (openQuestion == null) current.turns else current.turns.dropLast(1)
    val stopTitle = RegistryCatalog.actionTitle(
        RegistryActionIds.TASK_CONVERSATION_STOP,
        field = if (conversation.stoppedAt != null) "activeTitle" else "title",
        languageTag = languageTag,
    ).orEmpty()
    val otherTitle = RegistryCatalog.actionTitle(RegistryActionIds.TASK_CONVERSATION_OTHER, languageTag = languageTag).orEmpty()
    val sendTitle = RegistryCatalog.actionTitle(RegistryActionIds.TASK_CONVERSATION_SEND, languageTag = languageTag).orEmpty()
    val replyTitle = RegistryCatalog.actionTitle(RegistryActionIds.TASK_CONVERSATION_REPLY, languageTag = languageTag).orEmpty()
    val otherPrompt = conversationTextPrompt(RegistryPromptIds.CONVERSATION_OTHER, languageTag)
    val replyPrompt = conversationTextPrompt(RegistryPromptIds.CONVERSATION_REPLY, languageTag)
    val sendBackPrompt = conversationTextPrompt(RegistryPromptIds.SEND_BACK_REVIEW, languageTag)
    val acceptTitle = RegistryCatalog.actionTitle(RegistryActionIds.TASK_ACCEPT_REVIEW, languageTag = languageTag).orEmpty()
    val sendBackTitle = RegistryCatalog.actionTitle(RegistryActionIds.TASK_SEND_BACK_REVIEW, languageTag = languageTag).orEmpty()
    fun localized(key: String) = RegistryCatalog.localizedString(key, languageTag) ?: key
    val cancelTitle = localized("Cancel")
    // The kickers never name one agent: several can hand off.
    val promptCopy = RegistryCatalog.surface(RegistryTaskPageBlockIds.TASK_PAGE_CONVERSATION)?.fields
    val askKicker = registryText(promptCopy?.get("askKicker").stringValue(), languageTag)
    val reviewRequested = registryText(promptCopy?.get("reviewKicker").stringValue(), languageTag)
    val reviewKicker = relativeAgo(conversation.endStateAt)?.let { "$reviewRequested · $it" } ?: reviewRequested
    val readyForReview = registryText(promptCopy?.get("reviewFallback").stringValue(), languageTag)

    fun appendTurn(fields: Map<String, JsonValue>, afterSuccess: () -> Unit = {}) {
        if (!canWrite || busy) return
        scope.launch {
            busy = true
            runCatching {
                withContext(Dispatchers.IO) {
                    appendUserTurn(graph, taskId, fields)
                }
            }.onSuccess {
                graph.sync.noteLocalChange()
                graph.sync.requestSync()
                afterSuccess()
            }
            busy = false
        }
    }

    fun answer(question: ConversationLine, value: String, asOther: Boolean = false) {
        val clean = value.trim()
        if (clean.isEmpty()) return
        appendTurn(
            buildMap {
                put("role", JsonValue.StringValue(RegistryEntityEnums.ConvoTurnRole.USER))
                put("step", JsonValue.StringValue(question.step ?: RegistryEntityEnums.ConvoTurnStep.WORK))
                put(if (asOther) "otherText" else "chosen", JsonValue.StringValue(clean))
                put("inReplyTo", JsonValue.IntegerValue(question.sequence))
                put("ts", JsonValue.StringValue(WireTimestamp.format(graph.clock.now())))
            },
        ) {
            otherText = ""
            otherVisible = false
        }
    }

    fun sendReply() {
        val clean = replyText.trim()
        if (clean.isEmpty()) return
        appendTurn(
            mapOf(
                "role" to JsonValue.StringValue(RegistryEntityEnums.ConvoTurnRole.USER),
                "step" to JsonValue.StringValue(RegistryEntityEnums.ConvoTurnStep.WORK),
                "note" to JsonValue.StringValue(clean),
                "ts" to JsonValue.StringValue(WireTimestamp.format(graph.clock.now())),
            ),
        ) {
            replyText = ""
            replyVisible = false
        }
    }

    /**
     * Accept = unified path shared with Review list rows (`AndroidAppGraph.acceptReview`, #415):
     * completes, acknowledges, stamps fade clock, sets `agent_assisted_done`, and records undo.
     */
    fun acceptReview() {
        if (!canWrite || busy) return
        scope.launch {
            busy = true
            runCatching {
                withContext(Dispatchers.IO) { check(graph.acceptReview(taskId)) }
            }.onSuccess {
                sendBackVisible = false
                graph.sync.noteLocalChange()
                graph.sync.requestSync()
            }
            busy = false
        }
    }

    /**
     * Send back = unified path (`AndroidAppGraph.sendBackReview`, #412/#415):
     * appends user turn, reopens conversation for Claude, stamps fade clock, and records undo.
     */
    fun sendBack() {
        val clean = sendBackText.trim()
        if (clean.isEmpty() || !canWrite || busy) return
        scope.launch {
            busy = true
            runCatching {
                withContext(Dispatchers.IO) { check(graph.sendBackReview(taskId, clean)) }
            }.onSuccess {
                sendBackText = ""
                sendBackVisible = false
                graph.sync.noteLocalChange()
                graph.sync.requestSync()
            }
            busy = false
        }
    }

    fun toggleStopped() {
        if (!canWrite || busy) return
        val stopped = conversation.stoppedAt != null
        val changes = if (stopped) {
            mapOf(
                RegistryEntityFields.Convo.STOPPED_AT to JsonValue.Null,
                RegistryEntityFields.Convo.ASSIGNEE to JsonValue.StringValue(RegistryEntityEnums.ConvoAssignee.CLAUDE),
            )
        } else {
            mapOf(
                RegistryEntityFields.Convo.STOPPED_AT to JsonValue.StringValue(WireTimestamp.format(graph.clock.now())),
            )
        }
        scope.launch {
            busy = true
            runCatching {
                withContext(Dispatchers.IO) { graph.conversationMutator.update(taskId, changes) }
            }.onSuccess {
                graph.sync.noteLocalChange()
                graph.sync.requestSync()
            }
            busy = false
        }
    }

    Column(
        modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // The heading shows only when the conversation has started, so an empty task shows no empty section.
        if (heading != null) Text(heading, style = MaterialTheme.typography.titleMedium)
        transcript.forEach { line ->
            val text = when (line.role) {
                RegistryEntityEnums.ConvoTurnRole.PROVIDER -> line.question ?: line.note
                RegistryEntityEnums.ConvoTurnRole.USER -> line.chosen ?: line.otherText ?: line.note
                else -> null
            }
            if (!text.isNullOrBlank()) {
                Text(
                    text = text,
                    style = MaterialTheme.typography.bodyMedium,
                    color = if (line.role == RegistryEntityEnums.ConvoTurnRole.PROVIDER && line.question == null) {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    } else {
                        MaterialTheme.colorScheme.onSurface
                    },
                )
            }
        }

        ConversationArtifact(current.record)

        // The agent prompt (docs/AGENT_PROMPT_SPEC.md): kicker, question, a vertical
        // list of full-width choices, and a last choice that turns into a field.
        if (openQuestion != null) {
            AgentPromptKicker(askKicker)
            Text(openQuestion.question.orEmpty(), style = MaterialTheme.typography.titleMedium)
            openQuestion.options.forEach { option ->
                OutlinedButton(
                    onClick = { answer(openQuestion, option) },
                    enabled = canWrite && !busy,
                    modifier = Modifier.fillMaxWidth().heightIn(min = PROMPT_TARGET_HEIGHT),
                ) {
                    Text(option, modifier = Modifier.fillMaxWidth())
                }
            }
            if (otherVisible) {
                AgentPromptField(
                    value = otherText,
                    onValueChange = { otherText = it },
                    label = otherPrompt.placeholder,
                    minLines = 3,
                    confirmTitle = otherPrompt.confirmTitle.ifEmpty { sendTitle },
                    cancelTitle = cancelTitle,
                    enabled = canWrite && !busy,
                    onSend = { answer(openQuestion, otherText, asOther = true) },
                    onCancel = { otherVisible = false },
                )
            } else {
                OutlinedButton(
                    onClick = { otherVisible = true },
                    enabled = canWrite && !busy,
                    modifier = Modifier.fillMaxWidth().heightIn(min = PROMPT_TARGET_HEIGHT),
                ) {
                    Text(otherTitle, modifier = Modifier.fillMaxWidth())
                }
            }
        } else if (conversation.needsHumanReview) {
            if (isTaskOpen) {
                AgentPromptKicker(reviewKicker)
                Text(
                    conversation.endStateNote?.takeIf(String::isNotBlank) ?: readyForReview,
                    style = MaterialTheme.typography.bodyLarge,
                )
                // Accept first, Send back second, on every surface.
                Button(
                    onClick = ::acceptReview,
                    enabled = canWrite && !busy,
                    modifier = Modifier.fillMaxWidth().heightIn(min = PROMPT_TARGET_HEIGHT),
                ) {
                    Text(acceptTitle)
                }
                if (sendBackVisible) {
                    AgentPromptField(
                        value = sendBackText,
                        onValueChange = { sendBackText = it },
                        label = sendBackPrompt.placeholder,
                        minLines = 3,
                        confirmTitle = sendBackPrompt.confirmTitle.ifEmpty { sendTitle },
                        cancelTitle = cancelTitle,
                        enabled = canWrite && !busy,
                        onSend = ::sendBack,
                        onCancel = { sendBackVisible = false },
                    )
                } else {
                    OutlinedButton(
                        onClick = { sendBackVisible = true },
                        enabled = canWrite && !busy,
                        modifier = Modifier.fillMaxWidth().heightIn(min = PROMPT_TARGET_HEIGHT),
                    ) {
                        Text(sendBackTitle)
                    }
                }
            } else {
                conversation.endStateNote?.takeIf(String::isNotBlank)?.let { Text(it) }
            }
        } else {
            ConversationStatus(current.record, conversation, stopTitle, canWrite && !busy, languageTag, ::toggleStopped)
        }

        if (openQuestion == null && isTaskOpen && !conversation.needsHumanReview) {
            if (replyVisible) {
                AgentPromptField(
                    value = replyText,
                    onValueChange = { replyText = it },
                    label = replyPrompt.placeholder,
                    minLines = 2,
                    confirmTitle = replyPrompt.confirmTitle.ifEmpty { sendTitle },
                    cancelTitle = cancelTitle,
                    enabled = canWrite && !busy,
                    onSend = ::sendReply,
                    onCancel = { replyVisible = false },
                )
            } else {
                TextButton(onClick = { replyVisible = true }, enabled = canWrite && !busy) {
                    Text(replyTitle)
                }
            }
        }

        ConversationAcceptance(current.record, languageTag)
    }
}

/** 48dp: the Material touch target, the Android match for the 44pt agent prompt targets. */
private val PROMPT_TARGET_HEIGHT = 48.dp

/** The agent prompt kicker: who asks and when, one small line in secondary ink. */
@Composable
private fun AgentPromptKicker(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

/**
 * "Tell the agent instead": a multi-line field that grows to about six lines,
 * a primary send button and Cancel. The field takes focus when it appears.
 * The draft lives in the caller's state, so Cancel keeps it for the next open.
 */
@Composable
private fun AgentPromptField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    minLines: Int,
    confirmTitle: String,
    cancelTitle: String,
    enabled: Boolean,
    onSend: () -> Unit,
    onCancel: () -> Unit,
) {
    val focusRequester = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { focusRequester.requestFocus() } }
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        modifier = Modifier.fillMaxWidth().focusRequester(focusRequester),
        enabled = enabled,
        singleLine = false,
        minLines = minLines,
        maxLines = 6,
    )
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TextButton(onClick = onCancel, modifier = Modifier.heightIn(min = PROMPT_TARGET_HEIGHT)) {
            Text(cancelTitle)
        }
        Button(
            onClick = onSend,
            enabled = enabled && value.isNotBlank(),
            modifier = Modifier.heightIn(min = PROMPT_TARGET_HEIGHT),
        ) {
            Text(confirmTitle)
        }
    }
}

/** "2 hours ago" from a wire timestamp, or null when it is missing or unreadable. */
internal fun relativeAgo(stamp: String?): String? {
    if (stamp == null) return null
    val millis = runCatching { Instant.parse(stamp).toEpochMilli() }.getOrNull() ?: return null
    return DateUtils.getRelativeTimeSpanString(millis, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS).toString()
}

private fun SyncTurn.asConversationLine(): ConversationLine = ConversationLine(
    sequence = sequence,
    role = fields["role"].stringValue().orEmpty(),
    step = fields["step"].stringValue(),
    question = fields["question"].stringValue(),
    options = (fields["options"] as? JsonValue.ArrayValue)?.values?.mapNotNull(JsonValue?::stringValue).orEmpty(),
    chosen = fields["chosen"].stringValue(),
    otherText = fields["otherText"].stringValue(),
    note = fields["note"].stringValue(),
    inReplyTo = when (val value = fields["inReplyTo"]) {
        is JsonValue.IntegerValue -> value.value
        is JsonValue.DecimalValue -> value.value.toLong()
        else -> null
    },
)

private data class ConversationTextPrompt(val placeholder: String, val confirmTitle: String)

private fun conversationTextPrompt(id: String, languageTag: String): ConversationTextPrompt {
    val fields = RegistryCatalog.surface(id)?.fields
    fun text(key: String): String {
        val value = fields?.get(key).stringValue().orEmpty()
        return if (value.isEmpty()) value else RegistryCatalog.localizedString(value, languageTag) ?: value
    }
    return ConversationTextPrompt(placeholder = text("placeholder"), confirmTitle = text("confirmTitle"))
}
