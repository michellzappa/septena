package app.septena.android.ui

import app.septena.android.AndroidAppGraph
import app.septena.core.JsonValue
import app.septena.core.asSyncRecord
import app.septena.core.booleanValue
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.stringValue
import app.septena.ui.TASK_ORDER_GAP
import java.util.Locale

/*
 * Inline task create (Apple `TaskListView.startCreate` / `createInlineDraftAtDrop`).
 *
 * A Magic Plus tap or drop makes a real task row with an empty title and opens
 * its inline foldout on it. The row stays on this device (`TaskMutator`
 * `deferPush`) until its first title write, which sends the whole insert.
 * Return saves and folds. A draft that folds with no title is purged; it never
 * reached the server, so nothing else sees it.
 *
 * Purge trap (AGENTS.md "A rolled-back save looks exactly like the user typed
 * nothing"): a draft is purged only when the field the user typed in is blank,
 * the stored title is blank, AND the mutator still holds it as an unsent draft.
 * A failed title write leaves typed text in the field, so the draft is kept.
 */

/** The outcome of saving an inline draft's typed title. */
internal enum class InlineDraftCommit {
    /** The title landed; the draft is an ordinary task now. */
    Saved,

    /** A project draft titled `# Name` became a heading, and the placeholder row is gone. */
    BecameHeading,

    /** Nothing to save (blank title, or the row is gone). */
    NoChange,
}

/** Creates the empty, unsent draft row for [draft]'s place and returns its id. */
internal suspend fun AndroidAppGraph.createInlineDraft(draft: QuickAddDraft): String {
    val bottom = inlineDraftBottomPosition()
    // A drop on Today places the draft in Today's own order (#66); its list place is the foot.
    val listPosition = if (draft.useTodayPosition) bottom else draft.position ?: bottom
    val created = taskMutator.create(
        title = "",
        area = if (draft.projectId == null) draft.areaId else null,
        project = draft.projectId,
        today = draft.today && draft.whenDay == null,
        heading = if (draft.projectId != null) draft.headingId else null,
        position = listPosition,
        deferPush = true,
    )
    // These writes stay local with the insert until the title lands.
    draft.whenDay?.let { taskMutator.setWhen(created.id, it) }
    if (draft.starred) taskMutator.setStarred(created.id, true)
    val todayPosition = draft.position
    if (draft.useTodayPosition && todayPosition != null) {
        taskMutator.updateFields(
            created.id,
            mapOf(RegistryEntityFields.Task.TODAY_POSITION to JsonValue.DecimalValue(todayPosition)),
        )
    }
    return created.id
}

/**
 * Apple `TaskOrder.bottomPosition`: one gap below every live task, so a tapped
 * draft lands at the foot of its list.
 */
private suspend fun AndroidAppGraph.inlineDraftBottomPosition(): Double {
    val highest = taskStore.records(RegistryEntityNames.TASK)
        .asSequence()
        .filter { it.deletedAt == null }
        .mapNotNull { it.fields[RegistryEntityFields.Task.POSITION].positionValue() }
        .filter { it != 0.0 }
        .maxOrNull() ?: 0.0
    val bottom = highest + TASK_ORDER_GAP
    return if (bottom == 0.0) TASK_ORDER_GAP / 2 else bottom
}

/**
 * Saves the typed title of draft [taskId] (Apple `TaskComposerCard.persist`
 * for a deferred create): a project draft titled `# Name` becomes a heading;
 * otherwise the explicit title tokens (`!today`, `#project`, `@area`) apply to
 * fields that are still unset, and the cleaned title is written. The create
 * enters Undo only after the write lands. Throws when a write fails, so the
 * caller keeps the row and the typed text.
 */
