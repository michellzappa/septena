import SwiftUI

// The shared per-row action surface: the context menu, its modal presenter,
// and the `.taskRowActions` entry point every task row attaches. Split out of
// TaskComponents.swift.

// MARK: - Shared per-row task actions

/// The full task context menu + its picker sheets, bundled into one modifier so
/// any surface (the Tasks list, the Next feed) attaches the *same* menu — Edit
/// Details…, Move to / Remove from Today, Schedule (When… / Deadline…), Move,
/// Repeat…, Duplicate, Cancel, Delete. The menu body is `TaskListRowContextMenu` and the sheets are
/// `TaskListModalPresenter`, both shared with `TaskListView`, so the two
/// surfaces can't drift. Which picker is open is owned per-row.
///
/// Mutations go straight through `TaskMutator`; the surface refreshes off the
/// mutator's change notifications (same as the row's checkbox), so no explicit
/// reload is threaded here. The Inbox "file here" suggestions are a
/// Tasks-list-only affordance and stay nil elsewhere.
struct TaskRowActions: ViewModifier {
  let task: SeptenaTask
  var filter: TaskFilter = .today
  var areas: [Area] = []
  var projects: [Project] = []
  let mutator: TaskMutator
  /// Opens the task's edit / agent composer ("Edit Details…"). nil hides it.
  var onOpenDetail: ((SeptenaTask) -> Void)? = nil
  /// Fired after a menu mutation that can change which list a row belongs to
  /// (remove-from-today, reschedule, move, cancel, delete). Surfaces that hold
  /// their task arrays in @State — like the Tasks drawer — pass a reload here so
  /// the row leaves in real time. Surfaces that already refresh off
  /// `.septenaTasksChanged` (the full `TaskListView`) leave it nil.
  var onChange: (() -> Void)? = nil

  @State private var whenSheet: TaskListView.WhenSheet?
  @State private var showingMoveSheet = false
  @State private var moveTargetIds: [String] = []
  @State private var showingRepeatSheet = false
  @State private var repeatTargetId: String?
  @State private var reminderTargetId: String?
  @State private var tagsTargetIds: [String] = []

  @Environment(PromoteFlashStore.self) private var promoteFlash
  @Environment(\.septenaToast) private var toastStore
  @Environment(\.modelContext) private var modelContext

  // MARK: - Undo
  //
  // This menu is the SHARED per-row action surface, so every mutation it makes
  // has to land on the one shared stack (`TaskUndo`) — otherwise ⌘Z / shake
  // works on the deep Tasks list (which records) and silently does nothing
  // after the same gesture from a row menu on Next, a drawer, or the Septask
  // rows. Recording is explicit and sits at the GESTURE, never inside the
  // mutator (see `TaskUndo` for why).

  /// Scheduling fields as they stand right now, read from the store — the same
  /// source `TaskUndo.recordScheduleChange` re-reads for the redo side, so the
  /// two halves can't disagree.
  private func scheduleSnapshots(_ ids: [String]) -> [TaskUndo.ScheduleSnapshot] {
    LocalCache.liveTasks(ids: ids, in: modelContext)
      .map(TaskUndo.ScheduleSnapshot.init)
  }

  /// Run `body` and register the scheduling change it made.
  private func recordingSchedule(_ name: String, _ ids: [String], _ body: () -> Void) {
    let before = scheduleSnapshots(ids)
    body()
    TaskUndo.recordScheduleChange(name: name, before: before,
                                  context: modelContext, mutator: mutator)
  }

