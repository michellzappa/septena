import SwiftUI

// Single source of truth for the Add Info palette. Mirrors the webapp's
// `lib/quick-log-registry.tsx` — every quick-add destination in one enum,
// each case its own page view. Three verbs (▶ Start, ◉ Log, + Add) cluster
// the actions for scannability in the root list.

enum AddInfoVerb: Hashable {
  case start         // multi-step session (Training)
  case log           // record something that happened
  case add           // queue onto a future-facing list
}

enum AddInfoSection: String, CaseIterable, Identifiable, Hashable {
  case training, nutrition, caffeine, cannabis
  case habits, supplements, chores, gut
  case tasks, groceries

  var id: String { rawValue }

  var title: String {
    switch self {
    case .training:    return "Start Training"
    case .nutrition:   return "Log Meal"
    case .caffeine:    return "Log Caffeine"
    case .cannabis:    return "Log Cannabis"
    case .habits:      return "Log Habit"
    case .supplements: return "Log Supplement"
    case .chores:      return "Log Chore"
    case .gut:         return "Log Gut"
    case .tasks:       return "Add Task"
    case .groceries:   return "Add Grocery"
    }
  }

  var verb: AddInfoVerb {
    switch self {
    case .training:                                                       return .start
    case .caffeine, .cannabis,
         .habits, .supplements, .chores, .gut:                           return .log
    case .nutrition, .tasks, .groceries:                                  return .add
    }
  }

  /// Verb glyph shown as the row's leading icon. Three verbs, three
  /// icons, 1:1 — mirrors the webapp's quick-log registry. We deliberately
  /// don't carry per-section SF Symbols: picking a glyph per section is an
  /// Android/web pattern and made the iOS port feel off.
  var verbSystemImage: String {
    switch verb {
    case .start: return "play.fill"
    case .log:   return "checkmark"
    case .add:   return "plus"
    }
  }

  var placeholder: String {
    switch self {
    case .training:    return "Search sessions…"
    case .nutrition:   return "Search meals…"
    case .caffeine:    return "Search beans…"
    case .cannabis:    return "Search strains…"
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

  /// Stable order for the root Actions group. Mirrors the webapp's
  /// homepage-tile order (training first, capture-style add at the end).
  static let actionOrder: [AddInfoSection] = [
    .training, .nutrition, .caffeine, .cannabis,
    .habits, .supplements, .chores, .gut,
    .tasks, .groceries,
  ]

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
