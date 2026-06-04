#if DEBUG
import Foundation
import SwiftData

/// DEBUG-only curated dataset for App Store / marketing screenshots.
///
/// Generates ~90 days of *realistic* data with a deterministic seeded PRNG, so
/// heatmaps fill in, sparklines have shape, and the Correlations screen finds
/// real signals (late/heavy caffeine → lower sleep → lower mood; training →
/// better sleep). Inserts directly into the `ModelContext` (NOT mutators — no
/// CloudKit, no notifications). Only runs when `DemoSeedMode.isOn`, against the
/// in-memory store, so it never touches real data. Dates are relative to now.
///
/// Sleep (Oura) and Body (Withings) reach the dashboard because their providers
/// fall back to the SwiftData mirror (`OuraStore`/`WithingsStore`) when there's
/// no API token — so seeding `OuraNightEntity`/`WithingsRowEntity` is enough.
public enum DemoSeed {
  static let days = 90

  @MainActor
  public static func populate(context ctx: ModelContext, today: String) {
    seedLayout()
    guard (try? ctx.fetchCount(FetchDescriptor<HabitDefinitionEntity>())) == 0 else { return }
    var rng = SeededRNG(seed: 0x5EED_5E97_A11_C0DE)

    // --- shared, correlated daily signals (index 0 = today) ---
    var caffGrams = [Double?](repeating: nil, count: days)
    var caffLate = [Bool](repeating: false, count: days)
    var trainDay = [Bool](repeating: false, count: days)
    var sleep = [Int](repeating: 0, count: days)
    for d in 0..<days {
      let wknd = isWeekend(-d)
      if rng.chance(wknd ? 0.78 : 0.92) {
        caffGrams[d] = Double(rng.int(16, 24))
        caffLate[d] = rng.chance(0.22)            // an afternoon cup
      }
      trainDay[d] = rng.chance(wknd ? 0.40 : 0.6) // ~4 sessions / week
    }
    for d in 0..<days {
      var s = 80.0
      if caffLate[d] { s -= 9 }                    // the headline correlation
      if let g = caffGrams[d], g > 22 { s -= 3 }
      if trainDay[d] { s += 3 }
      s += rng.dbl(-5, 5)
      sleep[d] = Int(min(94, max(58, s)))
    }

    seedTasks(ctx)
    seedHabits(ctx, &rng)
    seedSupplements(ctx, &rng)
    seedChores(ctx, &rng)
    seedNutrition(ctx, &rng, trainDay: trainDay)
    seedTraining(ctx, &rng, trainDay: trainDay)
    seedCaffeine(ctx, grams: caffGrams, late: caffLate)
    seedSleep(ctx, &rng, scores: sleep)
    seedMood(ctx, &rng, scores: sleep)
    seedBody(ctx, &rng)
    seedGut(ctx, &rng)
    seedCannabis(ctx, &rng)
    seedGoals(ctx)
    seedGroceries(ctx)
    seedSectionColors(ctx)
    try? ctx.save()
  }

  // MARK: - date helpers (offset 0 = today, negative = past)

