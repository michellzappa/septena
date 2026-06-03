import Foundation

/// Canonical identity + ordering for every domain rendered on the homepage.
///
/// Phase 1 of the homepage-layout-modes refactor introduces this enum as the
/// **single source of truth** for which domains exist and in what order.
/// Previously the order came from two places — `SettingsStore.sections`
/// (user-customizable) and a `legacyTileOrder` fallback inside
/// `WeekDashboardView`. That dual system meant the canonical order could
/// differ between the homepage and Settings.
///
/// Going forward:
///   * **Order** is defined here, in `defaultOrder`, and is the same across all
///     future homepage layout modes (Tiles, Dense, Heatmap, List).
///   * **Visibility** comes from `SettingsStore.sections` — the user's
///     CloudKit-mirrored `SectionEntity` set. A section the user has hidden
///     is filtered out at the render site; an empty set (cold launch before
///     the local mirror has hydrated) falls back to `defaultOrder` so we
///     never paint blank.
///   * **Label & color** come from `SectionTheme` / `SettingsStore`, so
///     user customization of accent colors and labels keeps working.
///
/// The raw value matches `SectionEntity.id`, which keeps the visibility
/// lookup a direct string compare against the user's installed set.
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
  case body
  case gut
  case mood
  case activity

  var id: String { rawValue }

  // Icon moved to SectionManifest.iconSymbol (lookup-by-key). Reach it
  // via `SectionManifest.byKey[rawValue]?.iconSymbol`. Going through
  // the manifest lets non-HomepageDomain section keys (goals, future
  // additions) share the same icon registry.

  /// The canonical homepage order. Every layout mode iterates this list; the
  /// renderer is what varies per mode, not the sequence.
  ///
  /// Calendar is intentionally absent — it surfaces inline in the Next tab,
  /// not as a homepage tile (matches the previous `tile(for:)` behaviour
  /// which rendered `EmptyView` for the `"calendar"` key).
  static let defaultOrder: [HomepageDomain] = [
    .tasks,
    .habits,
    .training,
    .chores,
    .supplements,
    .sleep,
    .nutrition,
    .hydration,
    .groceries,
    .caffeine,
    .cannabis,
    .body,
    .gut,
    .mood,
    .activity,
  ]
}
