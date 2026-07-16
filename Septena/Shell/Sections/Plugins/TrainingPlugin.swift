import SwiftUI
import SwiftData

// Training section. Largest MCP brief migrated so far — three record
// types (ExerciseDefinition, SessionType, ExerciseEntry) and twelve
// tools. Keeping it next to the Today event production and the
// detail-line formatter means the catalog + agent contract + render
// helpers can't drift apart.

@MainActor
enum TrainingPlugin: SectionPlugin {
  static var producesTimedEvents: Bool { true }

  static var manifest: SectionManifest {
    SectionManifest.byKey["training"]!
  }

  static func destinationView() -> AnyView? { AnyView(TrainingDestinationView()) }

  static func detailPaneContent() -> AnyView? { AnyView(TrainingDetailContent()) }

  static var exportContribution: SectionExportContribution? {
    SectionExportContribution(
      tables: [
        SchemaTable(name: "exerciseDefinition", purpose: "exercise catalog entry", fields: [
          .req("id", "string", "slug, e.g. chest-press"),
          .req("name", "string"),
          .req("type", "string", "strength | cardio | mobility | core"),
          .opt("subgroup", "string"), .opt("aliases", "[string]"),
          .opt("primaryMuscle", "string"),
          .opt("secondaryMuscles", "[string]"),
          .opt("archived", "bool"), .opt("sortIndex", "int"),
        ]),
        SchemaTable(name: "sessionType", purpose: "a workout template (upper, lower, …)", fields: [
          .req("id", "string"), .req("label", "string"),
          .opt("emoji", "string"), .opt("exercises", "[string]"),
          .opt("kind", "string"), .opt("archived", "bool"),
          .opt("sortIndex", "int"),
        ]),
        SchemaTable(name: "exerciseEntry", purpose: "one logged set or interval", fields: [
          .req("id", "string"), .req("date", "date"),
          .req("time", "time", "session start"),
          .req("sessionType", "string"), .req("exercise", "string"),
          .opt("weight", "double"), .opt("sets", "string", "int or \"AMRAP\""),
          .opt("reps", "string"), .opt("difficulty", "string"),
          .opt("durationMin", "double"), .opt("distanceM", "double"),
          .opt("level", "double"), .opt("note", "string"),
          .opt("concludedAt", "timestamp", "session start"), .opt("endedAt", "timestamp", "session end"),
          .opt("loggedAt", "timestamp"),
        ]),
      ],
      collect: { ctx in
        let defs     = try ctx.fetch(FetchDescriptor<ExerciseDefinitionEntity>())
        let sessions = try ctx.fetch(FetchDescriptor<SessionTypeEntity>())
        let entries  = try ctx.fetch(FetchDescriptor<ExerciseEntryEntity>())
        return [
          "exerciseDefinition": defs.map(exerciseDefinitionExportDict),
          "sessionType":        sessions.map(sessionTypeExportDict),
          "exerciseEntry":      entries.map(exerciseEntryExportDict),
        ]
      }
    )
  }

  // MARK: - First-enable onboarding

  static func onboarding(complete: @escaping () -> Void) -> AnyView? {
    AnyView(SectionOnboarding(
      sectionKey: "training",
      intro: "Log your workouts — strength, cardio, or mobility. Pick the kinds of movement you do and Septena sets up a routine for each, ready to fill with exercises as you go.",
      nounPlural: String(localized: "routines"),
      header: String(localized: "Training types"),
      footer: String(localized: "Each becomes a routine you can fill with your own exercises. Rename or add more anytime."),
      items: SessionStarter.all,
      glyph: { .symbol($0.kind.icon) },
      primary: { $0.label },
      secondary: { $0.blurb },
      existsKey: { AnyHashable($0.label.lowercased()) },
      loadExistingKeys: {
        await MirrorReader.shared.read { ctx in
          Set(((try? ctx.fetch(FetchDescriptor<SessionTypeEntity>())) ?? [])
            .map { AnyHashable($0.label.lowercased()) })
        }
      },
      add: { items in
        let mutator = SeptenaServices.shared.trainingMutator
        for s in items { _ = mutator.addSessionType(label: s.label, emoji: nil, exercises: []) }
      },
      complete: complete
    ))
  }

  // MARK: - MCP / agent contract

