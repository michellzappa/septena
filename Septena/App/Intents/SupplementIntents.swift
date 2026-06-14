import AppIntents
import CoreSpotlight
import Foundation
import SwiftData
import UniformTypeIdentifiers

// Supplements — the canonical section-intent template. To add a section,
// copy this file and rename: (1) an AppEntity + EntityQuery exposing the
// section's catalog to the picker, (2) thin intents that lean on
// SectionLogIntent for boot + auto-enable. The matching Siri phrases go in
// `SeptenaShortcuts` (SectionLogIntent.swift) — the metadata processor needs
// every AppShortcut literal inline there. Mutator + entity types come from
// SeptenaCore (same module — no import needed).

// MARK: - Catalog entity

/// One of the user's supplements, surfaced to Siri / Shortcuts / Spotlight as
/// a pickable value. Backed by `SupplementDefinitionEntity`; `id` is the
/// stable definition id so a resolved value survives renames.
struct SupplementEntity: AppEntity, IndexedEntity {
  let id: String
  let title: String
  let emoji: String?

  static var typeDisplayRepresentation: TypeDisplayRepresentation { "Supplement" }

  var displayRepresentation: DisplayRepresentation {
    let label = [emoji, title].compactMap { $0 }.joined(separator: " ")
    return DisplayRepresentation(title: "\(label)")
  }

  static var defaultQuery = SupplementEntityQuery()

  /// Spotlight index entry — the surface Apple Intelligence reads. Donated by
  /// `SpotlightIndexer`; see docs/SPOTLIGHT_READABILITY_PLAN.md.
  var attributeSet: CSSearchableItemAttributeSet {
    let attrs = CSSearchableItemAttributeSet(contentType: .text)
    attrs.title = title
    attrs.displayName = [emoji, title].compactMap { $0 }.joined(separator: " ")
    attrs.keywords = ["supplement", "Septena"]
    return attrs
  }
}

/// Resolves supplement parameters and supplies the picker list. Reads the
/// live catalog from SwiftData, so suggestions are always the user's actual
/// supplements — the run-time surface that genuinely reflects data.
struct SupplementEntityQuery: EntityQuery {
  @MainActor
  func entities(for ids: [String]) async throws -> [SupplementEntity] {
    await SeptenaServices.shared.start()
    let wanted = Set(ids)
    return Self.catalog().filter { wanted.contains($0.id) }
  }

  @MainActor
  func suggestedEntities() async throws -> [SupplementEntity] {
    await SeptenaServices.shared.start()
    guard SeptenaServices.shared.isSectionEnabled("supplements") else { return [] }
    return Self.catalog()
  }

  @MainActor
  private static func catalog() -> [SupplementEntity] {
    let context = LocalStore.shared.container.mainContext
    let defs = (try? context.fetch(FetchDescriptor<SupplementDefinitionEntity>(
      sortBy: [SortDescriptor(\.sortIndex)]
    ))) ?? []
    return defs.map { SupplementEntity(id: $0.id, title: $0.title, emoji: $0.emoji) }
  }
}

// MARK: - Intents

/// The daily log action: check a supplement off for today.
struct MarkSupplementTakenIntent: SectionLogIntent {
  static let sectionKey = "supplements"
  static let title: LocalizedStringResource = "Mark Supplement Taken"
  static let description = IntentDescription("Check off a supplement for today.")

  @Parameter(title: "Supplement")
  var supplement: SupplementEntity

  static var parameterSummary: some ParameterSummary {
    Summary("Mark \(\.$supplement) as taken")
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await requireSection()
    SeptenaServices.shared.checklistMutator.toggleSupplement(
      id: supplement.id, date: SeptenaDate.today, done: true)
    return .result(dialog: "Marked \(supplement.title) as taken.")
  }
}

/// Catalog action: add a new supplement to track.
struct AddSupplementIntent: SectionLogIntent {
  static let sectionKey = "supplements"
  static let title: LocalizedStringResource = "Add Supplement"
  static let description = IntentDescription("Add a new supplement to Septena.")

  @Parameter(title: "Name", requestValueDialog: "Which supplement?")
  var name: String

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await requireSection()
    _ = SeptenaServices.shared.checklistMutator.createSupplement(name: name)
    return .result(dialog: "Added \(name) to your supplements.")
  }
}
