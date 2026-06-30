import SwiftUI

// Context-aware task creation. Inspects the current route to derive a
// default destination — Today filter → `today: true`, Project view →
// `project: <id>`, etc. The "Adding to <label>" line is pinned at top so
// the user can verify before committing.

private enum TaskBucket {
  case inbox
  case today
  case upcoming
  case area(Area)
  case project(Project)

  var label: String {
    switch self {
    case .inbox:               return "Inbox"
    case .today:               return "Today"
    case .upcoming:            return "Upcoming"
    case .area(let a):         return a.title
    case .project(let p):      return p.title
    }
  }
}

struct AddTaskPage: View {
  @Environment(NavigationState.self) private var nav
  @Environment(TaskMutator.self) private var mutator
  @Environment(SectionTheme.self) private var theme
  @Environment(DayClock.self) private var clock
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
    case .project(let p): return .project(p)
    case .area(let a):    return .area(a)
    case .next:           return .inbox
    }
  }

  private var trimmed: String {
    router.query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    let tint = AddInfoSection.tasks.accent(theme: theme)
    List {
      Section {
        HStack(spacing: 6) {
          Text("Adding to").foregroundStyle(.secondary)
          Text(bucket.label).fontWeight(.medium)
          Spacer()
        }
        .font(.footnote)
      }

      if !trimmed.isEmpty {
        Section {
          Button { commit(title: trimmed) } label: {
            AddInfoRow(
              title: "Add: “\(trimmed)”",
              subtitle: bucket.label,
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
    let scheduled: Date? = {
      if case .upcoming = bucket {
        return Calendar.current.date(byAdding: .day, value: 1, to: .now)
      }
      return nil
    }()
    let today: Bool = { if case .today = bucket { return true }; return false }()
    let area: String? = { if case .area(let a) = bucket { return a.id }; return nil }()
    let project: String? = { if case .project(let p) = bucket { return p.id }; return nil }()
    mutator.create(
      title: title,
      area: area,
      project: project,
      scheduled: scheduled,
      today: today
    )
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
