import SwiftUI
import SwiftData

struct RoutineDetailView: View {
  @Environment(\.modelContext) private var context
  @Environment(\.dismiss) private var dismiss

  let entity: SessionTypeEntity?

  @Query(sort: [SortDescriptor(\ExerciseDefinitionEntity.sortIndex),
                SortDescriptor(\ExerciseDefinitionEntity.name)])
  private var allExercises: [ExerciseDefinitionEntity]

  @State private var label = ""
  @State private var exercises: [String] = []  // ordered list of exercise IDs
  @State private var archived = false
  @State private var showPicker = false
  /// Routine category. Drives the in-session input UI (weight + reps
  /// vs. duration + distance + level vs. mobility checklist) and the
  /// quickadd menu icon. The seed-default heuristic in
  /// `SessionKind.defaulted(for:)` covers common ids (`cardio`, `upper`,
  /// `yoga`…) but any custom slug needs to be set here manually.
  @State private var kind: SessionKind = .mixed

  private var isNew: Bool { entity == nil }

  /// Catalog lookup keyed by the collapsed `exerciseKey` so a routine's
  /// stored slug (e.g. "Elliptical", "rowing-machine") still resolves
  /// to its `ExerciseDefinitionEntity` even when the routine and the
  /// catalog disagree on casing or separators. Mirrors what
  /// `TrainingPRCalculator.recents` / `ChecklistMirror.loadLastEntries`
  /// already do for entry → exercise joins — the routine editor was
  /// the last place still doing exact-id matching, which is why
  /// `elliptical` / `rowing` rows under a Cardio routine showed up as
  /// static italic text (no `NavigationLink` to drill into).
  ///
  /// On collision (two catalog entries with the same key — shouldn't
  /// happen in practice) the first one wins; same trade-off the other
  /// call sites accept.
  private var exerciseByID: [String: ExerciseDefinitionEntity] {
    Dictionary(allExercises.map { (exerciseKey($0.id), $0) },
               uniquingKeysWith: { first, _ in first })
  }

  private func resolveDefinition(_ id: String) -> ExerciseDefinitionEntity? {
    exerciseByID[exerciseKey(id)]
  }

  var body: some View {
    Form {
      Section("Name") {
        TextField("Routine label", text: $label)
      }

      Section {
        Picker("Kind", selection: $kind) {
          ForEach(SessionKind.allCases, id: \.self) { k in
            Label(kindTitle(k), systemImage: k.icon).tag(k)
          }
        }
      } header: {
        Text("Kind")
      } footer: {
        Text(kindFooter(kind))
          .font(.caption)
      }

      Section {
        ForEach(exercises, id: \.self) { id in
          if let def = resolveDefinition(id) {
            NavigationLink {
              ExerciseDetailView(entity: def)
            } label: {
              Text(def.name)
            }
          } else {
            Text(id)
              .foregroundStyle(.secondary)
              .italic()
          }
        }
        .onDelete { offsets in
          exercises.remove(atOffsets: offsets)
        }
        .onMove { from, to in
          exercises.move(fromOffsets: from, toOffset: to)
        }
        Button {
          showPicker = true
        } label: {
          Label("Add exercises", systemImage: "plus")
        }
      } header: {
        Text("Exercises")
      } footer: {
        Text("Order here drives the logger order.")
          .font(.caption)
      }

      if !isNew {
        Section("Archive") {
          Toggle("Archived", isOn: $archived)
        }
      }
    }
    .navigationTitle(isNew ? "New Routine" : label)
    // Edit mode is always-on so the drag handles for reordering /
    // swipe-to-delete on the Exercises section are visible without
    // the user toggling an Edit button. `editMode` only exists on
    // iOS — on macOS the Form already supports drag-reorder.
    #if os(iOS)
    .environment(\.editMode, .constant(.active))
    #endif
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { save() }
          .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .sheet(isPresented: $showPicker) {
      ExercisePickerSheet(preselected: exercises, onDone: { newIDs in
        // Append newly selected IDs that aren't already present
        let existing = Set(exercises)
        for id in newIDs where !existing.contains(id) {
          exercises.append(id)
        }
      })
    }
    .onAppear { load() }
  }

  private func load() {
    guard let e = entity else { return }
    label = e.label
    exercises = e.exercises
    archived = e.archived
    // Existing rows without `kindRaw` set fall back to the seed
    // default for their id — same logic the read side applies in
    // `ChecklistMirror.loadSessionTypes`.
    kind = e.kindRaw.flatMap(SessionKind.init(rawValue:))
      ?? SessionKind.defaulted(for: e.id)
  }

  private func save() {
    let id: String
    if let e = entity {
      id = e.id
    } else {
      id = TrainingConfigStore.slug(from: label)
    }
    // Emoji is deprecated — SessionKind.icon replaces it. Clear any
    // historical value on save so the CloudKit field drains naturally.
    TrainingConfigStore.upsertSessionType(
      id: id,
      label: label.trimmingCharacters(in: .whitespaces),
      emoji: nil,
      exercises: exercises,
      archived: archived,
      kind: kind,
      context: context
    )
    dismiss()
  }

  private func kindTitle(_ k: SessionKind) -> String {
    switch k {
    case .strength: return "Strength"
    case .cardio:   return "Cardio"
    case .mobility: return "Mobility"
    case .mixed:    return "Mixed"
    }
  }

  private func kindFooter(_ k: SessionKind) -> String {
    switch k {
    case .strength: return "Inputs: weight · sets · reps."
    case .cardio:   return "Inputs: minutes · distance · level."
    case .mobility: return "Inputs: difficulty only — no metrics."
    case .mixed:    return "Inputs: weight · sets · reps (treated like strength)."
    }
  }
}
