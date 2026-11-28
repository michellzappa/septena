package app.septena.core

import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityLimits
import app.septena.core.generated.RegistryEntityNames
import app.septena.sharedcore.ParsedRef
import app.septena.sharedcore.parseRef
import app.septena.sharedcore.taskRefId
import java.net.URI
import java.net.URLEncoder
import java.nio.charset.StandardCharsets

/** One parsed `taskRef` row (`docs/TASK_REFERENCES_SPEC.md`, ADR 0031). */
data class TaskRefRecord(
    val id: String,
    val taskId: String,
    val key: String,
    val kind: String,
    val role: String,
    val title: String?,
    val subtitle: String?,
    val date: String?,
    val url: String?,
    val rawId: String?,
    val account: String?,
    val position: Double?,
    /** When the reference was added (`taskRef.createdAt`), or null. */
    val createdAt: String? = null,
) {
    /** The part of `key` after `<kind>:`. */
    val keyId: String
        get() = key.substringAfter(':', missingDelimiterValue = "")

    /** Display title falling back to a readable form of the key. */
    fun displayTitle(fallbackKindLabel: String): String =
        title?.takeIf(String::isNotBlank)
            ?: when (kind) {
                "issue" -> keyId
                "url" -> webTitle(keyId)
                else -> keyId.takeIf(String::isNotBlank) ?: fallbackKindLabel
            }

    /** Display subtitle falling back to URL host when title is distinct. */
    fun displaySubtitle(): String? {
        subtitle?.takeIf(String::isNotBlank)?.let { return it }
        if (kind == "url" && !title.isNullOrBlank()) {
            return runCatching { URI(keyId).host?.removePrefix("www.") }.getOrNull()
        }
        return null
    }

    companion object {
        /** Host and path, as Apple `TaskRef.title`. */
        internal fun webTitle(url: String): String {
            val uri = runCatching { URI(url) }.getOrNull()
            val host = uri?.host?.takeIf(String::isNotBlank) ?: return url
            return host + uri.path.orEmpty().takeIf { it != "/" }.orEmpty()
        }

        fun from(record: SyncRecord): TaskRefRecord? {
            if (record.entity != RegistryEntityNames.TASK_REF || record.deletedAt != null) return null
            val fields = record.fields
            val taskId = fields[RegistryEntityFields.TaskRef.TASK_ID].stringValue() ?: return null
            val key = fields[RegistryEntityFields.TaskRef.KEY].stringValue() ?: return null
            val kind = fields[RegistryEntityFields.TaskRef.KIND].stringValue()
                ?: key.substringBefore(':', missingDelimiterValue = "").takeIf(String::isNotBlank)
                ?: "url"
            val role = fields[RegistryEntityFields.TaskRef.ROLE].stringValue()
                ?: RegistryEntityEnums.TaskRefRole.ABOUT
            val snapshotObj = when (val rawSnap = fields[RegistryEntityFields.TaskRef.SNAPSHOT]) {
                is JsonValue.ObjectValue -> rawSnap.fields
                is JsonValue.StringValue -> runCatching {
                    (JsonValue.parse(rawSnap.value) as? JsonValue.ObjectValue)?.fields
                }.getOrNull()
                else -> null
            }.orEmpty()
            val pos = when (val p = fields[RegistryEntityFields.TaskRef.POSITION]) {
                is JsonValue.DecimalValue -> p.value
                is JsonValue.IntegerValue -> p.value.toDouble()
                else -> null
            }
            return TaskRefRecord(
                id = record.id,
                taskId = taskId,
                key = key,
                kind = kind,
                role = role,
                title = snapshotObj["title"].stringValue(),
                subtitle = snapshotObj["subtitle"].stringValue(),
                date = snapshotObj["date"].stringValue(),
                url = snapshotObj["url"].stringValue(),
                rawId = snapshotObj["rawId"].stringValue(),
                account = snapshotObj["account"].stringValue(),
                position = pos,
                createdAt = fields[RegistryEntityFields.TaskRef.CREATED_AT].stringValue(),
            )
        }
    }
}

