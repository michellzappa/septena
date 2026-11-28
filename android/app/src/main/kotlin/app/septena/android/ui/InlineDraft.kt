package app.septena.android.ui

import app.septena.android.AndroidAppGraph
import app.septena.core.JsonValue
import app.septena.core.ProjectChecklistRules
import app.septena.core.RegistryCatalog
import app.septena.core.SyncRecord
import app.septena.core.asSyncRecord
import app.septena.core.booleanValue
import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.stringValue
import app.septena.ui.TASK_ORDER_GAP
import java.time.DayOfWeek
import java.time.LocalDate
import java.time.temporal.TemporalAdjusters
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
    // A new Checklist item with no heading joins the core's suggested group (#860).
    taskMutator.placeChecklistItem(taskId, parsed.title) { group ->
        RegistryCatalog.checklistGroupTitle(group, Locale.getDefault().toLanguageTag())
    }
    taskStore.record(RegistryEntityNames.TASK, taskId)?.let { taskUndoHistory.recordCreated(it) }
    return InlineDraftCommit.Saved
}

/** One add-field suggestion of a Checklist draft (#860): a checked row to reopen, or an active row. */
internal data class ChecklistSuggestion(val taskId: String, val label: String, val isChecked: Boolean)

/**
 * The core's matches for [query] in Checklist project [projectId] (exact
 * title first), labelled "Greek yogurt · Dairy" for a checked row and
 * "Milk · On list" for an active one. Null when [projectId] is not a Checklist.
 */
internal suspend fun AndroidAppGraph.checklistSuggestions(
    projectId: String,
    query: String,
    languageTag: String,
): List<ChecklistSuggestion>? {
    val project = taskStore.record(RegistryEntityNames.PROJECT, projectId) ?: return null
    if (project.deletedAt != null || project.fields[RegistryEntityFields.Project.CHECKLIST_MODE].stringValue() == null) return null
    val typed = query.trim()
    if (typed.isEmpty()) return emptyList()
    val rows: List<SyncRecord> = taskStore.records(RegistryEntityNames.TASK)
        .filter { it.deletedAt == null && it.fields[RegistryEntityFields.Task.PROJECT].stringValue() == projectId }
        .sortedBy { it.fields[RegistryEntityFields.Task.POSITION].positionValue() ?: Double.MAX_VALUE }
    val byId = rows.associateBy(SyncRecord::id)
    val onList = checklistCopy("onList", languageTag)
    return ProjectChecklistRules.layout(rows, typed).matches.mapNotNull { id ->
        val row = byId[id] ?: return@mapNotNull null
        val title = row.fields[RegistryEntityFields.Task.TITLE].stringValue().orEmpty()
        val checked = row.fields[RegistryEntityFields.Task.STATUS].stringValue() ==
            RegistryEntityEnums.TaskStatus.CHECKLIST_CHECKED
        val group = row.fields[RegistryEntityFields.Task.HEADING].stringValue()
            ?.let { byId[it]?.fields?.get(RegistryEntityFields.Task.TITLE).stringValue() }
        val detail = if (checked) group else onList
        ChecklistSuggestion(id, detail?.let { "$title · $it" } ?: title, checked)
    }
}

