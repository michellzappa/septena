import Foundation

// Wire types for the "Next" feed — the serializable shape shared by the app,
// the Mac app, the watch, and the iOS widget. Kept in its own small file (like
// `DayBucket.swift`) and added to each target's membership so every surface
// decodes the same `WatchSnapshot` payload without a shared framework. This
// replaces the former hand-maintained copy in `SeptenaWatch/WatchModels.swift`.

struct NextItem: Codable, Identifiable, Hashable {
  var id: String
  var kind: String
  var title: String
  var subtitle: String?
  var trailing: String?
  var overdue: Bool
  var sortKey: Int
  /// For a `kind == "suggestion"` row: the suggestion's sub-kind (intake /
  /// mood) when it's quick-loggable from a tap, else nil. Looked up
  /// in `SuggestionBlocks` by the watch to make the row interactive. Optional
  /// and absent on every non-suggestion row, so old payloads decode unchanged.
  var logKind: String? = nil

  enum CodingKeys: String, CodingKey {
    case id, kind, title, subtitle, trailing, overdue
    case sortKey = "sortKey"
    case logKind
  }
}

struct NextItemsResponse: Codable {
  var date: String
  var bucket: String
  var items: [NextItem]
  /// The phone's time-of-day bucket cutoffs at publish time, carried so the
  /// watch applies the same morning/afternoon/evening boundaries the phone uses.
  /// The watch's own app group is a separate container — it never receives
  /// cutoff writes from the phone — so without this the watch always uses the
  /// factory defaults (morning < 12, afternoon < 17), which diverges from any
  /// user-customised setting and makes bucket transitions feel early or late.
  /// Optional so older payloads decode unchanged; the watch falls back to the
  /// factory defaults when absent (same behaviour as before).
  var morningCutoff: Int? = nil
  var afternoonCutoff: Int? = nil
  /// The phone's per-section "carry over missed items" prefs at publish time,
  /// carried in the payload so the watch and widget filter exactly as the phone
  /// would (App Group defaults are per-device and don't cross to the watch).
  /// Optional so older payloads still decode — `itemsForBucket` falls back to the
  /// shipped `NextLinger` defaults when absent.
  var lingerHabits: Bool? = nil
  var lingerSupplements: Bool? = nil
  /// Per-section accent colors (section key → authored color token, e.g.
  /// "#ef4444" / "hsl(...)"), carried so the watch can tint its Next group
  /// rules with the user's *actual* customized colors — the watch target has
  /// no `SectionTheme`. Optional so older payloads decode unchanged; the watch
  /// falls back to a neutral rule when a key is absent.
  var sectionColors: [String: String]? = nil
  /// The user's enabled intake trackers, carried so the watch's + menu always
  /// offers every tracker — with container-aware choices — without compiled-in
  /// rows. Optional so older payloads decode.
  var intakeKinds: [IntakeKindWire]? = nil
  /// The user's most-eaten meals, ranked by frequency then recency and capped to
  /// a wrist-sized list, so the watch + menu can re-log a real meal (macros and
  /// all) with one tap. Optional so older payloads decode.
  var topMeals: [MealWire]? = nil
  /// Today's macro totals-so-far against their targets, so the watch's macro-ring
  /// complication can render Apple-Activity-style rings without replaying the
  /// nutrition zone. Phone-computed (it owns the goals + the daily summary).
  /// Optional so older payloads decode unchanged.
  var nutritionRings: NutritionRingsWire? = nil
  /// This week's (trailing-7-day) strength / cardio / session totals vs targets,
  /// for the watch's training-ring complication. Phone-computed. Optional so
  /// older payloads decode unchanged.
  var trainingRings: TrainingRingsWire? = nil
  /// The live fast, if one is running and the user tracks fasting — so the watch
  /// macro complication can morph into a fasting face exactly as the phone's
  /// Nutrition tile does. Phone-computed (fasting tracking is a phone preference
  /// and the live state machine needs the phone's meal history). Absent when not
  /// fasting, so the complication falls back to the macro rings. Optional so
  /// older payloads decode unchanged.
  var fasting: FastingWire? = nil
  /// The user's active medications, carried so the watch's + menu can mark a
  /// dose taken with one tap. Present only when the Medications section is
  /// enabled (the publisher omits it otherwise), so the wrist menu is dynamic.
  /// Optional so older payloads decode unchanged.
  var medications: [MedicationWire]? = nil
  /// The user's active symptom catalog, carried so the watch's + menu can log a
  /// symptom at a calibrated severity. Present only when the Symptoms section is
  /// enabled. Optional so older payloads decode unchanged.
  var symptoms: [SymptomWire]? = nil
  /// The user's in-stock grocery items, carried so the watch's + menu can mark
  /// one low ("we ran out") with one tap. Present only when the Groceries
  /// section is enabled. Optional so older payloads decode unchanged.
  var groceries: [GroceryWire]? = nil
  /// The keys of the sections currently enabled on the phone, so the watch can
  /// offer section-scoped affordances (e.g. the Next-list "Summaries" links to
  /// the macro / training pages) based on enablement rather than on whether
  /// today's data happened to ride along. Optional so older payloads decode
  /// unchanged — the watch falls back to data-presence when absent.
  var enabledSections: [String]? = nil
  /// The most-recent logged meals (newest first, capped), so the watch's Macros
  /// summary page can list them under the rings — a freshness check: the latest
  /// thing logged on the phone should appear on the wrist. Phone-computed.
  /// Optional so older payloads decode unchanged.
  var recentNutrition: [RecentLogWire]? = nil
  /// The most-recent logged training entries (newest first, capped), listed under
  /// the rings on the watch's training summary page for the same freshness check.
  /// Optional so older payloads decode unchanged.
  var recentTraining: [RecentLogWire]? = nil
  /// Today's intake tally — one row per tracker logged today, so the watch's
  /// Intakes summary page can show "what I've had today" at a glance. Present
  /// only when the Intake section is enabled and something's been logged today.
  /// Optional so older payloads decode unchanged.
  var intakeToday: [IntakeTodayWire]? = nil
}

