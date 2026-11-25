package app.septena.android.ui

import app.septena.core.JsonValue
import app.septena.core.SyncRecord
import app.septena.core.TaskSnapshot
import app.septena.core.TaskViewMembership
import app.septena.core.TaskViewRules
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset

class TaskRowMetadataTest {
    private val today = LocalDate.of(2026, 11, 24)
    private val now = Instant.parse("2026-11-24T12:00:00Z")

    private fun taskRecord(
        id: String = "t1",
        extra: Map<String, JsonValue> = emptyMap(),
    ): SyncRecord = SyncRecord(
        entity = RegistryEntityNames.TASK,
        id = id,
        fields = mapOf(
            RegistryEntityFields.Task.TITLE to JsonValue.StringValue("Ship update"),
            RegistryEntityFields.Task.STATUS to JsonValue.StringValue(RegistryEntityEnums.TaskStatus.OPEN),
        ) + extra,
    )

    @Test
    fun dueTodayAndOverdueDeadlinesRenderRedWithoutFlag() {
        val dueTodayRecord = taskRecord(extra = mapOf(RegistryEntityFields.Task.DEADLINE to JsonValue.StringValue("2026-11-24")))
        val dueTodayItem = buildTaskListItem(
            record = dueTodayRecord,
            snapshot = TaskSnapshot.from(dueTodayRecord),
            membership = TaskViewMembership(
                isUnfiled = false,
                isInboxMember = false,
                inTriageBand = false,
                isOnToday = true,
                inTodayInbox = false,
                daysOnToday = 0,
                matchesView = emptyMap(),
                dueState = TaskViewRules.DUE_TODAY,
                deadlineRed = true,
            ),
            subtitle = null,
            catalog = TaskRowMetadataCatalog(),
            today = today,
            now = now,
            showTodayIndicator = false,
            languageTag = "en-US",
            zoneId = ZoneOffset.UTC,
        )
        assertEquals("Today", dueTodayItem.deadlineText)
        assertTrue(dueTodayItem.deadlineIsRed)
        assertFalse(dueTodayItem.deadlineShowsFlag)

        val overdueRecord = taskRecord(extra = mapOf(RegistryEntityFields.Task.DEADLINE to JsonValue.StringValue("2026-11-20")))
        val overdueItem = buildTaskListItem(
            record = overdueRecord,
            snapshot = TaskSnapshot.from(overdueRecord),
            membership = TaskViewMembership(
                isUnfiled = false,
                isInboxMember = false,
                inTriageBand = false,
                isOnToday = true,
                inTodayInbox = false,
                daysOnToday = 0,
                matchesView = emptyMap(),
                dueState = TaskViewRules.DUE_OVERDUE,
                deadlineRed = true,
            ),
            subtitle = null,
            catalog = TaskRowMetadataCatalog(),
            today = today,
            now = now,
            showTodayIndicator = false,
            languageTag = "en-US",
            zoneId = ZoneOffset.UTC,
        )
        assertEquals("Overdue", overdueItem.deadlineText)
        assertTrue(overdueItem.deadlineIsRed)
        assertFalse(overdueItem.deadlineShowsFlag)
    }

    @Test
    fun futureDeadlineShowsMutedFlagAndFullMetadata() {
        val record = taskRecord(
            extra = mapOf(
                RegistryEntityFields.Task.DEADLINE to JsonValue.StringValue("2026-11-28"),
                RegistryEntityFields.Task.STARRED to JsonValue.BooleanValue(true),
                RegistryEntityFields.Task.RECURRENCE_UNIT to JsonValue.StringValue(RegistryEntityEnums.RecurrenceUnit.WEEK),
                RegistryEntityFields.Task.NOTES to JsonValue.StringValue("Bring charger"),
                RegistryEntityFields.Task.SOURCE to JsonValue.StringValue(RegistryEntityEnums.TaskSource.MCP),
                RegistryEntityFields.Task.SOURCE_CLIENT to JsonValue.StringValue("Claude"),
                RegistryEntityFields.Task.TAGS to JsonValue.ArrayValue(listOf(JsonValue.StringValue("tag1"))),
                RegistryEntityFields.Task.REMINDER_AT to JsonValue.StringValue("2026-11-24T10:00:00Z"),
            ),
        )
        val item = buildTaskListItem(
            record = record,
            snapshot = TaskSnapshot.from(record),
            membership = TaskViewMembership(
                isUnfiled = false,
                isInboxMember = false,
                inTriageBand = false,
                isOnToday = false,
                inTodayInbox = false,
                daysOnToday = 0,
                matchesView = emptyMap(),
                dueState = null,
                deadlineRed = false,
            ),
            subtitle = "Work",
            catalog = TaskRowMetadataCatalog(
                checklistCounts = mapOf("t1" to (2 to 5)),
                tagNames = mapOf("tag1" to "Urgent"),
                attachmentTaskIds = setOf("t1"),
            ),
            today = today,
            now = now,
            showTodayIndicator = true,
            languageTag = "en-US",
            zoneId = ZoneOffset.UTC,
        )
        assertEquals("Nov 28", item.deadlineText)
        assertFalse(item.deadlineIsRed)
        assertTrue(item.deadlineShowsFlag)
        assertNull(item.scheduledText)
        assertEquals(2, item.checklistDone)
        assertEquals(5, item.checklistTotal)
        assertEquals(listOf("Urgent"), item.tagNames)
        assertTrue(item.isStarred)
        assertTrue(item.isRepeating)
        assertTrue(item.hasNotes)
        assertTrue(item.hasAttachments)
        assertEquals("Claude", item.agentName)
        assertTrue(item.reminderIsPastDue)
    }
}
