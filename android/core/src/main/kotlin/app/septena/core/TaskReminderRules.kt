package app.septena.core

import app.septena.core.generated.RegistryEntityEnums
import java.time.LocalDate

/** Timed reminder behavior shared with Apple and backend reminder rules. */
object TaskReminderRules {
    fun shiftForRecurrence(
        sourceReminderAt: String?,
        sourceScheduled: String?,
        nextScheduled: String?,
    ): String? {
        val sourceReminder = sourceReminderAt ?: return null
        val nextDay = nextScheduled ?: return null
        if (sourceReminder.length <= 10 || sourceReminder.getOrNull(10) != 'T') return null
        val nextDate = parseDay(nextDay) ?: return null
        val reminderDay = parseDay(sourceReminder.take(10))
        val scheduledDay = sourceScheduled?.let(::parseDay)
        val offsetDays = if (reminderDay != null && scheduledDay != null) {
            (reminderDay.toEpochDay() - scheduledDay.toEpochDay()).toInt()
        } else {
            0
        }
        return nextDate.plusDays(offsetDays.toLong()).toString() + sourceReminder.drop(10)
    }

    fun shiftOnReschedule(reminderAt: String?, oldScheduled: String?, newScheduled: String?): String? {
        val reminder = reminderAt ?: return null
        if (oldScheduled.isNullOrEmpty() || newScheduled.isNullOrEmpty() ||
            reminder.length <= 10 || reminder.getOrNull(10) != 'T'
        ) return reminder
        val reminderDay = reminder.take(10)
        if (reminderDay != oldScheduled.take(10)) return reminder
        return newScheduled.take(10) + reminder.drop(10)
    }

    fun shouldArm(
        status: String,
        isDeleted: Boolean,
        isHeading: Boolean,
        isUnratifiedProposal: Boolean,
        reminderAt: String?,
        reminderDismissedAt: String?,
    ): Boolean = status == RegistryEntityEnums.TaskStatus.OPEN &&
        !isDeleted && !isHeading && !isUnratifiedProposal &&
        !reminderAt.isNullOrEmpty() && reminderDismissedAt == null

    private fun parseDay(value: String): LocalDate? =
        runCatching { LocalDate.parse(value.take(10)) }.getOrNull()
}
