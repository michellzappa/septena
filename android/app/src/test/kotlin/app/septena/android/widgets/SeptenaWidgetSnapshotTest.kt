package app.septena.android.widgets

import app.septena.core.DayClock
import app.septena.core.JsonValue
import app.septena.core.SyncOperation
import app.septena.core.SyncRecord
import app.septena.core.SyncTurn
import app.septena.core.TaskSnapshot
import app.septena.core.TaskStore
import app.septena.core.TaskViewMembership
import app.septena.core.TaskViewRules
import app.septena.core.generated.RegistryDestinationIds
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.LocalDate

class SeptenaWidgetSnapshotTest {
    private val fixedClock = object : DayClock {
        override fun now(): Instant = Instant.parse("2026-11-25T10:00:00Z")
        override fun today(instant: Instant): LocalDate = LocalDate.of(2026, 11, 25)
    }

    private fun fakeMembership(snap: TaskSnapshot, today: LocalDate, @Suppress("UNUSED_PARAMETER") now: Instant): TaskViewMembership {
        val sched = snap.scheduled?.let { runCatching { LocalDate.parse(it.take(10)) }.getOrNull() }
        val due = snap.deadline?.let { runCatching { LocalDate.parse(it.take(10)) }.getOrNull() }
        val isToday = snap.today || (sched != null && !sched.isAfter(today))
        val isUpcoming = sched != null && sched.isAfter(today)
        val dueState = when {
            due != null && due.isBefore(today) -> TaskViewRules.DUE_OVERDUE
            due != null && due == today -> TaskViewRules.DUE_TODAY
            else -> null
        }
        return TaskViewMembership(
            isUnfiled = snap.area == null && snap.project == null,
            isInboxMember = false,
            inTriageBand = false,
            isOnToday = isToday,
            inTodayInbox = isToday && snap.area == null && snap.project == null,
            daysOnToday = 0,
            matchesView = mapOf(
                RegistryDestinationIds.TODAY to isToday,
                RegistryDestinationIds.UPCOMING to isUpcoming,
            ),
            dueState = dueState,
            deadlineRed = dueState != null,
        )
    }

    private fun storeWith(records: List<SyncRecord>): TaskStore = object : TaskStore {
        override suspend fun records(entity: String): List<SyncRecord> = records.filter { it.entity == entity }
        override suspend fun record(entity: String, id: String): SyncRecord? = records.firstOrNull { it.entity == entity && it.id == id }
        override suspend fun turns(taskId: String): List<SyncTurn> = emptyList()
        override suspend fun syncCursor(): Long = 0L
        override suspend fun outbox(): List<SyncOperation> = emptyList()
        override suspend fun writeLocalAndEnqueue(record: SyncRecord, operation: SyncOperation) = Unit
        override suspend fun appendLocalTurnAndEnqueue(turn: SyncTurn, operation: SyncOperation) = Unit
        override suspend fun applyPull(
            cursor: Long,
            records: List<SyncRecord>,
            turns: List<SyncTurn>,
            ackedClientOpIds: Set<String>,
        ) = Unit
        override suspend fun dropOutbox(clientOpIds: Set<String>) = Unit
        override suspend fun resetAll() = Unit
    }

    private fun openTask(id: String, title: String, extra: Map<String, JsonValue> = emptyMap()): SyncRecord = SyncRecord(
        entity = RegistryEntityNames.TASK,
        id = id,
        fields = mapOf(
            RegistryEntityFields.Task.TITLE to JsonValue.StringValue(title),
            RegistryEntityFields.Task.STATUS to JsonValue.StringValue(RegistryEntityEnums.TaskStatus.OPEN),
        ) + extra,
    )

    @Test
    fun todayWidgetRanksInboxAndTodayOrderAndShowsTimeSlot() = runBlocking {
        val store = storeWith(
            listOf(
                openTask(
                    "t2",
                    "Second task",
                    mapOf(
                        RegistryEntityFields.Task.TODAY to JsonValue.BooleanValue(true),
                        RegistryEntityFields.Task.TODAY_POSITION to JsonValue.DecimalValue(2.0),
                        RegistryEntityFields.Task.AREA to JsonValue.StringValue("a1"),
                    ),
                ),
                openTask(
                    "t1",
                    "Morning standup",
                    mapOf(
                        RegistryEntityFields.Task.TODAY to JsonValue.BooleanValue(true),
                        RegistryEntityFields.Task.TODAY_POSITION to JsonValue.DecimalValue(1.0),
                        RegistryEntityFields.Task.START_TIME to JsonValue.StringValue("09:30"),
                        RegistryEntityFields.Task.DURATION_MINUTES to JsonValue.IntegerValue(30),
                        RegistryEntityFields.Task.AREA to JsonValue.StringValue("a1"),
                    ),
                ),
                openTask(
                    "t-overdue",
                    "Pay rent",
                    mapOf(
                        RegistryEntityFields.Task.DEADLINE to JsonValue.StringValue("2026-11-20"),
                        RegistryEntityFields.Task.TODAY to JsonValue.BooleanValue(true),
                        RegistryEntityFields.Task.TODAY_POSITION to JsonValue.DecimalValue(3.0),
                        RegistryEntityFields.Task.AREA to JsonValue.StringValue("a1"),
                    ),
                ),
                openTask(
                    "t-future",
                    "Tomorrow task",
                    mapOf(
                        RegistryEntityFields.Task.SCHEDULED to JsonValue.StringValue("2026-11-26"),
                    ),
                ),
            ),
        )
        val snap = SeptenaWidgetLoader.loadToday(store, fixedClock, "en-US", maxRows = 2, membershipFor = ::fakeMembership)
        assertEquals(RegistryDestinationIds.TODAY, snap.destinationId)
        assertEquals(3, snap.totalCount)
        assertEquals(2, snap.rows.size)
        assertEquals(1, snap.overflowCount)
        assertEquals("t1", snap.rows[0].id)
        assertEquals("09:30–10:00", snap.rows[0].trailingMeta)
        assertEquals("t2", snap.rows[1].id)
    }

    @Test
    fun upcomingWidgetOrdersByScheduledDateAndTime() = runBlocking {
        val store = storeWith(
            listOf(
                openTask(
                    "u2",
                    "Next week review",
                    mapOf(RegistryEntityFields.Task.SCHEDULED to JsonValue.StringValue("2026-12-02")),
                ),
                openTask(
                    "u1",
                    "Dentist",
                    mapOf(
                        RegistryEntityFields.Task.SCHEDULED to JsonValue.StringValue("2026-11-26"),
                        RegistryEntityFields.Task.START_TIME to JsonValue.StringValue("14:00"),
                    ),
                ),
                openTask(
                    "today-only",
                    "Today task",
                    mapOf(RegistryEntityFields.Task.TODAY to JsonValue.BooleanValue(true)),
                ),
            ),
        )
        val snap = SeptenaWidgetLoader.loadUpcoming(store, fixedClock, "en-US", membershipFor = ::fakeMembership)
        assertEquals(RegistryDestinationIds.UPCOMING, snap.destinationId)
        assertEquals(2, snap.totalCount)
        assertEquals("u1", snap.rows[0].id)
        assertTrue(snap.rows[0].trailingMeta.orEmpty().contains("14:00"))
        assertEquals("u2", snap.rows[1].id)
    }
}
