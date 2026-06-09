import AppIntents
import Foundation
import SwiftData

// Groceries — section intents. Copied from the Supplements template: a pair
// of catalog AppEntities exposing the user's live grocery list / categories
// to the picker, plus thin intents that lean on SectionLogIntent for boot +
// auto-enable. Voice phrases live inline in `SeptenaShortcuts`
// (SectionLogIntent.swift). Mutator + entity types come from SeptenaCore
// (same module — no import needed).
//
// Day-to-day, the high-value flow is "I'm out of X" → mark that item low so
// it lands on the shopping list, so `MarkGroceryLowIntent` is the voice
// priority. `AddGroceryItemIntent` puts a brand-new item in the catalog.

// MARK: - Catalog entities

/// One of the user's grocery items, surfaced to Siri / Shortcuts / Spotlight
/// as a pickable value. Backed by `GroceryItemEntity`; `id` is the stable
/// item id so a resolved value survives renames.
struct GroceryItemChoice: AppEntity {
  let id: String
  let title: String
  let emoji: String?

  static var typeDisplayRepresentation: TypeDisplayRepresentation { "Grocery Item" }

  var displayRepresentation: DisplayRepresentation {
    let label = [emoji, title].compactMap { $0 }.joined(separator: " ")
    return DisplayRepresentation(title: "\(label)")
  }

  static var defaultQuery = GroceryItemChoiceQuery()
}

/// Resolves grocery-item parameters and supplies the picker list. Reads the
/// live catalog from SwiftData, so suggestions are always the user's actual
/// items.
struct GroceryItemChoiceQuery: EntityQuery {
  @MainActor
  func entities(for ids: [String]) async throws -> [GroceryItemChoice] {
    await SeptenaServices.shared.start()
    let wanted = Set(ids)
    return Self.catalog().filter { wanted.contains($0.id) }
  }

  @MainActor
  func suggestedEntities() async throws -> [GroceryItemChoice] {
    await SeptenaServices.shared.start()
    guard SeptenaServices.shared.isSectionEnabled("groceries") else { return [] }
    return Self.catalog()
  }

  @MainActor
  private static func catalog() -> [GroceryItemChoice] {
    let context = LocalStore.shared.container.mainContext
    let items = (try? context.fetch(FetchDescriptor<GroceryItemEntity>(
      sortBy: [SortDescriptor(\.sortIndex)]
    ))) ?? []
    return items.map {
      GroceryItemChoice(id: $0.id, title: $0.name, emoji: $0.emoji.isEmpty ? nil : $0.emoji)
    }
  }
}

/// One of the user's grocery categories (shopping aisle / pantry group),
/// surfaced as a pickable value. Backed by `GroceryCategoryEntity`; `id` is
/// the stable category id passed straight to the mutator.
struct GroceryCategoryChoice: AppEntity {
  let id: String
  let title: String

  static var typeDisplayRepresentation: TypeDisplayRepresentation { "Grocery Category" }

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(title)")
  }

  static var defaultQuery = GroceryCategoryChoiceQuery()
}

/// Resolves category parameters and supplies the picker list from the live
/// catalog.
struct GroceryCategoryChoiceQuery: EntityQuery {
  @MainActor
  func entities(for ids: [String]) async throws -> [GroceryCategoryChoice] {
    await SeptenaServices.shared.start()
    let wanted = Set(ids)
    return Self.catalog().filter { wanted.contains($0.id) }
  }

  @MainActor
  func suggestedEntities() async throws -> [GroceryCategoryChoice] {
    await SeptenaServices.shared.start()
    guard SeptenaServices.shared.isSectionEnabled("groceries") else { return [] }
    return Self.catalog()
  }

  @MainActor
  private static func catalog() -> [GroceryCategoryChoice] {
    let context = LocalStore.shared.container.mainContext
    let cats = (try? context.fetch(FetchDescriptor<GroceryCategoryEntity>(
      sortBy: [SortDescriptor(\.sortIndex)]
    ))) ?? []
    return cats.map { GroceryCategoryChoice(id: $0.id, title: $0.name) }
  }
}

// MARK: - Intents

/// The day-to-day log action: flag an item as running low so it lands on the
/// shopping list ("I'm out of milk"). Setting low=true keeps the item in the
/// catalog and marks it needed.
struct MarkGroceryLowIntent: SectionLogIntent {
  static let sectionKey = "groceries"
  static let title: LocalizedStringResource = "Mark Grocery Low"
  static let description = IntentDescription("Flag a grocery item as running low so it shows up on your shopping list.")

  @Parameter(title: "Item")
  var item: GroceryItemChoice

  static var parameterSummary: some ParameterSummary {
    Summary("Mark \(\.$item) as low")
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await requireSection()
    SeptenaServices.shared.groceryMutator.setLow(id: item.id, low: true)
    return .result(dialog: "Added \(item.title) to your shopping list.")
  }
}

/// Catalog action: add a brand-new item to the grocery list. Category is
/// optional — if omitted we fall back to the first existing category (or
/// create a generic "Other" bucket), since the mutator requires a category id.
struct AddGroceryItemIntent: SectionLogIntent {
  static let sectionKey = "groceries"
  static let title: LocalizedStringResource = "Add Grocery Item"
  static let description = IntentDescription("Add a new item to your grocery list.")

  @Parameter(title: "Name", requestValueDialog: "Which item?")
  var name: String

  @Parameter(title: "Category")
  var category: GroceryCategoryChoice?

  static var parameterSummary: some ParameterSummary {
    Summary("Add \(\.$name) to \(\.$category)")
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await requireSection()
    let mutator = SeptenaServices.shared.groceryMutator
    let categoryID = category?.id ?? Self.fallbackCategoryID(using: mutator)
    _ = mutator.addItem(name: name, category: categoryID)
    return .result(dialog: "Added \(name) to your groceries.")
  }

  /// The mutator requires a category id. When the user doesn't pick one, use
  /// the first existing category; if the catalog is empty, create a generic
  /// "Other" bucket so the item still has a home.
  @MainActor
  private static func fallbackCategoryID(using mutator: GroceryMutator) -> String {
    let context = LocalStore.shared.container.mainContext
    let existing = (try? context.fetch(FetchDescriptor<GroceryCategoryEntity>(
      sortBy: [SortDescriptor(\.sortIndex)]
    ))) ?? []
    if let first = existing.first { return first.id }
    return mutator.addCategory(name: "Other").id
  }
}
