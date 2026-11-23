package app.septena.core

import app.septena.core.generated.RegistryCapabilities
import app.septena.core.generated.RegistryDocuments
import app.septena.core.generated.RegistryPlatformIds

data class FeatureCapability(
    val id: String,
    val title: String,
    val statusByPlatform: Map<String, String>,
) {
    fun status(platform: String): String? = statusByPlatform[platform]
}

/** Runtime view over the complete generated registries. No Android-only copy of product contracts. */
object RegistryCatalog {
    private val documents: Map<String, JsonValue.ObjectValue> by lazy {
        linkedMapOf(
            "entities" to RegistryDocuments.entitiesJson,
            "rules" to RegistryDocuments.rulesJson,
            "icons" to RegistryDocuments.iconsJson,
            "tokens" to RegistryDocuments.tokensJson,
            "capabilities" to RegistryDocuments.capabilitiesJson,
            "settings" to RegistryDocuments.settingsJson,
            "destinations" to RegistryDocuments.destinationsJson,
            "actions" to RegistryDocuments.actionsJson,
            "surfaces" to RegistryDocuments.surfacesJson,
            "conformance" to RegistryDocuments.conformanceJson,
            "localizations" to RegistryDocuments.localizationsJson,
        ).mapValues { (_, json) ->
            JsonValue.parse(json) as? JsonValue.ObjectValue
                ?: error("Generated registry document must be a JSON object")
        }
    }

    fun document(name: String): JsonValue.ObjectValue =
        documents[name] ?: error("Unknown generated registry document '$name'")

    fun capabilityStatus(featureId: String, platform: String = RegistryPlatformIds.ANDROID): String? {
        val feature = RegistryCapabilities.statusByFeatureAndPlatform[featureId] ?: return null
        return feature[platform]
    }

    fun capabilities(platform: String = RegistryPlatformIds.ANDROID): List<FeatureCapability> {
        val source = document("capabilities").objectAt("capabilities") ?: return emptyList()
        return source.mapNotNull { (id, raw) ->
            val fields = raw as? JsonValue.ObjectValue ?: return@mapNotNull null
            val title = fields.stringAt("title") ?: return@mapNotNull null
            val statuses = fields.mapNotNull { (key, value) ->
                if (key == "title") return@mapNotNull null
                value.stringValue()?.let { key to it }
            }.toMap()
            if (platform !in statuses) return@mapNotNull null
            FeatureCapability(id = id, title = title, statusByPlatform = statuses)
        }
    }

    fun action(id: String): JsonValue.ObjectValue? =
        document("actions").objectAt("actions")?.get(id) as? JsonValue.ObjectValue

    fun setting(key: String): JsonValue.ObjectValue? =
        document("settings").objectAt("keys")?.get(key) as? JsonValue.ObjectValue

    fun syncedSettingKeys(platform: String = RegistryPlatformIds.ANDROID): List<String> =
        document("settings").objectAt("keys")?.fields?.mapNotNull { (key, raw) ->
            val definition = raw as? JsonValue.ObjectValue ?: return@mapNotNull null
            val scope = definition.stringAt("scope")
            val platforms = (definition.fields["platforms"] as? JsonValue.ArrayValue)
                ?.values?.mapNotNull { it.stringValue() }.orEmpty()
            key.takeIf { scope == "synced" && platform in platforms }
        }.orEmpty()

    fun destination(id: String): JsonValue.ObjectValue? =
        document("destinations").arrayAt("destinations")
            ?.firstNotNullOfOrNull { item ->
                (item as? JsonValue.ObjectValue)?.takeIf { it.stringAt("id") == id }
            }

    fun destinationTitle(id: String, languageTag: String = "en"): String? =
        destination(id)?.stringAt("title")?.let { localizedString(it, languageTag) ?: it }

    fun destinationSupportsInlineCreate(id: String): Boolean =
        (destination(id)?.fields?.get(DESTINATION_INLINE_CREATE_FIELD) as? JsonValue.BooleanValue)?.value == true

    fun destinationEmptyTitle(id: String, languageTag: String = "en"): String? =
        destination(id)?.objectAt("emptyState")?.stringAt("title")?.let { localizedString(it, languageTag) ?: it }

    fun actionTitle(id: String, field: String = "title", languageTag: String = "en"): String? =
        action(id)?.stringAt(field)?.let { localizedString(it, languageTag) ?: it }

    fun actionAddTitle(id: String, languageTag: String = "en"): String? =
        actionTitle(id, field = ACTION_ADD_TITLE_FIELD, languageTag = languageTag)

    fun capabilityTitle(id: String, languageTag: String = "en"): String? =
        capabilities(RegistryPlatformIds.ANDROID).firstOrNull { it.id == id }?.title
            ?.let { localizedString(it, languageTag) ?: it }

    fun surface(id: String): JsonValue.ObjectValue? = findObjectWithId(document("surfaces"), id)

    fun localizedString(key: String, languageTag: String = "en"): String? {
        val translations = document("localizations")
        val locale = translations.fields.keys.firstOrNull { it.equals(languageTag, ignoreCase = true) }
            ?: translations.fields.keys.firstOrNull {
                it.substringBefore('-').equals(languageTag.substringBefore('-'), ignoreCase = true)
            }
        val selected = locale?.let { translations.objectAt(it) }
        fun text(value: JsonValue?): String? = when (value) {
            is JsonValue.StringValue -> value.value
            is JsonValue.ObjectValue -> value.stringAt("text")
            else -> null
        }
        return text(selected?.fields?.get(key)) ?: text(translations.objectAt("en")?.fields?.get(key))
    }

    private fun JsonValue.ObjectValue.objectAt(key: String): JsonValue.ObjectValue? =
        fields[key] as? JsonValue.ObjectValue

    private fun JsonValue.ObjectValue.stringAt(key: String): String? =
        fields[key].stringValue()

    private fun JsonValue.ObjectValue.arrayAt(key: String): List<JsonValue>? =
        (fields[key] as? JsonValue.ArrayValue)?.values

    private fun findObjectWithId(value: JsonValue, id: String): JsonValue.ObjectValue? = when (value) {
        is JsonValue.ObjectValue -> {
            if (value.stringAt("id") == id) value
            else value.fields.values.firstNotNullOfOrNull { findObjectWithId(it, id) }
        }
        is JsonValue.ArrayValue -> value.values.firstNotNullOfOrNull { findObjectWithId(it, id) }
        else -> null
    }

    private const val DESTINATION_INLINE_CREATE_FIELD = "supportsInlineCreate"
    private const val ACTION_ADD_TITLE_FIELD = "addTitle"
}
