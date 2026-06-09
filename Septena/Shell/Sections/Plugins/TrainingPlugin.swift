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

  static var logActions: [LogAction] {
    [LogAction(id: "start", title: "Start session", systemImage: "play.fill")]
  }

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
          .opt("concludedAt", "timestamp"), .opt("loggedAt", "timestamp"),
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
    AnyView(TrainingOnboardingView(complete: complete))
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
              inputs: "required: sessionType (id e.g. 'upper'), exercise (canonical NAME — e.g. 'Chest press') · optional: date (default today), time (HH:MM), weight (kg), sets (int or 'AMRAP'), reps, difficulty, durationMin, distanceM, level, note, concludedAt (ISO8601)"),
        SectionSkill.Tool("training_entry_update",   "Patch an entry",
              inputs: "required: id · optional: date, time, sessionType, exercise, weight, sets, reps, difficulty, durationMin, distanceM, level, note, concludedAt"),
        SectionSkill.Tool("training_entry_delete",   "Remove an entry",
              inputs: "required: id"),
        SectionSkill.Tool("training_exercises_list", "Exercise catalog (definitions)",
              inputs: "optional: type (strength|cardio|mobility|core), archived (default false), limit"),
        SectionSkill.Tool("training_exercise_create", "Add an exercise definition. id defaults to slugified name",
              inputs: "required: name, type (strength|cardio|mobility|core) · optional: id (slug), subgroup (e.g. push/pull), aliases (array), primaryMuscle, secondaryMuscles (array)"),
        SectionSkill.Tool("training_exercise_update", "Update an exercise definition",
              inputs: "required: id · optional: name, type, subgroup, aliases, primaryMuscle, secondaryMuscles, archived"),
        SectionSkill.Tool("training_exercise_delete", "Delete from catalog",
              inputs: "required: id"),
        SectionSkill.Tool("training_sessions_list",  "Session-type templates (e.g. 'upper', 'lower', 'cardio')",
              inputs: "optional: archived (default false), limit"),
        SectionSkill.Tool("training_session_create", "Create a session template. id is the canonical key",
              inputs: "required: id (e.g. 'upper'), label · optional: emoji, exercises (array of canonical names), kind"),
        SectionSkill.Tool("training_session_update", "Update a session template",
              inputs: "required: id · optional: label, emoji, exercises, kind, archived"),
        SectionSkill.Tool("training_session_delete", "Remove a session template",
              inputs: "required: id"),
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

      ### Don't
      - Don't pass an exercise id where `exercise` is expected — it's the **canonical name** (e.g. 'Chest press'), not the slug.
      - Don't pass arbitrary strings for `sessionType` — resolve to an existing SessionType id first.
      - Don't `training_exercise_delete` something that has historical entries unless the user is sure. Entries keep a denormalised exercise name, but the catalog reference is lost.
      """
    )
  }

  // MARK: - Aim metrics

  static var aimMetrics: [GoalMetric] {
    [
      GoalMetric(key: "training.session_count",
                 label: "Training sessions (this week)",
                 sectionKey: "training",
                 window: "calendarWeek",
                 unitLabel: "sessions"),
    ]
  }

  static func evaluateAim(metric: GoalMetric, context: ModelContext) -> Double? {
    switch metric.key {
    case "training.session_count":
      // A "session" collapses to a distinct training day — multiple
      // session types in one day still count as one training day from
      // the user's perspective.
      guard let (startStr, endStr) = GoalMetricWindow.dateStringRange(for: metric.window) else { return 0 }
      let descriptor = FetchDescriptor<ExerciseEntryEntity>(
        predicate: #Predicate { $0.date >= startStr && $0.date <= endStr }
      )
      let entries = (try? context.fetch(descriptor)) ?? []
      return Double(Set(entries.map { $0.date }).count)
    default:
      return nil
    }
  }
}

private struct TrainingDetailContent: View {
  var body: some View {
    Section("Training") {
      NavigationLink {
        ExerciseCatalogView()
      } label: { Label("Exercises", systemImage: "figure.strengthtraining.traditional") }
      NavigationLink {
        RoutineCatalogView()
      } label: { Label("Routines", systemImage: "list.bullet.rectangle") }
    }
  }
}

/// Starter session templates. Picking a session creates a SessionType
/// row the user can fill with exercises later. Additive only.
private struct SessionStarter: Identifiable, Hashable {
  let id: String
  let label: String

  static let all: [SessionStarter] = [
    .init(id: "starter-upper",    label: "Upper"),
    .init(id: "starter-lower",    label: "Lower"),
    .init(id: "starter-push",     label: "Push"),
    .init(id: "starter-pull",     label: "Pull"),
    .init(id: "starter-legs",     label: "Legs"),
    .init(id: "starter-cardio",   label: "Cardio"),
    .init(id: "starter-mobility", label: "Mobility"),
    .init(id: "starter-full",     label: "Full body"),
  ]
}

private struct TrainingOnboardingView: View {
  let complete: () -> Void
  @Environment(SectionTheme.self) private var theme
  @Environment(\.modelContext) private var modelContext
  @State private var selected: Set<String> = []
  @State private var existingLabels: Set<String> = []

  private var accent: Color { theme.color(for: "training") }
  private var mutator: TrainingMutator { SeptenaServices.shared.trainingMutator }

  private func alreadyExists(_ s: SessionStarter) -> Bool {
    existingLabels.contains(s.label.lowercased())
  }

  private func loadExisting() {
    let rows = (try? modelContext.fetch(FetchDescriptor<SessionTypeEntity>())) ?? []
    existingLabels = Set(rows.map { $0.label.lowercased() })
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          SectionOnboardingHero(
            sectionKey: "training",
            title: "Training",
            intro: "Groups workouts into session templates like Upper, Lower, or Cardio. Pick the ones you'll use — add exercises to each later, or define your own templates."
          )
          .onboardingHeroSection()
        }
        Section("Session templates") {
          ForEach(SessionStarter.all) { starter in
            starterRow(starter)
          }
        }
      }
      .formStyle(.grouped)
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .safeAreaInset(edge: .bottom) {
        bottomBar
      }
      .onAppear { loadExisting() }
    }
  }

  @ViewBuilder
  private func starterRow(_ s: SessionStarter) -> some View {
    let exists = alreadyExists(s)
    let isSelected = selected.contains(s.id)
    Button {
      guard !exists else { return }
      if isSelected { selected.remove(s.id) } else { selected.insert(s.id) }
    } label: {
      HStack(spacing: 12) {
        Text(s.label)
          .foregroundStyle(exists ? .secondary : .primary)
          .strikethrough(exists, color: .secondary)
        Spacer()
        if exists {
          Text("Already added")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isSelected ? accent : Color.secondary.opacity(0.6))
            .font(.title3)
        }
      }
    }
    .buttonStyle(.plain)
    .disabled(exists)
  }

  @ViewBuilder
  private var bottomBar: some View {
    HStack(spacing: 12) {
      Button("Skip") { complete() }
        .buttonStyle(.bordered)
      Spacer()
      Button(actionTitle) { addAndFinish() }
        .buttonStyle(.borderedProminent)
        .tint(accent)
    }
    .padding()
    .background(.bar)
  }

  private var actionTitle: String {
    selected.isEmpty ? String(localized: "Done") : String(localized: "Add \(selected.count) templates")
  }

  private func addAndFinish() {
    let toAdd = SessionStarter.all.filter {
      selected.contains($0.id) && !alreadyExists($0)
    }
    for s in toAdd {
      _ = mutator.addSessionType(label: s.label, emoji: nil, exercises: [])
    }
    complete()
  }
}

@MainActor func exerciseEntryExportDict(_ e: ExerciseEntryEntity) -> [String: Any] {
  compact([
    "id": e.id, "date": e.date, "time": EventTimestamp.hhmm(from: e.occurredAt),
    "sessionType": e.sessionType, "exercise": e.exercise,
    "weight": e.weight, "sets": e.sets, "reps": e.reps,
    "difficulty": e.difficulty, "durationMin": e.durationMin,
    "distanceM": e.distanceM, "level": e.level, "note": e.note,
    "concludedAt": e.concludedAt, "loggedAt": e.loggedAt,
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
