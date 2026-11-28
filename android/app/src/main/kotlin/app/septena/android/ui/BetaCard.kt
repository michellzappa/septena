package app.septena.android.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.septena.android.AndroidAppGraph
import app.septena.transport.BetaStatus
import app.septena.transport.SeptenaBetaClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

// The beta (ADR 0064): the checklist is a normal project in the tester's list, seeded by the
// server. Android shows one welcome card on Today until the tester opens or closes it. Every
// word comes from `GET /v1/beta`; on a failure or `member: false` nothing shows.

/**
 * The tester's beta state. [state] is null for a non-tester, a signed-out app or a failed
 * read. The card dismissal is optimistic; a refused write reads the server state again.
 */
internal class BetaModel(
    private val client: SeptenaBetaClient,
    private val scope: CoroutineScope,
) {
    private val _state = MutableStateFlow<BetaStatus?>(null)
    val state: StateFlow<BetaStatus?> = _state.asStateFlow()

    /** Reads the beta state again. Today calls it when it opens. */
    fun refresh(signedIn: Boolean) {
        if (!signedIn) {
            _state.value = null
            return
        }
        scope.launch(Dispatchers.IO) {
            runCatching { client.status() }
                .onSuccess { _state.value = it }
                .onFailure { _state.value = null }
        }
    }

    fun dismissCard() {
        if (_state.value == null) return
        _state.update { it?.copy(cardDismissedAtMs = System.currentTimeMillis()) }
        scope.launch(Dispatchers.IO) {
            if (runCatching { client.dismissCard() }.isFailure) {
                runCatching { client.status() }.onSuccess { _state.value = it }
            }
        }
    }
}

/**
 * Today: the one welcome card (`cardTitle`, `cardBody`) until the tester opens or closes it.
 * Open goes to the beta project with [onOpenProject] and closes the card; with no project,
 * open only closes the card.
 */
@Composable
internal fun BetaTodayCard(
    graph: AndroidAppGraph,
    isDark: Boolean,
    hasActiveTexture: Boolean,
    onOpenProject: (projectId: String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val beta by graph.beta.state.collectAsStateWithLifecycle()
    val status = beta ?: return
    if (status.cardDismissedAtMs != null) return
    FadeSweepBannerCard(
        title = status.text("cardTitle"),
        message = status.text("cardBody"),
        reviewLabel = status.text("cardOpen"),
        dismissLabel = status.text("cardDismiss"),
        isDark = isDark,
        hasActiveTexture = hasActiveTexture,
        onReview = {
            graph.beta.dismissCard()
            status.projectId?.let(onOpenProject)
        },
        onDismiss = graph.beta::dismissCard,
        modifier = modifier,
    )
}
