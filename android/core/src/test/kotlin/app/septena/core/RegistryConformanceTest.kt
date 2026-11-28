package app.septena.core

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlin.math.abs

class RegistryConformanceTest {
    fun recurrenceVectors() {
        val fixture = ConformanceFixtures.load("recurrence.json")
        for (caseValue in fixture.arrayAt("nextScheduledDate")) {
            val case = caseValue.asObject()
            val input = case.objectAt("input")
            val ordinal = (input.fields["ordinalWeekday"] as? JsonValue.ObjectValue)?.let {
                OrdinalWeekday(it.requiredLong("ordinal").toInt(), it.requiredLong("weekday").toInt())
            }
            val rule = RecurrenceRule(
                unit = input.requiredString("unit"),
                interval = input.longAt("interval")?.toInt() ?: 1,
                afterCompletion = input.booleanAt("afterCompletion") ?: true,
                weekdays = input.integerListAt("weekdays"),
                monthDay = input.longAt("monthDay")?.toInt(),
                ordinalWeekday = ordinal,
            )
            assertEquals(
                case.fields["expected"].stringValue(),
                RecurrenceRules.nextScheduledDate(
                    completedOn = input.requiredString("completedOn"),
                    scheduled = input.stringAt("scheduled"),
                    logicalScheduled = input.stringAt("logicalScheduled"),
                    rule = rule,
                ),
                case.requiredString("name"),
            )
        }

        for (caseValue in fixture.arrayAt("occurrenceID")) {
            val case = caseValue.asObject()
            assertEquals(
                case.requiredString("expected"),
                RecurrenceRules.occurrenceId(case.requiredString("sourceTaskID"), case.requiredString("scheduled")),
                case.requiredString("sourceTaskID"),
            )
        }
    }

    fun reminderVectors() {
        val fixture = ConformanceFixtures.load("reminders.json")
        for (caseValue in fixture.arrayAt("shiftReminderForRecurrence")) {
            val case = caseValue.asObject()
            val input = case.objectAt("input")
            assertEquals(
                case.fields["expected"].stringValue(),
                TaskReminderRules.shiftForRecurrence(
                    input.stringAt("sourceReminderAt"),
                    input.stringAt("sourceScheduled"),
                    input.stringAt("nextScheduled"),
                ),
                case.requiredString("name"),
            )
        }
        for (caseValue in fixture.arrayAt("shiftReminderOnReschedule")) {
            val case = caseValue.asObject()
            val input = case.objectAt("input")
            assertEquals(
                case.fields["expected"].stringValue(),
                TaskReminderRules.shiftOnReschedule(
                    input.stringAt("reminderAt"),
                    input.stringAt("oldScheduled"),
                    input.stringAt("newScheduled"),
                ),
                case.requiredString("name"),
            )
        }
        for (caseValue in fixture.arrayAt("shouldArmReminder")) {
            val case = caseValue.asObject()
            val input = case.objectAt("input")
            assertEquals(
                case.fields["expected"]?.booleanValue() ?: error("Expected reminder boolean"),
                TaskReminderRules.shouldArm(
                    status = input.requiredString("status"),
                    isDeleted = input.requiredBoolean("isDeleted"),
                    isHeading = input.requiredBoolean("isHeading"),
                    isUnratifiedProposal = input.requiredBoolean("isUnratifiedProposal"),
                    reminderAt = input.stringAt("reminderAt"),
                    reminderDismissedAt = input.stringAt("reminderDismissedAt"),
                ),
                case.requiredString("name"),
            )
        }
    }