  func body(content: Content) -> some View {
    content
      .taskRowSwipeActions(
        id: task.id,
        leading: swipeLeadingActions,
        allowsLeadingFullSwipe: true,
        trailing: swipeTrailingActions,
        allowsTrailingFullSwipe: false
      )
      .contextMenu {
        TaskListRowContextMenu(
          target: .single(task),
          filter: filter,
          rankedSuggestions: nil,
          onDuplicate: { _ in duplicateTask(task) },
          onOpenDetail: { onOpenDetail?($0) },
          onApplySuggestion: { _, _ in },
          onMoveToToday: { ids, today in
            Haptics.tick()
            recordingSchedule(today
                                ? RegistryActions.title("task.toggleToday", .add)
                                : RegistryActions.title("task.toggleToday", .remove),
                              ids) {
              if today {
                for id in ids {
                  mutator.apply(.putOnToday, to: id)
                  promoteFlash.flash(id)
                }
              } else {
                for id in ids { mutator.apply(.removeFromToday, to: id) }
              }
            }
            onChange?()
          },
          onToggleStar: { ids, starred in
            Haptics.tick()
            recordingSchedule(starred
                              ? RegistryActions.title("task.toggleStar", .add)
                              : RegistryActions.title("task.toggleStar", .remove),
                              ids) {
              for id in ids { mutator.setStarred(id: id, starred: starred) }
            }
            onChange?()
          },
          onToggleComplete: { ids in
            let wasDone = task.status == .done
            Haptics.tick()
            for id in ids {
              if wasDone { mutator.uncomplete(id: id) } else { mutator.complete(id: id) }
              mutator.acknowledge(id: id)
            }
            TaskUndo.recordCompletion(ids: ids, wasDone: wasDone, mutator: mutator)
            onChange?()
          },
          onOpenWhen: { target in
            whenSheet = .init(taskIds: target.ids, kind: .scheduled)
          },
          onOpenDeadline: { target in
            whenSheet = .init(taskIds: target.ids, kind: .deadline)
          },
          onOpenReminder: { t in
            reminderTargetId = t.id
          },
          onOpenTags: { target in
            tagsTargetIds = target.ids
          },
          onClearSchedule: { ids in
            Haptics.tick()
            recordingSchedule(RegistryActions.title("task.clearSchedule"), ids) {
              for id in ids { mutator.apply(.clearWhen, to: id) }
            }
            onChange?()
          },
          onOpenMove: { target in
            moveTargetIds = target.ids
            showingMoveSheet = true
          },
          onMoveTo: { target, areaId, projectId in
            for id in target.ids { applyMove(id: id, areaId: areaId, projectId: projectId) }
          },
          moveAreas: areas,
          moveTopProjects: projects.filter { $0.area == nil && $0.status == .active },
          onOpenRepeat: { t in repeatTargetId = t.id; showingRepeatSheet = true },
          onSetRepeatPaused: { ids, paused in
            Haptics.tick()
            recordingSchedule(String(localized: "Change Repeat", comment: "Undo action name"),
                              ids) {
              for id in ids { mutator.setRecurrencePaused(id: id, paused: paused) }
            }
            onChange?()
          },
          onCreateNextCopy: { t in
            Haptics.tick()
            if let copy = mutator.createNextOccurrence(id: t.id) {
              TaskUndo.recordCreate(
                name: RegistryActions.title("task.createNextCopy"),
                ids: [copy.id], mutator: mutator,
                rebuild: { [mutator] in
                  mutator.createNextOccurrence(id: t.id).map { [$0.id] } ?? []
                })
            }
            onChange?()
          },
          onCancel: { ids in
            Haptics.warning()
            for id in ids { mutator.cancel(id: id) }
            TaskUndo.recordCancel(ids: ids, mutator: mutator)
            onChange?()
          },
          onDelete: { _ in applyDelete(task) }
        )
      }
      .modifier(TaskListModalPresenter(
        whenSheet: $whenSheet,
        showingMoveSheet: $showingMoveSheet,
        moveTargetIds: $moveTargetIds,
        showingRepeatSheet: $showingRepeatSheet,
        repeatTargetId: $repeatTargetId,
        reminderTargetId: $reminderTargetId,
        tagsTargetIds: $tagsTargetIds,
        areas: areas,
        projects: projects,
        currentTask: { _ in task },
        currentScheduled: { _ in task.scheduled.flatMap(SeptenaDate.parse) },
        currentDeadline: { _ in task.deadline.flatMap(SeptenaDate.parse) },
        currentRecurrence: { _ in task.recurrence },
        applyWhen: { ids, kind, date in
          for id in ids { applyWhen(id: id, kind: kind, date: date) }
        },
        applyMove: { ids, areaId, projectId in
          for id in ids { applyMove(id: id, areaId: areaId, projectId: projectId) }
        },
        applyRecurrence: { id, rule in
          Haptics.tick()
          recordingSchedule(String(localized: "Change Repeat", comment: "Undo action name"),
                            [id]) {
            mutator.setRecurrence(id: id, recurrence: rule)
          }
          onChange?()
        },
        applyRecurrencePaused: { id, paused in
          Haptics.tick()
          recordingSchedule(String(localized: "Change Repeat", comment: "Undo action name"),
                            [id]) {
            mutator.setRecurrencePaused(id: id, paused: paused)
          }
          onChange?()
        },
        applyReminder: { id, reminder in
          Haptics.tick()
          recordingSchedule(String(localized: "Change Reminder", comment: "Undo action name"),
                            [id]) {
            mutator.setReminder(id: id, reminder: reminder)
          }
          onChange?()
        }
      ))
  }

