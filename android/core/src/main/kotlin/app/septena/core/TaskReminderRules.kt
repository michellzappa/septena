package app.septena.core

import app.septena.sharedcore.ReminderArmInput
import app.septena.sharedcore.shiftReminderForRecurrence
import app.septena.sharedcore.shiftReminderOnReschedule
import app.septena.sharedcore.shouldArmReminder

/**
 * Timed reminders, from the shared core (`reminders.rs`, ADR 0025 C1 #247):
 * the same rules Apple and the backend run.
 */
object TaskReminderRules {
    fun shiftForRecurrence(
        sourceReminderAt: String?,
        sourceScheduled: String?,
        nextScheduled: String?,
    ): String? = shiftReminderForRecurrence(sourceReminderAt, sourceScheduled, nextScheduled)

    fun shiftOnReschedule(reminderAt: String?, oldScheduled: String?, newScheduled: String?): String? =
        shiftReminderOnReschedule(reminderAt, oldScheduled, newScheduled)

    fun shouldArm(
        status: String,
        isDeleted: Boolean,
        isHeading: Boolean,
        isUnratifiedProposal: Boolean,
        reminderAt: String?,
        reminderDismissedAt: String?,
    ): Boolean = shouldArmReminder(
        ReminderArmInput(status, isDeleted, isHeading, isUnratifiedProposal, reminderAt, reminderDismissedAt),
    )
}
