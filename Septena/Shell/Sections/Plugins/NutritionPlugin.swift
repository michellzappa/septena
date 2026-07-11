import SwiftUI
import SwiftData

// Nutrition. The food-list rendering rules (first item + " +N" suffix
// when there are more) and the macro detail line move here alongside
// the MCP contract that captures macro estimation conventions.

@MainActor
enum NutritionPlugin: SectionPlugin {
  static var producesTimedEvents: Bool { true }

  static var manifest: SectionManifest {
    SectionManifest.byKey["nutrition"]!
  }

  static func destinationView() -> AnyView? { AnyView(NutritionDestinationView()) }

  // Only the day's FIRST meal — the one that breaks the overnight fast —
  // earns a flourish (the calm `.bloom`); every later meal commits quietly
  // (tick + announce, no canvas). Eating several times a day is normal, not
  // a moment; breaking the fast is the day's one nutrition event. Route all
  // new-meal commits through `commitMeal` below so the policy lives in one
  // place. The in-context confirmation for quiet meals is the new row + the
  // tile gauge advancing.
  static var logFlourish: LogFlourish? { LogFlourish(motion: .bloom) }

  // The commit path itself (`commitMeal` + the fast-break read) lives in
  // `NutritionCommit` (Sections/Nutrition/NutritionCommit.swift) so the meal
  // sheets compile into Septask without this plugin. Policy notes above.

  static func detailPaneContent() -> AnyView? { AnyView(NutritionDetailContent()) }

  static var exportContribution: SectionExportContribution? {
    SectionExportContribution(
      tables: [
        SchemaTable(name: "nutritionEntry", purpose: "a single meal / snack", fields: [
          .req("id", "string"), .req("loggedAt", "timestamp"),
          .opt("emoji", "string"), .opt("foods", "string", "newline-joined list"),
          .opt("note", "string"),
          .opt("mealType", "string", "breakfast | lunch | dinner | snack"),
          .opt("source", "string"),
          .req("proteinG", "double"), .req("fatG", "double"),
          .req("carbsG", "double"),
          .opt("fiberG", "double"), .opt("sugarG", "double"),
          .opt("saturatedFatG", "double"), .opt("alcoholG", "double"),
          .opt("kcal", "double", "falls back to 4P+9F+4C+7A if omitted"),
          .opt("sodiumMg", "double"), .opt("cholesterolMg", "double"),
          .opt("potassiumMg", "double"), .opt("waterMl", "double"),
        ]),
      ],
      collect: { ctx in
        let entries   = try ctx.fetch(FetchDescriptor<NutritionEntryEntity>())
        let summaries = try ctx.fetch(FetchDescriptor<NutritionDailySummaryEntity>())
        return [
          "nutritionEntry":        entries.map(nutritionEntryExportDict),
          "nutritionDailySummary": summaries.map(nutritionSummaryExportDict),
        ]
      }
    )
  }

  // MARK: - First-enable onboarding

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(SectionOnboarding(
      sectionKey: "nutrition",
      intro: "Meal + macro log with auto-computed daily totals. Name the food, estimate macros, done.",
      bullets: [
        .init("Foods as a list", "One line per item: \"chicken salad\", \"rice\", \"olive oil\". A meal is just a few lines.", icon: "list.bullet"),
        .init("Macros in grams", "Protein, fat, carbs. Calories auto-compute as 4P + 9F + 4C unless you override.", icon: "chart.bar"),
        .init("Meal type optional", "Breakfast / lunch / dinner / snack — useful for filtering, not required.", icon: "fork.knife"),
        .init("Daily totals roll up", "Kcal and macros sum automatically across every entry that day.", icon: "sum"),
      ],
      complete: complete
    ))
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
                ingredients (newline-separated), \
                proteinG, fatG, carbsG, \
                fiberG, sugarG, saturatedFatG, alcoholG, \
                kcal (override; else 4P+9F+4C+7A), \
                sodiumMg, cholesterolMg, potassiumMg, waterMl
                """),
        SectionSkill.Tool("nutrition_entry_update", "Patch any subset of fields",
              inputs: """
                required: id · \
                optional: loggedAt (ISO8601), foods, emoji, note, mealType (breakfast|lunch|dinner|snack), \
                ingredients (newline-separated), \
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

