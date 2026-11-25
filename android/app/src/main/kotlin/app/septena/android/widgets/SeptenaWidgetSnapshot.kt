package app.septena.android.widgets

import app.septena.android.ui.formatShortLocalDay
import app.septena.core.DayClock
import app.septena.core.DateBoardRowKinds
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.TaskFadeRules
import app.septena.core.TaskSnapshot
import app.septena.core.TaskStore
import app.septena.core.TaskTimeSlot
import app.septena.core.TaskViewMembership
import app.septena.core.TaskViewRules
import app.septena.core.generated.RegistryDestinationIds
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.generated.RegistryTaskAttributeIds
import java.time.Instant
import java.time.LocalDate
import java.util.Locale

internal data class WidgetTaskRow(
    val id: String,
    val title: String,
    val trailingMeta: String? = null,
    val isRedMeta: Boolean = false,
)

internal data class WidgetSnapshot(
    val destinationId: String,
    val title: String,
    val totalCount: Int,
    val rows: List<WidgetTaskRow>,
    val overflowCount: Int,
    val emptyLabel: String,
)

internal object SeptenaWidgetLoader {
    const val DEFAULT_MAX_ROWS = 6

    suspend fun loadToday(
        store: TaskStore,
        clock: DayClock,
        languageTag: String = Locale.getDefault().toLanguageTag(),
        maxRows: Int = DEFAULT_MAX_ROWS,
        membershipFor: (TaskSnapshot, LocalDate, Instant) -> TaskViewMembership = TaskViewRules::membership,
    ): WidgetSnapshot {
        val now = clock.now()
        val today = clock.today(now)
        val todayLabel = RegistryCatalog.destinationTitle(RegistryDestinationIds.TODAY, languageTag)
            ?.takeIf(String::isNotBlank).orEmpty()
        val overdueLabel = RegistryCatalog.localizedString("Overdue", languageTag) ?: "Overdue"
        val emptyLabel = RegistryCatalog.destinationEmptyTitle(RegistryDestinationIds.TODAY, languageTag)
            ?.takeIf(String::isNotBlank) ?: "All clear for today"

        data class Candidate(
            val row: WidgetTaskRow,
            val inInbox: Boolean,
            val pos: Double,
        )

        val candidates = mutableListOf<Candidate>()
        for (record in store.records(RegistryEntityNames.TASK)) {
            if (record.deletedAt != null) continue
            val snap = runCatching { TaskSnapshot.from(record) }.getOrNull() ?: continue
            if (snap.isHeading || snap.status != RegistryEntityEnums.TaskStatus.OPEN) continue
            val membership = membershipFor(snap, today, now)
            if (membership.matchesView[RegistryDestinationIds.TODAY] != true) continue

            val timeSlot = TaskTimeSlot.format(snap.startTime, snap.durationMinutes)
            val (meta, isRed) = when {
                membership.dueState == TaskViewRules.DUE_OVERDUE -> overdueLabel to membership.deadlineRed
                membership.dueState == TaskViewRules.DUE_TODAY && timeSlot == null -> todayLabel to membership.deadlineRed
                timeSlot != null -> timeSlot to false
                else -> null to false
            }
            val pos = record.fields[RegistryEntityFields.Task.TODAY_POSITION].asDouble()
                ?: record.fields[RegistryEntityFields.Task.POSITION].asDouble()
                ?: Double.MAX_VALUE
            candidates += Candidate(
                row = WidgetTaskRow(id = record.id, title = snap.title, trailingMeta = meta, isRedMeta = isRed),
                inInbox = membership.inTodayInbox,
                pos = pos,
            )
        }

        val sorted = candidates
            .sortedWith(compareBy<Candidate>({ if (it.inInbox) 0 else 1 }, { it.pos }, { it.row.title.lowercase() }))
            .map(Candidate::row)
        val shown = sorted.take(maxRows)
        return WidgetSnapshot(
            destinationId = RegistryDestinationIds.TODAY,
            title = todayLabel,
            totalCount = sorted.size,
            rows = shown,
            overflowCount = (sorted.size - shown.size).coerceAtLeast(0),
            emptyLabel = emptyLabel,
        )
    }

