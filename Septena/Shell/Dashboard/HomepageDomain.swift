import Foundation

/// Canonical identity + ordering for every domain rendered on the homepage.
///
/// Phase 1 of the homepage-layout-modes refactor introduces this enum as the
/// **single source of truth** for which domains exist and in what order.
/// Previously the order came from two places — `SettingsStore.sections` (server-
/// provided, user-customizable) and a `legacyTileOrder` fallback inside
/// `WeekDashboardView`. That dual system meant the canonical order depended on
/// network state and could differ between the homepage and Settings.
///
/// Going forward:
///   * **Order** is defined here, in `defaultOrder`, and is the same across all
///     future homepage layout modes (Tiles, Dense, Heatmap, List).
///   * **Visibility** still comes from `SettingsStore.sections`: if the server
///     omits a section the user has hidden, that domain is filtered out at the
///     render site. While the server list is still loading (empty), every
///     domain in `defaultOrder` is shown so cold launch never paints blank.
///   * **Label & color** still come from `SectionTheme` / `SettingsStore`, so
///     user customization of accent colors and labels keeps working.
///
/// The raw value matches the legacy section key the server returns from
/// `/api/sections`, which keeps the visibility lookup a direct string compare
/// and avoids any migration of cached blobs.
enum HomepageDomain: String, CaseIterable, Hashable, Identifiable {
  case tasks
  case habits
  case training
  case chores
  case supplements
  case sleep
  case nutrition
  case air
  case groceries
  case caffeine
  case cannabis
  case body
  case gut
  case activity

  var id: String { rawValue }

  /// SF Symbol used by the Dense / List renderers as the leading row
  /// icon. Kept here (not on `HomepageDomainData`) because the icon is
  /// a pure identity attribute — it never depends on today's data.
  var icon: String {
    switch self {
    case .tasks:       return "checklist"
    case .habits:      return "repeat"
    case .training:    return "figure.strengthtraining.traditional"
    case .chores:      return "house"
    case .supplements: return "pills"
    case .sleep:       return "bed.double"
    case .nutrition:   return "fork.knife"
    case .air:         return "wind"
    case .groceries:   return "cart"
    case .caffeine:    return "cup.and.saucer"
    case .cannabis:    return "leaf"
    case .body:        return "scalemass"
    case .gut:         return "circle.bottomhalf.filled"
    case .activity:    return "figure.walk"
    }
  }

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
    .air,
    .groceries,
    .caffeine,
    .cannabis,
    .body,
    .gut,
    .activity,
  ]
}
