package app.septena.core

import app.septena.core.generated.RegistryRules
import app.septena.sharedcore.FadeInput
import java.time.Instant
import java.time.ZoneId
import app.septena.sharedcore.fadeFill as coreFadeFill
import app.septena.sharedcore.rowOpacity as coreRowOpacity
import app.septena.sharedcore.shouldFade as coreShouldFade

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
