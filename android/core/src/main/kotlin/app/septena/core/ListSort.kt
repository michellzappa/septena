package app.septena.core

import app.septena.core.generated.RegistryEntityEnums
import app.septena.core.generated.RegistrySettingKeys
import app.septena.core.generated.RegistrySurfaceIds
import app.septena.sharedcore.invokeJson

/** One Sort By choice: its `listSort` value and its localized title (registry/settings.json `listSort.options`). */
data class ListSortOption(val value: String, val title: String)

/** The Sort By copy from registry/surfaces.json `listSort` and the options from registry/settings.json. */
data class ListSortCopy(
    val menuTitle: String,
    /** The registry icon id of the menu (icons.json). */
    val icon: String,
    val options: List<ListSortOption>,
    private val sortedByTemplate: String,
) {
    fun title(sort: String): String = options.firstOrNull { it.value == sort }?.title ?: sort

    /** "Sorted by <label>" for the list header, or null for Manual. */
    fun sortedBy(sort: String): String? =
        if (sort == RegistryEntityEnums.ListSort.MANUAL) null else sortedByTemplate.replace("{sort}", title(sort))

    companion object {
        fun fromRegistry(languageTag: String): ListSortCopy {
            val surface = RegistryCatalog.surface(RegistrySurfaceIds.LIST_SORT)?.fields.orEmpty()
            fun text(raw: String?): String = raw?.let { RegistryCatalog.localizedString(it, languageTag) ?: it }.orEmpty()
            val options = (RegistryCatalog.setting(RegistrySettingKeys.LIST_SORT)?.fields?.get("options") as? JsonValue.ArrayValue)
                ?.values.orEmpty()
                .mapNotNull { it as? JsonValue.ObjectValue }
                .mapNotNull { option ->
                    val value = option.fields["value"].stringValue() ?: return@mapNotNull null
                    ListSortOption(value, text(option.fields["title"].stringValue() ?: value))
                }
            return ListSortCopy(
                menuTitle = text(surface["menuTitle"].stringValue()),
                icon = surface["icon"].stringValue().orEmpty(),
                options = options,
                sortedByTemplate = text(surface["sortedBy"].stringValue()),
            )
        }
    }
}

/**
 * The per-list Sort By choices of one account: the synced record setting `listSort`
 * (docs/LIST_SORT_SPEC.md §5). Key: a destination id, `project:<id>` or `area:<id>`.
 * Manual is the absence of a key. Read and written like `smartListPlacement`.
 */
data class ListSortPreferences(val sorts: Map<String, String> = emptyMap()) {
    /** The sort of the list with [key], Manual when unset. */
    fun sortFor(key: String?): String =
        key?.let(sorts::get) ?: RegistryEntityEnums.ListSort.MANUAL

    /**
     * Sets [sort] on [key]. Manual removes the key. Keys of projects and areas that no
     * longer exist are dropped, and the oldest keys go when the record is over its limit.
     */
    fun setting(
        key: String,
        sort: String,
        liveProjectIds: Set<String>,
        liveAreaIds: Set<String>,
    ): ListSortPreferences {
        val next = LinkedHashMap<String, String>()
        for ((k, v) in sorts) {
            if (k == key) continue
            if (k.startsWith(PROJECT_PREFIX) && k.removePrefix(PROJECT_PREFIX) !in liveProjectIds) continue
            if (k.startsWith(AREA_PREFIX) && k.removePrefix(AREA_PREFIX) !in liveAreaIds) continue
            next[k] = v
        }
        if (sort != RegistryEntityEnums.ListSort.MANUAL && sort in VALUES) next[key] = sort
        val limit = maxEntries()
        while (limit != null && next.size > limit) {
            val oldest = next.keys.firstOrNull { it != key } ?: break
            next.remove(oldest)
        }
        return ListSortPreferences(next)
    }

    fun toJson(): JsonValue = JsonValue.ObjectValue(sorts.mapValues { JsonValue.StringValue(it.value) })

    companion object {
        private const val PROJECT_PREFIX = "project:"
        private const val AREA_PREFIX = "area:"
        /** The values of the setting's enum (settings.json `listSort.enum` → entities.json). */
        private val VALUES: Set<String> by lazy {
            val enumName = RegistryCatalog.setting(RegistrySettingKeys.LIST_SORT)?.fields?.get("enum").stringValue()
            enumName?.let(RegistryEntityEnums.all::get).orEmpty().toSet()
        }

        /** Reads the stored record; a value that is not a known sort, or Manual, reads as unset. */
        fun from(value: JsonValue?): ListSortPreferences = ListSortPreferences(
            (value as? JsonValue.ObjectValue)?.fields.orEmpty()
                .mapNotNull { (k, v) ->
                    v.stringValue()?.takeIf { it in VALUES && it != RegistryEntityEnums.ListSort.MANUAL }?.let { k to it }
                }
                .toMap(LinkedHashMap()),
        )

        suspend fun fromSynced(settings: SyncedSettings): ListSortPreferences =
            runCatching { from(settings.value(RegistrySettingKeys.LIST_SORT)) }.getOrDefault(ListSortPreferences())

        /** The key of a smart list, or null when it has a fixed order (destinations.json `supportsManualOrder`). */
        fun smartListKey(destinationId: String): String? =
            destinationId.takeIf {
                (RegistryCatalog.destination(it)?.fields?.get("supportsManualOrder") as? JsonValue.BooleanValue)?.value == true
            }

        fun projectKey(id: String): String = PROJECT_PREFIX + id

        fun areaKey(id: String): String = AREA_PREFIX + id

        private fun maxEntries(): Int? =
            RegistryCatalog.setting(RegistrySettingKeys.LIST_SORT)?.fields?.get("maxEntries").longValue()?.toInt()
    }
}

