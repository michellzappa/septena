import Foundation
import SwiftData

/// How far back the coach reads. Trailing window measured in weeks, where
/// "1 week" == today + the previous 6 days (the app's standard trailing-7
/// convention), so `daysBack` is `days - 1`.
enum CoachWindow: Int, CaseIterable, Identifiable {
  case week = 1, twoWeeks = 2, fourWeeks = 4, eightWeeks = 8

  var id: Int { rawValue }
  var weeks: Int { rawValue }
  var days: Int { rawValue * 7 }
  var daysBack: Int { days - 1 }
  var label: String { weeks == 1 ? "1 week" : "\(weeks) weeks" }
  var shortLabel: String { "\(weeks)w" }
}

/// One section's presence in the chat context — what the pills render.
/// `count` is the number of logged entries in the trailing window.
struct CoachDataPill: Identifiable {
  let id: String          // section key
  let label: String
  let systemImage: String
  let count: Int
}

// The "facts, not raw data" layer — same discipline as VirtueSummarizer,
// but grouped by SECTION and scoped to a coach preset + time window. Swift
// reads the window from the local SwiftData mirror (no network), computes
// per-section fact lines, and renders a compact plaintext block. The model
// never sees an entity — only counts and averages it can cite.
//
// Correlations are intentionally NOT used here yet — each section is read
// directly from its own store, mirroring the proven VirtueSummarizer reads.

@MainActor
enum CoachContextBuilder {

  /// All section keys a coach can summarize. `CoachDomain.wholeLife`
  /// (sectionKeys == nil) sees this whole list; other presets pick a slice.
  static let supportedKeys = ["training", "nutrition", "hydration", "supplements",
                              "sleep", "body", "mood", "gut", "tasks", "chores",
                              "habits", "caffeine", "cannabis"]

  /// A compact facts block for the preset + window, safe to paste into a
  /// prompt. `excluding` drops sections the user toggled off — the model
  /// only sees what's in scope, so it can't reference muted data.
  static func snapshot(for domain: CoachDomain, window: CoachWindow,
                       context: ModelContext, excluding: Set<String> = [], now: Date = Date()) -> String {
    let r = range(window, now)
    let keys = (domain.sectionKeys ?? supportedKeys).filter { !excluding.contains($0) }

    var lines: [String] = []
    var missing: [String] = []
    for key in keys {
      let produced = factLines(for: key, window, r, context)
      if produced.isEmpty { missing.append(key) } else { lines.append(contentsOf: produced) }
    }

    var blocks: [String] = []
    if lines.isEmpty {
      blocks.append("FACTS: nothing was logged in the last \(window.label) (\(r.from) → \(r.to)) for this area.")
    } else {
      var f = "FACTS (trailing \(window.label), \(r.from) → \(r.to) — computed locally, treat as ground truth):\n"
      f += lines.joined(separator: "\n")
      if !missing.isEmpty { f += "\nNo data this window: \(missing.joined(separator: ", "))." }
      blocks.append(f)
    }

    // Goals related to the in-scope sections — so the coach reflects against
    // the person's actual targets, not just raw numbers.
    let goals = goalLines(relatedTo: Set(keys), context)
    if !goals.isEmpty {
      blocks.append("""
        GOALS — targets the person SET for themselves (aspirations, NOT logged events). \
        Format is "goal text" — current / comparator target. Encourage progress; never \
        treat a goal as something that already happened:
        """ + "\n" + goals.joined(separator: "\n"))
    }

    return blocks.joined(separator: "\n\n")
  }

  // MARK: - Goals

  private static func goalLines(relatedTo keys: Set<String>, _ ctx: ModelContext) -> [String] {
    let goals = LocalCache.goals(in: ctx).filter { g in
      g.sections.contains(where: keys.contains)
        || (g.metricKey.flatMap { GoalMetricCatalog.sectionKey(for: $0) }.map(keys.contains) == true)
    }
    guard !goals.isEmpty else { return [] }
    return goals.prefix(8).map { g in
      if let p = GoalMetricEvaluator.evaluate(goal: g, context: ctx) {
        return "- \"\(g.text)\" — \(goalCaption(p))"
      }
      return "- \"\(g.text)\""
    }
  }

  private static func goalCaption(_ p: GoalMetricProgress) -> String {
    let cmp = p.comparator == "lte" ? "≤" : (p.comparator == "eq" ? "=" : "≥")
    var s = "\(num(p.current)) / \(cmp) \(num(p.target)) \(p.unitLabel)"
    if p.hit { s += " (met)" }
    return s
  }

