import AppIntents
import CoreSpotlight
import Foundation
import SwiftData
import UniformTypeIdentifiers

// Phase 2 of the Spotlight readability surface (docs/SPOTLIGHT_READABILITY_PLAN.md):
// the user's logged WORKOUTS (exercise sets) as a queryable, Spotlight-indexed
// entity — so Siri / Apple Intelligence can answer "when did I last squat."
// Historical log data, gated by the training section's Spotlight opt-out
// (`SpotlightIndexer.indexable("training")`, shared with the exercise catalog).
// Not a picker.

struct WorkoutLogEntity: AppEntity, IndexedEntity {
  let id: String
  let exercise: String
  let detail: String     // session type · sets×reps · weight · duration
  let occurredAt: Date

  static var typeDisplayRepresentation: TypeDisplayRepresentation { "Workout" }

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(exercise)", subtitle: "\(detail)")
  }

  static var defaultQuery = WorkoutLogQuery()

  var attributeSet: CSSearchableItemAttributeSet {
    let attrs = CSSearchableItemAttributeSet(contentType: .text)
    attrs.title = exercise
    attrs.displayName = exercise
    attrs.contentDescription = detail
    attrs.keywords = ["workout", "exercise", "training", "Septena"]
    attrs.startDate = occurredAt
    attrs.endDate = occurredAt
    return attrs
  }

  @MainActor
  static func from(_ e: ExerciseEntryEntity) -> WorkoutLogEntity {
    var bits = [e.sessionType]
    if let sets = e.sets, let reps = e.reps {
      bits.append("\(sets)×\(reps)")
    } else if let sets = e.sets {
      bits.append("\(sets) sets")
    }
    if let w = e.weight, w > 0 { bits.append("\(String(format: "%g", w)) kg") }
    if let d = e.durationMin, d > 0 { bits.append("\(Int(d.rounded())) min") }
    let detail = bits.joined(separator: " · ")
    return WorkoutLogEntity(id: e.id, exercise: e.exercise, detail: detail,
                            occurredAt: e.occurredAt)
  }
}

struct WorkoutLogQuery: EntityQuery {
  @MainActor
  func entities(for ids: [String]) async throws -> [WorkoutLogEntity] {
    await SeptenaServices.shared.start()
    let ctx = LocalStore.shared.container.mainContext
    let wanted = Set(ids)
    let rows = (try? ctx.fetch(FetchDescriptor<ExerciseEntryEntity>())) ?? []
    return rows.filter { wanted.contains($0.id) }.map { WorkoutLogEntity.from($0) }
  }

  @MainActor
  func suggestedEntities() async throws -> [WorkoutLogEntity] { [] }
}
