package app.septena.core

import app.septena.core.generated.RegistrySettingKeys

enum class SmartListSection(val wireValue: String) {
    TOP("top"),
    BOTTOM("bottom");

    companion object {
        fun fromWire(raw: String?): SmartListSection? = entries.firstOrNull { it.wireValue == raw }
    }
}

data class SmartListDescriptor(
    val id: String,
    val defaultSection: SmartListSection,
    val visibility: String,
    val canHide: Boolean,
    val canMoveSection: Boolean,
)

/**
 * Cross-platform resolution for per-account smart-list ordering, show/hide,
 * and top/bottom section placement (`registry/destinations.json` +
 * `registry/settings.json`). Mirrors Swift `SmartListPreferences` 1:1.
 */
object SmartListResolver {
    fun sidebarDestinations(): List<SmartListDescriptor> {
        val list = (RegistryCatalog.document("destinations").fields["destinations"] as? JsonValue.ArrayValue)
            ?.values.orEmpty()
        return list.mapNotNull { raw ->
            val obj = raw as? JsonValue.ObjectValue ?: return@mapNotNull null
            val visibility = obj.fields["visibility"].stringValue() ?: return@mapNotNull null
            if (visibility == "todayBand") return@mapNotNull null
            val id = obj.fields["id"].stringValue() ?: return@mapNotNull null
            val section = SmartListSection.fromWire(obj.fields["sidebarSection"].stringValue())
                ?: SmartListSection.TOP
            val canHide = (obj.fields["canHide"] as? JsonValue.BooleanValue)?.value ?: true
            val canMoveSection = (obj.fields["canMoveSection"] as? JsonValue.BooleanValue)?.value ?: true
            SmartListDescriptor(
                id = id,
                defaultSection = section,
                visibility = visibility,
                canHide = canHide,
                canMoveSection = canMoveSection,
            )
        }
    }

    fun ordered(order: List<String>): List<SmartListDescriptor> {
        val all = sidebarDestinations()
        val byId = all.associateBy(SmartListDescriptor::id)
        val result = mutableListOf<SmartListDescriptor>()
        val seen = linkedSetOf<String>()
        for (id in order) {
            val dest = byId[id]
            if (dest != null && seen.add(id)) result += dest
        }
        for (dest in all) {
            if (seen.add(dest.id)) result += dest
        }
        return result
    }

    fun sectionFor(
        dest: SmartListDescriptor,
        placement: Map<String, String>,
    ): SmartListSection {
        if (!dest.canMoveSection) return dest.defaultSection
        return SmartListSection.fromWire(placement[dest.id]) ?: dest.defaultSection
    }

    fun isHidden(dest: SmartListDescriptor, hidden: Set<String>): Boolean =
        dest.canHide && dest.id in hidden

    fun visible(
        order: List<String>,
        hidden: Set<String>,
        placement: Map<String, String>,
        nonEmptyIds: Set<String>,
        section: SmartListSection? = null,
    ): List<SmartListDescriptor> =
        ordered(order).filter { dest ->
            if (isHidden(dest, hidden)) return@filter false
            if (dest.visibility == "whenNonEmpty" && dest.id !in nonEmptyIds) return@filter false
            if (section != null && sectionFor(dest, placement) != section) return@filter false
            true
        }

    suspend fun visibleFromSynced(
        settings: SyncedSettings,
        nonEmptyIds: Set<String>,
        section: SmartListSection? = null,
    ): List<SmartListDescriptor> {
        val order = (settings.value(RegistrySettingKeys.SMART_LIST_ORDER) as? JsonValue.ArrayValue)
            ?.values?.mapNotNull { it.stringValue() }.orEmpty()
        val hidden = (settings.value(RegistrySettingKeys.SMART_LIST_HIDDEN) as? JsonValue.ArrayValue)
            ?.values?.mapNotNull { it.stringValue() }?.toSet().orEmpty()
        val placement = (settings.value(RegistrySettingKeys.SMART_LIST_PLACEMENT) as? JsonValue.ObjectValue)
            ?.fields?.mapNotNull { (k, v) -> v.stringValue()?.let { k to it } }?.toMap().orEmpty()
        return visible(order, hidden, placement, nonEmptyIds, section)
    }
}

/**
 * One account's smart-list layout: order, hidden lists and top/bottom placement
 * (`smartListOrder`, `smartListHidden`, `smartListPlacement`). The edits mirror Swift
 * `SmartListPreferences` (setHidden, setSection, moveInSection, resetToDefaults); each
 * returns the new layout, and the caller writes the changed keys through the mutator.
 */
data class SmartListLayout(
    val order: List<String> = emptyList(),
    val hidden: Set<String> = emptySet(),
    val placement: Map<String, String> = emptyMap(),
) {
    fun ordered(): List<SmartListDescriptor> = SmartListResolver.ordered(order)

    fun sectionOf(dest: SmartListDescriptor): SmartListSection = SmartListResolver.sectionFor(dest, placement)

    fun inSection(section: SmartListSection): List<SmartListDescriptor> = ordered().filter { sectionOf(it) == section }

    fun isHidden(dest: SmartListDescriptor): Boolean = SmartListResolver.isHidden(dest, hidden)

    /** Visibility, placement or order differs from the registry defaults. */
    val isCustomized: Boolean
        get() = hidden.isNotEmpty() || placement.isNotEmpty() ||
            ordered().map(SmartListDescriptor::id) != SmartListResolver.sidebarDestinations().map(SmartListDescriptor::id)

    fun setHidden(dest: SmartListDescriptor, hide: Boolean): SmartListLayout {
        if (!dest.canHide) return this
        return copy(hidden = if (hide) hidden + dest.id else hidden - dest.id)
    }

    fun setSection(dest: SmartListDescriptor, target: SmartListSection): SmartListLayout {
        if (!dest.canMoveSection) return this
        return copy(
            placement = if (target == dest.defaultSection) placement - dest.id else placement + (dest.id to target.wireValue),
        )
    }

    /** Moves the list at [from] to [to] inside [section]; the other section keeps its slots. */
    fun moveInSection(section: SmartListSection, from: Int, to: Int): SmartListLayout {
        val ids = inSection(section).map(SmartListDescriptor::id).toMutableList()
        if (from !in ids.indices || to !in ids.indices || from == to) return this
        ids.add(to, ids.removeAt(from))
        val iterator = ids.iterator()
        val rebuilt = ordered().map { dest ->
            if (sectionOf(dest) == section && iterator.hasNext()) iterator.next() else dest.id
        }
        return copy(order = rebuilt)
    }

    fun orderJson(): JsonValue = JsonValue.ArrayValue(order.map(JsonValue::StringValue))

    fun hiddenJson(): JsonValue = JsonValue.ArrayValue(hidden.sorted().map(JsonValue::StringValue))

    fun placementJson(): JsonValue = JsonValue.ObjectValue(placement.mapValues { JsonValue.StringValue(it.value) })

    companion object {
        val DEFAULT = SmartListLayout()

        fun from(order: JsonValue?, hidden: JsonValue?, placement: JsonValue?): SmartListLayout = SmartListLayout(
            order = (order as? JsonValue.ArrayValue)?.values?.mapNotNull { it.stringValue() }.orEmpty(),
            hidden = (hidden as? JsonValue.ArrayValue)?.values?.mapNotNull { it.stringValue() }?.toSet().orEmpty(),
            placement = (placement as? JsonValue.ObjectValue)?.fields
                ?.mapNotNull { (k, v) -> v.stringValue()?.let { k to it } }?.toMap().orEmpty(),
        )
    }
}
