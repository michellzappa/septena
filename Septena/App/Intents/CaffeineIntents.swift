import AppIntents
import Foundation
import SwiftData

// Caffeine — section intents following the SupplementIntents template. Two
// pieces: (1) a `CaffeineBeanChoice` AppEntity + EntityQuery exposing the
// user's bean / source catalog to the picker, and (2) one thin
// `LogCaffeineIntent` that leans on `SectionLogIntent` for boot + auto-enable.
// The matching Siri phrases go in `SeptenaShortcuts` (SectionLogIntent.swift) —
// the metadata processor needs every AppShortcut literal inline there. Mutator
// + entity types come from SeptenaCore (same module — no import needed).

// MARK: - Catalog entity

/// One of the user's coffee beans / caffeine sources, surfaced to Siri /
/// Shortcuts / Spotlight as a pickable value. Backed by `CaffeineBeanEntity`
/// (the SwiftData @Model); `id` is the stable bean id so a resolved value
/// survives renames. Named `CaffeineBeanChoice` to avoid colliding with that
/// model.
struct CaffeineBeanChoice: AppEntity {
  let id: String
  let name: String

  static var typeDisplayRepresentation: TypeDisplayRepresentation { "Bean" }

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(name)")
  }

  static var defaultQuery = CaffeineBeanChoiceQuery()
}

/// Resolves bean parameters and supplies the picker list. Reads the live
/// catalog from SwiftData, so suggestions are always the user's actual beans —
/// the run-time surface that genuinely reflects data.
struct CaffeineBeanChoiceQuery: EntityQuery {
  @MainActor
  func entities(for ids: [String]) async throws -> [CaffeineBeanChoice] {
    await SeptenaServices.shared.start()
    let wanted = Set(ids)
    return Self.catalog().filter { wanted.contains($0.id) }
  }

  @MainActor
  func suggestedEntities() async throws -> [CaffeineBeanChoice] {
    await SeptenaServices.shared.start()
    return Self.catalog()
  }

  @MainActor
  private static func catalog() -> [CaffeineBeanChoice] {
    let context = LocalStore.shared.container.mainContext
    let beans = (try? context.fetch(FetchDescriptor<CaffeineBeanEntity>(
      sortBy: [SortDescriptor(\.sortIndex)]
    ))) ?? []
    return beans.map { CaffeineBeanChoice(id: $0.id, name: $0.name) }
  }
}

// MARK: - Method

/// Brewing method for a logged drink. Cases mirror `CaffeinePlugin.logActions`
/// (V60 / Matcha / other); raw values match the strings `CaffeinePlugin.label`
/// switches on so the Today timeline labels logged intents correctly.
enum CaffeineMethod: String, AppEnum {
  case v60
  case matcha
  case other

  static var typeDisplayRepresentation: TypeDisplayRepresentation { "Method" }

  static var caseDisplayRepresentations: [CaffeineMethod: DisplayRepresentation] {
    [
      .v60: "V60",
      .matcha: "Matcha",
      .other: "Other",
    ]
  }

  /// Plain-text label for spoken dialog (mirrors the display reps above).
  var label: String {
    switch self {
    case .v60:    return "V60"
    case .matcha: return "Matcha"
    case .other:  return "other"
    }
  }
}

// MARK: - Intents

/// The daily log action: record a caffeine drink for today.
struct LogCaffeineIntent: SectionLogIntent {
  static let sectionKey = "caffeine"
  static let title: LocalizedStringResource = "Log Caffeine"
  static let description = IntentDescription("Log a coffee, matcha, or other caffeine drink.")

  @Parameter(title: "Method", default: .v60)
  var method: CaffeineMethod

  @Parameter(title: "Bean")
  var bean: CaffeineBeanChoice?

  @Parameter(title: "Grams")
  var grams: Double?

  static var parameterSummary: some ParameterSummary {
    Summary("Log a \(\.$method) drink with \(\.$bean)") {
      \.$grams
    }
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    await prepareSection()
    // `beans` is stored as the bean's display name (matching the in-app
    // quick-log path), not its id; the AppEntity id only stabilizes
    // resolution across renames.
    SeptenaServices.shared.caffeineMutator.addEntry(
      date: SeptenaDate.today,
      time: SeptenaDate.nowHHMM,
      method: method.rawValue,
      beans: bean?.name,
      grams: grams)
    let label = bean?.name ?? method.label
    return .result(dialog: "Logged \(label).")
  }
}
