package app.septena.core

import app.septena.sharedcore.conversationState
import app.septena.sharedcore.deriveConversation
import java.time.Instant
import app.septena.sharedcore.ConversationTurn as CoreConversationTurn
import app.septena.sharedcore.TaskConversation as CoreTaskConversation

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
    /** The core's predicates (`convo.rs`). A live claim needs a clock; these do not. */
    private fun state(now: Instant = Instant.now()) = conversationState(toCore(), now.toString())

    val isTerminal: Boolean get() = state().isTerminal
    val needsHumanReview: Boolean get() = state().needsHumanReview
    val hasOpenProviderQuestion: Boolean get() = state().hasOpenProviderQuestion
    val awaitsHuman: Boolean get() = state().awaitsHuman
    val hasStarted: Boolean get() = state().hasStarted

    /** The Agent list stage (queued, working, yourTurn, review, done), or null when not agent work. */
    fun agentStage(now: Instant = Instant.now()): String? = state(now).agentStage

    /** The agent holds the turn (the row shows "working"): it does not fade. */
    fun isAgentTurn(now: Instant = Instant.now()): Boolean =
        deriveConversation(toCore(), now.toString()).badge == "working"

    fun isPendingReasoning(now: Instant = Instant.now()): Boolean =
        deriveConversation(toCore(), now.toString()).pendingReasoning

    internal fun toCore() = CoreTaskConversation(
        confirmedIntent = confirmedIntent,
        thread = thread.map { CoreConversationTurn(it.sequence, it.role, it.options, it.confidence) },
        artifactExists = artifactExists,
        handoffExists = handoffExists,
        endState = endState,
        endStateNote = endStateNote,
        assignee = assignee,
        stoppedAt = stoppedAt,
        claimUntil = claimUntil,
    )

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

/** The conversation projection, from the shared core (`convo.rs`, ADR 0025 C1 #247). */
object ConversationRules {
    fun derive(conversation: TaskConversation, now: Instant): ConversationProjection {
        val p = deriveConversation(conversation.toCore(), now.toString())
        return ConversationProjection(p.stage, p.badge, p.nextAction, p.pendingReasoning)
    }
}
