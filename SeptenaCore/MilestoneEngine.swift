import Foundation
import SwiftData

// MilestoneEngine — turns continuously-true goal/training/habit state into
// discrete, latched GoalMilestoneEntity rows. See docs/GOAL_MILESTONES_PLAN.md.
//
// Three detector shapes, and only three:
//   • smoothed-level rungs — trailing-7-day mean of a noisy body metric
//     crossing a ladder derived from ONE goal (per-unit rungs, halfway,
//     target, held-30-days)
//   • monotonic max / cumulative XP — training PRs per exercise and lifetime
//     volume rungs with widening spacing
//   • adherence streaks — habit streak rungs at 7/30/50/100/365
//
// Idempotency is carried entirely by the deterministic milestone id
// ("<scope>|<rungKey>"): any device, any number of passes, any data rewrite
// produces the same id, so insert-if-absent can never duplicate a milestone.
//
// Grandfathering: the FIRST pass for a scope grants every currently-qualified
// rung silently (celebrated == false) and writes an "init" sentinel row so the
// scope is permanently marked as initialized — without the sentinel, a scope
// whose first pass grants nothing would look like a first pass forever.
// Only rungs that appear on a later pass celebrate.
//
// Time discipline: the engine never reads Date() / SeptenaDate.today — trigger
// sites pass DayClock.now / DayClock.today in, which is what keeps detection
// inert under time travel.

/// A milestone written by the current pass that should celebrate now.
/// Lightweight value type so presentation code doesn't hold @Model references.
public struct MilestoneGrant: Identifiable, Equatable {
  public let id: String        // entity id, "<scope>|<rungKey>"
  public let goalID: String?
  public let scope: String
  public let kind: String      // "rung" | "pr" | "xp" | "streak"
  public let rungKey: String
  public let label: String
  public let value: Double
}

@MainActor
@Observable
final class MilestoneMutator {
  private let context: ModelContext
  private var ckEngine: CKEngine?

  init(context: ModelContext, ckEngine: CKEngine? = nil) {
    self.context = context
    self.ckEngine = ckEngine
  }

  func bind(ckEngine: CKEngine) {
    self.ckEngine = ckEngine
  }

  // MARK: - Detector 1: smoothed-level rungs (body-metric goals)

  /// Streak ladder shared by every adherence scope.
  static let streakLadder = [7, 30, 50, 100, 365]
  /// Lifetime-volume rungs in kg, widening (10t, 25t, 50t, …) so cadence
  /// stays roughly constant as training volume compounds.
  static let xpLadderKg: [Double] = [10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000]
    .map { $0 * 1000 }
  /// A trailing-7-day mean needs at least this many readings before it
  /// counts as a trend — one weigh-in after a gap is not a crossing.
  static let minSmoothedReadings = 3

  /// Evaluate every active body-metric goal. Run on Withings ingest and on
  /// goal-metric edits. Returns the milestones that should celebrate (always
  /// queued — Withings lands in the background, nobody is watching).
  @discardableResult
  func evaluateBodyGoals(now: Date, today: String) -> [MilestoneGrant] {
    let goals = ((try? context.fetch(FetchDescriptor<GoalEntity>())) ?? [])
      .filter { ($0.metricKey ?? "").hasPrefix("body.")
        && $0.metricTarget != nil && $0.metricComparator != nil }
    guard !goals.isEmpty else { return [] }

    var celebrated: [MilestoneGrant] = []
    for goal in goals {
      guard let key = goal.metricKey,
            let target = goal.metricTarget,
            let comparator = goal.metricComparator,
            let smoothed = smoothedValue(metricKey: key, endingOn: today) else { continue }

      let unit = key.hasSuffix("pct") ? "%" : "kg"
      let step = key.hasSuffix("pct") ? 0.5 : 1.0
      // Direction of progress: explicit from baseline when present, else from
      // the comparator (lte = pushing down, gte = pushing up).
      let downward = goal.metricBaseline.map { $0 > target } ?? (comparator == "lte")

      var rungs: [(key: String, kind: String, label: String, value: Double)] = []

      // Per-unit grid rungs + halfway need a baseline to anchor the ladder.
      if let baseline = goal.metricBaseline {
        for grid in gridValues(baseline: baseline, target: target, step: step, downward: downward) {
          let qualified = downward ? smoothed <= grid : smoothed >= grid
          guard qualified else { continue }
          rungs.append((key: "lvl:\(trim(grid))", kind: "rung",
                        label: "Trailing average crossed \(trim(grid)) \(unit)",
                        value: grid))
        }
        let halfway = (baseline + target) / 2
        if downward ? smoothed <= halfway : smoothed >= halfway {
          rungs.append((key: "halfway", kind: "rung",
                        label: "Halfway to \(trim(target)) \(unit)",
                        value: halfway))
        }
      }

      let onTarget = onTargetSide(smoothed, target: target,
                                  upper: goal.metricTargetUpper,
                                  comparator: comparator, step: step,
                                  downward: downward)
      if onTarget {
        rungs.append((key: "target", kind: "rung",
                      label: "Target reached: \(trim(target)) \(unit)",
                      value: target))
        if heldTargetForThirtyDays(goal: goal, metricKey: key, today: today,
                                   step: step, downward: downward) {
          rungs.append((key: "held30", kind: "rung",
                        label: "Held \(trim(target)) \(unit) for 30 days",
                        value: target))
        }
      }

      celebrated += grantPass(scope: "goal:\(goal.id)", goalID: goal.id,
                              qualified: rungs, celebrateTop: true, now: now)
    }
    return celebrated
  }

