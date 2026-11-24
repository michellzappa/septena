package app.septena.android.ui

import android.content.SharedPreferences
import app.septena.android.sync.SyncController
import app.septena.core.DayClock
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.SyncedSettings
import app.septena.core.SyncedSettingsMutator
import app.septena.core.booleanValue
import app.septena.core.longValue
import app.septena.core.generated.RegistrySettingKeys
import app.septena.core.stringValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * The user's appearance choices (ADR 0019, docs/CUSTOMIZATION_SPEC.md), as the
 * iPhone's `AppearancePreferences` holds them.
 *
 * Wire values are the enums in registry/entities.json (`appearanceMode`,
 * `accentColor`, `canvasTexture`, `textureMotion`).
 */
data class AppearanceState(
    val mode: String,
    val syncTheme: Boolean,
    val accentId: String,
    val texture: String,
    val textureIntensity: Int,
    val textureMotion: String,
    val textSizeStep: Int,
) {
    val hasActiveTexture: Boolean get() = texture != TEXTURE_NONE
    val isSlowDrift: Boolean get() = hasActiveTexture && textureMotion == MOTION_SLOW_DRIFT

    companion object {
        const val MODE_LIGHT = "light"
        const val MODE_DARK = "dark"
        const val TEXTURE_NONE = "none"
        const val MOTION_STILL = "still"
        const val MOTION_SLOW_DRIFT = "slowDrift"
        const val INTENSITY_MIN = 15
        const val INTENSITY_MAX = 100
        const val TEXT_SIZE_MIN = -2
        const val TEXT_SIZE_MAX = 2

        /** Registry defaults, used before the store has read anything. */
        fun defaults(): AppearanceState = AppearanceState(
            mode = registryDefault(RegistrySettingKeys.APPEARANCE_MODE).stringValue().orEmpty(),
            syncTheme = registryDefault(RegistrySettingKeys.SYNC_THEME).booleanValue() ?: true,
            accentId = registryDefault(RegistrySettingKeys.ACCENT_COLOR).stringValue().orEmpty(),
            texture = registryDefault(RegistrySettingKeys.CANVAS_TEXTURE).stringValue() ?: TEXTURE_NONE,
            textureIntensity = registryDefault(RegistrySettingKeys.TEXTURE_INTENSITY).longValue()?.toInt() ?: 55,
            textureMotion = registryDefault(RegistrySettingKeys.TEXTURE_MOTION).stringValue() ?: MOTION_STILL,
            textSizeStep = registryDefault(RegistrySettingKeys.TEXT_SIZE_STEP).longValue()?.toInt() ?: 0,
        )
    }
}

/**
 * Holds [AppearanceState] for every screen and applies the iPhone's sync rule.
 *
 * Each choice is kept on the device (the same preferences file the Settings
 * screen writes). The accent, texture, intensity and motion are also synced
 * settings: while `syncTheme` is on (the default), a write goes to the synced
 * store first, and a value that sync brings in replaces the device copy, as
 * `AppearancePreferences.adoptSynced` does on Apple. With `syncTheme` off this
 * device keeps its own look. Mode, sync theme and text size are device-only.
 */
