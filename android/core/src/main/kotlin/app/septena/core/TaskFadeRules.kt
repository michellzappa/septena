package app.septena.core

import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryRules
import app.septena.sharedcore.FadeInput
import java.time.Instant
import java.time.ZoneId
import app.septena.sharedcore.fadeFill as coreFadeFill
import app.septena.sharedcore.rowOpacity as coreRowOpacity
import app.septena.sharedcore.shouldFade as coreShouldFade

/**
 * What a user gesture means for the fade clock (docs/TASK_FADE_SPEC.md §3), read from the task before
 * and after its write. Mirrors Apple's `TaskUndo` recorders.
 */
object TaskTouchRules {
    /** A hand reorder is not an edit, as on Apple. */
    private val ORDER_FIELDS = setOf(RegistryEntityFields.Task.POSITION, RegistryEntityFields.Task.TODAY_POSITION)

    /**
     * True when the gesture edited a task that is still there and the write did not stamp the clock
     * itself. A delete and a reorder do not stamp.
     */
    fun stamps(before: SyncRecord, after: SyncRecord): Boolean {
        if (after.deletedAt != null) return false
        if (before.deletedAt != null) return true
        val changed = (before.fields.keys + after.fields.keys).filter { before.value(it) != after.value(it) }
        return RegistryEntityFields.Task.TOUCHED_AT !in changed && changed.any { it !in ORDER_FIELDS }
    }

    /** The task left Today, moved to a later day, or was planned past its deadline. Dating an undated task is not a defer. */
    fun isDefer(before: SyncRecord, after: SyncRecord): Boolean {
        val today = RegistryEntityFields.Task.TODAY
        if (before.value(today).booleanValue() == true && after.value(today).booleanValue() != true) return true
        val deferredDeadline = after.value(RegistryEntityFields.Task.DEFERRED_DEADLINE).stringValue()
        if (deferredDeadline != null && deferredDeadline != before.value(RegistryEntityFields.Task.DEFERRED_DEADLINE).stringValue()) return true
        val was = before.value(RegistryEntityFields.Task.SCHEDULED).stringValue() ?: return false
        val now = after.value(RegistryEntityFields.Task.SCHEDULED).stringValue() ?: return false
        return now > was
    }

    private fun SyncRecord.value(field: String): JsonValue = fields[field] ?: JsonValue.Null
}

/**
 * Task fade, from the shared core (`fade.rs`, ADR 0025 C1 #247), verified by
 * registry/conformance/task-fade.json. Never re-implement a rule here.
 */
object TaskFadeRules {
    val minOpacity: Double = RegistryRules.FADE_MIN_OPACITY

    fun isFaded(fadedAt: String?): Boolean = fadedAt != null

    fun rowOpacity(fill: Double?): Double = coreRowOpacity(fill)

    fun shouldFade(
        isOpen: Boolean,
        isHeading: Boolean,
        isDeleted: Boolean,
        isFaded: Boolean,
        deadline: String?,
        scheduled: String?,
        hasRecurrence: Boolean,
        isAgentTurn: Boolean,
        isAssignedToClaude: Boolean,
        touchedAt: Instant?,
        createdAt: Instant?,
        created: String?,
        now: Instant,
        today: String,
        isAwaitingHuman: Boolean = false,
        isProposal: Boolean = false,
        zone: ZoneId = ZoneId.systemDefault(),
    ): Boolean = coreShouldFade(
        input(
            isOpen, isHeading, isDeleted, isFaded, deadline, scheduled, hasRecurrence, isAgentTurn,
            isAssignedToClaude, isAwaitingHuman, false, isProposal, touchedAt, createdAt, created, now, today, zone,
        ),
    )

    fun fadeFill(
        isOpen: Boolean,
        isHeading: Boolean,
        isDeleted: Boolean,
        isFaded: Boolean,
        deadline: String?,
        scheduled: String?,
        hasRecurrence: Boolean,
        isAgentTurn: Boolean,
        isAssignedToClaude: Boolean,
        showsAgentCue: Boolean,
        touchedAt: Instant?,
        createdAt: Instant?,
        created: String?,
        now: Instant,
        today: String,
        isAwaitingHuman: Boolean = false,
        isProposal: Boolean = false,
        zone: ZoneId = ZoneId.systemDefault(),
    ): Double? = coreFadeFill(
        input(
            isOpen, isHeading, isDeleted, isFaded, deadline, scheduled, hasRecurrence, isAgentTurn,
            isAssignedToClaude, isAwaitingHuman, showsAgentCue, isProposal, touchedAt, createdAt, created, now, today,
            zone,
        ),
    )

    private fun input(
        isOpen: Boolean,
        isHeading: Boolean,
        isDeleted: Boolean,
        isFaded: Boolean,
        deadline: String?,
        scheduled: String?,
        hasRecurrence: Boolean,
        isAgentTurn: Boolean,
        isAssignedToClaude: Boolean,
        isAwaitingHuman: Boolean,
        showsAgentCue: Boolean,
        isProposal: Boolean,
        touchedAt: Instant?,
        createdAt: Instant?,
        created: String?,
        now: Instant,
        today: String,
        zone: ZoneId,
    ) = FadeInput(
        isOpen = isOpen,
        isHeading = isHeading,
        isDeleted = isDeleted,
        isFaded = isFaded,
        deadline = deadline,
        scheduled = scheduled,
        hasRecurrence = hasRecurrence,
        isAgentTurn = isAgentTurn,
        isAssignedToClaude = isAssignedToClaude,
        isAwaitingHuman = isAwaitingHuman,
        showsAgentCue = showsAgentCue,
        isProposal = isProposal,
        touchedAt = touchedAt?.toString(),
        createdAt = createdAt?.toString(),
        created = created,
        now = now.toString(),
        today = today,
        // A date-only `created` is midnight on the device's clock.
        utcOffsetSeconds = zone.rules.getOffset(now).totalSeconds,
    )
}