  // The field rules live in `TaskDateActions` (spec §4: A1, A2, A5, A7);
  // this only picks the undo name and the feedback.
  private func applyWhen(id: String, kind: TaskListView.WhenKind, date: Date?) {
    Haptics.tick()
    let name = kind == .deadline
      ? String(localized: "Set Deadline", comment: "Undo action name")
      : String(localized: "Schedule Task", comment: "Undo action name")
    recordingSchedule(name, [id]) {
      switch kind {
      case .deadline:
        mutator.apply(.setDeadline(date), to: id)
      case .scheduled:
        if let d = date {
          mutator.apply(.scheduleFor(d), to: id)
          if let iso = SeptenaDate.format(d), iso <= SeptenaDate.today {
            promoteFlash.flash(id)
          } else {
            toastStore?.show(RegistryToasts.deferred(to: d))
          }
        } else {
          mutator.apply(.clearWhenDate, to: id)
        }
      }
    }
    onChange?()
  }

  private func duplicateTask(_ task: SeptenaTask) {
    Haptics.tick()
    let copy = mutator.duplicate(task)
    TaskUndo.recordCreate(name: String(localized: "Duplicate Task", comment: "Undo action name"),
                          ids: [copy.id], mutator: mutator,
                          rebuild: { [mutator] in [mutator.duplicate(task).id] })
    onChange?()
  }

  // Mirrors `TaskListView.applyMove`, minus the Inbox suggestion-rejection
  // bookkeeping (no classifier on surfaces that use this).
  private func applyMove(id: String, areaId: String?, projectId: String?) {
    let undoBefore = LocalCache.liveTasks(ids: [id], in: modelContext)
      .map(TaskUndo.FilingSnapshot.init)
    // Already there: a no-op, so no write, no toast and no undo step.
    guard let current = undoBefore.first else { return }
    let alreadyThere = projectId.map { current.project == $0 }
      ?? (current.project == nil && current.area == areaId)
    guard !alreadyThere else { return }
    Haptics.tick()
    // One save, the same call the Tasks list and the AppKit shell make.
    mutator.moveToList(id: id, area: areaId, project: projectId)
    mutator.acknowledge(id: id)
    // The toast's own Undo button stays — it's the discoverable affordance on
    // iOS. It reverses through the SAME stack entry (via the ticket), so the
    // toast and ⌘Z / shake can never disagree or both fire.
    TaskUndo.recordMove(before: undoBefore, context: modelContext, mutator: mutator)
    let ticket = TaskUndoTicket()
    onChange?()
    let destName =
      projectId.flatMap { pid in projects.first { $0.id == pid }?.title }
      ?? areaId.flatMap { aid in areas.first { $0.id == aid }?.title }
      ?? TaskFilter.triage.title
    toastStore?.show(RegistryToasts.moved(destination: destName)) {
      ticket.undo { TaskUndo.restore(undoBefore, using: mutator) }
      onChange?()
    }
  }

  /// Agent proposals swap the Today slot for Accept and Delete for Dismiss;
  /// everything else is the registry's `swipeActions` slots.
  private var isProposal: Bool {
    task.source == TaskSource.mcp && task.acknowledgedAt == nil
  }

