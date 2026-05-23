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

  private var isNew: Bool { entity == nil }

  private var exerciseByID: [String: ExerciseDefinitionEntity] {
    Dictionary(uniqueKeysWithValues: allExercises.map { ($0.id, $0) })
  }

  var body: some View {
    Form {
      Section("Name") {
        TextField("Routine label", text: $label)
      }

      Section {
        ForEach(exercises, id: \.self) { id in
          if let def = exerciseByID[id] {
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
    // the user toggling an Edit button.
    .environment(\.editMode, .constant(.active))
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
  }

  private func save() {
    let id: String
    if let e = entity {
      id = e.id
    } else {
      id = TrainingConfigStore.slug(from: label)
    }
    // Preserve any existing emoji on the entity — the UI no longer
    // exposes it, but we don't want to silently null out historical
    // values on save.
    TrainingConfigStore.upsertSessionType(
      id: id,
      label: label.trimmingCharacters(in: .whitespaces),
      emoji: entity?.emoji,
      exercises: exercises,
      archived: archived,
      context: context
    )
    dismiss()
  }
}
