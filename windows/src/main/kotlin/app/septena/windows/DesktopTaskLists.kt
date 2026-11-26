package app.septena.windows

import app.septena.core.DayClock
import app.septena.core.SyncRecord
import app.septena.core.TaskSnapshot
import app.septena.core.TaskViewRules
import app.septena.core.formatUpcomingDayHeader
import app.septena.core.generated.RegistryDestinationIds
import app.septena.core.generated.RegistryEntityEnums
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
) {
    fun rows(destination: String): List<TaskListItem> = byDestination[destination].orEmpty()
}

internal fun desktopTaskLists(records: List<SyncRecord>, clock: DayClock, languageTag: String): DesktopTaskLists {
    val now = clock.now()
    val today = clock.today(now)
    val inbox = mutableListOf<TaskListItem>()
    val lists = desktopDestinations.associateWith { mutableListOf<TaskListItem>() }

    for (record in records) {
        val task = TaskSnapshot.from(record)
        if (task.isHeading || task.deletedAt != null || task.status != RegistryEntityEnums.TaskStatus.OPEN) continue
        val membership = TaskViewRules.membership(task, today, now)
        val row = TaskListItem(
            id = task.id,
            title = task.title,
            isOnToday = membership.isOnToday,
            isStarred = task.starred,
        )

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

    return DesktopTaskLists(inbox, lists)
}
