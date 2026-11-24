package app.septena.android

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.Surface
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.lifecycle.lifecycleScope
import app.septena.android.ui.SeptenaAndroidTheme
import app.septena.android.ui.ShareCaptureScreen
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private data class ShareDraft(
    val title: String,
    val notes: String,
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
                    ShareCaptureScreen(
                        initialTitle = draft.title,
                        initialNotes = draft.notes,
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
                                            graph.taskMutator.create(
                                                title = title,
                                                notes = notes.ifBlank { null },
                                                today = today,
                                                source = "share_extension",
                                            )
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
        val sharedText = incoming.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            ?.trim()
            .orEmpty()
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
        return ShareDraft(title, notes)
    }

    private fun supportedUrl(uri: Uri?): Uri? = uri?.takeIf {
        it.scheme.equals("https", ignoreCase = true) || it.scheme.equals("http", ignoreCase = true)
    }?.takeIf { !it.host.isNullOrBlank() }

    private companion object {
        val URL_PATTERN = Regex("https?://[^\\s<>\\\"']+", RegexOption.IGNORE_CASE)
    }
}