internal suspend fun AndroidAppGraph.commitInlineDraft(
    taskId: String,
    rawTitle: String,
    rawNotes: String,
): InlineDraftCommit {
    val title = rawTitle.trim()
    if (title.isEmpty()) return InlineDraftCommit.NoChange
    val record = taskStore.record(RegistryEntityNames.TASK, taskId) ?: return InlineDraftCommit.NoChange
    if (record.deletedAt != null) return InlineDraftCommit.NoChange
    val projectId = record.fields[RegistryEntityFields.Task.PROJECT].stringValue()?.takeIf(String::isNotBlank)
    val areaId = record.fields[RegistryEntityFields.Task.AREA].stringValue()?.takeIf(String::isNotBlank)
    val isToday = record.fields[RegistryEntityFields.Task.TODAY].booleanValue() == true

    val headingTitle = InlineTitleTokens.headingTitle(title)
    if (projectId != null && headingTitle != null) {
        val highest = taskStore.records(RegistryEntityNames.TASK)
            .asSequence()
            .filter { it.deletedAt == null }
            .filter { it.fields[RegistryEntityFields.Task.PROJECT].stringValue() == projectId }
            .filter { it.fields[RegistryEntityFields.Task.KIND].stringValue() == RegistryEntityEnums.TaskKind.HEADING }
            .mapNotNull { it.fields[RegistryEntityFields.Task.POSITION].positionValue() }
            .maxOrNull()
        val heading = taskMutator.createHeading(headingTitle, projectId, (highest ?: 0.0) + TASK_ORDER_GAP)
        taskUndoHistory.recordCreated(heading.asSyncRecord())
        // The heading landed, so the empty placeholder can go.
        taskMutator.purge(taskId)
        return InlineDraftCommit.BecameHeading
    }

    val parsed = InlineTitleTokens.parse(
        raw = title,
        projects = activeProjects(),
        areas = areaTitles(),
        todaySet = isToday,
        projectSet = projectId != null,
        areaSet = areaId != null || projectId != null,
    )
    val changes = linkedMapOf<String, JsonValue>(
        RegistryEntityFields.Task.TITLE to JsonValue.StringValue(parsed.title),
    )
    val notes = rawNotes.trim()
    if (notes.isNotEmpty()) changes[RegistryEntityFields.Task.NOTES] = JsonValue.StringValue(notes)
    check(taskMutator.updateFields(taskId, changes) != null)
    when {
        parsed.projectId != null -> taskMutator.moveToList(taskId, area = null, project = parsed.projectId)
        parsed.areaId != null -> taskMutator.moveToList(taskId, area = parsed.areaId, project = null)
    }
    if (parsed.today) taskMutator.setToday(taskId, enabled = true)
    taskStore.record(RegistryEntityNames.TASK, taskId)?.let { taskUndoHistory.recordCreated(it) }
    return InlineDraftCommit.Saved
}

/**
 * Purges draft [taskId] when it folded with nothing typed. The caller has
 * already checked its own field; this checks the store and the unsent mark.
 * Fails closed: any doubt keeps the row.
 */
internal suspend fun AndroidAppGraph.discardInlineDraftIfEmpty(taskId: String): Boolean {
    if (!taskMutator.isUnsentDraft(taskId)) return false
    val record = taskStore.record(RegistryEntityNames.TASK, taskId) ?: return false
    val stored = record.fields[RegistryEntityFields.Task.TITLE].stringValue().orEmpty()
    if (stored.isNotBlank()) return false
    return taskMutator.purge(taskId)
}

/**
 * Apple `sweepAbandonedDraftsOnce`: at launch, purge rows a crash left behind,
 * an empty title that the server never acknowledged. A heading is never swept.
 */
internal suspend fun AndroidAppGraph.sweepAbandonedInlineDrafts(): Int {
    val abandoned = taskStore.records(RegistryEntityNames.TASK).filter { record ->
        record.deletedAt == null &&
            record.revision == null &&
            record.fields[RegistryEntityFields.Task.TITLE].stringValue().isNullOrBlank() &&
            record.fields[RegistryEntityFields.Task.KIND].stringValue() != RegistryEntityEnums.TaskKind.HEADING
    }
    abandoned.forEach { taskMutator.purge(it.id) }
    return abandoned.size
}