    fun taskFadeVectors() {
        val fixture = ConformanceFixtures.load("task-fade.json")
        for (caseValue in fixture.arrayAt("rowOpacity")) {
            val case = caseValue.asObject()
            val fill = (case.fields["fill"] as? JsonValue.DecimalValue)?.value
                ?: (case.fields["fill"] as? JsonValue.IntegerValue)?.value?.toDouble()
            val actual = TaskFadeRules.rowOpacity(fill)
            val expected = case.fields["expected"]?.let { value ->
                when (value) {
                    is JsonValue.DecimalValue -> value.value
                    is JsonValue.IntegerValue -> value.value.toDouble()
                    else -> error("Expected numeric opacity")
                }
            } ?: error("Expected opacity")
            assertTrue(abs(actual - expected) < 0.0001, case.requiredString("name"))
        }
        for (caseValue in fixture.arrayAt("shouldFade")) {
            val case = caseValue.asObject()
            val input = case.objectAt("input")
            val actual = TaskFadeRules.shouldFade(
                isOpen = input.requiredBoolean("isOpen"),
                isHeading = input.requiredBoolean("isHeading"),
                isDeleted = input.requiredBoolean("isDeleted"),
                isFaded = input.requiredBoolean("isFaded"),
                deadline = input.stringAt("deadline"),
                scheduled = input.stringAt("scheduled"),
                hasRecurrence = input.requiredBoolean("hasRecurrence"),
                isAgentTurn = input.requiredBoolean("isAgentTurn"),
                isAssignedToClaude = input.requiredBoolean("isAssignedToClaude"),
                touchedAt = input.stringAt("touchedAt")?.let(Instant::parse),
                createdAt = input.stringAt("createdAt")?.let(Instant::parse),
                created = input.stringAt("created"),
                now = Instant.parse(input.requiredString("now")),
                today = input.requiredString("today"),
                isAwaitingHuman = input.booleanAt("isAwaitingHuman") ?: false,
                isProposal = input.booleanAt("isProposal") ?: false,
                zone = ZoneId.of("UTC"),
                endState = input.stringAt("endState"),
            )
            assertEquals(
                case.fields["expected"]?.booleanValue() ?: error("Expected fade boolean"),
                actual,
                case.requiredString("name"),
            )
        }
    }

    fun taskViewVectors() {
        val fixture = ConformanceFixtures.load("task-views.json")
        val today = LocalDate.parse(fixture.requiredString("today"))
        val now = Instant.parse(fixture.requiredString("nowIso"))
        for (caseValue in fixture.arrayAt("cases")) {
            val case = caseValue.asObject()
            val task = case.objectAt("task")
            val id = task.requiredString("id")
            val record = SyncRecord(
                entity = "task",
                id = id,
                fields = task.without("id", "deletedAt", "endState"),
                deletedAt = task.stringAt("deletedAt"),
            )
            // `endState` is the conversation's (ADR 0065), not a task field.
            val snapshot = TaskSnapshot.from(record, endState = task.stringAt("endState"))
            val actual = TaskViewRules.membership(snapshot, today, now)
            val expected = case.objectAt("expected")
            assertEquals(expected.requiredBoolean("isUnfiled"), actual.isUnfiled, case.requiredString("name"))
            assertEquals(expected.requiredBoolean("isInboxMember"), actual.isInboxMember, case.requiredString("name"))
            assertEquals(expected.requiredBoolean("inTriageBand"), actual.inTriageBand, case.requiredString("name"))
            assertEquals(expected.requiredBoolean("isOnToday"), actual.isOnToday, case.requiredString("name"))
            assertEquals(expected.requiredBoolean("inInbox"), actual.inTodayInbox, case.requiredString("name"))
            assertEquals(expected.requiredLong("daysOnToday").toInt(), actual.daysOnToday, case.requiredString("name"))
            val expectedViews = expected.objectAt("matchesView").fields.mapValues { (_, value) ->
                value.booleanValue() ?: error("Expected view match boolean")
            }
            assertEquals(expectedViews, actual.matchesView, case.requiredString("name"))
            assertEquals(expected.requiredBoolean("isTracked"), actual.isTracked, case.requiredString("name"))
            assertEquals(
                expected.requiredBoolean("isTracked"),
                TaskViewRules.isTracked(snapshot, today, now),
                case.requiredString("name"),
            )
        }
    }

