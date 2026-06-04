#if DEBUG
import Foundation
import SwiftData

/// DEBUG-only curated dataset for App Store / marketing screenshots.
///
/// Inserts **directly** into the `ModelContext` — deliberately NOT through the
/// mutators, which would enqueue CloudKit writes and post change notifications.
/// Only ever runs when `DemoSeedMode.isOn` (a release build can't trigger it),
/// against the in-memory store, so it never touches real data. Dates are
/// relative to "now", so screenshots always look current.
public enum DemoSeed {
  @MainActor
  public static func populate(context ctx: ModelContext, today: String) {
    seedLayout() // homepage layout for screenshots (Sparkline by default)
    // In-memory store starts empty; this guard just prevents a double-seed if
    // the launch `.task` ever re-runs (unique-id collisions otherwise).
    let already = (try? ctx.fetchCount(FetchDescriptor<HabitDefinitionEntity>())) ?? 0
    guard already == 0 else { return }

    seedTasks(ctx)
    seedHabits(ctx)
    seedSupplements(ctx)
    seedNutrition(ctx)
    seedTraining(ctx)
    seedChores(ctx)
    seedCaffeine(ctx)
    seedMood(ctx)
    seedGroceries(ctx)
    seedSectionColors(ctx)
    try? ctx.save()
  }

  // MARK: - date helpers

  /// YYYY-MM-DD `offset` days from now (0 = today, -1 = yesterday).
  private static func day(_ offset: Int) -> String {
    let d = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
    return SeptenaDate.format(d) ?? SeptenaDate.today
  }

  /// A `Date` `offset` days ago at the given local hour:minute.
  private static func at(_ offset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    let cal = Calendar.current
    let base = cal.date(byAdding: .day, value: offset, to: Date()) ?? Date()
    return cal.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
  }

  // MARK: - sections

  private static func seedTasks(_ ctx: ModelContext) {
    var pos = 1024.0
    let open = [
      "Reply to the landlord", "Book flights for the trip", "Draft the Q3 plan",
      "Call the dentist", "Review the design doc", "Renew the parking permit",
    ]
    for (i, t) in open.enumerated() {
      ctx.insert(TaskEntity(id: "demo-task-open-\(i)", title: t, today: true, position: pos))
      pos += 1024
    }
    for (i, t) in ["Morning run", "Clear the inbox", "Stretch 10 min"].enumerated() {
      ctx.insert(TaskEntity(
        id: "demo-task-done-\(i)", title: t,
        statusRaw: TaskStatus.done.rawValue, today: true,
        completedAt: SeptenaDate.today, position: pos))
      pos += 1024
    }
  }

  private static func seedHabits(_ ctx: ModelContext) {
    // (title, emoji, bucket, streakDays) — Morning walk crosses the 7-day mark.
    let habits: [(String, String, String, Int)] = [
      ("Morning walk", "🚶", "morning", 12),
      ("Meditate", "🧘", "morning", 5),
      ("Stretch", "🤸", "afternoon", 6),
      ("Read", "📖", "evening", 8),
      ("Journal", "✍️", "evening", 3),
    ]
    for (i, h) in habits.enumerated() {
      let id = "demo-habit-\(i)"
      ctx.insert(HabitDefinitionEntity(id: id, title: h.0, emoji: h.1, bucket: h.2, sortIndex: i))
      for d in 0..<h.3 {
        let date = day(-d)
        ctx.insert(HabitDayStateEntity(
          id: "habit:\(date):\(id)", date: date, habitID: id, done: true, skipped: false))
      }
      let broke = day(-h.3) // a miss before the run, so it reads as a real streak
      ctx.insert(HabitDayStateEntity(
        id: "habit:\(broke):\(id)", date: broke, habitID: id, done: false, skipped: false))
    }
  }

  private static func seedSupplements(_ ctx: ModelContext) {
    let supps: [(String, String, String?)] = [
      ("Magnesium", "💊", "evening"), ("Omega-3", "🐟", "morning"),
      ("Vitamin D", "☀️", "morning"), ("Creatine", "💪", nil),
    ]
    for (i, s) in supps.enumerated() {
      let id = "demo-supp-\(i)"
      ctx.insert(SupplementDefinitionEntity(id: id, title: s.0, emoji: s.1, bucket: s.2, sortIndex: i))
      for d in 0..<14 {
        let date = day(-d)
        ctx.insert(SupplementDayStateEntity(
          id: "supplement:\(date):\(id)", date: date, supplementID: id, done: d % 5 != 2)) // ~80%
      }
    }
  }

