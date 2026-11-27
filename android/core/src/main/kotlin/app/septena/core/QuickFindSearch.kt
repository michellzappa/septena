package app.septena.core

import app.septena.core.generated.RegistryDestinationIds
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import java.util.Locale

sealed interface QuickFindTarget {
    data class Task(
        val taskId: String,
        val areaId: String?,
        val projectId: String?,
        val destinationId: String?,
    ) : QuickFindTarget

    data class Area(val areaId: String) : QuickFindTarget
    data class Project(val projectId: String) : QuickFindTarget
}

data class QuickFindResult(
    val id: String,
    val title: String,
    val subtitle: String?,
    val subtitleKey: QuickFindSubtitle?,
    val target: QuickFindTarget,
)

sealed interface QuickFindSubtitle {
    data object Completed : QuickFindSubtitle
    data class Destination(val id: String) : QuickFindSubtitle
}

private data class RankedResult(val result: QuickFindResult, val score: Int)

/** Local Quick Find ranking and result routing shared by the Kotlin clients. */
class QuickFindSearch(
    private val store: TaskStore,
    private val clock: DayClock,
    private val includeArchivedProjects: Boolean = true,
) {
    private val refs = TaskRefLookup(store)

    /** Captures one read-only search view so a desktop query never competes with writes for SQLite. */
    suspend fun snapshot(): QuickFindSearch {
        val records = SEARCH_ENTITIES.associateWith { store.records(it) }
        val readView = object : TaskStore by store {
            override suspend fun records(entity: String): List<SyncRecord> = records.getValue(entity)
        }
        return QuickFindSearch(readView, clock, includeArchivedProjects)
    }

    suspend fun search(rawQuery: String): List<QuickFindResult> {
        val tokens = rawQuery.trim().lowercase(Locale.ROOT).split(WHITESPACE).filter(String::isNotEmpty)
        if (tokens.isEmpty()) return emptyList()

        val taskRecords = store.records(RegistryEntityNames.TASK)
        val areaRecords = store.records(RegistryEntityNames.AREA).filter { it.deletedAt == null }
        val projectRecords = store.records(RegistryEntityNames.PROJECT).filter { project ->
            project.deletedAt == null && (includeArchivedProjects ||
                project.fields[RegistryEntityFields.Project.STATUS].stringValue() == RegistryEntityEnums.ProjectStatus.ACTIVE)
        }
        val tagNames = store.records(RegistryEntityNames.TAG)
            .asSequence()
            .filter { it.deletedAt == null }
            .mapNotNull { record ->
                record.fields[RegistryEntityFields.Tag.NAME].stringValue()?.let { record.id to it }
            }
            .toMap()
        val areasById = areaRecords.associateBy { it.id }
        val projectsById = projectRecords.associateBy { it.id }
        val areaTitles = areaRecords.mapNotNull { record ->
            record.fields[RegistryEntityFields.Area.TITLE].stringValue()?.let { record.id to it }
        }.toMap()
        val projectTitles = projectRecords.mapNotNull { record ->
            record.fields[RegistryEntityFields.Project.TITLE].stringValue()?.let { record.id to it }
        }.toMap()
        val now = clock.now()
        val today = clock.today(now)
        val ranked = mutableListOf<RankedResult>()
        val refTexts = refs.searchTexts()
        // A pasted link: the tasks that point at the item come first, whatever
        // way the link is spelled there.
        val pointing = refs.taskIdsForLink(rawQuery).orEmpty()
            .withIndex().associate { (index, id) -> id to index }

        val context = currentCoroutineContext()
        for (record in taskRecords) {
            context.ensureActive()
            if (record.deletedAt != null) continue
            val task = runCatching { TaskSnapshot.from(record) }.getOrNull() ?: continue
            if (task.isHeading) continue
            val areaId = task.area?.takeIf(areasById::containsKey)
            val projectId = task.project?.takeIf(projectsById::containsKey)
            val routableTask = task.copy(area = areaId, project = projectId)
            val tagText = ((record.fields[RegistryEntityFields.Task.TAGS] as? JsonValue.ArrayValue)
                ?.values.orEmpty())
                .mapNotNull { value -> value.stringValue()?.let(tagNames::get) }
                .joinToString(" ") { "$it #$it" }
            val notes = record.fields[RegistryEntityFields.Task.NOTES].stringValue().orEmpty()
            val found = score(task.title, "$notes $tagText ${refTexts[record.id].orEmpty()}", tokens)
            val rank = pointing[record.id]
            val score = found + if (rank == null) 0 else POINTING_SCORE - rank
            if (score <= 0) continue
            val destinationId = destinationFor(routableTask, today, now)
            val subtitle = taskSubtitle(task, today, now, areaTitles, projectTitles)
            ranked += RankedResult(
                result = QuickFindResult(
                    id = "task:${record.id}",
                    title = task.title,
                    subtitle = subtitle.text,
                    subtitleKey = subtitle.key,
                    target = QuickFindTarget.Task(
                        taskId = record.id,
                        areaId = areaId,
                        projectId = projectId,
                        destinationId = destinationId,
                    ),
                ),
                score = score + when {
                    task.status != RegistryEntityEnums.TaskStatus.DONE -> 0
                    rank == null -> -1
                    else -> -POINTING_SCORE / 2
                },
            )
        }

        for (record in projectRecords) {
            val title = record.fields[RegistryEntityFields.Project.TITLE].stringValue().orEmpty()
            val notes = record.fields[RegistryEntityFields.Project.NOTES].stringValue()
            val score = score(title, notes.orEmpty(), tokens)
            if (score <= 0) continue
            val areaId = record.fields[RegistryEntityFields.Project.AREA].stringValue()
            ranked += RankedResult(
                result = QuickFindResult(
                    id = "project:${record.id}",
                    title = title,
                    subtitle = areaId?.let(areaTitles::get),
                    subtitleKey = null,
                    target = QuickFindTarget.Project(record.id),
                ),
                score = score + 1 + if (
                    record.fields[RegistryEntityFields.Project.STATUS].stringValue() == RegistryEntityEnums.ProjectStatus.DONE
                ) -3 else 0,
            )
        }

        for (record in areaRecords) {
            val title = record.fields[RegistryEntityFields.Area.TITLE].stringValue().orEmpty()
            val context = record.fields[RegistryEntityFields.Area.CONTEXT].stringValue().orEmpty()
            val score = score(title, context, tokens)
            if (score <= 0) continue
            ranked += RankedResult(
                result = QuickFindResult(
                    id = "area:${record.id}",
                    title = title,
                    subtitle = null,
                    subtitleKey = null,
                    target = QuickFindTarget.Area(record.id),
                ),
                score = score + 1,
            )
        }

        return ranked
            .sortedWith(compareByDescending<RankedResult> { it.score }.thenBy { it.result.title.lowercase(Locale.ROOT) })
            .take(RESULT_LIMIT)
            .map(RankedResult::result)
    }

    private fun score(title: String, body: String, tokens: List<String>): Int {
        val normalizedTitle = title.lowercase(Locale.ROOT)
        val normalizedBody = body.lowercase(Locale.ROOT)
        var total = 0
        for (token in tokens) {
            val inTitle = token in normalizedTitle
            val inBody = token in normalizedBody
            if (!inTitle && !inBody) return 0
            if (inTitle) {
                total += 10
                if (normalizedTitle.startsWith(token)) total += 6
                else if (" $token" in normalizedTitle) total += 3
            }
            if (inBody) total += 2
        }
        if (normalizedTitle == tokens.joinToString(" ")) total += 20
        return total
    }

    private fun destinationFor(task: TaskSnapshot, today: java.time.LocalDate, now: java.time.Instant): String? {
        if (task.project != null || task.area != null) return null
        val membership = TaskViewRules.membership(task, today, now)
        return when {
            membership.isOnToday -> RegistryDestinationIds.TODAY
            task.scheduled != null || task.deadline != null -> RegistryDestinationIds.UPCOMING
            task.status == RegistryEntityEnums.TaskStatus.DONE -> RegistryDestinationIds.LOGBOOK
            else -> RegistryDestinationIds.TODAY
        }
    }

    private fun taskSubtitle(
        task: TaskSnapshot,
        today: java.time.LocalDate,
        now: java.time.Instant,
        areaTitles: Map<String, String>,
        projectTitles: Map<String, String>,
    ): TaskSubtitle {
        task.project?.let(projectTitles::get)?.let { return TaskSubtitle(text = it) }
        task.area?.let(areaTitles::get)?.let { return TaskSubtitle(text = it) }
        if (task.status == RegistryEntityEnums.TaskStatus.DONE) {
            return TaskSubtitle(key = QuickFindSubtitle.Completed)
        }
        if (TaskViewRules.membership(task, today, now).isOnToday) {
            return TaskSubtitle(key = QuickFindSubtitle.Destination(RegistryDestinationIds.TODAY))
        }
        return TaskSubtitle()
    }

    private data class TaskSubtitle(val text: String? = null, val key: QuickFindSubtitle? = null)

    private companion object {
        val SEARCH_ENTITIES = listOf(
            RegistryEntityNames.TASK,
            RegistryEntityNames.AREA,
            RegistryEntityNames.PROJECT,
            RegistryEntityNames.TAG,
            RegistryEntityNames.TASK_REF,
        )
        val WHITESPACE = Regex("\\s+")
        const val RESULT_LIMIT = 12
        const val POINTING_SCORE = 10_000
    }
}
