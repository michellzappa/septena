import SwiftUI
import SwiftData

// Browse-and-add picker for the curated DefaultExerciseLibrary. Entries
// whose slug already exists in the user's catalog are shown disabled
// with a checkmark — never overwritten. New picks are inserted via
// TrainingConfigStore.upsertExerciseDefinition; the live @Query in
// ExerciseCatalogView picks them up automatically on dismiss.

struct ExerciseLibrarySheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var context
  @Query private var existing: [ExerciseDefinitionEntity]
  @State private var selected: Set<String> = []
  @State private var searchText = ""

  private var existingSlugs: Set<String> {
    Set(existing.map(\.id))
  }

  private var filteredGroups: [(title: String, items: [LibraryExercise])] {
    let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if q.isEmpty { return DefaultExerciseLibrary.grouped }
    return DefaultExerciseLibrary.grouped
      .map { ($0.title, $0.items.filter { $0.name.lowercased().contains(q) }) }
      .filter { !$0.1.isEmpty }
  }

  var body: some View {
    NavigationStack {
      List {
        ForEach(filteredGroups, id: \.title) { group in
          Section(group.title) {
            ForEach(group.items) { item in
              row(item)
            }
          }
        }
      }
      .searchable(text: $searchText)
      .navigationTitle("Exercise library")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(addLabel) { commit() }
            .disabled(selected.isEmpty)
        }
      }
    }
    .macSheetFrame()
  }

  private var addLabel: String {
    selected.isEmpty ? "Add" : "Add \(selected.count)"
  }

  @ViewBuilder
  private func row(_ item: LibraryExercise) -> some View {
    let alreadyAdded = existingSlugs.contains(item.id)
    let isSelected = selected.contains(item.id)
    Button {
      guard !alreadyAdded else { return }
      if isSelected { selected.remove(item.id) } else { selected.insert(item.id) }
    } label: {
      HStack(spacing: 10) {
        Image(systemName: alreadyAdded
              ? "checkmark.circle.fill"
              : (isSelected ? "checkmark.circle.fill" : "circle"))
          .foregroundStyle(alreadyAdded
                           ? Color.secondary
                           : (isSelected ? Color.accentColor : Color.secondary))
        VStack(alignment: .leading, spacing: 2) {
          Text(item.name)
            .foregroundStyle(alreadyAdded ? .secondary : .primary)
          if !item.secondaryMuscles.isEmpty {
            Text(item.secondaryMuscles.map(\.label).joined(separator: " · "))
              .font(.caption2)
              .foregroundStyle(.tertiary)
          }
        }
        Spacer()
        if alreadyAdded {
          Text("In catalog")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      // `.plain` opts the row out of the list cell's tap target, so without
      // this the Spacer and trailing gaps are dead zones.
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(alreadyAdded)
  }

  private func commit() {
    for slug in selected {
      guard let item = DefaultExerciseLibrary.bySlug[slug] else { continue }
      guard !existingSlugs.contains(slug) else { continue }
      _ = TrainingConfigStore.upsertExerciseDefinition(
        id: item.id,
        name: item.name,
        type: item.type,
        primaryMuscle: item.primaryMuscle?.rawValue,
        secondaryMuscles: item.secondaryMuscles.map(\.rawValue),
        aliases: [],
        archived: false,
        context: context
      )
    }
    dismiss()
  }
}
