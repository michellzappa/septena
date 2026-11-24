package app.septena.android.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.selection.selectable
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import app.septena.android.AndroidAppGraph
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.generated.RegistrySettingKeys
import app.septena.core.stringValue

/**
 * Settings ▸ AI Preferences ▸ Where AI runs (`aiMode`, feature `ai.reach-dial`): every
 * mode as a row with its title and what it means, like Apple `SeptaskAIPreferencesSections`.
 *
 * Android has no on-device model, so the only provider any mode admits is the user's own
 * Claude: On-device only turns Discuss off, Automatic and Use my Claude hand a discussed
 * task to Claude. The rows say so (`aiMode` copy `onDeviceOnlyNoModel`, `autoNoModel`).
 */
@Composable
internal fun AiModePicker(value: String, languageTag: String, onSelect: (String) -> Unit) {
    val app = appName(LocalContext.current)
    Column {
        aiModeOptions(languageTag).forEach { (mode, title) ->
            val selected = mode == value
            ListItem(
                headlineContent = { Text(title) },
                supportingContent = { Text(aiModeDetail(mode, app, languageTag), style = MaterialTheme.typography.bodySmall) },
                trailingContent = { RadioButton(selected = selected, onClick = null) },
                modifier = Modifier.fillMaxWidth().selectable(selected = selected, role = Role.RadioButton) { onSelect(mode) },
            )
        }
    }
}

/** The `aiMode` value this device stores, or its registry default. */
internal fun currentAiMode(graph: AndroidAppGraph): String {
    val definition = aiModeDefinition() ?: return MODE_AUTO
    return graph.deviceSettings.read(RegistrySettingKeys.AI_MODE, definition).stringValue()
        ?: definition.fields["default"].stringValue()
        ?: MODE_AUTO
}

/** Whether the user's Claude may take a discussed task: every mode but On-device only. */
internal fun aiModeAdmitsClaude(mode: String): Boolean = mode != MODE_ON_DEVICE_ONLY

private fun aiModeDetail(mode: String, app: String, languageTag: String): String {
    val id = when (mode) {
        MODE_ON_DEVICE_ONLY -> "onDeviceOnlyNoModel"
        MODE_AUTO -> "autoNoModel"
        else -> mode
    }
    return settingsCopy(RegistrySettingKeys.AI_MODE, id, languageTag, "app" to app)
}

private fun aiModeOptions(languageTag: String): List<Pair<String, String>> =
    (aiModeDefinition()?.fields?.get("options") as? JsonValue.ArrayValue)?.values.orEmpty().mapNotNull { raw ->
        val option = raw as? JsonValue.ObjectValue ?: return@mapNotNull null
        val value = option.fields["value"].stringValue() ?: return@mapNotNull null
        value to registryText(option.fields["title"].stringValue(), languageTag)
    }

private fun aiModeDefinition(): JsonValue.ObjectValue? =
    (RegistryCatalog.document("settings").fields["keys"] as? JsonValue.ObjectValue)
        ?.fields?.get(RegistrySettingKeys.AI_MODE) as? JsonValue.ObjectValue

private const val MODE_ON_DEVICE_ONLY = "onDeviceOnly"
private const val MODE_AUTO = "auto"
