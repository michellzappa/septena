package app.septena.windows

import app.septena.core.DayClock
import app.septena.core.SyncRecord
import app.septena.core.TaskSnapshot
import app.septena.core.TaskViewRules
import app.septena.core.formatUpcomingDayHeader
import app.septena.core.generated.RegistryDestinationIds
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.stringValue
import app.septena.ui.TaskGroupHeader
import app.septena.ui.TaskListItem
import java.time.LocalDate

internal val desktopDestinations = listOf(
    RegistryDestinationIds.TODAY,
    RegistryDestinationIds.UPCOMING,
    RegistryDestinationIds.ANYTIME,
)

internal data class DesktopTaskLists(
    val inbox: List<TaskListItem> = emptyList(),
    val byDestination: Map<String, List<TaskListItem>> = emptyMap(),
    val places: DesktopPlaces = DesktopPlaces(),
    val byPlace: Map<DesktopLocation, List<TaskListItem>> = emptyMap(),
) {
    fun rows(destination: String): List<TaskListItem> = byDestination[destination].orEmpty()

    fun rows(location: DesktopLocation): List<TaskListItem> = when (location) {
        is DesktopLocation.Smart -> rows(location.id)
        else -> byPlace[location].orEmpty()
    }
}

internal fun desktopTaskLists(
    records: List<SyncRecord>,
    places: DesktopPlaces,
    clock: DayClock,
    languageTag: String,
): DesktopTaskLists {
    val now = clock.now()
    val today = clock.today(now)
    val inbox = mutableListOf<TaskListItem>()
    val lists = desktopDestinations.associateWith { mutableListOf<TaskListItem>() }
    val placeTasks = mutableMapOf<DesktopLocation, MutableList<TaskListItem>>()
    val headings = places.sections.values.flatten().associateBy(DesktopPlace::location)

    for (record in records) {
        val task = TaskSnapshot.from(record)
        if (task.isHeading || task.deletedAt != null || task.status != RegistryEntityEnums.TaskStatus.OPEN) continue
        val membership = TaskViewRules.membership(task, today, now)
        val row = TaskListItem(
            id = task.id,
            title = task.title,
            isOnToday = membership.isOnToday,
            isStarred = task.starred,
            position = record.fields[RegistryEntityFields.Task.POSITION].numberValue(),
        )

        val projectId = task.project
        val headingId = record.fields[RegistryEntityFields.Task.HEADING].stringValue()
        val location = when {
            projectId != null && headingId != null &&
                DesktopLocation.Section(projectId, headingId) in headings -> DesktopLocation.Section(projectId, headingId)
            projectId != null -> DesktopLocation.Project(projectId)
            task.area != null -> DesktopLocation.Area(task.area)
            else -> null
        }
        if (location != null) placeTasks.getOrPut(location) { mutableListOf() } += row

        for ((destination, rows) in lists) {
            if (!TaskViewRules.matchesView(task, membership, destination)) continue
            if (destination == RegistryDestinationIds.TODAY && membership.inTodayInbox) {
                inbox += row
            } else {
                val day = membership.upcomingDay?.takeIf { destination == RegistryDestinationIds.UPCOMING }
                rows += if (day == null) row else row.copy(
                    group = TaskGroupHeader(
                        key = "day:$day",
                        title = formatUpcomingDayHeader(LocalDate.parse(day), today, languageTag),
                    ),
                )
            }
        }
    }

    val byPlace = placeTasks.mapValuesTo(mutableMapOf()) { (_, rows) ->
        rows.sortedWith(compareBy({ it.position ?: Double.MAX_VALUE }, { it.title.lowercase() }))
    }
    for ((projectId, sections) in places.sections) {
        val project = DesktopLocation.Project(projectId)
        val unsectioned = byPlace[project].orEmpty()
        byPlace[project] = unsectioned + sections.flatMap { heading ->
            val section = heading.location as DesktopLocation.Section
            val header = TaskGroupHeader(key = section.id, title = heading.title, targetLocationKey = section.id)
            byPlace[section].orEmpty().map { row -> row.copy(group = header) }
        }
    }
    return DesktopTaskLists(inbox, lists, places, byPlace)
}