  private static func seedNutrition(_ ctx: ModelContext) {
    // 14 daily summaries (drive the macro tile/chart) + today's three meals.
    for d in 0..<14 {
      let date = day(-d)
      ctx.insert(NutritionDailySummaryEntity(
        id: date, date: date, entryCount: 3,
        kcal: 2120 + Double((d * 37) % 280), proteinG: 118 + Double((d * 5) % 22),
        fatG: 68 + Double((d * 3) % 14), carbsG: 224 + Double((d * 11) % 40),
        fiberG: 27 + Double(d % 9), waterMl: 1800 + Double((d * 90) % 500)))
    }
    let meals: [(Int, String, String, Double, Double, Double, Double)] = [
      (8, "🥣", "Oats, blueberries, Greek yogurt", 24, 9, 58, 380),
      (13, "🥗", "Chicken, quinoa, roasted veg", 46, 18, 52, 560),
      (19, "🍝", "Salmon, pasta, side salad", 42, 26, 70, 720),
    ]
    for (i, m) in meals.enumerated() {
      ctx.insert(NutritionEntryEntity(
        id: "demo-meal-\(i)", loggedAt: at(0, m.0), emoji: m.1, foods: m.2,
        mealType: ["breakfast", "lunch", "dinner"][i],
        proteinG: m.3, fatG: m.4, carbsG: m.5, kcal: m.6, waterMl: 350))
    }
  }

  private static func seedTraining(_ ctx: ModelContext) {
    ctx.insert(SessionTypeEntity(id: "upper", label: "Upper", emoji: "💪",
                                 exercises: ["bench-press", "row", "overhead-press"], sortIndex: 0))
    ctx.insert(SessionTypeEntity(id: "lower", label: "Lower", emoji: "🦵",
                                 exercises: ["squat", "deadlift"], sortIndex: 1))
    ctx.insert(SessionTypeEntity(id: "cardio", label: "Cardio", emoji: "🏃",
                                 exercises: ["run"], sortIndex: 2))
    for (slug, name, type) in [
      ("bench-press", "Bench press", "strength"), ("row", "Barbell row", "strength"),
      ("overhead-press", "Overhead press", "strength"), ("squat", "Back squat", "strength"),
      ("deadlift", "Deadlift", "strength"), ("run", "Run", "cardio"),
    ] {
      ctx.insert(ExerciseDefinitionEntity(id: slug, name: name, type: type))
    }
    // Sessions across the last two weeks (strength logged with weight×sets×reps,
    // cardio with duration/distance).
    var n = 0
    func strength(_ off: Int, _ type: String, _ ex: String, _ w: Double, _ reps: String) {
      let e = ExerciseEntryEntity(id: "demo-ex-\(n)", date: day(off), time: "18:00",
                                  sessionType: type, exercise: ex, weight: w, sets: "3", reps: reps)
      e.occurredAt = at(off, 18) // event tiles query occurredAt, not the date string
      ctx.insert(e); n += 1
    }
    func cardio(_ off: Int, _ min: Double, _ m: Double) {
      let e = ExerciseEntryEntity(id: "demo-ex-\(n)", date: day(off), time: "07:15",
                                  sessionType: "cardio", exercise: "run", durationMin: min, distanceM: m)
      e.occurredAt = at(off, 7, 15)
      ctx.insert(e); n += 1
    }
    strength(-1, "upper", "bench-press", 62.5, "8"); strength(-1, "upper", "row", 55, "10")
    cardio(-2, 32, 5200)
    strength(-4, "lower", "squat", 90, "5"); strength(-4, "lower", "deadlift", 120, "3")
    strength(-6, "upper", "overhead-press", 40, "8"); cardio(-7, 28, 4600)
    strength(-9, "lower", "squat", 87.5, "5"); cardio(-11, 35, 5800)
  }

  private static func seedChores(_ ctx: ModelContext) {
    // (title, emoji, cadenceDays, lastCompletedOffset) — mix of due/overdue/fresh.
    let chores: [(String, String, Int, Int)] = [
      ("Water the plants", "🪴", 4, -5),       // overdue
      ("Vacuum", "🧹", 7, -7),                  // due today
      ("Change the sheets", "🛏️", 7, -2),       // due in 5
      ("Clean the coffee machine", "☕️", 14, -10),
      ("Take out recycling", "♻️", 7, -6),
    ]
    for (i, c) in chores.enumerated() {
      let id = "demo-chore-\(i)"
      ctx.insert(ChoreDefinitionEntity(id: id, title: c.0, emoji: c.1, cadenceDays: c.2, sortIndex: i))
      let date = day(c.3)
      ctx.insert(ChoreEventEntity(id: "demo-chore-ev-\(i)", choreID: id, action: "complete",
                                  date: date, sortKey: "\(date)::\(id)"))
    }
  }