  private var swipeLeadingActions: [TaskRowSwipeAction] {
    TaskRowSwipeAction.leading { id in
      switch id {
      case "task.toggleToday":
        if isProposal {
          return TaskRowSwipeAction(
            id: "accept",
            title: String(localized: "Accept", comment: "Swipe action accept agent proposal"),
            systemImage: "checkmark",
            tint: .green
          ) { moveToToday() }
        }
        if task.isOnToday {
          return .registry(id, variant: .remove,
                           systemImage: RegistryIcons.sfSymbol(for: "action.today_remove"),
                           tint: .gray) {
            Haptics.tick()
            recordingSchedule(RegistryActions.title(id, .remove), [task.id]) {
              mutator.apply(.removeFromToday, to: task.id)
            }
            onChange?()
          }
        }
        return .registry(id, tint: TaskRowSwipeAction.tint(for: id)) { moveToToday() }
      case "task.when":
        return .registry(id, tint: TaskRowSwipeAction.tint(for: id)) {
          whenSheet = .init(taskIds: [task.id], kind: .scheduled)
        }
      default:
        return nil
      }
    }
  }

  private func moveToToday() {
    Haptics.tick()
    recordingSchedule(RegistryActions.title("task.toggleToday", .add), [task.id]) {
      mutator.apply(.putOnToday, to: task.id)
      promoteFlash.flash(task.id)
    }
    onChange?()
  }

  private var swipeTrailingActions: [TaskRowSwipeAction] {
    TaskRowSwipeAction.trailing { id in
      switch id {
      case "task.delete":
        if isProposal {
          return TaskRowSwipeAction(
            id: id,
            title: String(localized: "Dismiss", comment: "Swipe action dismiss agent proposal"),
            systemImage: RegistryActions.sfSymbols[id] ?? "trash",
            tint: .red,
            role: .destructive
          ) { applyDelete(task) }
        }
        return .registry(id, tint: TaskRowSwipeAction.tint(for: id)) { applyDelete(task) }
      case "task.move":
        return .registry(id, tint: TaskRowSwipeAction.tint(for: id)) {
          moveTargetIds = [task.id]
          showingMoveSheet = true
        }
      default:
        return nil
      }
    }
  }

  private func applyDelete(_ task: SeptenaTask) {
    Haptics.warning()
    let title = task.title
    mutator.delete(id: task.id)
    TaskUndo.recordDelete(ids: [task.id], mutator: mutator)
    let ticket = TaskUndoTicket()
    onChange?()
    let id = task.id
    toastStore?.show(RegistryToasts.deletedSingle(title: title)) {
      ticket.undo { mutator.restore(id: id) }
      onChange?()
    }
  }
}

extension View {
  /// Attach the shared task context menu + picker sheets to a row — see
  /// `TaskRowActions`. Use this anywhere a task row appears so the menu stays
  /// identical to the Tasks list.
  func taskRowActions(task: SeptenaTask,
                      filter: TaskFilter = .today,
                      areas: [Area] = [],
                      projects: [Project] = [],
                      mutator: TaskMutator,
                      onOpenDetail: ((SeptenaTask) -> Void)? = nil,
                      onChange: (() -> Void)? = nil) -> some View {
    modifier(TaskRowActions(task: task, filter: filter, areas: areas,
                            projects: projects, mutator: mutator,
                            onOpenDetail: onOpenDetail, onChange: onChange))
  }
}

// MARK: - Toast undo

/// Lets an undo toast reverse ITS OWN action, never whatever happens to be on
/// top of the shared stack.
///
/// A toast used to call `TaskUndo.undo()`, which undoes the NEWEST entry. If
/// anything was recorded after the toast's action (another completion, a
/// rename), tapping the toast's Undo took back that newer action and left the
/// toast's own one in place.
///
/// Create the ticket right AFTER recording the action. While nothing newer has
/// touched the stack, `undo` goes through `TaskUndo.undo()` so the toast and
/// shake / ⌘Z stay one stack. Once anything newer registers (or an undo / redo
/// runs), `undo` runs `fallback` instead: a direct reversal through the
/// mutators.
@MainActor
final class TaskUndoTicket {
  private let actionName: String
  private var isNewest = true
  nonisolated(unsafe) private var observer: NSObjectProtocol?

