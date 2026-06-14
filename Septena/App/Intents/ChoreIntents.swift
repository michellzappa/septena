import AppIntents
import CoreSpotlight
import Foundation
import SwiftData
import UniformTypeIdentifiers

// Chores — section intents mirroring the Supplements template
// (SupplementIntents.swift). Chores are checklist-shaped like
// Supplements/Habits, but the daily action is *complete* (a one-way
// completion event), not a toggle. The matching Siri phrases go in
// `SeptenaShortcuts` (SectionLogIntent.swift) — the metadata processor needs
// every AppShortcut literal inline there. Mutator + entity types come from
// SeptenaCore (same module — no import needed).

// MARK: - Catalog entity

/// One of the user's recurring chores, surfaced to Siri / Shortcuts /
/// Spotlight as a pickable value. Backed by `ChoreDefinitionEntity`; `id` is
/// the stable definition id so a resolved value survives renames.
struct ChoreEntity: AppEntity, IndexedEntity {
  let id: String
  let title: String
  let emoji: String?

  static var typeDisplayRepresentation: TypeDisplayRepresentation { "Chore" }

  var displayRepresentation: DisplayRepresentation {
    let label = [emoji, title].compactMap { $0 }.joined(separator: " ")
    return DisplayRepresentation(title: "\(label)")
  }

  static var defaultQuery = ChoreEntityQuery()

  /// Spotlight index entry — the surface Apple Intelligence reads. Donated by
  /// `SpotlightIndexer`; see docs/SPOTLIGHT_READABILITY_PLAN.md.
  var attributeSet: CSSearchableItemAttributeSet {
    let attrs = CSSearchableItemAttributeSet(contentType: .text)
    attrs.title = title
    attrs.displayName = [emoji, title].compactMap { $0 }.joined(separator: " ")
    attrs.keywords = ["chore", "Septena"]
    return attrs
  }
}

/// Resolves chore parameters and supplies the picker list. Reads the live
/// catalog from SwiftData, so suggestions are always the user's actual
/// chores — the run-time surface that genuinely reflects data.
struct ChoreEntityQuery: EntityQuery {
  @MainActor
  func entities(for ids: [String]) async throws -> [ChoreEntity] {
    await SeptenaServices.shared.start()
    let wanted = Set(ids)
    return Self.catalog().filter { wanted.contains($0.id) }
  }

  @MainActor
  func suggestedEntities() async throws -> [ChoreEntity] {
    await SeptenaServices.shared.start()
    guard SeptenaServices.shared.isSectionEnabled("chores") else { return [] }
    return Self.catalog()
  }

  @MainActor
  private static func catalog() -> [ChoreEntity] {
    let context = LocalStore.shared.container.mainContext
    let defs = (try? context.fetch(FetchDescriptor<ChoreDefinitionEntity>(
      sortBy: [SortDescriptor(\.sortIndex)]
    ))) ?? []
    return defs.map { ChoreEntity(id: $0.id, title: $0.title, emoji: $0.emoji) }
  }
}

// MARK: - Intents

/// The daily log action: mark a chore complete for today.
struct CompleteChoreIntent: SectionLogIntent {
  static let sectionKey = "chores"
  static let title: LocalizedStringResource = "Complete Chore"
  static let description = IntentDescription("Mark a chore complete for today.")

  @Parameter(title: "Chore")
  var chore: ChoreEntity

  static var parameterSummary: some ParameterSummary {
    Summary("Complete \(\.$chore)")
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await requireSection()
    SeptenaServices.shared.checklistMutator.completeChore(
      id: chore.id, date: SeptenaDate.today)
    return .result(dialog: "Marked \(chore.title) complete.")
  }
}

/// Catalog action: add a new recurring chore to track.
struct AddChoreIntent: SectionLogIntent {
  static let sectionKey = "chores"
  static let title: LocalizedStringResource = "Add Chore"
  static let description = IntentDescription("Add a new recurring chore to Septena.")

  @Parameter(title: "Name", requestValueDialog: "Which chore?")
  var name: String

  @Parameter(title: "Cadence (days)", requestValueDialog: "How many days between repeats?")
  var cadenceDays: Int

  static var parameterSummary: some ParameterSummary {
    Summary("Add \(\.$name) every \(\.$cadenceDays) days")
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await requireSection()
    _ = SeptenaServices.shared.checklistMutator.createChore(
      name: name, cadenceDays: cadenceDays)
    return .result(dialog: "Added \(name) to your chores.")
  }
}
