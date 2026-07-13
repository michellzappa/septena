import SwiftUI

// Context-aware task creation. Inspects the current route to derive a
// default destination — Today filter → `today: true`, Project view →
// `project: <id>`, etc. The "Adding to <label>" line is pinned at top so
// the user can verify before committing.

private enum TaskBucket {
  case inbox
  case today
  case upcoming
  case area(String)
  case project(String)
}

struct AddTaskPage: View {
  @Environment(NavigationState.self) private var nav
  @Environment(TaskMutator.self) private var mutator
  @Environment(SectionTheme.self) private var theme
  @Environment(DayClock.self) private var clock
  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @Bindable var router: AddInfoRouter
  @State private var todays: [SeptenaTask] = []
  @State private var working = false

  private var bucket: TaskBucket {
    guard let last = nav.path.last else { return .inbox }
    switch last {
    case .filter(let f):
      switch f {
      case .today:    return .today
      case .upcoming: return .upcoming
      default:        return .inbox
      }
    case .project(let id): return .project(id)
    case .area(let id):    return .area(id)
    case .next:           return .inbox
    }
  }

  private var bucketLabel: String {
    switch bucket {
    case .inbox: return "Inbox"
    case .today: return "Today"
    case .upcoming: return "Upcoming"
    case .area(let id):
      return LocalCache.areas(in: modelContext).first(where: { $0.id == id })?.title ?? "Area"
    case .project(let id):
      return LocalCache.projects(in: modelContext).first(where: { $0.id == id })?.title ?? "Project"
    }
  }

  private var trimmed: String {
    router.query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Quick capture deliberately has less UI than the full editor, but it must
  /// derive defaults and persist through the exact same draft contract.
  private var taskFilter: TaskFilter {
    switch bucket {
    case .inbox:           return .triage
    case .today:           return .today
    case .upcoming:        return .upcoming
    case .area(let id):    return .area(id)
    case .project(let id): return .project(id)
    }
  }

  var body: some View {
    let tint = AddInfoSection.tasks.accent(theme: theme)
    List {
      Section {
        HStack(spacing: 6) {
          Text("Adding to").foregroundStyle(.secondary)
          Text(bucketLabel).fontWeight(.medium)
          Spacer()
        }
        .font(.footnote)
      }

      if !trimmed.isEmpty {
        Section {
          Button { commit(title: trimmed) } label: {
            AddInfoRow(
              title: "Add: “\(trimmed)”",
              subtitle: bucketLabel,
              systemImage: "plus.circle.fill",
              tint: tint
            )
          }
          .buttonStyle(.plain)
          .disabled(working)
        }
      }

      let filtered = todays.filter { matches($0.title) }
      if !filtered.isEmpty {
        Section("Today") {
          ForEach(filtered) { task in
            Button { pull(task) } label: {
              AddInfoRow(
                title: task.title,
                subtitle: task.area ?? "Today",
                systemImage: task.isOnToday ? "circle.inset.filled" : "circle",
                tint: tint
              )
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
    .task { await loadTodays() }
    #if os(iOS)
    .listStyle(.insetGrouped)
    #endif
  }

  private func matches(_ s: String) -> Bool {
    trimmed.isEmpty || s.localizedCaseInsensitiveContains(trimmed)
  }

  private func commit(title: String) {
    guard !working else { return }
    var draft = TaskDraft(filter: taskFilter)
    draft.title = title
    draft.create(via: mutator)
    AddInfoSection.tasks.notifyTilesChanged()
    Haptics.tick()
    dismiss()
  }

  private func pull(_ task: SeptenaTask) {
    if task.isOnToday {
      mutator.complete(id: task.id)
    } else {
      mutator.moveToToday(id: task.id)
    }
    AddInfoSection.tasks.notifyTilesChanged()
    Haptics.tick()
    dismiss()
  }

  private func loadTodays() async {
    let resp = await TaskReads.list(
      view: "today",
      today: clock.today,
      now: clock.now,
      context: LocalStore.shared.container.mainContext
    )
    todays = resp.items.filter { $0.status == .open }
  }
}
