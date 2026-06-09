import SwiftUI
import SwiftData

struct ExerciseCatalogView: View {
  @Query(sort: [SortDescriptor(\ExerciseDefinitionEntity.sortIndex),
                SortDescriptor(\ExerciseDefinitionEntity.name)])
  private var allExercises: [ExerciseDefinitionEntity]

  @Environment(\.modelContext) private var context
  @State private var searchText = ""
  @State private var muscleFilter: MuscleFilter = .all
  @State private var showArchived = false
  @State private var showNewDetail = false
  @State private var showLibrary = false

  // Three-state filter: All, an individual muscle, or the "Unassigned"
  // bucket (primaryMuscle == nil). Unassigned exists as a first-class
  // option so users can triage exercises the backfill missed in one tap.
  private enum MuscleFilter: Hashable {
    case all
    case unassigned
    case muscle(Muscle)
  }

  private var hasUnassigned: Bool {
    allExercises.contains { !$0.archived && $0.primaryMuscle == nil }
  }

  private var filtered: [ExerciseDefinitionEntity] {
    allExercises.filter { entity in
      guard showArchived || !entity.archived else { return false }
      switch muscleFilter {
      case .all:
        break
      case .unassigned:
        guard entity.primaryMuscle == nil else { return false }
      case .muscle(let m):
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
      muscleFilterStrip
      // Exercises live in their own Section so the grouped card's rounded
      // top lands on the first exercise row — otherwise the (clear-backed)
      // filter strip row consumes the rounding and the list reads square.
      Section {
        ForEach(filtered) { entity in
          NavigationLink {
            ExerciseStatsView(entity: entity)
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
  private var muscleFilterStrip: some View {
    // Wrapping flow rather than a horizontal scroll: 16 muscle groups don't
    // fit one row, and wrapping shows them all at a glance instead of hiding
    // half off-screen.
    FlowLayout(spacing: 8) {
      filterChip(label: "All", isSelected: muscleFilter == .all) {
        muscleFilter = .all
      }
      ForEach(Muscle.allCases) { muscle in
        filterChip(label: muscle.label,
                   isSelected: muscleFilter == .muscle(muscle)) {
          muscleFilter = muscleFilter == .muscle(muscle) ? .all : .muscle(muscle)
        }
      }
      // "Other" lives at the end as a low-pressure escape hatch for
      // exercises without a primary muscle (mobility, conditioning,
      // complexes). Only shown when there's at least one such row so it
      // doesn't appear on tidy catalogs.
      if hasUnassigned {
        filterChip(label: "Other", isSelected: muscleFilter == .unassigned) {
          muscleFilter = muscleFilter == .unassigned ? .all : .unassigned
        }
      }
    }
    .padding(.vertical, 6)
    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
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
    // Use the enum label (multi-word raw values like "frontDelts" don't
    // capitalize cleanly); fall back to the raw string for any legacy value.
    Text(Muscle.resolve(raw)?.label ?? raw.capitalized)
      .font(.caption2)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(isPrimary ? Color.secondary.opacity(0.25) : Color.secondary.opacity(0.12))
      .foregroundStyle(.secondary)
      .clipShape(Capsule())
  }
}
