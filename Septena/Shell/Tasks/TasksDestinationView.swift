import SwiftUI
import SwiftData

// Tasks drawer — the light, standardized surface that opens from the
// homepage Tasks tile, built on the same `SectionDrawer` chrome every
// other section uses. Glance at today, check things off, capture a new
// task. The deep areas / projects / scheduling surface still lives in the
// Tasks tab; this is its quick-access counterpart, and the two share the
// canonical `TaskRow` so a task looks identical wherever it appears.
//
// Replaces the old behaviour where the Tasks tile sheeted the entire
// `TaskListView(filter: .today)` monolith — see `TasksPlugin.destinationView()`.

struct TasksDestinationView: View {
  @Environment(TaskMutator.self) private var mutator
  @Environment(SectionTheme.self) private var theme
  @Environment(\.modelContext) private var modelContext
  @Environment(\.a11yMotion) private var motion
  @AppStorage(SettingsKey.todayShowCompleted) private var showCompleted: Bool = true

  /// Drives the "linger → fade" beat after a check (see `SettleStore`).
  @State private var settle = SettleStore()

  /// Open tasks routed into Today (pinned, or scheduled / deadline ≤ today).
  /// Mirrors `LocalCache.tasks(in:filter:.today)`; held in @State so we can
  /// apply optimistic edits in-session without waiting on the outbox.
  @State private var openTasks: [SeptenaTask] = []
  /// Tasks completed today, newest first. Gated on the "Show completed in
  /// Today" preference (shared with the Today log + Settings).
  @State private var doneTasks: [SeptenaTask] = []
  /// Areas / projects backing the edit sheet's "List" picker. Loaded once
  /// alongside the task lists so the modal can resolve and reassign a task's
  /// home the same way the full Tasks surface does.
  @State private var areas: [Area] = []
  @State private var projects: [Project] = []
  @State private var editing: SeptenaTask? = nil
  @State private var creating = false

  private var accent: Color { theme.color(for: "tasks") }

