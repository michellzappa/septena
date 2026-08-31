import Foundation
import SwiftData

// Daily message — the optional, off-by-default quote line pinned to the very
// bottom of the home dashboard. Three pieces live here:
//
//   • DailyMessage      — the value type the footer renders (text + source).
//   • QuotePack         — the bundled, offline preset collections.
//   • QuoteEntity/Store — storage for the user's OWN quotes (CloudKit-mirrored,
//                         so curated lines follow them across devices) and their
//                         imported Readwise highlights (DEVICE-LOCAL — see
//                         ReadwiseProvider; a large library as individual
//                         CKRecords flooded sync, so each device re-imports from
//                         its own token instead).
//   • DailyMessageSelector — the deterministic, time-sliced picker.
//
// The on/off switch and the active-pack set are device-local @AppStorage
// (a homepage display preference, like the Day-dial toggles) — NOT synced
// through AppSettings. Only the quote *content* syncs.
//
// No MCP surface: this is presentation + personal config, not queryable life
// data, so neither the in-app server nor the hosted gateway changes.

// MARK: - Value type

public struct DailyMessage: Hashable, Sendable, Identifiable {
  /// The quote itself, verbatim.
  public let text: String
  /// Author or source. May be empty (e.g. an anonymous proverb).
  public let attribution: String
  /// Which source this came from: a `QuotePack.rawValue`, or `"user"` /
  /// `"readwise"` for the stored sources. Used as the pool tag and for `id`.
  public let source: String

  public var id: String { "\(source)|\(text)" }

  public init(text: String, attribution: String, source: String) {
    self.text = text
    self.attribution = attribution
    self.source = source
  }

  /// The primary credit line — the author, or the sole source when that's all we
  /// have. Readwise lines pack `"author\ntitle"`; packs and the user's own
  /// quotes are a single line, so this returns the whole attribution for them.
  public var attributionLead: String {
    attribution.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
      .first.map(String.init) ?? attribution
  }

  /// The secondary credit line — the book / article title — shown beneath the
  /// author when a source carries both. Empty for single-line attributions.
  public var attributionDetail: String {
    let parts = attribution.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
    return parts.count > 1 ? String(parts[1]) : ""
  }
}

// MARK: - Preset packs

/// The bundled quote collections. All content is public-domain (authors
/// pre-1900 / ancient) or anonymous proverb, so nothing here needs a license.
public enum QuotePack: String, CaseIterable, Identifiable, Sendable {
  case practice
  case stoic
  case zen

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .practice: return "Practice"
    case .stoic:    return "Stoic"
    case .zen:      return "Zen & Tao"
    }
  }

  public var subtitle: String {
    switch self {
    case .practice: return "Habits, consistency, the long game"
    case .stoic:    return "Marcus Aurelius, Seneca, Epictetus"
    case .zen:      return "Lao Tzu, the Buddha, Zen proverbs"
    }
  }

  public var messages: [DailyMessage] {
    Self.raw[self]!.map { DailyMessage(text: $0.0, attribution: $0.1, source: rawValue) }
  }

  /// (text, attribution) tuples per pack. Kept as a flat table so the packs
  /// read like a list and stay easy to curate.
  private static let raw: [QuotePack: [(String, String)]] = [
    .practice: [
      ("Well begun is half done.", "Aristotle"),
      ("The beginning is the most important part of the work.", "Plato"),
      ("Little strokes fell great oaks.", "Benjamin Franklin"),
      ("Energy and persistence conquer all things.", "Benjamin Franklin"),
      ("Lost time is never found again.", "Benjamin Franklin"),
      ("It does not matter how slowly you go as long as you do not stop.", "Confucius"),
      ("The man who moves a mountain begins by carrying away small stones.", "Confucius"),
      ("Practice is the best of all instructors.", "Publilius Syrus"),
      ("Patience and perseverance have a magical effect before which difficulties disappear and obstacles vanish.", "John Quincy Adams"),
      ("He who would learn to fly one day must first learn to stand and walk and run and climb and dance.", "Friedrich Nietzsche"),
      ("Drop by drop is the water pot filled.", "The Buddha"),
      ("Constant dripping wears away the stone.", "Proverb"),
      ("Discipline is the soul of an army.", "George Washington"),
    ],
    .stoic: [
      ("You have power over your mind — not outside events. Realize this, and you will find strength.", "Marcus Aurelius"),
      ("Waste no more time arguing about what a good man should be. Be one.", "Marcus Aurelius"),
      ("The happiness of your life depends upon the quality of your thoughts.", "Marcus Aurelius"),
      ("Very little is needed to make a happy life; it is all within yourself, in your way of thinking.", "Marcus Aurelius"),
      ("If it is not right, do not do it; if it is not true, do not say it.", "Marcus Aurelius"),
      ("We suffer more often in imagination than in reality.", "Seneca"),
      ("It is not that we have a short time to live, but that we waste a lot of it.", "Seneca"),
      ("Difficulties strengthen the mind, as labor does the body.", "Seneca"),
      ("Every new beginning comes from some other beginning's end.", "Seneca"),
      ("It's not what happens to you, but how you react to it that matters.", "Epictetus"),
      ("No man is free who is not master of himself.", "Epictetus"),
      ("First say to yourself what you would be; and then do what you have to do.", "Epictetus"),
      ("Wealth consists not in having great possessions, but in having few wants.", "Epictetus"),
    ],
    .zen: [
      ("A journey of a thousand miles begins with a single step.", "Lao Tzu"),
      ("Nature does not hurry, yet everything is accomplished.", "Lao Tzu"),
      ("When I let go of what I am, I become what I might be.", "Lao Tzu"),
      ("Knowing others is wisdom; knowing yourself is enlightenment.", "Lao Tzu"),
      ("Be content with what you have; rejoice in the way things are.", "Lao Tzu"),
      ("When walking, walk. When eating, eat.", "Zen proverb"),
      ("Before enlightenment, chop wood, carry water. After enlightenment, chop wood, carry water.", "Zen proverb"),
      ("The obstacle is the path.", "Zen proverb"),
      ("Let go, or be dragged.", "Zen proverb"),
      ("Sitting quietly, doing nothing, spring comes, and the grass grows by itself.", "Zenrin"),
      ("Peace comes from within. Do not seek it without.", "The Buddha"),
      ("Three things cannot be long hidden: the sun, the moon, and the truth.", "The Buddha"),
    ],
  ]
}

