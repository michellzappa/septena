import SwiftUI
import SwiftData

/// Waiting On… (`task.waitingOn`, docs/REVIEW_SPEC.md §6): who the task waits
/// on and the day to check back, which is the task's When date. A new wait
/// offers today + `RegistryWaiting.defaultCheckBackDays`; an edit opens with
/// the current name and When date. "No date" clears the When date.
/// The AppKit shell draws the same fields in `SeptaskKitWaitingPopover`.
struct WaitingOnSheet: View {
  let task: SeptenaTask
  /// The caller's `DayClock.today`.
  let today: String
  /// The name, then the check-back day (nil = No date).
  let onSave: (String, Date?) -> Void

  @Environment(\.dismiss) private var dismiss
  @FocusState private var nameFocused: Bool
  @State private var name: String
  @State private var checkBack: Date
  @State private var noDate: Bool

  init(task: SeptenaTask, today: String, onSave: @escaping (String, Date?) -> Void) {
    self.task = task
    self.today = today
    self.onSave = onSave
    let initial = WaitingOnSheet.initialCheckBack(task: task, today: today)
    _name = State(initialValue: task.waitingOn ?? "")
    _checkBack = State(initialValue: initial ?? SeptenaDate.parse(today) ?? DayClock.appNow)
    _noDate = State(initialValue: initial == nil)
  }

  /// An edit keeps the task's When date; a new wait offers the default.
  static func initialCheckBack(task: SeptenaTask, today: String) -> Date? {
    task.isWaiting ? SeptenaDate.parse(task.scheduled) : TaskWaiting.defaultCheckBack(today: today)
  }

  private var trimmed: String? { TaskWaiting.normalizedName(name) }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField(RegistryWaiting.namePlaceholder, text: $name)
            .focused($nameFocused)
            .submitLabel(.done)
            .onSubmit(save)
        }
        Section {
          Toggle(RegistryWaiting.noCheckBackTitle, isOn: $noDate)
          if !noDate {
            DatePicker(RegistryWaiting.checkBackTitle, selection: $checkBack,
                       in: (SeptenaDate.parse(today) ?? .distantPast)...,
                       displayedComponents: .date)
          }
        }
      }
      .navigationTitle(RegistryWaiting.sheetTitle)
      .septenaInlineTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          DrawerCloseButton { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(RegistryWaiting.confirmTitle, action: save)
            .disabled(trimmed == nil)
        }
      }
    }
    .macSheetFrame(width: 380, height: 300)
    .onAppear { nameFocused = true }
  }

  private func save() {
    guard let trimmed else { return }
    onSave(trimmed, noDate ? nil : checkBack)
    dismiss()
  }
}

/// The gestures every SwiftUI surface calls for Waiting On… and Got It Back.
/// Undo is recorded here, at the gesture (`TaskUndo.setWaiting`).
@MainActor
enum TaskWaitingActions {
  private static var mutator: TaskMutator { SeptenaServices.shared.taskMutator }
  private static var context: ModelContext { LocalStore.shared.container.mainContext }

  /// Save the sheet. When changes only when the day differs from the task's.
  static func save(task: SeptenaTask, name: String, checkBack: Date?) {
    let day = SeptenaDate.format(checkBack)
    let scheduled: Date?? = day == task.scheduled ? nil : .some(checkBack)
    Haptics.commit()
    TaskUndo.setWaiting(id: task.id, on: name, scheduled: scheduled,
                        context: context, mutator: mutator)
  }

  /// Got It Back on the waiting tasks among `ids`.
  static func gotItBack(ids: [String]) {
    Haptics.commit()
    TaskUndo.gotItBack(ids: ids, context: context, mutator: mutator)
  }
}

/// The task page's wait (docs/REVIEW_SPEC.md §6): "Waiting on Anna · 5 days"
/// with Got It Back and Waiting On…, or only Waiting On… for a task that does
/// not wait. Titles and icons come from the registry actions.
struct TaskWaitingStrip: View {
  let task: SeptenaTask
  /// False hides Waiting On… on a task that does not wait (the review depth).
  var offersNewWait: Bool = true

  @Environment(DayClock.self) private var clock
  /// The task as the last action here left it: the page's own copy can lag
  /// a reload behind.
  @State private var live: SeptenaTask?
  @State private var showingSheet = false

  private var current: SeptenaTask { live?.id == task.id ? live ?? task : task }

  var body: some View {
    let task = current
    HStack(spacing: Theme.iconTextGap) {
      if let label = task.waitingLabel(today: clock.today) {
        Label(label, systemImage: RegistryIcons.sfSymbol(for: "action.waiting"))
          .font(.septenaMeta)
          .foregroundStyle(Theme.inkSecondary)
        Spacer(minLength: 8)
        Button(RegistryActions.title(.taskGotItBack)) {
          TaskWaitingActions.gotItBack(ids: [task.id])
          refresh()
        }
        .buttonStyle(.bordered)
        Button {
          showingSheet = true
        } label: {
          Image(systemName: "pencil")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(RegistryActions.title(.taskWaitingOn))
      } else if offersNewWait {
        Button {
          showingSheet = true
        } label: {
          Label(RegistryActions.title(.taskWaitingOn), systemImage: RegistryIcons.sfSymbol(for: "action.waiting"))
            .font(.septenaMeta)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.inkSecondary)
        Spacer(minLength: 0)
      }
    }
    .sheet(isPresented: $showingSheet) {
      WaitingOnSheet(task: task, today: clock.today) { name, checkBack in
        TaskWaitingActions.save(task: task, name: name, checkBack: checkBack)
        refresh()
      }
      .taskPickerChrome(TaskPickerDetents.standard)
    }
  }

  private func refresh() {
    live = LocalCache.task(id: task.id, in: LocalStore.shared.container.mainContext)
  }
}