  // MARK: - Detector 2: training PR + XP

  /// Evaluate training PRs (per strength exercise) and the lifetime-volume XP
  /// ladder. Run after a training log commit; pass the logged exercise so the
  /// PR scan stays narrow (nil = all exercises, used by the first/grandfather
  /// pass and reconciles). `celebrate: false` = reconcile mode: rungs are
  /// granted but never queued for celebration (CK-synced history from another
  /// device must not read as a live crossing).
  @discardableResult
  func evaluateTraining(now: Date, exercise: String? = nil,
                        celebrate: Bool = true) -> [MilestoneGrant] {
    let entries = (try? context.fetch(FetchDescriptor<ExerciseEntryEntity>())) ?? []
    guard !entries.isEmpty else { return [] }
    var celebrated: [MilestoneGrant] = []

    // XP — lifetime volume across all entries with numeric weight×sets×reps.
    // AMRAP / missing components contribute nothing (documented in the plan).
    let totalKg = entries.reduce(0.0) { sum, e in
      guard let w = e.weight, w > 0,
            let sets = e.sets.flatMap(Int.init),
            let reps = e.reps.flatMap(Int.init) else { return sum }
      return sum + w * Double(sets) * Double(reps)
    }
    let xpRungs = Self.xpLadderKg.filter { totalKg >= $0 }.map { kg in
      (key: "xp:\(trim(kg / 1000))t", kind: "xp",
       label: "Lifetime volume: \(trim(kg / 1000)) tonnes", value: kg)
    }
    celebrated += grantPass(scope: "training.volume", goalID: nil,
                            qualified: xpRungs, celebrateTop: celebrate, now: now)

    // PR — max single weight per strength exercise. Monotonic, so the ladder
    // is just the current max; old PR rows stay behind as history.
    let strengthNames = Set(((try? context.fetch(FetchDescriptor<ExerciseDefinitionEntity>())) ?? [])
      .filter { $0.type == "strength" && !$0.archived }
      .map(\.name))
    let byExercise = Dictionary(grouping: entries.filter { strengthNames.contains($0.exercise) },
                                by: \.exercise)
    for (name, group) in byExercise {
      if let exercise, name != exercise { continue }
      guard let maxWeight = group.compactMap(\.weight).max(), maxWeight > 0 else { continue }
      // The first few logs of a movement are a baseline, not a record: with
      // fewer than 4 entries the rung is still granted (history stays honest)
      // but never celebrated.
      let enoughHistory = group.count >= 4
      let rung = [(key: "pr:\(trim(maxWeight))", kind: "pr",
                   label: "\(name) PR: \(trim(maxWeight)) kg", value: maxWeight)]
      celebrated += grantPass(scope: "exercise:\(slug(name))", goalID: nil,
                              qualified: rung, celebrateTop: enoughHistory && celebrate, now: now)
    }
    return celebrated
  }

  // MARK: - Detector 3: habit adherence streaks

  /// Evaluate one habit's streak ladder. Run after a habit toggle commit.
  /// `celebrate: false` for backfills and reconciles — grants land, history
  /// stays honest, nothing animates.
  @discardableResult
  func evaluateHabitStreak(habitID: String, now: Date, today: String,
                           celebrate: Bool = true) -> [MilestoneGrant] {
    guard let def = ((try? context.fetch(FetchDescriptor<HabitDefinitionEntity>(
      predicate: #Predicate { $0.id == habitID }
    ))) ?? []).first else { return [] }

    let dates = ChecklistMirror.habitCompletionDates(context: context, habitID: habitID)
    let stats = ConsistencyStats.make(dates: dates, today: today)
    // Qualification latches on bestStreak (history is honest even after a
    // reset); celebration only fires when the CURRENT streak is the one
    // crossing and today's log is what crossed it.
    let rungs = Self.streakLadder.filter { stats.bestStreak >= $0 }.map { days in
      (key: "streak:\(days)", kind: "streak",
       label: "\(def.title): \(days)-day streak", value: Double(days))
    }
    let topQualified = Self.streakLadder.filter { stats.bestStreak >= $0 }.max() ?? 0
    let liveCrossing = dates.contains(today) && stats.currentStreak >= topQualified
    return grantPass(scope: "habit:\(habitID)", goalID: nil,
                     qualified: rungs, celebrateTop: liveCrossing && celebrate, now: now)
  }

