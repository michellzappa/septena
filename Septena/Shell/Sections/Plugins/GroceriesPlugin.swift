import SwiftUI

// Groceries — shopping list and pantry. Skill-only; the section's
// real surface is the Groceries destination view, not Today.

@MainActor
enum GroceriesPlugin: SectionPlugin {
  static var manifest: SectionManifest {
    SectionManifest.byKey["groceries"]!
  }

  static func todayEvents(date: String, ctx: TodayContext) -> [TodayEvent] { [] }

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