  init() {
    actionName = TaskUndo.undoActionName
    // Registered after the caller's `record`, whose own `changed` post has
    // already gone out, so only LATER stack changes reach this.
    observer = NotificationCenter.default.addObserver(
      forName: TaskUndo.changed, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.isNewest = false }
    }
  }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  func undo(fallback: () -> Void) {
    if isNewest, TaskUndo.canUndo, TaskUndo.undoActionName == actionName {
      TaskUndo.undo()
    } else {
      fallback()
    }
    isNewest = false
  }
}

// MARK: - iOS task-row swipe actions (docs/IOS_SWIPE_ACTIONS_SPEC.md)

/// A single swipe action button revealed when swiping a task row on iOS/iPadOS,
/// and mirrored as a VoiceOver `.accessibilityAction` on all platforms.
struct TaskRowSwipeAction: Identifiable {
  let id: String
  let title: String
  let systemImage: String
  let tint: Color
  var role: ButtonRole? = nil
  let perform: () -> Void
}

extension TaskRowSwipeAction {
  /// A swipe button for a registry action: its title (the short swipe title
  /// when the registry has one), icon and role come from `registry/actions.json`.
  /// The shell supplies only the tint and the handler.
  static func registry(_ id: String, variant: RegistryTitleVariant? = nil,
                       systemImage: String? = nil, tint: Color,
                       perform: @escaping () -> Void) -> TaskRowSwipeAction {
    let title = variant.map { RegistryActions.title(id, $0) }
      ?? RegistryActions.alternateTitles[id]?[RegistryTitleVariant.short.rawValue]
      ?? RegistryActions.title(id)
    return TaskRowSwipeAction(
      id: id,
      title: title,
      systemImage: systemImage ?? RegistryActions.sfSymbols[id] ?? "circle",
      tint: tint,
      role: RegistryActions.destructive.contains(id) ? .destructive : nil,
      perform: perform)
  }

  /// The leading swipe buttons the registry slots name, outermost first.
  static func leading(_ make: (String) -> TaskRowSwipeAction?) -> [TaskRowSwipeAction] {
    RegistryActions.swipeLeading.compactMap(make)
  }

  /// The trailing swipe buttons, outermost first. The registry lists them in
  /// screen order, so the outermost (the right edge) is the last one.
  static func trailing(_ make: (String) -> TaskRowSwipeAction?) -> [TaskRowSwipeAction] {
    RegistryActions.swipeTrailing.reversed().compactMap(make)
  }

  /// The swipe tint for a registry action, one per action on every surface.
  static func tint(for id: String) -> Color {
    switch id {
    case "task.toggleToday": return .orange
    case "task.when": return .indigo
    case "task.move": return .blue
    case "task.delete", "task.deletePermanently": return .red
    case "task.restore": return .green
    case "task.keepFaded": return .blue
    case "task.letGoFaded": return .orange
    default: return .gray
    }
  }
}

extension Notification.Name {
  /// Posted with the opened row's `id` (`String`) so any other revealed row
  /// snaps closed when a new row is swiped open.
  static let septenaSwipeRowOpened = Notification.Name("septenaSwipeRowOpened")
}

extension View {
  /// Attach iOS/iPadOS horizontal swipe actions to a row hosted inside
  /// `SelectableScrollList` (a `ScrollView`/`LazyVStack`, where SwiftUI's
  /// `List`-only `.swipeActions` does not attach) and mirror every action as a
  /// VoiceOver `.accessibilityAction` across all platforms.
  func taskRowSwipeActions(id: String,
                           enabled: Bool = true,
                           leading: [TaskRowSwipeAction] = [],
                           allowsLeadingFullSwipe: Bool = true,
                           trailing: [TaskRowSwipeAction] = [],
                           allowsTrailingFullSwipe: Bool = false) -> some View {
    modifier(TaskRowSwipeActionsModifier(
      rowID: id,
      enabled: enabled,
      leading: leading,
      allowsLeadingFullSwipe: allowsLeadingFullSwipe,
      trailing: trailing,
      allowsTrailingFullSwipe: allowsTrailingFullSwipe
    ))
  }
}