  static var mcpSkill: SectionSkill? {
    SectionSkill(
      key: "training",
      summary: "Log exercise sets, manage exercise catalog, define session-type templates.",
      tools: [
        SectionSkill.Tool("training_entries_list",   "List exercise entries by day or range",
              inputs: "optional: date, from, to, exercise (filter to one canonical name), limit"),
        SectionSkill.Tool("training_entry_log",      "Log a set. Strength: weight/sets/reps. Cardio: durationMin/distanceM. Difficulty/note optional",
              inputs: "required: sessionType (id e.g. 'upper'), exercise (canonical NAME — e.g. 'Chest press') · optional: date (default today), time (HH:MM), weight (kg), sets (int or 'AMRAP'), reps, difficulty, durationMin, distanceM, level, note, concludedAt (session start ISO8601), endedAt (session end ISO8601)"),
        SectionSkill.Tool("training_entry_update",   "Patch any subset of fields (rename/retag supported; only fields you pass change)",
              inputs: "required: id · optional: date, time, sessionType, exercise, weight, sets, reps, difficulty, durationMin, distanceM, level, note, concludedAt, endedAt"),
        SectionSkill.Tool("training_exercises_list", "Exercise catalog (definitions)",
              inputs: "optional: type (strength|cardio|mobility|core), archived (default false), limit"),
        SectionSkill.Tool("training_exercise_create", "Add an exercise definition. id defaults to slugified name",
              inputs: "required: name, type (strength|cardio|mobility|core) · optional: id (slug), subgroup (e.g. push/pull), aliases (array), primaryMuscle, secondaryMuscles (array)"),
        SectionSkill.Tool("training_exercise_update", "Update an exercise definition (archive with archived: true)",
              inputs: "required: id · optional: name, type, subgroup, aliases, primaryMuscle, secondaryMuscles, archived"),
        SectionSkill.Tool("training_sessions_list",  "Session-type templates / routines (e.g. 'upper', 'lower', 'cardio')",
              inputs: "optional: archived (default false), limit"),
        SectionSkill.Tool("training_session_create", "Create a session template. id is the canonical key",
              inputs: "required: id (e.g. 'upper'), label · optional: emoji, exercises (array of canonical NAMES), kind (strength|cardio|mobility|mixed)"),
        SectionSkill.Tool("training_session_update", "Update a session template. Archive (remove from pickers, non-destructive) with archived: true",
              inputs: "required: id · optional: label, emoji, exercises, kind (strength|cardio|mobility|mixed), archived"),
      ],
      body: """
      ### Model
      Training has three record types that work together:
      - **ExerciseDefinition** — the catalog. Each has a stable slug `id` ('chest-press'), `name` ('Chest press'), `type` (strength/cardio/...), optional muscle tags.
        `primaryMuscle` + `secondaryMuscles` must be one of these 16 exact values:
        `chest, frontDelts, sideDelts, rearDelts, triceps, lats, upperBack, biceps,
        forearms, quads, hamstrings, glutes, calves, adductors, abs, lowerBack`
        (camelCase exactly; 'quads' not 'quadriceps'). Cardio/mobility usually have none. To
        backfill, read with `training_exercises_list` then set per exercise with
        `training_exercise_update({id, primaryMuscle, secondaryMuscles})`; pass
        `primaryMuscle: ""` to clear a wrong tag.
      - **SessionType** — a routine template. id is the key ('upper', 'lower', 'cardio'). Lists which exercises belong to that session.
      - **ExerciseEntry** — one logged set or block. References `sessionType` by id and `exercise` by canonical NAME (not id).

      ### Logging workflow
      1. `training_sessions_list()` → find the sessionType id matching what the user did ('upper', 'cardio', etc.)
      2. `training_exercises_list({type: "strength"})` → find the canonical exercise name
      3. `training_entry_log({sessionType, exercise, weight, sets, reps})` → log it

      ### Examples
      **"I just did 3 sets of 8 chest press at 80kg"**
      ```
      training_entry_log(
        sessionType: "upper",
        exercise: "Chest press",
        weight: 80,
        sets: "3",
        reps: "8"
      )
      ```

      **"Ran 5k in 24 minutes"**
      ```
      training_entry_log(
        sessionType: "cardio",
        exercise: "Run",
        durationMin: 24,
        distanceM: 5000
      )
      ```

      **"What did I do this week?"**
      ```
      training_entries_list({ from: "<monday>", to: "<sunday>" })
      ```

      ### Goals
      Training exposes three measurable goal metrics (set the target in-app under
      the section's goals strip; read them via `goals_list`). All use the
      trailing-7-day week:
      - `training.hard_sets_week` — effective hard sets (Σ sets × difficulty
        weight). Natural `range` goal; the productive default band is 12–20.
      - `training.cardio_minutes_week` — summed cardio minutes (default 150).
      - `training.session_count` — distinct training days (default 4).

      ### Don't
      - Don't pass an exercise id where `exercise` is expected — it's the **canonical name** (e.g. 'Chest press'), not the slug.
      - Don't pass arbitrary strings for `sessionType` — resolve to an existing SessionType id (via `training_sessions_list`) or create one first with `training_session_create`.
      - Don't invent a routine on the fly — reuse an existing session template when one fits; only `training_session_create` a genuinely new split.
      - Prefer archiving (`archived: true` via the update tools) over removal — there is no delete tool, and archiving keeps historical entries intact while hiding the template/exercise from pickers.
      """
    )
  }