/** What tapping a reference opens on Android (`docs/TASK_REFERENCES_SPEC.md` §5). */
sealed interface TaskRefTarget {
    /** Strictly `http` or `https` web URL, never another scheme. */
    data class Url(val url: String) : TaskRefTarget
    /** A Septena task in this account. */
    data class Task(val taskId: String) : TaskRefTarget
}

/** Resolves a reference key + snapshot to an Android open target (§5). */
object TaskRefResolver {
    fun canOpenWebUrl(url: String): Boolean {
        val trimmed = url.trim()
        if (trimmed.any(Char::isWhitespace)) return false
        val uri = runCatching { URI(trimmed) }.getOrNull() ?: return false
        val scheme = uri.scheme?.lowercase() ?: return false
        return (scheme == "http" || scheme == "https") && !uri.host.isNullOrBlank()
    }

    /**
     * The link a Review ▸ Tracked row shows (docs/REVIEW_SPEC.md §2, ADR 0066): the newest `issue`
     * reference that opens in the browser, else the first reference (in list order) that does.
     * Returns the reference and its web URL, or null.
     */
    fun trackedLink(refs: List<TaskRefRecord>): Pair<TaskRefRecord, String>? {
        fun webUrl(ref: TaskRefRecord): String? = (target(ref) { false } as? TaskRefTarget.Url)?.url
        val issue = refs.asSequence()
            .filter { it.kind == "issue" }
            .sortedWith(compareByDescending<TaskRefRecord> { it.createdAt.orEmpty() }.thenByDescending { it.position ?: 0.0 })
            .firstNotNullOfOrNull { ref -> webUrl(ref)?.let { ref to it } }
        if (issue != null) return issue
        return refs.sortedWith(compareBy<TaskRefRecord>({ it.position ?: Double.MAX_VALUE }, { it.id }))
            .firstNotNullOfOrNull { ref -> webUrl(ref)?.let { ref to it } }
    }

    fun target(ref: TaskRefRecord, hasTask: (String) -> Boolean): TaskRefTarget? {
        if (ref.kind == "task" && !ref.keyId.contains('/')) {
            if (hasTask(ref.keyId)) return TaskRefTarget.Task(ref.keyId)
        }
        keyUrl(ref)?.takeIf(::canOpenWebUrl)?.let { return TaskRefTarget.Url(it) }
        ref.url?.takeIf(::canOpenWebUrl)?.let { return TaskRefTarget.Url(it) }
        return null
    }

    private fun keyUrl(ref: TaskRefRecord): String? = when (ref.kind) {
        "issue" -> {
            val parts = ref.keyId.split('#', limit = 2)
            val repoParts = parts.firstOrNull()?.split('/')?.filter(String::isNotBlank).orEmpty()
            val num = parts.getOrNull(1)?.takeIf(String::isNotBlank)
            if (repoParts.size == 2 && num != null) {
                "https://github.com/${enc(repoParts[0])}/${enc(repoParts[1])}/issues/${enc(num)}"
            } else null
        }
        "url" -> ref.keyId.takeIf(::canOpenWebUrl)
        "task" -> {
            val slash = ref.keyId.indexOf('/')
            if (slash > 0 && slash < ref.keyId.lastIndex) {
                val host = ref.keyId.substring(0, slash)
                val id = ref.keyId.substring(slash + 1)
                "https://$host/work/task/${enc(id)}"
            } else null
        }
        "door" -> {
            val bar = ref.keyId.indexOf('|')
            if (bar > 0 && bar < ref.keyId.lastIndex) {
                val host = ref.keyId.substring(0, bar)
                val door = ref.keyId.substring(bar + 1)
                doorPath(door)?.let { segs -> "https://$host/${segs.joinToString("/") { enc(it) }}" }
            } else null
        }
        "email", "thread" -> {
            // Spec §5: Android opens email/thread via Gmail search when rawId/account is available.
            val msgId = ref.rawId?.takeIf(String::isNotBlank) ?: ref.keyId.takeIf(String::isNotBlank)
            if (msgId != null) {
                val query = enc("rfc822msgid:$msgId")
                val authUser = ref.account?.takeIf(String::isNotBlank)?.let { "?authuser=${enc(it)}" }.orEmpty()
                "https://mail.google.com/mail/u/0/$authUser#search/$query"
            } else null
        }
        else -> null
    }