// MARK: - Stored entity

/// One user-curated or Readwise-imported quote. User-added lines are
/// CloudKit-mirrored so they follow the user across devices; Readwise highlights
/// (`origin == "readwise"`) stay device-local and re-import per device — see
/// ReadwiseProvider / QuoteStore.save for why the sync split exists.
@Model
public final class QuoteEntity {
  /// `"user:<uuid>"` for hand-added lines, `"readwise:<highlightId>"` for
  /// imported highlights. The prefix routes CloudKit; the deterministic
  /// Readwise id makes re-sync idempotent.
  @Attribute(.unique) public var id: String

  public var text: String
  public var attribution: String
  /// `"user"` | `"readwise"`. Drives which lines the feature includes and
  /// lets the editor list only the hand-added ones.
  public var origin: String
  public var addedAt: Date

  public var updatedAt: Date
  /// CKSyncEngine per-record system fields. Same pattern as the other
  /// CloudKitSystemFieldsBacked conformances.
  public var cloudKitSystemFields: Data?

  public init(id: String,
              text: String = "",
              attribution: String = "",
              origin: String = "user",
              addedAt: Date = .now,
              updatedAt: Date = .now,
              cloudKitSystemFields: Data? = nil) {
    self.id = id
    self.text = text
    self.attribution = attribution
    self.origin = origin
    self.addedAt = addedAt
    self.updatedAt = updatedAt
    self.cloudKitSystemFields = cloudKitSystemFields
  }

  /// Apply `text`/`attribution`; returns true iff anything changed (so a
  /// re-sync of unchanged Readwise highlights is a genuine no-op — same
  /// guard rationale as `OuraNightEntity.update`).
  @discardableResult
  public func update(text: String, attribution: String) -> Bool {
    var changed = false
    if self.text != text { self.text = text; changed = true }
    if self.attribution != attribution { self.attribution = attribution; changed = true }
    if changed { updatedAt = .now }
    return changed
  }

  public func toMessage() -> DailyMessage {
    DailyMessage(text: text, attribution: attribution, source: origin)
  }
}

/// A highlight pulled from an external source (Readwise), pre-mapped to the
/// fields `QuoteStore.reconcileReadwise` writes.
public struct ImportedQuote: Sendable, Hashable {
  /// Stable source id — becomes `readwise:<sourceID>`.
  public let sourceID: String
  public let text: String
  public let attribution: String

  public init(sourceID: String, text: String, attribution: String) {
    self.sourceID = sourceID
    self.text = text
    self.attribution = attribution
  }
}

