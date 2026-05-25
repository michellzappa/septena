import SwiftUI
import SwiftData

// Training section. Largest MCP brief migrated so far — three record
// types (ExerciseDefinition, SessionType, ExerciseEntry) and twelve
// tools. Keeping it next to the Today event production and the
// detail-line formatter means the catalog + agent contract + render
// helpers can't drift apart.

@MainActor
enum TrainingPlugin: SectionPlugin {
  static var manifest: SectionManifest {
    SectionManifest.byKey["training"]!
  }

  // MARK: - Today timeline

  static func todayEvents(date: String, ctx: TodayContext) -> [TodayEvent] {
    let accent = ctx.theme.color(for: "training")
    return ctx.training
      .filter { $0.date == date }
      .compactMap { entry -> TodayEvent? in
        guard let name = entry.exercise else { return nil }
        let time = entry.concludedAt.map { String($0.dropFirst(11).prefix(5)) } ?? "00:00"
        return TodayEvent(
          id: "tr-\(entry.id)",
          time: time,
          section: "training",
          color: accent,
          title: name,
          detail: detail(for: entry),
          kind: .training(entry)
        )
      }
  }

  /// Compact secondary line: weight, sets×reps (or sets alone), duration,
  /// distance. Returns nil when every field is empty so the row stays
  /// single-line.
  static func detail(for entry: ExerciseEntry) -> String? {
    var parts: [String] = []
    if let w = entry.weight { parts.append("\(Int(w))kg") }
    if let s = entry.sets, let r = entry.reps { parts.append("\(s)×\(r)") }
    else if let s = entry.sets { parts.append("\(s) sets") }
    if let d = entry.durationMin { parts.append("\(Int(d)) min") }
    if let dist = entry.distanceM, dist > 0 {
      parts.append(String(format: "%.1f km", dist / 1000))
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
}

/// Starter session templates. Picking a session creates a SessionType
/// row the user can fill with exercises later. Additive only.
private struct SessionStarter: Identifiable, Hashable {
  let id: String
  let label: String
  let emoji: String

  static let all: [SessionStarter] = [
    .init(id: "starter-upper",    label: "Upper",     emoji: "💪"),
    .init(id: "starter-lower",    label: "Lower",     emoji: "🦵"),
    .init(id: "starter-push",     label: "Push",      emoji: "⬆️"),
    .init(id: "starter-pull",     label: "Pull",      emoji: "⬇️"),
    .init(id: "starter-legs",     label: "Legs",      emoji: "🦵"),
    .init(id: "starter-cardio",   label: "Cardio",    emoji: "🏃"),
    .init(id: "starter-mobility", label: "Mobility",  emoji: "🧘"),
    .init(id: "starter-full",     label: "Full body", emoji: "🏋️"),
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
          VStack(alignment: .leading, spacing: 8) {
            Text("Training groups workouts into session templates like Upper, Lower, or Cardio. Pick the ones you'll use — you can add exercises to each later, or define your own templates.")
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 4)
        }
        Section("Session templates") {
          ForEach(SessionStarter.all) { starter in
            starterRow(starter)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Set up Training")
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
        Text(s.emoji).font(.title3)
          .opacity(exists ? 0.4 : 1)
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
    selected.isEmpty ? "Done" : "Add \(selected.count) template\(selected.count == 1 ? "" : "s")"
  }

  private func addAndFinish() {
    let toAdd = SessionStarter.all.filter {
      selected.contains($0.id) && !alreadyExists($0)
    }
    for s in toAdd {
      _ = mutator.addSessionType(label: s.label, emoji: s.emoji, exercises: [])
    }
    complete()
  }
}
