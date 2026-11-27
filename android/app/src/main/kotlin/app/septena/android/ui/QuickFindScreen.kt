package app.septena.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import app.septena.android.AndroidAppGraph
import app.septena.ui.ChevronLeftGlyph
import app.septena.core.QuickFindCopy
import app.septena.core.QuickFindResult
import app.septena.core.QuickFindTarget

/** Registry-driven local search; the shell supplies result routing. */
@Composable
@OptIn(ExperimentalMaterial3Api::class)
fun QuickFindScreen(
    graph: AndroidAppGraph,
    onBack: () -> Unit,
    onSelect: (QuickFindTarget) -> Unit,
) {
    val factory = remember(graph) { QuickFindViewModelFactory(graph) }
    val viewModel: QuickFindViewModel = viewModel(factory = factory)
    val state by viewModel.state.collectAsStateWithLifecycle()
    val languageTag = LocalConfiguration.current.locales[0].toLanguageTag()
    val copy = remember(languageTag) { QuickFindCopy.fromRegistry(languageTag) }
    val searchFocusRequester = remember { FocusRequester() }

    BackHandler(enabled = true, onBack = onBack)
    LaunchedEffect(Unit) { searchFocusRequester.requestFocus() }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(copy.title) },
                navigationIcon = {
                    IconButton(
                        onClick = onBack,
                        modifier = Modifier.semantics { contentDescription = copy.backTitle },
                    ) {
                        ChevronLeftGlyph(tint = MaterialTheme.colorScheme.onSurface)
                    }
                },
            )
        },
    ) { contentPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(contentPadding)
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            OutlinedTextField(
                value = state.query,
                onValueChange = viewModel::updateQuery,
                modifier = Modifier.fillMaxWidth().focusRequester(searchFocusRequester),
                singleLine = true,
                label = { Text(copy.searchPrompt) },
            )
            when {
                state.isSearching -> Box(
                    modifier = Modifier.weight(1f).fillMaxWidth(),
                    contentAlignment = Alignment.TopCenter,
                ) {
                    CircularProgressIndicator()
                }
                state.query.isBlank() -> QuickFindEmptyState(
                    title = copy.emptyTitle,
                    detail = copy.emptyDetail,
                    modifier = Modifier.weight(1f).fillMaxWidth(),
                )
                state.results.isEmpty() -> QuickFindEmptyState(
                    title = copy.noResultsTitle,
                    detail = copy.noResultsDetail,
                    modifier = Modifier.weight(1f).fillMaxWidth(),
                )
                else -> LazyColumn(
                    modifier = Modifier.weight(1f).fillMaxWidth(),
                    contentPadding = PaddingValues(bottom = 24.dp),
                ) {
                    items(state.results, key = QuickFindResult::id) { result ->
                        val subtitle = copy.subtitleFor(result, languageTag)
                        ListItem(
                            headlineContent = { Text(result.title) },
                            supportingContent = subtitle?.let { { Text(it) } },
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { onSelect(result.target) },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun QuickFindEmptyState(title: String, detail: String, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.padding(horizontal = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(title, style = MaterialTheme.typography.titleMedium)
        Text(
            detail,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
