import AppIntents
import Foundation

// Nutrition — section intents. Conforms to the canonical `SectionLogIntent`
// pattern (see SupplementIntents.swift): a thin intent that boots the stack
// and auto-enables the section via `prepareSection()`, then drives the
// `NutritionMutator`. Mutator + entity types come from SeptenaCore (same
// module — no import needed). Siri phrases live in `SeptenaShortcuts`
// (SectionLogIntent.swift); see SHORTCUTS_TO_ADD in the handoff.
//
// No catalog entity here: a meal is free text ("chicken salad, rice"), so
// there's nothing pickable to back with an AppEntity/EntityQuery. Macros are
// estimated elsewhere (the MCP agent / in-app editor); a spoken log just
// captures what was eaten — macros default to 0 and kcal auto-computes.

// MARK: - Meal type

/// Optional meal classification, mirroring the nutrition export/MCP contract
/// (`breakfast | lunch | dinner | snack`). Backs the optional `mealType`
/// parameter; rawValues feed `NutritionMutator.addEntry(mealType:)` verbatim.
enum MealType: String, AppEnum {
  case breakfast
  case lunch
  case dinner
  case snack

  static var typeDisplayRepresentation: TypeDisplayRepresentation { "Meal Type" }

  static var caseDisplayRepresentations: [MealType: DisplayRepresentation] {
    [
      .breakfast: "Breakfast",
      .lunch: "Lunch",
      .dinner: "Dinner",
      .snack: "Snack",
    ]
  }
}

// MARK: - Intents

/// The daily log action: record a meal eaten now. `foods` is free text; the
/// mutator stores it as a newline-joined list, so we split the spoken/typed
/// value on newlines and commas, trim, and drop empties (matching the in-app
/// entry sheets and the plugin's newline-/comma-separated convention).
struct LogMealIntent: SectionLogIntent {
  static let sectionKey = "nutrition"
  static let title: LocalizedStringResource = "Log a Meal"
  static let description = IntentDescription("Log what you ate to Septena.")

  @Parameter(title: "Foods", requestValueDialog: "What did you eat?")
  var foods: String

  @Parameter(title: "Meal Type")
  var mealType: MealType?

  static var parameterSummary: some ParameterSummary {
    Summary("Log \(\.$foods) as \(\.$mealType)")
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    await prepareSection()
    let items = foods
      .split(whereSeparator: { $0.isNewline || $0 == "," })
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    _ = SeptenaServices.shared.nutritionMutator.addEntry(
      loggedAt: Date.now,
      foods: items,
      mealType: mealType?.rawValue)
    let label = items.first ?? foods
    return .result(dialog: "Logged \(label).")
  }
}
