import AppIntents
import Foundation
import SwiftData

// Cannabis — section intents following the SupplementIntents / CaffeineIntents
// template. Two pieces: (1) a `CannabisStrainChoice` AppEntity + EntityQuery
// exposing the user's strain catalog to the picker, and (2) one thin
// `LogCannabisIntent` that leans on `SectionLogIntent` for boot + auto-enable.
// The matching Siri phrases go in `SeptenaShortcuts` (SectionLogIntent.swift) —
// the metadata processor needs every AppShortcut literal inline there. Mutator
// + entity types come from SeptenaCore (same module — no import needed).
//
// SENSITIVITY: cannabis logging is private. The intent + a Shortcuts action
// exist so it's scriptable and usable from the share sheet / Shortcuts.app,
// but it is a deliberate candidate to OMIT from the zero-config Siri phrase
// set in `SeptenaShortcuts` (spoken "Hey Siri" surfaces). See DELIVERABLE notes.

// MARK: - Catalog entity

/// One of the user's cannabis strains, surfaced to Siri / Shortcuts / Spotlight
/// as a pickable value. Backed by `CannabisStrainEntity` (the SwiftData
/// @Model); `id` is the stable strain id so a resolved value survives renames.
/// Named `CannabisStrainChoice` to avoid colliding with that model.
struct CannabisStrainChoice: AppEntity {
  let id: String
  let name: String

  static var typeDisplayRepresentation: TypeDisplayRepresentation { "Strain" }

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(name)")
  }

  static var defaultQuery = CannabisStrainChoiceQuery()
}

/// Resolves strain parameters and supplies the picker list. Reads the live
/// catalog from SwiftData, so suggestions are always the user's actual
/// strains — the run-time surface that genuinely reflects data.
struct CannabisStrainChoiceQuery: EntityQuery {
  @MainActor
  func entities(for ids: [String]) async throws -> [CannabisStrainChoice] {
    await SeptenaServices.shared.start()
    let wanted = Set(ids)
    return Self.catalog().filter { wanted.contains($0.id) }
  }

  @MainActor
  func suggestedEntities() async throws -> [CannabisStrainChoice] {
    await SeptenaServices.shared.start()
    return Self.catalog()
  }

  @MainActor
  private static func catalog() -> [CannabisStrainChoice] {
    let context = LocalStore.shared.container.mainContext
    let strains = (try? context.fetch(FetchDescriptor<CannabisStrainEntity>(
      sortBy: [SortDescriptor(\.sortIndex)]
    ))) ?? []
    return strains.map { CannabisStrainChoice(id: $0.id, name: $0.name) }
  }
}

// MARK: - Method

/// Intake method for a logged session. Cases mirror `CannabisPlugin.logActions`
/// (vape / edible); raw values match the strings `CannabisPlugin.label`
/// switches on so the Today timeline labels logged intents correctly.
enum CannabisMethod: String, AppEnum {
  case vape
  case edible

  static var typeDisplayRepresentation: TypeDisplayRepresentation { "Method" }

  static var caseDisplayRepresentations: [CannabisMethod: DisplayRepresentation] {
    [
      .vape: "Vape",
      .edible: "Edible",
    ]
  }

  /// Plain-text label for spoken dialog (mirrors the display reps above).
  var label: String {
    switch self {
    case .vape:   return "vape"
    case .edible: return "edible"
    }
  }
}

// MARK: - Intents

/// The daily log action: record a cannabis session for today. `hits` applies to
/// vape, `grams` to edibles — both optional, matching the in-app quick-log path
/// (vape defaults to one hit; edible carries a dose). The mutator auto-fills
/// vape grams from its per-use constant when none is supplied.
struct LogCannabisIntent: SectionLogIntent {
  static let sectionKey = "cannabis"
  static let title: LocalizedStringResource = "Log Cannabis"
  static let description = IntentDescription("Log a cannabis session by method and strain.")

  @Parameter(title: "Method", default: .vape)
  var method: CannabisMethod

  @Parameter(title: "Strain")
  var strain: CannabisStrainChoice?

  @Parameter(title: "Hits")
  var hits: Int?

  @Parameter(title: "Grams")
  var grams: Double?

  static var parameterSummary: some ParameterSummary {
    Summary("Log a \(\.$method) session") {
      \.$strain
      \.$hits
      \.$grams
    }
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    await prepareSection()
    // `strain` is stored as the strain's display name (matching the in-app
    // quick-log path), not its id; the AppEntity id only stabilizes
    // resolution across renames. Vape defaults to a single hit, as in-app.
    let resolvedHit = method == .vape ? (hits ?? 1) : hits
    SeptenaServices.shared.cannabisMutator.addEntry(
      date: SeptenaDate.today,
      time: nowHHMM(),
      method: method.rawValue,
      strain: strain?.name,
      hit: resolvedHit,
      grams: grams)
    let label = strain?.name ?? method.label
    return .result(dialog: "Logged \(label).")
  }
}