  private static func num(_ v: Double) -> String {
    v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
  }

  /// The sections in this preset+window that actually have data, with entry
  /// counts and icons — what the chat's data pills show. Sections with zero
  /// entries are omitted (we only show what we can "see").
  static func availability(for domain: CoachDomain, window: CoachWindow,
                           context: ModelContext, now: Date = Date()) -> [CoachDataPill] {
    let r = range(window, now)
    let keys = domain.sectionKeys ?? supportedKeys
    return keys.compactMap { key in
      let n = count(for: key, r, context)
      guard n > 0 else { return nil }
      return CoachDataPill(id: key, label: sectionLabel(key), systemImage: icon(for: key), count: n)
    }
  }

  // MARK: - Window range

  /// Resolved trailing window: date-string bounds (for `date`-column rows)
  /// plus Date bounds (for `loggedAt`-column rows).
  private struct Range { let from: String; let to: String; let startDay: Date; let endExclusive: Date }

  private static func range(_ window: CoachWindow, _ now: Date) -> Range {
    let cal = Calendar.current
    let today = cal.startOfDay(for: now)
    let startDay = cal.date(byAdding: .day, value: -window.daysBack, to: today) ?? today
    let endExclusive = cal.date(byAdding: .day, value: 1, to: today) ?? today
    return Range(from: dayString(startDay), to: dayString(today),
                 startDay: startDay, endExclusive: endExclusive)
  }

  // MARK: - Per-section fact producers

  private static func factLines(for key: String, _ w: CoachWindow, _ r: Range, _ ctx: ModelContext) -> [String] {
    switch key {
    case "training":    return training(w, r, ctx)
    case "nutrition":   return nutrition(w, r, ctx)
    case "hydration":   return hydration(w, r, ctx)
    case "sleep":       return sleep(w, r, ctx)
    case "mood":        return mood(w, r, ctx)
    case "body":        return body(w, r, ctx)
    case "supplements": return adherence(SupplementDefinitionEntity.self, SupplementDayStateEntity.self,
                                         label: "Supplements", taken: "taken", w, r, ctx) { $0.date } done: { $0.done }
    case "habits":      return adherence(HabitDefinitionEntity.self, HabitDayStateEntity.self,
                                         label: "Habits", taken: "adherence", w, r, ctx) { $0.date } done: { $0.done }
    case "gut":         return gut(w, r, ctx)
    case "tasks":       return tasks(r, ctx)
    case "chores":      return chores(w, r, ctx)
    case "caffeine":    return caffeine(w, r, ctx)
    case "cannabis":    return cannabis(w, r, ctx)
    default:            return []
    }
  }

  private static func training(_ w: CoachWindow, _ r: Range, _ ctx: ModelContext) -> [String] {
    let cal = Calendar.current
    let entries = fetchDated(ExerciseEntryEntity.self, r, ctx) { $0.date }
    let sessions = Set(entries.map(\.date)).count
    let priorFrom = dayString(cal.date(byAdding: .day, value: -21, to: r.startDay) ?? r.startDay)
    let priorTo = dayString(cal.date(byAdding: .day, value: -1, to: r.startDay) ?? r.startDay)
    let priorWeekly = Double(Set(fetchDated(ExerciseEntryEntity.self,
      Range(from: priorFrom, to: priorTo, startDay: r.startDay, endExclusive: r.endExclusive), ctx) { $0.date }.map(\.date)).count) / 3.0
    guard sessions > 0 || priorWeekly >= 0.5 else { return [] }
    let minutes = entries.compactMap(\.durationMin).reduce(0, +)
    var text = "Training: \(sessions) session\(sessions == 1 ? "" : "s") over \(w.days) days"
    if minutes > 0 { text += ", \(Int(minutes.rounded())) active min" }
    if priorWeekly >= 0.5 { text += " (vs ~\(oneDecimal(priorWeekly))/wk the 3 weeks before)" }
    return ["- \(text)"]
  }

