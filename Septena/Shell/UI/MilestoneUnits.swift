import Foundation

/// Renders a milestone's unit at *display* time from its stored numeric
/// `value` + `unit` discriminator, so a card or history row honors the user's
/// `WeightUnit` preference instead of the "kg" frozen into the label string at
/// grant time. Stored data stays in kilograms (see `WeightUnit`); only what the
/// user reads changes when they flip to pounds.
///
/// Weight milestones (`unit == "kg"`) are the only ones converted — percent,
/// streak-day, and lifetime-tonnage milestones read the same in every locale.
enum MilestoneUnits {

  /// The unit discriminator for a milestone, falling back to a `kind`-derived
  /// guess for rows granted before the discriminator existed (their stored
  /// `unit` is empty). A legacy `rung` is the only ambiguous case — kg vs % —
  /// so it sniffs the frozen label, which still carries the literal "kg"/"%".
  static func unit(of m: GoalMilestoneEntity) -> String {
    if !m.unit.isEmpty { return m.unit }
    switch m.kind {
    case "pr":     return "kg"
    case "xp":     return "tonnes"
    case "streak": return "days"
    case "rung":   return m.label.contains("%") ? "%" : "kg"
    default:       return ""
    }
  }

  /// The milestone's full label, with any kilogram quantity converted to the
  /// user's preferred unit. A no-op for non-weight milestones and for users on
  /// kilograms. Used by the EditGoalSheet history rows and the VoiceOver
  /// announcement.
  static func label(_ m: GoalMilestoneEntity, weightUnit: WeightUnit = .current) -> String {
    guard unit(of: m) == "kg", weightUnit == .lb else { return m.label }
    return convertingKilograms(m.label, to: weightUnit)
  }

  /// The big headline number on a celebration card, in the user's unit. The
  /// card shows the magnitude only (the caption carries the context), so no
  /// suffix is appended — matching the existing presenter.
  static func headline(_ m: GoalMilestoneEntity, weightUnit: WeightUnit = .current) -> String {
    if unit(of: m) == "kg" {
      return "\(Int(weightUnit.display(m.value).rounded()))"
    }
    return m.value == m.value.rounded() ? String(Int(m.value))
                                        : String(format: "%.1f", m.value)
  }

  /// Replace every "<number> kg" quantity in a string with the same weight in
  /// the target unit (e.g. "Held 74 kg for 30 days" → "Held 163 lb for 30
  /// days"). Converts the numeral adjacent to the unit token, so the midpoint
  /// "Halfway to 74 kg" rung (whose stored `value` is the midpoint, not 74)
  /// still reads correctly.
  private static func convertingKilograms(_ s: String, to u: WeightUnit) -> String {
    s.replacing(/([0-9]+(?:\.[0-9]+)?)\s?kg/) { match in
      let kg = Double(match.1) ?? 0
      return "\(Int(u.display(kg).rounded())) \(u.suffix)"
    }
  }
}
