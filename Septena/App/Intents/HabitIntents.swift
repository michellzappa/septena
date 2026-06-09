import AppIntents
import Foundation
import SwiftData

// Habits — modeled on the Supplements template (SupplementIntents.swift): a
// definition + a per-day toggle. Two thin intents lean on SectionLogIntent
// for boot + auto-enable; the catalog AppEntity feeds the picker from the
// live SwiftData store. The matching Siri phrases go in `SeptenaShortcuts`
// (SectionLogIntent.swift) — the metadata processor needs every AppShortcut
// literal inline there. Mutator + entity types come from SeptenaCore (same
// module — no import needed).

// MARK: - Daypart bucket

/// The daypart a new habit belongs to. Cases mirror the free-form bucket
/// keys used across the Habits section (HabitsPlugin starter list,
/// `ChecklistMutator.createHabit(bucket:)`): "morning" | "anytime" |
/// "evening". As an AppEnum, Siri can capture it inline from a phrase.
enum HabitBucket: String, AppEnum {
  case morning
  case anytime
  case evening

  static var typeDisplayRepresentation: TypeDisplayRepresentation { "Time of Day" }

  static var caseDisplayRepresentations: [HabitBucket: DisplayRepresentation] {
    [
      .morning: "Morning",
      .anytime: "Anytime",
      .evening: "Evening",
    ]
  }
}

// MARK: - Catalog entity

/// One of the user's habits, surfaced to Siri / Shortcuts / Spotlight as a
/// pickable value. Backed by `HabitDefinitionEntity`; `id` is the stable
/// definition id so a resolved value survives renames.
struct HabitEntity: AppEntity {
  let id: String
  let title: String
  let emoji: String?

  static var typeDisplayRepresentation: TypeDisplayRepresentation { "Habit" }

  var displayRepresentation: DisplayRepresentation {
    let label = [emoji, title].compactMap { $0 }.joined(separator: " ")
    return DisplayRepresentation(title: "\(label)")
  }

  static var defaultQuery = HabitEntityQuery()
}

/// Resolves habit parameters and supplies the picker list. Reads the live
/// catalog from SwiftData, so suggestions are always the user's actual
/// habits — the run-time surface that genuinely reflects data.
struct HabitEntityQuery: EntityQuery {
  @MainActor
  func entities(for ids: [String]) async throws -> [HabitEntity] {
    await SeptenaServices.shared.start()
    let wanted = Set(ids)
    return Self.catalog().filter { wanted.contains($0.id) }
  }

  @MainActor
  func suggestedEntities() async throws -> [HabitEntity] {
    await SeptenaServices.shared.start()
    guard SeptenaServices.shared.isSectionEnabled("habits") else { return [] }
    return Self.catalog()
  }

  @MainActor
  private static func catalog() -> [HabitEntity] {
    let context = LocalStore.shared.container.mainContext
    let defs = (try? context.fetch(FetchDescriptor<HabitDefinitionEntity>(
      sortBy: [SortDescriptor(\.sortIndex)]
    ))) ?? []
    return defs.map { HabitEntity(id: $0.id, title: $0.title, emoji: $0.emoji) }
  }
}

// MARK: - Intents

/// The daily log action: check a habit off for today.
struct MarkHabitDoneIntent: SectionLogIntent {
  static let sectionKey = "habits"
  static let title: LocalizedStringResource = "Mark Habit Done"
  static let description = IntentDescription("Check off a habit for today.")

  @Parameter(title: "Habit")
  var habit: HabitEntity

  static var parameterSummary: some ParameterSummary {
    Summary("Mark \(\.$habit) as done")
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await requireSection()
    SeptenaServices.shared.checklistMutator.toggleHabit(
      id: habit.id, date: SeptenaDate.today, done: true)
    return .result(dialog: "Marked \(habit.title) as done.")
  }
}

/// Catalog action: add a new habit to track.
struct AddHabitIntent: SectionLogIntent {
  static let sectionKey = "habits"
  static let title: LocalizedStringResource = "Add Habit"
  static let description = IntentDescription("Add a new habit to Septena.")

  @Parameter(title: "Name", requestValueDialog: "Which habit?")
  var name: String

  @Parameter(title: "Time of Day", default: .anytime)
  var bucket: HabitBucket

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await requireSection()
    _ = SeptenaServices.shared.checklistMutator.createHabit(
      name: name, bucket: bucket.rawValue)
    return .result(dialog: "Added \(name) to your habits.")
  }
}
