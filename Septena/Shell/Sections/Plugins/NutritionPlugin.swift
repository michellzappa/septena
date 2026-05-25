import SwiftUI

// Nutrition. The food-list rendering rules (first item + " +N" suffix
// when there are more) and the macro detail line move here alongside
// the MCP contract that captures macro estimation conventions.

@MainActor
enum NutritionPlugin: SectionPlugin {
  static var manifest: SectionManifest {
    SectionManifest.byKey["nutrition"]!
  }

  static func destinationView() -> AnyView? { AnyView(NutritionDestinationView()) }

  // MARK: - First-enable onboarding

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(SectionExplainerView(
      sectionKey: "nutrition",
      title: "Set up Nutrition",
      intro: "Nutrition is a meal + macro log with auto-computed daily totals. Logging is fast — name the food, estimate macros, done.",
      bullets: [
        ("Foods", "Newline-separated list. \"chicken salad\", \"rice\", \"olive oil\" — one meal, three lines."),
        ("Macros", "Protein, fat, carbs in grams. Calories auto-compute from 4P + 9F + 4C if you don't override."),
        ("Meal type", "Breakfast / lunch / dinner / snack. Optional but useful for filtering daily summaries."),
        ("Daily summary", "Totals roll up automatically — kcal, macros, micros. Nothing to write by hand."),
      ],
      actionLabel: "Got it",
      complete: complete
    ))
  }

  // MARK: - Today timeline

  static func todayEvents(date: String, ctx: TodayContext) -> [TodayEvent] {
    let accent = ctx.theme.color(for: "nutrition")
    return ctx.nutrition
      .filter { $0.date == date }
      .map { entry in
        TodayEvent(
          id: "nut-\(entry.id)",
          time: entry.time,
          section: "nutrition",
          color: accent,
          title: title(for: entry),
          detail: detail(for: entry),
          kind: .nutrition(entry)
        )
      }
  }

  /// "🥗 chicken salad +2" — emoji prefix (if any) + first food + count of
  /// remaining foods. Empty `foods` falls back to literal "Meal".
  static func title(for entry: NutritionEntry) -> String {
    let name = entry.foods.first ?? "Meal"
    let prefix = entry.emoji.map { "\($0) " } ?? ""
    let more = entry.foods.count > 1 ? " +\(entry.foods.count - 1)" : ""
    return "\(prefix)\(name)\(more)"
  }

  /// Protein + kcal headline — the two numbers people glance at on the
  /// timeline. Full macro breakdown lives on the entry detail screen.
  static func detail(for entry: NutritionEntry) -> String? {
    "\(Int(entry.proteinG))g protein · \(Int(entry.kcal)) kcal"
  }

  // MARK: - MCP / agent contract

  static var mcpSkill: SectionSkill? {
    SectionSkill(
      key: "nutrition",
      summary: "Meal + macro log with auto-computed daily totals.",
      tools: [
        SectionSkill.Tool("nutrition_entries_list", "By day or range. Defaults to last 7 days",
              inputs: "optional: date, from, to, limit"),
        SectionSkill.Tool("nutrition_entry_log",    "Log a meal. foods is newline-separated; macros default to 0; kcal auto-computed if omitted; source auto-tagged 'mcp'",
              inputs: """
                required: foods · \
                optional: loggedAt (ISO8601), emoji, note, mealType (breakfast|lunch|dinner|snack), \
                proteinG, fatG, carbsG, \
                fiberG, sugarG, saturatedFatG, alcoholG, \
                kcal (override; else 4P+9F+4C+7A), \
                sodiumMg, cholesterolMg, potassiumMg, waterMl
                """),
        SectionSkill.Tool("nutrition_entry_update", "Patch any subset of fields",
              inputs: """
                required: id · \
                optional: loggedAt (ISO8601), foods, emoji, note, mealType (breakfast|lunch|dinner|snack), \
                proteinG, fatG, carbsG, \
                fiberG, sugarG, saturatedFatG, alcoholG, kcal, \
                sodiumMg, cholesterolMg, potassiumMg, waterMl
                """),
        SectionSkill.Tool("nutrition_entry_delete", "Remove an entry",
              inputs: "required: id"),
        SectionSkill.Tool("nutrition_day_summary",  "Read-only daily rollup (kcal + macros + micros + entryCount + first/last loggedAt)",
              inputs: "optional: date (default today)"),
      ],
      body: """
      `foods` is a newline-separated list. \
      **Estimate macros from food names** — the user expects the model to do \
      the math, not ask back. `kcal` is computed `4P + 9F + 4C + 7A` if not \
      overridden.

      ### Example
      **"Log lunch: chicken salad, rice, olive oil"**
      ```
      nutrition_entry_log(
        foods: "chicken salad\\nrice\\nolive oil",
        mealType: "lunch",
        proteinG: 40, fatG: 20, carbsG: 50
      )
      ```

      ### Don't
      - Don't bundle multiple meals into one entry — separate `loggedAt` timestamps.
      - Don't try to write a day summary — the app computes it automatically.
      """
    )
  }
}
