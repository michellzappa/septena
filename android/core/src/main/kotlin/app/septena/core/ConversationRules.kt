package app.septena.core

import app.septena.core.generated.RegistryEntityEnums
import java.time.Instant

data class ConversationTurn(
    val sequence: Long,
    val role: String,
    val options: List<String>? = null,
    val confidence: Double? = null,
)

data class TaskConversation(
    val confirmedIntent: String? = null,
    val thread: List<ConversationTurn> = emptyList(),
    val artifactExists: Boolean = false,
    val handoffExists: Boolean = false,
    val endState: String? = null,
    val endStateNote: String? = null,
    val assignee: String? = null,
    val stoppedAt: String? = null,
    val claimUntil: String? = null,
) {
    val isTerminal: Boolean get() = endState != null && endState != RegistryEntityEnums.ConvoEndState.OPEN
    val needsHumanReview: Boolean get() = endState == RegistryEntityEnums.ConvoEndState.NEEDS_VERIFY
    val hasOpenProviderQuestion: Boolean
        get() = thread.lastOrNull()?.let {
            it.role == RegistryEntityEnums.ConvoTurnRole.PROVIDER && !it.options.isNullOrEmpty()
        } == true
    val awaitsHuman: Boolean get() = needsHumanReview || hasOpenProviderQuestion
    val hasStarted: Boolean
        get() = thread.isNotEmpty() || confirmedIntent != null || isTerminal || artifactExists || handoffExists

    fun isPendingReasoning(): Boolean {
        if (isTerminal || stoppedAt != null) return false
        if (assignee == RegistryEntityEnums.ConvoAssignee.CLAUDE) return true
        val lastProviderConfidence = thread.lastOrNull {
            it.role == RegistryEntityEnums.ConvoTurnRole.PROVIDER
        }?.confidence
        return lastProviderConfidence != null && lastProviderConfidence < 0.5
    }

    companion object {
        fun from(record: SyncRecord, turns: List<SyncTurn>): TaskConversation {
            require(record.entity == "convo") { "Expected a conversation record" }
            val fields = record.fields
            return TaskConversation(
                confirmedIntent = fields["confirmedIntent"].stringValue(),
                thread = turns.sortedBy(SyncTurn::sequence).map { turn ->
                    val values = turn.fields
                    ConversationTurn(
                        sequence = turn.sequence,
                        role = values["role"].stringValue().orEmpty(),
                        options = (values["options"] as? JsonValue.ArrayValue)?.values?.mapNotNull { it.stringValue() },
                        confidence = when (val value = values["confidence"]) {
                            is JsonValue.IntegerValue -> value.value.toDouble()
                            is JsonValue.DecimalValue -> value.value
                            else -> null
                        },
                    )
                },
                artifactExists = fields["artifact"]?.let { it !== JsonValue.Null } == true,
                handoffExists = fields["handoff"]?.let { it !== JsonValue.Null } == true,
                endState = fields["endState"].stringValue(),
                endStateNote = fields["endStateNote"].stringValue(),
                assignee = fields["assignee"].stringValue(),
                stoppedAt = fields["stoppedAt"].stringValue(),
                claimUntil = fields["claimUntil"].stringValue(),
            )
        }
    }
}

data class ConversationProjection(
    val stage: String,
    val badge: String?,
    val nextAction: String,
    val pendingReasoning: Boolean,
)

/** Pure conversation projection shared by task rows, queues and conformance fixtures. */
object ConversationRules {
    fun derive(conversation: TaskConversation, now: Instant): ConversationProjection {
        val pending = conversation.isPendingReasoning()
        if (conversation.needsHumanReview) {
            return ConversationProjection(
                stage = "awaitingHuman",
                badge = "needsYou",
                nextAction = conversation.endStateNote ?: "Needs review",
                pendingReasoning = false,
            )
        }
        if (conversation.isTerminal) {
            val badge = if (conversation.endState == RegistryEntityEnums.ConvoEndState.WONT_DO) "wontDo" else "done"
            return ConversationProjection("terminal", badge, conversation.endStateNote ?: "Resolved", false)
        }
        if (!conversation.hasStarted) {
            return ConversationProjection("open", null, "No conversation yet", pending)
        }
        if (conversation.stoppedAt != null) {
            return ConversationProjection("inProgress", null, "Stopped", false)
        }
        if (conversation.hasOpenProviderQuestion) {
            return ConversationProjection("awaitingHuman", "needsYou", "Tap to answer", pending)
        }
        val stage = if (conversation.confirmedIntent == null) "clarifying" else "inProgress"
        val claimed = conversation.claimUntil
            ?.let { runCatching { Instant.parse(it) }.getOrNull()?.isAfter(now) == true } == true
        return ConversationProjection(stage, "working", if (claimed) "Claude is working" else "Claude's move", pending)
    }
}