/** The last suggestion: Add "<typed text>" (registry `checklistProjects.addTyped`). */
internal fun checklistAddTyped(typed: String, languageTag: String): String =
    checklistCopy("addTyped", languageTag).replace("{title}", typed)

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

    /** One tap-to-apply chip under a draft's title (Apple `DetectedToken`). */
    data class Detected(
        val kind: Kind,
        /** The words that leave the title when the chip is applied. */
        val phrase: String,
        val day: LocalDate? = null,
        val id: String? = null,
        val title: String? = null,
    )

    enum class Kind { Today, Date, Project, Area }

    /**
     * Apple `TaskTitleParser.detect`: the explicit tokens, then one date phrase
     * found in the title with the token words taken out (so `#friday-standup`
     * is never the day Friday).
     */
    fun detect(
        raw: String,
        projects: List<Pair<String, String>>,
        areas: List<Pair<String, String>>,
        today: LocalDate,
    ): List<Detected> {
        val tokens = mutableListOf<Detected>()
        for (word in raw.split(' ', '\n').filter(String::isNotEmpty)) {
            val lower = word.lowercase(Locale.ROOT)
            when {
                lower == "!today" || lower == "!t" -> tokens += Detected(Kind.Today, word)
                word.startsWith("#") && word.length > 1 ->
                    projects.firstOrNull { titleMatches(it.second, lower.drop(1)) }?.let { (id, title) ->
                        tokens += Detected(Kind.Project, word, id = id, title = title)
                    }
                word.startsWith("@") && word.length > 1 ->
                    areas.firstOrNull { titleMatches(it.second, lower.drop(1)) }?.let { (id, title) ->
                        tokens += Detected(Kind.Area, word, id = id, title = title)
                    }
            }
        }
        val withoutTokens = tokens.fold(raw) { text, token -> strip(token.phrase, text) }
        detectDate(withoutTokens, today)?.let { (day, phrase) -> tokens += Detected(Kind.Date, phrase, day = day) }
        return tokens
    }

    /** Takes [phrase] out of [text] (Apple `TaskTitleParser.strip`). */
    fun removing(phrase: String, text: String): String = strip(phrase, text)

    private val weekdays: Map<String, DayOfWeek> = buildMap {
        DayOfWeek.values().forEach { day -> put(day.name.lowercase(Locale.ROOT), day) }
        put("mon", DayOfWeek.MONDAY)
        put("tue", DayOfWeek.TUESDAY)
        put("tues", DayOfWeek.TUESDAY)
        put("wed", DayOfWeek.WEDNESDAY)
        put("thu", DayOfWeek.THURSDAY)
        put("thur", DayOfWeek.THURSDAY)
        put("thurs", DayOfWeek.THURSDAY)
        put("fri", DayOfWeek.FRIDAY)
    }

    private val months: Map<String, Int> = buildMap {
        listOf(
            "january", "february", "march", "april", "may", "june",
            "july", "august", "september", "october", "november", "december",
        ).forEachIndexed { i, name ->
            put(name, i + 1)
            if (name.length > 3) put(name.take(3), i + 1)
        }
        put("sept", 9)
    }

    private val weekdayPattern = weekdays.keys.sortedByDescending(String::length).joinToString("|")
    private val monthPattern = months.keys.sortedByDescending(String::length).joinToString("|")
    private val urlPattern = Regex("""\S+://\S+""")
    private fun rule(
        regex: Regex,
        resolve: (MatchResult, LocalDate) -> LocalDate?,
    ): Pair<Regex, (MatchResult, LocalDate) -> LocalDate?> = regex to resolve

    private val datePatterns: List<Pair<Regex, (MatchResult, LocalDate) -> LocalDate?>> = listOf(
        rule(Regex("""\b(today|tonight)\b""", RegexOption.IGNORE_CASE)) { _, today -> today },
        rule(Regex("""\btomorrow\b""", RegexOption.IGNORE_CASE)) { _, today -> today.plusDays(1) },
        rule(Regex("""\bnext week\b""", RegexOption.IGNORE_CASE)) { _, today -> today.plusWeeks(1) },
        rule(Regex("""\bin (\d{1,3}) (day|days|week|weeks)\b""", RegexOption.IGNORE_CASE)) { m, today ->
            val n = m.groupValues[1].toLong()
            if (m.groupValues[2].lowercase(Locale.ROOT).startsWith("week")) today.plusWeeks(n) else today.plusDays(n)
        },
        rule(Regex("""\b(?:(next|this|on) )?($weekdayPattern)\b""", RegexOption.IGNORE_CASE)) { m, today ->
            val day = weekdays.getValue(m.groupValues[2].lowercase(Locale.ROOT))
            if (m.groupValues[1].equals("next", ignoreCase = true)) {
                today.with(TemporalAdjusters.next(day))
            } else {
                today.with(TemporalAdjusters.nextOrSame(day))
            }
        },
        rule(Regex("""\b($monthPattern)\.? (\d{1,2})(?:st|nd|rd|th)?\b""", RegexOption.IGNORE_CASE)) { m, today ->
            monthDay(months.getValue(m.groupValues[1].lowercase(Locale.ROOT)), m.groupValues[2].toInt(), today)
        },
        rule(Regex("""\b(\d{1,2})(?:st|nd|rd|th)? ($monthPattern)\b""", RegexOption.IGNORE_CASE)) { m, today ->
            monthDay(months.getValue(m.groupValues[2].lowercase(Locale.ROOT)), m.groupValues[1].toInt(), today)
        },
    )

    /** The next [month]/[day] on or after [today], or null for an impossible date. */
    private fun monthDay(month: Int, day: Int, today: LocalDate): LocalDate? {
        val thisYear = runCatching { LocalDate.of(today.year, month, day) }.getOrNull() ?: return null
        return if (thisYear.isBefore(today)) runCatching { thisYear.plusYears(1) }.getOrNull() else thisYear
    }

    /**
     * One date phrase in [text], the earliest match (Apple uses `NSDataDetector`
     * and keeps a match only when it holds a letter; every phrase here does).
     * Words inside a link never count.
     */
    fun detectDate(text: String, today: LocalDate): Pair<LocalDate, String>? {
        val links = urlPattern.findAll(text).map { it.range }.toList()
        var best: Pair<MatchResult, LocalDate>? = null
        for ((pattern, resolve) in datePatterns) {
            for (match in pattern.findAll(text)) {
                if (links.any { match.range.first in it }) continue
                val day = resolve(match, today) ?: continue
                val current = best
                if (current == null || match.range.first < current.first.range.first ||
                    (match.range.first == current.first.range.first && match.value.length > current.first.value.length)
                ) {
                    best = match to day
                }
                break
            }
        }
        return best?.let { (match, day) -> day to match.value }
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
        candidates.firstOrNull { (_, title) -> titleMatches(title, query) }?.first

    private fun titleMatches(title: String, query: String): Boolean {
        val t = title.lowercase(Locale.ROOT)
        return t == query || t.startsWith(query) || t.replace(" ", "").startsWith(query)
    }
}
