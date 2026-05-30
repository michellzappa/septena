import Foundation

// On-device "where does this task go?" classifier for the Inbox.
//
// Multinomial Naive Bayes over the user's own assignment history: each
// area / project is a class, trained on the tokens of the tasks already
// filed there (plus the target's own title). Two signals do the work:
//   • Lexical likelihood  P(token | target) — the words you reuse inside a
//     project ("milk", "eggs" → Groceries). This is the workhorse.
//   • Frequency prior      P(target) ∝ how many tasks live there — captures
//     that most inbox items get funneled into a few active projects.
//
// No embeddings, no Core ML / NaturalLanguage asset to download, no async
// warmup — it's a handful of word-count dictionaries recomputed on each
// Inbox refresh. Interpretable, and it learns the instant you file a task.
//
// A guess is only surfaced when there's REAL lexical evidence (the winning
// target actually contains at least one of the task's words) AND it clearly
// beats the runner-up. That gate is the whole point: silence beats a
// confidently-wrong pick — and prevents "everything → your biggest project"
// when a task has no recognizable words (which is just the prior talking).
//
// "Not this" rejections are stored per target and penalize any future task
// that shares words with the rejected text.

@MainActor
@Observable
final class SuggestionEngine {
  struct Suggestion: Hashable {
    enum Kind: Hashable { case area, project }
    let kind: Kind
    let id: String
    let title: String
    /// Softmax posterior P(target | task), 0…1. Stored for display/sorting.
    let score: Double
  }

  static let shared = SuggestionEngine()

  /// task.id → ranked suggestions (best first). The top entry is only present
  /// when it clears the evidence + margin gate; up to two softer runners-up
  /// follow for the context-menu "Suggested" section.
  private(set) var suggestions: [String: [Suggestion]] = [:]

  // MARK: - Tuning knobs
  //
  // NB posteriors are peaked, so the absolute posterior isn't a great gate on
  // its own — the real guards are `minMatchedTokens` (must be genuine lexical
  // overlap, not just the frequency prior) and `marginFloor` (clear winner).
  private let minMatchedTokens = 1     // winner must share ≥ this many words
  private let marginFloor      = 0.15  // top posterior must beat #2 by this
  private let altFloor         = 0.15  // runners-up shown above this posterior
  private let rejectionPenalty = 4.0   // log-space, scaled by token overlap

  private let rejectionsKey = "septena.suggestion.rejections.v1"
  /// "a:<id>" / "p:<id>" → raw "Not this" texts. Persisted so a normal app
  /// upgrade keeps the learning; a clean reinstall loses it.
  private var rejectedTexts: [String: [String]] = [:]

  private init() { loadRejections() }

  // MARK: - Public API

