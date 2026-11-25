package app.septena.android.ui

import android.content.Context
import app.septena.core.JsonValue
import kotlin.math.exp
import kotlin.math.ln

/**
 * On-device "where does this task go?" classifier mirroring Apple
 * `SeptenaCore/SuggestionEngine.swift` (feature `edit.filing-suggestion`, #368).
 *
 * Multinomial Naive Bayes with Laplace smoothing over the user's own filed tasks
 * plus area/project titles. Surfaces a suggestion ONLY when there is real lexical
 * overlap (`minMatchedTokens = 1`) AND a clear margin over #2 (`marginFloor = 0.15`).
 */
data class FilingSuggestion(
    val kind: Kind,
    val id: String,
    val title: String,
    val score: Double,
) {
    enum class Kind { AREA, PROJECT }
}

data class FilingTrainingTask(
    val id: String,
    val title: String,
    val notes: String?,
    val areaId: String?,
    val projectId: String?,
    val isCancelled: Boolean = false,
)

data class FilingTarget(
    val kind: FilingSuggestion.Kind,
    val id: String,
    val title: String,
    val notes: String? = null,
)

class FilingSuggestionEngine(context: Context? = null) {
    private val prefs = context?.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private val rejectedTexts = linkedMapOf<String, MutableList<String>>()

    private data class Model(
        val tokenCount: Map<String, Map<String, Int>>,
        val classTokens: Map<String, Int>,
        val docCount: Map<String, Int>,
        val labels: Map<String, Pair<FilingSuggestion.Kind, String>>,
        val keys: List<String>,
        val vocabSize: Int,
        val totalDocs: Int,
        val rejectedSets: Map<String, List<Set<String>>>,
    )

    @Volatile private var preparedModel: Model? = null
    @Volatile private var cachedSignature: Int? = null

    init {
        loadRejections()
    }

    fun prepare(
        tasks: List<FilingTrainingTask>,
        areas: List<FilingTarget>,
        projects: List<FilingTarget>,
    ) {
        val corpus = tasks.filter { !it.isCancelled && (it.areaId != null || it.projectId != null) }
        val sig = computeSignature(corpus, areas, projects)
        if (sig == cachedSignature && preparedModel != null) return
        cachedSignature = sig
        preparedModel = buildModel(corpus, areas, projects)
    }

    fun suggest(
        title: String,
        notes: String? = null,
        allowedProjectIds: Set<String>? = null,
    ): FilingSuggestion? = rankedSuggestions(title, notes, allowedProjectIds).firstOrNull()

    fun rankedSuggestions(
        title: String,
        notes: String? = null,
        allowedProjectIds: Set<String>? = null,
    ): List<FilingSuggestion> {
        val model = preparedModel ?: return emptyList()
        return classify(tokenize(composite(title, notes)), model, allowedProjectIds)
    }

    fun recordRejection(taskText: String, targetKind: FilingSuggestion.Kind, targetId: String) {
        val key = (if (targetKind == FilingSuggestion.Kind.AREA) "a:" else "p:") + targetId
        val list = rejectedTexts.getOrPut(key) { mutableListOf() }
        list += taskText
        while (list.size > MAX_REJECTIONS_PER_TARGET) list.removeAt(0)
        saveRejections()
        cachedSignature = null
    }

    private fun computeSignature(
        corpus: List<FilingTrainingTask>,
        areas: List<FilingTarget>,
        projects: List<FilingTarget>,
    ): Int {
        var h = 17
        for (a in areas.sortedBy(FilingTarget::id)) h = 31 * h + a.id.hashCode() + a.title.hashCode()
        for (p in projects.sortedBy(FilingTarget::id)) h = 31 * h + p.id.hashCode() + p.title.hashCode()
        for (t in corpus.sortedBy(FilingTrainingTask::id)) {
            h = 31 * h + t.id.hashCode()
            h = 31 * h + t.title.hashCode()
            h = 31 * h + (t.areaId?.hashCode() ?: 0)
            h = 31 * h + (t.projectId?.hashCode() ?: 0)
        }
        h = 31 * h + rejectedTexts.entries.sumOf { it.key.hashCode() + it.value.size }
        return h
    }

    private fun buildModel(
        corpus: List<FilingTrainingTask>,
        areas: List<FilingTarget>,
        projects: List<FilingTarget>,
    ): Model {
        val tokenCount = linkedMapOf<String, MutableMap<String, Int>>()
        val classTokens = linkedMapOf<String, Int>()
        val docCount = linkedMapOf<String, Int>()
        val labels = linkedMapOf<String, Pair<FilingSuggestion.Kind, String>>()
        val vocab = HashSet<String>()

        fun train(key: String, tokens: List<String>, isDoc: Boolean) {
            if (isDoc) docCount[key] = (docCount[key] ?: 0) + 1
            val bucket = tokenCount.getOrPut(key) { linkedMapOf() }
            for (tok in tokens) {
                bucket[tok] = (bucket[tok] ?: 0) + 1
                classTokens[key] = (classTokens[key] ?: 0) + 1
                vocab += tok
            }
        }

        for (a in areas) {
            val key = "a:${a.id}"
            labels[key] = FilingSuggestion.Kind.AREA to a.title
            train(key, tokenize(a.title), isDoc = false)
        }
        for (p in projects) {
            val key = "p:${p.id}"
            labels[key] = FilingSuggestion.Kind.PROJECT to p.title
            train(key, tokenize(composite(p.title, p.notes)), isDoc = false)
        }
        for (t in corpus) {
            val toks = tokenize(composite(t.title, t.notes))
            t.areaId?.let { if ("a:$it" in labels) train("a:$it", toks, isDoc = true) }
            t.projectId?.let { if ("p:$it" in labels) train("p:$it", toks, isDoc = true) }
        }

        val rejectedSets = rejectedTexts.mapValues { (_, texts) ->
            texts.map { tokenize(it).toSet() }
        }

        return Model(
            tokenCount = tokenCount,
            classTokens = classTokens,
            docCount = docCount,
            labels = labels,
            keys = labels.keys.toList(),
            vocabSize = maxOf(vocab.size, 1),
            totalDocs = docCount.values.sum(),
            rejectedSets = rejectedSets,
        )
    }

