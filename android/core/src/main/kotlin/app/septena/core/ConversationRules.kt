package app.septena.core

import app.septena.core.generated.RegistryEntityFields
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

/** Single-call snapshot of the core's conversation predicates for one timestamp. */
data class ConversationSnapshotState(
    val isTerminal: Boolean,
    val needsHumanReview: Boolean,
    val awaitsHuman: Boolean,
    val isClaimed: Boolean,
    val agentStage: String?,
    /** The Review group an open task is in because of its conversation ([ReviewGroupIds]), or null. */
    val reviewGroup: String?,
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
    /**
     * When `endState` last changed (`convos.endStateAt`). Server-owned: the app
     * reads it for "{ago}" on the agent prompt and never writes it. Kotlin-side
     * only; the core's conversation rules do not use it.
     */
    val endStateAt: String? = null,
    /** When the last turn was written. Kotlin-side only, like [endStateAt]. */
    val lastTurnAt: String? = null,
) {
    /** The core's predicates (`convo.rs`). A live claim needs a clock; these do not. */
    private fun state(now: Instant = Instant.now()) = conversationState(toCore(), now.toString())

    /** Evaluates all core conversation predicates in one FFI call. */
    fun evaluate(now: Instant = Instant.now()): ConversationSnapshotState {
        val s = state(now)
        return ConversationSnapshotState(
            isTerminal = s.isTerminal,
            needsHumanReview = s.needsHumanReview,
            awaitsHuman = s.awaitsHuman,
            isClaimed = s.isClaimed,
            agentStage = s.agentStage,
            reviewGroup = s.reviewGroup,
        )
    }

    val isTerminal: Boolean get() = state().isTerminal
    val needsHumanReview: Boolean get() = state().needsHumanReview
    val hasOpenProviderQuestion: Boolean get() = state().hasOpenProviderQuestion
    val awaitsHuman: Boolean get() = state().awaitsHuman
    val hasStarted: Boolean get() = state().hasStarted

    /** An agent holds a live claim on the task (it is working now). */
    fun isClaimed(now: Instant = Instant.now()): Boolean = state(now).isClaimed

    /** The Agent list stage (queued, working, yourTurn, stopped, review, done), or null when not agent work. */
    fun agentStage(now: Instant = Instant.now()): String? = state(now).agentStage

    /** The agent holds the turn (the row shows "working") or a live claim: the task does not fade. */
    fun isAgentTurn(now: Instant = Instant.now()): Boolean =
        isClaimed(now) || deriveConversation(toCore(), now.toString()).badge == "working"

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
        /** The conversation hands the task to the user to check. The end state alone decides it, so no turns are read. */
        fun needsHumanReview(record: SyncRecord): Boolean =
            record.deletedAt == null && record.fields["endState"].stringValue() != null &&
                from(record, emptyList()).needsHumanReview

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
                // The core reads a claim only when it has a claimant (`convo.rs`, `is_claimed`).
                claimUntil = fields["claimUntil"].stringValue().takeIf { fields["claimedBy"].stringValue() != null },
                endStateAt = fields[RegistryEntityFields.Convo.END_STATE_AT].stringValue(),
                lastTurnAt = turns.maxByOrNull(SyncTurn::sequence)?.fields?.get("ts").stringValue(),
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
