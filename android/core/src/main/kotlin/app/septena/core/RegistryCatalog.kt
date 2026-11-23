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

/** The closed set of task page block kinds (surfaces.json `taskPage.blocks[].kind`, ADR 0029). */
object TaskPageBlockKinds {
    const val HEADER: String = "header"
    const val NOTES: String = "notes"
    const val ATTRIBUTES: String = "attributes"
    const val CHECKLIST: String = "checklist"
    const val ATTACHMENTS: String = "attachments"
    const val CONVERSATION: String = "conversation"
    const val HISTORY: String = "history"
}

/** The two depths of the task page (ADR 0029). */
object TaskPageDepths {
    const val INLINE: String = "inline"
    const val PAGE: String = "page"
}

/** One block of the task page, in registry order. [status] is the capability status of [featureId] on the platform. */
data class TaskPageBlock(
    val id: String,
    val kind: String,
    val depths: List<String>,
    val label: String?,
    val attribute: String?,
    val featureId: String,
    val editOnly: Boolean,
    val status: String?,
)

/** One task attribute (surfaces.json `taskAttributes`), in registry order. */
data class TaskAttribute(
    val id: String,
    val label: String,
    val featureId: String,
    val editOnly: Boolean,
)

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

    /**
     * The task attributes in registry order, with localized labels. The task page
     * `attributes` block renders these; it holds no list of its own (ADR 0029).
     */
    fun taskAttributes(languageTag: String = "en"): List<TaskAttribute> =
        document("surfaces").arrayAt(TASK_ATTRIBUTES_KEY).orEmpty().mapNotNull { raw ->
            val fields = raw as? JsonValue.ObjectValue ?: return@mapNotNull null
            val id = fields.stringAt("id") ?: return@mapNotNull null
            val label = fields.stringAt("label") ?: return@mapNotNull null
            TaskAttribute(
                id = id,
                label = localizedString(label, languageTag) ?: label,
                featureId = fields.stringAt("featureId").orEmpty(),
                editOnly = (fields.fields["editOnly"] as? JsonValue.BooleanValue)?.value == true,
            )
        }

    /**
     * The task page blocks for [depth], in registry order, with localized labels.
     * The capability gate drops a block whose feature is `not_applicable` on
     * [platform]. A `planned` block stays in the list: the platform decides if it
     * has a renderer for that kind, and [TaskPageBlock.status] tells it the claim.
     */
    fun taskPageBlocks(
        depth: String,
        platform: String = RegistryPlatformIds.ANDROID,
        languageTag: String = "en",
    ): List<TaskPageBlock> {
        val page = document("surfaces").objectAt(TASK_PAGE_KEY) ?: return emptyList()
        return page.arrayAt("blocks").orEmpty().mapNotNull { raw ->
            val fields = raw as? JsonValue.ObjectValue ?: return@mapNotNull null
            val id = fields.stringAt("id") ?: return@mapNotNull null
            val kind = fields.stringAt("kind") ?: return@mapNotNull null
            val featureId = fields.stringAt("featureId") ?: return@mapNotNull null
            val depths = fields.arrayAt("depths").orEmpty().mapNotNull { it.stringValue() }
            if (depth !in depths) return@mapNotNull null
            val status = capabilityStatus(featureId, platform)
            if (status == CAPABILITY_NOT_APPLICABLE) return@mapNotNull null
            TaskPageBlock(
                id = id,
                kind = kind,
                depths = depths,
                label = fields.stringAt("label")?.let { localizedString(it, languageTag) ?: it },
                attribute = fields.stringAt("attribute"),
                featureId = featureId,
                editOnly = (fields.fields["editOnly"] as? JsonValue.BooleanValue)?.value == true,
                status = status,
            )
        }
    }

    /** The section heading of a block: its own label, else the label of its attribute. */
    fun taskPageBlockHeading(block: TaskPageBlock, languageTag: String = "en"): String? =
        block.label ?: block.attribute?.let { attribute ->
            taskAttributes(languageTag).firstOrNull { it.id == attribute }?.label
        }

    /** The task attribute that an action opens (actions.json `opensAttribute`), or null. */
    fun actionOpensAttribute(actionId: String): String? = action(actionId)?.stringAt("opensAttribute")

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

    private const val TASK_ATTRIBUTES_KEY = "taskAttributes"
    private const val TASK_PAGE_KEY = "taskPage"
    private const val CAPABILITY_NOT_APPLICABLE = "not_applicable"
    private const val DESTINATION_INLINE_CREATE_FIELD = "supportsInlineCreate"
    private const val ACTION_ADD_TITLE_FIELD = "addTitle"
}
