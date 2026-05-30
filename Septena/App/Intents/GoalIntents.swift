import AppIntents
import Foundation

// Goals — the simplest section: free-text intentions, no catalog. So there's
// no AppEntity / EntityQuery here, just one thin intent that leans on
// SectionLogIntent for boot + auto-enable. The matching Siri phrase goes in
// `SeptenaShortcuts` (SectionLogIntent.swift) — the metadata processor needs
// every AppShortcut literal inline there. Mutator types come from SeptenaCore
// (same module — no import needed).

// MARK: - Intents

/// Capture a new free-text goal.
struct AddGoalIntent: SectionLogIntent {
  static let sectionKey = "goals"
  static let title: LocalizedStringResource = "Add Goal"
  static let description = IntentDescription("Add a new goal to Septena.")

  @Parameter(title: "Goal", requestValueDialog: "What's the goal?")
  var text: String

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    await prepareSection()
    _ = SeptenaServices.shared.goalMutator.createGoal(text: text)
    return .result(dialog: "Added \(text) to your goals.")
  }
}
