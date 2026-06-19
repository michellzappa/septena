import SwiftUI

// Per-metric presentation for the rings-style surfaces (the macro + training
// complications and their in-app detail pages), derived from each ring's wire
// `key` so the snapshot stays tiny. Shared across the watch app and the
// complication extension (see project.yml) so the two never disagree about a
// metric's color, order, or label.

// MARK: - Macros (kcal · protein · carbs · fat · fiber)

enum MacroStyle {
  /// Canonical outermost→innermost order. The complication renders rings in this
  /// order and slices the first three for the small circular family.
  static let order = ["kcal", "protein", "carbs", "fat", "fiber"]

  static func color(_ key: String) -> Color {
    // Deliberately off Apple's Activity-ring triad (red / green / cyan): an
    // orange-anchored, green-free palette so the macro rings never read as the
    // Move/Exercise/Stand rings on the same face.
    switch key {
    case "kcal":    return .indigo
    case "protein": return .pink
    case "carbs":   return .blue
    case "fat":     return .yellow
    case "fiber":   return .purple
    default:        return .gray
    }
  }

  /// One-letter chip label for the cramped rectangular legend.
  static func chip(_ key: String) -> String {
    switch key {
    case "protein": return "P"
    case "carbs":   return "C"
    case "fat":     return "F"
    case "fiber":   return "Fi"
    default:        return key.prefix(1).uppercased()
    }
  }

  /// Full label for the roomy in-app detail page legend.
  static func label(_ key: String) -> String {
    switch key {
    case "kcal":    return "Calories"
    case "protein": return "Protein"
    case "carbs":   return "Carbs"
    case "fat":     return "Fat"
    case "fiber":   return "Fiber"
    default:        return key.capitalized
    }
  }

  /// Unit suffix for the detail page ("cal" for energy, grams for the macros).
  static func unit(_ key: String) -> String {
    key == "kcal" ? "cal" : "g"
  }
}

// MARK: - Training (strength · cardio · sessions)

/// Distinct hues from the macro complication so the two faces read differently.
enum TrainingStyle {
  /// Outer→inner order.
  static let order = ["strength", "cardio", "sessions"]

  static func color(_ key: String) -> Color {
    switch key {
    case "strength": return .orange
    case "cardio":   return .green
    case "sessions": return .blue
    default:         return .gray
    }
  }

  /// Full legend label.
  static func label(_ key: String) -> String {
    switch key {
    case "strength": return "Strength"
    case "cardio":   return "Cardio"
    case "sessions": return "Sessions"
    default:         return key.capitalized
    }
  }

  /// Compact unit suffix for the rectangular legend.
  static func unit(_ key: String) -> String {
    switch key {
    case "strength": return "sets"
    case "cardio":   return "min"
    case "sessions": return "sess"
    default:         return ""
    }
  }
}