    private fun doorPath(door: String): List<String>? {
        val parts = door.split(':', limit = 2)
        if (parts.size != 2 || parts[1].isBlank()) return null
        return when (parts[0]) {
            "subject" -> {
                val sub = parts[1].split(':', limit = 2)
                if (sub.size == 2 && sub[0].isNotBlank() && sub[1].isNotBlank()) listOf("work", sub[0], sub[1]) else null
            }
            "contact" -> listOf("work", "contact", parts[1])
            "document" -> listOf("docs", "document", parts[1])
            "event" -> listOf("calendar", "event", parts[1])
            "thread" -> listOf("team", "thread", parts[1])
            else -> null
        }
    }

    private fun enc(value: String): String =
        URLEncoder.encode(value, StandardCharsets.UTF_8.name()).replace("+", "%20")
}

/** One link of a task's own text, offered by Add Reference (§8). */
data class TaskRefOffer(
    val key: String,
    val input: String,
    val kind: String,
    val title: String,
)

/** The links in a task's title and notes that are not references yet (§8). */
object TaskRefOffers {
    private val link = Regex("""(?:https?://|message:)[^\s<>"]+""", RegexOption.IGNORE_CASE)

    /** In order, one per key. The core decides what each link is. */
    fun of(title: String, notes: String?, existing: List<TaskRefRecord>): List<TaskRefOffer> {
        val keys = existing.mapTo(HashSet()) { it.key }
        return listOf(title, notes.orEmpty()).flatMap(::linkTexts).mapNotNull { text ->
            val parsed = runCatching { parseRef(text) }.getOrNull() ?: return@mapNotNull null
            if (!keys.add(parsed.key)) return@mapNotNull null
            val label = when (parsed.kind) {
                "issue" -> parsed.id
                "url" -> TaskRefRecord.webTitle(parsed.id)
                else -> text
            }
            TaskRefOffer(parsed.key, text, parsed.kind, label)
        }
    }

    /** The offers an open task shows on its own. Nothing becomes a reference before a tap. */
    fun suggestions(
        title: String,
        notes: String?,
        existing: List<TaskRefRecord>,
        max: Int,
    ): List<TaskRefOffer> {
        val room = RegistryEntityLimits.MAX_REFS_PER_TASK.toInt() - existing.size
        return of(title, notes, existing).take(minOf(room, max).coerceAtLeast(0))
    }

    internal fun linkTexts(text: String): List<String> =
        link.findAll(text).map { trimmedEnd(it.value) }.filter(::canRead).toList()

    /** Sentence punctuation after a link, and the bracket that closes a Markdown link. */
    private fun trimmedEnd(found: String): String {
        var text = found
        while (text.isNotEmpty()) {
            val last = text.last()
            val closes = when (last) {
                ')' -> text.count { it == ')' } > text.count { it == '(' }
                ']' -> text.count { it == ']' } > text.count { it == '[' }
                else -> last in ".,;:!?'*_"
            }
            if (!closes) return text
            text = text.dropLast(1)
        }
        return text
    }

    private fun canRead(text: String): Boolean =
        text.startsWith("message:", ignoreCase = true) || TaskRefResolver.canOpenWebUrl(text)
}

sealed interface TaskRefAddResult {
    data class Added(val record: SyncRecord) : TaskRefAddResult
    data class Existing(val record: SyncRecord) : TaskRefAddResult
    data object Invalid : TaskRefAddResult
    data object LimitReached : TaskRefAddResult
    data object Failed : TaskRefAddResult
}

/**
 * Adds and removes task references using the shared Rust core (`parseRef`, `taskRefId`)
 * so Android and Apple mint identical normalized keys and deterministic IDs (ADR 0031).
 */
