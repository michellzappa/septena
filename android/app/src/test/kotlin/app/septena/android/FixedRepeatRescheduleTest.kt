package app.septena.android

import app.septena.core.JsonValue
import app.septena.core.TaskMutator
import app.septena.core.generated.RegistryEntityFields
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FixedRepeatRescheduleTest {

    @Test
    fun needsFixedRepeatPromptOnlyForFixedRepeatsMovingToAnotherDay() {
        val fixedWeekly = mapOf(
            RegistryEntityFields.Task.SCHEDULED to JsonValue.StringValue("2026-11-30"),
            RegistryEntityFields.Task.RECURRENCE_UNIT to JsonValue.StringValue("week"),
            RegistryEntityFields.Task.RECURRENCE_AFTER_COMPLETION to JsonValue.BooleanValue(false),
        )
        assertTrue(TaskMutator.needsFixedRepeatReschedulePrompt(fixedWeekly, "2026-12-02"))
        assertFalse(TaskMutator.needsFixedRepeatReschedulePrompt(fixedWeekly, "2026-11-30"))
        assertFalse(TaskMutator.needsFixedRepeatReschedulePrompt(fixedWeekly, null))

        val afterCompletion = fixedWeekly + (RegistryEntityFields.Task.RECURRENCE_AFTER_COMPLETION to JsonValue.BooleanValue(true))
        assertFalse(TaskMutator.needsFixedRepeatReschedulePrompt(afterCompletion, "2026-12-02"))

        val nonRepeating = mapOf(RegistryEntityFields.Task.SCHEDULED to JsonValue.StringValue("2026-11-30"))
        assertFalse(TaskMutator.needsFixedRepeatReschedulePrompt(nonRepeating, "2026-12-02"))
    }
}