private suspend fun AndroidAppGraph.activeProjects(): List<Pair<String, String>> =
    taskStore.records(RegistryEntityNames.PROJECT)
        .filter { it.deletedAt == null }
        .filter {
            (it.fields[RegistryEntityFields.Project.STATUS].stringValue() ?: RegistryEntityEnums.ProjectStatus.ACTIVE) ==
                RegistryEntityEnums.ProjectStatus.ACTIVE
        }
        .mapNotNull { record -> record.fields[RegistryEntityFields.Project.TITLE].stringValue()?.let { record.id to it } }

private suspend fun AndroidAppGraph.areaTitles(): List<Pair<String, String>> =
    taskStore.records(RegistryEntityNames.AREA)
        .filter { it.deletedAt == null }
        .mapNotNull { record -> record.fields[RegistryEntityFields.Area.TITLE].stringValue()?.let { record.id to it } }

private fun JsonValue?.positionValue(): Double? = when (this) {
    is JsonValue.IntegerValue -> value.toDouble()
    is JsonValue.DecimalValue -> value
    else -> null
}

/**
 * Apple `TaskTitleParser`'s explicit tokens, applied on save
 * (`TaskComposerCard.applyPendingTokens`): one per whitespace-separated word,
 * `!today` / `!t`, `#project` (an active project), `@area`. A token applies only
 * when its field is still unset, and its word leaves the title. A title that
 * would end up empty keeps its words.
 */
internal object InlineTitleTokens {
    data class Result(
        val title: String,
        val today: Boolean = false,
        val projectId: String? = null,
        val areaId: String? = null,
    )

    /** `# Name` in a project draft: the heading title, else null (Apple `headingPrefixMatch`). */
    fun headingTitle(title: String): String? {
        if (!title.startsWith("# ")) return null
        return title.removePrefix("# ").trim().takeIf(String::isNotEmpty)
    }

    fun parse(
        raw: String,
        projects: List<Pair<String, String>>,
        areas: List<Pair<String, String>>,
        todaySet: Boolean,
        projectSet: Boolean,
        areaSet: Boolean,
    ): Result {
        var today = false
        var projectId: String? = null
        var areaId: String? = null
        val applied = mutableListOf<String>()
        for (word in raw.split(' ', '\n').filter(String::isNotEmpty)) {
            val lower = word.lowercase(Locale.ROOT)
            when {
                lower == "!today" || lower == "!t" -> if (!todaySet && !today) {
                    today = true
                    applied += word
                }
                word.startsWith("#") && word.length > 1 -> if (!projectSet && projectId == null) {
                    matchTitle(lower.drop(1), projects)?.let {
                        projectId = it
                        applied += word
                    }
                }
                word.startsWith("@") && word.length > 1 -> if (!areaSet && areaId == null && projectId == null) {
                    matchTitle(lower.drop(1), areas)?.let {
                        areaId = it
                        applied += word
                    }
                }
            }
        }
        val cleaned = applied.fold(raw) { text, phrase -> strip(phrase, text) }
        if (cleaned.isEmpty()) return Result(title = raw.trim())
        return Result(title = cleaned, today = today, projectId = projectId, areaId = if (projectId != null) null else areaId)
    }

    /** Apple `TaskTitleParser.strip`: the first case-insensitive match, then tidy spaces. */
    private fun strip(phrase: String, text: String): String {
        val index = text.indexOf(phrase, ignoreCase = true)
        if (index < 0) return text
        var s = text.removeRange(index, index + phrase.length)
        while (s.contains("  ")) s = s.replace("  ", " ")
        return s.trim()
    }

    /** Exact, prefix, or prefix with spaces removed, as Apple `titleMatches`. */
    private fun matchTitle(query: String, candidates: List<Pair<String, String>>): String? =
        candidates.firstOrNull { (_, title) ->
            val t = title.lowercase(Locale.ROOT)
            t == query || t.startsWith(query) || t.replace(" ", "").startsWith(query)
        }?.first
}