class TaskRefMutator(
    private val store: TaskStore,
    private val clock: DayClock,
    private val ids: TaskIdGenerator,
) {
    suspend fun add(
        taskId: String,
        input: String,
        role: String = RegistryEntityEnums.TaskRefRole.ABOUT,
    ): TaskRefAddResult {
        val trimmed = input.trim()
        if (trimmed.isEmpty()) return TaskRefAddResult.Invalid
        val task = store.record(RegistryEntityNames.TASK, taskId)
        if (task == null || task.deletedAt != null) return TaskRefAddResult.Failed

        val parsed: ParsedRef = runCatching { parseRef(trimmed) }.getOrNull() ?: return TaskRefAddResult.Invalid
        val allForTask = store.records(RegistryEntityNames.TASK_REF)
            .filter { it.fields[RegistryEntityFields.TaskRef.TASK_ID].stringValue() == taskId }
        val liveForTask = allForTask.filter { it.deletedAt == null }
        liveForTask.firstOrNull { it.fields[RegistryEntityFields.TaskRef.KEY].stringValue() == parsed.key }
            ?.let { return TaskRefAddResult.Existing(it) }
        if (liveForTask.size >= RegistryEntityLimits.MAX_REFS_PER_TASK.toInt()) {
            return TaskRefAddResult.LimitReached
        }

        val deletedCount = allForTask.count {
            it.deletedAt != null && it.fields[RegistryEntityFields.TaskRef.KEY].stringValue() == parsed.key
        }
        val refId = taskRefId(taskId, parsed.key, deletedCount.toUInt())
        val nextPosition = liveForTask.mapNotNull { r ->
            when (val p = r.fields[RegistryEntityFields.TaskRef.POSITION]) {
                is JsonValue.DecimalValue -> p.value
                is JsonValue.IntegerValue -> p.value.toDouble()
                else -> null
            }
        }.maxOrNull()?.plus(1.0) ?: 0.0

        val snapshotFields = linkedMapOf<String, JsonValue>()
        if (parsed.rawId.isNotBlank()) {
            snapshotFields["rawId"] = JsonValue.StringValue(parsed.rawId)
        }
        parsed.url?.takeIf(TaskRefResolver::canOpenWebUrl)?.let { url ->
            snapshotFields["url"] = JsonValue.StringValue(url)
            runCatching { URI(url).host?.removePrefix("www.") }.getOrNull()?.takeIf(String::isNotBlank)?.let { host ->
                snapshotFields["subtitle"] = JsonValue.StringValue(host)
            }
        }
        if (parsed.kind == "issue") {
            snapshotFields["title"] = JsonValue.StringValue(parsed.id)
        }
        val snapshotValue = JsonValue.ObjectValue(snapshotFields).takeIf {
            snapshotFields.isNotEmpty() &&
                JsonValue.ObjectValue(snapshotFields).canonicalJson().toByteArray(StandardCharsets.UTF_8).size <=
                RegistryEntityLimits.REF_SNAPSHOT_MAX.toInt()
        }

        val fields = linkedMapOf<String, JsonValue>(
            RegistryEntityFields.TaskRef.TASK_ID to JsonValue.StringValue(taskId),
            RegistryEntityFields.TaskRef.KEY to JsonValue.StringValue(parsed.key),
            RegistryEntityFields.TaskRef.ROLE to JsonValue.StringValue(role),
            RegistryEntityFields.TaskRef.POSITION to JsonValue.DecimalValue(nextPosition),
            RegistryEntityFields.TaskRef.CREATED_AT to JsonValue.StringValue(WireTimestamp.format(clock.now())),
        )
        if (snapshotValue != null) {
            fields[RegistryEntityFields.TaskRef.SNAPSHOT] = snapshotValue
        }

        RegistryValidator.requireValidUpsert(RegistryEntityNames.TASK_REF, refId, fields, insert = true)
        val storedRecord = SyncRecord(
            entity = RegistryEntityNames.TASK_REF,
            id = refId,
            fields = fields + (RegistryEntityFields.TaskRef.KIND to JsonValue.StringValue(parsed.kind)),
        )
        store.writeLocalAndEnqueue(
            storedRecord,
            SyncOperation.Upsert(ids.nextClientOpId(), RegistryEntityNames.TASK_REF, refId, fields),
        )
        return TaskRefAddResult.Added(storedRecord)
    }
}