  private static func seedCaffeine(_ ctx: ModelContext) {
    // ~0.7 cups/day, mostly mornings. Grams vary (used later for the
    // caffeine→sleep correlation once synthetic Oura is seeded).
    let grams: [Double?] = [20, 18, nil, 24, 16, nil, 22, 19, nil, 25, 18, nil, 21, 17]
    for (d, g) in grams.enumerated() {
      guard let g else { continue }
      let e = CaffeineEventEntity(id: "demo-caf-\(d)", date: day(-d), time: "07:40",
                                  method: d % 3 == 0 ? "matcha" : "v60", grams: g)
      e.occurredAt = at(-d, 7, 40)
      ctx.insert(e)
    }
  }

  private static func seedMood(_ ctx: ModelContext) {
    // (dayOffset, time, bucket, quadrant, arousal, valence, emotion)
    let moods: [(Int, String, String, String, Int, Int, String)] = [
      (0, "08:30:00", "morning", "lap", 1, 3, "Calm"),
      (0, "17:30:00", "evening", "hap", 3, 3, "Upbeat"),
      (-1, "09:00:00", "morning", "hap", 2, 2, "Focused"),
      (-2, "21:00:00", "evening", "lan", 1, 1, "Tired"),
      (-3, "13:00:00", "afternoon", "han", 2, 1, "Stressed"),
      (-4, "08:45:00", "morning", "lap", 1, 3, "Content"),
      (-6, "18:00:00", "evening", "hap", 3, 3, "Energized"),
    ]
    for (i, m) in moods.enumerated() {
      let e = MoodEventEntity(id: "demo-mood-\(i)", date: day(m.0), time: m.1, bucket: m.2,
                              quadrant: m.3, arousal: m.4, valence: m.5, emotion: m.6)
      e.occurredAt = at(m.0, Int(m.1.prefix(2)) ?? 9)
      ctx.insert(e)
    }
  }

  private static func seedGroceries(_ ctx: ModelContext) {
    for (i, c) in ["Produce", "Pantry", "Dairy", "Household"].enumerated() {
      ctx.insert(GroceryCategoryEntity(id: "demo-cat-\(i)", name: c, sortIndex: i))
    }
    // (name, category, emoji, low)
    let items: [(String, String, String, Bool)] = [
      ("Bananas", "Produce", "🍌", true), ("Spinach", "Produce", "🥬", false),
      ("Avocados", "Produce", "🥑", true), ("Oats", "Pantry", "🌾", false),
      ("Olive oil", "Pantry", "🫒", true), ("Coffee beans", "Pantry", "☕️", false),
      ("Greek yogurt", "Dairy", "🥛", false), ("Eggs", "Dairy", "🥚", true),
      ("Dish soap", "Household", "🧼", false), ("Paper towels", "Household", "🧻", false),
    ]
    for (i, it) in items.enumerated() {
      ctx.insert(GroceryItemEntity(id: "demo-groc-\(i)", name: it.0, category: it.1,
                                   emoji: it.2, low: it.3, sortIndex: i))
    }
  }

  // MARK: - presentation

  /// Homepage layout for screenshots — Sparkline (`dense`) by default; override
  /// with `-SeptenaLayout <dense|heatmap|tiles|correlations>` (also accepts
  /// `sparkline`/`histogram`). Key mirrors `SettingsKey.homepageLayout`.
  private static func seedLayout() {
    var raw = "dense"
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "-SeptenaLayout"), i + 1 < args.count {
      let v = args[i + 1]
      raw = ["sparkline": "dense", "histogram": "tiles"][v] ?? v
    }
    UserDefaults.standard.set(raw, forKey: "septena.homepage.layout")
  }

  /// The manifest backfill creates SectionEntity rows but not always with an
  /// accent, so the dashboard renders a wall of fallback gray. Paint every
  /// section from the brand palette. (SectionTheme.defaultPalette omits
  /// hydration + mood — included here.) SectionEntity.id is the section key.
  private static func seedSectionColors(_ ctx: ModelContext) {
    let palette: [String: String] = [
      "tasks": "#ef4444", "habits": "#22c55e", "training": "#f97316", "chores": "#a855f7",
      "supplements": "#3b82f6", "sleep": "#6366f1", "nutrition": "#f59e0b", "groceries": "#84cc16",
      "caffeine": "#92400e", "cannabis": "#65a30d", "body": "#ec4899", "gut": "#b45309",
      "activity": "#06b6d4", "goals": "#8b5cf6", "hydration": "#0ea5e9", "mood": "#f43f5e",
    ]
    let rows = (try? ctx.fetch(FetchDescriptor<SectionEntity>())) ?? []
    for r in rows { if let c = palette[r.id] { r.color = c } }
  }
}
#endif
