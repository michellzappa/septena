import Foundation
import SwiftData
import SwiftUI

// VirtueSummarizer — the "summarize + route" layer for the Examined Week
// mini app. This is the one capability the Ikigai / Values minis don't
// have: it reads the last 7 days of LOGGED data (from the local SwiftData
// mirror — no network, no gateway) and distills it into a tiny, citable
// evidence bundle per cardinal virtue.
//
// Design rule that makes this safe on a 3B on-device model: **Swift
// computes every fact here; the model only interprets.** We never hand
// raw events to the model — only pre-aggregated, pre-routed lines. The
// model can't miscount (it never counts) and can't cite a section that
// has no data (gaps are explicit).
//
// Routing (which signal feeds which virtue, and whether it reads as a
// strength or a strain) is the editable "lens" — see `route(...)` below.
// v1 hard-codes the four cardinal virtues; a future version swaps the
// lens for a Stoic / examen / user-defined frame.

// MARK: - Vocabulary

enum Virtue: String, CaseIterable, Identifiable {
  case temperance, wisdom, courage, justice

  var id: String { rawValue }
  var title: String {
    switch self {
    case .temperance: return String(localized: "Temperance", comment: "Cardinal virtue")
    case .wisdom:     return String(localized: "Wisdom", comment: "Cardinal virtue")
    case .courage:    return String(localized: "Courage", comment: "Cardinal virtue")
    case .justice:    return String(localized: "Justice", comment: "Cardinal virtue")
    }
  }

  var gloss: String {
    switch self {
    case .temperance: return String(localized: "Moderation & self-governance", comment: "Virtue gloss")
    case .wisdom:     return String(localized: "Judgment & foresight", comment: "Virtue gloss")
    case .courage:    return String(localized: "Doing the hard thing", comment: "Virtue gloss")
    case .justice:    return String(localized: "Duty to others", comment: "Virtue gloss")
    }
  }

  var systemImage: String {
    switch self {
    case .temperance: return "circle.lefthalf.filled"
    case .wisdom:     return "brain.head.profile"
    case .courage:    return "flame.fill"
    case .justice:    return "building.columns.fill"
    }
  }
}

/// Whether a single computed fact reads as a strength, a strain, or is
/// purely informational. The per-virtue status is derived from the mix.
enum Valence { case good, strain, neutral }

/// One pre-computed, citable fact routed to a virtue.
struct VirtueSignal: Hashable {
  let text: String
  let valence: Valence
}

enum VirtueStatus: String {
  case steady, mixed, strained, unknown

  var label: String {
    switch self {
    case .steady:   return String(localized: "Steady", comment: "Virtue status")
    case .mixed:    return String(localized: "Mixed", comment: "Virtue status")
    case .strained: return String(localized: "Strained", comment: "Virtue status")
    case .unknown:  return String(localized: "No data", comment: "Virtue status")
    }
  }

  var color: Color {
    switch self {
    case .steady:   return .green
    case .mixed:    return .orange
    case .strained: return .red
    case .unknown:  return .secondary
    }
  }
}

/// The evidence bundle for one virtue: the routed facts plus a derived
/// status. `hasData` is false when no real section fed this virtue (the
/// Justice blind-spot line alone doesn't count as data).
struct VirtueEvidence: Identifiable {
  let virtue: Virtue
  let signals: [VirtueSignal]
  let hasData: Bool

  var id: String { virtue.rawValue }

  var status: VirtueStatus {
    guard hasData else { return .unknown }
    let hasStrain = signals.contains { $0.valence == .strain }
    let hasGood   = signals.contains { $0.valence == .good }
    switch (hasGood, hasStrain) {
    case (true, true):   return .mixed
    case (false, true):  return .strained
    case (true, false):  return .steady
    case (false, false): return .steady   // only-informational → nothing concerning
    }
  }
}

/// The whole-week summary. `evidence` always holds all four virtues in
/// canonical order. `promptText` is the compact, faithful blob handed to
/// the on-device model.
struct VirtueWeekSummary {
  let rangeLabel: String
  let fromStr: String
  let toStr: String
  let evidence: [VirtueEvidence]
  let sectionsWithData: [String]
  let sectionsMissing: [String]

  func bundle(for virtue: Virtue) -> VirtueEvidence {
    evidence.first { $0.virtue == virtue } ?? VirtueEvidence(virtue: virtue, signals: [], hasData: false)
  }

