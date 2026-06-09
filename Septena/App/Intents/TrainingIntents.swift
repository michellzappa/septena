import AppIntents
import Foundation
import SwiftData

// Training — section-intent surface modeled on SupplementIntents (the
// canonical template). Exposes the exercise catalog to the picker via an
// AppEntity + EntityQuery, plus one thin logging intent that leans on
// SectionLogIntent for boot + auto-enable. Matching Siri phrases live in
// `SeptenaShortcuts` (SectionLogIntent.swift) — the metadata processor needs
// every AppShortcut literal inline there.
//
// Catalog resolution note: `TrainingMutator.addEntry` resolves the exercise by
// its CANONICAL NAME (not the slug id). So `ExerciseChoice.id` carries the
// name itself — a resolved value is passed straight through as `exercise:`.

// MARK: - Catalog entity

/// One exercise from the user's catalog, surfaced to Siri / Shortcuts /
/// Spotlight as a pickable value. Backed by `ExerciseDefinitionEntity`. `id`
/// is the canonical NAME (the value the mutator wants), so the picked value
/// maps directly onto `addEntry(exercise:)` with no slug→name lookup.
struct ExerciseChoice: AppEntity {
  let id: String   // canonical exercise name, e.g. "Chest press"

  static var typeDisplayRepresentation: TypeDisplayRepresentation { "Exercise" }

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(id)")
  }

  static var defaultQuery = ExerciseEntityQuery()
}

/// Resolves exercise parameters and supplies the picker list. Reads the live
/// catalog from SwiftData (non-archived, sorted), so suggestions are always
/// the user's actual exercises.
struct ExerciseEntityQuery: EntityQuery {
  @MainActor
  func entities(for ids: [String]) async throws -> [ExerciseChoice] {
    await SeptenaServices.shared.start()
    let wanted = Set(ids)
    return Self.catalog().filter { wanted.contains($0.id) }
  }

  @MainActor
  func suggestedEntities() async throws -> [ExerciseChoice] {
    await SeptenaServices.shared.start()
    guard SeptenaServices.shared.isSectionEnabled("training") else { return [] }
    return Self.catalog()
  }

  @MainActor
  private static func catalog() -> [ExerciseChoice] {
    let context = LocalStore.shared.container.mainContext
    let defs = (try? context.fetch(FetchDescriptor<ExerciseDefinitionEntity>(
      sortBy: [SortDescriptor(\.sortIndex)]
    ))) ?? []
    return defs
      .filter { !$0.archived }
      .map { ExerciseChoice(id: $0.name) }
  }
}

/// One of the user's configured training session types (upper, cardio, yoga,
/// etc.), surfaced as an optional picker so Siri / Shortcuts logs can land in
/// the correct routine bucket instead of always defaulting to "upper".
struct TrainingSessionTypeChoice: AppEntity {
  let id: String
  let title: String

  static var typeDisplayRepresentation: TypeDisplayRepresentation { "Session Type" }

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(title)")
  }

  static var defaultQuery = TrainingSessionTypeQuery()
}

struct TrainingSessionTypeQuery: EntityQuery {
  @MainActor
  func entities(for ids: [String]) async throws -> [TrainingSessionTypeChoice] {
    await SeptenaServices.shared.start()
    let wanted = Set(ids)
    return Self.catalog().filter { wanted.contains($0.id) }
  }

  @MainActor
  func suggestedEntities() async throws -> [TrainingSessionTypeChoice] {
    await SeptenaServices.shared.start()
    guard SeptenaServices.shared.isSectionEnabled("training") else { return [] }
    return Self.catalog()
  }

  @MainActor
  private static func catalog() -> [TrainingSessionTypeChoice] {
    let context = LocalStore.shared.container.mainContext
    return ChecklistMirror.loadSessionTypes(context: context)
      .filter { !$0.archived }
      .map { TrainingSessionTypeChoice(id: $0.id, title: $0.label) }
  }
}

// MARK: - Intents

/// The daily log action: record one exercise set under a session type.
/// Strength fields (sets / reps / weight) are optional — the simplest call
/// logs just the exercise. The exercise is resolved by canonical name.
struct LogTrainingIntent: SectionLogIntent {
  static let sectionKey = "training"
  static let title: LocalizedStringResource = "Log Workout"
  static let description = IntentDescription("Log an exercise set in Septena.")

  @Parameter(title: "Exercise")
  var exercise: ExerciseChoice

  @Parameter(title: "Session Type")
  var sessionType: TrainingSessionTypeChoice?

  @Parameter(title: "Sets")
  var sets: Int?

  @Parameter(title: "Reps")
  var reps: Int?

  @Parameter(title: "Weight (kg)")
  var weightKg: Double?

  static var parameterSummary: some ParameterSummary {
    Summary("Log \(\.$exercise)") {
      \.$sessionType
      \.$sets
      \.$reps
      \.$weightKg
    }
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await requireSection()
    // `exercise.id` IS the canonical name (see ExerciseChoice), so it maps
    // straight onto `exercise:`. When the caller omits a session type, infer a
    // sensible default from the exercise's kind (cardio/mobility/strength)
    // rather than forcing everything into "upper".
    SeptenaServices.shared.trainingMutator.addEntry(
      date: SeptenaDate.today,
      time: Self.nowTime(),
      sessionType: resolvedSessionTypeID(),
      exercise: exercise.id,
      weight: weightKg,
      sets: sets.map(String.init),
      reps: reps.map(String.init))
    return .result(dialog: "Logged \(exercise.id).")
  }

  @MainActor
  private func resolvedSessionTypeID() -> String {
    if let sessionType { return sessionType.id }

    let context = LocalStore.shared.container.mainContext
    let activeSessionTypes = ChecklistMirror.loadSessionTypes(context: context)
      .filter { !$0.archived }
    guard !activeSessionTypes.isEmpty else { return "upper" }

    let defs = (try? context.fetch(FetchDescriptor<ExerciseDefinitionEntity>())) ?? []
    let exerciseKind = defs.first {
      $0.name == exercise.id || $0.id == exercise.id
    }.map { SessionKind(rawValue: $0.type.lowercased()) ?? .defaulted(for: $0.type) }

    if let exerciseKind,
       let matching = activeSessionTypes.first(where: { $0.kind == exerciseKind }) {
      return matching.id
    }
    if let upper = activeSessionTypes.first(where: { $0.id == "upper" }) {
      return upper.id
    }
    return activeSessionTypes[0].id
  }

  /// Current wall-clock time as "HH:mm" — the string shape `addEntry`
  /// stores and later renders. No shared now-helper exists in SeptenaCore,
  /// so it's derived inline here.
  private static func nowTime() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    return f.string(from: Date())
  }
}
