import AppIntents
import Foundation

// Hydration — a UX layer over Nutrition, so there's no dedicated mutator and
// no catalog. A water log is just a NutritionEntryEntity tagged with
// `foods: ["Water"]` and `waterMl > 0` (all macros 0); the daily summary
// already sums waterMl across every nutrition entry. So this intent leans on
// SectionLogIntent for boot + auto-enable and writes the SAME call the in-app
// quick-add makes (`HydrationDestinationView.commit(ml:)` →
// `NutritionMutator.addEntry`). The matching Siri phrase goes in
// `SeptenaShortcuts` (SectionLogIntent.swift) — the metadata processor needs
// every AppShortcut literal inline there. Mutator + marker types come from
// SeptenaCore (same module — no import needed).

// MARK: - Intents

/// Log a glass of water. Writes a water-only nutrition entry, exactly as the
/// in-app Hydration quick-add does.
struct LogWaterIntent: SectionLogIntent {
  static let sectionKey = "hydration"
  static let title: LocalizedStringResource = "Log Water"
  static let description = IntentDescription("Log water intake in Septena.")

  @Parameter(title: "Milliliters", default: 250, requestValueDialog: "How many milliliters?")
  var milliliters: Int

  static var parameterSummary: some ParameterSummary {
    Summary("Log \(\.$milliliters) ml of water")
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await requireSection()
    // Mirrors HydrationDestinationView.commit(ml:) exactly: a water-only
    // NutritionEntryEntity (foods == ["Water"], macros 0) via the shared
    // NutritionMutator — hydration has no mutator of its own.
    _ = SeptenaServices.shared.nutritionMutator.addEntry(
      loggedAt: .now,
      emoji: "💧",
      foods: HydrationPlugin.waterFoodsMarker,
      mealType: nil,
      source: "manual",
      waterMl: Double(milliliters)
    )
    return .result(dialog: "Logged \(milliliters) ml of water.")
  }
}