  private static func nutrition(_ w: CoachWindow, _ r: Range, _ ctx: ModelContext) -> [String] {
    let meals = fetchNutrition(r, ctx).filter { $0.foods.lowercased() != "water" }
    guard !meals.isEmpty else { return [] }
    let dayKeys = Set(meals.map { dayString($0.loggedAt) })
    let days = max(1, dayKeys.count)
    let protein = meals.reduce(0.0) { $0 + $1.proteinG } / Double(days)
    let kcal = meals.reduce(0.0) { $0 + kcalOf($1) } / Double(days)
    let fiber = meals.reduce(0.0) { $0 + ($1.fiberG ?? 0) } / Double(days)
    var macro = "Nutrition: \(meals.count) meals across \(dayKeys.count)/\(w.days) days; "
    macro += "protein ~\(Int(protein.rounded()))g/day, energy ~\(Int(kcal.rounded())) kcal/day"
    if fiber > 0 { macro += ", fiber ~\(Int(fiber.rounded()))g/day" }
    return ["- \(macro)"]
  }

  private static func hydration(_ w: CoachWindow, _ r: Range, _ ctx: ModelContext) -> [String] {
    let withWater = fetchNutrition(r, ctx).filter { ($0.waterMl ?? 0) > 0 }
    guard !withWater.isEmpty else { return [] }
    let totalMl = withWater.reduce(0.0) { $0 + ($1.waterMl ?? 0) }
    let dayKeys = Set(withWater.map { dayString($0.loggedAt) })
    let perDay = totalMl / Double(w.days)
    return ["- Hydration: ~\(Int(perDay.rounded())) ml/day over \(dayKeys.count)/\(w.days) days logged"]
  }

  private static func sleep(_ w: CoachWindow, _ r: Range, _ ctx: ModelContext) -> [String] {
    let nights = fetchDated(OuraNightEntity.self, r, ctx) { $0.id }
    guard !nights.isEmpty else { return [] }
    let hours = nights.compactMap(\.totalH)
    let scores = nights.compactMap(\.sleepScore)
    var t = "Sleep: \(nights.count) nights over \(w.days) days"
    if !hours.isEmpty { t += ", avg \(oneDecimal(hours.reduce(0, +) / Double(hours.count)))h" }
    if !scores.isEmpty { t += ", avg score \(Int((Double(scores.reduce(0, +)) / Double(scores.count)).rounded()))" }
    return ["- \(t)"]
  }

  private static func mood(_ w: CoachWindow, _ r: Range, _ ctx: ModelContext) -> [String] {
    let mood = fetchDated(MoodEventEntity.self, r, ctx) { $0.date }
    guard !mood.isEmpty else { return [] }
    let days = Set(mood.map(\.date)).count
    let avgValence = Double(mood.reduce(0) { $0 + $1.valence }) / Double(mood.count)
    return ["- Mood: \(mood.count) check-ins over \(days)/\(w.days) days (avg valence \(oneDecimal(avgValence))/3, higher = more pleasant)"]
  }

  private static func body(_ w: CoachWindow, _ r: Range, _ ctx: ModelContext) -> [String] {
    let rows = fetchDated(WithingsRowEntity.self, r, ctx) { $0.id }.sorted { $0.id < $1.id }
    let weights = rows.compactMap { row in row.weightKg.map { (row.id, $0) } }
    guard !weights.isEmpty else { return [] }
    let first = weights.first!.1, last = weights.last!.1
    var t = "Body: \(weights.count) weigh-ins, latest \(oneDecimal(last))kg"
    if weights.count > 1 {
      let d = last - first
      t += " (\(d >= 0 ? "+" : "")\(oneDecimal(d))kg over window)"
    }
    if let fat = rows.compactMap(\.fatPct).last { t += ", body fat \(oneDecimal(fat))%" }
    return ["- \(t)"]
  }

  private static func gut(_ w: CoachWindow, _ r: Range, _ ctx: ModelContext) -> [String] {
    let gut = fetchDated(GutEventEntity.self, r, ctx) { $0.date }
    guard !gut.isEmpty else { return [] }
    let days = Set(gut.map(\.date)).count
    let avgBristol = Double(gut.reduce(0) { $0 + $1.bristol }) / Double(gut.count)
    let anyBlood = gut.contains { $0.blood != 0 }
    return ["- Gut: \(gut.count) entries over \(days)/\(w.days) days (avg Bristol \(oneDecimal(avgBristol)), \(anyBlood ? "blood noted" : "no blood"))"]
  }