  // MARK: - Aim metrics

  static var aimMetrics: [GoalMetric] {
    [
      GoalMetric(key: "nutrition.protein_sum",
                 label: "Protein (today)",
                 sectionKey: "nutrition",
                 window: "today",
                 unitLabel: "g"),
      GoalMetric(key: "nutrition.fat_sum",
                 label: "Fat (today)",
                 sectionKey: "nutrition",
                 window: "today",
                 unitLabel: "g"),
      GoalMetric(key: "nutrition.carbs_sum",
                 label: "Carbs (today)",
                 sectionKey: "nutrition",
                 window: "today",
                 unitLabel: "g"),
      GoalMetric(key: "nutrition.fiber_sum",
                 label: "Fiber (today)",
                 sectionKey: "nutrition",
                 window: "today",
                 unitLabel: "g"),
      GoalMetric(key: "nutrition.kcal_sum",
                 label: "Calories (today)",
                 sectionKey: "nutrition",
                 window: "today",
                 unitLabel: "kcal"),
      GoalMetric(key: "nutrition.water_sum",
                 label: "Water (today)",
                 sectionKey: "nutrition",
                 window: "today",
                 unitLabel: "ml"),
    ]
  }

  static func evaluateAim(metric: GoalMetric, context: ModelContext, now: Date) -> Double? {
    // Nutrition uses `loggedAt: Date` (not a string date column), so we
    // filter with a Date range rather than the YYYY-MM-DD string helper.
    guard let (start, end) = GoalMetricWindow.dateRange(for: metric.window, now: now)
    else { return 0 }
    let descriptor = FetchDescriptor<NutritionEntryEntity>(
      predicate: #Predicate { $0.loggedAt >= start && $0.loggedAt < end }
    )
    let entries = (try? context.fetch(descriptor)) ?? []
    switch metric.key {
    case "nutrition.protein_sum":
      return entries.reduce(0.0) { $0 + $1.proteinG }
    case "nutrition.fat_sum":
      return entries.reduce(0.0) { $0 + $1.fatG }
    case "nutrition.carbs_sum":
      return entries.reduce(0.0) { $0 + $1.carbsG }
    case "nutrition.fiber_sum":
      return entries.reduce(0.0) { $0 + ($1.fiberG ?? 0) }
    case "nutrition.kcal_sum":
      // Mirror the section UI: when an entry has no stored kcal, derive it from
      // macros (4·protein + 9·fat + 4·carbs + 7·alcohol) so macro-only meals
      // aren't silently counted as zero. See ChecklistMirror.makeNutritionEntry.
      return entries.reduce(0.0) {
        $0 + ($1.kcal ?? (4 * $1.proteinG + 9 * $1.fatG + 4 * $1.carbsG + 7 * ($1.alcoholG ?? 0)))
      }
    case "nutrition.water_sum":
      return entries.reduce(0.0) { $0 + ($1.waterMl ?? 0) }
    default:
      return nil
    }
  }

  // Starter targets. Water is the one universal enough to pre-check; protein is
  // a common opt-in (the rest of the macros are too personal to default-suggest
  // — the user sets those from the section's goals strip). Editable in the
  // onboarding step before they're seeded.
  static func suggestedGoals(context: ModelContext) -> [SuggestedGoal] {
    [
      SuggestedGoal(metricKey: "nutrition.water_sum", sectionKey: "nutrition",
                    text: "Drink 2000 ml water/day",
                    comparator: "gte", target: 2000, upper: nil,
                    window: "today", unitLabel: "ml", recommended: true),
      SuggestedGoal(metricKey: "nutrition.protein_sum", sectionKey: "nutrition",
                    text: "Eat 100 g protein/day",
                    comparator: "gte", target: 100, upper: nil,
                    window: "today", unitLabel: "g", recommended: false),
    ]
  }
}

