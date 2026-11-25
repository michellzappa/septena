package app.septena.core

import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import app.septena.sharedcore.parseRef
import java.net.URI

/** Another task that points at the same item. */
data class TaskRefOther(val id: String, val title: String)

/**
 * "Which tasks point at this?" (`docs/TASK_REFERENCES_SPEC.md` §6.4). A task points
 * at an item when it has a reference to it, or when its title or notes hold a link
 * to it: every spelling of a link gives one key (Apple `TaskRefLookup`).
 */
class TaskRefLookup(private val store: TaskStore) {
    /** The tasks that point at the link, references first. Null when the text is not one link. */
    suspend fun taskIdsForLink(text: String): List<String>? {
        val link = text.trim()
        if (link.any(Char::isWhitespace)) return null
        if (!link.startsWith("message:", ignoreCase = true) && !TaskRefResolver.canOpenWebUrl(link)) return null
        val key = runCatching { parseRef(link) }.getOrNull()?.key ?: return null
        return pointing(pair(key)) { true }.map { it.id }
    }

    /** What a text search reads of each task's references. */
    suspend fun searchTexts(): Map<String, String> = refs()
        .groupBy(TaskRefRecord::taskId)
        .mapValues { (_, refs) ->
            refs.flatMap { listOfNotNull(it.title, it.subtitle, it.keyId) }.joinToString(" ")
        }

    /** The other open tasks that point at what this task points at, or at the task itself. */
    suspend fun alsoIn(taskId: String, title: String, notes: String?, max: Int): List<TaskRefOther> {
        val keys = refs().filter { it.taskId == taskId }.map(TaskRefRecord::key) +
            TaskRefOffers.of(title, notes, emptyList()).map(TaskRefOffer::key)
        return pointing(keys.flatMapTo(HashSet(), ::pair) + "task:$taskId") { it.id != taskId && isOpen(it) }
            .take(max)
            .map { TaskRefOther(it.id, it.title()) }
    }

    /** The open tasks that point at one of the links of a text (the share screen). */
    suspend fun openTasksFor(text: String, max: Int): List<TaskRefOther> {
        val keys = TaskRefOffers.of(text, null, emptyList()).flatMapTo(HashSet()) { pair(it.key) }
        if (keys.isEmpty()) return emptyList()
        return pointing(keys, ::isOpen).take(max).map { TaskRefOther(it.id, it.title()) }
    }

    private suspend fun pointing(keys: Set<String>, include: (SyncRecord) -> Boolean): List<SyncRecord> {
        val referenced = refs().filter { it.key in keys }.mapTo(HashSet(), TaskRefRecord::taskId)
        // A text without one of these holds none of the keys.
        val needles = keys.mapNotNullTo(HashSet(), ::needle)
        if (referenced.isEmpty() && needles.isEmpty()) return emptyList()
        val (first, rest) = store.records(RegistryEntityNames.TASK)
            .filter { it.deletedAt == null && !isHeading(it) && it.title().isNotBlank() && include(it) }
            .partition { it.id in referenced }
        return first + rest.filter { record ->
            listOf(record.title(), record.fields[RegistryEntityFields.Task.NOTES].stringValue().orEmpty())
                .filter { text -> needles.any { text.contains(it, ignoreCase = true) } }
                .flatMap(TaskRefOffers::linkTexts)
                .any { link -> runCatching { parseRef(link) }.getOrNull()?.key in keys }
        }
    }

    private suspend fun refs(): List<TaskRefRecord> =
        store.records(RegistryEntityNames.TASK_REF).mapNotNull(TaskRefRecord::from)

    private fun SyncRecord.title(): String = fields[RegistryEntityFields.Task.TITLE].stringValue().orEmpty()

    private fun isOpen(record: SyncRecord): Boolean =
        record.fields[RegistryEntityFields.Task.STATUS].stringValue() == RegistryEntityEnums.TaskStatus.OPEN

    private fun isHeading(record: SyncRecord): Boolean =
        record.fields[RegistryEntityFields.Task.KIND].stringValue() == RegistryEntityEnums.TaskKind.HEADING

    /** A part of every link that gives this key. */
    private fun needle(key: String): String? {
        val id = key.substringAfter(':', missingDelimiterValue = "")
        return when (key.substringBefore(':')) {
            "issue" -> "github.com"
            "email", "thread" -> "message:"
            "url" -> runCatching { URI(id).host }.getOrNull()
            "door" -> id.substringBefore('|')
            "task" -> if ('/' in id) id.substringBefore('/') else null
            else -> null
        }?.takeIf(String::isNotBlank)
    }

    /** A mail and the thread it starts share an id: a link to one finds both. */
    private fun pair(key: String): Set<String> = when {
        key.startsWith("email:") -> setOf(key, "thread:" + key.removePrefix("email:"))
        key.startsWith("thread:") -> setOf(key, "email:" + key.removePrefix("thread:"))
        else -> setOf(key)
    }
}
