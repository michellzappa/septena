package app.septena.windows

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
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
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.SyncTurn
import app.septena.core.TaskConversation
import app.septena.core.generated.RegistryActionIds
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryPromptIds
import app.septena.core.generated.RegistryTaskPageBlockIds
import app.septena.core.stringValue
import java.time.Instant

internal sealed interface ConversationEdit {
    data class Stop(val stopped: Boolean) : ConversationEdit
    data class Answer(val sequence: Long, val text: String, val other: Boolean = false) : ConversationEdit
    data class Reply(val text: String) : ConversationEdit
}

internal data class DesktopConversation(val state: TaskConversation, val turns: List<SyncTurn>) {
    fun question(): SyncTurn? = turns.lastOrNull()?.takeIf {
        !it.isPending && it.fields["role"].stringValue() == RegistryEntityEnums.ConvoTurnRole.PROVIDER &&
            it.choices().isNotEmpty()
    }

    fun canStop(now: Instant): Boolean = !state.evaluate(now).isTerminal &&
        (state.stoppedAt != null || state.assignee == RegistryEntityEnums.ConvoAssignee.CLAUDE)
}

internal fun SyncTurn.choices(): List<String> = (fields["options"] as? JsonValue.ArrayValue)
    ?.values.orEmpty().mapNotNull { it.stringValue() }

private fun SyncTurn.displayText(): String? = when (fields["role"].stringValue()) {
    RegistryEntityEnums.ConvoTurnRole.PROVIDER -> fields["question"].stringValue() ?: fields["note"].stringValue()
    RegistryEntityEnums.ConvoTurnRole.USER -> fields["chosen"].stringValue()
        ?: fields["otherText"].stringValue() ?: fields["note"].stringValue()
    else -> null
}

@Composable
internal fun DesktopConversationDialog(
    conversation: DesktopConversation,
    now: Instant,
    languageTag: String,
    enabled: Boolean,
    canWrite: Boolean,
    error: String?,
    onBack: () -> Unit,
    onEdit: (ConversationEdit, () -> Unit) -> Unit,
) {
    fun localized(text: String) = RegistryCatalog.localizedString(text, languageTag) ?: text
    fun copy(id: String, field: String) = localized(RegistryCatalog.surface(id)?.get(field).stringValue().orEmpty())
    fun action(id: String, field: String = "title") = RegistryCatalog.actionTitle(id, field, languageTag).orEmpty()
    val question = conversation.question()
    val canEdit = enabled && canWrite
    var reply by remember(question?.sequence) { mutableStateOf("") }
    var other by remember(question?.sequence) { mutableStateOf(false) }
    val block = RegistryTaskPageBlockIds.TASK_PAGE_CONVERSATION

    AlertDialog(
        onDismissRequest = { if (enabled) onBack() },
        title = { Text(copy(block, "label")) },
        text = {
            Column(
                modifier = Modifier.heightIn(max = 400.dp).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                for (turn in conversation.turns) {
                    if (turn == question) continue
                    turn.displayText()?.let { text ->
                        Text(text, style = MaterialTheme.typography.bodyMedium)
                        if (turn.isPending) {
                            Text(localized("Pending"), style = MaterialTheme.typography.labelSmall)
                        }
                    }
                }
                if (question != null) {
                    Text(copy(block, "askKicker"), style = MaterialTheme.typography.labelMedium)
                    Text(question.displayText().orEmpty(), style = MaterialTheme.typography.titleMedium)
                    for (choice in question.choices()) {
                        OutlinedButton(
                            enabled = canEdit,
                            onClick = { onEdit(ConversationEdit.Answer(question.sequence, choice)) {} },
                            modifier = Modifier.fillMaxWidth(),
                        ) { Text(choice) }
                    }
                    if (!other) {
                        TextButton(enabled = canEdit, onClick = { other = true }) {
                            Text(action(RegistryActionIds.TASK_CONVERSATION_OTHER))
                        }
                    }
                }
                if (canWrite && (question == null || other)) {
                    val prompt = if (question == null) RegistryPromptIds.CONVERSATION_REPLY else RegistryPromptIds.CONVERSATION_OTHER
                    OutlinedTextField(
                        value = reply,
                        onValueChange = { reply = it },
                        label = { Text(copy(prompt, "placeholder")) },
                        enabled = enabled,
                        minLines = 2,
                        maxLines = 4,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Button(enabled = canEdit && reply.isNotBlank(), onClick = {
                        val edit = if (question == null) ConversationEdit.Reply(reply)
                        else ConversationEdit.Answer(question.sequence, reply, other = true)
                        onEdit(edit) {
                            reply = ""
                            other = false
                        }
                    }) { Text(copy(prompt, "confirmTitle")) }
                }
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        dismissButton = if (canWrite && conversation.canStop(now)) {
            {
                val stopped = conversation.state.stoppedAt != null
                TextButton(enabled = enabled, onClick = { onEdit(ConversationEdit.Stop(!stopped)) {} }) {
                    Text(action(RegistryActionIds.TASK_CONVERSATION_STOP, if (stopped) "activeTitle" else "title"))
                }
            }
        } else null,
        confirmButton = { TextButton(enabled = enabled, onClick = onBack) { Text(localized("Back")) } },
    )
}