private struct TaskRowSwipeActionsModifier: ViewModifier {
  let rowID: String
  let enabled: Bool
  let leading: [TaskRowSwipeAction]
  let allowsLeadingFullSwipe: Bool
  let trailing: [TaskRowSwipeAction]
  let allowsTrailingFullSwipe: Bool

  func body(content: Content) -> some View {
    let base = content
      .modifier(SwipeAccessibilityActionsModifier(
        enabled: enabled,
        actions: leading + trailing
      ))
    #if os(iOS)
    if enabled && (!leading.isEmpty || !trailing.isEmpty) {
      TaskRowSwipeContainer(
        rowID: rowID,
        leading: leading,
        allowsLeadingFullSwipe: allowsLeadingFullSwipe,
        trailing: trailing,
        allowsTrailingFullSwipe: allowsTrailingFullSwipe
      ) {
        base
      }
    } else {
      base
    }
    #else
    base
    #endif
  }
}

/// Mirrors swipe actions as VoiceOver `.accessibilityAction(named:)` entries on
/// all platforms so every swipe gesture has full assistive-tech parity.
private struct SwipeAccessibilityActionsModifier: ViewModifier {
  let enabled: Bool
  let actions: [TaskRowSwipeAction]

  func body(content: Content) -> some View {
    if enabled, !actions.isEmpty {
      content.accessibilityActions {
        ForEach(actions) { action in
          Button(action.title, role: action.role) {
            action.perform()
          }
        }
      }
    } else {
      content
    }
  }
}

#if os(iOS)
/// Horizontal swipe container for rows inside `SelectableScrollList` on
/// iOS/iPadOS. Yields to vertical scrolling unless horizontal translation
/// clearly dominates; enforces `allowsTrailingFullSwipe = false` on destructive
/// actions so accidental deletes cannot happen on a sloppy swipe.
private struct TaskRowSwipeContainer<Content: View>: View {
  let rowID: String
  let leading: [TaskRowSwipeAction]
  let allowsLeadingFullSwipe: Bool
  let trailing: [TaskRowSwipeAction]
  let allowsTrailingFullSwipe: Bool
  @ViewBuilder let content: () -> Content

  private static var buttonWidth: CGFloat { 74 }

  @State private var settledOffset: CGFloat = 0
  @State private var dragDelta: CGFloat = 0
  @State private var dragAxis: DragAxis? = nil
  @State private var crossedFullSwipe = false

  private enum DragAxis { case horizontal, vertical }

  private var leadingWidth: CGFloat { CGFloat(leading.count) * Self.buttonWidth }
  private var trailingWidth: CGFloat { CGFloat(trailing.count) * Self.buttonWidth }
  private var leadingFullThreshold: CGFloat { max(144, leadingWidth + 36) }
  private var trailingFullThreshold: CGFloat { max(144, trailingWidth + 36) }

  private var rawOffset: CGFloat { settledOffset + dragDelta }

  private var effectiveOffset: CGFloat {
    let raw = rawOffset
    if raw > 0 {
      guard !leading.isEmpty else { return 0 }
      if allowsLeadingFullSwipe { return min(raw, leadingFullThreshold + 48) }
      let overflow = max(0, raw - leadingWidth)
      return min(raw, leadingWidth) + overflow * 0.25
    } else if raw < 0 {
      guard !trailing.isEmpty else { return 0 }
      let absRaw = -raw
      if allowsTrailingFullSwipe { return -min(absRaw, trailingFullThreshold + 48) }
      let overflow = max(0, absRaw - trailingWidth)
      return -(min(absRaw, trailingWidth) + overflow * 0.25)
    }
    return 0
  }

  private var isLeadingFullSwipeArmed: Bool {
    allowsLeadingFullSwipe && !leading.isEmpty && effectiveOffset >= leadingFullThreshold
  }

  private var isTrailingFullSwipeArmed: Bool {
    allowsTrailingFullSwipe && !trailing.isEmpty && -effectiveOffset >= trailingFullThreshold
  }

