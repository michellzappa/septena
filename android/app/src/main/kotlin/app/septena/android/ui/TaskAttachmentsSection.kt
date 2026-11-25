package app.septena.android.ui

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.text.format.Formatter
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.septena.android.AndroidAppGraph
import app.septena.android.AttachmentTooLargeException
import app.septena.core.SyncRecord
import app.septena.core.generated.RegistryTaskDetail
import app.septena.ui.AttachmentSmallGlyph
import app.septena.ui.CloseSmallGlyph
import app.septena.ui.PlusSmallGlyph
import app.septena.ui.TaskCardMetrics
import app.septena.ui.TaskCardSlice
import app.septena.ui.cardPosition
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The task's files (feature `task.attachments`, block `taskPage.attachments`),
 * styled as a continuous glass card matching iOS `TaskAttachmentsPanel`: one
 * row per file with its size, tap opens it in another app, trailing close removes
 * it, and the bottom add row opens the system file picker.
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
    val isDark = LocalSeptenaDarkTheme.current
    val hasActiveTexture = LocalAppearance.current.hasActiveTexture
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
        withContext(Dispatchers.IO) {
            graph.attachments.remove(record)
            graph.touchTask(taskId)
        }
        graph.sync.noteLocalChange()
        graph.sync.requestSync()
    }

    val totalSlices = rows.size + 1
    val mutedInk = MaterialTheme.colorScheme.onSurfaceVariant

    Column(modifier = Modifier.fillMaxWidth()) {
        heading?.let {
            Text(
                text = it,
                fontSize = 18.sp,
                lineHeight = 22.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.padding(
                    start = TaskCardMetrics.HeaderLeading,
                    end = TaskCardMetrics.Margin,
                    top = 14.dp,
                    bottom = 6.dp,
                ),
            )
        }
        rows.forEachIndexed { index, record ->
            val name = graph.attachments.filename(record)
            val removeLabel = control(RegistryTaskDetail.Controls.ATTACHMENT_REMOVE).replace("{name}", name)
            TaskCardSlice(
                position = cardPosition(index, totalSlices),
                isSelected = false,
                isDark = isDark,
                hasActiveTexture = hasActiveTexture,
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(enabled = !busy) { open(record) }
                        .padding(horizontal = TaskCardMetrics.ContentInset, vertical = 10.dp),
                ) {
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier.width(TaskCardMetrics.LeadingColumnWidth),
                    ) {
                        AttachmentSmallGlyph(tint = mutedInk, size = 15.dp)
                    }
                    Spacer(modifier = Modifier.width(TaskCardMetrics.IconTextGap))
                    Column(
                        verticalArrangement = Arrangement.spacedBy(1.dp),
                        modifier = Modifier.weight(1f),
                    ) {
                        Text(
                            text = name,
                            fontSize = 15.sp,
                            lineHeight = 20.sp,
                            color = MaterialTheme.colorScheme.onSurface,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            text = Formatter.formatShortFileSize(context, graph.attachments.byteCount(record)),
                            fontSize = 12.sp,
                            lineHeight = 15.sp,
                            color = mutedInk,
                            maxLines = 1,
                        )
                    }
                    if (canEdit) {
                        IconButton(
                            onClick = { remove(record) },
                            enabled = !busy,
                            modifier = Modifier
                                .size(32.dp)
                                .semantics { contentDescription = removeLabel },
                        ) {
                            CloseSmallGlyph(tint = mutedInk.copy(alpha = 0.75f), size = 13.dp)
                        }
                    }
                }
            }
        }
        TaskCardSlice(
            position = cardPosition(rows.size, totalSlices),
            isSelected = false,
            isDark = isDark,
            hasActiveTexture = hasActiveTexture,
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(enabled = canEdit && !busy) { picker.launch(arrayOf(ANY_TYPE)) }
                    .padding(horizontal = TaskCardMetrics.ContentInset, vertical = 12.dp),
            ) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier.width(TaskCardMetrics.LeadingColumnWidth),
                ) {
                    PlusSmallGlyph(tint = MaterialTheme.colorScheme.primary, size = 15.dp)
                }
                Spacer(modifier = Modifier.width(TaskCardMetrics.IconTextGap))
                Text(
                    text = control(
                        if (rows.isEmpty()) RegistryTaskDetail.Controls.ATTACHMENT_CHOOSE
                        else RegistryTaskDetail.Controls.ATTACHMENT_ADD_ANOTHER,
                    ),
                    fontSize = 15.sp,
                    lineHeight = 20.sp,
                    color = MaterialTheme.colorScheme.primary,
                )
            }
        }
        error?.let {
            Text(
                text = it,
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.padding(horizontal = TaskCardMetrics.HeaderLeading, vertical = 4.dp),
            )
        }
    }
}

/** Matches the provider authority in AndroidManifest.xml (`${applicationId}.attachments`). */
private const val ATTACHMENT_AUTHORITY_SUFFIX = ".attachments"
private const val ANY_TYPE = "*/*"
