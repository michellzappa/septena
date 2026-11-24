package app.septena.android.ui

import app.septena.ui.RegistryIcon
import app.septena.core.generated.RegistryIconIds
import androidx.compose.material3.IconButton
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
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import app.septena.android.AndroidAppGraph
import app.septena.core.RegistryCatalog
import app.septena.core.JsonValue
import app.septena.core.generated.RegistryActionIds
import app.septena.core.stringValue

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
                colors = pageTopAppBarColors(),
                title = { Text(copy.title) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        RegistryIcon(RegistryIconIds.ACTION_BACK, contentDescription = copy.backTitle)
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
                        val subtitle = result.subtitle ?: result.subtitleKey?.let { key ->
                            when (key) {
                                QuickFindSubtitle.Completed -> copy.completedLabel
                                is QuickFindSubtitle.Destination -> RegistryCatalog.destinationTitle(
                                    key.id,
                                    languageTag,
                                )
                            }
                        }
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

private data class QuickFindCopy(
    val title: String,
    val backTitle: String,
    val searchPrompt: String,
    val emptyTitle: String,
    val emptyDetail: String,
    val noResultsTitle: String,
    val noResultsDetail: String,
    val completedLabel: String,
) {
    companion object {
        fun fromRegistry(languageTag: String): QuickFindCopy {
            val surface = RegistryCatalog.surface("quickFind")
            fun copy(vararg path: String): String {
                var value: JsonValue? = surface
                path.forEach { key ->
                    value = (value as? JsonValue.ObjectValue)?.fields?.get(key)
                }
                val source = value.stringValue().orEmpty()
                return RegistryCatalog.localizedString(source, languageTag).orEmpty()
            }
            return QuickFindCopy(
                title = RegistryCatalog.actionTitle(
                    RegistryActionIds.APP_QUICK_FIND,
                    languageTag = languageTag,
                ).orEmpty(),
                backTitle = copy("controls", "back"),
                searchPrompt = copy("placeholder"),
                emptyTitle = copy("emptyState", "title"),
                emptyDetail = copy("emptyState", "detail"),
                noResultsTitle = copy("noResults", "title"),
                noResultsDetail = copy("noResults", "detail"),
                completedLabel = copy("completed", "label"),
            )
        }
    }
}
