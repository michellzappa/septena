import SwiftUI
import SwiftData

struct ExercisePickerSheet: View {
  @Query(sort: [SortDescriptor(\ExerciseDefinitionEntity.sortIndex),
                SortDescriptor(\ExerciseDefinitionEntity.name)])
  private var allExercises: [ExerciseDefinitionEntity]

  @Environment(\.dismiss) private var dismiss
  @State private var searchText = ""
  @State private var selected: Set<String> = []

  // IDs already in the routine — passed in so we can pre-check them.
  let preselected: [String]
  let onDone: ([String]) -> Void

  private var visibleExercises: [ExerciseDefinitionEntity] {
    let active = allExercises.filter { !$0.archived }
    guard !searchText.isEmpty else { return active }
    let q = searchText.lowercased()
    return active.filter { e in
      e.name.lowercased().contains(q) || e.aliases.contains { $0.lowercased().contains(q) }
    }
  }

  var body: some View {
    NavigationStack {
      List {
        ForEach(visibleExercises) { entity in
          rowView(entity)
        }
      }
      .searchable(text: $searchText)
      .navigationTitle("Pick Exercises")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            // Preserve catalog order for selected items
            let orderedIDs = visibleExercises
              .filter { selected.contains($0.id) }
              .map(\.id)
            onDone(orderedIDs)
            dismiss()
          }
        }
      }
      .onAppear {
        selected = Set(preselected)
      }
    }
  }

  private func rowView(_ entity: ExerciseDefinitionEntity) -> some View {
    Button {
      if selected.contains(entity.id) {
        selected.remove(entity.id)
      } else {
        selected.insert(entity.id)
      }
    } label: {
      HStack {
        Text(entity.name)
          .foregroundStyle(.primary)
        Spacer()
        if selected.contains(entity.id) {
          Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
        }
      }
    }
    .buttonStyle(.plain)
  }
}
