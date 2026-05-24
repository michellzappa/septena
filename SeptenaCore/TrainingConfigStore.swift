import Foundation
import SwiftData

// TrainingConfigStore — write helpers for the exercise-definition and
// session-type catalogs. Mirrors the pattern in SeptenaServices but
// isolated so the Settings UI doesn't need to reach into the fat
// ChecklistMutator / SeptenaServices stack.
//
// CKEngine note functions are instance methods on CKEngine; we reach
// the shared instance via SeptenaServices.shared.ckEngine (which is
// nil until start() is called — calls are silently dropped, matching
// the existing offline-safe pattern throughout the codebase).

@MainActor
enum TrainingConfigStore {

  private static var ckEngine: CKEngine { SeptenaServices.shared.ckEngine }

  // MARK: - Exercise definitions

  @discardableResult
  static func upsertExerciseDefinition(
    id: String,
    name: String,
    type: String,
    primaryMuscle: String? = nil,
    secondaryMuscles: [String] = [],
    aliases: [String] = [],
    archived: Bool = false,
    context: ModelContext
  ) -> ExerciseDefinitionEntity {
    let descriptor = FetchDescriptor<ExerciseDefinitionEntity>(
      predicate: #Predicate { $0.id == id }
    )
    let entity: ExerciseDefinitionEntity
    if let existing = (try? context.fetch(descriptor))?.first {
      entity = existing
    } else {
      let nextIndex = ((try? context.fetch(FetchDescriptor<ExerciseDefinitionEntity>(
        sortBy: [SortDescriptor(\.sortIndex, order: .reverse)]
      )))?.first?.sortIndex ?? -1) + 1
      entity = ExerciseDefinitionEntity(id: id, name: name, type: type, sortIndex: nextIndex)
      context.insert(entity)
    }
    entity.name = name
    entity.type = type
    entity.primaryMuscle = primaryMuscle
    entity.secondaryMuscles = secondaryMuscles
    entity.aliases = aliases
    entity.archived = archived
    entity.updatedAt = .now
    try? context.save()
    ckEngine.noteExerciseDefinitionChange(id: id)
    return entity
  }

  static func deleteExerciseDefinition(id: String, context: ModelContext) {
    let descriptor = FetchDescriptor<ExerciseDefinitionEntity>(
      predicate: #Predicate { $0.id == id }
    )
    guard let entity = (try? context.fetch(descriptor))?.first else { return }
    context.delete(entity)
    try? context.save()
    ckEngine.noteExerciseDefinitionDeletion(id: id)
  }

  static func setExerciseDefinitionArchived(id: String, archived: Bool, context: ModelContext) {
    let descriptor = FetchDescriptor<ExerciseDefinitionEntity>(
      predicate: #Predicate { $0.id == id }
    )
    guard let entity = (try? context.fetch(descriptor))?.first else { return }
    entity.archived = archived
    entity.updatedAt = .now
    try? context.save()
    ckEngine.noteExerciseDefinitionChange(id: id)
  }

  // MARK: - Session types

  @discardableResult
  static func upsertSessionType(
    id: String,
    label: String,
    emoji: String?,
    exercises: [String],
    archived: Bool = false,
    kind: SessionKind? = nil,
    context: ModelContext
  ) -> SessionTypeEntity {
    let descriptor = FetchDescriptor<SessionTypeEntity>(
      predicate: #Predicate { $0.id == id }
    )
    let entity: SessionTypeEntity
    if let existing = (try? context.fetch(descriptor))?.first {
      entity = existing
    } else {
      let nextIndex = ((try? context.fetch(FetchDescriptor<SessionTypeEntity>(
        sortBy: [SortDescriptor(\.sortIndex, order: .reverse)]
      )))?.first?.sortIndex ?? -1) + 1
      entity = SessionTypeEntity(id: id, label: label, sortIndex: nextIndex)
      context.insert(entity)
    }
    entity.label = label
    entity.emoji = emoji
    entity.exercises = exercises
    entity.archived = archived
    // Only overwrite the stored kind when the caller explicitly
    // passed one. Otherwise preserve whatever's there — including
    // `nil` on legacy rows, which the read site treats as the seed
    // default via `SessionKind.defaulted(for: id)`. Avoids stomping
    // a user-chosen kind when an unrelated edit flows through here.
    if let kind { entity.kindRaw = kind.rawValue }
    entity.updatedAt = .now
    try? context.save()
    ckEngine.noteSessionTypeChange(id: id)
    return entity
  }

  static func deleteSessionType(id: String, context: ModelContext) {
    let descriptor = FetchDescriptor<SessionTypeEntity>(
      predicate: #Predicate { $0.id == id }
    )
    guard let entity = (try? context.fetch(descriptor))?.first else { return }
    context.delete(entity)
    try? context.save()
    ckEngine.noteSessionTypeDeletion(id: id)
  }

  static func setSessionTypeArchived(id: String, archived: Bool, context: ModelContext) {
    let descriptor = FetchDescriptor<SessionTypeEntity>(
      predicate: #Predicate { $0.id == id }
    )
    guard let entity = (try? context.fetch(descriptor))?.first else { return }
    entity.archived = archived
    entity.updatedAt = .now
    try? context.save()
    ckEngine.noteSessionTypeChange(id: id)
  }

  /// Reassign sortIndex values to match the provided ordered id list.
  static func reorderSessionTypes(idsInOrder: [String], context: ModelContext) {
    let all = (try? context.fetch(FetchDescriptor<SessionTypeEntity>())) ?? []
    let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    for (index, id) in idsInOrder.enumerated() {
      if let entity = byID[id] {
        entity.sortIndex = index
        entity.updatedAt = .now
        ckEngine.noteSessionTypeChange(id: id)
      }
    }
    try? context.save()
  }

  // MARK: - Slug helper

  /// Derive a stable ID slug from a display name. Lowercased, spaces →
  /// hyphens, strips everything that isn't alphanumeric or a hyphen.
  static func slug(from name: String) -> String {
    name
      .lowercased()
      .replacingOccurrences(of: " ", with: "-")
      .filter { $0.isLetter || $0.isNumber || $0 == "-" }
  }
}
