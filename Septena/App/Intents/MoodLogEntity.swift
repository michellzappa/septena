import AppIntents
import CoreSpotlight
import Foundation
import SwiftData
import UniformTypeIdentifiers

// Phase 2 of the Spotlight readability surface (docs/SPOTLIGHT_READABILITY_PLAN.md):
// the user's logged MOODS as a queryable, Spotlight-indexed entity — so Siri /
// Apple Intelligence can reason over how the user has been feeling. Historical
// log data, gated by the section's Spotlight opt-out
// (`SpotlightIndexer.indexable("mood")`). Not a picker.

struct MoodLogEntity: AppEntity, IndexedEntity {
  let id: String
  let emotion: String
  let note: String?
  let occurredAt: Date

  static var typeDisplayRepresentation: TypeDisplayRepresentation { "Mood" }

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(emotion)")
  }

  static var defaultQuery = MoodLogQuery()

  var attributeSet: CSSearchableItemAttributeSet {
    let attrs = CSSearchableItemAttributeSet(contentType: .text)
    attrs.title = emotion
    attrs.displayName = emotion
    if let note, !note.isEmpty { attrs.contentDescription = note }
    attrs.keywords = ["mood", "feeling", "emotion", emotion, "Septena"]
    attrs.startDate = occurredAt
    attrs.endDate = occurredAt
    return attrs
  }

  @MainActor
  static func from(_ e: MoodEventEntity) -> MoodLogEntity {
    MoodLogEntity(id: e.id, emotion: e.emotion, note: e.note, occurredAt: e.occurredAt)
  }
}

struct MoodLogQuery: EntityQuery {
  @MainActor
  func entities(for ids: [String]) async throws -> [MoodLogEntity] {
    await SeptenaServices.shared.start()
    let ctx = LocalStore.shared.container.mainContext
    let wanted = Set(ids)
    let rows = (try? ctx.fetch(FetchDescriptor<MoodEventEntity>())) ?? []
    return rows.filter { wanted.contains($0.id) }.map { MoodLogEntity.from($0) }
  }

  @MainActor
  func suggestedEntities() async throws -> [MoodLogEntity] { [] }
}