  /// Sweep every habit — the grandfather pass and the day-rollover reconcile.
  @discardableResult
  func evaluateAllHabitStreaks(now: Date, today: String,
                               celebrate: Bool = false) -> [MilestoneGrant] {
    let defs = (try? context.fetch(FetchDescriptor<HabitDefinitionEntity>())) ?? []
    return defs.flatMap {
      evaluateHabitStreak(habitID: $0.id, now: now, today: today, celebrate: celebrate)
    }
  }

  // MARK: - Queued presentation (MilestoneInbox)

  /// Celebrated milestones not yet shown to the user, oldest first. The
  /// background-detected path (Withings) lands here; the foreground presents
  /// on next scene-activation. Refuses future-dated rows so time-travel
  /// artifacts present silently instead of animating.
  func pendingPresentation(now: Date) -> [GoalMilestoneEntity] {
    let rows = (try? context.fetch(FetchDescriptor<GoalMilestoneEntity>(
      predicate: #Predicate { $0.celebrated == true && $0.presentedAt == nil },
      sortBy: [SortDescriptor(\.occurredAt)]
    ))) ?? []
    return rows.filter { $0.occurredAt <= now }
  }

  func markPresented(ids: [String], at now: Date) {
    guard !ids.isEmpty else { return }
    for id in ids {
      guard let row = ((try? context.fetch(FetchDescriptor<GoalMilestoneEntity>(
        predicate: #Predicate { $0.id == id }
      ))) ?? []).first, row.presentedAt == nil else { continue }
      row.presentedAt = now
      row.updatedAt = .now
      ckEngine?.noteGoalMilestoneChange(id: id)
    }
    save("milestones presented")
  }

  /// Milestone history for a goal scope (timeline UI). Sentinel rows excluded.
  func milestones(goalID: String) -> [GoalMilestoneEntity] {
    let rows = (try? context.fetch(FetchDescriptor<GoalMilestoneEntity>(
      predicate: #Predicate { $0.goalID == goalID },
      sortBy: [SortDescriptor(\.occurredAt, order: .reverse)]
    ))) ?? []
    return rows.filter { $0.kind != "init" }
  }

  // MARK: - The grant pass

  /// Insert-if-absent for one scope. First pass (no rows for the scope) grants
  /// everything silently + the init sentinel; later passes grant new rungs and
  /// celebrate only the most advanced one (everything below it was skipped
  /// through, not crossed live).
  private func grantPass(scope: String, goalID: String?,
                         qualified: [(key: String, kind: String, label: String, value: Double)],
                         celebrateTop: Bool, now: Date) -> [MilestoneGrant] {
    let existing = Set((((try? context.fetch(FetchDescriptor<GoalMilestoneEntity>(
      predicate: #Predicate { $0.scope == scope }
    ))) ?? [])).map(\.id))
    let initialized = !existing.isEmpty

    let missing = qualified.filter { !existing.contains("\(scope)|\($0.key)") }
    guard !missing.isEmpty || !initialized else { return [] }

    var celebratedGrants: [MilestoneGrant] = []
    var touched = false

    for (index, rung) in missing.enumerated() {
      let id = "\(scope)|\(rung.key)"
      let isTop = index == missing.count - 1
      let celebrate = initialized && celebrateTop && isTop
      let entity = GoalMilestoneEntity(id: id, goalID: goalID, scope: scope,
                                       kind: rung.kind, rungKey: rung.key,
                                       label: rung.label, value: rung.value,
                                       occurredAt: now, celebrated: celebrate,
                                       presentedAt: celebrate ? nil : now)
      context.insert(entity)
      ckEngine?.noteGoalMilestoneChange(id: id)
      touched = true
      if celebrate {
        celebratedGrants.append(MilestoneGrant(id: id, goalID: goalID, scope: scope,
                                               kind: rung.kind, rungKey: rung.key,
                                               label: rung.label, value: rung.value))
      }
    }

    if !initialized {
      // Sentinel marks the scope as initialized even when nothing qualified,
      // so the NEXT crossing celebrates instead of reading as grandfathered.
      let id = "\(scope)|init"
      context.insert(GoalMilestoneEntity(id: id, goalID: goalID, scope: scope,
                                         kind: "init", rungKey: "init", label: "",
                                         value: 0, occurredAt: now,
                                         celebrated: false, presentedAt: now))
      ckEngine?.noteGoalMilestoneChange(id: id)
      touched = true
    }

    if touched {
      save("milestones \(scope)")
      NotificationCenter.default.post(name: .septenaDataChanged, object: nil)
    }
    return celebratedGrants
  }

