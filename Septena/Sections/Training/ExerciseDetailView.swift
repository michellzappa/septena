import SwiftUI
import SwiftData

struct ExerciseDetailView: View {
  @Environment(\.modelContext) private var context
  @Environment(\.dismiss) private var dismiss

  // Existing entity (edit mode) or nil (new mode)
  let entity: ExerciseDefinitionEntity?

  @Query(sort: [SortDescriptor(\ExerciseDefinitionEntity.name)])
  private var allExercises: [ExerciseDefinitionEntity]

  @State private var name = ""
  @State private var type = "strength"
  @State private var primaryMuscle: Muscle? = nil
  @State private var secondaryMuscles: Set<Muscle> = []
  @State private var aliasesText = ""
  @State private var archived = false
  @State private var slugCollision = false

  private let typeOptions = ["strength", "cardio", "mobility", "core"]

  private var isNew: Bool { entity == nil }

  private var derivedID: String {
    TrainingConfigStore.slug(from: name)
  }

  var body: some View {
    Form {
      Section("Name") {
        TextField("Exercise name", text: $name)
          .autocorrectionDisabled()
        if isNew && slugCollision {
          Text("An exercise with this ID already exists.")
            .font(.caption)
            .foregroundStyle(.red)
        }
      }

      Section("Classification") {
        Picker("Type", selection: $type) {
          ForEach(typeOptions, id: \.self) { Text($0.capitalized).tag($0) }
        }
        Picker("Primary muscle", selection: $primaryMuscle) {
          Text("None").tag(Optional<Muscle>.none)
          ForEach(Muscle.allCases) { m in
            Text(m.label).tag(Optional(m))
          }
        }
      }

      Section("Secondary muscles") {
        ForEach(Muscle.allCases) { muscle in
          Toggle(muscle.label, isOn: Binding(
            get: { secondaryMuscles.contains(muscle) },
            set: { on in
              if on { secondaryMuscles.insert(muscle) }
              else  { secondaryMuscles.remove(muscle) }
            }
          ))
        }
      }

      Section {
        TextField("alias1, alias2", text: $aliasesText)
          .autocorrectionDisabled()
      } header: {
        Text("Aliases")
      } footer: {
        Text("Comma-separated alternate names used in search.")
          .font(.caption)
      }

      if !isNew {
        Section("Archive") {
          Toggle("Archived", isOn: $archived)
        }
      }
    }
    .navigationTitle(isNew ? "New Exercise" : name)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { save() }
          .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .onAppear { load() }
  }

  private func load() {
    guard let e = entity else { return }
    name = e.name
    type = e.type
    primaryMuscle = e.primaryMuscle.flatMap(Muscle.init(rawValue:))
    secondaryMuscles = Set(e.secondaryMuscles.compactMap(Muscle.init(rawValue:)))
    aliasesText = e.aliases.joined(separator: ", ")
    archived = e.archived
  }

  private func save() {
    let id: String
    if let e = entity {
      id = e.id
    } else {
      id = derivedID
      // Check for slug collision on new exercises
      let exists = allExercises.contains { $0.id == id }
      if exists {
        slugCollision = true
        return
      }
    }
    let aliases = aliasesText
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }

    TrainingConfigStore.upsertExerciseDefinition(
      id: id,
      name: name.trimmingCharacters(in: .whitespaces),
      type: type,
      primaryMuscle: primaryMuscle?.rawValue,
      secondaryMuscles: secondaryMuscles.map(\.rawValue).sorted(),
      aliases: aliases,
      archived: archived,
      context: context
    )
    dismiss()
  }
}
