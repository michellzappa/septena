import Foundation
import NaturalLanguage

// Local semantic sorter for the Inbox.
//
// Why this design beats a naive "embed the project title" approach:
//  • Contextual embeddings. NLContextualEmbedding (BERT-class, ships with
//    macOS) gives per-token vectors we mean-pool — far stronger on short
//    labels than NLEmbedding's static sentence model.
//  • Each target's vector is a BLEND of its label and the centroid of its
//    existing tasks. "Errands" stops being defined by the word "Errands"
//    and starts being defined by {buy milk, pick up dry cleaning, …}.
//    The user trains the model implicitly every time they assign a task —
//    no extra signal needed.
//  • Per-target rejection penalty. "Not this" on the chip stores the task
//    text; on the next refresh we re-embed and subtract a fraction of the
//    similarity from anything semantically close to that rejection. Tiny
//    UserDefaults blob persists across launches.
//
// Engine is process-global. The vector cache survives filter swaps so
// re-entering Inbox is free after the first refresh.

@MainActor
@Observable
final class SuggestionEngine {
  struct Suggestion: Hashable {
    enum Kind: Hashable { case area, project }
    let kind: Kind
    let id: String
    let title: String
    let score: Double
  }

  static let shared = SuggestionEngine()

  /// task.id → ranked suggestions (best first). Empty when nothing clears
  /// the confidence floor; up to 3 entries when there's a real signal.
  private(set) var suggestions: [String: [Suggestion]] = [:]

  /// task.id → embedding vector. Cached by content hash so unchanged tasks
  /// don't re-embed across refreshes.
  private var taskVectors: [String: [Double]] = [:]
  private var taskTextHash: [String: Int] = [:]

  /// "a:<id>" / "p:<id>" → blended (label + centroid of assigned tasks).
  private var targetCentroids: [String: [Double]] = [:]

  /// User-recorded "Not this" texts, keyed by target. Re-embedded on each
  /// refresh and applied as a similarity-proximity penalty.
  private var rejectedTexts: [String: [String]] = [:]
  private var rejectedVectors: [String: [[Double]]] = [:]

  /// Contextual model. Loaded asynchronously the first time the app runs
  /// (downloads the asset on first launch). Suggestions are suppressed
  /// entirely until it's ready — better to show nothing than to show
  /// confidently-wrong picks from a weaker model.
  private var contextual: NLContextualEmbedding?

  /// Cosine floor for surfacing a chip at all. Contextual embeddings tend
  /// to score short-text pairs higher than the static sentence model, so
  /// this is a touch above what NLEmbedding alone needed.
  private let minScore: Double = 0.45
  /// Blend weights — when a target has at least one assigned task, the
  /// centroid of those tasks dominates the label. With no tasks the
  /// centroid is empty and the label carries the full signal.
  private let labelWeight: Double = 0.3
  private let centroidWeight: Double = 0.7
  /// Subtracted from a target's score, scaled by the inbox task's max
  /// similarity to any rejected text for that target. 0.6 is strong enough
  /// to flip a borderline pick off the chip after one rejection.
  private let rejectionPenalty: Double = 0.6

  private let rejectionsDefaultsKey = "septena.suggestion.rejections.v1"

  private init() {
    loadRejections()
    Task { await prepareContextualModel() }
  }

  // MARK: - Public API

  /// Recompute suggestions. `allTasks` is needed because target centroids
  /// are built from every task already assigned to a project / area —
  /// that's the "auto-learning from your inputs" channel.
  func refresh(inbox: [SeptenaTask],
               allTasks: [SeptenaTask],
               projects: [Project],
               areas: [Area]) {
    // 1. Make sure every task we'll touch has a cached embedding.
    for t in inbox { embedIfNeeded(task: t) }
    for t in allTasks where t.status != .cancelled { embedIfNeeded(task: t) }

    // 2. Bucket assigned tasks by target so we can build centroids.
    var byTarget: [String: [String]] = [:]
    for t in allTasks where t.status != .cancelled {
      if let aid = t.area   { byTarget["a:\(aid)", default: []].append(t.id) }
      if let pid = t.project { byTarget["p:\(pid)", default: []].append(t.id) }
    }

    // 3. Compute target centroids = blended(label, mean(assigned-task vecs)).
    var centroids: [String: [Double]] = [:]
    var labels: [String: (Suggestion.Kind, String)] = [:]
    for a in areas {
      let key = "a:\(a.id)"
      let labelVec = embed(text: composite(title: a.title, extras: [a.context])) ?? []
      let taskVecs = (byTarget[key] ?? []).compactMap { taskVectors[$0] }
      centroids[key] = blend(label: labelVec, taskVecs: taskVecs)
      labels[key] = (.area, a.title)
    }
    for p in projects where p.status == .active {
      let key = "p:\(p.id)"
      let labelVec = embed(text: composite(title: p.title,
                                           extras: [p.context, p.notes])) ?? []
      let taskVecs = (byTarget[key] ?? []).compactMap { taskVectors[$0] }
      centroids[key] = blend(label: labelVec, taskVecs: taskVecs)
      labels[key] = (.project, p.title)
    }
    targetCentroids = centroids

    // 4. Re-embed rejection texts (cheap; few per target).
    var rVecs: [String: [[Double]]] = [:]
    for (key, texts) in rejectedTexts {
      rVecs[key] = texts.compactMap { embed(text: $0) }
    }
    rejectedVectors = rVecs

    // 5. Score each inbox task against every target, apply rejection
    //    penalty, keep top-3 above the floor.
    var next: [String: [Suggestion]] = [:]
    for t in inbox {
      guard let tv = taskVectors[t.id], !tv.isEmpty else { continue }
      var scored: [(key: String, score: Double)] = []
      for (key, cv) in centroids where !cv.isEmpty && cv.count == tv.count {
        var s = Self.cosine(tv, cv)
        if let rvs = rejectedVectors[key], !rvs.isEmpty {
          let maxRej = rvs.compactMap { $0.count == tv.count ? Self.cosine(tv, $0) : nil }
            .max() ?? 0
          s -= rejectionPenalty * maxRej
        }
        scored.append((key, s))
      }
      scored.sort { $0.score > $1.score }
      let top3 = scored.prefix(3).compactMap { entry -> Suggestion? in
        guard entry.score >= minScore, let label = labels[entry.key] else { return nil }
        let id = String(entry.key.dropFirst(2))
        return Suggestion(kind: label.0,
                          id: id,
                          title: label.1,
                          score: entry.score)
      }
      if !top3.isEmpty { next[t.id] = Array(top3) }
    }
    suggestions = next
  }