/**
 * Sort By, from the shared core (`sort.rs`, `sortTasks`), verified by
 * registry/conformance/list-sort.json. The comparison lives only in the core:
 * this file passes tasks in and reads ids out. JSON entry point only.
 */
object ListSortRules {
    private const val SORT_TASKS = "sortTasks"

    /**
     * The ids of [tasks] (one group, in manual order) in [sort] order. Manual, or any
     * failure of the linked core (a core without `sortTasks` included), returns the input order.
     */
    fun sortedIds(tasks: List<TaskSnapshot>, sort: String): List<String> {
        val manual = tasks.map(TaskSnapshot::id)
        if (sort == RegistryEntityEnums.ListSort.MANUAL || tasks.size < 2) return manual
        return runCatching {
            val input = JsonValue.ObjectValue(
                linkedMapOf(
                    "tasks" to JsonValue.ArrayValue(tasks.map(::snapshotJson)),
                    "sort" to JsonValue.StringValue(sort),
                ),
            )
            val out = JsonValue.parse(invokeJson(SORT_TASKS, input.canonicalJson())) as JsonValue.ArrayValue
            val ids = out.values.map { requireNotNull(it.stringValue()) }
            // Only a permutation of the input is a valid answer.
            require(ids.size == manual.size && ids.toSet() == manual.toSet())
            ids
        }.getOrDefault(manual)
    }

    /**
     * Sorts [items] (in manual order) inside each run of the same [groupKey]. Groups keep their
     * order; rows where [isFixed] holds (completed rows) keep their slot. A row without a
     * snapshot is fixed too. [pinnedId] (a row in inline edit) keeps its slot in [previousIds],
     * the order the list showed before, until the edit ends.
     */
    fun <T> sortInGroups(
        items: List<T>,
        sort: String,
        id: (T) -> String,
        groupKey: (T) -> String?,
        snapshot: (T) -> TaskSnapshot?,
        isFixed: (T) -> Boolean = { false },
        pinnedId: String? = null,
        previousIds: List<String> = emptyList(),
    ): List<T> {
        if (sort == RegistryEntityEnums.ListSort.MANUAL || items.size < 2) return items
        val result = ArrayList<T>(items.size)
        var start = 0
        while (start < items.size) {
            val key = groupKey(items[start])
            var end = start + 1
            while (end < items.size && groupKey(items[end]) == key) end += 1
            result += sortRun(items.subList(start, end), sort, id, snapshot, isFixed)
            start = end
        }
        return pin(result, pinnedId, previousIds, id)
    }

    private fun <T> sortRun(
        run: List<T>,
        sort: String,
        id: (T) -> String,
        snapshot: (T) -> TaskSnapshot?,
        isFixed: (T) -> Boolean,
    ): List<T> {
        val movable = run.filter { !isFixed(it) && snapshot(it) != null }
        if (movable.size < 2) return run
        val byId = movable.associateBy(id)
        val order = sortedIds(movable.map { requireNotNull(snapshot(it)) }, sort).mapNotNull(byId::get).iterator()
        return run.map { item -> if (!isFixed(item) && snapshot(item) != null && order.hasNext()) order.next() else item }
    }

    private fun <T> pin(sorted: List<T>, pinnedId: String?, previousIds: List<String>, id: (T) -> String): List<T> {
        if (pinnedId == null) return sorted
        val pinned = sorted.firstOrNull { id(it) == pinnedId } ?: return sorted
        val present = sorted.mapTo(HashSet(), id)
        val slot = previousIds.filter { it in present }.indexOf(pinnedId)
        if (slot < 0) return sorted
        val rest = sorted.filter { id(it) != pinnedId }.toMutableList()
        rest.add(slot.coerceAtMost(rest.size), pinned)
        return rest
    }

    private fun snapshotJson(task: TaskSnapshot): JsonValue = JsonValue.ObjectValue(
        linkedMapOf(
            "id" to JsonValue.StringValue(task.id),
            "title" to JsonValue.StringValue(task.title),
            "status" to JsonValue.StringValue(task.status),
            "kind" to JsonValue.stringOrNull(task.kind),
            "created" to JsonValue.stringOrNull(task.created),
            "createdAt" to JsonValue.stringOrNull(task.createdAt),
            "scheduled" to JsonValue.stringOrNull(task.scheduled),
            "deadline" to JsonValue.stringOrNull(task.deadline),
        ),
    )
}
