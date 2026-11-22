package app.septena.core

import app.septena.core.generated.RegistryRules
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/** Pure fade calculation shared with registry/conformance/task-fade.json. */
object TaskFadeRules {
    private val window = Duration.ofDays(RegistryRules.FADE_WINDOW_DAYS)
    private val grace = Duration.ofDays(RegistryRules.FADE_GRACE_DAYS)
    val minOpacity: Double = RegistryRules.FADE_MIN_OPACITY

    fun rowOpacity(fill: Double?): Double {
        if (fill == null || !fill.isFinite() || fill <= 0.0) return 1.0
        return 1.0 - minOf(1.0, fill) * (1.0 - minOpacity)
    }

    fun isEligible(
        isOpen: Boolean,
        isHeading: Boolean,
        isDeleted: Boolean,
        isFaded: Boolean,
        deadline: String?,
        scheduled: String?,
        hasRecurrence: Boolean,
        isAgentTurn: Boolean,
        isAssignedToClaude: Boolean,
        isAwaitingHuman: Boolean = false,
        today: String,
    ): Boolean {
        if (!isOpen || isHeading || isDeleted || isFaded) return false
        if (!deadline.isNullOrEmpty()) return false
        if (!scheduled.isNullOrEmpty() && scheduled.take(10) >= today) return false
        return !hasRecurrence && !isAgentTurn && !isAssignedToClaude && !isAwaitingHuman
    }

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
        zone: ZoneId = ZoneId.systemDefault(),
    ): Boolean {
        if (!isEligible(
                isOpen, isHeading, isDeleted, isFaded, deadline, scheduled, hasRecurrence,
                isAgentTurn, isAssignedToClaude, isAwaitingHuman, today,
            )
        ) return false
        val clock = clockDate(touchedAt, createdAt, created, zone) ?: return false
        return Duration.between(clock, now) >= window
    }

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
        zone: ZoneId = ZoneId.systemDefault(),
    ): Double? {
        if (showsAgentCue || !isEligible(
                isOpen, isHeading, isDeleted, isFaded, deadline, scheduled, hasRecurrence,
                isAgentTurn, isAssignedToClaude, isAwaitingHuman, today,
            )
        ) return null
        val clock = clockDate(touchedAt, createdAt, created, zone) ?: return null
        val elapsed = Duration.between(clock, now)
        if (elapsed < grace) return null
        return minOf(1.0, elapsed.toMillis().toDouble() / window.toMillis().toDouble())
    }

    private fun clockDate(
        touchedAt: Instant?,
        createdAt: Instant?,
        created: String?,
        zone: ZoneId,
    ): Instant? = touchedAt ?: createdAt ?: created
        ?.let { runCatching { LocalDate.parse(it.take(10)).atStartOfDay(zone).toInstant() }.getOrNull() }
}
