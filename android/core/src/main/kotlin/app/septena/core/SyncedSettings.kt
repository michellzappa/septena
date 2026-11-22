package app.septena.core

import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.generated.RegistryPlatformIds

/** Synced settings use the same `setting` rows and defaults declared in `registry/settings.json`. */
class SyncedSettings(private val store: TaskStore, private val platform: String = RegistryPlatformIds.ANDROID) {
    suspend fun value(key: String): JsonValue {
        val definition = RegistryCatalog.setting(key)
            ?: throw IllegalArgumentException("Unknown registry setting '$key'")
        require(definition.appliesTo(platform)) { "Setting '$key' is not available on $platform" }
        val saved = store.record(RegistryEntityNames.SETTING, key)
            ?.fields?.get(RegistryEntityFields.Setting.VALUE)
        return if (saved == null || saved === JsonValue.Null) definition.defaultValue() else saved
    }

    suspend fun all(): Map<String, JsonValue> {
        val keys = RegistryCatalog.syncedSettingKeys(platform)
        val persisted = store.records(RegistryEntityNames.SETTING).associateBy(SyncRecord::id)
        return keys.associateWith { key ->
            val saved = persisted[key]?.fields?.get(RegistryEntityFields.Setting.VALUE)
            val value = if (saved == null || saved === JsonValue.Null) {
                RegistryCatalog.setting(key)?.defaultValue() ?: JsonValue.Null
            } else {
                saved
            }
            value
        }
    }

    private fun JsonValue.ObjectValue.appliesTo(platform: String): Boolean =
        stringSetAt("platforms").contains(platform) && stringAt("scope") == "synced"

    private fun JsonValue.ObjectValue.defaultValue(): JsonValue = fields["default"] ?: JsonValue.Null

    private fun JsonValue.ObjectValue.stringAt(key: String): String? = fields[key].stringValue()

    private fun JsonValue.ObjectValue.stringSetAt(key: String): Set<String> =
        (fields[key] as? JsonValue.ArrayValue)?.values?.mapNotNull { it.stringValue() }?.toSet().orEmpty()
}

/** Settings writes still pass through a mutator and join the same persistent outbox as task edits. */
class SyncedSettingsMutator(
    private val store: TaskStore,
    private val ids: TaskIdGenerator,
    private val platform: String = RegistryPlatformIds.ANDROID,
) {
    suspend fun set(key: String, value: JsonValue): SyncRecord {
        val definition = RegistryCatalog.setting(key)
            ?: throw IllegalArgumentException("Unknown registry setting '$key'")
        require(definition.stringAt("scope") == "synced") {
            "Device-only setting '$key' cannot be written to the sync store"
        }
        require(definition.stringSetAt("platforms").contains(platform)) {
            "Setting '$key' is not available on $platform"
        }
        val fields = mapOf(RegistryEntityFields.Setting.VALUE to value)
        RegistryValidator.requireValidUpsert(RegistryEntityNames.SETTING, key, fields, insert = false)
        val existing = store.record(RegistryEntityNames.SETTING, key)
        val updated = SyncRecord(
            entity = RegistryEntityNames.SETTING,
            id = key,
            fields = existing?.fields.orEmpty() + fields,
            revision = existing?.revision,
            updatedAt = existing?.updatedAt,
        )
        store.writeLocalAndEnqueue(
            record = updated,
            operation = SyncOperation.Upsert(ids.nextClientOpId(), RegistryEntityNames.SETTING, key, fields),
        )
        return updated
    }

    private fun JsonValue.ObjectValue.stringAt(key: String): String? = fields[key].stringValue()

    private fun JsonValue.ObjectValue.stringSetAt(key: String): Set<String> =
        (fields[key] as? JsonValue.ArrayValue)?.values?.mapNotNull { it.stringValue() }?.toSet().orEmpty()
}

