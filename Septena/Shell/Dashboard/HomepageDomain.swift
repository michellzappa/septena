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
  case air
  case groceries
  case caffeine
  case cannabis
  case body
  case gut
  case mood
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
    case .mood:        return "face.smiling"
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
    .mood,
    .activity,
  ]
}