  private static func dateObj(_ off: Int) -> Date {
    Calendar.current.date(byAdding: .day, value: off, to: Date()) ?? Date()
  }
  private static func day(_ off: Int) -> String { SeptenaDate.format(dateObj(off)) ?? SeptenaDate.today }
  private static func at(_ off: Int, _ h: Int, _ m: Int = 0) -> Date {
    Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: dateObj(off)) ?? dateObj(off)
  }
  private static func isWeekend(_ off: Int) -> Bool { Calendar.current.isDateInWeekend(dateObj(off)) }

  // MARK: - sections

  private static func seedTasks(_ ctx: ModelContext) {
    var pos = 1024.0
    for (i, t) in ["Reply to the landlord", "Book flights for the trip", "Draft the Q3 plan",
                   "Call the dentist", "Review the design doc", "Renew the parking permit"].enumerated() {
      ctx.insert(TaskEntity(id: "demo-task-open-\(i)", title: t, today: true, position: pos)); pos += 1024
    }
    for (i, t) in ["Morning run", "Clear the inbox", "Stretch 10 min"].enumerated() {
      ctx.insert(TaskEntity(id: "demo-task-done-\(i)", title: t, statusRaw: TaskStatus.done.rawValue,
                            today: true, completedAt: SeptenaDate.today, position: pos)); pos += 1024
    }
  }

  private static func seedHabits(_ ctx: ModelContext, _ rng: inout SeededRNG) {
    // (title, emoji, bucket, current streak, baseline adherence)
    let habits: [(String, String, String, Int, Double)] = [
      ("Morning walk", "🚶", "morning", 12, 0.85),
      ("Meditate", "🧘", "morning", 5, 0.80),
      ("Stretch", "🤸", "afternoon", 6, 0.78),
      ("Read", "📖", "evening", 8, 0.88),
      ("Journal", "✍️", "evening", 3, 0.72),
    ]
    for (i, h) in habits.enumerated() {
      let id = "demo-habit-\(i)"
      ctx.insert(HabitDefinitionEntity(id: id, title: h.0, emoji: h.1, bucket: h.2, sortIndex: i))
      for d in 0..<days {
        let done = d < h.3 ? true : rng.chance(h.4)   // force the current streak, then realistic
        let date = day(-d)
        ctx.insert(HabitDayStateEntity(id: "habit:\(date):\(id)", date: date, habitID: id,
                                       done: done, skipped: false))
      }
    }
  }

  private static func seedSupplements(_ ctx: ModelContext, _ rng: inout SeededRNG) {
    let supps: [(String, String, String?)] = [
      ("Magnesium", "💊", "evening"), ("Omega-3", "🐟", "morning"),
      ("Vitamin D", "☀️", "morning"), ("Creatine", "💪", nil),
    ]
    for (i, s) in supps.enumerated() {
      let id = "demo-supp-\(i)"
      ctx.insert(SupplementDefinitionEntity(id: id, title: s.0, emoji: s.1, bucket: s.2, sortIndex: i))
      for d in 0..<days {
        let date = day(-d)
        ctx.insert(SupplementDayStateEntity(id: "supplement:\(date):\(id)", date: date,
                                            supplementID: id, done: rng.chance(0.82)))
      }
    }
  }

  private static func seedChores(_ ctx: ModelContext, _ rng: inout SeededRNG) {
    let chores: [(String, String, Int, Int)] = [   // title, emoji, cadenceDays, lastDoneOffset
      ("Water the plants", "🪴", 4, -5), ("Vacuum", "🧹", 7, -7),
      ("Change the sheets", "🛏️", 7, -2), ("Clean the coffee machine", "☕️", 14, -10),
      ("Take out recycling", "♻️", 7, -6),
    ]
    for (i, c) in chores.enumerated() {
      let id = "demo-chore-\(i)"
      ctx.insert(ChoreDefinitionEntity(id: id, title: c.0, emoji: c.1, cadenceDays: c.2, sortIndex: i))
      // completion history every ~cadence days back to 90d, plus the explicit last-done.
      var off = c.3
      var n = 0
      while off > -days {
        let date = day(off)
        ctx.insert(ChoreEventEntity(id: "demo-chore-ev-\(i)-\(n)", choreID: id, action: "complete",
                                    date: date, sortKey: "\(date)::\(id)"))
        off -= c.2 + rng.int(-1, 1); n += 1
      }
    }
  }

  private static func seedNutrition(_ ctx: ModelContext, _ rng: inout SeededRNG, trainDay: [Bool]) {
    for d in 0..<days {
      let date = day(-d)
      let wknd = isWeekend(-d)
      let protein = 108 + (trainDay[d] ? 16 : 0) + rng.int(-10, 12)
      let kcal = 2050 + (wknd ? 240 : 0) + rng.int(-180, 220)
      ctx.insert(NutritionDailySummaryEntity(
        id: date, date: date, entryCount: 3,
        kcal: Double(kcal), proteinG: Double(protein),
        fatG: Double(62 + rng.int(-8, 14)), carbsG: Double(210 + rng.int(-30, 50)),
        fiberG: Double(26 + rng.int(-6, 9)), waterMl: Double(1600 + rng.int(0, 800))))
    }
    // Today's individual meals (for the detail view + today tile).
    let meals: [(Int, String, String, Double, Double, Double, Double)] = [
      (8, "🥣", "Oats, blueberries, Greek yogurt", 24, 9, 58, 380),
      (13, "🥗", "Chicken, quinoa, roasted veg", 46, 18, 52, 560),
      (19, "🍝", "Salmon, pasta, side salad", 42, 26, 70, 720),
    ]
    for (i, m) in meals.enumerated() {
      ctx.insert(NutritionEntryEntity(id: "demo-meal-\(i)", loggedAt: at(0, m.0), emoji: m.1, foods: m.2,
                                      mealType: ["breakfast", "lunch", "dinner"][i],
                                      proteinG: m.3, fatG: m.4, carbsG: m.5, kcal: m.6, waterMl: 350))
    }
  }

  private static func seedTraining(_ ctx: ModelContext, _ rng: inout SeededRNG, trainDay: [Bool]) {
    ctx.insert(SessionTypeEntity(id: "upper", label: "Upper", emoji: "💪",
                                 exercises: ["bench-press", "row", "overhead-press"], sortIndex: 0))
    ctx.insert(SessionTypeEntity(id: "lower", label: "Lower", emoji: "🦵", exercises: ["squat", "deadlift"], sortIndex: 1))
    ctx.insert(SessionTypeEntity(id: "cardio", label: "Cardio", emoji: "🏃", exercises: ["run"], sortIndex: 2))
    for (slug, name, type) in [("bench-press", "Bench press", "strength"), ("row", "Barbell row", "strength"),
                               ("overhead-press", "Overhead press", "strength"), ("squat", "Back squat", "strength"),
                               ("deadlift", "Deadlift", "strength"), ("run", "Run", "cardio")] {
      ctx.insert(ExerciseDefinitionEntity(id: slug, name: name, type: type))
    }
    var n = 0
    func add(_ off: Int, _ type: String, _ ex: String, w: Double? = nil, reps: String? = nil,
             min: Double? = nil, dist: Double? = nil, hour: Int) {
      let e = ExerciseEntryEntity(id: "demo-ex-\(n)", date: day(off), time: String(format: "%02d:00", hour),
                                  sessionType: type, exercise: ex, weight: w, sets: w != nil ? "3" : nil,
                                  reps: reps, durationMin: min, distanceM: dist)
      e.occurredAt = at(off, hour); ctx.insert(e); n += 1
    }
    // Progressive overload: weights creep up as we approach today (smaller offset).
    for d in 0..<days where trainDay[d] {
      let progress = Double(days - d) / Double(days)           // 0 (old) → 1 (recent)
      let kind = (d % 3)
      switch kind {
      case 0:
        add(-d, "upper", "bench-press", w: (55 + progress * 12).rounded(), reps: "8", hour: 18)
        add(-d, "upper", "row", w: (50 + progress * 10).rounded(), reps: "10", hour: 18)
      case 1:
        add(-d, "lower", "squat", w: (80 + progress * 18).rounded(), reps: "5", hour: 18)
        add(-d, "lower", "deadlift", w: (100 + progress * 22).rounded(), reps: "3", hour: 18)
      default:
        add(-d, "cardio", "run", min: Double(28 + rng.int(0, 12)), dist: Double(4600 + rng.int(0, 1800)), hour: 7)
      }
    }
  }

  private static func seedCaffeine(_ ctx: ModelContext, grams: [Double?], late: [Bool]) {
    for d in 0..<days {
      guard let g = grams[d] else { continue }
      let date = day(-d)
      let am = CaffeineEventEntity(id: "demo-caf-\(d)", date: date, time: "07:40",
                                   method: d % 4 == 0 ? "matcha" : "v60", grams: g)
      am.occurredAt = at(-d, 7, 40); ctx.insert(am)
      if late[d] {
        let pm = CaffeineEventEntity(id: "demo-caf-\(d)-pm", date: date, time: "15:10", method: "v60",
                                     grams: Double(Int(g) - 4))
        pm.occurredAt = at(-d, 15, 10); ctx.insert(pm)
      }
    }
  }

  private static func seedSleep(_ ctx: ModelContext, _ rng: inout SeededRNG, scores: [Int]) {
    for d in 0..<days {
      let s = scores[d]
      let total = 6.0 + Double(s - 58) / 36.0 * 2.3                 // ~6.0–8.3h
      ctx.insert(OuraNightEntity(
        id: day(-d), sleepScore: s, readinessScore: min(95, max(55, s + rng.int(-4, 4))),
        totalH: (total * 10).rounded() / 10,
        deepH: ((total * 0.18) * 10).rounded() / 10,
        remH: ((total * 0.22) * 10).rounded() / 10,
        efficiency: min(98, 82 + (s - 70) / 3),
        hrv: 30 + Int(Double(s - 58) * 0.7) + rng.int(-4, 4),       // higher score → higher HRV
        restingHr: 60 - Int(Double(s - 58) * 0.15) + rng.int(-2, 2),
        bedtime: "23:1\(rng.int(0, 5))", wakeTime: "07:0\(rng.int(0, 9))"))
    }
  }

  private static func seedMood(_ ctx: ModelContext, _ rng: inout SeededRNG, scores: [Int]) {
    // Quadrant biased by that day's sleep — good sleep skews pleasant/activated.
    for d in 0..<days {
      let count = d < 7 ? 2 : (rng.chance(0.6) ? 1 : 0)            // denser recent history
      for k in 0..<count {
        let good = scores[d] >= 76
        let morning = k == 0
        let quadrant: String
        let (arousal, valence, emotion): (Int, Int, String)
        if good {
          quadrant = morning ? "lap" : "hap"
          (arousal, valence, emotion) = morning ? (1, 3, "Calm") : (3, 3, "Upbeat")
        } else if scores[d] <= 66 {
          quadrant = morning ? "lan" : "han"
          (arousal, valence, emotion) = morning ? (1, 1, "Tired") : (2, 1, "Stressed")
        } else {
          quadrant = "lap"; (arousal, valence, emotion) = (2, 2, "Focused")
        }
        let h = morning ? 8 : 18
        let e = MoodEventEntity(id: "demo-mood-\(d)-\(k)", date: day(-d),
                                time: String(format: "%02d:30:00", h), bucket: morning ? "morning" : "evening",
                                quadrant: quadrant, arousal: arousal, valence: valence, emotion: emotion)
        e.occurredAt = at(-d, h, 30); ctx.insert(e)
      }
    }
  }

  private static func seedBody(_ ctx: ModelContext, _ rng: inout SeededRNG) {
    // Slow cut: ~78.6kg 90 days ago → ~76.6kg today, with daily noise. ~5 weigh-ins/week.
    for d in 0..<days where rng.chance(0.7) {
      let t = Double(d) / Double(days - 1)                         // 0 today → 1 oldest
      let weight = 76.6 + t * 2.0 + rng.dbl(-0.3, 0.3)
      let fat = 16.2 + t * 1.9 + rng.dbl(-0.25, 0.25)
      ctx.insert(WithingsRowEntity(id: day(-d),
                                   weightKg: (weight * 10).rounded() / 10,
                                   fatPct: (fat * 10).rounded() / 10))
    }
  }

  private static func seedGroceries(_ ctx: ModelContext) {
    for (i, c) in ["Produce", "Pantry", "Dairy", "Household"].enumerated() {
      ctx.insert(GroceryCategoryEntity(id: "demo-cat-\(i)", name: c, sortIndex: i))
    }
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

  /// Paint every section from the brand palette (the manifest backfill leaves
  /// colors empty → fallback gray). SectionEntity.id is the section key.
  private static func seedSectionColors(_ ctx: ModelContext) {
    let palette: [String: String] = [
      "tasks": "#ef4444", "habits": "#22c55e", "training": "#f97316", "chores": "#a855f7",
      "supplements": "#3b82f6", "sleep": "#6366f1", "nutrition": "#f59e0b", "groceries": "#84cc16",
      "caffeine": "#92400e", "cannabis": "#65a30d", "body": "#ec4899", "gut": "#b45309",
      "activity": "#06b6d4", "goals": "#8b5cf6", "hydration": "#0ea5e9", "mood": "#f43f5e",
    ]
    for r in (try? ctx.fetch(FetchDescriptor<SectionEntity>())) ?? [] {
      if let c = palette[r.id] { r.color = c }
    }
  }
}

/// Deterministic SplitMix64 — reproducible "random" so screenshots are stable.
struct SeededRNG: RandomNumberGenerator {
  private var s: UInt64
  init(seed: UInt64) { s = seed }
  mutating func next() -> UInt64 {
    s &+= 0x9E37_79B9_7F4A_7C15
    var z = s
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
  mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &self) < p }
  mutating func int(_ lo: Int, _ hi: Int) -> Int { Int.random(in: lo...hi, using: &self) }
  mutating func dbl(_ lo: Double, _ hi: Double) -> Double { Double.random(in: lo...hi, using: &self) }
}
#endif