    suspend fun loadUpcoming(
        store: TaskStore,
        clock: DayClock,
        languageTag: String = Locale.getDefault().toLanguageTag(),
        maxRows: Int = DEFAULT_MAX_ROWS,
        membershipFor: (TaskSnapshot, LocalDate, Instant) -> TaskViewMembership = TaskViewRules::membership,
    ): WidgetSnapshot {
        val now = clock.now()
        val today = clock.today(now)
        val upcomingTitle = RegistryCatalog.destinationTitle(RegistryDestinationIds.UPCOMING, languageTag)
            ?.takeIf(String::isNotBlank).orEmpty()
        val todayLabel = RegistryCatalog.destinationTitle(RegistryDestinationIds.TODAY, languageTag)
            ?.takeIf(String::isNotBlank).orEmpty()
        val tomorrowLabel = RegistryCatalog.dateBoardRows(
            RegistryTaskAttributeIds.WHEN,
            languageTag = languageTag,
        ).firstOrNull { it.kind == DateBoardRowKinds.TOMORROW }?.label.orEmpty()
        val emptyLabel = RegistryCatalog.destinationEmptyTitle(RegistryDestinationIds.UPCOMING, languageTag)
            ?.takeIf(String::isNotBlank) ?: "Nothing scheduled"

        data class Candidate(
            val row: WidgetTaskRow,
            val scheduledDay: LocalDate,
            val startTime: String,
            val pos: Double,
        )

        val candidates = mutableListOf<Candidate>()
        for (record in store.records(RegistryEntityNames.TASK)) {
            if (record.deletedAt != null) continue
            val snap = runCatching { TaskSnapshot.from(record) }.getOrNull() ?: continue
            if (snap.isHeading || snap.status != RegistryEntityEnums.TaskStatus.OPEN) continue
            if (TaskFadeRules.isFaded(snap.fadedAt)) continue
            val membership = membershipFor(snap, today, now)
            if (membership.matchesView[RegistryDestinationIds.UPCOMING] != true) continue

            val schedDate = snap.scheduled?.let { runCatching { LocalDate.parse(it.take(10)) }.getOrNull() }
                ?: continue
            val dayLabel = formatShortLocalDay(schedDate, today, todayLabel, tomorrowLabel, languageTag)
            val timeSlot = TaskTimeSlot.format(snap.startTime, snap.durationMinutes)
            val meta = if (timeSlot != null) "$dayLabel · $timeSlot" else dayLabel
            val pos = record.fields[RegistryEntityFields.Task.POSITION].asDouble() ?: Double.MAX_VALUE
            candidates += Candidate(
                row = WidgetTaskRow(id = record.id, title = snap.title, trailingMeta = meta, isRedMeta = false),
                scheduledDay = schedDate,
                startTime = snap.startTime ?: "99:99",
                pos = pos,
            )
        }

        val sorted = candidates
            .sortedWith(compareBy<Candidate>({ it.scheduledDay }, { it.startTime }, { it.pos }, { it.row.title.lowercase() }))
            .map(Candidate::row)
        val shown = sorted.take(maxRows)
        return WidgetSnapshot(
            destinationId = RegistryDestinationIds.UPCOMING,
            title = upcomingTitle,
            totalCount = sorted.size,
            rows = shown,
            overflowCount = (sorted.size - shown.size).coerceAtLeast(0),
            emptyLabel = emptyLabel,
        )
    }

    private fun JsonValue?.asDouble(): Double? = when (this) {
        is JsonValue.IntegerValue -> value.toDouble()
        is JsonValue.DecimalValue -> value
        else -> null
    }
}