/// One intake tracker's tally for today on the wire — enough for the wrist's
/// Intakes summary page to show "what I've had today" at a glance. One row per
/// tracker with at least one event today, phone-computed. Read-only.
struct IntakeTodayWire: Codable, Hashable, Identifiable {
  var id: String          // kind id
  var name: String
  var symbol: String? = nil
  var color: String? = nil
  /// How many times the tracker was logged today — the "×N" tally.
  var count: Int
  /// A short phone-formatted summary line, e.g. "3 cups" using the tracker's
  /// count noun. Optional — absent when the kind carries no noun.
  var detail: String? = nil
}

/// One recently-logged row on the wire — enough for a remote surface (watch) to
/// render a compact "last logged" list under a summary page's rings, purely so
/// the user can eyeball whether the snapshot is current. Read-only (no write-back
/// like `MealWire`); everything optional-with-defaults so the wire stays additive.
struct RecentLogWire: Codable, Hashable, Identifiable {
  var id: String
  var emoji: String? = nil
  /// The row's primary line (meal name / exercise name).
  var title: String
  /// A short metric summary for the trailing/secondary text — e.g. "410 kcal" for
  /// a meal, "3×8 · 80kg" or "30 min" for a training entry. Optional.
  var detail: String? = nil
  /// When it was logged, already formatted for display — "14:30" for today, else
  /// a day-prefixed label like "Yesterday 14:30". The wrist only renders it.
  var when: String
}

/// One active medication on the wire: enough for the wrist to render a row and
/// write a "taken" `MedicationDoseEvent`. Built phone-side from the user's
/// non-archived medications; everything optional-with-defaults so the wire
/// stays additive.
struct MedicationWire: Codable, Hashable, Identifiable {
  var id: String
  /// The medication's display name (its `title`).
  var name: String
  /// A short dose/strength detail for the subtitle (e.g. "500 mg"), derived
  /// phone-side. Optional — absent when the med carries no strength/form.
  var detail: String? = nil
}

