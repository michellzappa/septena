import SwiftUI
import SwiftData

struct ExerciseCatalogView: View {
  @Query(sort: [SortDescriptor(\ExerciseDefinitionEntity.sortIndex),
                SortDescriptor(\ExerciseDefinitionEntity.name)])
  private var allExercises: [ExerciseDefinitionEntity]

  @Environment(\.modelContext) private var context
  @State private var searchText = ""
  @State private var selectedMuscle: Muscle? = nil
  @State private var showArchived = false
  @State private var showNewDetail = false
  @State private var showLibrary = false

  private var filtered: [ExerciseDefinitionEntity] {
    allExercises.filter { entity in
      guard showArchived || !entity.archived else { return false }
      if let m = selectedMuscle {
        guard entity.primaryMuscle == m.rawValue ||
              entity.secondaryMuscles.contains(m.rawValue) else { return false }
      }
      if !searchText.isEmpty {
        let q = searchText.lowercased()
        let nameMatch = entity.name.lowercased().contains(q)
        let aliasMatch = entity.aliases.contains { $0.lowercased().contains(q) }
        guard nameMatch || aliasMatch else { return false }
      }
      return true
    }
  }

  var body: some View {
    List {
      muscleFilter
      ForEach(filtered) { entity in
        NavigationLink {
          ExerciseDetailView(entity: entity)
        } label: {
          exerciseRow(entity)
        }
        .swipeActions(edge: .trailing) {
          if entity.archived {
            Button("Unarchive") {
              TrainingConfigStore.setExerciseDefinitionArchived(id: entity.id, archived: false, context: context)
            }.tint(.blue)
          } else {
            Button("Archive") {
              TrainingConfigStore.setExerciseDefinitionArchived(id: entity.id, archived: true, context: context)
            }.tint(.orange)
          }
        }
        .contextMenu {
          Button(role: .destructive) {
            TrainingConfigStore.deleteExerciseDefinition(id: entity.id, context: context)
          } label: {
            Label("Delete permanently", systemImage: "trash")
          }
        }
      }
    }
    .searchable(text: $searchText)
    .navigationTitle("Exercises")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button { showNewDetail = true } label: {
          Image(systemName: "plus")
        }
      }
      ToolbarItem(placement: .secondaryAction) {
        Button { showLibrary = true } label: {
          Label("Browse library", systemImage: "books.vertical")
        }
      }
      ToolbarItem(placement: .secondaryAction) {
        Toggle("Show archived", isOn: $showArchived)
      }
    }
    .navigationDestination(isPresented: $showNewDetail) {
      ExerciseDetailView(entity: nil)
    }
    .sheet(isPresented: $showLibrary) {
      ExerciseLibrarySheet()
    }
  }

  @ViewBuilder
  private var muscleFilter: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        filterChip(label: "All", isSelected: selectedMuscle == nil) {
          selectedMuscle = nil
        }
        ForEach(Muscle.allCases) { muscle in
          filterChip(label: muscle.label, isSelected: selectedMuscle == muscle) {
            selectedMuscle = selectedMuscle == muscle ? nil : muscle
          }
        }
      }
      .padding(.horizontal, 4)
      .padding(.vertical, 6)
    }
    .listRowInsets(EdgeInsets())
    .listRowBackground(Color.clear)
  }

  private func filterChip(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(label)
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.15))
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .clipShape(Capsule())
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private func exerciseRow(_ entity: ExerciseDefinitionEntity) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text(entity.name)
          .foregroundStyle(entity.archived ? .secondary : .primary)
        typeBadge(entity.type)
        Spacer()
      }
      HStack(spacing: 4) {
        if let pm = entity.primaryMuscle {
          musclePill(pm, isPrimary: true)
        }
        ForEach(entity.secondaryMuscles, id: \.self) { m in
          musclePill(m, isPrimary: false)
        }
      }
    }
    .padding(.vertical, 2)
  }

  private func typeBadge(_ type: String) -> some View {
    Text(type)
      .font(.caption2)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(Color.accentColor.opacity(0.12))
      .foregroundStyle(Color.accentColor)
      .clipShape(RoundedRectangle(cornerRadius: 4))
  }

  private func musclePill(_ raw: String, isPrimary: Bool) -> some View {
    Text(raw.capitalized)
      .font(.caption2)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(isPrimary ? Color.secondary.opacity(0.25) : Color.secondary.opacity(0.12))
      .foregroundStyle(.secondary)
      .clipShape(Capsule())
  }
}
