import Foundation

/// Type-safe identity for every domain that can render as a homepage tile.
/// One case per dashboard-capable section; the raw value matches
/// `SectionEntity.id` / `SectionManifest.key`, so a section key maps to a
/// domain with a direct string compare.
///
/// This enum owns **identity only** — deliberately not order, not visibility:
///   * **Order + visibility** come from `SettingsStore.sections` (the user's
///     CloudKit-mirrored `SectionEntity` set, ordered by `section_order`).
///     The cold-launch fallback, before that mirror hydrates, is the
///     `SectionManifest.all` catalog order — see
///     `WeekDashboardView.visibleDomains`. There is intentionally no
///     hardcoded order list here: that's a second source of truth that
///     drifts from the manifest (and did — every new dashboard section had
///     to be added in two places).
///   * **Label, color, icon** come from `SectionManifest` / `SectionTheme`.
///
/// Calendar is intentionally absent — it surfaces inline in the Next tab,
/// not as a homepage tile.
enum HomepageDomain: String, CaseIterable, Hashable, Identifiable {
  case tasks
  case habits
  case training
  case chores
  case supplements
  case sleep
  case nutrition
  case hydration
  case groceries
  case caffeine
  case cannabis
  case intake
  case body
  case gut
  case mood
  case activity
  case github

  var id: String { rawValue }

  // Icon moved to SectionManifest.iconSymbol (lookup-by-key). Reach it
  // via `SectionManifest.byKey[rawValue]?.iconSymbol`. Going through
  // the manifest lets non-HomepageDomain section keys (goals, future
  // additions) share the same icon registry.
}
