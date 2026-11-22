package app.septena.core

/** Selection facts needed to evaluate the canonical availability rules in `registry/actions.json`. */
data class RegistryActionContext(
    val platform: String,
    val destinationId: String?,
    val selectedCount: Int,
    val hasRecurrence: Boolean = false,
)

/** Resolves action IDs from the shared registry; app code binds those IDs to mutators. */
object RegistryActionResolver {
    fun availableActionIds(context: RegistryActionContext): List<String> {
        require(context.selectedCount >= 0) { "Selection count cannot be negative" }
        val actions = RegistryCatalog.document("actions").objectAt("actions") ?: return emptyList()
        return actions.mapNotNull { (id, raw) ->
            val action = raw as? JsonValue.ObjectValue ?: return@mapNotNull null
            val availability = action.objectAt("availability") ?: JsonValue.ObjectValue(emptyMap())
            if (matches(availability, context)) id else null
        }
    }

    fun isAvailable(actionId: String, context: RegistryActionContext): Boolean =
        actionId in availableActionIds(context)

    private fun matches(availability: JsonValue.ObjectValue, context: RegistryActionContext): Boolean {
        val selection = availability.stringAt("selection") ?: "any"
        val selectionMatches = when (selection) {
            "single" -> context.selectedCount == 1
            "none" -> context.selectedCount == 0
            "any" -> context.selectedCount > 0
            else -> false
        }
        if (!selectionMatches) return false

        val platforms = availability.stringSetAt("platforms")
        if (platforms.isNotEmpty() && context.platform !in platforms) return false
        if (context.platform in availability.stringSetAt("excludePlatforms")) return false

        val onlyDestinations = availability.stringSetAt("onlyDestinations")
        val destination = context.destinationId
        if (onlyDestinations.isNotEmpty() && (destination == null || destination !in onlyDestinations)) return false
        if (destination != null && destination in availability.stringSetAt("excludeDestinations")) return false

        val requiresRecurrence = availability.booleanAt("requiresRecurrence") == true
        if (requiresRecurrence && !context.hasRecurrence) return false
        return true
    }

    private fun JsonValue.ObjectValue.objectAt(key: String): JsonValue.ObjectValue? =
        fields[key] as? JsonValue.ObjectValue

    private fun JsonValue.ObjectValue.stringAt(key: String): String? = fields[key].stringValue()

    private fun JsonValue.ObjectValue.booleanAt(key: String): Boolean? = fields[key].booleanValue()

    private fun JsonValue.ObjectValue.stringSetAt(key: String): Set<String> =
        (fields[key] as? JsonValue.ArrayValue)?.values?.mapNotNull { it.stringValue() }?.toSet().orEmpty()
}