    fun conversationVectors() {
        val fixture = ConformanceFixtures.load("convo-derived.json")
        val now = Instant.parse("2026-11-21T12:00:00Z")
        for (caseValue in fixture.arrayAt("cases")) {
            val case = caseValue.asObject()
            val source = case.objectAt("convo")
            val turns = source.arrayAt("thread").map { turnValue ->
                val turn = turnValue.asObject()
                SyncTurn(
                    taskId = "task-0001",
                    sequence = turn.requiredLong("seq"),
                    fields = turn.without("seq"),
                )
            }
            val conversation = TaskConversation.from(
                SyncRecord(
                    entity = "convo",
                    id = "task-0001",
                    fields = source.without("thread"),
                ),
                turns,
            )
            val actual = ConversationRules.derive(conversation, now)
            val expected = case.objectAt("expected")
            assertEquals(expected.requiredString("stage"), actual.stage, case.requiredString("name"))
            assertEquals(expected.stringAt("badge"), actual.badge, case.requiredString("name"))
            assertEquals(expected.requiredBoolean("pendingReasoning"), actual.pendingReasoning, case.requiredString("name"))
        }
        // The core's Review group through the Kotlin wrapper (Tracked: ADR 0065). A claim needs a
        // claimant here (`claimedBy`), which the vectors leave out, so claim cases stay with the
        // core's own runner.
        val stateNow = Instant.parse("2026-11-20T12:00:00Z")
        for (caseValue in fixture.arrayAt("conversationState")) {
            val case = caseValue.asObject()
            val source = case.objectAt("convo")
            if (source.stringAt("claimUntil") != null) continue
            val turns = source.arrayAt("thread").map { turnValue ->
                val turn = turnValue.asObject()
                SyncTurn(taskId = "task-0001", sequence = turn.requiredLong("seq"), fields = turn.without("seq"))
            }
            val conversation = TaskConversation.from(
                SyncRecord(entity = "convo", id = "task-0001", fields = source.without("thread")),
                turns,
            )
            val actual = conversation.evaluate(stateNow)
            val expected = case.objectAt("expected")
            assertEquals(expected.stringAt("reviewGroup"), actual.reviewGroup, case.requiredString("name"))
            assertEquals(expected.requiredBoolean("needsHumanReview"), actual.needsHumanReview, case.requiredString("name"))
        }
    }

    fun taskPageBlocksVectors() {
        val inlineKinds = RegistryCatalog.taskPageBlocks(TaskPageDepths.INLINE).map(TaskPageBlock::kind)
        assertEquals(
            listOf(
                TaskPageBlockKinds.HEADER,
                TaskPageBlockKinds.NOTES,
                TaskPageBlockKinds.ATTRIBUTES,
                TaskPageBlockKinds.CHECKLIST,
                TaskPageBlockKinds.ATTACHMENTS,
                TaskPageBlockKinds.REFERENCES,
            ),
            inlineKinds,
            "inline task page blocks",
        )

        val pageKinds = RegistryCatalog.taskPageBlocks(TaskPageDepths.PAGE).map(TaskPageBlock::kind)
        assertEquals(
            listOf(
                TaskPageBlockKinds.HEADER,
                TaskPageBlockKinds.NOTES,
                TaskPageBlockKinds.ATTRIBUTES,
                TaskPageBlockKinds.CHECKLIST,
                TaskPageBlockKinds.ATTACHMENTS,
                TaskPageBlockKinds.REFERENCES,
                TaskPageBlockKinds.CONVERSATION,
                TaskPageBlockKinds.PROVENANCE,
                TaskPageBlockKinds.HISTORY,
            ),
            pageKinds,
            "full task page blocks",
        )

        val reviewKinds = RegistryCatalog.taskPageBlocks(TaskPageDepths.REVIEW).map(TaskPageBlock::kind)
        assertEquals(
            listOf(
                TaskPageBlockKinds.HEADER,
                TaskPageBlockKinds.NOTES,
                TaskPageBlockKinds.CONVERSATION,
                TaskPageBlockKinds.PROVENANCE,
            ),
            reviewKinds,
            "review task page blocks",
        )

        assertTrue(RegistryCatalog.dateBoardRows("when").isNotEmpty(), "when date board rows")
        assertTrue(RegistryCatalog.dateBoardRows("deadline").isNotEmpty(), "deadline date board rows")
    }
}
