import SwiftUI

// Single source of truth for the Add Info palette's section pages. Each case
// that has a dedicated search/create page in AddInfoSheet maps 1:1 here.
// The root palette list itself is built by `AddInfoPalette` from the user's
// dashboard tile order (all sections + per-kind intake rows).

enum AddInfoSection: String, CaseIterable, Identifiable, Hashable {
  case training, nutrition
  case habits, supplements, chores, gut
  case tasks, groceries

  var id: String { rawValue }

  var title: String {
    switch self {
    case .training:    return "Start Training"
    case .nutrition:   return "Log Meal"
    case .habits:      return "Log Habit"
    case .supplements: return "Log Supplement"
    case .chores:      return "Log Chore"
    case .gut:         return "Log Gut"
    case .tasks:       return "Add Task"
    case .groceries:   return "Add Grocery"
    }
  }

  var placeholder: String {
    switch self {
    case .training:    return "Search sessions…"
    case .nutrition:   return "Search meals…"
    case .habits:      return "Search or add habit…"
    case .supplements: return "Search supplements…"
    case .chores:      return "Search or add chore…"
    case .gut:         return "Search Bristol types…"
    case .tasks:       return "Type task…"
    case .groceries:   return "Type grocery…"
    }
  }

  /// Pages where the search field IS the action — typing a new value with
  /// no match commits a creation on Return.
  var isCreatePage: Bool {
    switch self {
    case .tasks, .groceries, .habits, .chores: return true
    default: return false
    }
  }

  /// Section accent from the live `/api/sections` config, with a neutral
  /// fallback so the row still renders before the theme has refreshed.
  @MainActor
  func accent(theme: SectionTheme) -> Color {
    theme.color(for: rawValue)
  }

  /// Broadcast that this section's tile state has changed (quick-add
  /// committed, item toggled, etc.). The Week dashboard listens and
  /// repaints just that tile from cache + kicks off a background refetch,
  /// so the user sees the new number/progress/bar without waiting for the
  /// next pull-to-refresh.
  func notifyTilesChanged() {
    NotificationCenter.default.post(
      name: .tilesDidChange,
      object: nil,
      userInfo: [TileChangeKey.section: rawValue]
    )
  }
}

extension Notification.Name {
  /// Posted by quick-add pages after a successful commit. UserInfo carries
  /// the `AddInfoSection.rawValue` under `TileChangeKey.section` so the
  /// receiver can scope its refresh to one tile.
  static let tilesDidChange = Notification.Name("septena.tilesDidChange")
}

enum TileChangeKey {
  static let section = "section"
}
