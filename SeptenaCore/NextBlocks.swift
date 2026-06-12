// NextBlocks — the single source of truth for the "Next" feed's
// composition: which sections are members, in what fallback order, the
// `NextItem.kind` each one emits, and how a completion is persisted.
//
// Historically this knowledge was duplicated across surfaces that silently
// drifted whenever Next gained or lost a section:
//   1. `NextFeed.sectionKeys`              — the membership list
//   2. `NextFeed.flat`'s key→kind map      — section key → NextItem.kind
//   3. iOS `NextOpenSection`'s two switches — `isEmpty(_:)` + `block(for:)`
//   4. `WatchConnectivity.complete`'s switch — kind → CloudKit writer
//
// Now every surface derives from `NextBlocks.all`. Adding or removing a
// Next block is a one-row edit here; the feed builder, the iOS list, and
// the watch completion dispatch all follow. The rendering/writing switches
// stay per-platform — an interactive SwiftUI row and a CloudKit write are
// irreducibly bespoke — but each carries a `default` + `assertionFailure`
// so a row added here without its matching code fails loudly in debug.
//
// Suggestions (intake / training / fast-break) are NOT in this
// table. They're read-only nudges that lead the feed, never complete, and
// don't participate in the saved order — see `NextFeed.flat`. Membership in
// this table *is* the definition of "completable in Next".
//
// Dependency-free on purpose (no SwiftData / SwiftUI), so it compiles into
// the watch target the same way `DayBucket` does and the phone & watch can
// never disagree about Next's membership.
public enum NextBlocks {
  /// One member section of the Next feed.
  public struct Block: Sendable, Hashable {
    /// Section key — matches `SectionEntity.id`, the saved section order,
    /// and `SectionManifest.key`.
    public let sectionKey: String
    /// The `NextItem.kind` (singular) this block emits and the watch
    /// dispatches on.
    public let itemKind: String
    /// How a completion for this block's item is persisted to CloudKit.
    public let completion: Completion
  }

  /// How a completed Next item is written. Selects the *strategy*; the
  /// per-record field details stay in each surface's writer (the watch's
  /// CloudKit helpers, the phone's `ChecklistMutator`), since those are
  /// genuinely type-specific.
  public enum Completion: Sendable, Hashable {
    /// Mutate the existing record in place (Tasks: status → done).
    case recordStatus
    /// Append/update a per-day event record of this CloudKit type
    /// (Habits / Supplements / Chores).
    case event(recordType: String)
  }

  /// THE source of truth: one row per Next block, in fallback order.
  /// Calendar is intentionally absent — it no longer surfaces in Next.
  public static let all: [Block] = [
    .init(sectionKey: "tasks",       itemKind: "task",       completion: .recordStatus),
    .init(sectionKey: "chores",      itemKind: "chore",      completion: .event(recordType: "ChoreEvent")),
    .init(sectionKey: "habits",      itemKind: "habit",      completion: .event(recordType: "HabitEvent")),
    .init(sectionKey: "supplements", itemKind: "supplement", completion: .event(recordType: "SupplementEvent")),
  ]

  /// Member section keys in fallback order.
  public static let sectionKeys: [String] = all.map(\.sectionKey)

  /// Constant-time lookups, built once.
  public static let bySectionKey: [String: Block] =
    Dictionary(uniqueKeysWithValues: all.map { ($0.sectionKey, $0) })
  public static let byItemKind: [String: Block] =
    Dictionary(uniqueKeysWithValues: all.map { ($0.itemKind, $0) })

  /// Whether a `NextItem.kind` is a completable member (vs. a read-only
  /// suggestion). The watch uses this to ignore nudges without hard-coding
  /// the kind set a second time.
  public static func isCompletable(kind: String) -> Bool {
    byItemKind[kind] != nil
  }

  /// Member keys in the user's saved order, filtered to those still in the
  /// table, falling back to the full list when the caller has no enabled
  /// keys yet (cold launch before the settings mirror hydrates) so Next
  /// never paints blank.
  public static func orderedSectionKeys(enabledKeys: [String]) -> [String] {
    let ranked = enabledKeys.filter { bySectionKey[$0] != nil }
    return ranked.isEmpty ? sectionKeys : ranked
  }
}