  /// Recompute Inbox suggestions. `allTasks` (every assigned task, any status
  /// except cancelled) is the training corpus; `inbox` are the items to
  /// classify. Synchronous and cheap — call it on each Inbox load.
  func refresh(inbox: [SeptenaTask],
               allTasks: [SeptenaTask],
               projects: [Project],
               areas: [Area]) {
    // ── 1. Train: per-class token counts, class token totals, doc counts ──
    var tokenCount: [String: [String: Int]] = [:]  // classKey → token → n
    var classTokens: [String: Int] = [:]           // classKey → Σ token n
    var docCount: [String: Int] = [:]              // classKey → #tasks
    var labels: [String: (Suggestion.Kind, String)] = [:]
    var vocab = Set<String>()

    func train(_ key: String, _ tokens: [String], isDoc: Bool) {
      if isDoc { docCount[key, default: 0] += 1 }
      for tok in tokens {
        tokenCount[key, default: [:]][tok, default: 0] += 1
        classTokens[key, default: 0] += 1
        vocab.insert(tok)
      }
    }

    // Seed every active target with its title so a brand-new project (no
    // tasks yet) can still win on a title-word match alone.
    for a in areas {
      let key = "a:\(a.id)"
      labels[key] = (.area, a.title)
      train(key, tokenize(a.title), isDoc: false)
    }
    for p in projects where p.status == .active {
      let key = "p:\(p.id)"
      labels[key] = (.project, p.title)
      train(key, tokenize(composite(p.title, p.notes)), isDoc: false)
    }

    for t in allTasks where t.status != .cancelled {
      let toks = tokenize(composite(t.title, t.notes))
      if let aid = t.area    { train("a:\(aid)", toks, isDoc: true) }
      if let pid = t.project { train("p:\(pid)", toks, isDoc: true) }
    }

    let keys = Array(labels.keys)
    guard !keys.isEmpty else { suggestions = [:]; return }
    let vocabSize = max(vocab.count, 1)
    let totalDocs = docCount.values.reduce(0, +)

    // Pre-tokenize rejection texts into sets for overlap scoring.
    var rejectedSets: [String: [Set<String>]] = [:]
    for (key, texts) in rejectedTexts {
      rejectedSets[key] = texts.map { Set(tokenize($0)) }
    }

    // ── 2. Classify each inbox task ──
    var next: [String: [Suggestion]] = [:]
    for t in inbox {
      let taskTokens = tokenize(composite(t.title, t.notes))
      guard !taskTokens.isEmpty else { continue }
      let taskSet = Set(taskTokens)

      var logScore: [String: Double] = [:]
      var matched: [String: Int] = [:]
      for key in keys {
        let counts = tokenCount[key] ?? [:]
        let denom = Double((classTokens[key] ?? 0) + vocabSize)
        // Frequency prior, Laplace-smoothed.
        var lp = log(Double((docCount[key] ?? 0) + 1) / Double(totalDocs + keys.count))
        var hits = 0
        for tok in taskTokens {
          let c = counts[tok] ?? 0
          if c > 0 { hits += 1 }
          lp += log(Double(c + 1) / denom)   // Laplace smoothing
        }
        // "Not this" penalty: shared words with a rejected text for this target.
        if let rsets = rejectedSets[key], !rsets.isEmpty {
          let overlap = rsets.map { jaccard(taskSet, $0) }.max() ?? 0
          lp -= rejectionPenalty * overlap
        }
        logScore[key] = lp
        matched[key] = hits
      }

      // Softmax → posteriors, best first.
      let ordered = keys.sorted { logScore[$0]! > logScore[$1]! }
      let ranked = Array(zip(ordered, softmax(ordered.map { logScore[$0]! })))

      guard let (topKey, topP) = ranked.first, let topLabel = labels[topKey]
      else { continue }

      // Gate: genuine lexical evidence + a clear win over #2.
      let secondP = ranked.count > 1 ? ranked[1].1 : 0
      guard (matched[topKey] ?? 0) >= minMatchedTokens,
            (topP - secondP) >= marginFloor
      else { continue }

      var out = [Suggestion(kind: topLabel.0,
                            id: String(topKey.dropFirst(2)),
                            title: topLabel.1,
                            score: topP)]
      for (key, p) in ranked.dropFirst() where p >= altFloor {
        guard let l = labels[key] else { continue }
        out.append(Suggestion(kind: l.0, id: String(key.dropFirst(2)),
                              title: l.1, score: p))
        if out.count >= 3 { break }
      }
      next[t.id] = out
    }
    suggestions = next
  }

  func topSuggestion(for taskId: String) -> Suggestion? {
    suggestions[taskId]?.first
  }

  func clearSuggestion(for taskId: String) {
    suggestions.removeValue(forKey: taskId)
  }

  /// Persist a "this task does NOT belong here" signal (bounded to 50/target).
  func recordRejection(taskText: String,
                       targetKind: Suggestion.Kind,
                       targetId: String) {
    let key = (targetKind == .area ? "a:" : "p:") + targetId
    var arr = rejectedTexts[key, default: []]
    arr.append(taskText)
    if arr.count > 50 { arr = Array(arr.suffix(50)) }
    rejectedTexts[key] = arr
    saveRejections()
  }

  // MARK: - Tokenize / math

  private static let stopwords: Set<String> = [
    "the", "a", "an", "to", "of", "and", "or", "for", "in", "on", "at",
    "with", "my", "me", "is", "be", "do", "this", "that", "it",
  ]

  private func tokenize(_ s: String) -> [String] {
    s.lowercased()
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
      .filter { $0.count > 1 && !Self.stopwords.contains($0) }
  }

  private func composite(_ title: String, _ notes: String?) -> String {
    let n = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return n.isEmpty ? title : "\(title). \(n)"
  }

  private func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
    guard !a.isEmpty, !b.isEmpty else { return 0 }
    let union = a.union(b).count
    return union == 0 ? 0 : Double(a.intersection(b).count) / Double(union)
  }

  private func softmax(_ xs: [Double]) -> [Double] {
    guard let m = xs.max() else { return [] }
    let exps = xs.map { exp($0 - m) }
    let sum = exps.reduce(0, +)
    return sum == 0 ? exps : exps.map { $0 / sum }
  }

  // MARK: - Rejection persistence

  private func loadRejections() {
    guard let data = UserDefaults.standard.data(forKey: rejectionsKey),
          let dict = try? JSONDecoder().decode([String: [String]].self, from: data)
    else { return }
    rejectedTexts = dict
  }

  private func saveRejections() {
    guard let data = try? JSONEncoder().encode(rejectedTexts) else { return }
    UserDefaults.standard.set(data, forKey: rejectionsKey)
  }
}
