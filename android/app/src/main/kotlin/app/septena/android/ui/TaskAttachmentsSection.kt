package app.septena.android.ui

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.core.content.FileProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.septena.android.AndroidAppGraph
import app.septena.android.AttachmentTooLargeException
import app.septena.android.R
import app.septena.core.SyncRecord
import app.septena.core.generated.RegistryTaskDetail
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The task's files (feature `task.attachments`, block `taskPage.attachments`),
 * as iOS `TaskAttachmentsPanel`: one row per file with its size, a tap opens
 * it in another app, the close button removes it, and the add button opens
 * the system file picker. A file that only the server holds downloads on the
 * first open.
 */
@Composable
internal fun TaskAttachmentsSection(
    graph: AndroidAppGraph,
    taskId: String,
    heading: String?,
    canEdit: Boolean,
    control: (String) -> String,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val dataVersion by graph.sync.dataVersion.collectAsStateWithLifecycle()
    var rows by remember(taskId) { mutableStateOf<List<SyncRecord>>(emptyList()) }
    var busy by remember(taskId) { mutableStateOf(false) }
    var error by remember(taskId) { mutableStateOf<String?>(null) }

    LaunchedEffect(graph, taskId, dataVersion) {
        rows = withContext(Dispatchers.IO) { graph.attachments.attachments(taskId) }
    }

    fun launchAction(failure: (Exception) -> String, work: suspend () -> Unit) {
        if (busy) return
        scope.launch {
            busy = true
            error = try {
                work()
                null
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failed: Exception) {
                failure(failed)
            } finally {
                busy = false
            }
        }
    }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris: List<Uri> ->
        if (uris.isEmpty()) return@rememberLauncherForActivityResult
        launchAction({ failed ->
            control(
                if (failed is AttachmentTooLargeException) RegistryTaskDetail.Controls.ATTACHMENT_TOO_LARGE
                else RegistryTaskDetail.Controls.ATTACHMENT_ADD_FAILED,
            )
        }) {
            withContext(Dispatchers.IO) { uris.forEach { graph.attachments.add(taskId, it) } }
            graph.sync.noteLocalChange()
            graph.sync.requestSync()
        }
    }

    fun open(record: SyncRecord) = launchAction({ failed ->
        control(
            if (failed is ActivityNotFoundException) RegistryTaskDetail.Controls.ATTACHMENT_NO_VIEWER
            else RegistryTaskDetail.Controls.ATTACHMENT_OPEN_FAILED,
        )
    }) {
        val file = withContext(Dispatchers.IO) { graph.attachments.openableFile(record) }
        val uri = FileProvider.getUriForFile(context, context.packageName + ATTACHMENT_AUTHORITY_SUFFIX, file)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, graph.attachments.mimeType(record))
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        context.startActivity(intent)
    }

    fun remove(record: SyncRecord) = launchAction({ control(RegistryTaskDetail.Controls.SAVE_ERROR) }) {
        withContext(Dispatchers.IO) { graph.attachments.remove(record) }
        graph.sync.noteLocalChange()
        graph.sync.requestSync()
    }

    Column(modifier = Modifier.fillMaxWidth()) {
        HorizontalDivider()
        heading?.let { Text(it, style = MaterialTheme.typography.titleMedium) }
        rows.forEach { record ->
            val name = graph.attachments.filename(record)
            ListItem(
                headlineContent = { Text(name, maxLines = 1) },
                supportingContent = { Text(Formatter.formatShortFileSize(context, graph.attachments.byteCount(record))) },
                trailingContent = {
                    IconButton(onClick = { remove(record) }, enabled = canEdit && !busy) {
                        Icon(
                            painterResource(R.drawable.ic_close),
                            contentDescription = control(RegistryTaskDetail.Controls.ATTACHMENT_REMOVE).replace("{name}", name),
                        )
                    }
                },
                modifier = Modifier.fillMaxWidth().clickable(enabled = !busy) { open(record) },
            )
        }
        TextButton(onClick = { picker.launch(arrayOf(ANY_TYPE)) }, enabled = canEdit && !busy) {
            Text(
                control(
                    if (rows.isEmpty()) RegistryTaskDetail.Controls.ATTACHMENT_CHOOSE
                    else RegistryTaskDetail.Controls.ATTACHMENT_ADD_ANOTHER,
                ),
            )
        }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
    }
}

/** Matches the provider authority in AndroidManifest.xml (`${applicationId}.attachments`). */
private const val ATTACHMENT_AUTHORITY_SUFFIX = ".attachments"
private const val ANY_TYPE = "*/*"
