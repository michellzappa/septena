import SwiftUI

/// History series for a homepage domain. Three cases cover every shape
/// the existing tiles render today; new domains pick the closest fit
/// rather than introducing new cases unless genuinely necessary.
///
///   * `.bars`     — single-series N-day count. The default. Used by
///                   habits, chores, supplements, sleep score, nutrition
///                   protein, intake sessions,
///                   groceries bought-per-day, gut movements, activity
///                   steps, tasks completed.
///   * `.centered` — per-day deltas from a baseline; `nil` entries are
///                   missing days that should render as stubs, not as
///                   zero deviation. Today only body weight.
enum HistorySeries {
  case bars([Int])
  case centered(values: [Double?], baseline: Double)
}

/// A short labelled number for the headline area of a domain row/tile.
/// Roughly mirrors `ModuleTile.Stat` but mode-agnostic (no styling).
struct DomainStat {
  let label: String
  let value: String
  var unit: String? = nil
}

/// Optional progress indicator (done-of-total, today-vs-target, etc.).
/// Domains without a meaningful progress concept (sleep, body,
/// groceries) leave this `nil` on `HomepageDomainData`.
struct DomainProgress {
  let label: String
  let current: Double
  let target: Double
  var unit: String? = nil
}

/// What tapping the domain does. Most domains open the matching
/// destination as a sheet; Tasks is special — it switches to the
/// dedicated Tasks tab instead.
enum DomainTapAction {
  case openSheet(WeekDestination)
  case switchToTasksTab
  /// Open one intake tracker's page directly (no switcher hop) — the
  /// per-kind tiles are peers of section tiles, so they deep-open like one.
  case openIntakeKind(String)
}

/// Single mode-agnostic view-model for one homepage domain.
///
/// Phase 1b of the homepage-layout-modes refactor introduces this type
/// as the contract every future renderer (Dense, Heatmap, List) will
/// read from. The current Tiles renderer continues to consume the
/// per-domain `Week*Tile` views directly for now — this struct sits
/// alongside, built once per `loadAll()` cycle, ready for the
/// alternative modes that land in phases 3+.
///
/// Conformances are intentionally minimal — no `Hashable` because
/// `Color` doesn't bridge cleanly across all SwiftUI versions and we
/// don't need it for the use sites planned. Identity comes from
/// `domain` when needed.
struct HomepageDomainData: Identifiable {
  let domain: HomepageDomain
  /// Render identity. One domain = one row was true until intake started
  /// expanding to one row PER tracker — those all share `domain: .intake`, so
  /// keying a ForEach on `\.domain` collapses them into the first row repeated.
  /// Defaults to the domain; intake's per-kind rows pass "intake:<kindID>".
  var itemID: String? = nil
  var id: String { itemID ?? domain.rawValue }
  /// Glyph override for rows that aren't 1=1 with a section — intake's
  /// per-tracker rows pass the kind's own SF Symbol here. Nil = the
  /// section's manifest icon, which is right for every other domain.
  var iconSymbol: String? = nil
  /// The glyph every renderer should draw for this row.
  var icon: String {
    iconSymbol ?? SectionManifest.byKey[domain.rawValue]?.iconSymbol ?? "circle.fill"
  }
  let title: String
  let accent: Color
  /// Compact one-line summary used by Dense / List rows where there
  /// isn't room for the full stats array. Example: "2/5 · 1 skipped".
  let headline: String
  /// Multi-stat header used by Tiles (and a richer Dense layout, if
  /// we choose). Order matters — the first stat is the most prominent.
  let headlineStats: [DomainStat]
  let progress: DomainProgress?
  let history: HistorySeries?
  let tap: DomainTapAction
  /// Render the Dense-mode sparkline as a **trailing-7-day moving
  /// average** instead of raw daily values. For domains where the
  /// natural cadence isn't daily (training, where recovery days
  /// produce zero entries every other day) the raw spikes hide the
  /// real trend — Apple Watch's Exercise / Move charts use the same
  /// smoothing for the same reason.
  ///
  /// Heatmap mode ignores this flag — the heatmap strip *is* the
  /// "did I train today" consistency view and needs daily resolution.
  var smoothSparkline: Bool = false
  /// True when the last element of `history` is a placeholder for
  /// today's still-pending value (e.g. sleep — Oura only records
  /// completed nights, so today reads as 0 until tomorrow morning).
  /// The Heatmap renderer keeps it so the date map anchors to today;
  /// the Sparkline renderer drops it so the line doesn't dive to 0.
  var trailingTodayPending: Bool = false
  /// Scale the Dense-mode `.bars` sparkline's Y-axis to the window's
  /// actual min…max instead of the default 0…max. For domains whose
  /// values live in a narrow band well above zero (sleep score, which
  /// sits in the 70–95 range) the 0-anchored scale flattens the line
  /// into a near-straight bar; min/max framing restores the day-to-day
  /// variation. Count-based domains (tasks, habits) keep the default
  /// 0-anchored scale where "zero" is meaningful.
  var autoscaleSparkline: Bool = false
}
