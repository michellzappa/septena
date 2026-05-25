import SwiftUI
import SwiftData

// Nutrition. The food-list rendering rules (first item + " +N" suffix
// when there are more) and the macro detail line move here alongside
// the MCP contract that captures macro estimation conventions.

@MainActor
enum NutritionPlugin: SectionPlugin {
  static var manifest: SectionManifest {
    SectionManifest.byKey["nutrition"]!
  }

  static func destinationView() -> AnyView? { AnyView(NutritionDestinationView()) }

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
      // Filter out water-only entries — those belong to the Hydration
      // section's Today block, not here. A real meal that happens to
      // record waterMl still shows under Nutrition (it's a meal).
      .filter { $0.date == date && !HydrationPlugin.isHydrationOnly($0) }
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

private struct NutritionDetailContent: View {
  @Environment(SettingsStore.self) private var store
  @AppStorage(SettingsKey.nutritionTrackFasting)
  private var trackFasting: Bool = false
  @AppStorage(SettingsKey.nutritionHeatmapMetric)
  private var heatmapMetricRaw: String = NutritionHeatmapMetric.protein.rawValue

  var body: some View {
    if let m = store.macros {
      Section("Macro ranges") {
        sectionDetailRow("Protein", "\(Int(m.protein.min))–\(Int(m.protein.max)) g")
        sectionDetailRow("Fat",     "\(Int(m.fat.min))–\(Int(m.fat.max)) g")
        sectionDetailRow("Carbs",   "\(Int(m.carbs.min))–\(Int(m.carbs.max)) g")
        sectionDetailRow("Calories","\(Int(m.kcal.min))–\(Int(m.kcal.max)) kcal")
      }
    }
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
