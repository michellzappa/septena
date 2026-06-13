import SwiftUI
import SwiftData

// Groceries — shopping list and pantry. Skill-only; the section's
// real surface is the Groceries destination view, not Today.

@MainActor
enum GroceriesPlugin: SectionPlugin {
  static var manifest: SectionManifest {
    SectionManifest.byKey["groceries"]!
  }

  static func destinationView() -> AnyView? { AnyView(GroceriesDestinationView()) }

  // Groceries celebrates only the satisfying moment — finishing the shop
  // ("mark all bought") — with a burst. Adding/marking-needed is mundane
  // list-keeping and stays silent.
  static var logFlourish: LogFlourish? { LogFlourish(motion: .burst) }

  static var logActions: [LogAction] {
    [LogAction(id: "new", title: "New item", systemImage: "plus")]
  }

  static var exportContribution: SectionExportContribution? {
    SectionExportContribution(
      tables: [
        SchemaTable(name: "groceryCategory", purpose: "a shopping aisle / pantry group", fields: [
          .req("id", "string"), .req("name", "string"),
          .opt("sortIndex", "int"),
        ]),
        SchemaTable(name: "groceryItem", purpose: "one item in the shopping list / pantry", fields: [
          .req("id", "string"), .req("name", "string"),
          .req("category", "string", "groceryCategory.id"),
          .opt("emoji", "string"), .opt("low", "bool", "marked as running low"),
          .opt("lastBought", "date"), .opt("sortIndex", "int"),
        ]),
      ],
      collect: { ctx in
        let cats  = try ctx.fetch(FetchDescriptor<GroceryCategoryEntity>())
        let items = try ctx.fetch(FetchDescriptor<GroceryItemEntity>())
        return [
          "groceryCategory": cats.map(groceryCategoryExportDict),
          "groceryItem":     items.map(groceryItemExportDict),
        ]
      }
    )
  }

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(SectionOnboarding(
      sectionKey: "groceries",
      intro: "Organizes shopping items by category. Pick a few common categories to start — items themselves get added later as you go.",
      nounPlural: String(localized: "categories"),
      header: String(localized: "Categories"),
      items: GroceryCategoryStarter.all,
      primary: { $0.name },
      existsKey: { AnyHashable($0.name.lowercased()) },
      loadExistingKeys: {
        await MirrorReader.shared.read { ctx in
          Set(((try? ctx.fetch(FetchDescriptor<GroceryCategoryEntity>())) ?? [])
            .map { AnyHashable($0.name.lowercased()) })
        }
      },
      add: { items in
        let mutator = SeptenaServices.shared.groceryMutator
        for s in items { _ = mutator.addCategory(name: s.name) }
      },
      complete: complete
    ))
  }

  static var mcpSkill: SectionSkill? {
    SectionSkill(
      key: "groceries",
      summary: "Shopping list and pantry. Mark items low; clear when restocked.",
      tools: [
        SectionSkill.Tool("grocery_items_list",       "Items, with low-stock flag",
              inputs: "optional: low (filter to running-low), category (id), limit"),
        SectionSkill.Tool("grocery_item_create",      "Add an item",
              inputs: "required: name, category (GroceryCategory id) · optional: emoji"),
        SectionSkill.Tool("grocery_item_update",      "Patch an item",
              inputs: "required: id · optional: name, category, emoji, low (boolean), lastBought (YYYY-MM-DD or null)"),
        SectionSkill.Tool("grocery_item_set_low",     "Mark low / restocked. The daily workflow: low=true when running out, low=false when bought (auto-stamps lastBought=today)",
              inputs: "required: id, low (boolean)"),
        SectionSkill.Tool("grocery_item_delete",      "Remove an item",
              inputs: "required: id"),
        SectionSkill.Tool("grocery_categories_list",  "Categories"),
        SectionSkill.Tool("grocery_category_create",  "Add a category",
              inputs: "required: name"),
        SectionSkill.Tool("grocery_category_delete",  "Remove a category",
              inputs: "required: id"),
      ],
      body: """
      ### Two record types
      - **GroceryItem** — a pantry/shopping-list entry. Has a `low` flag (running out) and `lastBought` date.
      - **GroceryCategory** — section header for items ('Produce', 'Dairy', etc.).

      ### Most common workflow: marking items low
      Day-to-day, users say "I'm out of milk" or "we need eggs." Use `grocery_item_set_low(id, low: true)`. When they restock, `grocery_item_set_low(id, low: false)` — it auto-stamps `lastBought=today`.

      ### Examples
      **"I'm out of milk"**
      ```
      grocery_items_list({})                  → find milk's id
      grocery_item_set_low(id, low: true)
      ```

      **"What do I need to buy?"**
      ```
      grocery_items_list({ low: true })
      ```

      **"I bought milk"**
      ```
      grocery_item_set_low(id, low: false)    → clears low, stamps lastBought=today
      ```

      **"Add quinoa to my staples"**
      ```
      grocery_categories_list()                            → find category id
      grocery_item_create(name: "Quinoa", category: <id>)
      ```

      ### Don't
      - Don't use `grocery_item_update` for the low/restock workflow when `grocery_item_set_low` exists — the convenience tool handles the lastBought stamping.
      - Don't reference categories by name; always resolve to id first.
      """
    )
  }
}

/// Starter categories. Items themselves are user-specific; categories
/// are a small fixed scaffold that makes the first grocery-list use
/// productive. Additive only.
private struct GroceryCategoryStarter: Identifiable, Hashable {
  let id: String
  let name: String

  static let all: [GroceryCategoryStarter] = [
    .init(id: "starter-produce",   name: "Produce"),
    .init(id: "starter-dairy",     name: "Dairy"),
    .init(id: "starter-pantry",    name: "Pantry"),
    .init(id: "starter-frozen",    name: "Frozen"),
    .init(id: "starter-meat-fish", name: "Meat & fish"),
    .init(id: "starter-bakery",    name: "Bakery"),
    .init(id: "starter-drinks",    name: "Drinks"),
    .init(id: "starter-household", name: "Household"),
  ]
}

@MainActor func groceryCategoryExportDict(_ e: GroceryCategoryEntity) -> [String: Any] {
  compact([
    "id": e.id, "name": e.name, "sortIndex": e.sortIndex,
    "updatedAt": isoDate(e.updatedAt),
  ])
}

@MainActor func groceryItemExportDict(_ e: GroceryItemEntity) -> [String: Any] {
  compact([
    "id": e.id, "name": e.name, "category": e.category, "emoji": e.emoji,
    "low": e.low, "lastBought": e.lastBought,
    "sortIndex": e.sortIndex, "updatedAt": isoDate(e.updatedAt),
  ])
}