/// One trackable symptom on the wire: enough for the wrist to render a row and
/// write a `SymptomEvent` at a chosen severity. Built phone-side from the
/// non-archived symptom catalog.
struct SymptomWire: Codable, Hashable, Identifiable {
  var id: String
  /// The symptom's display name (its `title`).
  var name: String
  /// The symptom's emoji glyph, if the user set one.
  var emoji: String? = nil
}

/// One in-stock grocery item on the wire: enough for the wrist to render a row
/// and mark it low (mutating the `GroceryItem` record in place). Built
/// phone-side from items whose `low` flag is currently false.
struct GroceryWire: Codable, Hashable, Identifiable {
  var id: String
  var name: String
  var emoji: String? = nil
  var category: String? = nil
}

/// Today's nutrition macros as concentric "ring" progress — the wire feeding the
/// watch macro complication. Each ring is one macro's running total against the
/// target the user set (a range goal's upper bound, else the legacy
/// `MacrosConfig`). Computed phone-side so the wrist only renders. Kept tiny —
/// it rides the snapshot on every checklist mutation — so the view derives the
/// per-macro label / unit / color from `key` rather than carrying them.
struct NutritionRingsWire: Codable, Hashable {
  /// Ordered outermost→innermost: kcal, protein, carbs, fat, fiber. The macro
  /// complication draws them in this order and slices the first 3 for the small
  /// circular family.
  var rings: [RingMetricWire]
}

/// This week's training as concentric rings — strength, cardio, sessions. Same
/// shape as the macro wire; the complication derives label / unit / color from
/// each ring's `key`.
struct TrainingRingsWire: Codable, Hashable {
  /// Ordered outer→inner: "strength" (weekly hard sets), "cardio" (weekly
  /// minutes), "sessions" (distinct training days this week).
  var rings: [RingMetricWire]
}

/// The fasting *context* for the watch macro complication: the anchor (most
/// recent eating event) plus the target, so the wrist can decide fed-vs-fasting
/// **itself** at its own `now` and morph into a fasting face exactly as the
/// phone's Nutrition tile does.
///
/// Crucially this ships the raw input, not a phone-frozen verdict: the fed→
/// fasting transition and the day rollover both happen overnight while the iOS
/// app is suspended and can't republish. By carrying the absolute last-meal
/// instant, the watch app and the complication timeline re-run the shared
/// `computeFastingState` at each render — so the morph appears on the wrist with
/// no republish. Present whenever the user tracks fasting and has a recent meal;
/// absent (so the wrist shows macros) when fasting is untracked or there's no
/// meal to anchor.
struct FastingWire: Codable, Hashable, Sendable {
  /// The absolute instant of the user's most recent eating event — the fast's
  /// anchor. The watch derives elapsed = now − `lastMealAt` and feeds the same
  /// instant into the state machine, so elapsed and the morph stay live across
  /// midnight without a phone republish.
  var lastMealAt: Date
  /// "HH:mm" of that meal — the phone tile's "since 19:30" label.
  var sinceLabel: String
  /// The user's lower fasting target in hours; the ring fills toward it.
  var targetHours: Double
  /// The Fasting metric's authored color token, mirrored from Settings so the
  /// ring matches the phone. Nil → the complication's fixed fallback hue.
  var colorHex: String? = nil

  #if !WIDGET_EXTENSION
  /// Live fed-vs-fasting at `now`, shared by watch complications so the morph
  /// appears overnight without a republish.
  func liveState(now: Date) -> (isFasting: Bool, elapsed: TimeInterval) {
    let elapsed = max(0, now.timeIntervalSince(lastMealAt))
    let cal = Calendar.current
    // Bucket the anchor by whole-day distance, not just "same day?". The phone
    // anchors to the most recent meal in the last 2 days, so a skipped/unlogged
    // day leaves an anchor that is 2+ days old. Collapsing that into the
    // "yesterday" branch made Case A assert a live fast while elapsed ballooned
    // across the gap (the phantom 37h counter). Only today (Case B) or a genuine
    // yesterday (Case A) is a credible live fast; an older anchor is a data gap,
    // so revert to macros.
    let dayGap = cal.dateComponents(
      [.day], from: cal.startOfDay(for: lastMealAt),
      to: cal.startOfDay(for: now)).day ?? 0
    let inputs: FastingStateInputs
    switch dayGap {
    case 0:
      inputs = FastingStateInputs(todayLatestMeal: sinceLabel,
                                  todayMealCount: 1, yesterdayLastMeal: nil)
    case 1:
      inputs = FastingStateInputs(todayLatestMeal: nil,
                                  todayMealCount: 0, yesterdayLastMeal: sinceLabel)
    default:
      return (false, elapsed)
    }
    let fasting = computeFastingState(inputs: inputs, now: now).isFasting
    return (fasting, elapsed)
  }
  #endif
}

