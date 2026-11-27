package app.septena.android.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.septena.android.AndroidAppGraph
import app.septena.core.QuickFindResult
import app.septena.core.QuickFindSearch
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.withContext

data class QuickFindUiState(
    val query: String = "",
    val results: List<QuickFindResult> = emptyList(),
    val isSearching: Boolean = false,
)

private data class SearchRequest(val query: String, val dataVersion: Long)
private data class SearchSnapshot(val request: SearchRequest, val results: List<QuickFindResult>)

/** Searches local task and structure records; the store query always runs off the main thread. */
class QuickFindViewModel(private val graph: AndroidAppGraph) : ViewModel() {
    private val query = MutableStateFlow("")
    private val search = QuickFindSearch(graph.taskStore, graph.clock)

    @OptIn(ExperimentalCoroutinesApi::class)
    private val searchSnapshot: StateFlow<SearchSnapshot> = combine(
        query,
        graph.sync.dataVersion,
    ) { value, version -> SearchRequest(value, version) }
        .mapLatest { request ->
            val results = if (request.query.isBlank()) {
                emptyList()
            } else {
                withContext(Dispatchers.IO) { search.search(request.query) }
            }
            SearchSnapshot(request, results)
        }
        .stateIn(
            scope = viewModelScope,
            started = SharingStarted.WhileSubscribed(stopTimeoutMillis = 5_000),
            initialValue = SearchSnapshot(SearchRequest("", -1L), emptyList()),
        )

    val state: StateFlow<QuickFindUiState> = combine(
        query,
        graph.sync.dataVersion,
        searchSnapshot,
    ) { value, version, snapshot ->
        val current = snapshot.request == SearchRequest(value, version)
        QuickFindUiState(
            query = value,
            results = if (current) snapshot.results else emptyList(),
            isSearching = value.isNotBlank() && !current,
        )
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(stopTimeoutMillis = 5_000),
        initialValue = QuickFindUiState(),
    )

    fun updateQuery(value: String) {
        query.value = value
    }
}

internal class QuickFindViewModelFactory(
    private val graph: AndroidAppGraph,
) : androidx.lifecycle.ViewModelProvider.Factory {
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
        require(modelClass.isAssignableFrom(QuickFindViewModel::class.java))
        @Suppress("UNCHECKED_CAST")
        return QuickFindViewModel(graph) as T
    }
}