  var body: some View {
    SectionDrawer(sectionKey: "tasks",
                  title: "Tasks",
                  onLog: { _ in creating = true }) {
      if !openTasks.isEmpty {
        DrawerSection("Today", padding: .none) {
          ForEach(openTasks) { task in
            TaskRow(task: task,
                    accent: accent,
                    trailing: deadlineLabel(task),
                    trailingTint: isOverdue(task) ? Theme.overdueRed : nil,
                    onToggle: { toggle(task) },
                    onTap: { editing = task })
              .transition(.opacity)
          }
        }
      }
      if showCompleted, !doneTasks.isEmpty {
        DrawerSection("Done", padding: .none) {
          ForEach(doneTasks) { task in
            TaskRow(task: task,
                    accent: accent,
                    onToggle: { toggle(task) },
                    onTap: { editing = task })
          }
        }
      }
      if openTasks.isEmpty && doneTasks.isEmpty {
        DrawerSection {
          Text("Nothing for today yet. Tap + to add a task.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .tint(accent)
    .task { reload() }
    .modifier(DrawerTaskComposer(
      isOpen: composerBinding,
      composerIsOpen: composerIsOpen,
      card: { composerCard }
    ))
  }

  /// One liquid-glass composer for both add (the drawer's + / ⌘N, declared via
  /// TasksPlugin.logActions) and edit (row tap) — the same `TaskComposerCard`
  /// the Tasks tab uses. The drawer is a *pushed* screen, so an `.overlay`
  /// would clip the card to the drawer's bounds; on iOS we present it through a
  /// transparent `.fullScreenCover` instead, so the card floats over the whole
  /// app. (See `DrawerTaskComposer` for the macOS overlay fallback.)
  @ViewBuilder
  private var composerCard: some View {
    if let mode = composerMode {
      TaskComposerCard(
        mode: mode,
        areas: areas,
        projects: projects,
        accent: accent,
        onDismiss: closeComposer,
        onDone: { reload() }
      )
    }
  }

  /// The drawer is the Today drawer, so a new task defaults to Today; a row
  /// tap edits. The scrim blocks drawer taps while open, so the two modes are
  /// naturally mutually exclusive.
  private var composerMode: TaskComposerCard.Mode? {
    if creating { return .create(.today) }
    if let task = editing { return .edit(task) }
    return nil
  }
  private var composerIsOpen: Bool { creating || editing != nil }
  private var composerBinding: Binding<Bool> {
    Binding(get: { composerIsOpen }, set: { if !$0 { closeComposer() } })
  }
  private func closeComposer() {
    creating = false
    editing = nil
  }

  // MARK: - Data

  private func reload() {
    settle.cancelAll()
    areas = LocalCache.areas(in: modelContext)
    projects = LocalCache.projects(in: modelContext)
    openTasks = LocalCache.tasks(in: modelContext, filter: .today)
    guard showCompleted else { doneTasks = []; return }
    let today = SeptenaDate.today
    doneTasks = LocalCache.tasks(in: modelContext, filter: .logbook)
      .filter { ($0.completedAt ?? "").hasPrefix(today) }
      .sorted { ($0.completedAt ?? "") > ($1.completedAt ?? "") }
  }

  /// Optimistic toggle — routes through the mutator (outbox + CloudKit) and
  /// keeps the in-session arrays as the source of truth until the next appear
  /// (the local store write isn't guaranteed synchronous, so we don't reload).
  ///
  /// On complete the row doesn't vanish: it flips struck-through in place,
  /// lingers for the settle beat, then fades out of Today and lands at the top
  /// of Done (see `SettleStore`). Re-checking within the window cancels the
  /// fade. Reduce Motion drops the fade but keeps the delayed move.
  private func toggle(_ task: SeptenaTask) {
    Haptics.tick()
    if task.status == .done {
      // Uncomplete — abort any in-flight fade and restore to the open list,
      // whether the row is still settling in Today or already sitting in Done.
      mutator.uncomplete(id: task.id)
      settle.cancel(task.id)
      var reopened = task
      reopened.status = .open
      reopened.completedAt = nil
      motion.run(Theme.Motion.settle) {
        doneTasks.removeAll { $0.id == task.id }
        if let i = openTasks.firstIndex(where: { $0.id == task.id }) {
          openTasks[i] = reopened
        } else {
          openTasks.append(reopened)
        }
      }
    } else {
      // Complete — flip in place so the checkbox fills and the title strikes,
      // then schedule the fade-out into Done.
      mutator.complete(id: task.id)
      motion.run(Theme.Motion.settle) {
        if let i = openTasks.firstIndex(where: { $0.id == task.id }) {
          openTasks[i].status = .done
          openTasks[i].completedAt = SeptenaDate.today + "T00:00:00"
        }
      }
      settle.schedule(task.id) {
        motion.run(Theme.Motion.settle) {
          guard let i = openTasks.firstIndex(where: { $0.id == task.id }) else { return }
          let done = openTasks.remove(at: i)
          if showCompleted { doneTasks.insert(done, at: 0) }
        }
      }
    }
  }

  // MARK: - Row meta

  private func isOverdue(_ task: SeptenaTask) -> Bool {
    // Deadline-only, Things-style: a past *scheduled* date is just a plan that
    // rolled into Today, not an overdue task. See `SeptenaTask.isOverdue`.
    task.isOverdue
  }

  /// Trailing chip: the task's deadline rendered as "MMM d", or nil.
  private func deadlineLabel(_ task: SeptenaTask) -> String? {
    guard let deadline = task.deadline else { return nil }
    return Self.shortDate(deadline)
  }

  private static let isoParser: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()
  private static let shortFormatter: DateFormatter = {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("MMMd")
    return f
  }()
  private static func shortDate(_ iso: String) -> String {
    guard let date = isoParser.date(from: String(iso.prefix(10))) else { return iso }
    return shortFormatter.string(from: date)
  }
}

// MARK: - Composer presentation

/// Presents the drawer's task composer so it floats over the *whole app*, not
/// just the pushed drawer screen. iOS uses a transparent full-screen cover (the
/// card carries its own dim scrim); macOS — where full-screen covers aren't
/// available — falls back to an in-place overlay, which is fine on a roomy
/// window.
private struct DrawerTaskComposer<Card: View>: ViewModifier {
  @Binding var isOpen: Bool
  let composerIsOpen: Bool
  @ViewBuilder var card: () -> Card

  func body(content: Content) -> some View {
    #if os(iOS)
    content.fullScreenCover(isPresented: $isOpen) {
      card()
        .presentationBackground(.clear)
    }
    #else
    content
      .overlay { if composerIsOpen { card() } }
      .animation(.snappy(duration: 0.2), value: composerIsOpen)
    #endif
  }
}
