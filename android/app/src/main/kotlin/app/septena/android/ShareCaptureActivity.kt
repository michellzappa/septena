package app.septena.android

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.Surface
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.lifecycle.lifecycleScope
import app.septena.android.ui.SeptenaAndroidTheme
import app.septena.android.ui.ShareCaptureScreen
import app.septena.android.widgets.SeptenaWidgetIntents
import app.septena.core.TaskAddedVia
import app.septena.core.TaskRefOther
import app.septena.core.generated.RegistryEntityEnums
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private data class ShareDraft(
    val title: String,
    val notes: String,
    val sourceUrl: String?,
)

class ShareCaptureActivity : ComponentActivity() {
    private val graph by lazy { (application as SeptenaAndroidApp).graph }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val draft = captureDraft(intent)
        setContent {
            SeptenaAndroidTheme(graph.appearance) {
                Surface(modifier = androidx.compose.ui.Modifier.safeDrawingPadding()) {
                    var saving by remember { mutableStateOf(false) }
                    var saveFailed by remember { mutableStateOf(false) }
                    var existing by remember { mutableStateOf<List<TaskRefOther>>(emptyList()) }
                    LaunchedEffect(Unit) {
                        val links = draft.sourceUrl ?: "${draft.title}\n${draft.notes}"
                        existing = withContext(Dispatchers.IO) {
                            runCatching { graph.taskRefLookup.openTasksFor(links, MAX_EXISTING) }.getOrDefault(emptyList())
                        }
                    }
                    ShareCaptureScreen(
                        initialTitle = draft.title,
                        initialNotes = draft.notes,
                        existing = existing,
                        onOpenExisting = { taskId ->
                            startActivity(
                                Intent(this@ShareCaptureActivity, MainActivity::class.java)
                                    .putExtra(SeptenaWidgetIntents.EXTRA_TASK_ID, taskId)
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
                            )
                            finish()
                        },
                        saving = saving,
                        saveFailed = saveFailed,
                        onCancel = { finish() },
                        onSave = { title, notes, today ->
                            if (!saving) {
                                saving = true
                                saveFailed = false
                                lifecycleScope.launch {
                                    runCatching {
                                        withContext(Dispatchers.IO) {
                                            val task = graph.taskMutator.create(
                                                title = title,
                                                notes = notes.ifBlank { null },
                                                today = today,
                                                source = "share_extension",
                                                addedVia = TaskAddedVia.SHARE,
                                            )
                                            draft.sourceUrl?.let { url ->
                                                // The task is saved: a link that is no reference does not undo it.
                                                runCatching {
                                                    graph.taskRefMutator.add(task.id, url, RegistryEntityEnums.TaskRefRole.FROM)
                                                }
                                            }
                                        }
                                    }.onSuccess {
                                        graph.sync.noteLocalChange()
                                        graph.sync.requestSync()
                                        finish()
                                    }.onFailure {
                                        saving = false
                                        saveFailed = true
                                    }
                                }
                            }
                        },
                    )
                }
            }
        }
    }

    private fun captureDraft(incoming: Intent): ShareDraft {
        val sharedText = extractSharedText(incoming)
        val textUrl = URL_PATTERN.find(sharedText)?.value?.trimEnd('.', ',', ';', ')', ']', '}', '"', '\'')
            ?.let { Uri.parse(it) }
            ?.let(::supportedUrl)
        val sharedUrl = supportedUrl(incoming.data) ?: textUrl
        val lines = sharedText.lineSequence().map(String::trim).filter(String::isNotEmpty).toList()
        val title = lines.firstOrNull()
            ?: incoming.getCharSequenceExtra(Intent.EXTRA_TITLE)?.toString()?.trim()?.takeIf(String::isNotEmpty)
            ?: sharedUrl?.host
            ?: sharedUrl?.toString()
            .orEmpty()
        val notes = buildList {
            addAll(lines.drop(1))
            sharedUrl?.toString()?.let(::add)
        }.joinToString("\n")
        return ShareDraft(title, notes, sharedUrl?.toString())
    }

    private fun supportedUrl(uri: Uri?): Uri? = uri?.takeIf {
        it.scheme.equals("https", ignoreCase = true) || it.scheme.equals("http", ignoreCase = true)
    }?.takeIf { !it.host.isNullOrBlank() }

    internal companion object {
        private const val MAX_EXISTING = 3
        val URL_PATTERN = Regex("https?://[^\\s<>\\\"']+", RegexOption.IGNORE_CASE)

        /** Reads text from either `ACTION_SEND` (`EXTRA_TEXT`) or Android's selection menu (`EXTRA_PROCESS_TEXT`). */
        internal fun extractSharedText(incoming: Intent): String =
            (incoming.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)
                ?: incoming.getCharSequenceExtra(Intent.EXTRA_TEXT))
                ?.toString()
                ?.trim()
                .orEmpty()
    }
}
