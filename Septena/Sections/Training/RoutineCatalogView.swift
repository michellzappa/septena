import SwiftUI
import SwiftData

struct RoutineCatalogView: View {
  @Query(sort: [SortDescriptor(\SessionTypeEntity.sortIndex)])
  private var allRoutines: [SessionTypeEntity]

  @Environment(\.modelContext) private var context
  @State private var showArchived = false
  @State private var showNewDetail = false

  private var displayed: [SessionTypeEntity] {
    showArchived ? allRoutines : allRoutines.filter { !$0.archived }
  }

  var body: some View {
    List {
      ForEach(displayed) { entity in
        NavigationLink {
          RoutineDetailView(entity: entity)
        } label: {
          routineRow(entity)
        }
        .swipeActions(edge: .trailing) {
          if entity.archived {
            Button("Unarchive") {
              TrainingConfigStore.setSessionTypeArchived(id: entity.id, archived: false, context: context)
            }.tint(.blue)
          } else {
            Button("Archive") {
              TrainingConfigStore.setSessionTypeArchived(id: entity.id, archived: true, context: context)
            }.tint(.orange)
          }
        }
        .contextMenu {
          Button(role: .destructive) {
            TrainingConfigStore.deleteSessionType(id: entity.id, context: context)
          } label: {
            Label("Delete permanently", systemImage: "trash")
          }
        }
      }
      .onMove { from, to in
        var ids = displayed.map(\.id)
        ids.move(fromOffsets: from, toOffset: to)
        TrainingConfigStore.reorderSessionTypes(idsInOrder: ids, context: context)
      }
    }
    .navigationTitle("Routines")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button { showNewDetail = true } label: {
          Image(systemName: "plus")
        }
      }
      ToolbarItem(placement: .secondaryAction) {
        Toggle("Show archived", isOn: $showArchived)
      }
      #if os(iOS)
      ToolbarItem(placement: .navigationBarLeading) {
        EditButton()
      }
      #endif
    }
    .navigationDestination(isPresented: $showNewDetail) {
      RoutineDetailView(entity: nil)
    }
  }

  @ViewBuilder
  private func routineRow(_ entity: SessionTypeEntity) -> some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(entity.label)
          .foregroundStyle(entity.archived ? .secondary : .primary)
        Text("\(entity.exercises.count) exercises")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
  }
}