    private fun classify(
        taskTokens: List<String>,
        model: Model,
        allowedProjectIds: Set<String>?,
    ): List<FilingSuggestion> {
        val keys = if (allowedProjectIds == null) {
            model.keys
        } else {
            if (allowedProjectIds.isEmpty()) return emptyList()
            model.keys.filter { it.startsWith("p:") && it.removePrefix("p:") in allowedProjectIds }
        }
        if (taskTokens.isEmpty() || keys.isEmpty()) return emptyList()
        val taskSet = taskTokens.toSet()

        val logScore = LinkedHashMap<String, Double>(keys.size)
        val matched = LinkedHashMap<String, Int>(keys.size)
        for (key in keys) {
            val counts = model.tokenCount[key].orEmpty()
            val denom = ((model.classTokens[key] ?: 0) + model.vocabSize).toDouble()
            var lp = ln(((model.docCount[key] ?: 0) + 1).toDouble() / (model.totalDocs + keys.size).toDouble())
            var hits = 0
            for (tok in taskTokens) {
                val c = counts[tok] ?: 0
                if (c > 0) hits += 1
                lp += ln((c + 1).toDouble() / denom)
            }
            val rsets = model.rejectedSets[key]
            if (!rsets.isNullOrEmpty()) {
                val overlap = rsets.maxOfOrNull { jaccard(taskSet, it) } ?: 0.0
                lp -= REJECTION_PENALTY * overlap
            }
            logScore[key] = lp
            matched[key] = hits
        }

        val ordered = keys.sortedByDescending { logScore.getValue(it) }
        val probs = softmax(ordered.map { logScore.getValue(it) })
        val ranked = ordered.zip(probs)

        val (topKey, topP) = ranked.firstOrNull() ?: return emptyList()
        val topLabel = model.labels[topKey] ?: return emptyList()
        val secondP = ranked.getOrNull(1)?.second ?: 0.0
        if ((matched[topKey] ?: 0) < MIN_MATCHED_TOKENS || (topP - secondP) < MARGIN_FLOOR) {
            return emptyList()
        }

        val out = mutableListOf(
            FilingSuggestion(
                kind = topLabel.first,
                id = topKey.substring(2),
                title = topLabel.second,
                score = topP,
            ),
        )
        for ((key, p) in ranked.drop(1)) {
            if (p < ALT_FLOOR) continue
            val label = model.labels[key] ?: continue
            out += FilingSuggestion(label.first, key.substring(2), label.second, p)
            if (out.size >= 3) break
        }
        return out
    }

    private fun tokenize(text: String): List<String> = text
        .lowercase()
        .split(NON_WORD_REGEX)
        .filter { it.length > 1 && it !in STOPWORDS }

    private fun composite(title: String, notes: String?): String {
        val clean = notes?.trim().orEmpty()
        return if (clean.isEmpty()) title else "$title. $clean"
    }

    private fun jaccard(a: Set<String>, b: Set<String>): Double {
        if (a.isEmpty() || b.isEmpty()) return 0.0
        val inter = a.count { it in b }
        val union = a.size + b.size - inter
        return if (union == 0) 0.0 else inter.toDouble() / union.toDouble()
    }

    private fun softmax(xs: List<Double>): List<Double> {
        val m = xs.maxOrNull() ?: return emptyList()
        val exps = xs.map { exp(it - m) }
        val sum = exps.sum()
        return if (sum == 0.0) exps else exps.map { it / sum }
    }

    private fun loadRejections() {
        val raw = prefs?.getString(KEY_REJECTIONS, null) ?: return
        val obj = runCatching { JsonValue.parse(raw) as? JsonValue.ObjectValue }.getOrNull() ?: return
        obj.fields.forEach { (k, v) ->
            val items = (v as? JsonValue.ArrayValue)?.values
                ?.mapNotNull { (it as? JsonValue.StringValue)?.value }
                .orEmpty()
            if (items.isNotEmpty()) rejectedTexts[k] = items.toMutableList()
        }
    }

    private fun saveRejections() {
        val json = JsonValue.ObjectValue(
            rejectedTexts.mapValues { (_, list) ->
                JsonValue.ArrayValue(list.map(JsonValue::StringValue))
            },
        ).canonicalJson()
        prefs?.edit()?.putString(KEY_REJECTIONS, json)?.apply()
    }

    companion object {
        private const val PREFS_NAME = "septena_filing_suggestions"
        private const val KEY_REJECTIONS = "rejections_v1"
        private const val MIN_MATCHED_TOKENS = 1
        private const val MARGIN_FLOOR = 0.15
        private const val ALT_FLOOR = 0.15
        private const val REJECTION_PENALTY = 4.0
        private const val MAX_REJECTIONS_PER_TARGET = 50
        private val NON_WORD_REGEX = Regex("[^\\p{L}\\p{N}]+")
        private val STOPWORDS = setOf(
            "the", "a", "an", "to", "of", "and", "or", "for", "in", "on", "at",
            "with", "my", "me", "is", "be", "do", "this", "that", "it",
        )
    }
}
