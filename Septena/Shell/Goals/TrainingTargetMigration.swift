import Foundation
import SwiftData

// One-shot migration: materialize training's built-in weekly targets as real
// goals tagged `training`, so the numbers the section has always shown (the
// productive 12–20 hard-set band, ~150 cardio min/week, 4 sessions/week) become
// editable commitments — they show progress, surface in the Training strip and
// under the Training coach, and the watch ring fills toward them.
//
// Training never stored these as user data (they were hardcoded defaults), so
// unlike `MacroTargetMigration` there's nothing personal to lift — we seed the
// defaults from `TrainingMetrics`. Only for users who actually train (≥1 logged
// entry), so non-lifters don't get three empty goals.
//
// Idempotent (flag-gated) and dedup-guarded (never clobbers an existing goal for
// a metric — notably a `training.session_count` goal a user already created).
// Runs after CloudKit bind + fetch so it can't duplicate a sibling device's seed.

@MainActor
enum TrainingTargetMigration {
  private static let flag = "migration.trainingTargetsToGoals.v1"

  static func runIfNeeded(context: ModelContext) {
    guard !UserDefaults.standard.bool(forKey: flag) else { return }

    // Only seed for users who train — skip (and DON'T set the flag) when there's
    // no history yet, so a later first workout still gets the seed.
    var entryCheck = FetchDescriptor<ExerciseEntryEntity>()
    entryCheck.fetchLimit = 1
    let hasHistory = ((try? context.fetch(entryCheck)) ?? []).isEmpty == false
    guard hasHistory else { return }

    let mutator = SeptenaServices.shared.goalMutator
    let existingKeys = Set(LocalCache.goals(in: context).compactMap(\.metricKey))

    // Seed ALL of training's suggested goals (existing users get the full set;
    // new users pick a subset in onboarding instead). Single source of the
    // numbers: `TrainingPlugin.suggestedGoals`.
    for s in TrainingPlugin.suggestedGoals(context: context) {
      s.seedIfAbsent(existingKeys: existingKeys, mutator: mutator)
    }

    UserDefaults.standard.set(true, forKey: flag)
  }
}