  /// The model input. ~200–400 tokens: four short bundles of facts. The
  /// status hint is included so the model has a baseline it may override.
  var promptText: String {
    var out = "WEEK \(rangeLabel) (trailing 7 days).\n"
    out += "Sections with data: \(sectionsWithData.isEmpty ? "none" : sectionsWithData.joined(separator: ", ")).\n"
    if !sectionsMissing.isEmpty {
      out += "No data this run: \(sectionsMissing.joined(separator: ", ")).\n"
    }
    for virtue in Virtue.allCases {
      let ev = bundle(for: virtue)
      out += "\n\(virtue.title.uppercased()) [hint: \(ev.status.rawValue)]\n"
      if ev.signals.isEmpty {
        out += "· (no logged signal)\n"
      } else {
        for s in ev.signals { out += "· \(s.text)\n" }
      }
    }
    return out
  }
}

// MARK: - Summarizer

@MainActor
enum VirtueSummarizer {
  /// Read the trailing-7-day window from the local store and route it
  /// into per-virtue evidence. Pure read — never mutates.
  static func summarize(context: ModelContext, now: Date = Date()) -> VirtueWeekSummary {
    let cal = Calendar.current
    let today = cal.startOfDay(for: now)
    let startDay = cal.date(byAdding: .day, value: -6, to: today) ?? today
    let endExclusive = cal.date(byAdding: .day, value: 1, to: today) ?? today
    let fromStr = dayString(startDay)
    let toStr = dayString(today)

    var buckets: [Virtue: [VirtueSignal]] = [:]
    var populated: Set<Virtue> = []
    var sections: Set<String> = []

    func add(_ virtue: Virtue, _ text: String, _ valence: Valence, section: String?) {
      buckets[virtue, default: []].append(VirtueSignal(text: text, valence: valence))
      populated.insert(virtue)
      if let section { sections.insert(section) }
    }

    // ── Intake → Temperance (consumption self-governance) ──────────
    // One signal per active tracker. Valence keys off the user's own
    // objective: trackers they've set to limit/reduce/quit read as strain
    // when used most days; plain logs stay neutral (the generic successor
    // to the old caffeine/cannabis heuristics).
    let intakeKinds = fetchAll(IntakeKindEntity.self, context).filter { $0.archivedAt == nil }
    if !intakeKinds.isEmpty {
      let byKind = Dictionary(grouping: fetchByDate(IntakeEventEntity.self, fromStr, toStr, context),
                              by: \.kindID)
      for k in intakeKinds.sorted(by: { $0.sortIndex < $1.sortIndex }) {
        let evs = byKind[k.id] ?? []
        guard !evs.isEmpty else { continue }
        let days = Set(evs.map(\.date)).count
        let perDay = Double(evs.count) / 7.0
        var text = "\(k.name) \(oneDecimal(perDay))/day, \(days)/7 days"
        if k.metricMode == "sumAmount", let unit = k.unit {
          let total = evs.compactMap(\.amount).reduce(0, +)
          if total > 0 { text += ", \(oneDecimal(total))\(unit)" }
        }
        let reducing = ["limit", "reduce", "quit"].contains(k.objective)
        let valence: Valence = reducing ? (days >= 5 ? .strain : .neutral) : .neutral
        add(.temperance, text, valence, section: "intake")
      }
    }

    // ── Habits → Temperance (self-governance / ordered routine) ─────
    let habitDefs = fetchAll(HabitDefinitionEntity.self, context)
    if !habitDefs.isEmpty {
      let done = fetchByDate(HabitDayStateEntity.self, fromStr, toStr, context).filter(\.done).count
      let possible = habitDefs.count * 7
      if possible > 0 {
        let pct = Int((Double(done) / Double(possible) * 100).rounded())
        let valence: Valence = pct >= 70 ? .good : (pct >= 40 ? .neutral : .strain)
        add(.temperance, "Habits ~\(pct)% adherence (\(done)/\(possible) over 7 days)", valence, section: "habits")
      }
    }

    // ── Nutrition → Wisdom (self-knowledge) + light Temperance ──────
    let meals = fetchNutrition(startDay, endExclusive, context)
      .filter { $0.foods.lowercased() != "water" }
    if !meals.isEmpty {
      let dayKeys = Set(meals.map { dayString($0.loggedAt) })
      let daysWithFood = max(1, dayKeys.count)
      let protein = meals.reduce(0.0) { $0 + $1.proteinG } / Double(daysWithFood)
      let kcal = meals.reduce(0.0) { $0 + kcalOf($1) } / Double(daysWithFood)
      let fiber = meals.reduce(0.0) { $0 + ($1.fiberG ?? 0) } / Double(daysWithFood)
      add(.wisdom, "Logged \(meals.count) meals across \(dayKeys.count)/7 days", .good, section: "nutrition")
      var macroLine = "Protein ~\(Int(protein.rounded()))g/day, energy ~\(Int(kcal.rounded())) kcal/day"
      if fiber > 0 { macroLine += ", fiber ~\(Int(fiber.rounded()))g" }
      add(.wisdom, macroLine, .neutral, section: nil)
    }

    // ── Supplements → Wisdom (caring for the future self) ───────────
    let suppDefs = fetchAll(SupplementDefinitionEntity.self, context)
    if !suppDefs.isEmpty {
      let done = fetchByDate(SupplementDayStateEntity.self, fromStr, toStr, context).filter(\.done).count
      let possible = suppDefs.count * 7
      if possible > 0 {
        let pct = Int((Double(done) / Double(possible) * 100).rounded())
        add(.wisdom, "Supplements ~\(pct)% taken over 7 days", pct >= 60 ? .good : .neutral, section: "supplements")
      }
    }

    // ── Gut → Wisdom (bodily attentiveness) ─────────────────────────
    let gut = fetchByDate(GutEventEntity.self, fromStr, toStr, context)
    if !gut.isEmpty {
      let days = Set(gut.map(\.date)).count
      let avgBristol = Double(gut.reduce(0) { $0 + $1.bristol }) / Double(gut.count)
      let text = "Gut tracked \(gut.count)× over \(days)/7 days (avg Bristol \(oneDecimal(avgBristol)))"
      add(.wisdom, text, .good, section: "gut")
    }

    // ── Training → Courage (the body / discomfort) ──────────────────
    let training = fetchByDate(ExerciseEntryEntity.self, fromStr, toStr, context)
    let sessions = Set(training.map(\.date)).count
    let priorFrom = dayString(cal.date(byAdding: .day, value: -21, to: startDay) ?? startDay)
    let priorTo = dayString(cal.date(byAdding: .day, value: -1, to: startDay) ?? startDay)
    let priorWeekly = Double(Set(fetchByDate(ExerciseEntryEntity.self, priorFrom, priorTo, context).map(\.date)).count) / 3.0
    if sessions > 0 || priorWeekly >= 0.5 {
      let minutes = training.compactMap(\.durationMin).reduce(0, +)
      var text = String(localized: "Training \(sessions) sessions this week")
      if minutes > 0 { text += ", \(Int(minutes.rounded())) active min" }
      if priorWeekly >= 0.5 { text += " (vs ~\(oneDecimal(priorWeekly))/wk the prior 3 weeks)" }
      let valence: Valence = (sessions == 0 && priorWeekly >= 1) ? .strain : (sessions >= 2 ? .good : .neutral)
      add(.courage, text, valence, section: "training")
    }

    // ── Tasks → Justice (duty to others) + Courage/Wisdom ───────────
    let completed = fetchCompletedTasks(fromStr, toStr, context)
    if !completed.isEmpty {
      let otherDirected = completed.filter(isOtherDirected).count
      let financial = completed.filter { isFinancial($0.title) }.count
      let obligations = completed.filter { $0.due != nil || isFinancial($0.title) }.count
      add(.wisdom, "Completed \(completed.count) real tasks this week (test entries excluded)", .good, section: "tasks")
      if otherDirected > 0 {
        add(.justice, "\(otherDirected) other-directed commitments done (replies, follow-ups, messages)", .good, section: "tasks")
      }
      if financial > 0 {
        add(.justice, "\(financial) financial duties handled (payments, invoices, tax)", .good, section: "tasks")
      }
      if obligations > 0 {
        add(.courage, "Cleared \(obligations) deadline / obligation tasks", .good, section: "tasks")
      }
    }

    // ── Chores → Justice (shared household duty) ────────────────────
    let chores = fetchByDate(ChoreEventEntity.self, fromStr, toStr, context)
      .filter { $0.action.lowercased().hasPrefix("complet") }
    if !chores.isEmpty {
      add(.justice, "\(chores.count) chores completed", .good, section: "chores")
    }

    // Wisdom: the breadth of self-tracking is itself applied self-knowledge.
    if !sections.isEmpty {
      add(.wisdom, "Tracked \(sections.count) areas of life this week", .good, section: nil)
    }

    // Justice always carries its blind-spot line — informational, never
    // a data signal on its own.
    buckets[.justice, default: []].append(
      VirtueSignal(text: "Most of how you treat others happens off-log, so this view sees only what's tracked.",
                   valence: .neutral)
    )

    let evidence = Virtue.allCases.map { virtue in
      VirtueEvidence(virtue: virtue,
                     signals: buckets[virtue] ?? [],
                     hasData: populated.contains(virtue))
    }

    let allSupported = ["intake", "habits", "nutrition", "supplements",
                        "gut", "training", "tasks", "chores"]
    let missing = allSupported.filter { !sections.contains($0) }

    return VirtueWeekSummary(
      rangeLabel: "\(fromStr) → \(toStr)",
      fromStr: fromStr,
      toStr: toStr,
      evidence: evidence,
      sectionsWithData: allSupported.filter { sections.contains($0) },
      sectionsMissing: missing
    )
  }

