import Foundation
import SwiftData

/// How far back the coach reads. Trailing window measured in weeks, where
/// "1 week" == today + the previous 6 days (the app's standard trailing-7
/// convention), so `daysBack` is `days - 1`.
enum CoachWindow: Int, CaseIterable, Identifiable {
  case week = 1, twoWeeks = 2, fourWeeks = 4, eightWeeks = 8, thirteenWeeks = 13

  var id: Int { rawValue }
  var weeks: Int { rawValue }
  var days: Int { rawValue * 7 }
  var daysBack: Int { days - 1 }
  var label: String {
    switch self {
    case .week:          return "1 week"
    case .thirteenWeeks: return "90 days"
    default:             return "\(weeks) weeks"
    }
  }
  var shortLabel: String { self == .thirteenWeeks ? "90d" : "\(weeks)w" }

  /// The window coaches open on and read their availability badges from.
  static let `default`: CoachWindow = .thirteenWeeks
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
                              "habits", "intake"]

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

    // RECORDS — the raw logged entries behind the FACTS, so a capable model
    // can reason over detail the summary throws away (per-session sets,
    // time-of-day, sequence). Most-recent-first, capped per section.
    var recordBlocks: [String] = []
    for key in keys {
      if let block = recordBlock(for: key, r, context) { recordBlocks.append(block) }
    }
    if !recordBlocks.isEmpty {
      blocks.append("RECORDS — raw logged entries behind the FACTS above (most recent first):\n\n"
                    + recordBlocks.joined(separator: "\n\n"))
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
    var s: String
    if p.isRange, let upper = p.targetUpper {
      s = "\(num(p.current)), aiming \(num(p.target))–\(num(upper)) \(p.unitLabel)"
    } else {
      let cmp = p.comparator == "lte" ? "≤" : (p.comparator == "eq" ? "=" : "≥")
      s = "\(num(p.current)) / \(cmp) \(num(p.target)) \(p.unitLabel)"
    }
    if p.hit { s += " (met)" }
    return s
  }

  private static func num(_ v: Double) -> String {
    v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
  }

  // MARK: - Records (raw entries behind the summary)

  /// Max rows per section, with explicit "older omitted" disclosure (no
  /// silent truncation). Tuning knob for the context/token budget.
  private static let recordCap = 50

  private static func recordBlock(for key: String, _ r: Range, _ ctx: ModelContext) -> String? {
    let (label, rows) = rawRecords(for: key, r, ctx)
    guard !rows.isEmpty else { return nil }
    var head = "### \(label) — \(rows.count) record\(rows.count == 1 ? "" : "s")"
    if rows.count > recordCap { head += " (showing latest \(recordCap); \(rows.count - recordCap) older omitted)" }
    return head + "\n" + rows.prefix(recordCap).joined(separator: "\n")
  }

  private static func rawRecords(for key: String, _ r: Range, _ ctx: ModelContext) -> (String, [String]) {
    switch key {
    case "training":  return ("Training", trainingRecords(r, ctx))
    case "nutrition": return ("Nutrition", nutritionRecords(r, ctx))
    case "intake":    return ("Intake", intakeRecords(r, ctx))
    case "gut":       return ("Gut", gutRecords(r, ctx))
    case "mood":      return ("Mood", moodRecords(r, ctx))
    case "sleep":     return ("Sleep", sleepRecords(r, ctx))
    case "body":      return ("Body", bodyRecords(r, ctx))
    case "tasks":     return ("Tasks completed", taskRecords(r, ctx))
    default:          return ("", [])   // chores/habits/supplements/hydration stay aggregate-only
    }
  }

  private static func trainingRecords(_ r: Range, _ ctx: ModelContext) -> [String] {
    fetchDated(ExerciseEntryEntity.self, r, ctx) { $0.date }
      .sorted { $0.occurredAt > $1.occurredAt }
      .map { x in
        var s = "\(stamp(x.date, x.occurredAt)) · \(x.sessionType) · \(x.exercise)"
        if let w = x.weight { s += " · \(num(w))kg" }
        if x.sets != nil || x.reps != nil { s += " · \(x.sets ?? "?")×\(x.reps ?? "?")" }
        if let d = x.durationMin, d > 0 { s += " · \(Int(d.rounded()))min" }
        if let dist = x.distanceM, dist > 0 { s += " · \(num(dist / 1000))km" }
        if let diff = x.difficulty, !diff.isEmpty { s += " · \(diff)" }
        if let n = x.note, !n.isEmpty { s += " — \(n)" }
        return s
      }
  }

  private static func nutritionRecords(_ r: Range, _ ctx: ModelContext) -> [String] {
    fetchNutrition(r, ctx).filter { $0.foods.lowercased() != "water" }
      .sorted { $0.loggedAt > $1.loggedAt }
      .map { f in
        let foods = f.foods.replacingOccurrences(of: "\n", with: ", ")
        var s = "\(stamp(dayString(f.loggedAt), f.loggedAt)) · \(f.mealType ?? "meal") · \(foods)"
        s += " · \(Int(kcalOf(f).rounded()))kcal \(Int(f.proteinG.rounded()))P/\(Int(f.fatG.rounded()))F/\(Int(f.carbsG.rounded()))C"
        if let fib = f.fiberG, fib > 0 { s += " fiber \(Int(fib.rounded()))g" }
        if let n = f.note, !n.isEmpty { s += " — \(n)" }
        return s
      }
  }

  private static func intakeRecords(_ r: Range, _ ctx: ModelContext) -> [String] {
    let kindName = Dictionary(uniqueKeysWithValues:
      ((try? ctx.fetch(FetchDescriptor<IntakeKindEntity>())) ?? []).map { ($0.id, $0.name) })
    return fetchDated(IntakeEventEntity.self, r, ctx) { $0.date }
      .sorted { $0.occurredAt > $1.occurredAt }
      .map { x in
        var s = "\(stamp(x.date, x.occurredAt)) · \(kindName[x.kindID] ?? "intake") · \(x.method)"
        if let a = x.amount { s += " · \(num(a))" }
        if let c = x.count { s += " · \(c)" }
        if let n = x.note, !n.isEmpty { s += " — \(n)" }
        return s
      }
  }

  private static func gutRecords(_ r: Range, _ ctx: ModelContext) -> [String] {
    fetchDated(GutEventEntity.self, r, ctx) { $0.date }
      .sorted { $0.occurredAt > $1.occurredAt }
      .map { x in
        var s = "\(stamp(x.date, x.occurredAt)) · Bristol \(x.bristol)"
        if let v = x.volume, !v.isEmpty { s += " · \(v)" }
        if let n = x.note, !n.isEmpty { s += " — \(n)" }
        return s
      }
  }

  private static func moodRecords(_ r: Range, _ ctx: ModelContext) -> [String] {
    fetchDated(MoodEventEntity.self, r, ctx) { $0.date }
      .sorted { $0.occurredAt > $1.occurredAt }
      .map { x in
        var s = "\(stamp(x.date, x.occurredAt)) · \(x.bucket) · \(x.emotion) (valence \(x.valence)/3, arousal \(x.arousal)/3)"
        if let n = x.note, !n.isEmpty { s += " — \(n)" }
        return s
      }
  }

  private static func sleepRecords(_ r: Range, _ ctx: ModelContext) -> [String] {
    fetchDated(OuraNightEntity.self, r, ctx) { $0.id }
      .sorted { $0.id > $1.id }
      .map { x in
        var parts = [x.id]
        if let h = x.totalH { parts.append("\(oneDecimal(h))h") }
        if let sc = x.sleepScore { parts.append("score \(sc)") }
        if let d = x.deepH { parts.append("deep \(oneDecimal(d))h") }
        if let rem = x.remH { parts.append("rem \(oneDecimal(rem))h") }
        if let e = x.efficiency { parts.append("eff \(e)%") }
        if let hrv = x.hrv { parts.append("hrv \(hrv)") }
        return parts.joined(separator: " · ")
      }
  }

  private static func bodyRecords(_ r: Range, _ ctx: ModelContext) -> [String] {
    fetchDated(WithingsRowEntity.self, r, ctx) { $0.id }
      .sorted { $0.id > $1.id }
      .map { x in
        var parts = [x.id]
        if let w = x.weightKg { parts.append("\(oneDecimal(w))kg") }
        if let f = x.fatPct { parts.append("\(oneDecimal(f))% fat") }
        if let m = x.muscleMassKg { parts.append("muscle \(oneDecimal(m))kg") }
        return parts.joined(separator: " · ")
      }
  }

  private static func taskRecords(_ r: Range, _ ctx: ModelContext) -> [String] {
    fetchCompletedTasks(r, ctx)
      .sorted { ($0.completedAt ?? "") > ($1.completedAt ?? "") }
      .map { t in
        var s = "\(String((t.completedAt ?? "").prefix(10))) · \(t.title)"
        var tags: [String] = []
        if let a = t.area, !a.isEmpty { tags.append(a) }
        if let p = t.project, !p.isEmpty { tags.append(p) }
        if !tags.isEmpty { s += " [\(tags.joined(separator: "/"))]" }
        return s
      }
  }

  private static func stamp(_ day: String, _ at: Date) -> String {
    if let t = hm(at) { return "\(day) \(t)" }
    return day
  }

  private static func hm(_ date: Date) -> String? {
    date == Date.distantPast ? nil : timeFormatter.string(from: date)
  }

  private static let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()

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
      // Label + icon come from the canonical manifest, not a local switch —
      // one source of truth for section identity (and complete for every key).
      let m = SectionManifest.byKey[key]
      return CoachDataPill(id: key,
                           label: m?.defaultLabel ?? key.capitalized,
                           systemImage: m?.iconSymbol ?? "circle.fill",
                           count: n)
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
    case "intake":      return intake(w, r, ctx)
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
    return ["- Gut: \(gut.count) entries over \(days)/\(w.days) days (avg Bristol \(oneDecimal(avgBristol)))"]
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

  /// One line per active intake tracker — the generic successor to the old
  /// per-substance consumable facts. Each kind's name comes from user
  /// data, so the coach reasons about "Matcha" or "Nicotine" with no edit.
  private static func intake(_ w: CoachWindow, _ r: Range, _ ctx: ModelContext) -> [String] {
    let kinds = ((try? ctx.fetch(FetchDescriptor<IntakeKindEntity>())) ?? [])
      .filter { $0.archivedAt == nil }
      .sorted { $0.sortIndex < $1.sortIndex }
    guard !kinds.isEmpty else { return [] }
    let byKind = Dictionary(grouping: fetchDated(IntakeEventEntity.self, r, ctx) { $0.date },
                            by: \.kindID)
    return kinds.compactMap { k -> String? in
      let evs = byKind[k.id] ?? []
      guard !evs.isEmpty else { return nil }
      let days = Set(evs.map(\.date)).count
      let perDay = Double(evs.count) / Double(w.days)
      var line = "\(k.name): \(oneDecimal(perDay))/day, \(days)/\(w.days) days"
      if k.metricMode == "sumAmount", let unit = k.unit {
        let total = evs.compactMap(\.amount).reduce(0, +)
        if total > 0 { line += ", \(oneDecimal(total))\(unit) total" }
      }
      return "- \(line)"
    }
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
    case "intake":      return fetchDated(IntakeEventEntity.self, r, ctx) { $0.date }.count
    default:            return 0
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
