package app.septena.android.ui

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalConfiguration
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.septena.android.sync.SyncController
import app.septena.core.RegistryCatalog
import app.septena.core.generated.RegistryPromptIds
import app.septena.core.stringValue

/**
 * Tells the user that a sync could not save a write (#617): the server refused it,
 * for example a rule of a shared project. Same words as Apple's store-health alert
 * (`surfaces.json` prompt `changeNotSaved`). An alert, not a snackbar: the user just
 * lost typed work, and a notice they can miss would hide that again. The write itself
 * stays listed under Settings, Not synced.
 */
@Composable
internal fun ChangeNotSavedDialog(sync: SyncController) {
    val refused by sync.refusedWrite.collectAsStateWithLifecycle()
    if (!refused) return
    val languageTag = LocalConfiguration.current.locales[0].toLanguageTag()
    val prompt = remember(languageTag) {
        val fields = RegistryCatalog.surface(RegistryPromptIds.CHANGE_NOT_SAVED)?.fields.orEmpty()
        Triple(
            registryText(fields["title"].stringValue(), languageTag),
            registryText(fields["message"].stringValue(), languageTag),
            registryText(fields["confirmTitle"].stringValue(), languageTag),
        )
    }
    AlertDialog(
        onDismissRequest = sync::acknowledgeRefusedWrite,
        title = { Text(prompt.first) },
        text = { Text(prompt.second) },
        confirmButton = { TextButton(onClick = sync::acknowledgeRefusedWrite) { Text(prompt.third) } },
    )
}
