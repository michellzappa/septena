package app.septena.core

import app.septena.core.generated.RegistryDestinationIds
import app.septena.core.generated.RegistryEntityEnums

/** The Review group order (docs/REVIEW_SPEC.md §1 and §6, ADR 0053). */
class ReviewGroupTest {
    private val open = TaskSnapshot(id = "t1", title = "Ask Anna", status = RegistryEntityEnums.TaskStatus.OPEN)
    private val waiting = open.copy(waitingOn = "Anna", waitingSince = "2026-11-20")

    fun registryOrder() {
        val groups = (RegistryCatalog.destination(RegistryDestinationIds.REVIEW)?.fields?.get("groups") as? JsonValue.ArrayValue)
            ?.values.orEmpty()
            .mapNotNull { (it as? JsonValue.ObjectValue)?.fields?.get("id").stringValue() }
        assertEquals(ReviewGroupIds.ORDER, groups, "Review groups in registry/destinations.json")
    }

    fun waitingOrder() {
        // A conversation group comes first.
        assertEquals(ReviewGroupIds.QUESTIONS, TaskViewRules.reviewGroup(waiting, ReviewGroupIds.QUESTIONS, ReviewGroupIds.WORKING))
        assertEquals(ReviewGroupIds.FINISHED, TaskViewRules.reviewGroup(waiting, ReviewGroupIds.FINISHED, null))
        // Then the wait, before the agent stage and Faded.
        assertEquals(ReviewGroupIds.WAITING, TaskViewRules.reviewGroup(waiting, null, ReviewGroupIds.WORKING))
        assertEquals(ReviewGroupIds.WAITING, TaskViewRules.reviewGroup(waiting.copy(fadedAt = "2026-11-25T00:00:00Z"), null, null))
        // A blank name is no wait.
        assertEquals(ReviewGroupIds.WORKING, TaskViewRules.reviewGroup(waiting.copy(waitingOn = "  "), null, ReviewGroupIds.WORKING))
        assertEquals(null, TaskViewRules.reviewGroup(open, null, null))
        // A closed task is not in Review.
        assertEquals(null, TaskViewRules.reviewGroup(waiting.copy(status = RegistryEntityEnums.TaskStatus.DONE), null, null))
        // Waiting is not in the badge.
        assertTrue(ReviewGroupIds.WAITING !in ReviewGroupIds.BADGE, "Waiting counts in the badge")
    }

    /** Tracked (ADR 0065): the core's group comes first, before a wait, and it is not in the badge. */
    fun trackedOrder() {
        assertEquals(ReviewGroupIds.TRACKED, TaskViewRules.reviewGroup(waiting, ReviewGroupIds.TRACKED, null))
        assertEquals(ReviewGroupIds.TRACKED, TaskViewRules.reviewGroup(open.copy(fadedAt = "2026-11-25T00:00:00Z"), ReviewGroupIds.TRACKED, null))
        assertEquals(null, TaskViewRules.reviewGroup(open.copy(status = RegistryEntityEnums.TaskStatus.DONE), ReviewGroupIds.TRACKED, null))
        assertTrue(ReviewGroupIds.TRACKED !in ReviewGroupIds.BADGE, "Tracked counts in the badge")
        // An open task with no conversation end state is never tracked; the core is not asked.
        assertEquals(false, TaskViewRules.isTracked(open, java.time.LocalDate.parse("2026-11-28"), java.time.Instant.parse("2026-11-28T12:00:00Z")))
    }
}