  // MARK: - Smoothing helpers

  /// Trailing-7-day mean of a body metric ending on `day`, or nil when fewer
  /// than `minSmoothedReadings` rows in the window have a value. Always
  /// recomputed from rows — Withings re-syncs rewrite history, so a cached
  /// mean would lie.
  private func smoothedValue(metricKey: String, endingOn day: String) -> Double? {
    guard let end = SeptenaDate.parse(day),
          let startDate = Calendar.current.date(byAdding: .day, value: -6, to: end),
          let start = SeptenaDate.format(startDate) else { return nil }
    let rows = (try? context.fetch(FetchDescriptor<WithingsRowEntity>(
      predicate: #Predicate { $0.id >= start && $0.id <= day }
    ))) ?? []
    let values = rows.compactMap { metricValue($0, key: metricKey) }
    guard values.count >= Self.minSmoothedReadings else { return nil }
    return values.reduce(0, +) / Double(values.count)
  }

  private func metricValue(_ row: WithingsRowEntity, key: String) -> Double? {
    switch key {
    case "body.weight":      return row.weightKg
    case "body.fat_pct":     return row.fatPct
    case "body.muscle_mass": return row.muscleMassKg
    case "body.fat_mass":    return row.fatMassKg
    case "body.muscle_pct":
      guard let muscle = row.muscleMassKg, let weight = row.weightKg, weight > 0 else { return nil }
      return muscle / weight * 100
    default: return nil
    }
  }

  private func onTargetSide(_ value: Double, target: Double, upper: Double?,
                            comparator: String, step: Double, downward: Bool) -> Bool {
    switch comparator {
    case "lte":   return value <= target
    case "gte":   return value >= target
    case "range": return value >= target && value <= (upper ?? target)
    case "eq":    return abs(value - target) <= step / 2
    default:      return downward ? value <= target : value >= target
    }
  }

  /// Maintenance is the real achievement in body metrics: the smoothed value
  /// must sit on the target side for the whole trailing 30 days. Days where
  /// the mean isn't computable are skipped, but the qualifying span must
  /// genuinely reach back — the earliest computable day must be ≥25 days ago
  /// and at least 5 days must be computable, so a week of data can't claim a
  /// month of holding.
  private func heldTargetForThirtyDays(goal: GoalEntity, metricKey: String,
                                       today: String, step: Double,
                                       downward: Bool) -> Bool {
    guard let target = goal.metricTarget,
          let comparator = goal.metricComparator,
          let todayDate = SeptenaDate.parse(today) else { return false }
    var computable = 0
    var earliestOffset = 0
    for offset in 0..<30 {
      guard let d = Calendar.current.date(byAdding: .day, value: -offset, to: todayDate),
            let iso = SeptenaDate.format(d),
            let mean = smoothedValue(metricKey: metricKey, endingOn: iso) else { continue }
      guard onTargetSide(mean, target: target, upper: goal.metricTargetUpper,
                         comparator: comparator, step: step, downward: downward)
      else { return false }
      computable += 1
      earliestOffset = offset
    }
    return computable >= 5 && earliestOffset >= 25
  }

  /// Whole-step grid values strictly between target and baseline, nearest the
  /// baseline first, so the ladder reads as progress (81, 80, 79… toward 74).
  private func gridValues(baseline: Double, target: Double, step: Double,
                          downward: Bool) -> [Double] {
    var values: [Double] = []
    if downward {
      var v = (baseline / step).rounded(.down) * step
      if v >= baseline { v -= step }
      while v > target {
        values.append(v)
        v -= step
      }
    } else {
      var v = (baseline / step).rounded(.up) * step
      if v <= baseline { v += step }
      while v < target {
        values.append(v)
        v += step
      }
    }
    return values
  }

  // MARK: - Small helpers

  private func trim(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
  }

  private func slug(_ name: String) -> String {
    name.lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: "-")
  }

  private func save(_ label: String) {
    do { try context.save() } catch {
      SeptenaLog.info("[Milestones] save failed (\(label)): \(error.localizedDescription)")
    }
  }
}
