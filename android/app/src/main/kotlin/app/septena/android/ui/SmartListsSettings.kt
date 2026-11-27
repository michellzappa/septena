package app.septena.android.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.SmartListDescriptor
import app.septena.core.SmartListLayout
import app.septena.core.SmartListSection
import app.septena.core.generated.RegistrySettingKeys

/**
 * Surface `smart_lists_editor` (Settings ▸ General ▸ Lists): show, hide, order and place the
 * smart lists above or below Areas & Projects, like iOS `SeptaskSmartListsPane`. iOS drags
 * to reorder; Android moves a list with the arrows. The three keys sync per account.
 */
@Composable
internal fun SmartListsEditor(
    values: Map<String, JsonValue>,
    languageTag: String,
    onValueChange: (String, JsonValue) -> Unit,
) {
    val layout = SmartListLayout.from(
        values[RegistrySettingKeys.SMART_LIST_ORDER],
        values[RegistrySettingKeys.SMART_LIST_HIDDEN],
        values[RegistrySettingKeys.SMART_LIST_PLACEMENT],
    )

    fun save(next: SmartListLayout) {
        if (next.order != layout.order) onValueChange(RegistrySettingKeys.SMART_LIST_ORDER, next.orderJson())
        if (next.hidden != layout.hidden) onValueChange(RegistrySettingKeys.SMART_LIST_HIDDEN, next.hiddenJson())
        if (next.placement != layout.placement) onValueChange(RegistrySettingKeys.SMART_LIST_PLACEMENT, next.placementJson())
    }

    SmartListSectionBlock(SmartListSection.TOP, "topHeader", "topFooter", layout, languageTag, ::save)
    SmartListSectionBlock(SmartListSection.BOTTOM, "bottomHeader", "bottomFooterButtons", layout, languageTag, ::save)
    if (layout.isCustomized) {
        TextButton(onClick = {
            onValueChange(RegistrySettingKeys.SMART_LIST_ORDER, SmartListLayout.DEFAULT.orderJson())
            onValueChange(RegistrySettingKeys.SMART_LIST_HIDDEN, SmartListLayout.DEFAULT.hiddenJson())
            onValueChange(RegistrySettingKeys.SMART_LIST_PLACEMENT, SmartListLayout.DEFAULT.placementJson())
        }) { Text(settingsCopy(SMART_LISTS, "reset", languageTag)) }
    }
}

@Composable
private fun SmartListSectionBlock(
    section: SmartListSection,
    headerId: String,
    footerId: String,
    layout: SmartListLayout,
    languageTag: String,
    onChange: (SmartListLayout) -> Unit,
) {
    SectionHeader(settingsCopy(SMART_LISTS, headerId, languageTag))
    val items = layout.inSection(section)
    if (items.isEmpty()) {
        ListItem(headlineContent = {
            Text(settingsCopy(SMART_LISTS, "empty", languageTag), color = MaterialTheme.colorScheme.onSurfaceVariant)
        })
    }
    items.forEachIndexed { index, dest ->
        SmartListRow(dest, index, items.size, section, layout, languageTag, onChange)
    }
    SectionFooter(settingsCopy(SMART_LISTS, footerId, languageTag))
}

@Composable
private fun SmartListRow(
    dest: SmartListDescriptor,
    index: Int,
    count: Int,
    section: SmartListSection,
    layout: SmartListLayout,
    languageTag: String,
    onChange: (SmartListLayout) -> Unit,
) {
    val title = RegistryCatalog.destinationTitle(dest.id, languageTag) ?: dest.id
    val note = when {
        !dest.canHide -> settingsCopy(SMART_LISTS, "alwaysShown", languageTag)
        dest.visibility == WHEN_NON_EMPTY -> settingsCopy(SMART_LISTS, "whenNonEmpty", languageTag)
        else -> null
    }
    val up = settingsCopy(SMART_LISTS, "moveUp", languageTag)
    val down = settingsCopy(SMART_LISTS, "moveDown", languageTag)
    ListItem(
        headlineContent = { Text(title) },
        supportingContent = {
            Column {
                note?.let { Text(it) }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    TextButton(
                        onClick = { onChange(layout.moveInSection(section, index, index - 1)) },
                        enabled = index > 0,
                        modifier = Modifier.semantics { contentDescription = up },
                    ) { Text("↑") }
                    TextButton(
                        onClick = { onChange(layout.moveInSection(section, index, index + 1)) },
                        enabled = index < count - 1,
                        modifier = Modifier.semantics { contentDescription = down },
                    ) { Text("↓") }
                    if (dest.canMoveSection) {
                        val target = if (section == SmartListSection.TOP) SmartListSection.BOTTOM else SmartListSection.TOP
                        val label = settingsCopy(
                            SMART_LISTS,
                            if (target == SmartListSection.BOTTOM) "moveBelow" else "moveAbove",
                            languageTag,
                        )
                        TextButton(
                            onClick = { onChange(layout.setSection(dest, target)) },
                            modifier = Modifier.semantics { contentDescription = label },
                        ) { Text(if (target == SmartListSection.BOTTOM) "⤓" else "⤒") }
                    }
                }
            }
        },
        trailingContent = {
            Switch(
                checked = !layout.isHidden(dest),
                onCheckedChange = { onChange(layout.setHidden(dest, !it)) },
                enabled = dest.canHide,
            )
        },
        modifier = Modifier.fillMaxWidth(),
    )
}

private const val SMART_LISTS = "smart_lists_editor"
private const val WHEN_NON_EMPTY = "whenNonEmpty"
