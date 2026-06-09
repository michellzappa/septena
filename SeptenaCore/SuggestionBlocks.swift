// SuggestionBlocks — the single source of truth for which Next *suggestions*
// can be quick-logged from a tap (today: the watch), the CloudKit event each
// one writes, and how much input the surface must collect first.
//
// Sibling to `NextBlocks`, which covers the completable Next *members* (chores
// / habits / supplements / tasks). Suggestions are the read-only nudges that
// lead the feed and never "complete" — so acting on one means *logging a new
// event*, which needs its own table: record type + the minimal input shape.
//
// Membership here = "loggable from a Next suggestion." The phone keeps its rich
// sheet routing (`NextSuggestion.Kind.perform`), but the record type and the
// input contract live here once, so the phone and watch can't disagree.
//
// Adding a kind is a one-row edit — the same discipline as `NextBlocks`.
// Deferred for v1 (no coherent zero-/low-input wrist write yet):
//   • training  — `ExerciseEntry` needs a named exercise, not just a type.
//   • fastBreak — `NutritionEntry` needs macros.
// Both slot in here as one row once a wrist input model is designed.
//
// Dependency-free on purpose (no SwiftData / SwiftUI) so it compiles into the
// watch target exactly like `DayBucket` / `NextBlocks`.
public enum SuggestionBlocks {
  /// One quick-loggable suggestion kind.
  public struct Block: Sendable, Hashable {
    /// Suggestion sub-kind — carried to the watch in `NextItem.logKind` and
    /// dispatched on there. Matches `NextSuggestion.Kind.rawValue`.
    public let kind: String
    /// Section key (matches `SectionManifest.key` / the `SectionTheme` accent).
    public let sectionKey: String
    /// CloudKit event record type the watch writer creates.
    public let recordType: String
    /// How much the surface must collect before it can write.
    public let input: Input
  }

  /// The input a surface gathers before writing the event.
  public enum Input: Sendable, Hashable {
    /// Pick one option (e.g. caffeine method, cannabis method). The chosen
    /// `Choice.value` is written to the event's `method` field.
    case choice([Choice])
    /// The two-step mood picker: a 2×2 valence/arousal quadrant grid, then the
    /// chosen quadrant's 3×3 emotion grid. The words + coordinates come from
    /// `MoodVocabulary` (shared with the phone), so the case carries no payload.
    case moodGrid
  }

  /// One option in a `.choice` input.
  public struct Choice: Sendable, Hashable {
    public let value: String    // persisted (e.g. "v60")
    public let label: String    // display (e.g. "V60")
    public let symbol: String?  // optional SF Symbol
    public init(value: String, label: String, symbol: String? = nil) {
      self.value = value; self.label = label; self.symbol = symbol
    }
  }

  /// THE source of truth: one row per quick-loggable suggestion kind.
  public static let all: [Block] = [
    .init(kind: "caffeine", sectionKey: "caffeine", recordType: "CaffeineEvent",
          input: .choice([
            .init(value: "v60",    label: "V60",    symbol: "cup.and.saucer"),
            .init(value: "matcha", label: "Matcha", symbol: "leaf"),
            .init(value: "other",  label: "Other",  symbol: "mug"),
          ])),
    .init(kind: "cannabis", sectionKey: "cannabis", recordType: "CannabisEvent",
          input: .choice([
            .init(value: "vape",   label: "Vape",   symbol: "wind"),
            .init(value: "edible", label: "Edible", symbol: "birthday.cake"),
          ])),
    .init(kind: "mood", sectionKey: "mood", recordType: "MoodEvent",
          input: .moodGrid),
  ]

  /// Constant-time lookup by suggestion sub-kind.
  public static let byKind: [String: Block] =
    Dictionary(uniqueKeysWithValues: all.map { ($0.kind, $0) })

  /// Whether a suggestion of this sub-kind can be logged from a tap. The watch
  /// uses this to decide which nudge rows become interactive.
  public static func isQuickLoggable(kind: String) -> Bool { byKind[kind] != nil }
}