  func topSuggestion(for taskId: String) -> Suggestion? {
    suggestions[taskId]?.first
  }

  /// Runners-up under the top pick — surfaced in the chip's right-click menu.
  func alternatives(for taskId: String) -> [Suggestion] {
    Array((suggestions[taskId] ?? []).dropFirst())
  }

  func clearSuggestion(for taskId: String) {
    suggestions.removeValue(forKey: taskId)
  }

  /// Persist a "this task does NOT belong here" signal. The text is stored
  /// raw in UserDefaults so reinstalling-from-scratch loses it, but a normal
  /// app upgrade keeps it. Bounded to 50 per target.
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

  // MARK: - Embedding

  private func embedIfNeeded(task: SeptenaTask) {
    let text = composite(title: task.title, extras: [task.notes])
    let h = text.hashValue
    if taskTextHash[task.id] == h, taskVectors[task.id] != nil { return }
    if let v = embed(text: text) {
      taskVectors[task.id] = v
      taskTextHash[task.id] = h
    }
  }

  private func embed(text: String) -> [Double]? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let m = contextual else { return nil }
    return embedContextual(trimmed, model: m)
  }

  private func embedContextual(_ s: String,
                               model: NLContextualEmbedding) -> [Double]? {
    guard let result = try? model.embeddingResult(for: s, language: .english) else {
      return nil
    }
    var sum = [Double](repeating: 0, count: model.dimension)
    var count = 0
    result.enumerateTokenVectors(in: s.startIndex..<s.endIndex) { vec, _ in
      for i in 0..<min(vec.count, sum.count) { sum[i] += vec[i] }
      count += 1
      return true
    }
    guard count > 0 else { return nil }
    return sum.map { $0 / Double(count) }
  }

  private func prepareContextualModel() async {
    guard let m = try? NLContextualEmbedding(language: .english) else { return }
    if !m.hasAvailableAssets {
      // First launch downloads ~tens of MB from Apple's CDN. Best-effort —
      // we keep using the fallback model until it lands.
      _ = try? await m.requestAssets()
    }
    do {
      try m.load()
      contextual = m
      SeptenaLog.info("SuggestionEngine: NLContextualEmbedding loaded (dim=\(m.dimension))")
    } catch {
      SeptenaLog.error("NLContextualEmbedding.load failed", error)
    }
  }

  // MARK: - Math

  /// Blend = α·normalize(label) + β·normalize(centroid). Both legs normalized
  /// so a 5-word label can't out-magnitude a 50-task centroid (or vice
  /// versa). Falls back gracefully when either leg is missing.
  private func blend(label: [Double], taskVecs: [[Double]]) -> [Double] {
    if taskVecs.isEmpty { return label }
    let dim = taskVecs[0].count
    var centroid = [Double](repeating: 0, count: dim)
    for v in taskVecs where v.count == dim {
      for i in 0..<dim { centroid[i] += v[i] / Double(taskVecs.count) }
    }
    guard !label.isEmpty, label.count == dim else { return centroid }
    let nLabel = Self.normalize(label)
    let nCent = Self.normalize(centroid)
    var out = [Double](repeating: 0, count: dim)
    for i in 0..<dim {
      out[i] = labelWeight * nLabel[i] + centroidWeight * nCent[i]
    }
    return out
  }

  private static func normalize(_ v: [Double]) -> [Double] {
    var sq = 0.0
    for x in v { sq += x * x }
    let norm = sq.squareRoot()
    return norm == 0 ? v : v.map { $0 / norm }
  }

  private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot = 0.0, na = 0.0, nb = 0.0
    for i in 0..<a.count {
      dot += a[i] * b[i]
      na += a[i] * a[i]
      nb += b[i] * b[i]
    }
    let denom = na.squareRoot() * nb.squareRoot()
    return denom == 0 ? 0 : dot / denom
  }

  // MARK: - Helpers

  private func composite(title: String, extras: [String?]) -> String {
    var parts = [title]
    for e in extras {
      let t = e?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !t.isEmpty { parts.append(t) }
    }
    return parts.joined(separator: ". ")
  }

  // MARK: - Rejection persistence

  private func loadRejections() {
    guard let data = UserDefaults.standard.data(forKey: rejectionsDefaultsKey),
          let dict = try? JSONDecoder().decode([String: [String]].self, from: data)
    else { return }
    rejectedTexts = dict
  }

  private func saveRejections() {
    guard let data = try? JSONEncoder().encode(rejectedTexts) else { return }
    UserDefaults.standard.set(data, forKey: rejectionsDefaultsKey)
  }
}
