package app.septena.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DatePicker
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.septena.core.DateBoardRowKinds
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.generated.RegistryDestinationIds
import app.septena.core.generated.RegistryEntities
import app.septena.core.generated.RegistryEntityFields
import app.septena.core.generated.RegistryEntityNames
import app.septena.core.generated.RegistrySurfaceIds
import app.septena.core.generated.RegistryTaskAttributeIds
import app.septena.core.longValue
import app.septena.core.stringValue
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.temporal.ChronoUnit

/**
 * Waiting On… and the waiting row label (docs/REVIEW_SPEC.md §6, ADR 0053). All copy comes from
 * registry/surfaces.json `waiting` and the `waitingDays` count phrase.
 */
internal object WaitingCopy {
    /** The longest name the registry allows (`task.waitingOn`). */
    val nameMax: Int = RegistryEntities.all[RegistryEntityNames.TASK]?.columns
        ?.get(RegistryEntityFields.Task.WAITING_ON)?.max?.toInt() ?: DEFAULT_NAME_MAX

    /** A field of the `waiting` surface by its dotted path ("sheet.checkBack.title"), localized. */
    fun field(path: String, languageTag: String): String {
        var node: JsonValue? = RegistryCatalog.surface(RegistrySurfaceIds.WAITING)
        for (key in path.split('.')) node = (node as? JsonValue.ObjectValue)?.fields?.get(key)
        val raw = node.stringValue().orEmpty()
        return RegistryCatalog.localizedString(raw, languageTag) ?: raw
    }

    /** How many days the sheet proposes for the day to chase. */
    fun defaultCheckBackDays(): Long =
        RegistryCatalog.surface(RegistrySurfaceIds.WAITING)?.fields?.get("defaultCheckBackDays").longValue()
            ?: DEFAULT_CHECK_BACK_DAYS

    /**
     * "Waiting on Anna · 5 days". A wait that started today shows the name alone: "0 days" says
     * nothing.
     */
    fun label(name: String, since: String?, today: LocalDate, languageTag: String): String {
        val base = field("label.format", languageTag).replace("{name}", name)
        val start = since?.let { runCatching { LocalDate.parse(it.take(10)) }.getOrNull() } ?: return base
        val days = ChronoUnit.DAYS.between(start, today).toInt()
        if (days <= 0) return base
        return "$base · ${countPhrase(WAITING_DAYS_PHRASE, days, languageTag)}"
    }

    private const val WAITING_DAYS_PHRASE = "waitingDays"
    private const val DEFAULT_NAME_MAX = 80
    private const val DEFAULT_CHECK_BACK_DAYS = 7L
}

/**
 * The Waiting On… sheet: who the task waits on, and the day to check back (the task's When date).
 * The day starts at today + `defaultCheckBackDays`; "No date" leaves the When date as it is.
 * [onConfirm] gets the trimmed name and the day (`YYYY-MM-DD`) or null.
 */
@Composable
@OptIn(ExperimentalMaterial3Api::class)
internal fun WaitingOnDialog(
    initialName: String,
    today: LocalDate,
    languageTag: String,
    onDismiss: () -> Unit,
    onConfirm: (name: String, checkBack: String?) -> Unit,
) {
    val title = remember(languageTag) { WaitingCopy.field("sheet.title", languageTag) }
    val placeholder = remember(languageTag) { WaitingCopy.field("sheet.placeholder", languageTag) }
    val confirmTitle = remember(languageTag) { WaitingCopy.field("sheet.confirmTitle", languageTag) }
    val checkBackTitle = remember(languageTag) { WaitingCopy.field("sheet.checkBack.title", languageTag) }
    val noCheckBackTitle = remember(languageTag) { WaitingCopy.field("sheet.noCheckBack.title", languageTag) }
    val cancelTitle = remember(languageTag) { promptsCancelTitle(languageTag) }
    val todayLabel = remember(languageTag) {
        RegistryCatalog.destinationTitle(RegistryDestinationIds.TODAY, languageTag).orEmpty()
    }
    val tomorrowLabel = remember(languageTag) {
        RegistryCatalog.dateBoardRows(RegistryTaskAttributeIds.WHEN, languageTag = languageTag)
            .firstOrNull { it.kind == DateBoardRowKinds.TOMORROW }?.label.orEmpty()
    }
    var name by remember(initialName) { mutableStateOf(initialName) }
    var checkBack by remember(today) { mutableStateOf<LocalDate?>(today.plusDays(WaitingCopy.defaultCheckBackDays())) }
    var calendarOpen by remember { mutableStateOf(false) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it.take(WaitingCopy.nameMax) },
                    label = { Text(placeholder) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(checkBackTitle, style = MaterialTheme.typography.titleSmall)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    val day = checkBack
                    FilterChip(
                        selected = day != null,
                        onClick = {
                            if (day == null) {
                                checkBack = today.plusDays(WaitingCopy.defaultCheckBackDays())
                            } else {
                                calendarOpen = !calendarOpen
                            }
                        },
                        label = {
                            Text(
                                formatShortLocalDay(
                                    day ?: today.plusDays(WaitingCopy.defaultCheckBackDays()),
                                    today,
                                    todayLabel,
                                    tomorrowLabel,
                                    languageTag,
                                ),
                            )
                        },
                    )
                    FilterChip(
                        selected = day == null,
                        onClick = { checkBack = null; calendarOpen = false },
                        label = { Text(noCheckBackTitle) },
                    )
                }
                if (calendarOpen) {
                    val initial = (checkBack ?: today.plusDays(WaitingCopy.defaultCheckBackDays()))
                        .atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
                    val state = rememberDatePickerState(initialSelectedDateMillis = initial)
                    val picked = state.selectedDateMillis
                    LaunchedEffect(picked) {
                        if (picked != null) {
                            checkBack = Instant.ofEpochMilli(picked).atZone(ZoneOffset.UTC).toLocalDate()
                        }
                    }
                    DatePicker(state = state, title = null, headline = null, showModeToggle = false)
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = name.isNotBlank(),
                onClick = { onConfirm(name.trim(), checkBack?.toString()) },
            ) { Text(confirmTitle) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(cancelTitle) }
        },
    )
}

/** Shared prompt chrome: surfaces.json `prompts.cancelTitle`. */
private fun promptsCancelTitle(languageTag: String): String {
    val prompts = RegistryCatalog.document("surfaces").fields["prompts"] as? JsonValue.ObjectValue
    val raw = prompts?.fields?.get("cancelTitle").stringValue().orEmpty()
    return RegistryCatalog.localizedString(raw, languageTag) ?: raw
}