  // MARK: - Fetch helpers

  private static func fetchByDate<T>(_ type: T.Type, _ from: String, _ to: String,
                                     _ context: ModelContext) -> [T] where T: PersistentModel {
    // Every event entity in this set exposes a `date` String column
    // ("YYYY-MM-DD"), so a lexical range is a true calendar range.
    let descriptor = FetchDescriptor<T>()
    let all = (try? context.fetch(descriptor)) ?? []
    return all.filter { model in
      guard let date = (model as? any DateStringed)?.dateKey else { return false }
      return date >= from && date <= to
    }
  }

  private static func fetchAll<T>(_ type: T.Type, _ context: ModelContext) -> [T] where T: PersistentModel {
    (try? context.fetch(FetchDescriptor<T>())) ?? []
  }

  private static func fetchNutrition(_ start: Date, _ endExclusive: Date,
                                     _ context: ModelContext) -> [NutritionEntryEntity] {
    let descriptor = FetchDescriptor<NutritionEntryEntity>(
      predicate: #Predicate { $0.loggedAt >= start && $0.loggedAt < endExclusive }
    )
    return (try? context.fetch(descriptor)) ?? []
  }

  private static func fetchCompletedTasks(_ from: String, _ to: String,
                                          _ context: ModelContext) -> [TaskEntity] {
    let descriptor = FetchDescriptor<TaskEntity>(
      predicate: #Predicate { $0.completedAt != nil && $0.deletedAt == nil && $0.pendingDeletion == false }
    )
    let all = (try? context.fetch(descriptor)) ?? []
    return all.filter { task in
      guard let completed = task.completedAt else { return false }
      let day = String(completed.prefix(10))
      return day >= from && day <= to && !isNoise(task.title)
    }
  }

  // MARK: - Classification heuristics (v1 — part of the editable lens)

  private static func isNoise(_ title: String) -> Bool {
    let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if t.count < 4 { return true }
    if t.contains("test") { return true }
    if t.hasPrefix("new to-do") { return true }
    // Keyboard-mash entries from dogfooding: no vowels and no spaces.
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
    let keys = ["pay", "invoice", "bill", "tax", "payment", "nubank", "revolut", "€", "ir 20"]
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

  private static func oneDecimal(_ value: Double) -> String {
    String(format: "%.1f", value)
  }

  private static let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()

  private static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }
}

// Lets the generic `fetchByDate` read the `date` column off any event
// entity without a per-type switch. Conformances are declared here so
// adding a new event type to the summary is a one-line extension.
private protocol DateStringed { var dateKey: String { get } }
extension IntakeEventEntity: DateStringed { var dateKey: String { date } }
extension GutEventEntity: DateStringed { var dateKey: String { date } }
extension ExerciseEntryEntity: DateStringed { var dateKey: String { date } }
extension ChoreEventEntity: DateStringed { var dateKey: String { date } }
extension HabitDayStateEntity: DateStringed { var dateKey: String { date } }
extension SupplementDayStateEntity: DateStringed { var dateKey: String { date } }