  private static func tasks(_ r: Range, _ ctx: ModelContext) -> [String] {
    let completed = fetchCompletedTasks(r, ctx)
    guard !completed.isEmpty else { return [] }
    var lines = ["- Tasks: completed \(completed.count) (test entries excluded)"]
    let otherDirected = completed.filter(isOtherDirected).count
    if otherDirected > 0 { lines.append("- Tasks: \(otherDirected) other-directed (replies, follow-ups, messages)") }
    let financial = completed.filter { isFinancial($0.title) }.count
    if financial > 0 { lines.append("- Tasks: \(financial) financial duties (payments, invoices, tax)") }
    return lines
  }

  private static func chores(_ w: CoachWindow, _ r: Range, _ ctx: ModelContext) -> [String] {
    let chores = fetchDated(ChoreEventEntity.self, r, ctx) { $0.date }
      .filter { $0.action.lowercased().hasPrefix("complet") }
    guard !chores.isEmpty else { return [] }
    return ["- Chores: \(chores.count) completed over \(w.days) days"]
  }

  private static func caffeine(_ w: CoachWindow, _ r: Range, _ ctx: ModelContext) -> [String] {
    let caffeine = fetchDated(CaffeineEventEntity.self, r, ctx) { $0.date }
    guard !caffeine.isEmpty else { return [] }
    let days = Set(caffeine.map(\.date)).count
    let perDay = Double(caffeine.count) / Double(w.days)
    let late = caffeine.filter { (hour(of: EventTimestamp.hhmm(from: $0.occurredAt)) ?? 0) >= 16 }.count
    var text = "Caffeine: \(oneDecimal(perDay))/day, \(days)/\(w.days) days"
    text += late == 0 ? ", none after 16:00" : ", \(late) after 16:00"
    return ["- \(text)"]
  }

  private static func cannabis(_ w: CoachWindow, _ r: Range, _ ctx: ModelContext) -> [String] {
    let cannabis = fetchDated(CannabisEventEntity.self, r, ctx) { $0.date }
    guard !cannabis.isEmpty else { return [] }
    let days = Set(cannabis.map(\.date)).count
    let perDay = Double(cannabis.count) / Double(w.days)
    let hits = cannabis.reduce(0) { $0 + ($1.hit ?? 0) }
    return ["- Cannabis: \(oneDecimal(perDay))/day, \(days)/\(w.days) days, \(hits) hits"]
  }

  /// Definition-count × window-days vs. logged "done" days → adherence %.
  /// Shared by supplements and habits, which have the same shape.
  private static func adherence<Def: PersistentModel, State: PersistentModel>(
    _ defType: Def.Type, _ stateType: State.Type,
    label: String, taken: String, _ w: CoachWindow, _ r: Range, _ ctx: ModelContext,
    date: (State) -> String, done: (State) -> Bool
  ) -> [String] {
    let defs = (try? ctx.fetch(FetchDescriptor<Def>())) ?? []
    guard !defs.isEmpty else { return [] }
    let states = fetchDated(stateType, r, ctx, key: date).filter(done)
    let possible = defs.count * w.days
    guard possible > 0 else { return [] }
    let pct = Int((Double(states.count) / Double(possible) * 100).rounded())
    return ["- \(label): ~\(pct)% \(taken) over \(w.days) days (\(states.count)/\(possible))"]
  }

  // MARK: - Pill metadata

  private static func count(for key: String, _ r: Range, _ ctx: ModelContext) -> Int {
    switch key {
    case "training":    return fetchDated(ExerciseEntryEntity.self, r, ctx) { $0.date }.count
    case "nutrition":   return fetchNutrition(r, ctx).filter { $0.foods.lowercased() != "water" }.count
    case "hydration":   return fetchNutrition(r, ctx).filter { ($0.waterMl ?? 0) > 0 }.count
    case "sleep":       return fetchDated(OuraNightEntity.self, r, ctx) { $0.id }.count
    case "mood":        return fetchDated(MoodEventEntity.self, r, ctx) { $0.date }.count
    case "body":        return fetchDated(WithingsRowEntity.self, r, ctx) { $0.id }.count
    case "supplements": return fetchDated(SupplementDayStateEntity.self, r, ctx) { $0.date }.filter(\.done).count
    case "habits":      return fetchDated(HabitDayStateEntity.self, r, ctx) { $0.date }.filter(\.done).count
    case "gut":         return fetchDated(GutEventEntity.self, r, ctx) { $0.date }.count
    case "tasks":       return fetchCompletedTasks(r, ctx).count
    case "chores":      return fetchDated(ChoreEventEntity.self, r, ctx) { $0.date }.filter { $0.action.lowercased().hasPrefix("complet") }.count
    case "caffeine":    return fetchDated(CaffeineEventEntity.self, r, ctx) { $0.date }.count
    case "cannabis":    return fetchDated(CannabisEventEntity.self, r, ctx) { $0.date }.count
    default:            return 0
    }
  }

