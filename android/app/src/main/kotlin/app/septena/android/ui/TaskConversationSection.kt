package app.septena.android.ui

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.FilterChip
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
import androidx.compose.ui.Modifier
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
import app.septena.core.stringValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

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
    val conversation: TaskConversation,
    val turns: List<ConversationLine>,
)

@Composable
internal fun TaskConversationSection(
    graph: AndroidAppGraph,
    taskId: String,
    isTaskOpen: Boolean,
    canWrite: Boolean,
) {
    val dataVersion by graph.sync.dataVersion.collectAsStateWithLifecycle()
    val languageTag = LocalConfiguration.current.locales[0].toLanguageTag()
    val scope = rememberCoroutineScope()
    var data by remember(taskId) { mutableStateOf<ConversationSectionData?>(null) }
    var otherVisible by remember(taskId) { mutableStateOf(false) }
    var replyVisible by remember(taskId) { mutableStateOf(false) }
    var otherText by remember(taskId) { mutableStateOf("") }
    var replyText by remember(taskId) { mutableStateOf("") }
    var busy by remember(taskId) { mutableStateOf(false) }

    LaunchedEffect(graph, taskId, dataVersion) {
        data = withContext(Dispatchers.IO) {
            val record = graph.taskStore.record(RegistryEntityNames.CONVO, taskId)
                ?: SyncRecord(RegistryEntityNames.CONVO, taskId, emptyMap())
            val turns = graph.taskStore.turns(taskId)
            ConversationSectionData(
                conversation = TaskConversation.from(record, turns),
                turns = turns.sortedBy(SyncTurn::sequence).map(SyncTurn::asConversationLine),
            )
        }
    }

    val current = data ?: return
    val conversation = current.conversation
    if (!conversation.hasStarted) return

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

    fun appendTurn(fields: Map<String, JsonValue>, afterSuccess: () -> Unit = {}) {
        if (!canWrite || busy) return
        scope.launch {
            busy = true
            runCatching {
                withContext(Dispatchers.IO) {
                    graph.conversationMutator.appendTurn(taskId, fields)
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
        transcript.forEach { line ->
            val text = when (line.role) {
                RegistryEntityEnums.ConvoTurnRole.PROVIDER -> line.question ?: line.note
                RegistryEntityEnums.ConvoTurnRole.USER -> line.chosen ?: line.otherText ?: line.note
                else -> null
            }
            if (!text.isNullOrBlank()) {
                Text(
                    text = text,
                    style = if (line.role == RegistryEntityEnums.ConvoTurnRole.PROVIDER) {
                        MaterialTheme.typography.bodyMedium
                    } else {
                        MaterialTheme.typography.bodyMedium
                    },
                    color = if (line.role == RegistryEntityEnums.ConvoTurnRole.PROVIDER && line.question == null) {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    } else {
                        MaterialTheme.colorScheme.onSurface
                    },
                )
            }
        }

        if (openQuestion != null) {
            Text(openQuestion.question.orEmpty(), style = MaterialTheme.typography.titleMedium)
            if (openQuestion.options.any { it.length > 22 }) {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    openQuestion.options.forEach { option ->
                        OutlinedButton(
                            onClick = { answer(openQuestion, option) },
                            enabled = canWrite && !busy,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text(option, modifier = Modifier.fillMaxWidth())
                        }
                    }
                    TextButton(onClick = { otherVisible = !otherVisible }, enabled = canWrite && !busy) {
                        Text(otherTitle)
                    }
                }
            } else {
                Row(
                    modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    openQuestion.options.forEach { option ->
                        FilterChip(
                            selected = false,
                            onClick = { answer(openQuestion, option) },
                            enabled = canWrite && !busy,
                            label = { Text(option) },
                        )
                    }
                    FilterChip(
                        selected = false,
                        onClick = { otherVisible = !otherVisible },
                        enabled = canWrite && !busy,
                        label = { Text(otherTitle) },
                    )
                }
            }

            if (otherVisible) {
                OutlinedTextField(
                    value = otherText,
                    onValueChange = { otherText = it },
                    label = { Text(otherPrompt.placeholder) },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = canWrite && !busy,
                    singleLine = true,
                )
                TextButton(
                    onClick = { answer(openQuestion, otherText, asOther = true) },
                    enabled = canWrite && !busy && otherText.isNotBlank(),
                ) {
                    Text(sendTitle)
                }
            }
        } else if (conversation.needsHumanReview) {
            conversation.endStateNote?.takeIf(String::isNotBlank)?.let { Text(it) }
        } else if (!conversation.isTerminal && !conversation.handoffExists) {
            TextButton(onClick = ::toggleStopped, enabled = canWrite && !busy) {
                Text(stopTitle)
            }
        }

        if (openQuestion == null && isTaskOpen && !conversation.needsHumanReview) {
            if (replyVisible) {
                OutlinedTextField(
                    value = replyText,
                    onValueChange = { replyText = it },
                    label = { Text(replyPrompt.placeholder) },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = canWrite && !busy,
                    singleLine = true,
                )
                TextButton(onClick = ::sendReply, enabled = canWrite && !busy && replyText.isNotBlank()) {
                    Text(sendTitle)
                }
            } else {
                TextButton(onClick = { replyVisible = true }, enabled = canWrite && !busy) {
                    Text(replyTitle)
                }
            }
        }
    }
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

private data class ConversationTextPrompt(val placeholder: String)

private fun conversationTextPrompt(id: String, languageTag: String): ConversationTextPrompt {
    val value = RegistryCatalog.surface(id)?.fields?.get("placeholder").stringValue().orEmpty()
    return ConversationTextPrompt(RegistryCatalog.localizedString(value, languageTag) ?: value)
}
