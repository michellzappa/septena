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
  /// True when this page is the whole quick-add (Septask's sheet): it then
  /// owns its own focused title field and Cancel / Add toolbar. False under
  /// Septena's `AddInfoSheet`, which feeds `router.query` from its `.searchable`
  /// bar and owns the chrome.
  var hostsTitleField: Bool = false
  /// File every capture to the Inbox instead of deriving a list from the
  /// current route (Septask's quick add is a pure Inbox capture).
  var forcesInbox: Bool = false
  @State private var todays: [SeptenaTask] = []
  @State private var working = false
  @FocusState private var titleFocused: Bool

  init(router: AddInfoRouter, hostsTitleField: Bool = false, forcesInbox: Bool = false) {
    self._router = Bindable(router)
    self.hostsTitleField = hostsTitleField
    self.forcesInbox = forcesInbox
  }

  private var bucket: TaskBucket {
    if forcesInbox { return .inbox }
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
    case .inbox: return TaskFilter.triage.title
    case .today: return TaskFilter.today.title
    case .upcoming: return TaskFilter.upcoming.title
    case .area(let id):
      return LocalCache.areas(in: modelContext).first(where: { $0.id == id })?.title ?? TaskFilter.area(id).title
    case .project(let id):
      return LocalCache.projects(in: modelContext).first(where: { $0.id == id })?.title ?? TaskFilter.project(id).title
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
      if hostsTitleField {
        Section {
          // Return adds. One line: a capture is a title, details come later.
          TextField(RegistryActions.title("app.newTask"), text: $router.query)
            .focused($titleFocused)
            .submitLabel(.done)
            .onSubmit { if !trimmed.isEmpty { commit(title: trimmed) } }
        }
      }

      Section {
        HStack(spacing: 6) {
          Text("Adding to").foregroundStyle(.secondary)
          Text(bucketLabel).fontWeight(.medium)
          Spacer()
        }
        .font(.footnote)
      }

      if !hostsTitleField, !trimmed.isEmpty {
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
            if task.isOnToday {
              // Already on Today: shown so you don't add a duplicate. Not a
              // button. A plain tap here used to COMPLETE the task, an action
              // nothing on the row announced.
              AddInfoRow(
                title: task.title,
                subtitle: "Already on Today",
                systemImage: "circle.inset.filled",
                tint: tint
              )
            } else {
              // Due or rolled in but not pinned: the one action is to pin it,
              // and the row says so.
              Button { pullToToday(task) } label: {
                AddInfoRow(
                  title: task.title,
                  subtitle: RegistryActions.title("task.toggleToday", .add),
                  systemImage: "circle",
                  tint: tint
                )
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          }
        }
      }
    }
    .task { await loadTodays() }
    #if os(iOS)
    .listStyle(.insetGrouped)
    #endif
    .toolbar {
      if hostsTitleField {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Add") { commit(title: trimmed) }
            .disabled(trimmed.isEmpty || working)
        }
      }
    }
    .onAppear {
      guard hostsTitleField else { return }
      // Focus after the sheet settles: an immediate focus is dropped before
      // the field joins the responder chain, so the keyboard would not rise.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { titleFocused = true }
    }
  }

  private func matches(_ s: String) -> Bool {
    trimmed.isEmpty || s.localizedCaseInsensitiveContains(trimmed)
  }

  private func commit(title: String) {
    guard !working, !title.isEmpty else { return }
    working = true
    var draft = TaskDraft(filter: taskFilter)
    draft.title = title
    let created = draft.create(via: mutator)
    let saved = draft
    TaskUndo.recordCreate(
      name: RegistryActions.title("app.newTask"),
      ids: [created.id], mutator: mutator,
      rebuild: { [mutator] in [saved.create(via: mutator).id] })
    AddInfoSection.tasks.notifyTilesChanged()
    Haptics.tick()
    dismiss()
  }

  private func pullToToday(_ task: SeptenaTask) {
    let before = TaskUndo.ScheduleSnapshot(task)
    mutator.apply(.putOnToday, to: task.id)
    TaskUndo.recordScheduleChange(
      name: RegistryActions.title("task.toggleToday", .add),
      before: [before], context: modelContext, mutator: mutator)
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