/// One ring on the wire: its key, the running total, and the value that fills
/// the ring (nil when there's no target — the view draws a faint empty track
/// instead of a fill). Shared by every rings-style complication.
struct RingMetricWire: Codable, Hashable, Sendable {
  var key: String
  /// The running total in the metric's unit (grams / kcal / minutes / count).
  var value: Double
  /// The target the ring fills toward — a full ring means it's been reached.
  var goal: Double?
  /// The metric's authored color (hex / hsl token), so the wrist ring matches
  /// the user's Settings color for that metric. Optional — absent on metrics
  /// with no color source, where the complication falls back to a fixed hue.
  var colorHex: String? = nil
}

/// One re-loggable meal on the wire: enough for a remote surface (watch) to
/// render a quick-select chip — emoji, the meal's foods, a macro summary, an
/// ×count badge — and to write a full `NutritionEntry` back from a single tap.
/// Built phone-side from the user's logged meals (the same frequency-then-recency
/// ranking the phone's "+" meal search uses), so the wrist offers exactly the
/// meals the phone would. Everything optional-with-defaults so the wire stays
/// additive.
struct MealWire: Codable, Hashable, Identifiable {
  /// Normalized food signature — stable across re-logs, so it dedupes and makes
  /// a good `Identifiable` id.
  var id: String
  var emoji: String? = nil
  /// The meal's food lines, written back verbatim (newline-joined) on re-log.
  var foods: [String]
  /// How many times this meal was logged in the window — the ×N badge and the
  /// frequency rank (already applied by the publisher).
  var count: Int = 1
  /// Already logged today. The wrist picker keeps the row but grays it so it
  /// reads as done — still tappable to log again. Additive (defaults false)
  /// so older snapshots decode fine.
  var loggedToday: Bool = false
  var proteinG: Double = 0
  var fatG: Double = 0
  var carbsG: Double = 0
  var kcal: Double = 0
  var fiberG: Double? = nil
  var sugarG: Double? = nil
  var saturatedFatG: Double? = nil
  var alcoholG: Double? = nil
  var sodiumMg: Double? = nil
  var cholesterolMg: Double? = nil
  var potassiumMg: Double? = nil

  /// The meal's display name — its first food line.
  var title: String { foods.first ?? "Meal" }

  /// "32P · 14F · 40C · 410kcal" — the quick-select chip's summary line, derived
  /// here so the wire carries the data once and every surface formats it alike.
  var macroSummary: String {
    "\(Int(proteinG.rounded()))P · \(Int(fatG.rounded()))F · "
      + "\(Int(carbsG.rounded()))C · \(Int(kcal.rounded()))kcal"
  }
}

/// One enabled intake tracker on the wire: enough config for a remote surface
/// (watch) to render its quick-log choices via `ConsumableContainer.choices`
/// and write an `IntakeEvent` record. Mirrors the kind's config; everything
/// optional-with-defaults so the wire stays additive.
struct IntakeKindWire: Codable, Hashable, Identifiable {
  var id: String
  var name: String
  var symbol: String? = nil
  var color: String? = nil
  var countNoun: String? = nil
  var containerNoun: String? = nil
  var containerCap: Int? = nil
  /// Today's most recent count on the container method ("Continue (use N)").
  var lastContainerCount: Int? = nil
  /// Whether logging should carry the method's default amount.
  var showsAmount: Bool? = nil
  var methods: [Method] = []