private struct NutritionDetailContent: View {
  @Environment(SettingsStore.self) private var store
  @Environment(\.modelContext) private var modelContext
  @Environment(CKEngine.self) private var ckEngine
  @AppStorage(SettingsKey.nutritionTrackFasting)
  private var trackFasting: Bool = false
  @AppStorage(SettingsKey.nutritionHeatmapMetric)
  private var heatmapMetricRaw: String = NutritionHeatmapMetric.protein.rawValue

  var body: some View {
    // Macro target *ranges* now live in goals (range goals tagged
    // "nutrition") — set them in the Nutrition section's goals strip or under
    // the Food coach, where they show live progress. The old read-only
    // "Macro ranges" mirror that lived here has moved out; this pane keeps the
    // tile config (colors / visibility) and fasting, which aren't goals.
    MacroTilesEditor(initialPrefs: MacroCatalog.reconcile(
      store.serverSettings?.nutrition?.macroTiles ?? MacroCatalog.defaultTilePrefs()))
    Section {
      // Write through the store so the choice syncs (the wrist publisher and
      // every device read it); `setTrackFasting` keeps the local @AppStorage
      // mirror this view binds to in lockstep.
      Toggle("Track fasting", isOn: Binding(
        get: { trackFasting },
        set: { store.setTrackFasting($0, context: modelContext, engine: ckEngine) }))
    } footer: {
      Text("When on, the Nutrition tile shows a live fasting timer after your last meal of the day, and you can choose what the heatmap encodes.")
    }
    if trackFasting {
      Section("Fasting target") {
        if let fasting = store.macros?.fasting {
          sectionDetailRow("Range", "\(Int(fasting.min))–\(Int(fasting.max)) h")
        } else {
          sectionDetailRow("Range", "\(Int(FastingDefaults.targetMinH))–\(Int(FastingDefaults.targetMaxH)) h")
        }
      }
      Section("Heatmap shows") {
        Picker("Heatmap metric", selection: $heatmapMetricRaw) {
          ForEach(NutritionHeatmapMetric.allCases) { m in
            Text(m.label).tag(m.rawValue)
          }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      }
    }
  }
}

@MainActor func nutritionEntryExportDict(_ e: NutritionEntryEntity) -> [String: Any] {
  compact([
    "id": e.id, "loggedAt": isoDate(e.loggedAt),
    "updatedAt": isoDate(e.updatedAt),
    "emoji": e.emoji, "foods": e.foods, "note": e.note,
    "mealType": e.mealType, "source": e.source,
    "proteinG": e.proteinG, "fatG": e.fatG, "carbsG": e.carbsG,
    "fiberG": e.fiberG, "sugarG": e.sugarG,
    "saturatedFatG": e.saturatedFatG, "alcoholG": e.alcoholG,
    "kcal": e.kcal, "sodiumMg": e.sodiumMg,
    "cholesterolMg": e.cholesterolMg, "potassiumMg": e.potassiumMg,
    "waterMl": e.waterMl,
  ])
}

@MainActor func nutritionSummaryExportDict(_ e: NutritionDailySummaryEntity) -> [String: Any] {
  compact([
    "id": e.id, "date": e.date, "entryCount": e.entryCount,
    "firstLoggedAt": e.firstLoggedAt.map(isoDate),
    "lastLoggedAt": e.lastLoggedAt.map(isoDate),
    "computedAt": isoDate(e.computedAt),
    "kcal": e.kcal, "proteinG": e.proteinG, "fatG": e.fatG, "carbsG": e.carbsG,
    "fiberG": e.fiberG, "sugarG": e.sugarG,
    "saturatedFatG": e.saturatedFatG, "alcoholG": e.alcoholG,
    "sodiumMg": e.sodiumMg, "cholesterolMg": e.cholesterolMg,
    "potassiumMg": e.potassiumMg, "waterMl": e.waterMl,
  ])
}