  // MARK: - Aim metrics

  // Training's measurable commitments. All three read the trailing-7-day week
  // via `TrainingMetrics` (single source of truth shared with the strength /
  // cardio cards and the watch training-ring complication), so the goal bar,
  // the in-section chart, and the wrist always agree. `hard_sets_week` is the
  // natural `range` goal (the productive 12–20 band); the other two are `gte`.
  static var aimMetrics: [GoalMetric] {
    [
      GoalMetric(key: TrainingMetrics.hardSetsKey,
                 label: "Hard sets (this week)",
                 sectionKey: "training",
                 window: "calendarWeek",
                 unitLabel: "sets"),
      GoalMetric(key: TrainingMetrics.cardioMinutesKey,
                 label: "Cardio minutes (this week)",
                 sectionKey: "training",
                 window: "calendarWeek",
                 unitLabel: "min"),
      GoalMetric(key: TrainingMetrics.sessionCountKey,
                 label: "Training sessions (this week)",
                 sectionKey: "training",
                 window: "calendarWeek",
                 unitLabel: "sessions"),
    ]
  }

  static func evaluateAim(metric: GoalMetric, context: ModelContext, now: Date) -> Double? {
    let today = SeptenaDate.format(Calendar.current.startOfDay(for: now)) ?? SeptenaDate.today
    let entries = TrainingMetrics.entriesThisWeek(context: context, today: today)
    switch metric.key {
    case TrainingMetrics.hardSetsKey:      return TrainingMetrics.hardSets(entries)
    case TrainingMetrics.cardioMinutesKey: return TrainingMetrics.cardioMinutes(entries)
    case TrainingMetrics.sessionCountKey:  return TrainingMetrics.sessionCount(entries)
    default:                               return nil
    }
  }

  // Starter targets — the built-in defaults from `TrainingMetrics`, offered in
  // first-run onboarding and seeded for existing users by `TrainingTargetMigration`
  // (single source of the numbers). "Sessions/week" is the one universal enough
  // to pre-check; volume + cardio are opt-in.
  static func suggestedGoals(context: ModelContext) -> [SuggestedGoal] {
    let band = TrainingMetrics.hardSetsBand(context: context)
    let cardio = TrainingMetrics.defaultCardioWeeklyMin
    let sessions = TrainingMetrics.defaultSessionTarget
    return [
      SuggestedGoal(metricKey: TrainingMetrics.sessionCountKey, sectionKey: "training",
                    text: "\(Int(sessions)) training sessions/week",
                    comparator: "gte", target: sessions, upper: nil,
                    window: "calendarWeek", unitLabel: "sessions", recommended: true),
      SuggestedGoal(metricKey: TrainingMetrics.hardSetsKey, sectionKey: "training",
                    text: "Hard sets \(Int(band.target))–\(Int(band.ceiling))/week",
                    comparator: "range", target: band.target, upper: band.ceiling,
                    window: "calendarWeek", unitLabel: "sets", recommended: false),
      SuggestedGoal(metricKey: TrainingMetrics.cardioMinutesKey, sectionKey: "training",
                    text: "Cardio \(Int(cardio)) min/week",
                    comparator: "gte", target: cardio, upper: nil,
                    window: "calendarWeek", unitLabel: "min", recommended: false),
    ]
  }
}

