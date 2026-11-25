package app.septena.android.ui

import app.septena.core.DateBoardRowKinds
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.SyncRecord
import app.septena.core.TaskFadeRules
import app.septena.core.TaskProvenance
import app.septena.core.TaskSnapshot
import app.septena.core.TaskStore
import app.septena.core.TaskTimeSlot
import app.septena.core.TaskViewMembership
import app.septena.core.TaskViewRules
import app.septena.core.booleanValue
import app.septena.core.generated.RegistryDestinationIds
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames as EntityNames
import app.septena.core.generated.RegistryTaskAttributeIds
import app.septena.core.stringValue
import app.septena.ui.SeptenaIconKind
import app.septena.ui.TaskListItem
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

/** Preloaded per-task secondary metadata (checklist counts, tag names, attachments) for one list render. */
internal data class TaskRowMetadataCatalog(
    val checklistCounts: Map<String, Pair<Int, Int>> = emptyMap(),
    val tagNames: Map<String, String> = emptyMap(),
    val attachmentTaskIds: Set<String> = emptySet(),
) {
    companion object {
        suspend fun load(store: TaskStore): TaskRowMetadataCatalog {
            val checklist = mutableMapOf<String, Pair<Int, Int>>()
            for (row in store.records(EntityNames.CHECKLIST_ITEM)) {
                if (row.deletedAt != null) continue
                val taskId = row.fields[RegistryEntityFields.ChecklistItem.TASK_ID].stringValue() ?: continue
                val checked = row.fields[RegistryEntityFields.ChecklistItem.CHECKED].booleanValue() == true
                val prev = checklist[taskId] ?: (0 to 0)
                checklist[taskId] = (prev.first + if (checked) 1 else 0) to (prev.second + 1)
            }
            val tags = buildMap {
                for (row in store.records(EntityNames.TAG)) {
                    if (row.deletedAt != null) continue
                    val name = row.fields[RegistryEntityFields.Tag.NAME].stringValue()?.takeIf(String::isNotBlank)
                        ?: continue
                    put(row.id, name)
                }
            }
            val attachments = buildSet {
                for (row in store.records(EntityNames.ATTACHMENT)) {
                    if (row.deletedAt != null) continue
                    val taskId = row.fields[RegistryEntityFields.Attachment.TASK_ID].stringValue() ?: continue
                    add(taskId)
                }
            }
            return TaskRowMetadataCatalog(
                checklistCounts = checklist,
                tagNames = tags,
                attachmentTaskIds = attachments,
            )
        }
    }
}

/** Builds a rich iOS-parity [TaskListItem] using core [TaskViewMembership] rules and store metadata. */
internal fun buildTaskListItem(
    record: SyncRecord,
    snapshot: TaskSnapshot,
    membership: TaskViewMembership,
    subtitle: String?,
    catalog: TaskRowMetadataCatalog,
    today: LocalDate,
    now: Instant,
    showTodayIndicator: Boolean,
    isLogbook: Boolean = false,
    languageTag: String = Locale.getDefault().toLanguageTag(),
    zoneId: ZoneId = ZoneId.systemDefault(),
): TaskListItem {
    val isOpen = snapshot.status == RegistryEntityEnums.TaskStatus.OPEN
    val isDeleted = snapshot.deletedAt != null
    val isFaded = TaskFadeRules.isFaded(snapshot.fadedAt)

    val todayLabel = RegistryCatalog.destinationTitle(RegistryDestinationIds.TODAY, languageTag)
        ?.takeIf(String::isNotBlank).orEmpty()
    val tomorrowLabel = RegistryCatalog.dateBoardRows(
        RegistryTaskAttributeIds.WHEN,
        languageTag = languageTag,
    ).firstOrNull { it.kind == DateBoardRowKinds.TOMORROW }?.label?.takeIf(String::isNotBlank).orEmpty()
    val overdueLabel = RegistryCatalog.taskDateBoardOverdueLabel(languageTag)

    // Deadline / Scheduled / Completed date — matches iOS `TaskRow.trailingDate`.
    var deadlineText: String? = null
    var deadlineIsRed = false
    var deadlineShowsFlag = false
    var scheduledText: String? = null
    var completedDateText: String? = null

    if (isLogbook || snapshot.status != RegistryEntityEnums.TaskStatus.OPEN) {
        val completedAt = record.fields[RegistryEntityFields.Task.COMPLETED_AT].stringValue()
        completedDateText = completedAt?.let { formatShortInstantDay(it, today, todayLabel, tomorrowLabel, languageTag, zoneId) }
    } else if (!isDeleted) {
        val dueDay = snapshot.deadline?.let { parseIsoDay(it) }
        if (dueDay != null) {
            when (membership.dueState) {
                TaskViewRules.DUE_TODAY -> {
                    deadlineText = todayLabel
                    deadlineIsRed = membership.deadlineRed
                    deadlineShowsFlag = false
                }
                TaskViewRules.DUE_OVERDUE -> {
                    deadlineText = overdueLabel
                    deadlineIsRed = membership.deadlineRed
                    deadlineShowsFlag = false
                }
                else -> {
                    deadlineText = formatShortLocalDay(dueDay, today, todayLabel, tomorrowLabel, languageTag)
                    deadlineIsRed = false
                    deadlineShowsFlag = true
                }
            }
        } else {
            val schedDay = snapshot.scheduled?.let { parseIsoDay(it) }
            if (schedDay != null) {
                val coveredByTodayPill = showTodayIndicator && membership.isOnToday && !isFaded && !schedDay.isAfter(today)
                if (!coveredByTodayPill && (showTodayIndicator || schedDay.isAfter(today))) {
                    scheduledText = formatShortLocalDay(schedDay, today, todayLabel, tomorrowLabel, languageTag)
                }
            }
        }
    }

    // Checklist progress (`done/total`).
    val (checklistDone, checklistTotal) = catalog.checklistCounts[record.id] ?: (0 to 0)

    // Resolved live tags.
    val tagIds = (record.fields[RegistryEntityFields.Task.TAGS] as? JsonValue.ArrayValue)
        ?.values?.mapNotNull { it.stringValue() }.orEmpty()
    val tagNames = tagIds.mapNotNull(catalog.tagNames::get)

    // Active timed reminder badge (only for open, non-deleted, non-dismissed tasks).
    var reminderText: String? = null
    var reminderIsPastDue = false
    if (isOpen && !isDeleted) {
        val reminderAt = record.fields[RegistryEntityFields.Task.REMINDER_AT].stringValue()
        val dismissedAt = record.fields[RegistryEntityFields.Task.REMINDER_DISMISSED_AT].stringValue()
        if (reminderAt != null && dismissedAt == null) {
            val snoozed = record.fields[RegistryEntityFields.Task.REMINDER_SNOOZED_UNTIL].stringValue()
            val effectiveRaw = snoozed ?: reminderAt
            val triggerInstant = runCatching { Instant.parse(effectiveRaw) }.getOrNull()
            if (triggerInstant != null) {
                reminderText = formatCompactReminder(triggerInstant, today, languageTag, zoneId)
                reminderIsPastDue = triggerInstant.isBefore(now)
            }
        }
    }

    val hasNotes = !record.fields[RegistryEntityFields.Task.NOTES].stringValue().isNullOrBlank()
    val hasAttachments = record.id in catalog.attachmentTaskIds
    val agent = if (TaskProvenance.isAgentAuthored(snapshot.source)) {
        TaskProvenance.addedByName(snapshot.source, snapshot.sourceClient)
    } else {
        null
    }

    val timeSlotText = if (isOpen && !isDeleted) {
        TaskTimeSlot.format(snapshot.startTime, snapshot.durationMinutes)
    } else {
        null
    }

    return TaskListItem(
        id = record.id,
        title = snapshot.title,
        agentName = agent,
        subtitle = subtitle,
        isCompleted = snapshot.status == RegistryEntityEnums.TaskStatus.DONE,
        isOnToday = membership.isOnToday,
        isStarred = snapshot.starred,
        isFaded = isFaded,
        deadlineText = deadlineText,
        deadlineIsRed = deadlineIsRed,
        deadlineShowsFlag = deadlineShowsFlag,
        scheduledText = scheduledText,
        completedDateText = completedDateText,
        timeSlotText = timeSlotText,
        checklistDone = checklistDone,
        checklistTotal = checklistTotal,
        tagNames = tagNames,
        reminderText = reminderText,
        reminderIsPastDue = reminderIsPastDue,
        isRepeating = snapshot.recurrenceUnit != null,
        hasNotes = hasNotes,
        hasAttachments = hasAttachments,
    )
}

