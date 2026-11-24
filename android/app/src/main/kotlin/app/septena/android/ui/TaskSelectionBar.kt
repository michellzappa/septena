package app.septena.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.septena.core.RegistryActionContext
import app.septena.core.RegistryActionResolver
import app.septena.core.RegistryCatalog
import app.septena.core.generated.RegistryActionIds
import app.septena.core.generated.RegistryPlatformIds
import app.septena.core.generated.RegistrySurfaceIds
import app.septena.core.stringValue

/** What a tap on the selection bar asks the host to do. */
sealed interface TaskSelectionCommand {
    /** Complete, Cancel or Delete: runs at once on the selection. */
    data class Apply(val actionId: String) : TaskSelectionCommand
    data class SetToday(val enabled: Boolean) : TaskSelectionCommand
    data object PickWhen : TaskSelectionCommand
    data object PickList : TaskSelectionCommand
    data object Copy : TaskSelectionCommand
    data object ToggleSelectAll : TaskSelectionCommand
    data object Done : TaskSelectionCommand
}

/**
 * The bottom bar while tasks are selected, the iPhone multi-select bar:
 * When, Move, Complete and Delete, then Today, Copy, Select All and Cancel
 * under More. Complete and Cancel hide where the rows cannot be completed
 * (Logbook). Each button is a registry action, shown only where the registry makes it
 * available for this selection.
 */
@Composable
fun TaskSelectionBar(
    selectedCount: Int,
    destinationId: String?,
    allOnToday: Boolean,
    allSelected: Boolean,
    canComplete: Boolean,
    languageTag: String,
    onCommand: (TaskSelectionCommand) -> Unit,
) {
    val context = RegistryActionContext(
        platform = RegistryPlatformIds.ANDROID,
        destinationId = destinationId,
        selectedCount = selectedCount,
    )
    val available = remember(context) { RegistryActionResolver.availableActionIds(context).toSet() }
    fun title(id: String, field: String = "title") =
        RegistryCatalog.actionTitle(id, field = field, languageTag = languageTag).orEmpty()
    val countText = remember(languageTag, selectedCount) { selectionCountText(selectedCount, languageTag) }
    val moreLabel = remember(languageTag) { surfaceField(RegistrySurfaceIds.TASK_ROW_MENU, "accessibilityLabel", languageTag) }
    var moreExpanded by remember { mutableStateOf(false) }

    Surface(tonalElevation = 3.dp, shadowElevation = 6.dp) {
        Column(modifier = Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 8.dp, vertical = 4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = countText,
                    style = MaterialTheme.typography.titleSmall,
                    modifier = Modifier.weight(1f).padding(start = 8.dp),
                )
                TextButton(onClick = { onCommand(TaskSelectionCommand.Done) }) {
                    Text(title(RegistryActionIds.TASK_SELECT, ACTIVE_TITLE))
                }
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (RegistryActionIds.TASK_WHEN in available) {
                    BarButton(title(RegistryActionIds.TASK_WHEN, SHORT_TITLE)) { onCommand(TaskSelectionCommand.PickWhen) }
                }
                if (RegistryActionIds.TASK_MOVE in available) {
                    BarButton(title(RegistryActionIds.TASK_MOVE, SHORT_TITLE)) { onCommand(TaskSelectionCommand.PickList) }
                }
                if (canComplete && RegistryActionIds.TASK_TOGGLE_COMPLETE in available) {
                    BarButton(title(RegistryActionIds.TASK_TOGGLE_COMPLETE, SHORT_TITLE)) {
                        onCommand(TaskSelectionCommand.Apply(RegistryActionIds.TASK_TOGGLE_COMPLETE))
                    }
                }
                if (RegistryActionIds.TASK_DELETE in available) {
                    BarButton(title(RegistryActionIds.TASK_DELETE), color = MaterialTheme.colorScheme.error) {
                        onCommand(TaskSelectionCommand.Apply(RegistryActionIds.TASK_DELETE))
                    }
                }
                val showToday = RegistryActionIds.TASK_TOGGLE_TODAY in available
                val showCancel = canComplete && RegistryActionIds.TASK_CANCEL in available
                val showCopy = RegistryActionIds.TASK_COPY in available
                val showSelectAll = RegistryActionIds.TASK_SELECT_ALL in available
                if (showToday || showCopy || showSelectAll || showCancel) {
                    Box {
                        IconButton(
                            onClick = { moreExpanded = true },
                            modifier = Modifier.semantics { contentDescription = moreLabel },
                        ) {
                            Text("⋮", style = MaterialTheme.typography.titleLarge)
                        }
                        DropdownMenu(expanded = moreExpanded, onDismissRequest = { moreExpanded = false }) {
                            if (showToday) {
                                DropdownMenuItem(
                                    text = {
                                        Text(title(RegistryActionIds.TASK_TOGGLE_TODAY, if (allOnToday) REMOVE_TITLE else ADD_TITLE))
                                    },
                                    onClick = {
                                        moreExpanded = false
                                        onCommand(TaskSelectionCommand.SetToday(!allOnToday))
                                    },
                                )
                            }
                            if (showCopy) {
                                DropdownMenuItem(
                                    text = { Text(title(RegistryActionIds.TASK_COPY)) },
                                    onClick = {
                                        moreExpanded = false
                                        onCommand(TaskSelectionCommand.Copy)
                                    },
                                )
                            }
                            if (showSelectAll) {
                                DropdownMenuItem(
                                    text = {
                                        Text(title(RegistryActionIds.TASK_SELECT_ALL, if (allSelected) ACTIVE_TITLE else TITLE))
                                    },
                                    onClick = {
                                        moreExpanded = false
                                        onCommand(TaskSelectionCommand.ToggleSelectAll)
                                    },
                                )
                            }
                            if (showCancel) {
                                DropdownMenuItem(
                                    text = {
                                        Text(
                                            title(RegistryActionIds.TASK_CANCEL, PLURAL_TITLE),
                                            color = MaterialTheme.colorScheme.error,
                                        )
                                    },
                                    onClick = {
                                        moreExpanded = false
                                        onCommand(TaskSelectionCommand.Apply(RegistryActionIds.TASK_CANCEL))
                                    },
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun BarButton(
    title: String,
    color: androidx.compose.ui.graphics.Color = MaterialTheme.colorScheme.primary,
    onClick: () -> Unit,
) {
    TextButton(onClick = onClick) {
        Text(title, color = color, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** "{count} selected" from the registry (`surfaces.json` taskSelection). */
private fun selectionCountText(count: Int, languageTag: String): String =
    surfaceField(RegistrySurfaceIds.TASK_SELECTION, "format", languageTag)
        .replace(COUNT_PLACEHOLDER, count.toString())

internal fun surfaceField(surfaceId: String, field: String, languageTag: String): String {
    val key = RegistryCatalog.surface(surfaceId)?.fields?.get(field).stringValue().orEmpty()
    return RegistryCatalog.localizedString(key, languageTag) ?: key
}

private const val COUNT_PLACEHOLDER = "{count}"
private const val TITLE = "title"
private const val ACTIVE_TITLE = "activeTitle"
private const val SHORT_TITLE = "shortTitle"
private const val ADD_TITLE = "addTitle"
private const val REMOVE_TITLE = "removeTitle"
private const val PLURAL_TITLE = "pluralTitle"
