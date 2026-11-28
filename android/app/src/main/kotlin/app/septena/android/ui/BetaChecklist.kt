package app.septena.android.ui

import androidx.compose.foundation.clickable
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
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.septena.android.AndroidAppGraph
import app.septena.core.JsonValue
import app.septena.core.RegistryCatalog
import app.septena.core.generated.RegistryTaskDetail
import app.septena.core.stringValue
import app.septena.transport.BetaChecklist
import app.septena.transport.BetaItem
import app.septena.transport.SeptenaBetaClient
import app.septena.ui.ChevronLeftGlyph
import java.text.DateFormat
import java.util.Date
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

// The beta checklist (docs/BETA_ONBOARDING_SPEC.md §7): a Beta row in Settings, the Beta
// screen, and one card on Today. Every word comes from `GET /v1/beta`; on a failure or
// `member: false` nothing shows. No badges, no reminders.

/**
 * The tester's checklist for the whole app. [state] is null for a non-tester, a signed-out
 * app or a failed read. Writes are optimistic; a refused write reads the server state again.
 */
internal class BetaChecklistModel(
    private val client: SeptenaBetaClient,
    private val scope: CoroutineScope,
) {
    private val _state = MutableStateFlow<BetaChecklist?>(null)
    val state: StateFlow<BetaChecklist?> = _state.asStateFlow()

    /** Reads the checklist again. Today and Settings call it when they open. */
    fun refresh(signedIn: Boolean) {
        if (!signedIn) {
            _state.value = null
            return
        }
        scope.launch(Dispatchers.IO) {
            runCatching { client.checklist() }
                .onSuccess { _state.value = it }
                .onFailure { _state.value = null }
        }
    }

    fun setTried(item: String, tried: Boolean) = write({ list ->
        list.copy(tried = if (tried) list.tried + (item to System.currentTimeMillis()) else list.tried - item)
    }) { client.setTried(item, tried) }

    fun acknowledge() = write({ it.copy(ackAtMs = System.currentTimeMillis()) }) { client.acknowledge() }

    fun dismissCard() = write({ it.copy(cardDismissedAtMs = System.currentTimeMillis()) }) { client.dismissCard() }

    private fun write(change: (BetaChecklist) -> BetaChecklist, send: suspend () -> Unit) {
        if (_state.value == null) return
        _state.update { it?.let(change) }
        scope.launch(Dispatchers.IO) {
            if (runCatching { send() }.isFailure) {
                runCatching { client.checklist() }.onSuccess { _state.value = it }
            }
        }
    }
}

/** Settings root: the Beta row (`settingsRow`, `settingsSummary`), only for a tester. */
@Composable
internal fun BetaSettingsRow(graph: AndroidAppGraph, languageTag: String) {
    val checklist by graph.beta.state.collectAsStateWithLifecycle()
    val list = checklist ?: return
    var open by rememberSaveable { mutableStateOf(false) }
    ListItem(
        headlineContent = { Text(list.text("settingsRow")) },
        modifier = Modifier.fillMaxWidth().clickable { open = true },
        trailingContent = {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(list.summary, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text("›", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        },
    )
    HorizontalDivider(modifier = Modifier.padding(top = 4.dp))
    if (open) BetaScreenDialog(graph, languageTag, onClose = { open = false })
}

/** Today: the one welcome card (`cardTitle`, `cardBody`) until the tester opens or closes it. */
@Composable
internal fun BetaTodayCard(
    graph: AndroidAppGraph,
    languageTag: String,
    isDark: Boolean,
    hasActiveTexture: Boolean,
    modifier: Modifier = Modifier,
) {
    val checklist by graph.beta.state.collectAsStateWithLifecycle()
    var open by rememberSaveable { mutableStateOf(false) }
    val list = checklist
    if (list != null && list.cardDismissedAtMs == null) {
        FadeSweepBannerCard(
            title = list.text("cardTitle"),
            message = list.text("cardBody"),
            reviewLabel = list.text("cardOpen"),
            dismissLabel = list.text("cardDismiss"),
            isDark = isDark,
            hasActiveTexture = hasActiveTexture,
            onReview = {
                open = true
                graph.beta.dismissCard()
            },
            onDismiss = graph.beta::dismissCard,
            modifier = modifier,
        )
    }
    if (open) BetaScreenDialog(graph, languageTag, onClose = { open = false })
}

@Composable
private fun BetaScreenDialog(graph: AndroidAppGraph, languageTag: String, onClose: () -> Unit) {
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        BetaScreen(graph, languageTag, onClose)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun BetaScreen(graph: AndroidAppGraph, languageTag: String, onClose: () -> Unit) {
    val checklist by graph.beta.state.collectAsStateWithLifecycle()
    val signedIn by graph.credentials.signedIn.collectAsStateWithLifecycle()
    val syncState by graph.sync.state.collectAsStateWithLifecycle()
    var noteFor by remember { mutableStateOf<BetaItem?>(null) }
    val list = checklist
    if (list == null) {
        LaunchedEffect(Unit) { onClose() }
        return
    }
    val backTitle = remember(languageTag) {
        val controls = RegistryCatalog.surface(RegistryTaskDetail.ID)?.fields?.get("controls") as? JsonValue.ObjectValue
        registryText(controls?.fields?.get("back").stringValue(), languageTag)
    }
    Scaffold(
        modifier = Modifier.fillMaxSize(),
        topBar = {
            TopAppBar(
                title = { Text(list.text("title")) },
                navigationIcon = {
                    IconButton(onClick = onClose, modifier = Modifier.semantics { contentDescription = backTitle }) {
                        ChevronLeftGlyph(tint = MaterialTheme.colorScheme.onSurface)
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
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(list.text("deal"), style = MaterialTheme.typography.titleMedium)
            Text(list.text("intro"), color = MaterialTheme.colorScheme.onSurfaceVariant)
            HorizontalDivider()
            list.items.forEach { item ->
                BetaItemRow(
                    item = item,
                    tried = item.id in list.tried,
                    triedLabel = list.text("tried"),
                    noteLabel = list.text("note"),
                    onTried = { graph.beta.setTried(item.id, it) },
                    onNote = { noteFor = item },
                )
                HorizontalDivider()
            }
            OutlinedButton(onClick = graph.beta::acknowledge, modifier = Modifier.fillMaxWidth()) {
                Text(list.text("ack"))
            }
            list.ackAtMs?.let { at ->
                val date = remember(at) { DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(at)) }
                Text(
                    list.text("ackDone").replace("{date}", date),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
    noteFor?.let { item ->
        Dialog(
            onDismissRequest = { noteFor = null },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            ContactSupportScreen(
                graph = graph,
                signedIn = signedIn,
                syncState = syncState,
                languageTag = languageTag,
                onClose = { noteFor = null },
                // The support form has no subject field: the subject starts the message.
                initialText = list.text("noteSubject").replace("{item}", item.title) + "\n\n",
            )
        }
    }
}

@Composable
private fun BetaItemRow(
    item: BetaItem,
    tried: Boolean,
    triedLabel: String,
    noteLabel: String,
    onTried: (Boolean) -> Unit,
    onNote: () -> Unit,
) {
    Column(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(item.title, style = MaterialTheme.typography.titleSmall)
        Text(item.tryText, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.weight(1f).clickable { onTried(!tried) },
            ) {
                Checkbox(checked = tried, onCheckedChange = onTried)
                Text(triedLabel)
            }
            TextButton(onClick = onNote) { Text(noteLabel) }
        }
    }
}
