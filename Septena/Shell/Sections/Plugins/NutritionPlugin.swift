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

  /// The one new-meal commit path: decides fast-breaking `.bloom` vs quiet
  /// tick from the local mirror at commit time (never display state), then
  /// routes through `SectionLog`. Water-only rows (hydration's sentinel)
  /// don't break a fast, and only *today's* first meal celebrates — a
  /// past-day backfill is a correction, not a moment.
  @MainActor
  static func commitMeal(loggedAt: Date,
                         accent: Color,
                         announce: String? = nil,
                         logCommit: LogCommitCenter?,
                         write: () -> Void) {
    if breaksFast(at: loggedAt) {
      SectionLog.newLog(section: "nutrition", accent: accent,
                        announce: announce, logCommit: logCommit, write: write)
    } else {
      SectionLog.quietLog(announce: announce, write: write)
    }
  }

  /// True when `loggedAt` is today and no real meal (non-water entry)
  /// exists earlier that day in the local mirror.
  @MainActor
  private static func breaksFast(at loggedAt: Date) -> Bool {
    let cal = Calendar.current
    guard let today = SeptenaDate.parse(SeptenaDate.today),
          cal.isDate(loggedAt, inSameDayAs: today) else { return false }
    let dayStart = cal.startOfDay(for: loggedAt)
    guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return false }
    let descriptor = FetchDescriptor<NutritionEntryEntity>(
      predicate: #Predicate { $0.loggedAt >= dayStart && $0.loggedAt < dayEnd }
    )
    let rows = (try? LocalStore.shared.container.mainContext.fetch(descriptor)) ?? []
    return !rows.contains { !isWaterOnly($0) }
  }

  /// Hydration's water-only sentinel, on the entity (mirrors
  /// `HydrationPlugin.isHydrationOnly` for the DTO).
  private static func isWaterOnly(_ e: NutritionEntryEntity) -> Bool {
    e.foods.split(separator: "\n").map(String.init) == HydrationPlugin.waterFoodsMarker
      && (e.waterMl ?? 0) > 0
      && e.proteinG == 0 && e.fatG == 0 && e.carbsG == 0
  }

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

  static func evaluateAim(metric: GoalMetric, context: ModelContext) -> Double? {
    // Nutrition uses `loggedAt: Date` (not a string date column), so we
    // filter with a Date range rather than the YYYY-MM-DD string helper.
    guard let (start, end) = GoalMetricWindow.dateRange(for: metric.window)
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
      return entries.reduce(0.0) { $0 + ($1.kcal ?? 0) }
    case "nutrition.water_sum":
      return entries.reduce(0.0) { $0 + ($1.waterMl ?? 0) }
    default:
      return nil
    }
  }
}

private struct NutritionDetailContent: View {
  @Environment(SettingsStore.self) private var store
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
      Toggle("Track fasting", isOn: $trackFasting)
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
    HKSyncSection(label: "Write to Apple Health",
                  icon: "heart.text.square",
                  kind: .nutrition)
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