  struct Method: Codable, Hashable {
    var token: String
    var label: String
    var emoji: String? = nil
    var defaultAmount: Double? = nil
    var usesContainer: Bool = false
  }
}

/// UserDefaults keys + defaults for the per-section "carry over missed items"
/// toggle (a.k.a. linger): keep an item on the Next list after its time-of-day
/// bucket has passed, until it's done. Per-device by design — it's a glance
/// filter, so it stays out of the CloudKit schema. The toggle lives in each
/// section's settings; these keys are the shared contract between that toggle,
/// the iOS Next list, and the watch/widget snapshot filter (`itemsForBucket`),
/// so all three live here in SeptenaCore. Defaults preserve shipped behavior:
/// supplements linger, habits stay strict.
public enum NextLinger {
  public static let supplementsKey = "next.linger.supplements"
  public static let supplementsDefault = true
  public static let habitsKey = "next.linger.habits"
  public static let habitsDefault = false
}

/// UserDefaults keys + defaults for the Next view's learned time-of-day
/// **suggestions** — the "log your coffee", "break your fast", mood check-in,
/// and workout-nudge cards (`NextSuggestion.Kind`). Device-local like
/// `NextLinger`: a glance filter, kept out of the CloudKit schema. A master
/// switch plus a per-kind opt-out; defaults preserve shipped behavior
/// (everything on). The phone Next list applies these in
/// `NextSuggestionsModel.load`; the watch snapshot still computes its own
/// suggestions, so watch parity is a deliberate follow-up, not wired here.
public enum NextSuggestionsPrefs {
  public static let enabledKey = "next.suggestions.enabled"
  public static let enabledDefault = true
  /// Per-kind opt-out, keyed by `NextSuggestion.Kind.rawValue`
  /// (training / fastBreak / mood / intake). All default on.
  public static let kindDefault = true
  public static func kindKey(_ rawKind: String) -> String {
    "next.suggestions.\(rawKind)"
  }

  /// Master switch state, honoring the shipped-on default for an unset key.
  public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: enabledKey) as? Bool ?? enabledDefault
  }

  /// Whether a given suggestion kind should surface, given the master switch
  /// and its per-kind opt-out.
  public static func allows(rawKind: String, _ defaults: UserDefaults = .standard) -> Bool {
    guard isEnabled(defaults) else { return false }
    return defaults.object(forKey: kindKey(rawKind)) as? Bool ?? kindDefault
  }
}

extension NextItemsResponse {
  /// The day's open items narrowed to the given time-of-day bucket, ready to show.
  ///
  /// This is the watch/widget twin of the phone's `NextOpenSection` filters
  /// (`habitsNow` / `supplementsNow`) — same rules, same linger prefs (carried in
  /// the payload), so the three surfaces never disagree about what's due now.
  ///
  /// The snapshot payload is all-day (`bucket == ""`) and tags each bucketed item
  /// with its bucket in `subtitle`. Chores and tasks have no time-of-day and always
  /// apply. Habits and supplements are bucketed identically (both optional —
  /// an "anytime" item shows all day); each has the now-implicit bucket stripped
  /// from `subtitle` once it passes `DayBucket.isDueNow`:
  ///   • strict by default for habits (exactly the current bucket), carry-over by
  ///     default for supplements (lingers through later buckets once opened);
  ///   • the per-section linger pref (carried in the payload) flips that. Neither
  ///     ever shows before its window opens.
  func itemsForBucket(_ bucket: DayBucket) -> [NextItem] {
    let lingerHabits = self.lingerHabits ?? NextLinger.habitsDefault
    let lingerSupplements = self.lingerSupplements ?? NextLinger.supplementsDefault
    return items.compactMap { item in
      let linger: Bool
      switch item.kind {
      case "habit":      linger = lingerHabits
      case "supplement": linger = lingerSupplements
      default:           return item   // tasks / chores have no time-of-day
      }
      guard DayBucket.isDueNow(bucketKey: item.subtitle, linger: linger, now: bucket)
      else { return nil }
      var due = item
      due.subtitle = nil
      return due
    }
  }
}
