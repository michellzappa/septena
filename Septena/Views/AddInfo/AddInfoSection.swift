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
    case .nutrition, .caffeine, .cannabis,
         .habits, .supplements, .chores, .gut:                            return .log
    case .tasks, .groceries:                                              return .add
    }
  }

  /// SF Symbol for the row's leading glyph. Picked to read clearly even
  /// when the section accent isn't loaded yet (offline / first launch).
  var systemImage: String {
    switch self {
    case .training:    return "figure.strengthtraining.traditional"
    case .nutrition:   return "fork.knife"
    case .caffeine:    return "cup.and.saucer.fill"
    case .cannabis:    return "leaf.fill"
    case .habits:      return "checkmark.circle"
    case .supplements: return "pills.fill"
    case .chores:      return "house.fill"
    case .gut:         return "drop.fill"
    case .tasks:       return "checklist"
    case .groceries:   return "cart.fill"
    }
  }

  /// Verb glyph shown trailing the verb in the root list.
  var verbSystemImage: String {
    switch verb {
    case .start: return "play.fill"
    case .log:   return "checkmark.circle"
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
}