internal fun destinationIconKind(destinationId: String): SeptenaIconKind = when (destinationId) {
    RegistryDestinationIds.TODAY -> SeptenaIconKind.Today
    RegistryDestinationIds.INBOX -> SeptenaIconKind.Inbox
    RegistryDestinationIds.REVIEW -> SeptenaIconKind.Review
    RegistryDestinationIds.AGENT -> SeptenaIconKind.Agent
    RegistryDestinationIds.UPCOMING -> SeptenaIconKind.Upcoming
    RegistryDestinationIds.REPEATING -> SeptenaIconKind.Repeating
    RegistryDestinationIds.ANYTIME -> SeptenaIconKind.Anytime
    RegistryDestinationIds.STARRED -> SeptenaIconKind.Starred
    RegistryDestinationIds.FADED -> SeptenaIconKind.Faded
    RegistryDestinationIds.LOGBOOK -> SeptenaIconKind.Logbook
    RegistryDestinationIds.RECENTLY_DELETED -> SeptenaIconKind.RecentlyDeleted
    else -> SeptenaIconKind.None
}

private fun parseIsoDay(raw: String): LocalDate? =
    runCatching { LocalDate.parse(raw.take(10)) }.getOrNull()

internal fun formatShortLocalDay(
    day: LocalDate,
    today: LocalDate,
    todayLabel: String,
    tomorrowLabel: String,
    languageTag: String,
): String = when (day) {
    today -> todayLabel
    today.plusDays(1) -> tomorrowLabel
    else -> {
        val locale = Locale.forLanguageTag(languageTag)
        val pattern = if (day.year == today.year) "MMM d" else "MMM d, yyyy"
        DateTimeFormatter.ofPattern(pattern, locale).format(day)
    }
}

private fun formatShortInstantDay(
    isoInstant: String,
    today: LocalDate,
    todayLabel: String,
    tomorrowLabel: String,
    languageTag: String,
    zoneId: ZoneId,
): String? {
    val day = runCatching { Instant.parse(isoInstant).atZone(zoneId).toLocalDate() }.getOrNull()
        ?: parseIsoDay(isoInstant)
        ?: return null
    return formatShortLocalDay(day, today, todayLabel, tomorrowLabel, languageTag)
}

internal fun formatCompactReminder(
    instant: Instant,
    today: LocalDate,
    languageTag: String,
    zoneId: ZoneId,
): String {
    val locale = Locale.forLanguageTag(languageTag)
    val zoned = instant.atZone(zoneId)
    val timeText = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withLocale(locale).format(zoned)
    val day = zoned.toLocalDate()
    return if (day == today) {
        timeText
    } else {
        val dateText = DateTimeFormatter.ofPattern("MMM d", locale).format(day)
        "$dateText, $timeText"
    }
}
