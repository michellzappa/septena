package app.septena.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import app.septena.android.R
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.generated.RegistryActionIds
import app.septena.core.generated.RegistryDestinationIds
import app.septena.core.generated.RegistryEntityLimits
import app.septena.core.generated.RegistryTaskDetail
import app.septena.core.stringValue

@Composable
@OptIn(ExperimentalMaterial3Api::class)
internal fun ShareCaptureScreen(
    initialTitle: String,
    initialNotes: String,
    saving: Boolean,
    saveFailed: Boolean,
    onCancel: () -> Unit,
    onSave: (title: String, notes: String, today: Boolean) -> Unit,
) {
    val languageTag = LocalConfiguration.current.locales[0].toLanguageTag()
    val labels = remember(languageTag) { ShareCaptureLabels.fromRegistry(languageTag) }
    var title by rememberSaveable { mutableStateOf(initialTitle.take(RegistryEntityLimits.TEXT_MAX.toInt())) }
    var notes by rememberSaveable { mutableStateOf(initialNotes.take(RegistryEntityLimits.NOTES_MAX.toInt())) }
    var today by rememberSaveable { mutableStateOf(false) }

    Scaffold(
        modifier = Modifier.fillMaxSize(),
        topBar = {
            TopAppBar(
                title = { Text(labels.title) },
                navigationIcon = {
                    // A close (x), not a "Cancel" text button: the same leading
                    // control as every sheet on iOS and Mac.
                    IconButton(onClick = onCancel, enabled = !saving) {
                        Icon(painterResource(R.drawable.ic_close), contentDescription = labels.cancel)
                    }
                },
                actions = {
                    TextButton(
                        onClick = { onSave(title.trim(), notes.trim(), today) },
                        enabled = !saving && title.isNotBlank(),
                    ) {
                        Text(labels.add)
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(padding)
                .padding(horizontal = 20.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            OutlinedTextField(
                value = title,
                onValueChange = { title = it.take(RegistryEntityLimits.TEXT_MAX.toInt()) },
                label = { Text(labels.task) },
                modifier = Modifier.fillMaxWidth(),
                minLines = 1,
                maxLines = 3,
                enabled = !saving,
            )
            OutlinedTextField(
                value = notes,
                onValueChange = { notes = it.take(RegistryEntityLimits.NOTES_MAX.toInt()) },
                label = { Text(labels.notes) },
                modifier = Modifier.fillMaxWidth(),
                minLines = 3,
                maxLines = 8,
                enabled = !saving,
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Checkbox(checked = today, onCheckedChange = { today = it }, enabled = !saving)
                Text(labels.today)
            }
            if (saveFailed) {
                Text(labels.saveError, color = MaterialTheme.colorScheme.error)
            }
        }
    }
}

private data class ShareCaptureLabels(
    val title: String,
    val cancel: String,
    val add: String,
    val task: String,
    val notes: String,
    val today: String,
    val saveError: String,
) {
    companion object {
        fun fromRegistry(languageTag: String): ShareCaptureLabels {
            val taskDetail = RegistryCatalog.surface(RegistryTaskDetail.ID)
            val fields = (taskDetail?.fields?.get("fields") as? JsonValue.ObjectValue)?.fields.orEmpty()
            val controls = (taskDetail?.fields?.get("controls") as? JsonValue.ObjectValue)?.fields.orEmpty()
            fun localized(value: String?): String = value?.let { RegistryCatalog.localizedString(it, languageTag) ?: it }.orEmpty()
            fun field(id: String): String = localized(fields[id].stringValue())
            return ShareCaptureLabels(
                title = RegistryCatalog.actionTitle(RegistryActionIds.APP_NEW_TASK, languageTag = languageTag).orEmpty(),
                cancel = RegistryCatalog.localizedString("Cancel", languageTag).orEmpty(),
                add = RegistryCatalog.actionTitle(RegistryActionIds.APP_SHARE_CAPTURE_ADD, languageTag = languageTag).orEmpty(),
                task = field(RegistryTaskDetail.Fields.TITLE),
                notes = field(RegistryTaskDetail.Fields.NOTES),
                today = RegistryCatalog.destinationTitle(RegistryDestinationIds.TODAY, languageTag).orEmpty(),
                saveError = localized(controls[RegistryTaskDetail.Controls.SAVE_ERROR].stringValue()),
            )
        }
    }
}
