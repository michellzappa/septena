package app.septena.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.septena.android.AndroidAppGraph
import app.septena.android.deleteAccount
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** The settings surface id, and the owner of its copy in registry/settings.json `copy`. */
internal const val DELETE_ACCOUNT = "delete_account"

/**
 * Settings ▸ Account surface `delete_account`: deletes the account on the server and this device. Draws
 * nothing while signed out. The confirmation says what iOS says (`SeptaskDeleteAccountSheet`), from the same
 * registry copy, and stays up while the delete runs. On success the device is signed out and the app starts
 * over at the first run ([deleteAccount]).
 */
@Composable
internal fun DeleteAccountRow(graph: AndroidAppGraph, signedIn: Boolean, languageTag: String) {
    if (!signedIn) return
    val scope = rememberCoroutineScope()
    var confirming by remember { mutableStateOf(false) }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    fun copy(id: String) = settingsCopy(DELETE_ACCOUNT, id, languageTag)

    ListItem(
        headlineContent = { Text(copy("button"), color = MaterialTheme.colorScheme.error) },
        supportingContent = { Text(copy("footer")) },
        modifier = Modifier.fillMaxWidth().clickable {
            error = null
            confirming = true
        },
    )
    if (!confirming) return

    fun delete() {
        working = true
        error = null
        scope.launch {
            // Signing out removes this row and cancels its scope: the wipe must still run to the end.
            val result = runCatching { withContext(Dispatchers.IO + NonCancellable) { graph.deleteAccount() } }
            working = false
            result
                .onSuccess { confirming = false }
                .onFailure { error = listOfNotNull(copy("failed"), it.message).joinToString(" ") }
        }
    }

    AlertDialog(
        onDismissRequest = { if (!working) confirming = false },
        title = { Text(copy("title")) },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(copy("intro"))
                Column(modifier = Modifier.padding(start = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    for (id in DELETED_THINGS) Text("\u2022 ${copy(id)}")
                }
                Text(copy("consequence"))
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                if (working) CircularProgressIndicator()
            }
        },
        confirmButton = {
            TextButton(enabled = !working, onClick = ::delete) {
                Text(copy("button"), color = MaterialTheme.colorScheme.error)
            }
        },
        dismissButton = {
            TextButton(enabled = !working, onClick = { confirming = false }) { Text(promptCancelTitle(languageTag)) }
        },
    )
}

/** What the server deletes, in the iOS order (copy ids of [DELETE_ACCOUNT]). */
private val DELETED_THINGS = listOf("tasks", "attachments", "conversations", "settings")
