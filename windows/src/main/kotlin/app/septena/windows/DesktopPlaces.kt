package app.septena.windows

import app.septena.core.JsonValue
import app.septena.core.SyncRecord
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.stringValue

internal sealed interface DesktopLocation {
    data class Smart(val id: String) : DesktopLocation
    data class Area(val id: String) : DesktopLocation
    data class Project(val id: String) : DesktopLocation
    data class Section(val projectId: String, val id: String) : DesktopLocation

    fun key(): String = when (this) {
        is Smart -> "smart:$id"
        is Area -> "area:$id"
        is Project -> "project:$id"
        is Section -> "section:$projectId:$id"
    }
}

internal data class DesktopPlace(
    val location: DesktopLocation,
    val title: String,
    val areaId: String? = null,
    val position: Double? = null,
)

internal data class DesktopPlaces(
    val areas: List<DesktopPlace> = emptyList(),
    val projects: List<DesktopPlace> = emptyList(),
    val sections: Map<String, List<DesktopPlace>> = emptyMap(),
) {
    fun outline(): List<DesktopPlace> = buildList {
        fun addProject(project: DesktopPlace) {
            add(project)
            addAll(sections[(project.location as DesktopLocation.Project).id].orEmpty())
        }
        for (area in areas) {
            add(area)
            val id = (area.location as DesktopLocation.Area).id
            projects.filter { it.areaId == id }.forEach(::addProject)
        }
        projects.filter { it.areaId == null }.forEach(::addProject)
    }

    fun place(location: DesktopLocation): DesktopPlace? = when (location) {
        is DesktopLocation.Smart -> null
        is DesktopLocation.Area -> areas.firstOrNull { it.location == location }
        is DesktopLocation.Project -> projects.firstOrNull { it.location == location }
        is DesktopLocation.Section -> sections[location.projectId]?.firstOrNull { it.location == location }
    }
}

internal fun desktopPlaces(
    areaRecords: List<SyncRecord>,
    projectRecords: List<SyncRecord>,
    taskRecords: List<SyncRecord>,
): DesktopPlaces {
    val areas = areaRecords.filter { it.deletedAt == null }.map { area ->
        DesktopPlace(
            DesktopLocation.Area(area.id),
            area.fields[RegistryEntityFields.Area.TITLE].stringValue().orEmpty(),
            position = area.fields[RegistryEntityFields.Area.POSITION].numberValue(),
        )
    }.sortedWith(placeOrder)
    val areaIds = areas.mapTo(HashSet()) { (it.location as DesktopLocation.Area).id }
    val projects = projectRecords.filter {
        it.deletedAt == null &&
            it.fields[RegistryEntityFields.Project.STATUS].stringValue() == RegistryEntityEnums.ProjectStatus.ACTIVE
    }.map { project ->
        DesktopPlace(
            DesktopLocation.Project(project.id),
            project.fields[RegistryEntityFields.Project.TITLE].stringValue().orEmpty(),
            project.fields[RegistryEntityFields.Project.AREA].stringValue()?.takeIf { it in areaIds },
            project.fields[RegistryEntityFields.Project.POSITION].numberValue(),
        )
    }.sortedWith(placeOrder)
    val projectIds = projects.mapTo(HashSet()) { (it.location as DesktopLocation.Project).id }
    val headings = taskRecords.mapNotNull { task ->
        if (task.deletedAt != null ||
            task.fields[RegistryEntityFields.Task.STATUS].stringValue() != RegistryEntityEnums.TaskStatus.OPEN ||
            task.fields[RegistryEntityFields.Task.KIND].stringValue() != RegistryEntityEnums.TaskKind.HEADING
        ) return@mapNotNull null
        val projectId = task.fields[RegistryEntityFields.Task.PROJECT].stringValue()?.takeIf { it in projectIds }
            ?: return@mapNotNull null
        DesktopPlace(
            DesktopLocation.Section(projectId, task.id),
            task.fields[RegistryEntityFields.Task.TITLE].stringValue().orEmpty(),
            position = task.fields[RegistryEntityFields.Task.POSITION].numberValue(),
        )
    }.sortedWith(placeOrder)
    return DesktopPlaces(areas, projects, headings.groupBy { (it.location as DesktopLocation.Section).projectId })
}

private val placeOrder = compareBy<DesktopPlace>({ it.position ?: Double.MAX_VALUE }, { it.title.lowercase() })

internal fun JsonValue?.numberValue(): Double? = when (this) {
    is JsonValue.IntegerValue -> value.toDouble()
    is JsonValue.DecimalValue -> value
    else -> null
}