private struct TrainingDetailContent: View {
  @AppStorage(EffortScale.storageKey) private var effortScaleRaw = EffortScale.difficulty.rawValue
  @AppStorage(TrainingDraftStore.autoAdvanceKey) private var autoAdvanceNext = TrainingDraftStore.defaultAutoAdvance

  var body: some View {
    Section("Training") {
      NavigationLink {
        ExerciseCatalogView()
      } label: { Label("Exercises", systemImage: "figure.strengthtraining.traditional") }
      NavigationLink {
        RoutineCatalogView()
      } label: { Label("Routines", systemImage: "list.bullet.rectangle") }
    }
    Section {
      Picker("Effort scale", selection: $effortScaleRaw) {
        Text("Difficulty").tag(EffortScale.difficulty.rawValue)
        Text("RIR").tag(EffortScale.rir.rawValue)
      }
      Text("How you rate each set. Difficulty uses plain words (Easy · Moderate · Hard · Max); RIR is reps in reserve (3+ · 2 · 1 · 0, where 0 is to failure). Same data either way.")
        .font(.caption)
        .foregroundStyle(.secondary)
    } header: {
      Text("Effort scale")
    }
    Section {
      Toggle("Auto-advance to next exercise", isOn: $autoAdvanceNext)
      Text("After saving a set, open the next pending exercise automatically. Turn off to stay on the session list.")
        .font(.caption)
        .foregroundStyle(.secondary)
    } header: {
      Text("Session")
    }
  }
}

/// Starter routines, framed as the three kinds of movement rather than a
/// muscle-group split — the simplest mental model for a general exercise
/// tracker, and a 1:1 match with `SessionKind`. Picking one creates a
/// SessionType row (its slug maps back to the right `SessionKind`) the user
/// can fill with exercises later. Additive only. Power users build their own
/// splits (Upper/Lower/Push/Pull…) from the section once they're in.
private struct SessionStarter: Identifiable, Hashable {
  let id: String
  let label: String
  let kind: SessionKind
  let blurb: String

  static let all: [SessionStarter] = [
    .init(id: "starter-strength", label: "Strength", kind: .strength,
          blurb: "Lifting and resistance — track sets, reps, and weight."),
    .init(id: "starter-cardio", label: "Cardio", kind: .cardio,
          blurb: "Runs, rides, rows — track time and distance."),
    .init(id: "starter-mobility", label: "Mobility", kind: .mobility,
          blurb: "Yoga, stretching, recovery — track each session."),
  ]
}

@MainActor func exerciseEntryExportDict(_ e: ExerciseEntryEntity) -> [String: Any] {
  compact([
    "id": e.id, "date": e.date, "time": EventTimestamp.hhmm(from: e.occurredAt),
    "sessionType": e.sessionType, "exercise": e.exercise,
    "weight": e.weight, "sets": e.sets, "reps": e.reps,
    "difficulty": e.difficulty, "durationMin": e.durationMin,
    "distanceM": e.distanceM, "level": e.level, "note": e.note,
    "concludedAt": e.concludedAt, "endedAt": e.endedAt, "loggedAt": e.loggedAt,
    "updatedAt": isoDate(e.updatedAt),
  ])
}

@MainActor func exerciseDefinitionExportDict(_ e: ExerciseDefinitionEntity) -> [String: Any] {
  compact([
    "id": e.id, "name": e.name, "type": e.type, "subgroup": e.subgroup,
    "aliases": e.aliases, "primaryMuscle": e.primaryMuscle,
    "secondaryMuscles": e.secondaryMuscles, "archived": e.archived,
    "sortIndex": e.sortIndex, "updatedAt": isoDate(e.updatedAt),
  ])
}

@MainActor func sessionTypeExportDict(_ e: SessionTypeEntity) -> [String: Any] {
  compact([
    "id": e.id, "label": e.label, "emoji": e.emoji,
    "exercises": e.exercises, "archived": e.archived,
    "sortIndex": e.sortIndex, "kind": e.kindRaw,
    "updatedAt": isoDate(e.updatedAt),
  ])
}