// MARK: - Store

/// SwiftData read/write surface for `QuoteEntity`. Late-binds to CKEngine in
/// SeptenaServices.start() so every upsert fans out to CloudKit.
@MainActor
@Observable
public final class QuoteStore {
  public static let shared = QuoteStore()

  private var context: ModelContext { LocalStore.shared.container.mainContext }
  private var ckEngine: CKEngine?

  private init() {}

  func bind(ckEngine: CKEngine) { self.ckEngine = ckEngine }

  /// All stored quotes, optionally filtered to one origin.
  public func all(origin: String? = nil) -> [QuoteEntity] {
    let rows = (try? context.fetch(FetchDescriptor<QuoteEntity>(
      sortBy: [SortDescriptor(\.addedAt, order: .reverse)]
    ))) ?? []
    guard let origin else { return rows }
    return rows.filter { $0.origin == origin }
  }

  /// Stored quotes as render-ready messages.
  public func messages(origin: String? = nil) -> [DailyMessage] {
    all(origin: origin)
      .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .map { $0.toMessage() }
  }

  /// Add a hand-typed quote. No-op on empty text. Posts a data-changed
  /// notification so the footer + editor repaint.
  @discardableResult
  public func addUserQuote(text: String, attribution: String) -> QuoteEntity? {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return nil }
    let a = attribution.trimmingCharacters(in: .whitespacesAndNewlines)
    let entity = QuoteEntity(id: "user:\(UUID().uuidString)",
                             text: t, attribution: a, origin: "user")
    context.insert(entity)
    save(touching: [entity.id])
    return entity
  }

  /// Delete a quote by id (used by the editor for user lines, and by
  /// "Disconnect Readwise" to clear imported rows).
  public func delete(id: String) {
    let descriptor = FetchDescriptor<QuoteEntity>(predicate: #Predicate { $0.id == id })
    guard let entity = try? context.fetch(descriptor).first else { return }
    context.delete(entity)
    StoreHealth.save(context, op: "DailyMessage.delete")
    // Readwise rows are device-local; only user-authored lines sync. See `save`.
    if !id.hasPrefix("readwise:") { ckEngine?.noteQuoteDeletion(id: id) }
    NotificationCenter.default.post(name: .septenaQuotesChanged, object: nil)
  }

  /// Remove every imported Readwise row (called on disconnect). Batched: one
  /// fetch, one delete pass, one save, one CloudKit enqueue — a per-row
  /// `delete(id:)` loop (save + state.add each) hangs the main thread on a large
  /// library.
  public func deleteAllReadwise() {
    let rows = all(origin: "readwise")
    guard !rows.isEmpty else { return }
    for entity in rows { context.delete(entity) }
    guard StoreHealth.save(context, op: "QuoteStore.deleteAll") else { return }
    // Readwise rows are device-local — no CloudKit deletions to enqueue (that's
    // what kept a disconnect from hanging on a large library).
    NotificationCenter.default.post(name: .septenaQuotesChanged, object: nil)
  }

  /// Idempotently make the stored Readwise rows match `quotes` exactly: upsert
  /// the highlights passed in and PRUNE any imported row not in the set. The
  /// prune is what lets "Choose books" work — deselecting a book (or deleting a
  /// highlight in Readwise) drops its lines on the next sync, because the caller
  /// only ever fetches the selected books so `quotes` is the complete desired
  /// set. Unchanged rows earn no save. One fetch of the existing rows up front —
  /// a per-quote `fetch(predicate: id == …)` was O(n) queries on the main thread
  /// and the cause of the freeze on a multi-thousand-highlight library. Wholly
  /// device-local: no CloudKit enqueue for the readwise rows (see `save`).
  public func reconcileReadwise(_ quotes: [ImportedQuote]) {
    // Index existing Readwise rows by id in a single fetch, then diff in memory.
    let existing = Dictionary(all(origin: "readwise").map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
    var desired = Set<String>()
    var touched: [String] = []
    for q in quotes {
      let t = q.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !t.isEmpty else { continue }
      let id = "readwise:\(q.sourceID)"
      desired.insert(id)
      if let entity = existing[id] {
        if entity.update(text: t, attribution: q.attribution) { touched.append(id) }
      } else {
        let entity = QuoteEntity(id: id, text: t, attribution: q.attribution, origin: "readwise")
        context.insert(entity)
        touched.append(id)
      }
    }
    // Drop imported rows the user no longer wants (deselected book / removed
    // highlight). Readwise rows are device-local, so deletion is a plain
    // context.delete — no CloudKit deletion to enqueue.
    var pruned = false
    for (id, entity) in existing where !desired.contains(id) {
      context.delete(entity)
      pruned = true
    }
    guard pruned || !touched.isEmpty else { return }
    save(touching: touched)
  }

  private func save(touching ids: [String]) {
    guard StoreHealth.save(context, op: "QuoteStore.save") else { return }
    // Only user-authored quotes sync to CloudKit. Readwise highlights are
    // device-local (re-imported per device from the user's own token), so a
    // multi-thousand-highlight library never floods the sync engine — the cause
    // of the launch lock-up. ONE batched enqueue for the user lines that remain.
    let synced = ids.filter { !$0.hasPrefix("readwise:") }
    ckEngine?.noteQuoteChanges(ids: synced)
    NotificationCenter.default.post(name: .septenaQuotesChanged, object: nil)
  }
}

// MARK: - Notification

extension Notification.Name {
  /// Posted after QuoteStore mutates. The dashboard footer + Settings editor
  /// listen so freshly-added / synced lines repaint.
  public static let septenaQuotesChanged = Notification.Name("septena.quotes.changed")
}

// MARK: - Selector

/// The deterministic, time-sliced picker. Given the active pool and a
/// (day, slot) seed it returns a stable choice — glancing twice within the
/// same part of the day shows the same line; it rotates at each day-bucket
/// boundary and re-seeds each day.
public enum DailyMessageSelector {
  /// Assemble the candidate pool from the enabled preset packs plus the stored
  /// user + Readwise lines, then de-cluster it by author (see `interleaved`).
  /// Raw, the pool is grouped source-by-source — every highlight of one book in
  /// a run, every Marcus Aurelius line in a row — so the day-anchor lands in a
  /// cluster and tapping for another line walks straight through the rest of it.
  /// Interleaving spreads authors out so consecutive lines come from different
  /// sources.
  public static func pool(packs: Set<QuotePack>,
                          stored: [DailyMessage]) -> [DailyMessage] {
    var out: [DailyMessage] = []
    for pack in QuotePack.allCases where packs.contains(pack) {
      out.append(contentsOf: pack.messages)
    }
    out.append(contentsOf: stored)
    return interleaved(out)
  }

  /// Round-robin the messages across authors (keyed by `attributionLead`) so
  /// adjacent entries come from different sources. Deterministic — group order
  /// is first-appearance, order within a group is preserved — so the (day, slot)
  /// anchor stays stable across launches. Clustering only returns at the tail,
  /// once every other author is exhausted and a single dominant source remains.
  static func interleaved(_ messages: [DailyMessage]) -> [DailyMessage] {
    guard messages.count > 2 else { return messages }
    var order: [String] = []
    var groups: [String: [DailyMessage]] = [:]
    for m in messages {
      let key = m.attributionLead
      if groups[key] == nil { order.append(key) }
      groups[key, default: []].append(m)
    }
    guard order.count > 1 else { return messages }  // single author: nothing to spread
    var result: [DailyMessage] = []
    result.reserveCapacity(messages.count)
    var rank = 0
    var added = true
    while added {
      added = false
      for key in order {
        if let group = groups[key], rank < group.count {
          result.append(group[rank])
          added = true
        }
      }
      rank += 1
    }
    return result
  }

  /// Deterministically pick one message. `day` is the `yyyy-MM-dd` string and
  /// `slot` is the day-bucket order (0…2).
  public static func pick(from pool: [DailyMessage], day: String, slot: Int) -> DailyMessage? {
    guard let index = index(count: pool.count, day: day, slot: slot) else { return nil }
    return pool[index]
  }

  /// The deterministic base index into a pool of `count` for a (day, slot)
  /// seed. Uses a stable FNV-1a hash — Swift's `Hasher` is per-process-
  /// randomized, so it can't anchor a choice that must survive relaunch within
  /// a day. Returns nil for an empty pool. Exposed so the footer can walk
  /// forward from this anchor when the user taps for another line.
  public static func index(count: Int, day: String, slot: Int) -> Int? {
    guard count > 0 else { return nil }
    let seed = "\(day)|\(slot)"
    return Int(fnv1a(seed) % UInt64(count))
  }

  private static func fnv1a(_ string: String) -> UInt64 {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in string.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x00000100000001B3
    }
    return hash
  }
}
