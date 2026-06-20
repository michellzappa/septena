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

/// The live fasting window for the watch macro complication, so it morphs into a
/// fasting face exactly as the phone's Nutrition tile does. Phone-computed and
/// present only while a fast is running; the complication shows macros otherwise.
struct FastingWire: Codable, Hashable {
  /// The absolute instant the current fast began (now − elapsed), so the wrist
  /// can render a live elapsed timer (stepped by the complication timeline)
  /// instead of a value frozen at publish time.
  var since: Date
  /// "HH:mm" of the meal the fast started from — the phone tile's "since" label.
  var sinceLabel: String
  /// The user's lower fasting target in hours; the ring fills toward it.
  var targetHours: Double
  /// The Fasting metric's authored color token, mirrored from Settings so the
  /// ring matches the phone. Nil → the complication's fixed fallback hue.
  var colorHex: String? = nil
}

/// One ring on the wire: its key, the running total, and the value that fills
/// the ring (nil when there's no target — the view draws a faint empty track
/// instead of a fill). Shared by every rings-style complication.
struct RingMetricWire: Codable, Hashable {
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
struct IntakeKindWire: Codable, Hashable {
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
    var symbol: String? = nil
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
