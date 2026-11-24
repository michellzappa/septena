package app.septena.android.ui

import android.text.format.DateFormat
import app.septena.android.AndroidAppGraph
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.SyncRecord
import app.septena.core.TaskProvenance
import app.septena.core.TaskSnapshot
import app.septena.core.TaskViewMembership
import app.septena.core.booleanValue
import app.septena.core.generated.RegistryDestinationIds
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.generated.RegistryIconIds
import app.septena.core.generated.RegistryTaskAttributeIds
import app.septena.core.stringValue
import app.septena.ui.TaskListItem
import app.septena.ui.TaskRowSignal
import app.septena.ui.TaskSignalTone
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * Builds the row every task list shows, with the trailing signals of the
 * iPhone row (`TaskRow.trailing`). Tags and checklist counts load once per list.
 * The due state comes from the shared core, never from a date compare here.
 */
internal class TaskRowSource private constructor(
    private val today: LocalDate,
    private val locale: Locale,
    private val tagNames: Map<String, String>,
    private val checklists: Map<String, Pair<Int, Int>>,
) {
    private val languageTag = locale.toLanguageTag()
    private val todayTitle = RegistryCatalog.destinationTitle(RegistryDestinationIds.TODAY, languageTag).orEmpty()
    private val starredTitle = RegistryCatalog.destinationTitle(RegistryDestinationIds.STARRED, languageTag).orEmpty()
    private val attributeLabels = RegistryCatalog.taskAttributes(languageTag).associate { it.id to it.label }
    private val dayFormat = DateTimeFormatter.ofPattern(DateFormat.getBestDateTimePattern(locale, "MMMd"), locale)

    /** [showsToday] is false on Today itself, where the Today pill and past dates are noise. */
    fun item(
        record: SyncRecord,
        snapshot: TaskSnapshot,
        membership: TaskViewMembership,
        subtitle: String?,
        showsToday: Boolean,
    ): TaskListItem {
        val isOpen = snapshot.status == RegistryEntityEnums.TaskStatus.OPEN && snapshot.deletedAt == null
        val agentName = if (TaskProvenance.isAgentAuthored(snapshot.source)) {
            TaskProvenance.addedByName(snapshot.source, snapshot.sourceClient)
        } else {
            null
        }
        val tagIds = (record.fields[RegistryEntityFields.Task.TAGS] as? JsonValue.ArrayValue)
            ?.values.orEmpty().mapNotNull { it.stringValue() }
        return TaskListItem(
            id = record.id,
            title = snapshot.title,
            agentName = agentName,
            subtitle = subtitle,
            isCompleted = snapshot.status == RegistryEntityEnums.TaskStatus.DONE,
            isOnToday = membership.isOnToday,
            isStarred = snapshot.starred,
            signals = buildList {
                dateSignal(record, snapshot, membership, showsToday)?.let(::add)
                checklists[record.id]?.let { (done, total) ->
                    add(signal(RegistryIconIds.ACTION_CHECKLIST, RegistryTaskAttributeIds.CHECKLIST, "$done/$total"))
                }
                val reminder = record.fields[RegistryEntityFields.Task.REMINDER_AT].stringValue()
                val dismissed = record.fields[RegistryEntityFields.Task.REMINDER_DISMISSED_AT].stringValue()
                if (isOpen && reminder != null && dismissed == null) {
                    add(signal(RegistryIconIds.ACTION_REMINDER, RegistryTaskAttributeIds.REMINDER))
                }
                if (snapshot.recurrenceUnit != null) {
                    add(signal(RegistryIconIds.ACTION_REPEAT, RegistryTaskAttributeIds.REPEAT))
                }
                if (snapshot.starred) {
                    add(TaskRowSignal(RegistryIconIds.LIST_STARRED, label = starredTitle, tone = TaskSignalTone.Star))
                }
                // An agent's row already says "there is more here" with the agent name.
                val hasNotes = !record.fields[RegistryEntityFields.Task.NOTES].stringValue().isNullOrBlank()
                if (hasNotes && agentName == null) {
                    add(signal(RegistryIconIds.ACTION_NOTES, RegistryTaskAttributeIds.NOTES))
                }
            },
            tags = tagIds.mapNotNull(tagNames::get),
        )
    }

    private fun dateSignal(
        record: SyncRecord,
        snapshot: TaskSnapshot,
        membership: TaskViewMembership,
        showsToday: Boolean,
    ): TaskRowSignal? {
        val deadline = day(snapshot.deadline)
        val scheduled = day(snapshot.scheduled)
        val deadlineLabel = attributeLabels[RegistryTaskAttributeIds.DEADLINE].orEmpty()
        return when {
            snapshot.status == RegistryEntityEnums.TaskStatus.DONE ||
                snapshot.status == RegistryEntityEnums.TaskStatus.CANCELLED -> {
                val on = day(record.fields[RegistryEntityFields.Task.COMPLETED_AT].stringValue()) ?: return null
                val icon = if (snapshot.status == RegistryEntityEnums.TaskStatus.DONE) {
                    RegistryIconIds.LIST_LOGBOOK
                } else {
                    RegistryIconIds.ACTION_CANCEL
                }
                TaskRowSignal(icon, text = label(on))
            }
            membership.dueState == DUE_TODAY ->
                TaskRowSignal(RegistryIconIds.ACTION_DEADLINE, todayTitle, deadlineLabel, TaskSignalTone.Overdue)
            membership.dueState != null && deadline != null ->
                TaskRowSignal(RegistryIconIds.ACTION_DEADLINE, label(deadline), deadlineLabel, TaskSignalTone.Overdue)
            deadline != null ->
                TaskRowSignal(RegistryIconIds.ACTION_DEADLINE, label(deadline), deadlineLabel)
            scheduled != null -> {
                val covered = showsToday && membership.isOnToday && !scheduled.isAfter(today)
                if (covered || (!showsToday && !scheduled.isAfter(today))) return null
                signal(RegistryIconIds.ACTION_WHEN, RegistryTaskAttributeIds.WHEN, label(scheduled))
            }
            else -> null
        }
    }

    private fun signal(icon: String, attribute: String, text: String? = null) =
        TaskRowSignal(icon, text, attributeLabels[attribute].orEmpty())

    private fun label(date: LocalDate): String = if (date == today) todayTitle else dayFormat.format(date)

    private fun day(value: String?): LocalDate? = value?.let { runCatching { LocalDate.parse(it.take(10)) }.getOrNull() }

    companion object {
        /** The core's `due_state` for a deadline on today; any other value is overdue (views.rs R3). */
        private const val DUE_TODAY = "dueToday"

        suspend fun load(graph: AndroidAppGraph, today: LocalDate): TaskRowSource {
            val tagNames = graph.taskStore.records(RegistryEntityNames.TAG)
                .filter { it.deletedAt == null }
                .mapNotNull { tag -> tag.fields[RegistryEntityFields.Tag.NAME].stringValue()?.let { tag.id to it } }
                .toMap()
            val checklists = graph.taskStore.records(RegistryEntityNames.CHECKLIST_ITEM)
                .filter { it.deletedAt == null }
                .groupBy { it.fields[RegistryEntityFields.ChecklistItem.TASK_ID].stringValue().orEmpty() }
                .mapValues { (_, items) ->
                    items.count { it.fields[RegistryEntityFields.ChecklistItem.CHECKED].booleanValue() == true } to items.size
                }
            return TaskRowSource(today, Locale.getDefault(), tagNames, checklists)
        }
    }
}