class AppearanceStore(
    private val deviceSettings: AndroidDeviceSettings,
    private val syncedSettings: SyncedSettings,
    private val syncedSettingsMutator: SyncedSettingsMutator,
    private val sync: SyncController,
    private val clock: DayClock,
    private val scope: CoroutineScope,
) {
    private val lock = Mutex()
    private val _state = MutableStateFlow(readState())
    val state: StateFlow<AppearanceState> = _state.asStateFlow()

    private val watchedStorageKeys: Set<String> = ALL_KEYS.map(::storageKey).toSet()

    // SharedPreferences keeps listeners weakly: this field holds the reference.
    private val preferenceListener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        if (key == null || key in watchedStorageKeys) _state.value = readState()
    }

    init {
        deviceSettings.preferences.registerOnSharedPreferenceChangeListener(preferenceListener)
        scope.launch {
            sync.dataVersion.collect { adoptSynced() }
        }
    }

    /** Today as `YYYY-MM-DD`, for the daily texture seed. */
    fun dayIso(): String = clock.today().toString()

    fun setMode(mode: String) = write(RegistrySettingKeys.APPEARANCE_MODE, JsonValue.StringValue(mode))

    fun setAccent(accentId: String) {
        if (FruitAccents.all.none { it.id == accentId }) return
        write(RegistrySettingKeys.ACCENT_COLOR, JsonValue.StringValue(accentId))
    }

    fun setTexture(texture: String) = write(RegistrySettingKeys.CANVAS_TEXTURE, JsonValue.StringValue(texture))

    fun setTextureMotion(motion: String) =
        write(RegistrySettingKeys.TEXTURE_MOTION, JsonValue.StringValue(motion))

    fun setTextSizeStep(step: Int) = write(
        RegistrySettingKeys.TEXT_SIZE_STEP,
        JsonValue.IntegerValue(
            step.coerceIn(AppearanceState.TEXT_SIZE_MIN, AppearanceState.TEXT_SIZE_MAX).toLong(),
        ),
    )

    private fun write(key: String, value: JsonValue) {
        scope.launch {
            var pushed = false
            lock.withLock {
                withContext(Dispatchers.IO) {
                    // Synced store first: a sync that lands between the two
                    // writes then brings back the new value, not the old one.
                    // Keep the local write in its own guard so a sync failure
                    // never drops the user's choice on this device.
                    if (key in SYNCED_KEYS && readState().syncTheme) {
                        pushed = runCatching { syncedSettingsMutator.set(key, value) }.isSuccess
                    }
                    runCatching { writeLocal(key, value) }
                }
                _state.value = readState()
            }
            if (pushed) {
                sync.noteLocalChange()
                sync.requestSync()
            }
        }
    }

    /** Takes the synced accent and texture choices while `syncTheme` is on. */
    private suspend fun adoptSynced() {
        lock.withLock {
            withContext(Dispatchers.IO) {
                if (!readState().syncTheme) return@withContext
                for (key in SYNCED_KEYS) {
                    // Read the raw persisted value, not the default fallback: a missing
                    // or null server row must never overwrite the local choice back to
                    // `none` / `colorful` (matches Apple `AppearancePreferences.adoptSynced`).
                    val synced = runCatching { syncedSettings.rawValue(key) }.getOrNull() ?: continue
                    if (!isValid(key, synced)) continue
                    if (readLocal(key) != synced) writeLocal(key, synced)
                }
            }
            _state.value = readState()
        }
    }

    private fun isValid(key: String, value: JsonValue): Boolean = when (key) {
        RegistrySettingKeys.ACCENT_COLOR -> FruitAccents.all.any { it.id == value.stringValue() }
        RegistrySettingKeys.TEXTURE_INTENSITY -> value.longValue()?.toInt() != null
        else -> value.stringValue() in enumValues(key)
    }

    private fun readState(): AppearanceState {
        val defaults = AppearanceState.defaults()
        val accent = readLocal(RegistrySettingKeys.ACCENT_COLOR).stringValue()
            ?.takeIf { id -> FruitAccents.all.any { it.id == id } } ?: defaults.accentId
        return AppearanceState(
            mode = readEnum(RegistrySettingKeys.APPEARANCE_MODE) ?: defaults.mode,
            syncTheme = readLocal(RegistrySettingKeys.SYNC_THEME).booleanValue() ?: defaults.syncTheme,
            accentId = accent,
            texture = readEnum(RegistrySettingKeys.CANVAS_TEXTURE) ?: defaults.texture,
            textureIntensity = (readLocal(RegistrySettingKeys.TEXTURE_INTENSITY).longValue()?.toInt() ?: defaults.textureIntensity)
                .coerceIn(AppearanceState.INTENSITY_MIN, AppearanceState.INTENSITY_MAX),
            textureMotion = readEnum(RegistrySettingKeys.TEXTURE_MOTION) ?: defaults.textureMotion,
            textSizeStep = (readLocal(RegistrySettingKeys.TEXT_SIZE_STEP).longValue()?.toInt() ?: defaults.textSizeStep)
                .coerceIn(AppearanceState.TEXT_SIZE_MIN, AppearanceState.TEXT_SIZE_MAX),
        )
    }

    private fun readEnum(key: String): String? =
        readLocal(key).stringValue()?.takeIf { it in enumValues(key) }

    /** The device copy, or the registry default when the device has none. */
    private fun readLocal(key: String): JsonValue = deviceSettings.read(key, definition(key))

    private fun writeLocal(key: String, value: JsonValue) = deviceSettings.write(key, definition(key), value)

    private companion object {
        val SYNCED_KEYS = listOf(
            RegistrySettingKeys.ACCENT_COLOR,
            RegistrySettingKeys.CANVAS_TEXTURE,
            RegistrySettingKeys.TEXTURE_INTENSITY,
            RegistrySettingKeys.TEXTURE_MOTION,
        )

        val ALL_KEYS = SYNCED_KEYS + listOf(
            RegistrySettingKeys.APPEARANCE_MODE,
            RegistrySettingKeys.SYNC_THEME,
            RegistrySettingKeys.TEXT_SIZE_STEP,
        )

        fun definition(key: String): JsonValue.ObjectValue =
            requireNotNull(RegistryCatalog.setting(key)) { "Unknown registry setting '$key'" }

        fun storageKey(key: String): String = definition(key).fields["storageKey"].stringValue() ?: key

        fun enumValues(key: String): List<String> {
            val enumName = RegistryCatalog.setting(key)?.fields?.get("enum").stringValue() ?: return emptyList()
            val enums = RegistryCatalog.document("entities").fields["enums"] as? JsonValue.ObjectValue
            return (enums?.fields?.get(enumName) as? JsonValue.ArrayValue)?.values
                ?.mapNotNull { it.stringValue() }.orEmpty()
        }
    }
}

private fun registryDefault(key: String): JsonValue? = RegistryCatalog.setting(key)?.fields?.get("default")