  private static func sectionLabel(_ key: String) -> String {
    switch key {
    case "training": return "Training"; case "nutrition": return "Nutrition"
    case "hydration": return "Hydration"; case "supplements": return "Supplements"
    case "sleep": return "Sleep"; case "mood": return "Mood"; case "body": return "Body"
    case "habits": return "Habits"; case "gut": return "Gut"
    case "tasks": return "Tasks"; case "chores": return "Chores"
    case "caffeine": return "Caffeine"; case "cannabis": return "Cannabis"
    default: return key.capitalized
    }
  }

  private static func icon(for key: String) -> String {
    switch key {
    case "training": return "figure.run"; case "nutrition": return "fork.knife"
    case "hydration": return "drop.fill"; case "supplements": return "pills.fill"
    case "sleep": return "bed.double"; case "mood": return "face.smiling"; case "body": return "scalemass"
    case "habits": return "repeat"; case "gut": return "stethoscope"
    case "tasks": return "checklist"; case "chores": return "house.fill"
    case "caffeine": return "cup.and.saucer.fill"; case "cannabis": return "leaf.fill"
    default: return "circle.fill"
    }
  }

  // MARK: - Fetch helpers

  /// Fetch all of a type, then keep rows whose date key falls in [from, to].
  /// yyyy-MM-dd sorts lexically == chronologically, so this is a true range.
  private static func fetchDated<T: PersistentModel>(
    _ type: T.Type, _ r: Range, _ ctx: ModelContext, key: (T) -> String
  ) -> [T] {
    let all = (try? ctx.fetch(FetchDescriptor<T>())) ?? []
    return all.filter { let d = key($0); return d >= r.from && d <= r.to }
  }

  private static func fetchNutrition(_ r: Range, _ ctx: ModelContext) -> [NutritionEntryEntity] {
    let start = r.startDay, end = r.endExclusive
    let descriptor = FetchDescriptor<NutritionEntryEntity>(
      predicate: #Predicate { $0.loggedAt >= start && $0.loggedAt < end }
    )
    return (try? ctx.fetch(descriptor)) ?? []
  }

  private static func fetchCompletedTasks(_ r: Range, _ ctx: ModelContext) -> [TaskEntity] {
    let descriptor = FetchDescriptor<TaskEntity>(
      predicate: #Predicate { $0.completedAt != nil && $0.deletedAt == nil && $0.pendingDeletion == false }
    )
    let all = (try? ctx.fetch(descriptor)) ?? []
    return all.filter { task in
      guard let completed = task.completedAt else { return false }
      let day = String(completed.prefix(10))
      return day >= r.from && day <= r.to && !isNoise(task.title)
    }
  }

  // MARK: - Classification heuristics (mirrors VirtueSummarizer's lens)

  private static func isNoise(_ title: String) -> Bool {
    let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if t.count < 4 { return true }
    if t.contains("test") { return true }
    if t.hasPrefix("new to-do") { return true }
    if !t.contains(" ") && t.rangeOfCharacter(from: CharacterSet(charactersIn: "aeiou")) == nil { return true }
    return false
  }

  private static func isOtherDirected(_ task: TaskEntity) -> Bool {
    if task.area?.lowercased() == "partnerships" { return true }
    let verbs = ["reply", "respond", "send", "follow", "share", "call",
                 "email", "message", "talk", "ping", "write", "invite", "thank"]
    let t = task.title.lowercased()
    return verbs.contains { t.contains($0) }
  }

  private static func isFinancial(_ title: String) -> Bool {
    let keys = ["pay", "invoice", "bill", "tax", "payment"]
    let t = title.lowercased()
    return keys.contains { t.contains($0) }
  }

  // MARK: - Small math/format helpers

  private static func kcalOf(_ e: NutritionEntryEntity) -> Double {
    e.kcal ?? (4 * e.proteinG + 9 * e.fatG + 4 * e.carbsG + 7 * (e.alcoholG ?? 0))
  }

  private static func hour(of time: String) -> Int? {
    Int(time.split(separator: ":").first ?? "")
  }

  private static func oneDecimal(_ value: Double) -> String { String(format: "%.1f", value) }

  private static let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()

  private static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }
}
