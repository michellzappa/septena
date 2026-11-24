package app.septena.android

import android.content.Context
import app.septena.core.DayClock
import app.septena.core.JsonValue
import app.septena.core.SyncedSettings
import app.septena.core.SyncedSettingsMutator
import app.septena.core.TaskStore
import app.septena.core.WireTimestamp
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.generated.RegistrySettingKeys
import app.septena.core.stringValue
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Whether this device still owes the user the first run (registry/surfaces.json `firstRun`), as on iOS
 * (`SeptaskFirstRunGate`). The synced `onboardedAt` setting records a first run finished on any device; two
 * device-local flags mirror it here: `completed`, and `force` (Settings ▸ About ▸ Show Welcome Again), which
 * shows the first run again on this device only.
 */
class FirstRunState(
    context: Context,
    private val store: TaskStore,
    private val syncedSettings: SyncedSettings,
    private val syncedSettingsMutator: SyncedSettingsMutator,
    private val clock: DayClock,
) {
    enum class Phase { Unresolved, Show, Hidden }

    private val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    // Returning devices already know the first run is done: skip the blank spinner on Frame 1.
    private val _phase = MutableStateFlow(
        if (preferences.getBoolean(KEY_COMPLETED, false) && !preferences.getBoolean(KEY_FORCE, false)) {
            Phase.Hidden
        } else {
            Phase.Unresolved
        },
    )
    val phase: StateFlow<Phase> = _phase.asStateFlow()

    /**
     * Settles the decision once per launch. Signed in with an empty local store (the app closed before the
     * first pull landed), the answer arrives with that pull, so pull before deciding: showing the welcome to
     * a returning account is the bug this guards against.
     */
    suspend fun resolve(graph: AndroidAppGraph) {
        // A deleted account's rows must not count as this account's content. A wipe that fails again stays
        // pending and blocks the next sign-in.
        runCatching { graph.finishPendingWipe() }
        if (_phase.value != Phase.Unresolved) return
        if (needsFirstRun() && graph.credentials.signedIn.value) runCatching { graph.sync.syncAndWait() }
        grandfatherIfEstablished(graph)
        _phase.value = if (needsFirstRun()) Phase.Show else Phase.Hidden
    }

    /** True when the account this device sees already finished a first run or holds tasks. */
    suspend fun accountIsEstablished(): Boolean {
        if (onboardedAt() != null) return true
        val name = runCatching { syncedSettings.value(RegistrySettingKeys.WELCOME_NAME).stringValue() }.getOrNull()
        if (!name.isNullOrBlank()) return true
        return listOf(RegistryEntityNames.TASK, RegistryEntityNames.AREA, RegistryEntityNames.PROJECT).any { entity ->
            store.records(entity).any { it.deletedAt == null }
        }
    }

    /** Stamps the first run as done here and, the first time on any device, in the synced setting. */
    suspend fun markComplete(graph: AndroidAppGraph) {
        preferences.edit().putBoolean(KEY_COMPLETED, true).putBoolean(KEY_FORCE, false).commit()
        _phase.value = Phase.Hidden
        if (onboardedAt() != null) return
        val written = runCatching {
            syncedSettingsMutator.set(
                RegistrySettingKeys.ONBOARDED_AT,
                JsonValue.StringValue(WireTimestamp.format(clock.now())),
            )
        }
        if (written.isSuccess) {
            graph.sync.noteLocalChange()
            graph.sync.requestSync()
        }
    }

    /** Settings ▸ About ▸ Show Welcome Again: this device only; the synced `onboardedAt` stays. */
    fun showAgain() {
        preferences.edit().putBoolean(KEY_FORCE, true).commit()
        _phase.value = Phase.Show
    }

    /** After account deletion: this device starts over like a new install. */
    fun startOver() {
        preferences.edit().clear().commit()
        _phase.value = Phase.Show
    }

    private suspend fun needsFirstRun(): Boolean {
        if (preferences.getBoolean(KEY_FORCE, false)) return true
        if (preferences.getBoolean(KEY_COMPLETED, false)) return false
        return !accountIsEstablished()
    }

    /** An account used before this app had a first run: mark it done instead of welcoming it. */
    private suspend fun grandfatherIfEstablished(graph: AndroidAppGraph) {
        if (preferences.getBoolean(KEY_COMPLETED, false) || preferences.getBoolean(KEY_FORCE, false)) return
        if (accountIsEstablished()) markComplete(graph)
    }

    private suspend fun onboardedAt(): String? =
        runCatching { syncedSettings.value(RegistrySettingKeys.ONBOARDED_AT).stringValue() }.getOrNull()

    private companion object {
        const val PREFS = "septena-first-run"
        const val KEY_COMPLETED = "completed"
        const val KEY_FORCE = "force"
    }
}
