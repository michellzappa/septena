import AppIntents
import CoreSpotlight
import Foundation
import SwiftData
import UniformTypeIdentifiers

// Phase 2 of the Spotlight readability surface (docs/SPOTLIGHT_READABILITY_PLAN.md):
// the user's logged MEALS as a queryable, Spotlight-indexed entity — so Siri /
// Apple Intelligence can answer "what did I eat yesterday." Unlike the catalog
// entities, this is historical log data, gated by the section's Spotlight
// opt-out (`SpotlightIndexer.indexable("nutrition")`). Not a picker — its
// `EntityQuery` resolves by id (for a Spotlight tap) but suggests nothing.

struct MealLogEntity: AppEntity, IndexedEntity {
  let id: String
  let headline: String   // first food, or the meal type
  let detail: String     // foods + kcal summary
  let loggedAt: Date

  static var typeDisplayRepresentation: TypeDisplayRepresentation { "Meal" }

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(headline)", subtitle: "\(detail)")
  }

  static var defaultQuery = MealLogQuery()

  var attributeSet: CSSearchableItemAttributeSet {
    let attrs = CSSearchableItemAttributeSet(contentType: .text)
    attrs.title = headline
    attrs.displayName = headline
    attrs.contentDescription = detail
    attrs.keywords = ["meal", "food", "nutrition", "ate", "Septena"]
    attrs.startDate = loggedAt
    attrs.endDate = loggedAt
    return attrs
  }

  @MainActor
  static func from(_ e: NutritionEntryEntity) -> MealLogEntity {
    let foods = e.foods.split(separator: "\n").map(String.init)
    let headline = foods.first ?? (e.mealType?.capitalized ?? "Meal")
    // kcal: stored override, else the standard Atwater fallback the app uses.
    let kcal = e.kcal ?? (4 * e.proteinG + 9 * e.fatG + 4 * e.carbsG + 7 * (e.alcoholG ?? 0))
    var parts = [foods.joined(separator: ", ")]
    if kcal > 0 { parts.append("\(Int(kcal.rounded())) kcal") }
    let detail = parts.filter { !$0.isEmpty }.joined(separator: " · ")
    return MealLogEntity(id: e.id, headline: headline, detail: detail, loggedAt: e.loggedAt)
  }
}

struct MealLogQuery: EntityQuery {
  @MainActor
  func entities(for ids: [String]) async throws -> [MealLogEntity] {
    await SeptenaServices.shared.start()
    let ctx = LocalStore.shared.container.mainContext
    let wanted = Set(ids)
    let rows = (try? ctx.fetch(FetchDescriptor<NutritionEntryEntity>())) ?? []
    return rows.filter { wanted.contains($0.id) }.map { MealLogEntity.from($0) }
  }

  // Log entities aren't offered in pickers — only indexed for search.
  @MainActor
  func suggestedEntities() async throws -> [MealLogEntity] { [] }
}