  var body: some View {
    ZStack {
      if effectiveOffset > 0.5, !leading.isEmpty {
        HStack(spacing: 0) {
          if isLeadingFullSwipeArmed, let primary = leading.first {
            swipeButton(primary, width: effectiveOffset)
          } else {
            ForEach(leading) { action in
              swipeButton(action, width: Self.buttonWidth)
            }
          }
          Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }

      if effectiveOffset < -0.5, !trailing.isEmpty {
        HStack(spacing: 0) {
          Spacer(minLength: 0)
          if isTrailingFullSwipeArmed, let primary = trailing.first {
            swipeButton(primary, width: -effectiveOffset)
          } else {
            // Trailing primary sits outermost (right edge); secondary sits to its left.
            ForEach(Array(trailing.reversed())) { action in
              swipeButton(action, width: Self.buttonWidth)
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }

      content()
        .offset(x: effectiveOffset)
        .allowsHitTesting(settledOffset == 0)
        .overlay {
          if settledOffset != 0 {
            Color.clear
              .contentShape(Rectangle())
              .onTapGesture { close() }
          }
        }
    }
    .clipped()
    .simultaneousGesture(
      DragGesture(minimumDistance: 12, coordinateSpace: .local)
        .onChanged { value in
          let dx = value.translation.width
          let dy = value.translation.height
          if dragAxis == nil {
            if abs(dx) > abs(dy) * 1.25, abs(dx) > 12 {
              dragAxis = .horizontal
              NotificationCenter.default.post(name: .septenaSwipeRowOpened, object: rowID)
            } else if abs(dy) > 10 {
              dragAxis = .vertical
              return
            } else {
              return
            }
          }
          guard dragAxis == .horizontal else { return }
          dragDelta = dx
          let armed = isLeadingFullSwipeArmed || isTrailingFullSwipeArmed
          if armed && !crossedFullSwipe {
            crossedFullSwipe = true
            Haptics.tick()
          } else if !armed && crossedFullSwipe {
            crossedFullSwipe = false
          }
        }
        .onEnded { value in
          defer {
            dragAxis = nil
            dragDelta = 0
            crossedFullSwipe = false
          }
          guard dragAxis == .horizontal else { return }
          let finalOffset = effectiveOffset
          if allowsLeadingFullSwipe, finalOffset >= leadingFullThreshold, let primary = leading.first {
            a11yAnimate(.snappy(duration: 0.22)) { settledOffset = 0 }
            primary.perform()
            return
          }
          if allowsTrailingFullSwipe, -finalOffset >= trailingFullThreshold, let primary = trailing.first {
            a11yAnimate(.snappy(duration: 0.22)) { settledOffset = 0 }
            primary.perform()
            return
          }
          let projected = finalOffset + value.predictedEndTranslation.width * 0.2
          a11yAnimate(.snappy(duration: 0.22)) {
            if projected > 44, !leading.isEmpty {
              settledOffset = leadingWidth
              NotificationCenter.default.post(name: .septenaSwipeRowOpened, object: rowID)
            } else if projected < -44, !trailing.isEmpty {
              settledOffset = -trailingWidth
              NotificationCenter.default.post(name: .septenaSwipeRowOpened, object: rowID)
            } else {
              settledOffset = 0
            }
          }
        }
    )
    .onReceive(NotificationCenter.default.publisher(for: .septenaSwipeRowOpened)) { note in
      if let openedID = note.object as? String, openedID != rowID, settledOffset != 0 {
        close()
      }
    }
  }

  private func swipeButton(_ action: TaskRowSwipeAction, width: CGFloat) -> some View {
    Button(role: action.role) {
      close()
      action.perform()
    } label: {
      VStack(spacing: 3) {
        Image(systemName: action.systemImage)
          .font(.system(size: 15, weight: .semibold))
        Text(action.title)
          .font(.septenaCaption)
          .lineLimit(1)
      }
      .foregroundStyle(Color.white)
      .frame(width: max(width, Self.buttonWidth))
      .frame(maxHeight: .infinity)
      .background(action.tint)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(action.title))
  }

  private func close() {
    a11yAnimate(.snappy(duration: 0.2)) {
      settledOffset = 0
      dragDelta = 0
    }
  }
}
#endif
