package app.septena.android.ui

import app.septena.android.AndroidAppGraph
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.generated.RegistryFirstRunStepIds
import app.septena.core.generated.RegistryNoticeIds
import app.septena.core.generated.RegistrySettingKeys
import app.septena.core.stringValue

/**
 * Ticks the Get started step that connecting an agent completes (Apple
 * `TaskNotices.completeStep(.connectAI)`), and dismisses the notice when every
 * step is done. The registry names the step (`completesGetStartedStep`).
 */
internal suspend fun completeConnectAgentStep(graph: AndroidAppGraph) {
    val step = RegistryCatalog.surface(RegistryFirstRunStepIds.CONNECT_CLAUDE)
        ?.fields?.get("completesGetStartedStep").stringValue() ?: return
    val saved = graph.syncedSettings.value(RegistrySettingKeys.GET_STARTED_STEPS) as? JsonValue.ArrayValue
    val done = saved?.values.orEmpty().mapNotNull { it.stringValue() }.toSet()
    if (step in done) return
    val next = (done + step).sorted()
    graph.syncedSettingsMutator.set(
        RegistrySettingKeys.GET_STARTED_STEPS,
        JsonValue.ArrayValue(next.map { JsonValue.StringValue(it) }),
    )
    val steps = (RegistryCatalog.surface(RegistryNoticeIds.GET_STARTED)?.fields?.get("steps") as? JsonValue.ArrayValue)
        ?.values.orEmpty().mapNotNull { (it as? JsonValue.ObjectValue)?.fields?.get("id").stringValue() }
    if (steps.isNotEmpty() && next.containsAll(steps)) {
        graph.syncedSettingsMutator.set(RegistrySettingKeys.GET_STARTED_DISMISSED, JsonValue.BooleanValue(true))
    }
    graph.sync.noteLocalChange()
    graph.sync.requestSync()
}
