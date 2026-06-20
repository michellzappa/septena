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
    // Mirror the phone's `MacroCatalog` default colors, so the fallback — empty
    // tracks before the first sync, and the widget-gallery placeholder, both of
    // which carry no authored `colorHex` — matches the app's macro tiles instead
    // of a different palette. The live wire still overrides per macro with the
    // user's customized tile color (`RingsView` prefers `ring.colorHex`).
    let hex: String
    switch key {
    case "kcal":    hex = "#eab308"
    case "protein": hex = "#ef4444"
    case "carbs":   hex = "#3b82f6"
    case "fat":     hex = "#f59e0b"
    case "fiber":   hex = "#10b981"
    default:        return .gray
    }
    return Color(hexToken: hex) ?? .gray
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

// MARK: - Fasting (single ring — the macro complication's fasting morph)

/// The fasting face the macro complication morphs into during an active fast:
/// one ring filling toward the user's lower fasting target. The default hue
/// mirrors the phone's `MacroCatalog` "fasting" color; the live wire overrides
/// it per-fast with the user's authored color (`RingsView` prefers `colorHex`).
enum FastingStyle {
  static let fallbackHex = "#8b5cf6"

  /// The authored color when present, else the fixed fasting hue.
  static func color(_ colorHex: String? = nil) -> Color {
    Color(hexToken: colorHex) ?? Color(hexToken: fallbackHex) ?? .purple
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
