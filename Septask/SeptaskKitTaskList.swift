#if os(macOS)
import AppKit
import EventKit
import SwiftData

extension NSPasteboard.PasteboardType {
  /// Dragged task rows carry their stable task id — the same identity every
  /// wire and mutator speaks (docs/IDENTIFIERS.md).
  static let septaskTask = NSPasteboard.PasteboardType("com.septena.septask.task-id")
  /// Dragged SIDEBAR STRUCTURE rows (area/project reordering) — carries the
  /// node's `key` ("area:<id>" / "project:<id>"), distinct from
  /// `.septaskTask` so the sidebar's single drop handler can tell "reorder
  /// the sidebar itself" apart from "file a dragged task".
  static let septaskStructureItem = NSPasteboard.PasteboardType("com.septena.septask.structure-item")
}

/// Shared by the list (reorder/re-file drops) and the sidebar (file/schedule
/// drops).
@MainActor
enum KitDrag {
  static func ids(from info: NSDraggingInfo) -> [String] {
    (info.draggingPasteboard.pasteboardItems ?? [])
      .compactMap { $0.string(forType: .septaskTask) }
  }
}

// The spike's task list (see SeptaskKitWindow.swift for scope): a native
// NSTableView over LocalCache's ordered DTOs, writing through TaskMutator.
// Selection, arrow keys, type-select, and every shortcut below run on the
// synchronous responder chain — the feel being evaluated against SwiftUI.
//
// Structure matches the SwiftUI list: Today (setting-gated, default on) and
// Anytime group open tasks under area / project headers in sidebar order —
// loose tasks first, then each area (direct tasks, then its projects), then
// loose projects (`orderedFromGroupedOpen` in TaskListView is the reference).
// Flat Today sorts by due urgency instead, per the same setting's contract.
//
// Keyboard map — same bindings as `TaskRowShortcuts` (TaskCommands.swift),
// so the two shells never teach conflicting muscle memory:
//   ↑/↓, ⇧-arrows, type-select, Home/End — native NSTableView
//   ⌘K — toggle complete          ⌘T — toggle Today
//   ⌘N — new task in this list    ⌘, — settings
//   ⌘R, Return, double-click — rename via the field editor (Esc cancels)
//   ⌘⌫ — delete (soft; lands in Recently Deleted)
//   Space — deliberately unbound (the "Space completes the task" trap);
//           the checkbox refuses first responder for the same reason.
@MainActor
final class SeptaskKitTaskListController: NSViewController {

  /// A row's list-membership capsule ("# BFF", "📁 Admin") — shown only where
  /// the surrounding group doesn't already say where the task lives.
  struct Chip: Equatable {
    let symbol: String
    let title: String
  }

  /// The glyph a group header wears — mirrors the sidebar's vocabulary.
  enum GroupIcon: Equatable {
    case emoji(String)
    case areaDot
    case project(Double)
    case symbol(String)
  }

  /// What the Claude reconnect row says right now. The four states are
  /// `ClaudeReconnectCue`'s, one for one: the calm auth checkpoint, a genuine
  /// failure, the re-mint in flight, and the brief "you're back" flash that
  /// closes the loop instead of letting the row vanish silently.
  enum ReconnectCueState: Equatable {
    case idle, failed, refreshing, reconnected

    var key: String {
      switch self {
      case .idle: return "idle"
      case .failed: return "failed"
      case .refreshing: return "refreshing"
      case .reconnected: return "reconnected"
      }
    }
  }

  /// A calendar event flattened to a value — the row diff compares rows, and
  /// EKEvent is a live reference whose identity says nothing about content.
  struct Event: Equatable {
    let id: String
    let title: String
    let time: String
  }

  /// One list line: a synthetic group header, a task row, a calendar event,
  /// the project/area page's own big title, or the "N logged items" footer.
  /// `key` is the stable identity the animated diff runs on.
  private enum Row: Equatable {
    case header(id: String, title: String, icon: GroupIcon, count: Int)
    case screenTitle(title: String, icon: GroupIcon)
    case projectTarget(id: String, title: String, progress: Double)
    case task(SeptenaTask, chip: Chip?, suggestion: SuggestionEngine.Suggestion?)
    case event(Event)
    case loggedFooter(count: Int, expanded: Bool)
    /// Foot of Today's Inbox card — the clickable "New task" line, the AppKit
    /// counterpart of SwiftUI's `QuickAddTriggerRow`. It carries no task, so
    /// `shouldSelectRow` already keeps it out of selection and arrow-nav.
    case newTask
    /// Foot of a project page — the quiet "Add Section" line, the AppKit
    /// counterpart of `TaskListView.addSectionButton`. Until this existed the
    /// ONLY way to make a heading was a right-click on blank space below the
    /// list, which a project with enough tasks to fill the window doesn't have.
    case addSection
    /// "Import all N from Reminders" — a quiet action LINE inside the Inbox,
    /// shown only when more than one is waiting. A line rather than a header
    /// button because the Inbox header's trailing slot belongs to the `+`, and
    /// a header answering to two actions is how cells grow bugs.
    case importAllReminders(count: Int, importing: Bool)
    /// One pending Apple Reminder, click to import. `importing` drives the
    /// in-flight dimming so a slow EventKit delete doesn't look like a no-op.
    case reminder(ImportedReminder, importing: Bool)
    /// "N tasks rolled into Today" — the dismissible start-of-day notice for
    /// work that arrived on its own because a date the user set earlier has
    /// now come round.
    case rolledInBanner(count: Int)
    /// "Reconnect" — the Claude gateway token lapsed and only the user can
    /// re-mint it. Today only, the slot `ClaudeReconnectCue(.card)` takes in
    /// the SwiftUI shell.
    case reconnectCue(state: ReconnectCueState)

    var key: String {
      switch self {
      case .header(let id, _, _, _): return "h:" + id
      case .screenTitle: return "screen-title"
      case .projectTarget(let id, _, _): return "project-target:" + id
      case .task(let task, _, _): return task.id
      case .event(let event): return "e:" + event.id
      case .loggedFooter: return "logged-footer"
      case .newTask: return "new-task"
      case .addSection: return "add-section"
      case .reminder(let item, _): return "reminder:" + item.id
      case .rolledInBanner: return "rolled-in-banner"
      // The state rides the key so a change (idle → refreshing → reconnected)
      // reads as a row REPLACEMENT in the diff, and the cell re-configures.
      case .reconnectCue(let state): return "reconnect-cue:" + state.key
      case .importAllReminders: return "import-all-reminders"
      }
    }

    var task: SeptenaTask? {
      if case .task(let task, _, _) = self { return task }
      return nil
    }

    /// Rows that draw on a card (tasks and events), vs. headers on the page.
    /// Project section headings sit BETWEEN cards (SwiftUI's `headingRow`),
    /// so they break the card run the same way a Today area/project header does.
    var isCardRow: Bool {
      switch self {
      case .header, .screenTitle, .loggedFooter, .addSection: return false
      // A notice, not an item: it sits on the page like a header, NOT on a
      // card. A statement about your list must not look like a row of it.
      case .rolledInBanner: return false
      // A control, not a notice: it draws on a card because it is something
      // you press, the same reason SwiftUI's cue is a glass card and the
      // rolled-in notice above is bare page.
      case .reconnectCue: return true
      // Rides the Inbox card with the reminder rows it acts on.
      case .importAllReminders: return true
      case .projectTarget, .event, .newTask, .reminder: return true
      case .task(let task, _, _): return !task.isHeading
      }
    }
  }

  private let tableView = SeptaskKitTableView()
  private let scrollView = NSScrollView()
  private let emptyLabel = NSTextField(labelWithString: String(localized: "No Tasks",
                                                                comment: "SeptaskKit: empty list"))
  private var rows: [Row] = []
  private var filter: TaskFilter = .today
  private var observers: [NSObjectProtocol] = []
  /// A ⌘N row whose first title is still being typed — abandoned (empty on
  /// commit) it's purged, so escaping a fresh row leaves nothing behind.
  private var pendingNewTaskId: String?
  /// Pending Apple Reminders mirrored onto Today, newest read wins. Held as
  /// (reminder, view) pairs exactly like `RemindersInboxSection`: the
  /// `EKReminder` is what we delete after a successful import, the
  /// `ImportedReminder` is the value the row draws from.
  private var reminderPairs: [(reminder: EKReminder, view: ImportedReminder)] = []
  /// The reminder currently being imported, if any — dims its row.
  private var importingReminderID: String?
  /// True while Import All is in flight — disables every reminder row.
  private var bulkImportingReminders = false
  /// Tasks just pinned to Today, waiting for their promote cue. A one-shot
  /// set rather than a per-row flag: the cue plays against the row's CURRENT
  /// cell, which only exists after the reload the promote triggered, so the
  /// intent has to outlive the mutation by exactly one reload.
  /// The AppKit counterpart of SwiftUI's `PromoteFlashStore`.
  private var pendingPromoteFlash: Set<String> = []
  /// task id → top filing pick, the "→ Suggested" capsule's contents. Snapshot
  /// per reload (like `TaskListModel.filingSuggestions`) rather than read live
  /// off the engine, so a row and its capsule always agree.
  private var filingSuggestions: [String: SuggestionEngine.Suggestion] = [:]
  /// Live notes-band height while the composer is open (`nil` = notes folded).
  private var composerNotesHeight: CGFloat?
  /// The row currently expanded into the inline composer, if any.
  private var composingTaskId: String?
  /// The row with a live bare title field editor (⌘N / ⌘R), if any — drives
  /// `KitCardRowView.isEditingTitle` so the selection wash drops while typing,
  /// the same way the composer already does.
  private var editingTaskId: String?
  /// Row the drag would insert ABOVE (`NSTableView` gap index; `rows.count`
  /// means after the last row). Drives `KitCardRowView.dropLine`.
  private var dropAboveRow: Int? {
    didSet {
      if oldValue != dropAboveRow { refreshDropIndicator() }
    }
  }
  /// Completed rows are lingering on screen; refreshes wait (see `beginSettle`).
  private var isSettling = false
  private var settleWorkItem: DispatchWorkItem?
  /// Held so its submenu can be refreshed from the live structure on open.
  private let moveMenuItem = NSMenuItem()
  /// Placement items — titles / visibility refresh on every open from the
  /// current selection (see `refreshPlacementMenuItems`).
  private let todayMenuItem = NSMenuItem()
  /// Titled in `refreshPlacementMenuItems` — Show / Hide, so the row menu says
  /// what ⌥⌘I will actually do next.
  private let infoMenuItem = NSMenuItem()
  private let clearScheduleMenuItem = NSMenuItem()
  private let pauseRepeatMenuItem = NSMenuItem()
  /// The ranked filing picks currently offered in the context menu's
  /// "Suggested" section, best first — read back by `tag` when one is chosen.
  /// Rebuilt on every menu open, like the Move submenu, because the answer
  /// depends on the selected row.
  private var menuSuggestions: [SuggestionEngine.Suggestion] = []
  /// The items this controller inserted for that section. The context menu is
  /// built once and edited in place, so the next open has to take the previous
  /// section back out before inserting the current one.
  private var suggestedMenuItems: [NSMenuItem] = []

  /// The inspector follows the selection; the window owns the wiring.
  var onSelectionChange: ((SeptenaTask?) -> Void)?
  /// A refresh landed — anything showing this data should re-read.
  var onStoreChanged: (() -> Void)?
  var onToggleInspector: (() -> Void)?
  var onQuickFind: (() -> Void)?
  /// Jump to another destination — a grouped Today/Anytime area or project
  /// header was clicked, or the title dropdown picked a list. Carries a
  /// `KitSidebarDestination` (not a bare `TaskFilter`) because Next is a
  /// sidebar destination without a filter of its own.
  var onNavigate: ((KitSidebarDestination) -> Void)?
  /// Tab pressed while the list holds focus — the window owns moving focus
  /// to the sidebar (see `focusList()`'s sibling, `focusSidebar()`).
  var onFocusSidebar: (() -> Void)?

  private var context: ModelContext { LocalStore.shared.container.mainContext }

  // MARK: - Undo

  /// Owned rather than borrowed from `NSWindow` — without an `NSDocument`,
  /// `NSWindow.undoManager` is nil by default (that machinery is document
  /// -architecture-only). `NSViewController` IS an `NSResponder`, and this
  /// controller sits properly in the chain (a real child of the split view
  /// controller), so overriding `undoManager` here is what makes the
  /// standard Edit ▸ Undo/Redo menu items — and ⌘Z/⌘⇧Z — find it.
  /// The SHARED stack (`TaskUndo`), not a controller-owned one. Undo used to
  /// live only here, which made ⌘Z a property of one of four task surfaces;
  /// it now belongs to the write boundary, so the same stack backs this table,
  /// the SwiftUI lists, and iOS shake / three-finger undo. Everything below is
  /// unchanged — the shell still registers its own inverses, it just registers
  /// them somewhere the other surfaces can see.
  private var kitUndoManager: UndoManager { TaskUndo.manager }
  override var undoManager: UndoManager? { kitUndoManager }

  /// Registers `undoAction` as the inverse of a mutation just made; performing
  /// it (⌘Z) re-registers `redoAction` as ITS OWN inverse, which is what gives
  /// ⌘⇧Z (redo) for free — the standard `UndoManager` symmetric-registration
  /// idiom. Covers every value-level mutator the shell offers:
  /// complete/uncomplete, delete/restore, rename, move,
  /// create/duplicate/paste, and the scheduling fields (When, Deadline,
  /// Today, repeat) via `ScheduleSnapshot`.
  private func recordUndo(name: String, undo undoAction: @escaping () -> Void,
                          redo redoAction: @escaping () -> Void) {
    kitUndoManager.setActionName(name)
    kitUndoManager.registerUndo(withTarget: self) { target in
      undoAction()
      target.recordUndo(name: name, undo: redoAction, redo: undoAction)
    }
  }
  /// The scheduling fields the date / Today / repeat commands touch, captured
  /// before a change so undo can put them back. There is no second write path:
  /// `restore` replays the SAME mutators the forward commands use.
  private struct ScheduleSnapshot {
    let id: String
    let scheduled: Date?
    let today: Bool
    let deadline: Date?
    let recurrence: Recurrence?
    let recurrencePaused: Bool
  }

  private func scheduleSnapshot(_ task: SeptenaTask) -> ScheduleSnapshot {
    ScheduleSnapshot(id: task.id,
                     scheduled: KitDayFormat.date(fromWire: task.scheduled),
                     today: task.today,
                     deadline: KitDayFormat.date(fromWire: task.deadline),
                     recurrence: task.recurrence,
                     recurrencePaused: task.recurrencePaused)
  }

  /// Put the captured fields back. Order is load-bearing: `schedule` and
  /// `setDeadline` both carry their own Today side effects (a deadline that
  /// has landed can drop a row off Today), so the explicit Today flag is
  /// written LAST and wins. `moveToToday(id:today:)` rather than
  /// `removeFromToday` — the latter also clears any already-landed scheduled
  /// or deadline date, which would undo more than the command did.
  /// One fidelity limit: `todaySetOn` re-stamps to the current day, so undo
  /// restores Today membership but not the row's original tenure age.
  private func restoreSchedules(_ snapshots: [ScheduleSnapshot]) {
    for snapshot in snapshots {
      mutator.schedule(id: snapshot.id, date: snapshot.scheduled)
      mutator.setDeadline(id: snapshot.id, date: snapshot.deadline)
      mutator.setRecurrence(id: snapshot.id, recurrence: snapshot.recurrence)
      if snapshot.recurrence != nil {
        mutator.setRecurrencePaused(id: snapshot.id, paused: snapshot.recurrencePaused)
      }
      mutator.moveToToday(id: snapshot.id, today: snapshot.today)
    }
    reload()
  }

  /// Register undo for a change to the scheduling fields. Call it AFTER the
  /// change: `before` is captured by the caller beforehand, and the redo side
  /// is re-read from the store rather than predicted, because `schedule` /
  /// `setDeadline` / `removeFromToday` each carry their own Today side
  /// effects and modelling those here would be a second copy of that logic.
  private func recordScheduleUndo(name: String, before: [ScheduleSnapshot]) {
    guard !before.isEmpty else { return }
    let wanted = Set(before.map(\.id))
    let after = LocalCache.allTasks(in: context)
      .filter { wanted.contains($0.id) }
      .map(scheduleSnapshot)
    guard !after.isEmpty else { return }
    recordUndo(name: name,
               undo: { [weak self] in self?.restoreSchedules(before) },
               redo: { [weak self] in self?.restoreSchedules(after) })
  }

  /// Undo for freshly created tasks. Redo has to RE-create rather than
  /// restore: `purge` is a real delete, so there is no row left to bring
  /// back. Re-creating mints NEW ids, hence the box both closures read.
  private func recordCreateUndo(name: String, ids: [String],
                                rebuild: @escaping () -> [String]) {
    var current = ids
    recordUndo(name: name,
               undo: { [weak self] in
                 for id in current { self?.mutator.purge(id: id) }
                 self?.reload()
               },
               redo: { [weak self] in
                 current = rebuild()
                 self?.reload()
               })
  }

  /// Undo for a ⌘N row that has just been given a real title. The undoable
  /// act is the CREATION, not a rename from the empty placeholder the row was
  /// born with — reading the row's own filing back out means redo re-creates
  /// it exactly where it was.
  private func recordNewTaskUndo(id: String) {
    guard let task = LocalCache.allTasks(in: context).first(where: { $0.id == id })
    else { return }
    let title = task.title
    let area = task.area
    let project = task.project
    let scheduled = KitDayFormat.date(fromWire: task.scheduled)
    let today = task.today
    recordCreateUndo(name: String(localized: "New Task", comment: "SeptaskKit: undo action"),
                     ids: [id],
                     rebuild: { [weak self] in
                       guard let self else { return [] }
                       return [self.mutator.create(title: title, area: area, project: project,
                                                   scheduled: scheduled, today: today,
                                                   atBottom: false).id]
                     })
  }

  private var mutator: TaskMutator { SeptenaServices.shared.taskMutator }

  override func loadView() {
    let column = NSTableColumn(identifier: .init("task"))
    tableView.addTableColumn(column)
    tableView.headerView = nil
    // Cards are drawn per row (KitCardRowView) on the page background, the
    // SwiftUI list's grouped-card look — so the table itself stays plain and
    // transparent rather than adding a second inset/background of its own.
    tableView.style = .plain
    // MUST be .custom: any other value makes AppKit impose its own row height
    // AND its own font on `NSTableCellView`s. That silently overrode the group
    // headers' larger font (the task rows escaped it only because they set an
    // `attributedStringValue`, which carries its own font attribute).
    tableView.rowSizeStyle = .custom
    tableView.backgroundColor = .clear
    tableView.intercellSpacing = NSSize(width: 0, height: 0)
    tableView.allowsMultipleSelection = true
    // The selection fill IS the focus indicator. A focus ring on top of it is
    // a second highlight language on one surface — and it draws in
    // `keyboardFocusIndicatorColor`, which follows the accent, so with this
    // app's ink accent it renders as a black box around the selected row.
    tableView.focusRingType = .none
    // Layer-backed NSTableView paints a full-row selection fill that never
    // reaches `KitCardRowView.drawSelection` — a second rectangle around the
    // inset card. `.none` turns that off; the row view paints the wash
    // inside the card in `drawBackground`.
    tableView.selectionHighlightStyle = .none
    // Default `.gap` punches a row-height hole at the drop, which splits a
    // per-row card into two and leaves a chrome-less duplicate in the gap.
    // `.none` keeps the card intact; we draw SwiftUI's insertion line instead.
    tableView.draggingDestinationFeedbackStyle = .none
    tableView.dataSource = self
    tableView.delegate = self
    tableView.target = self
    tableView.doubleAction = #selector(beginEditFromDoubleClick)
    tableView.onToggleComplete = { [weak self] in self?.toggleCompleteSelection() }
    tableView.onToggleToday = { [weak self] in self?.toggleTodaySelection() }
    tableView.onBeginEdit = { [weak self] in self?.beginEditSelectedRow() }
    tableView.onOpenComposer = { [weak self] in self?.beginComposingSelectedRow() }
    tableView.onDelete = { [weak self] in self?.deleteSelection() }
    tableView.onNewTask = { [weak self] in self?.createTask() }
    tableView.onToggleInspector = { [weak self] in self?.onToggleInspector?() }
    tableView.onQuickFind = { [weak self] in self?.onQuickFind?() }
    tableView.onWhen = { [weak self] in self?.presentDatePopover(kind: .when) }
    tableView.onDeadline = { [weak self] in self?.presentDatePopover(kind: .deadline) }
    tableView.onClearSchedule = { [weak self] in self?.clearScheduleSelection() }
    tableView.onDuplicate = { [weak self] in self?.duplicateSelection() }
    tableView.onMove = { [weak self] in self?.presentMoveMenu() }
    tableView.onFocusSidebar = { [weak self] in self?.onFocusSidebar?() }
    // Edit ▸ Copy targets the first responder, so implementing `copy(_:)` on
    // the table is what makes the STANDARD menu item work — better than a
    // second ⌘C item in the Task menu fighting it for the binding.
    tableView.onCopy = { [weak self] in self?.copySelection() }
    tableView.onPaste = { [weak self] in self?.pasteTasks() }
    tableView.canPaste = { [weak self] in self?.canPasteTasks ?? false }
    tableView.canCopy = { [weak self] in self?.hasActionableSelection ?? false }
    // NOT `tableView.menu = ...`: AppKit's automatic path for a table's
    // `.menu` property paints its own native "row targeted by a context
    // menu" highlight UNDERNEATH our custom fill — a second, uncontrollable
    // selection language on top of `KitCardRowView`'s. Popping the menu up
    // manually from `rightMouseDown` bypasses that machinery entirely.
    let contextMenu = buildContextMenu()
    let recentlyDeletedMenu = buildRecentlyDeletedMenu()
    tableView.onRightClick = { [weak self, weak tableView] event in
      guard let self, let tableView else { return }
      let point = tableView.convert(event.locationInWindow, from: nil)
      let row = tableView.row(at: point)
      guard row >= 0 else {
        // Blank space below the list, on a project page: the entry point
        // for adding a section, matching the SwiftUI page's own affordance.
        if case .project = self.filter {
          self.buildBlankSpaceMenu().popUp(positioning: nil, at: point, in: tableView)
        }
        return
      }
      if !tableView.selectedRowIndexes.contains(row) {
        tableView.selectRowIndexes([row], byExtendingSelection: false)
      }
      let menu: NSMenu
      if let task = self.rows[row].task, task.isHeading {
        menu = self.buildHeadingContextMenu()
      } else if self.filter == .recentlyDeleted {
        menu = recentlyDeletedMenu
      } else {
        menu = contextMenu
      }
      menu.popUp(positioning: nil, at: point, in: tableView)
    }
    tableView.registerForDraggedTypes([.septaskTask])
    tableView.setDraggingSourceOperationMask(.move, forLocal: true)
    tableView.onDragEnded = { [weak self] in self?.dropAboveRow = nil }

    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = true
    scrollView.backgroundColor = SeptaskKitTheme.pageBackground
    // Breathing room above the first card and below the last — Things-style;
    // without it the list runs flush to the window's top and bottom edges.
    // `contentInsets` (not a spacer row) is the standard way to do this: it
    // pads the clip view rather than the document, so scroll/bounce and
    // "scroll to visible" all still measure from the real content edges.
    // Fixed vertical inset (not the width-dependent side margin) — matching
    // the sides made top/bottom swell on wide windows and read as broken.
    // The TOP is a placeholder: `viewDidLayout` grows it to clear the title
    // bar, whose height belongs to the toolbar and isn't knowable here.
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.contentInsets = NSEdgeInsets(top: SeptaskKitLayout.titleBarGap,
                                            left: 0,
                                            bottom: SeptaskKitLayout.verticalInset,
                                            right: 0)
    // The window title mirrors this page's big in-content title (`screenTitle`):
    // hidden while that title is on screen, revealed once it scrolls away — so
    // the top of the window always NAMES the destination instead of reading as
    // a bare strip of tasks. This is the standard NSWindow title reveal, driven
    // by the clip view's own bounds notification; no NSEvent monitor.
    scrollView.contentView.postsBoundsChangedNotifications = true
    view = scrollView

    emptyLabel.font = SeptaskKitTheme.taskTitle
    emptyLabel.textColor = SeptaskKitTheme.iconMuted
    emptyLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(emptyLabel)
    NSLayoutConstraint.activate([
      emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])

    // CloudKit batches post .septenaTasksChanged; mutations made in the
    // SwiftUI window don't post anything (its views refresh themselves), so
    // window-becomes-key covers the cross-window A/B case.
    for name in [Notification.Name.septenaTasksChanged, .septenaStructureChanged,
                 .septenaDataChanged] {
      observers.append(NotificationCenter.default.addObserver(
        forName: name, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.reload() }
      })
    }
    observers.append(NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
    ) { [weak self] note in
      MainActor.assumeIsolated {
        guard let self, note.object as? NSWindow === self.view.window else { return }
        self.reload()
      }
    })
    observers.append(NotificationCenter.default.addObserver(
      forName: .septenaTextSizeDidChange, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshTextSize() }
    })
    // Pending Apple Reminders. `.EKEventStoreChanged` fires for every edit in
    // every list, so `refreshReminders` compares the resulting set and only
    // reloads when the mirrored list actually moved.
    observers.append(NotificationCenter.default.addObserver(
      forName: .EKEventStoreChanged, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshReminders() }
    })
    observers.append(NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.syncWindowTitle() }
    })
    // The Claude reconnect row. `@Observable` state, not a notification —
    // see `trackClaudeGatewayState`.
    trackClaudeGatewayState()
  }

  /// Keep the first card clear of the title bar. The bar's height is the
  /// toolbar's, which no constant here can know, so it is MEASURED:
  /// `contentLayoutRect` is the part of the content view the bar does not
  /// cover, so the difference is the bar. Re-read on every layout because
  /// the toolbar's height moves with the system's toolbar settings.
  ///
  /// `automaticallyAdjustsContentInsets` would do the clearing on its own,
  /// but it owns the WHOLE inset — it would drop the deliberate gap above the
  /// first card and the one below the last.
  override func viewDidLayout() {
    super.viewDidLayout()
    guard let window = view.window, let content = window.contentView else { return }
    let barHeight = max(0, content.bounds.height - window.contentLayoutRect.height)
    let top = barHeight + SeptaskKitLayout.titleBarGap
    // Guarded: an unconditional assignment during layout re-enters forever.
    if abs(scrollView.contentInsets.top - top) > 0.5 {
      scrollView.contentInsets.top = top
    }
  }

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }

  /// True once `show` has run at least once — see the guard below.
  private var hasShownOnce = false

  /// THE actual fix for "linger doesn't linger": completing a task posts
  /// `.septenaTasksChanged` synchronously, which the SIDEBAR also observes to
  /// refresh its counts — and its rebuild reselects the (freshly rebuilt,
  /// so identity-different) currently-selected row, which re-fires `onSelect`
  /// → `show(sameFilter, ...)` on THIS list, synchronously, mid-settle.
  /// Reselecting the destination you're already on must be a no-op, or every
  /// settle gets cancelled the instant it starts by the very completion that
  /// triggered it. `hasShownOnce` keeps this from also swallowing the very
  /// first call at launch, when `filter` already equals the default `.today`
  /// before anything has actually loaded.
  func show(_ filter: TaskFilter) {
    if hasShownOnce, filter == self.filter { return }
    hasShownOnce = true
    cancelSettle()
    self.filter = filter
    reload(animated: false)
    if tableView.numberOfRows > 0 {
      tableView.scrollRowToVisible(0)
    }
    syncWindowTitle()
    // Off-main-thread EventKit read; lands via its own `reload()`. Leaving
    // Today clears the block, so a stale mirror can't ride along to a project
    // page.
    refreshReminders()
  }

  /// Hide the window title while this page's own big title is on screen, show
  /// it once that title has scrolled out — the shell's only header. Pages with
  /// no `screenTitle` row (none today, but the row is optional) keep it shown.
  /// Called on every scroll, on every destination change, and by the shell
  /// when it swaps this pane back in ahead of the first scroll event.
  func syncWindowTitle() {
    guard let window = view.window else { return }
    var shown = true
    if let first = rows.first, case .screenTitle = first {
      // Table coordinates are flipped: the clip view's origin climbs as the
      // list scrolls, so the title row is gone once the origin has passed its
      // bottom edge.
      shown = scrollView.contentView.bounds.origin.y >= tableView.rect(ofRow: 0).maxY
    }
    let wanted: NSWindow.TitleVisibility = shown ? .visible : .hidden
    if window.titleVisibility != wanted { window.titleVisibility = wanted }
  }

  /// Give the task list keyboard focus. Called once the window is on screen
  /// so arrow keys drive TASKS from the start — AppKit would otherwise make
  /// the sidebar (the first view in the split) the initial first responder,
  /// which is the "arrows move the sidebar selection" trap the SwiftUI shell
  /// also had (see CLAUDE.md, "the sidebar holds focus by default").
  func focusList() {
    view.window?.makeFirstResponder(tableView)
    if tableView.selectedRow < 0, let first = rows.firstIndex(where: { $0.task != nil }) {
      tableView.selectRowIndexes([first], byExtendingSelection: false)
    }
  }

  /// Native AppKit cells do not observe `FontScale` the way SwiftUI font
  /// tokens do. Reload the visible table cells and invalidate row heights so
  /// View ▸ Text Size takes effect immediately in the main shell.
  func refreshTextSize() {
    emptyLabel.font = SeptaskKitTheme.taskTitle
    tableView.reloadData()
    if tableView.numberOfRows > 0 {
      tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<tableView.numberOfRows))
    }
    tableView.needsLayout = true
  }

  /// Select and reveal a row by task id — how a jump (Quick Find) lands on
  /// the thing it was asked to find. No-op when the task isn't in this list.
  func select(taskId: String) {
    guard let row = rows.firstIndex(where: { $0.task?.id == taskId }) else { return }
    tableView.selectRowIndexes([row], byExtendingSelection: false)
    tableView.scrollRowToVisible(row)
    view.window?.makeFirstResponder(tableView)
  }

  // MARK: - Data

  /// True while a title field editor is live in this table — a mid-edit
  /// reloadData() would destroy the editing session (e.g. a CloudKit batch
  /// landing while the user types), so reloads defer until the edit commits.
  private var isTitleEditorActive: Bool {
    guard let editor = view.window?.firstResponder as? NSTextView,
          let field = editor.delegate as? NSTextField else { return false }
    return field.isDescendant(of: tableView)
  }

  /// Mirrors SettingsKey.todayGroupByList's contract: absent → on.
  private var todayGroupsByList: Bool {
    UserDefaults.standard.object(forKey: SettingsKey.todayGroupByList) == nil
      ? true
      : UserDefaults.standard.bool(forKey: SettingsKey.todayGroupByList)
  }

  private func reload(animated: Bool = true) {
    // Every edit funnels through commitRename, which reloads — so a skipped
    // refresh here is picked up the moment the edit ends. The settle window
    // ends in a reload of its own, so skipping here is likewise not a loss.
    if isTitleEditorActive || isSettling || composingTaskId != nil { return }

    let selected = Set(tableView.selectedRowIndexes.compactMap { row in
      rows.indices.contains(row) ? rows[row].task?.id : nil
    })

    let pool = LocalCache.tasks(in: context, filter: filter)
    // Capsules first: `chipped()` reads the snapshot, so it has to be current
    // before any row is built. Includes the triage band, which `pool` omits on
    // Today — the band is exactly where most suggestions land.
    refreshFilingSuggestions(
      pool: pool + (filter == .today ? LocalCache.tasks(in: context, filter: .triage) : []))
    // One standard title row, on every page — computed once here rather than
    // duplicated into each branch below.
    let titleRows: [Row] = screenTitleRow().map { [$0] } ?? []
    var newRows: [Row]
    switch filter {
    case .today where todayGroupsByList:
      newRows = reconnectCue() + titleRows + agenda() + rolledInBanner(pool) + triageBand()
        + groupedByList(withoutTriage(pool), inboxFooter: newTaskLine)
    case .today:
      // Flat Today: due-first ordering, per the setting's documented contract.
      newRows = reconnectCue() + titleRows + agenda() + rolledInBanner(pool) + triageBand()
        + withoutTriage(pool).sorted(by: SeptenaTask.compareNextPageOrder).map(chipped)
        + newTaskLine
    case .upcoming:
      newRows = titleRows + upcomingBuckets(pool)
    case .unscheduled:
      newRows = titleRows + groupedByList(pool)
    case .project, .area:
      // Scoped reads return every live status; capture the done subset for
      // the logged footer BEFORE narrowing `pool` to open work — finished
      // rows don't live inline here, same as the SwiftUI page. Headings
      // never ride through `LocalCache.tasks` (see `convert`); the project
      // path fetches them via `LocalCache.headings(inProject:)` below.
      var completed = pool.filter { $0.status == .done }
      if case .area = filter {
        // Area pages show only area-DIRECT work in the open list — a task
        // filed under one of the area's projects appears on that project's
        // page, not doubled here. The logged footer honors the same split.
        completed = completed.filter { $0.project == nil }
      }
      completed.sort { ($0.completedAt ?? "") > ($1.completedAt ?? "") }

      let open = pool.filter { $0.status == .open }
      if case .project(let projectId) = filter {
        newRows = titleRows + projectGrouped(open: open, projectId: projectId)
          + loggedFooterRows(completed: completed)
      } else {
        // Area: flat (headings only live inside a project), and only
        // area-direct open work — same `excludeProjectedTasks` split.
        let direct = open.filter { $0.project == nil }
        // …followed by the area's own projects as jump targets, so an area
        // page shows its structure and not just its loose tasks.
        var projectRows: [Row] = []
        if case .area(let areaID) = filter {
          let snapshot = StructureCache.snapshot(in: context)
          let areaProjects = snapshot.projects.filter {
            $0.area == areaID && $0.status == .active
          }
          if !areaProjects.isEmpty {
            let progress = projectProgress()
            projectRows = [.header(id: "area-projects-\(areaID)",
                                   title: String(localized: "Projects",
                                                 comment: "SeptaskKit: area page section"),
                                   icon: .symbol("folder"),
                                   count: areaProjects.count)]
              + areaProjects.map {
                .projectTarget(id: $0.id,
                               title: $0.title,
                               progress: progress[$0.id] ?? 0)
              }
          }
        }
        newRows = titleRows + direct.map(unchipped)
          + projectRows + loggedFooterRows(completed: completed)
      }
    case .logbook:
      // Already most-recent-first from LocalCache; cap what one screen needs.
      newRows = titleRows + pool.prefix(200).map(chipped)
    default:
      newRows = titleRows + pool.map(chipped)
    }

    apply(newRows, animated: animated)
    emptyLabel.isHidden = !rows.isEmpty
    onStoreChanged?()

    if !selected.isEmpty {
      let indexes = IndexSet(rows.indices.filter {
        guard let id = rows[$0].task?.id else { return false }
        return selected.contains(id)
      })
      tableView.selectRowIndexes(indexes, byExtendingSelection: false)
    }
  }

  /// Gated on the setting AND on access already being granted — this shell
  /// never triggers the permission prompt itself; Settings ▸ Integrations
  /// owns that, same as `agenda()`/`upcomingBuckets()` below.
  private var showsCalendarEvents: Bool {
    let enabled = UserDefaults.standard.object(forKey: SettingsKey.tasksShowCalendarEvents) == nil
      ? true
      : UserDefaults.standard.bool(forKey: SettingsKey.tasksShowCalendarEvents)
    return enabled && CalendarBridge.shared.access == .granted
  }

  /// TODAY's calendar agenda, woven above the tasks the way the SwiftUI list
  /// weaves it (`TaskListModel.refreshCalendarEvents`) — what's still ahead
  /// today. Upcoming uses `upcomingBuckets()` instead, which weaves events
  /// per-day rather than as one block at the top.
  private func agenda() -> [Row] {
    guard showsCalendarEvents else { return [] }
    let events = CalendarBridge.shared.remainingTodayEvents()
    guard !events.isEmpty else { return [] }

    let rows = events.map { event in
      Row.event(Event(id: event.eventIdentifier ?? UUID().uuidString,
                      title: event.title ?? "",
                      time: KitDayFormat.eventTime(event, on: filter)))
    }
    return [.header(id: "agenda",
                    title: String(localized: "Agenda", comment: "SeptaskKit: Today calendar group"),
                    icon: .symbol("calendar"),
                    count: events.count)] + rows
  }

  /// Upcoming grouped by day — matches `TaskListView.upcomingBuckets()`
  /// exactly: bucket key is the EARLIEST FUTURE of a task's scheduled/deadline
  /// date (so a past-scheduled, future-deadline task buckets on the deadline,
  /// never under a stale header), days are the UNION of task-days and
  /// event-days (an all-day-event-only day still gets a row), sorted
  /// ascending, with `SeptenaDate.scheduleHeaderLabel` giving each day's
  /// title ("Today"/"Tomorrow"/weekday/"EEE, MMM d" — the exact same
  /// function, not a reimplementation).
  private func upcomingBuckets(_ pool: [SeptenaTask]) -> [Row] {
    let today = SeptenaDate.today
    var tasksByDay: [String: [SeptenaTask]] = [:]
    for task in pool {
      let key = [task.scheduled, task.deadline]
        .compactMap { $0 }
        .filter { $0 > today }
        .min()
      guard let key else { continue }
      tasksByDay[key, default: []].append(task)
    }

    var eventsByDay: [String: [EKEvent]] = [:]
    if showsCalendarEvents {
      for event in CalendarBridge.shared.upcomingEvents(days: 30) {
        for key in upcomingDayKeys(for: event) {
          eventsByDay[key, default: []].append(event)
        }
      }
    }

    let days = Set(tasksByDay.keys).union(eventsByDay.keys).sorted()
    var rows: [Row] = []
    for key in days {
      let label = SeptenaDate.parse(key).map(SeptenaDate.scheduleHeaderLabel) ?? key
      let dayTasks = tasksByDay[key] ?? []
      let dayEvents = eventsByDay[key] ?? []
      rows.append(.header(id: "day-\(key)", title: label, icon: .symbol("calendar"),
                         count: dayTasks.count))
      rows.append(contentsOf: dayEvents.map { event in
        .event(Event(id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? "",
                    time: KitDayFormat.eventTime(event, on: filter)))
      })
      rows.append(contentsOf: dayTasks.map(chipped))
    }
    return rows
  }

  /// Every day an event covers within the 30-day window — a multi-day
  /// all-day event (e.g. a long weekend) shows on each day it spans, not
  /// just its start day. Mirrors `TaskListView.upcomingDayKeys(for:)`.
  private func upcomingDayKeys(for event: EKEvent) -> [String] {
    let cal = Calendar.current
    guard let today = SeptenaDate.startOfDay(for: SeptenaDate.today),
          let start = event.startDate,
          let windowEnd = cal.date(byAdding: .day, value: 30, to: today)
    else { return [] }
    var endRef = event.endDate ?? start
    if event.isAllDay, endRef == cal.startOfDay(for: endRef) {
      endRef = endRef.addingTimeInterval(-1)
    }
    var day = max(cal.startOfDay(for: start), today)
    let lastDay = min(cal.startOfDay(for: endRef), windowEnd)
    var keys: [String] = []
    while day <= lastDay {
      if let key = SeptenaDate.format(day) { keys.append(key) }
      guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
      day = next
    }
    return keys
  }

  /// The unratified band that rides on top of Today — loose captures and
  /// agent proposals (docs/TRIAGE_BAND_SPEC.md). This is why the sidebar has
  /// no separate Inbox row: the band IS the inbox, and it lives here, exactly
  /// as the SwiftUI Today renders it.
  // MARK: - Rolled-into-Today banner
  //
  // The counterpart of `TaskListView.newTodosBanner`. NOTE this is a BANNER,
  // not a bucket: there is no separate "review" section, and an earlier
  // version of the parity doc was wrong about that. The rows it counts are
  // already on Today; the notice just says how many of them arrived on their
  // own because a date set earlier has now come round.
  //
  // Dismissal persists today's date, so it stays gone for the rest of the day
  // and returns tomorrow — the SAME UserDefaults key SwiftUI uses, so
  // dismissing in one shell dismisses in the other.

  // MARK: - Claude reconnect cue
  //
  // The AppKit twin of `ClaudeReconnectCue(.card)`, which Septask's SwiftUI
  // shell puts at the top of Today (`TaskListView.taskListHeader`). Same
  // gate, same copy, same tap: the app never auto-presents the Apple sign-in,
  // so a lapsed token needs a row the user can press. Without it the fast
  // shell had no in-app recovery at all — the connection just stopped working.
  //
  // Today only, like SwiftUI: it is the landing surface, and a reconnect
  // prompt on every project page would be a nag.

  /// True during the brief post-reconnect flash. Held here rather than read
  /// off the provider because it is a UI beat, not gateway state — the same
  /// role `justReconnected` plays in the SwiftUI cue.
  private var justReconnectedClaude = false

  private func reconnectCue() -> [Row] {
    let provider = ClaudeGatewayProvider.shared
    guard provider.isEnabled, provider.needsReauth || justReconnectedClaude
    else { return [] }
    if justReconnectedClaude { return [.reconnectCue(state: .reconnected)] }
    if provider.isRefreshing { return [.reconnectCue(state: .refreshing)] }
    // A real failure (network etc.) — a user-cancel leaves `lastError` nil,
    // so the row stays in its calm default copy instead of crying wolf.
    return [.reconnectCue(state: provider.lastError != nil ? .failed : .idle)]
  }

  private func reconnectClaude() {
    let provider = ClaudeGatewayProvider.shared
    guard !justReconnectedClaude, !provider.isRefreshing else { return }
    Task { @MainActor in
      guard await provider.refreshNow() else { return }
      justReconnectedClaude = true
      reload()
      try? await Task.sleep(for: .seconds(1.6))
      justReconnectedClaude = false
      reload()
    }
  }

  /// Follow the provider's observable state. `ClaudeGatewayProvider` is
  /// `@Observable`, and it only posts `.septenaClaudeGatewayChanged` on
  /// connect / disconnect / successful refresh — the flip to `needsReauth`
  /// that MAKES this row appear posts nothing. So track the properties
  /// themselves; `withObservationTracking` fires once per change, hence the
  /// re-arm on every callback.
  private func trackClaudeGatewayState() {
    withObservationTracking {
      let provider = ClaudeGatewayProvider.shared
      _ = provider.isEnabled
      _ = provider.needsReauth
      _ = provider.isRefreshing
      _ = provider.lastError
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.trackClaudeGatewayState()
        // The cue only renders on Today; nothing else in the list moves.
        if self.filter == .today { self.reload() }
      }
    }
  }

  private func rolledInBanner(_ pool: [SeptenaTask]) -> [Row] {
    let today = SeptenaDate.today
    // Account-wide, not per-device: `SettingsMirror` resolves the synced
    // dismissal against the device-local mirror, so dismissing on one device
    // clears the banner on all of them.
    guard SettingsMirror.rolledInDismissedOn(context: context) != today
    else { return [] }
    // Read from the rows already on Today, exactly like `rolledInReview`:
    // scheduled STRICTLY before today. A task scheduled FOR today, or merely
    // due today, isn't "new" — the user placed it.
    let count = pool.filter { task in
      guard task.status == .open, let scheduled = task.scheduled, !scheduled.isEmpty
      else { return false }
      return String(scheduled.prefix(10)) < today
    }.count
    guard count > 0 else { return [] }
    return [.rolledInBanner(count: count)]
  }

  private func dismissRolledInBanner() {
    SettingsMirror.dismissRolledIn(on: SeptenaDate.today, context: context,
                                   engine: SeptenaServices.shared.ckEngine)
    reload()
  }

  // MARK: - Reminders inbox
  //
  // The AppKit counterpart of `RemindersInboxSection`. Same placement as
  // SwiftUI's `remindersRow`: on Today only, ABOVE the Inbox, and ONLY when
  // something is actually pending — no setup CTAs here, so a user who has
  // never nominated a Reminders list sees nothing rather than a permanent
  // prompt (SwiftUI passes `showsSetupCTAs: false` for exactly this).
  // Setup lives in Settings, which is the hosted SwiftUI pane, so there is no
  // second copy of the grant-access flow.
  //
  // Import semantics are the SwiftUI ones, unchanged: create a task carrying
  // the reminder's title, due date (as a DEADLINE) and notes, then delete the
  // original so dedupe is automatic and re-import is impossible.

  /// Play the amber promote cue on every row that was just pinned to Today —
  /// the gold ring at the checkbox plus the row wash, the two halves SwiftUI
  /// plays together (`playTodayPromotePulse` + `playPromoteWash`). Rows that
  /// scrolled out of view simply have no cell; the set is cleared either way,
  /// so a cue can never fire late against an unrelated row.
  private func playPendingPromoteFlashes() {
    defer { pendingPromoteFlash.removeAll() }
    guard !pendingPromoteFlash.isEmpty, !KitMotion.reduce else { return }
    for (index, row) in rows.enumerated() {
      guard let id = row.task?.id, pendingPromoteFlash.contains(id) else { continue }
      (tableView.rowView(atRow: index, makeIfNecessary: false) as? KitCardRowView)?
        .playPromoteWash()
      (tableView.view(atColumn: 0, row: index, makeIfNecessary: false)
        as? SeptaskKitTaskCell)?.playTodayPromotePulse()
    }
  }

  /// The pending reminders, as Inbox rows.
  ///
  /// NOT a section of their own any more. A pending Apple Reminder is by
  /// definition an Inbox item — unratified inbound work that hasn't been
  /// placed — which is exactly what the Inbox already holds. It used to get
  /// its own "From Reminders" header, which asserted that it was a different
  /// KIND of thing when it is the same kind from a different source, and gave
  /// a transient staging queue the same visual rank as your permanent Inbox.
  ///
  /// The Inbox already merges two populations this way (agent proposals and
  /// loose captures), distinguished by ROW TREATMENT rather than by section.
  /// Reminders are the third, and they wear a `↓` where a checkbox would go —
  /// they are not tasks yet, so they must not offer a checkbox: it could only
  /// mean "import and complete" (two acts conflated) or "complete a thing that
  /// doesn't exist".
  ///
  /// They sort to the TOP of the Inbox: they are the only rows carrying an
  /// extra step before they are even real.
  private func reminderRows() -> [Row] {
    guard !reminderPairs.isEmpty else { return [] }
    var rows: [Row] = reminderPairs.map { pair in
      Row.reminder(pair.view,
                   importing: bulkImportingReminders
                     || importingReminderID == pair.view.id)
    }
    // Bulk import only earns a line when there is a bulk to import. With one
    // waiting, the row itself IS the one-click action.
    if reminderPairs.count > 1 {
      rows.append(.importAllReminders(count: reminderPairs.count,
                                      importing: bulkImportingReminders))
    }
    return rows
  }

  /// Re-read the nominated list. Clears the block when access was revoked or
  /// the list was un-nominated, so a change in Settings takes effect here
  /// without a relaunch.
  private func refreshReminders() {
    let bridge = RemindersBridge.shared
    guard filter == .today, bridge.access == .granted, let calendar = bridge.sourceList()
    else {
      guard !reminderPairs.isEmpty else { return }
      reminderPairs = []
      reload()
      return
    }
    Task { @MainActor in
      let fetched = await bridge.pendingReminders(in: calendar)
      let pairs = fetched.map { ($0, ImportedReminder($0)) }
      // Only rebuild when the set actually changed — `.EKEventStoreChanged`
      // fires for every edit in every Reminders list, including ones we don't
      // mirror, and a needless reload would fight an open editor.
      guard pairs.map(\.1.id) != reminderPairs.map(\.view.id) else { return }
      reminderPairs = pairs
      reload()
    }
  }

  private func importReminder(_ id: String) {
    guard !bulkImportingReminders, importingReminderID == nil,
          let pair = reminderPairs.first(where: { $0.view.id == id }) else { return }
    importingReminderID = id
    reload()
    let created = mutator.create(title: pair.view.title,
                                 deadline: pair.view.dueDate,
                                 notes: pair.view.notes)
    try? RemindersBridge.shared.delete([pair.reminder])
    reminderPairs.removeAll { $0.view.id == id }
    importingReminderID = nil
    // Undoable like any other create. Redo re-creates (purge is a real
    // delete), and it deliberately does NOT put the reminder back in Apple
    // Reminders — that row is gone from EventKit and re-creating it there
    // would be a write to another app's data on the user's behalf.
    TaskUndo.recordCreate(
      name: String(localized: "Import Reminder", comment: "SeptaskKit: undo action"),
      ids: [created.id], mutator: mutator,
      rebuild: { [weak self] in
        guard let self else { return [] }
        return [self.mutator.create(title: pair.view.title,
                                    deadline: pair.view.dueDate,
                                    notes: pair.view.notes).id]
      })
    reload()
  }

  private func importAllReminders() {
    guard !bulkImportingReminders, !reminderPairs.isEmpty else { return }
    bulkImportingReminders = true
    reload()
    let pairs = reminderPairs
    var createdIDs: [String] = []
    for pair in pairs {
      createdIDs.append(mutator.create(title: pair.view.title,
                                       deadline: pair.view.dueDate,
                                       notes: pair.view.notes).id)
    }
    try? RemindersBridge.shared.delete(pairs.map(\.reminder))
    reminderPairs = []
    bulkImportingReminders = false
    TaskUndo.recordCreate(
      name: String(localized: "Import Reminders", comment: "SeptaskKit: undo action"),
      ids: createdIDs, mutator: mutator,
      rebuild: { [weak self] in
        guard let self else { return [] }
        return pairs.map { pair in
          self.mutator.create(title: pair.view.title,
                              deadline: pair.view.dueDate,
                              notes: pair.view.notes).id
        }
      })
    reload()
  }

  /// The Inbox — every unratified row, whatever its source: pending Apple
  /// Reminders first, then agent proposals and loose captures.
  ///
  /// Rendered even when empty: the Inbox header carries the `+`, so it is the
  /// capture slot whether or not anything sits in it. Matches
  /// `TaskListView.triageSection`, which shows the section whenever
  /// `allowsInlineCreate` regardless of row count.
  private func triageBand() -> [Row] {
    let band = LocalCache.tasks(in: context, filter: .triage)
    let reminders = reminderRows()
    // The count includes pending reminders — they ARE Inbox items now, and a
    // header that excluded them would be lying about what sits below it. The
    // bulk-import line is an action, not an item, so it doesn't count.
    let count = band.count + reminderPairs.count
    return [.header(id: "inbox",
                    title: String(localized: "Inbox", comment: "Smart list title"),
                    icon: .symbol("tray"), count: count)]
      + reminders
      + band.map(chipped)
  }

  /// The "New task" line, or nothing while a create is in flight — then the
  /// row being typed into reads as the slot itself rather than sitting under a
  /// duplicate prompt. `pendingNewTaskId` clears on commit (and on an
  /// abandoned empty row, which is purged), and the reload that follows puts a
  /// fresh line back.
  ///
  /// Emitted by the CALLER, not by `triageBand`, because Today's Inbox run is
  /// the triage band PLUS the loose rows that `groupedByList` emits before its
  /// first group header — the same `allInbox` split SwiftUI's `triageSection`
  /// makes. Appending it to the band alone parked it above those loose rows.
  private var newTaskLine: [Row] {
    pendingNewTaskId == nil ? [Row.newTask] : []
  }

  /// An MCP-authored row can satisfy both the triage band and Today (the band
  /// keys off the agent cue, not the date fields), so Today's own rows drop
  /// anything already shown in the band above.
  private func withoutTriage(_ pool: [SeptenaTask]) -> [SeptenaTask] {
    pool.filter { !$0.isInTriageBand }
  }

  /// A task row carrying its list-membership chip, for surfaces where the
  /// group doesn't already say where the task lives. Agent-authored triage
  /// rows are exactly why loose lists still need this — they can carry a
  /// project while sitting in the band.
  /// A row with no list-membership chip — scoped pages already name their
  /// context. It still carries a filing capsule where the gate allows one
  /// (an area page ranks area-direct rows against that area's projects).
  private func unchipped(_ task: SeptenaTask) -> Row {
    .task(task, chip: nil, suggestion: filingSuggestions[task.id])
  }

  private func chipped(_ task: SeptenaTask) -> Row {
    .task(task, chip: chip(for: task), suggestion: filingSuggestions[task.id])
  }

  /// Per-row top filing pick, snapshotted each reload so the capsule paints on
  /// the same frame as the row. The GATE is `TaskFilingSuggestions`, shared
  /// with the SwiftUI list — this only decides when to ask.
  private func refreshFilingSuggestions(pool: [SeptenaTask]) {
    guard TaskRowFlags.filingSuggestionsEnabled else {
      if !filingSuggestions.isEmpty { filingSuggestions = [:] }
      return
    }
    let structure = StructureCache.snapshot(in: context)
    TaskFilingSuggestions.prime(filter: filter, context: context,
                                engine: SuggestionEngine.shared,
                                projects: structure.projects, areas: structure.areas)
    let childIds = Self.childProjectIds(in: structure.projects)
    var fresh: [String: SuggestionEngine.Suggestion] = [:]
    for task in pool {
      if let top = TaskFilingSuggestions.top(for: task, filter: filter,
                                             engine: SuggestionEngine.shared,
                                             childProjectIds: childIds) {
        fresh[task.id] = top
      }
    }
    filingSuggestions = fresh
  }

  /// One-tap filing from the capsule — always the TOP pick.
  private func applyFilingSuggestion(taskID: String) {
    guard let suggestion = filingSuggestions[taskID] else { return }
    applyFilingSuggestion(taskID: taskID, suggestion: suggestion)
  }

  /// File a task into one ranked pick — the AppKit twin of
  /// `TaskListView.applySuggestion`, same order and the same side effects.
  /// Both offers share it: the capsule passes its top pick, the context
  /// menu's "Suggested" section passes whichever row the user chose.
  private func applyFilingSuggestion(taskID: String,
                                     suggestion: SuggestionEngine.Suggestion) {
    guard let task = LocalCache.allTasks(in: context).first(where: { $0.id == taskID })
    else { return }
    let before = [TaskUndo.FilingSnapshot(task)]
    let wasInTriage = task.isInTriageBand
    // Implicit "not this": the user accepted THIS pick, so there is nothing to
    // reject — rejection only fires when they file somewhere else. Clearing
    // stops the engine re-offering a pick that has now been acted on.
    SuggestionEngine.shared.clearSuggestion(for: taskID)
    switch suggestion.kind {
    case .area: mutator.moveToArea(id: taskID, area: suggestion.id)
    case .project: mutator.moveToProject(id: taskID, project: suggestion.id)
    }
    // Filing is engagement — clears the agent cue so the row leaves the Inbox.
    mutator.acknowledge(id: taskID)
    if filter == .today, wasInTriage { pendingPromoteFlash.insert(taskID) }
    TaskUndo.recordMove(before: before, context: context, mutator: mutator)
    reload()
    playPendingPromoteFlashes()
  }

  private func chip(for task: SeptenaTask) -> Chip? {
    let snapshot = StructureCache.snapshot(in: context)
    if let projectId = task.project,
       let project = snapshot.projects.first(where: { $0.id == projectId }) {
      return Chip(symbol: "number", title: project.title)
    }
    if let areaId = task.area,
       let area = snapshot.areas.first(where: { $0.id == areaId }) {
      return Chip(symbol: "folder", title: area.title)
    }
    return nil
  }

  /// The grouped open list — reference implementation is TaskListView's
  /// `orderedFromGroupedOpen`: loose tasks, then each area (direct tasks,
  /// then its projects), then loose projects. Sidebar order throughout
  /// (StructureCache). Headers only appear above non-empty groups, and carry
  /// the same glyph + count as their sidebar row.
  // MARK: - Project/area page chrome (screen title, logged footer)

  /// The current project/area's id, when the list is scoped to one — the
  /// same value both the title row and the logged-footer state key key off.
  private var scopeId: String? {
    switch filter {
    case .project(let id), .area(let id): return id
    default: return nil
    }
  }

  /// The page's own big title — an area's emoji/dot or a project's
  /// completion ring, plus its name at a larger rung than an in-list group
  /// header. macOS windows have no automatic "large title" the way an iOS
  /// nav bar does, so this is what stands in for it, same as the SwiftUI
  /// destination screens.
  /// One standard component on EVERY page, not just project/area — the
  /// smart lists use the same symbols the sidebar rows do
  /// (`NavigationState.filterIcon`), so a page's title always matches the
  /// icon you clicked in the sidebar to get there.
  private func screenTitleRow() -> Row? {
    let snapshot = StructureCache.snapshot(in: context)
    switch filter {
    case .today:
      return .screenTitle(title: String(localized: "Today", comment: "Smart list title"),
                          icon: .symbol("sun.max.fill"))
    case .triage:
      return .screenTitle(title: String(localized: "Inbox", comment: "Smart list title"),
                          icon: .symbol("tray"))
    case .upcoming:
      return .screenTitle(title: String(localized: "Upcoming", comment: "Smart list title"),
                          icon: .symbol("calendar"))
    case .repeating:
      return .screenTitle(title: String(localized: "Repeating", comment: "Smart list title"),
                          icon: .symbol("arrow.clockwise"))
    case .unscheduled:
      return .screenTitle(title: String(localized: "Anytime", comment: "Smart list title"),
                          icon: .symbol("rectangle.stack.fill"))
    case .logbook:
      return .screenTitle(title: String(localized: "Logbook", comment: "Smart list title"),
                          icon: .symbol("checkmark"))
    case .recentlyDeleted:
      return .screenTitle(title: String(localized: "Recently Deleted", comment: "Smart list title"),
                          icon: .symbol("trash"))
    case .project(let id):
      guard let project = snapshot.projects.first(where: { $0.id == id }) else { return nil }
      let progress = projectProgress()[id] ?? 0
      return .screenTitle(title: project.title, icon: .project(progress))
    case .area(let id):
      guard let area = snapshot.areas.first(where: { $0.id == id }) else { return nil }
      return .screenTitle(title: area.title, icon: area.emoji.map(GroupIcon.emoji) ?? .areaDot)
    }
  }

  /// Same UserDefaults key AND encoding `TaskListView`'s
  /// `scopeLoggedExpandedData` (`@AppStorage`-backed `Data` holding a
  /// JSON `Set<String>` of expanded project/area ids) uses — sharing it
  /// means expand/collapse state agrees between this shell and the classic
  /// SwiftUI window instead of drifting into two independent trackers.
  private static let loggedExpandedKey = "septena.tasks.projectLoggedExpanded"

  private func loggedExpandedIds() -> Set<String> {
    guard let data = UserDefaults.standard.data(forKey: Self.loggedExpandedKey) else { return [] }
    return (try? JSONDecoder().decode(Set<String>.self, from: data)) ?? []
  }

  /// Project detail partitioned by heading — mirrors
  /// `TaskListView.projectGroupedRows`: the un-headed block first, then each
  /// heading as a divider followed by its member tasks. Tasks whose
  /// `heading` points at a since-deleted divider fall back into the
  /// un-headed block. Headings come from `LocalCache.headings(inProject:)`
  /// (they are excluded from every `tasks(in:filter:)` read).
  private func projectGrouped(open: [SeptenaTask], projectId: String) -> [Row] {
    let headings = LocalCache.headings(inProject: projectId, in: context)
    let headingIds = Set(headings.map(\.id))
    let unheaded = open.filter { task in
      guard let h = task.heading else { return true }
      return !headingIds.contains(h)
    }
    var result: [Row] = unheaded.map(unchipped)
    for heading in headings {
      result.append(.task(heading, chip: nil, suggestion: nil))
      let members = open.filter { $0.heading == heading.id }
      result.append(contentsOf: members.map(unchipped))
    }
    // Last, before the logged footer the caller appends — the same place
    // `TaskListView.projectGroupedRows` puts `addSectionButton`.
    result.append(.addSection)
    return result
  }

  /// Things-style footer: "Show N logged items" / collapsed by default,
  /// expanding into the completed tasks for this page. Matches
  /// `TaskListView.scopeLoggedSection` exactly (same copy, same sort —
  /// newest-completed-first).
  private func loggedFooterRows(completed: [SeptenaTask]) -> [Row] {
    guard let scopeId, !completed.isEmpty else { return [] }
    let expanded = loggedExpandedIds().contains(scopeId)
    var rows: [Row] = [.loggedFooter(count: completed.count, expanded: expanded)]
    if expanded {
      rows.append(contentsOf: completed.map(unchipped))
    }
    return rows
  }

  func toggleLoggedExpanded() {
    guard let scopeId else { return }
    var ids = loggedExpandedIds()
    if ids.contains(scopeId) { ids.remove(scopeId) } else { ids.insert(scopeId) }
    UserDefaults.standard.set((try? JSONEncoder().encode(ids)) ?? Data(),
                              forKey: Self.loggedExpandedKey)
    // Hard reload, not the diffed animated path: this can insert/remove a
    // whole BLOCK of rows below the footer in one go, and an instant
    // reveal/collapse reads as correct disclosure behavior on its own —
    // no need to fight the diff machinery for what's an infrequent toggle.
    reload(animated: false)
  }

  private func groupedByList(_ pool: [SeptenaTask], inboxFooter: [Row] = []) -> [Row] {
    let snapshot = StructureCache.snapshot(in: context)
    let byProject = Dictionary(grouping: pool.filter { $0.project != nil },
                               by: { $0.project! })
    let byArea = Dictionary(grouping: pool.filter { $0.project == nil && $0.area != nil },
                            by: { $0.area! })
    let loose = pool.filter { $0.project == nil && $0.area == nil }
    let progress = projectProgress()

    // Loose rows keep their chips: an agent proposal can name a project while
    // still sitting in the ungrouped band.
    // `inboxFooter` closes the Inbox run — Today's "New task" line sits after
    // the loose rows and before the first group header.
    var result: [Row] = loose.map(chipped) + inboxFooter
    func appendProject(_ project: Project) {
      guard let tasks = byProject[project.id], !tasks.isEmpty else { return }
      result.append(.header(id: "p-\(project.id)", title: project.title,
                            icon: .project(progress[project.id] ?? 0),
                            count: tasks.count))
      result.append(contentsOf: tasks.map(unchipped))
    }
    for area in snapshot.areas {
      if let direct = byArea[area.id], !direct.isEmpty {
        result.append(.header(id: "a-\(area.id)", title: area.title,
                              icon: area.emoji.map(GroupIcon.emoji) ?? .areaDot,
                              count: direct.count))
        result.append(contentsOf: direct.map(unchipped))
      }
      for project in snapshot.projects where project.area == area.id {
        appendProject(project)
      }
    }
    for project in snapshot.projects where project.area == nil {
      appendProject(project)
    }
    return result
  }

  /// Completion ratio per project — done / (done + open), matching the
  /// sidebar's ring. Cancelled rows don't count either way.
  private func projectProgress() -> [String: Double] {
    var done: [String: Int] = [:]
    var open: [String: Int] = [:]
    for task in LocalCache.allTasks(in: context) where !task.isHeading {
      guard let project = task.project else { continue }
      switch task.status {
      case .done: done[project, default: 0] += 1
      case .open: open[project, default: 0] += 1
      case .cancelled: break
      }
    }
    var result: [String: Double] = [:]
    for (project, doneCount) in done {
      let total = doneCount + (open[project] ?? 0)
      result[project] = total > 0 ? Double(doneCount) / Double(total) : 0
    }
    for project in open.keys where result[project] == nil {
      result[project] = 0
    }
    return result
  }

  /// Animated structural diff: rows keep identity by `key`, so completes fade
  /// out where they sit, arrivals slide in, and everything else stays put.
  /// Falls back to a hard reload for filter switches / first population, and
  /// collapses to an instant swap under Reduce Motion.
  private func apply(_ new: [Row], animated: Bool) {
    let old = rows
    rows = new

    guard animated, !old.isEmpty, !KitMotion.reduce else {
      tableView.reloadData()
      return
    }

    let oldKeys = old.map(\.key)
    let newKeys = new.map(\.key)
    if oldKeys == newKeys {
      var changed = IndexSet()
      for index in new.indices where new[index] != old[index] { changed.insert(index) }
      if !changed.isEmpty {
        tableView.reloadData(forRowIndexes: changed, columnIndexes: [0])
      }
      return
    }

    // Plain difference — deliberately NOT the move-inferring variant
    // (`inferringMoves`; see the appkit-inferring-moves lint rule). An inferred
    // move's `associatedWith` offset is in the ORIGINAL array's coordinate
    // space, but NSTableView applies a begin/endUpdates batch INCREMENTALLY
    // (each call relative to the state the preceding calls left behind), so by
    // the time the move ran its source index had already been shifted by the
    // removes before it — `moveRow` then picked up whatever row had slid into
    // that slot. Moving a task between Today's list groups reproduced it
    // exactly: the group header got moved instead of the task, so the task
    // appeared under the wrong heading and looked duplicated. A plain
    // remove+insert is what NSTableView's incremental batch is defined for
    // (and reads better here anyway — a row changing groups should leave and
    // arrive, not glide).
    tableView.beginUpdates()
    for change in newKeys.difference(from: oldKeys) {
      switch change {
      case .remove(let offset, _, _):
        tableView.removeRows(at: [offset], withAnimation: KitMotion.removeRows)
      case .insert(let offset, _, _):
        tableView.insertRows(at: [offset], withAnimation: KitMotion.insertRows)
      }
    }
    tableView.endUpdates()
    // The insert/remove/move above can change which SURVIVING rows are now
    // first/last in their card — refresh every on-screen row's geometry
    // directly rather than relying on the content-diff below, which only
    // catches a row whose own `Row` value changed (see the doc comment on
    // `refreshCardGeometry`).
    refreshCardGeometry()

    // Surviving rows whose content changed (rename, date, today flag).
    let oldByKey = Dictionary(old.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    var changed = IndexSet()
    for index in new.indices {
      if let previous = oldByKey[new[index].key], previous != new[index] {
        changed.insert(index)
      }
    }
    if !changed.isEmpty {
      tableView.reloadData(forRowIndexes: changed, columnIndexes: [0])
    }
  }

  /// Whether a row command has anything to act on — drives menu enablement.
  var hasActionableSelection: Bool { !actionableSelection.isEmpty }

  /// Copy the selection's titles — one per line. Reached through Edit ▸ Copy
  /// (the table implements `copy(_:)`, so the standard menu item finds it on
  /// the responder chain) as well as the row menus.
  func copySelection() {
    let titles = actionableSelection.map(\.title)
    guard !titles.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(titles.joined(separator: "\n"), forType: .string)
  }

  /// Paste (⌘V) — one task per non-blank line of the clipboard's text, filed
  /// exactly where ⌘N would file it. Reached through Edit ▸ Paste (the table
  /// implements `paste(_:)`, so the standard menu item finds it on the
  /// responder chain), the mirror of `copySelection` above.
  func pasteTasks() {
    guard let text = NSPasteboard.general.string(forType: .string),
          let context = creationContext(inInbox: false) else {
      NSSound.beep()
      return
    }
    let titles = text
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !titles.isEmpty else {
      NSSound.beep()
      return
    }
    // Reversed: `create` inserts at the top of its group (TaskOrder's
    // insert-at-top, the same placement ⌘N gets), so laying the lines down
    // back-to-front is what leaves the pasted block in reading order.
    var created: [String] = []
    for title in titles.reversed() {
      let task = mutator.create(title: title, area: context.area, project: context.project,
                                scheduled: context.scheduled, today: context.today,
                                atBottom: false)
      created.append(task.id)
    }
    recordUndo(name: String(localized: "Paste Tasks", comment: "SeptaskKit: undo action"),
               undo: { [weak self] in
                 for id in created { self?.mutator.purge(id: id) }
                 self?.reload()
               },
               redo: { [weak self] in
                 guard let self else { return }
                 // Re-create rather than un-purge: a purge is a real delete,
                 // so there is no row left to restore.
                 var again: [String] = []
                 for title in titles.reversed() {
                   let task = self.mutator.create(
                     title: title, area: context.area, project: context.project,
                     scheduled: context.scheduled, today: context.today, atBottom: false)
                   again.append(task.id)
                 }
                 created = again
                 self.reload()
               })
    reload()
    // Select what just landed, so ⌘K / move / delete act on the paste.
    let ids = Set(created)
    let indexes = IndexSet(rows.indices.filter {
      guard let id = rows[$0].task?.id else { return false }
      return ids.contains(id)
    })
    if !indexes.isEmpty {
      tableView.selectRowIndexes(indexes, byExtendingSelection: false)
      tableView.scrollRowToVisible(indexes.first!)
    }
  }

  /// Paste is offered only where a new task can actually land, and only when
  /// the clipboard holds text — drives Edit ▸ Paste enablement.
  var canPasteTasks: Bool {
    guard creationContext(inInbox: false) != nil,
          let text = NSPasteboard.general.string(forType: .string)
    else { return false }
    return text.contains { !$0.isWhitespace }
  }

  func duplicateSelection() {
    let originals = actionableSelection
    guard !originals.isEmpty else { return }
    let ids = originals.map { mutator.duplicate($0).id }
    reload()
    recordCreateUndo(name: String(localized: "Duplicate Task",
                                  comment: "SeptaskKit: undo action"),
                     ids: ids,
                     rebuild: { [weak self] in
                       guard let self else { return [] }
                       return originals.map { self.mutator.duplicate($0).id }
                     })
  }

  /// File the selection. `nil` area+project is the loose "No List" case.
  func move(to destination: KitMoveMenu.Destination) {
    let selection = actionableSelection
    guard !selection.isEmpty else { return }
    // Captured before mutating, so undo can restore each task's EXACT prior
    // (project, area) pair — not just "the previous list", since a batch move
    // can start from several different lists at once.
    let previous = selection.map { (id: $0.id, project: $0.project, area: $0.area) }

    func apply(_ destination: KitMoveMenu.Destination, project: String?, area: String?, id: String) {
      switch destination {
      case .none:
        mutator.moveToProject(id: id, project: nil)
        mutator.moveToArea(id: id, area: nil)
      case .area(let areaId):
        mutator.moveToProject(id: id, project: nil)
        mutator.moveToArea(id: id, area: areaId)
      case .project(let projectId):
        mutator.moveToProject(id: id, project: projectId)
      }
    }

    recordUndo(name: String(localized: "Move Task", comment: "SeptaskKit: undo action"),
              undo: { [weak self] in
                guard let self else { return }
                for entry in previous {
                  self.mutator.moveToProject(id: entry.id, project: entry.project)
                  self.mutator.moveToArea(id: entry.id, area: entry.area)
                }
                self.reload()
                self.onStoreChanged?()
              },
              redo: { [weak self] in
                guard let self else { return }
                for entry in previous {
                  apply(destination, project: entry.project, area: entry.area, id: entry.id)
                }
                self.reload()
                self.onStoreChanged?()
              })

    for entry in previous {
      apply(destination, project: entry.project, area: entry.area, id: entry.id)
      mutator.acknowledge(id: entry.id)
    }
    reload()
    onStoreChanged?()
  }

  /// ⌘M / ⌘⇧M — the type-to-filter Move picker (`SeptaskKitMovePicker`), the
  /// AppKit counterpart of SwiftUI's `MovePickerSheet`. Built once, reused —
  /// it re-reads structure fresh on every `show`.
  private lazy var movePicker = SeptaskKitMovePicker { [weak self] destination in
    self?.move(to: destination)
  }

  /// Exact destination for the picker's checkmark — project if filed there,
  /// otherwise the area, otherwise No List.
  private func currentMoveDestination(for task: SeptenaTask) -> KitMoveMenu.Destination? {
    if let project = task.project { return .project(project) }
    if let area = task.area { return .area(area) }
    return KitMoveMenu.Destination.none
  }

  /// `anchor` is the view the picker should hang off when exactly one row is
  /// moving — the row itself by default, or the composer's List pill when the
  /// pill asked. A multi-selection has no single row to point at, so it falls
  /// back to the centered command panel (SeptaskKitSurface.swift, Tier 2).
  func presentMoveMenu(anchor: KitSurfaceAnchor? = nil) {
    let selection = actionableSelection
    guard !selection.isEmpty else { return }
    let single = selection.count == 1
    let title = single
      ? String(localized: "Move", comment: "SeptaskKit: Move picker title")
      : String(localized: "Move \(selection.count) Tasks",
               comment: "SeptaskKit: Move picker title (plural)")
    let current = single ? currentMoveDestination(for: selection[0]) : nil
    movePicker.show(current: current, title: title,
                    anchor: single ? (anchor ?? selectedRowAnchor ?? .window) : .window)
  }

  /// The focused row's rect, for a Tier 1 surface to anchor to.
  private var selectedRowAnchor: KitSurfaceAnchor? {
    guard tableView.selectedRow >= 0 else { return nil }
    return .rect(tableView.rect(ofRow: tableView.selectedRow), tableView)
  }

  /// Open the Repeat editor for the current selection, anchored to the row it
  /// edits like When and Deadline. It is intentionally the only AppKit rule
  /// picker: no preset submenu can silently flatten a fixed schedule into an
  /// after-completion rule.
  func presentRecurrencePanel(anchor: KitSurfaceAnchor? = nil) {
    let selection = actionableSelection
    guard !selection.isEmpty else { NSSound.beep(); return }
    guard case .rect(let rect, let host)? = anchor ?? selectedRowAnchor else {
      NSSound.beep()
      return
    }
    SeptaskKitRepeatPopover.present(
      selection: SeptaskKitRepeatSelection(selection),
      relativeTo: rect, of: host
    ) { [weak self] result in
      guard let self else { return }
      let before = selection.map(self.scheduleSnapshot)
      for task in selection {
        if result.clears {
          self.mutator.setRecurrence(id: task.id, recurrence: nil)
        } else {
          // Overlay only the axes the editor answered onto THIS row's own
          // rule. Handing the editor's whole draft to every row is what used
          // to flatten a mixed selection onto row one's cadence.
          self.mutator.setRecurrence(id: task.id,
                                     recurrence: result.applied(to: task.recurrence))
          // `setRecurrence` clears the pause across the series, so editing
          // the cadence of a PAUSED series would silently resume it.
          // Re-assert the pause being kept (or the one just chosen); the
          // false case needs no write, since setRecurrence already cleared it.
          if result.paused ?? task.recurrencePaused {
            self.mutator.setRecurrencePaused(id: task.id, paused: true)
          }
        }
        self.refreshComposerRow(taskId: task.id)
      }
      self.reload()
      self.recordScheduleUndo(name: String(localized: "Change Repeat",
                                           comment: "SeptaskKit: undo action"),
                              before: before)
      self.onStoreChanged?()
    }
  }

  /// Explicit pause/resume is kept separate from editing the cadence, so a
  /// person can stop a series without reopening the rule controls.
  func setRecurrencePaused(_ paused: Bool) {
    let selection = actionableSelection.filter { $0.recurrence != nil }
    guard !selection.isEmpty else { NSSound.beep(); return }
    let before = selection.map(scheduleSnapshot)
    for task in selection {
      mutator.setRecurrencePaused(id: task.id, paused: paused)
      refreshComposerRow(taskId: task.id)
    }
    reload()
    recordScheduleUndo(name: paused
                       ? String(localized: "Pause Repeat", comment: "SeptaskKit: undo action")
                       : String(localized: "Resume Repeat", comment: "SeptaskKit: undo action"),
                       before: before)
    onStoreChanged?()
  }

  /// Start the next copy of each selected repeating task without completing
  /// the current one. The backend makes this idempotent, so invoking it again
  /// after a sync delay cannot create duplicates.
  func createNextCopySelection() {
    let repeating = actionableSelection.filter { $0.recurrence != nil }
    guard !repeating.isEmpty else { NSSound.beep(); return }
    for task in repeating { _ = mutator.createNextOccurrence(id: task.id) }
    reload()
    onStoreChanged?()
  }

  /// The rows a command applies to (headings excluded — they only rename).
  private var actionableSelection: [SeptenaTask] {
    tableView.selectedRowIndexes.compactMap { row in
      guard rows.indices.contains(row), let task = rows[row].task else { return nil }
      return task.isHeading ? nil : task
    }
  }

  // MARK: - Mutations

  func toggleCompleteSelection() {
    // Mark-complete has no meaning in the trash — checkbox tap and ⌘K both
    // route to restore there (see `toggle(id:)`).
    guard filter != .recentlyDeleted else {
      restoreTasks(actionableSelection.map(\.id))
      return
    }
    let selection = actionableSelection
    guard !selection.isEmpty else { return }
    apply(completing: selection.filter { $0.status == .open },
         reopening: selection.filter { $0.status != .open })
  }

  /// Cancel open tasks in the selection — same settle beat as complete
  /// (linger struck-through, then leave for the Logbook). Already-finished
  /// rows are left alone; trash has nothing to cancel.
  func cancelSelection() {
    guard filter != .recentlyDeleted else { return }
    let open = actionableSelection.filter { $0.status == .open }
    guard !open.isEmpty else { return }
    applyCancel(open)
  }

  private func toggle(id: String) {
    // In the trash, a checkbox tap means "bring this back" — mark-complete
    // has no meaning for an already-deleted row.
    guard filter != .recentlyDeleted else {
      restoreTasks([id])
      return
    }
    guard let task = rows.compactMap(\.task).first(where: { $0.id == id }) else { return }
    if task.status == .open {
      apply(completing: [task], reopening: [])
    } else {
      apply(completing: [], reopening: [task])
    }
  }

  // MARK: - Recently Deleted (restore / purge)

  private func restoreTasks(_ ids: [String]) {
    guard !ids.isEmpty else { return }
    recordUndo(name: String(localized: "Restore Task", comment: "SeptaskKit: undo action"),
              undo: { [weak self] in
                for id in ids { self?.mutator.delete(id: id) }
                self?.reload()
              },
              redo: { [weak self] in
                for id in ids { self?.mutator.restore(id: id) }
                self?.reload()
              })
    for id in ids { mutator.restore(id: id) }
    reload()
  }

  private func purgeTasks(_ ids: [String]) {
    // No undo: purge is a real SwiftData delete, not a tombstone — there is
    // no state left to restore from.
    for id in ids { mutator.purge(id: id) }
    reload()
  }

  /// Complete/reopen a batch. Completed rows in drop-done lists get the
  /// settle beat — restyled checked in place, then removed after a beat by
  /// the diffed reload's fade. Views that keep completed rows (Logbook) and
  /// pure reopens refresh immediately.
  ///
  /// Restyling and `isSettling = true` happen BEFORE any `mutator` call —
  /// `TaskMutator.complete`/`uncomplete` post `.septenaTasksChanged`
  /// SYNCHRONOUSLY (`commitAndPush` → `TaskChange.post`, on the calling
  /// thread, before the call returns). `reload()`'s only defense against that
  /// racing ahead of the restyle is the `isSettling` flag, so it has to
  /// already be true by the time the first mutator call fires — setting it
  /// afterward is a no-op, the notification's reload already ran and wiped
  /// the row before the linger ever started. This IS why the linger
  /// previously didn't linger.
  private func apply(completing: [SeptenaTask], reopening: [SeptenaTask]) {
    if !completing.isEmpty || !reopening.isEmpty {
      let completingIds = completing.map(\.id)
      let reopeningIds = reopening.map(\.id)
      recordUndo(name: completingIds.isEmpty
                    ? String(localized: "Reopen Task", comment: "SeptaskKit: undo action")
                    : String(localized: "Complete Task", comment: "SeptaskKit: undo action"),
                undo: { [weak self] in
                  for id in completingIds { self?.mutator.uncomplete(id: id) }
                  for id in reopeningIds { self?.mutator.complete(id: id) }
                  self?.reload()
                },
                redo: { [weak self] in
                  for id in completingIds { self?.mutator.complete(id: id) }
                  for id in reopeningIds { self?.mutator.uncomplete(id: id) }
                  self?.reload()
                })
    }
    guard !completing.isEmpty else {
      if isSettling {
        // Un-checking a row that is still lingering. It's on screen, restyled
        // done but not yet dropped, so ⌘K (or a second checkbox tap) has to
        // read as "unchecked" right now — those seconds are exactly the window
        // in which the completion is meant to be reversible. `reload()` is
        // suppressed while settling (that suppression IS the linger), so
        // restyle in place and let the settle timer's own reload resolve the
        // list. Rows still lingering from the same batch keep their beat.
        restyle(ids: reopening.map(\.id), to: .open)
        for task in reopening { mutator.uncomplete(id: task.id) }
        return
      }
      for task in reopening { mutator.uncomplete(id: task.id) }
      reload()
      return
    }

    let dropsCompleted: Bool
    switch filter {
    case .logbook, .recentlyDeleted: dropsCompleted = false
    default: dropsCompleted = true
    }
    guard dropsCompleted else {
      for task in completing {
        mutator.complete(id: task.id)
        mutator.acknowledge(id: task.id)
      }
      for task in reopening { mutator.uncomplete(id: task.id) }
      reload()
      return
    }

    isSettling = true
    // The row stays where it is, restyled as completed, for the settle window
    // — you see what you just did before it leaves.
    restyle(ids: completing.map(\.id), to: .done)

    for task in completing {
      mutator.complete(id: task.id)
      mutator.acknowledge(id: task.id)
    }
    for task in reopening { mutator.uncomplete(id: task.id) }
    beginSettle()
  }

  /// Cancel a batch with the same linger-then-drop path as `apply(completing:)`.
  /// Undo reopens via `uncomplete` (status → open), matching SwiftUI's cancel.
  private func applyCancel(_ tasks: [SeptenaTask]) {
    let ids = tasks.map(\.id)
    recordUndo(name: String(localized: "Cancel Task", comment: "SeptaskKit: undo action"),
              undo: { [weak self] in
                for id in ids { self?.mutator.uncomplete(id: id) }
                self?.reload()
              },
              redo: { [weak self] in
                for id in ids { self?.mutator.cancel(id: id) }
                self?.reload()
              })

    let dropsFinished: Bool
    switch filter {
    case .logbook, .recentlyDeleted: dropsFinished = false
    default: dropsFinished = true
    }
    guard dropsFinished else {
      for id in ids { mutator.cancel(id: id) }
      reload()
      return
    }

    isSettling = true
    restyle(ids: ids, to: .cancelled)
    for id in ids { mutator.cancel(id: id) }
    beginSettle()
  }

  /// Repaint the given rows at a new status WITHOUT going through the store.
  /// This is how the settle window shows what you just did: `rows` holds
  /// `SeptenaTask` values, so restyling means swapping the row's own copy and
  /// reloading just those indexes. Used in both directions — checked on
  /// complete/cancel, and back to open when a lingering row is un-checked.
  private func restyle(ids: [String], to status: TaskStatus) {
    let wanted = Set(ids)
    var restyled = IndexSet()
    for index in rows.indices {
      if case .task(var task, let chip, let suggestion) = rows[index],
         wanted.contains(task.id) {
        task.status = status
        rows[index] = .task(task, chip: chip, suggestion: suggestion)
        restyled.insert(index)
      }
    }
    guard !restyled.isEmpty else { return }
    tableView.reloadData(forRowIndexes: restyled, columnIndexes: [0])
  }

  /// Hold the list still for the settle window, then let the completed rows
  /// fade out on the next diffed reload.
  ///
  /// Reloads are suppressed meanwhile rather than merely delayed: completing a
  /// task queues a CloudKit change, and the batch's `.septenaTasksChanged`
  /// would otherwise land mid-linger and yank the row out early — which is
  /// exactly the "row vanishes the instant you check it" feel this removes.
  private func beginSettle() {
    settleWorkItem?.cancel()
    isSettling = true
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.isSettling = false
      self.settleWorkItem = nil
      self.reload()
    }
    settleWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + KitMotion.settleDelay, execute: work)
  }

  /// End the linger immediately — used when the list itself changes out from
  /// under it (a different filter), where holding stale rows makes no sense.
  private func cancelSettle() {
    settleWorkItem?.cancel()
    settleWorkItem = nil
    isSettling = false
  }

  // MARK: - Dates (⌘S When, ⌘⇧D Deadline, ⌘⇧. Clear)

  /// Anchor a date popover to the focused row and apply the choice to the
  /// whole actionable selection.
  func presentDatePopover(kind: SeptaskKitDatePopover.Kind) {
    let selection = actionableSelection
    guard !selection.isEmpty, tableView.selectedRow >= 0 else { return }

    let anchor = tableView.rect(ofRow: tableView.selectedRow)
    let initial: Date? = switch kind {
    case .when: KitDayFormat.date(fromWire: selection.first?.scheduled)
    case .deadline: KitDayFormat.date(fromWire: selection.first?.deadline)
    }

    SeptaskKitDatePopover.present(kind: kind, initial: initial,
                                  relativeTo: anchor, of: tableView) { [weak self] date, today in
      guard let self else { return }
      let before = selection.map(self.scheduleSnapshot)
      for task in selection {
        switch kind {
        case .when:
          if today {
            let target = KitDayFormat.todayDate()
            guard let mode = self.rescheduleMode(for: task, newDate: target) else { continue }
            self.mutator.reschedule(id: task.id, date: target, mode: mode)
            self.mutator.schedule(id: task.id, date: nil)
            self.mutator.moveToToday(id: task.id)
          } else {
            guard let mode = self.rescheduleMode(for: task, newDate: date) else { continue }
            self.mutator.reschedule(id: task.id, date: date, mode: mode)
            self.mutator.removeFromToday(id: task.id)
          }
        case .deadline:
          self.mutator.setDeadline(id: task.id, date: date)
        }
        self.mutator.acknowledge(id: task.id)
      }
      self.reload()
      self.recordScheduleUndo(
        name: kind == .when
          ? String(localized: "Change When", comment: "SeptaskKit: undo action")
          : String(localized: "Change Deadline", comment: "SeptaskKit: undo action"),
        before: before)
    }
  }

  /// Fixed-schedule repeats get the same two-way decision as the iOS shell.
  /// Returning nil means the user cancelled the move for that row.
  private func rescheduleMode(for task: SeptenaTask,
                              newDate: Date?) -> RecurrenceRescheduleMode? {
    guard let rule = task.recurrence, !rule.afterCompletion,
          SeptenaDate.format(newDate) != task.scheduled else {
      return .makeException
    }

    let chosen = KitPrompt.choice(
      title: String(localized: "Reschedule Repeating Task?",
                    comment: "SeptaskKit: fixed recurrence move"),
      message: String(localized:
        "Make Exception moves only this copy. Update Rule moves the repeating schedule to the new date.",
        comment: "SeptaskKit: fixed recurrence move"),
      options: [String(localized: "Make Exception",
                       comment: "SeptaskKit: fixed recurrence move"),
                String(localized: "Update Rule",
                       comment: "SeptaskKit: fixed recurrence move")])
    switch chosen {
    case 0: return .makeException
    case 1: return .updateRule
    default: return nil
    }
  }

  /// ⌘⇧. — drop both the schedule and the Today pin, leaving the task in
  /// Anytime. Matches `TaskRowShortcuts.clearSchedule`.
  func clearScheduleSelection() {
    let before = actionableSelection.map(scheduleSnapshot)
    for task in actionableSelection {
      mutator.schedule(id: task.id, date: nil)
      mutator.removeFromToday(id: task.id)
      mutator.acknowledge(id: task.id)
    }
    reload()
    recordScheduleUndo(name: String(localized: "Clear Dates",
                                    comment: "SeptaskKit: undo action"),
                       before: before)
  }

  func toggleTodaySelection() {
    let before = actionableSelection.map(scheduleSnapshot)
    for task in actionableSelection {
      if task.today {
        mutator.removeFromToday(id: task.id)
      } else {
        mutator.moveToToday(id: task.id)
        pendingPromoteFlash.insert(task.id)
      }
      mutator.acknowledge(id: task.id)
    }
    reload()
    playPendingPromoteFlashes()
    recordScheduleUndo(name: String(localized: "Toggle Today",
                                    comment: "SeptaskKit: undo action"),
                       before: before)
  }

  func deleteSelection() {
    let victims = actionableSelection
    guard !victims.isEmpty else { return }
    let anchor = tableView.selectedRowIndexes.first ?? 0
    if filter == .recentlyDeleted {
      // ⌘⌫ already means "delete" everywhere else; in the trash itself that
      // naturally reads as the final, permanent delete.
      purgeTasks(victims.map(\.id))
    } else {
      let ids = victims.map(\.id)
      recordUndo(name: String(localized: "Delete Task", comment: "SeptaskKit: undo action"),
                undo: { [weak self] in
                  for id in ids { self?.mutator.restore(id: id) }
                  self?.reload()
                },
                redo: { [weak self] in
                  for id in ids { self?.mutator.delete(id: id) }
                  self?.reload()
                })
      for task in victims {
        mutator.delete(id: task.id)
      }
      reload()
    }
    // Standard list behavior: selection moves to the nearest surviving row.
    if !rows.isEmpty {
      tableView.selectRowIndexes([min(anchor, rows.count - 1)],
                                 byExtendingSelection: false)
    }
  }

  private func commitRename(id: String, title: String) {
    clearEditingTitle()
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let wasNew = (id == pendingNewTaskId)
    pendingNewTaskId = nil
    if wasNew, trimmed.isEmpty {
      // The ⌘N row was escaped/committed empty — it never really existed for
      // the user, so remove it entirely rather than soft-deleting to trash.
      mutator.purge(id: id)
    } else if wasNew {
      // The row was born titleless, so undo here means "un-create", not
      // "rename back to empty" — which is what the rename branch below used
      // to register for a brand-new row.
      mutator.update(id: id, title: trimmed)
      recordNewTaskUndo(id: id)
    } else if let task = rows.compactMap(\.task).first(where: { $0.id == id }),
              !trimmed.isEmpty, trimmed != task.title {
      let previousTitle = task.title
      recordUndo(name: String(localized: "Rename Task", comment: "SeptaskKit: undo action"),
                undo: { [weak self] in
                  self?.mutator.update(id: id, title: previousTitle)
                  self?.reload()
                },
                redo: { [weak self] in
                  self?.mutator.update(id: id, title: trimmed)
                  self?.reload()
                })
      mutator.update(id: id, title: trimmed)
    }
    reload()
    view.window?.makeFirstResponder(tableView)
  }

  // MARK: - Creation (⌘N)

  /// Create in the context being looked at — and, on mixed multi-group
  /// surfaces (Today / Anytime), in the area/project of the focused task so
  /// ⌘N stays in the group you're in rather than always dumping into Inbox.
  /// Upcoming schedules tomorrow (the minimal date that keeps the row visible
  /// in that list). The new row appears at the top of its group (TaskOrder's
  /// insert-at-top), selected, with the title editor open.
  /// `inInbox` is the foot-of-Inbox "New task" line: that row is anchored to
  /// the Inbox card, so it must create LOOSE work regardless of what is
  /// selected. Inheriting the focused row's filing there would file the task
  /// into that list and drop it straight out of the Inbox band the user just
  /// clicked in. ⌘N (inInbox: false) keeps inheriting, which is what makes it
  /// land in the group you are working in.
  func createTask(inInbox: Bool = false) {
    if isTitleEditorActive {
      // Commit the in-flight edit first; commitRename runs synchronously.
      view.window?.makeFirstResponder(tableView)
    }
    if composingTaskId != nil {
      // A composer left open would otherwise silently swallow the reload
      // below (reload() no-ops while `composingTaskId` is set) — the new
      // task would be created but never actually show up. Closing it first
      // gives ⌘N a clean slate no matter what was being edited before.
      collapseComposer(commit: true)
    }

    guard let context = creationContext(inInbox: inInbox) else {
      NSSound.beep()
      return
    }

    // Bottom-positioned for anything landing in the Inbox run: the "New task"
    // line sits at the FOOT of that run, so a top-positioned create opens the
    // editor at the top and shoves everything down — you ask for a new task at
    // the bottom of the list and the field appears somewhere else. `atBottom`
    // lands the row exactly where the line was, which is the same reason
    // SwiftUI's foot quick-add passes it ("inline captures land above the New
    // task row").
    //
    // This is keyed on the DESTINATION, not on which gesture asked. A loose
    // capture (no area, no project) is an Inbox row wherever it was typed, so
    // ⌘N from the Inbox page and ⌘N on Today with no list inherited both land
    // on the line — not above it. A ⌘N that inherits a list from the focused
    // row still files into that group at the top, unchanged.
    let landsInInboxRun = inInbox || (context.area == nil && context.project == nil)
    let task = mutator.create(title: "", area: context.area, project: context.project,
                              scheduled: context.scheduled, today: context.today,
                              atBottom: landsInInboxRun)
    pendingNewTaskId = task.id
    reload(animated: false)
    guard let row = rows.firstIndex(where: { $0.task?.id == task.id }) else { return }
    tableView.selectRowIndexes([row], byExtendingSelection: false)
    tableView.scrollRowToVisible(row)
    if inInbox {
      // The foot-of-Inbox line is a deliberately light capture affordance —
      // click, type, done. A pill rail there would be heavier than the
      // gesture that opened it.
      beginEditingRow(row)
    } else {
      // ⌘N opens the full composer, so a new task can be given its When /
      // Deadline / List / Repeat without a second gesture. The bare field
      // editor is still one keystroke away as ⌘R.
      beginComposing(id: task.id)
    }
  }

  /// Where a newly created task should be filed, given the list being looked
  /// at and (on mixed surfaces) the focused row. Returns nil in the two views
  /// that cannot hold new work — Logbook and Recently Deleted. Shared by ⌘N
  /// and paste so the two can never disagree about filing.
  private func creationContext(inInbox: Bool)
    -> (area: String?, project: String?, today: Bool, scheduled: Date?)? {
    var area: String?
    var project: String?
    var today = false
    var scheduled: Date?
    switch filter {
    case .today:
      today = true
      // Grouped Today: inherit the selected row's filing. Flat Today has no
      // groups, but the same inheritance still files under the focused list.
      if !inInbox, let focused = focusedTaskForCreate() {
        area = focused.area
        project = focused.project
      }
    case .unscheduled:
      if let focused = focusedTaskForCreate() {
        area = focused.area
        project = focused.project
      }
    case .project(let pid):
      project = pid
    case .area(let aid):
      area = aid
    case .upcoming:
      scheduled = KitDayFormat.tomorrow()
      // Upcoming isn't grouped by list, but still honor a focused task's
      // filing so ⌘N doesn't strand the new row in Inbox.
      if let focused = focusedTaskForCreate() {
        area = focused.area
        project = focused.project
      }
    case .triage: break
    // Repeating lists the templates that already carry a recurrence rule;
    // a plain new task can't join it, so ⌘N stays off there — same as the
    // two read-only lists.
    case .repeating, .logbook, .recentlyDeleted: return nil
    }
    return (area, project, today, scheduled)
  }

  /// Grouped Today only, mirroring `TaskListView.showsGroupedHeaderQuickAdd`
  /// (`filter == .today && todayGroupByList && allowsInlineCreate`). A flat
  /// Today has no per-list headers to hang a "+" on, and every other list is
  /// already scoped to one place, so ⌘N there needs no disambiguation.
  private var showsGroupedHeaderQuickAdd: Bool {
    filter == .today && todayGroupsByList
  }

  /// The header "+" — create straight into the area/project that header
  /// names. Deliberately the bare title editor rather than ⌘N's composer:
  /// this is a quick-add affordance, the same weight as SwiftUI's inline
  /// quick-add draft and the foot-of-Inbox "New task" line.
  private func createTask(underHeaderId id: String) {
    guard let target = navigationTarget(forHeaderId: id) else { return }
    switch target {
    case .project(let projectId): createTask(inArea: nil, project: projectId)
    case .area(let areaId): createTask(inArea: areaId, project: nil)
    default: break
    }
  }

  /// Create with filing given OUTRIGHT, rather than derived from the filter
  /// and the focused row the way `createTask(inInbox:)` does. `today: true`
  /// because the only caller is a Today header — the row belongs both to
  /// Today and to that list, which is exactly what the header represents.
  private func createTask(inArea area: String?, project: String?) {
    if isTitleEditorActive {
      view.window?.makeFirstResponder(tableView)
    }
    if composingTaskId != nil {
      collapseComposer(commit: true)
    }
    let task = mutator.create(title: "", area: area, project: project,
                              scheduled: nil, today: true, atBottom: false)
    pendingNewTaskId = task.id
    reload(animated: false)
    guard let row = rows.firstIndex(where: { $0.task?.id == task.id }) else { return }
    tableView.selectRowIndexes([row], byExtendingSelection: false)
    tableView.scrollRowToVisible(row)
    beginEditingRow(row)
  }

  /// The task that should seed ⌘N's area/project — the table's focused row,
  /// falling back to the sole selected task when focus is on a header/empty.
  private func focusedTaskForCreate() -> SeptenaTask? {
    let row = tableView.selectedRow
    if row >= 0, let task = rows[row].task, !task.isHeading {
      return task
    }
    let selected = actionableSelection
    return selected.count == 1 ? selected[0] : nil
  }

  // MARK: - Editing entry points

  /// ⌘R only — a fast bare-title rename via the field editor, distinct from
  /// the full composer (Return / double-click). Some edits really are just
  /// fixing a typo.
  func beginEditSelectedRow() {
    let row = tableView.selectedRow
    // Nothing to rename on the "New task" line — it is selectable, so ⌘R can
    // land on it, but it carries no task.
    guard row >= 0, rows[row].task != nil else { return }
    beginEditingRow(row)
  }

  /// Standard AppKit way to act on a row synchronously right after inserting
  /// it: `makeIfNecessary: true` forces the cell into existence instead of
  /// hoping it's already been dequeued (a bare `reloadData()` doesn't
  /// guarantee that timing, so `false` here could silently no-op — the
  /// exact way ⌘N could create a task and NOT actually enter edit mode,
  /// leaving the title un-editable until the user clicked it themselves).
  /// One retry on the next runloop turn as a backstop, so a fresh task is
  /// reliably ready to type into immediately.
  private func beginEditingRow(_ row: Int) {
    if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
      as? SeptaskKitTaskCell {
      markEditingTitle(atRow: row)
      cell.beginEditing()
      return
    }
    DispatchQueue.main.async { [weak self] in
      guard let self, self.rows.indices.contains(row) else { return }
      if let cell = self.tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
        as? SeptaskKitTaskCell {
        self.markEditingTitle(atRow: row)
        cell.beginEditing()
      }
    }
  }

  /// Flag the row as title-editing and repaint just that row view — NOT a
  /// `reloadData`, which would tear down the field editor we are about to
  /// attach (the same hazard `isTitleEditorActive` guards `reload()` against).
  private func markEditingTitle(atRow row: Int) {
    editingTaskId = rows[row].task?.id
    repaintEditingRow(row)
  }

  /// Clear the title-editing flag and repaint whichever row carried it.
  private func clearEditingTitle() {
    guard let id = editingTaskId else { return }
    editingTaskId = nil
    if let row = rows.firstIndex(where: { $0.task?.id == id }) {
      repaintEditingRow(row)
    }
  }

  private func repaintEditingRow(_ row: Int) {
    guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: false)
      as? KitCardRowView else { return }
    let taskId = rows[row].task?.id
    rowView.isEditingTitle = taskId != nil && taskId == editingTaskId
    rowView.needsDisplay = true
  }

  /// Return / double-click — expands the selected row into the inline
  /// composer (title + elective pill rail + notes), the AppKit counterpart of
  /// `TaskComposerCard` in `.inline` mode. Matches the SwiftUI shell, whose
  /// Return already opens the rich editor rather than a bare rename.
  func beginComposingSelectedRow() {
    // Nothing about a deleted task is editable — Return/double-click there
    // restores it instead (matching the checkbox), rather than opening dead
    // controls.
    guard filter != .recentlyDeleted else {
      restoreTasks(actionableSelection.map(\.id))
      return
    }
    let row = tableView.selectedRow
    // Return on the "New task" line creates, exactly as clicking it does.
    if rows.indices.contains(row), case .newTask = rows[row] {
      createTask(inInbox: true)
      return
    }
    guard row >= 0, let task = rows[row].task else { return }
    // A section heading has no pills/notes to open a full composer for —
    // same as the SwiftUI project page, renaming it is a bare title edit.
    guard !task.isHeading else {
      beginEditingRow(row)
      return
    }
    beginComposing(id: task.id)
  }

  @objc private func beginEditFromDoubleClick() {
    guard tableView.clickedRow >= 0, rows[tableView.clickedRow].task != nil else { return }
    tableView.selectRowIndexes([tableView.clickedRow], byExtendingSelection: false)
    beginComposingSelectedRow()
  }

  // MARK: - Inline composer (title + elective pills + notes)

  func beginComposing(id: String) {
    guard composingTaskId != id else { return }
    // Switching rows: fold the open one instantly so two height animations
    // don't fight; the newly opened row still expands.
    // Opening to peek must NOT acknowledge — cue == Inbox membership for
    // agent rows (same contract as SwiftUI `TaskComposer`). Disposition
    // paths (complete / when / move / today) ratify.
    if composingTaskId != nil { collapseComposer(commit: true, animated: false) }
    composingTaskId = id
    guard let row = rows.firstIndex(where: { $0.task?.id == id }) else {
      composingTaskId = nil
      return
    }
    tableView.selectRowIndexes([row], byExtendingSelection: false)
    // Swap to the composer cell first (clipped to the still-short row), then
    // animate the height open — `noteHeightOfRows` animates for view-based
    // tables when wrapped in an `NSAnimationContext` with non-zero duration.
    tableView.reloadData(forRowIndexes: [row], columnIndexes: [0])
    if let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? KitCardRowView {
      applyCardGeometry(rowView, atRow: row)
    }
    refreshCardGeometry()
    tableView.scrollRowToVisible(row)
    animateComposerHeight(ofRow: row)
    // Focus as soon as the cell exists so typing isn't gated on the expand.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.composingTaskId == id,
            let freshRow = self.rows.firstIndex(where: { $0.task?.id == id }),
            let cell = self.tableView.view(atColumn: 0, row: freshRow, makeIfNecessary: false)
              as? KitComposerCell
      else { return }
      cell.focusTitle()
    }
  }

  /// Fold the composing row back to a normal row. `commit` is false when the
  /// cell already committed itself (Return/Esc inside the title/notes field —
  /// see `KitComposerCell.control(_:doCommandBy:)`), true for every other path
  /// (switching to a different row, selecting elsewhere) so nothing typed is
  /// silently dropped.
  private func collapseComposer(commit: Bool, animated: Bool = true) {
    guard let taskId = composingTaskId else { return }
    if commit, let row = rows.firstIndex(where: { $0.task?.id == taskId }),
       let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
         as? KitComposerCell {
      // Mutator notifications fire sync; `reload()` no-ops while
      // `composingTaskId` is still set, so the height animation below owns
      // the visual fold instead of racing a full-list reload.
      cell.commit()
    }
    // Resign before the height fold — a live field editor would keep edit
    // chrome attached through the shrink.
    view.window?.makeFirstResponder(tableView)
    composingTaskId = nil
    composerNotesHeight = nil

    // ⌘N now opens the composer rather than the bare field editor, so the
    // abandoned-new-task rule has to live here too — a row created and closed
    // without ever being titled never existed for the user, so purge it
    // instead of folding an empty row back into the list. Same contract as
    // `commitRename`'s branch, and read AFTER `cell.commit()` so a title the
    // user did type has already landed on the model.
    if taskId == pendingNewTaskId {
      pendingNewTaskId = nil
      // Read the STORE, not `rows` — `SeptenaTask` is a struct, so the row
      // array still holds the pre-commit copy and a title the user just typed
      // would look empty here and get the row purged out from under them.
      let title = LocalCache.allTasks(in: context)
        .first { $0.id == taskId }?.title ?? ""
      if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        mutator.purge(id: taskId)
        reload()
        return
      }
      recordNewTaskUndo(id: taskId)
    }

    guard let row = rows.firstIndex(where: { $0.task?.id == taskId }) else {
      reload()
      return
    }
    // Pull the just-committed title/notes into the in-memory row so the
    // closed cell doesn't flash the pre-edit snapshot.
    refreshTaskRowInPlace(id: taskId)
    // Shrink FIRST while the composer cell is still on screen — its title
    // sits in the closed-row band, so the glyphs stay put as pills clip away.
    // Swapping to the task cell *before* the shrink would center the title
    // in the still-tall frame (a visible jump).
    animateComposerHeight(ofRow: row, animated: animated) { [weak self] in
      guard let self else { return }
      self.tableView.reloadData(forRowIndexes: [row], columnIndexes: [0])
      self.refreshCardGeometry()
      // Keep the just-closed task selected so Esc returns to the closed-row
      // keyboard surface (arrows / ⌘K / …) instead of an empty selection.
      if self.rows.indices.contains(row) {
        self.tableView.selectRowIndexes([row], byExtendingSelection: false)
      }
    }
  }

  /// Re-read one task from the store into `rows` without a full list rebuild —
  /// enough for the closed cell after a composer commit to show the new title.
  private func refreshTaskRowInPlace(id: String) {
    guard let index = rows.firstIndex(where: { $0.task?.id == id }),
          case .task(_, let chip, let suggestion) = rows[index],
          let fresh = LocalCache.allTasks(in: context).first(where: { $0.id == id })
    else { return }
    rows[index] = .task(fresh, chip: chip, suggestion: suggestion)
  }

  /// Animate (or jump, under Reduce Motion) a row's height to whatever
  /// `heightOfRow` currently returns — used for composer open/close and the
  /// notes-pill expand inside an already-open composer.
  private func animateComposerHeight(ofRow row: Int, animated: Bool = true,
                                     completion: (() -> Void)? = nil) {
    guard rows.indices.contains(row) else {
      completion?()
      return
    }
    let duration = animated ? KitMotion.composerAnimationDuration : 0
    if duration <= 0 {
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0
        tableView.noteHeightOfRows(withIndexesChanged: [row])
      }
      completion?()
      return
    }
    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = duration
      ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      ctx.allowsImplicitAnimation = true
      tableView.noteHeightOfRows(withIndexesChanged: [row])
    }, completionHandler: {
      // AppKit may call this off the main actor; hop back before touching UI.
      DispatchQueue.main.async { completion?() }
    })
  }

  /// Re-read the task from the store and refresh the composer cell's PILLS —
  /// used after a pill's popover/menu writes through the mutator. Deliberately
  /// does NOT call `wireComposer`/`cell.configure`: that would re-run
  /// `titleField.stringValue = task.title` and silently discard whatever
  /// title the user has typed but not yet committed (the same bug class as
  /// `SeptaskKitInspectorController.show(_:)`'s same-id guard exists for —
  /// this is the composer's version of it). Still re-binds the action
  /// closures via `bindComposerActions`, since those close over `task` by
  /// value and would otherwise keep acting on a stale pre-edit snapshot.
  private func refreshComposerRow(taskId: String) {
    guard composingTaskId == taskId,
          let fresh = LocalCache.allTasks(in: context).first(where: { $0.id == taskId }),
          let row = rows.firstIndex(where: { $0.task?.id == taskId }),
          let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
            as? KitComposerCell
    else { return }
    cell.refreshPills(with: fresh, listName: listName(for: fresh))
    bindComposerActions(cell, task: fresh)
  }

  /// A header id built by `groupedByList`'s "p-"/"a-" prefix has a real
  /// area/project to drill into; "inbox"/"agenda" don't. ONE place this is
  /// decided — `heightOfRow`'s extra margin and `viewFor:`'s click/cursor
  /// wiring both call this rather than each re-deriving it, which is exactly
  /// the kind of duplicated logic that let them drift apart before.
  private func isNavigableHeaderId(_ id: String) -> Bool {
    id.hasPrefix("p-") || id.hasPrefix("a-")
  }

  /// A header that STARTS a new section gets the extra margin above it —
  /// area/project headers on Today/Anytime, and Upcoming's day headers, which
  /// break the list the same way. Separate from `isNavigableHeaderId`: a day
  /// header owns the same air but has no list to drill into.
  private func headerStartsSection(_ id: String) -> Bool {
    isNavigableHeaderId(id) || id.hasPrefix("day-")
  }

  private func navigationTarget(forHeaderId id: String) -> TaskFilter? {
    if id.hasPrefix("p-") { return .project(String(id.dropFirst(2))) }
    if id.hasPrefix("a-") { return .area(String(id.dropFirst(2))) }
    return nil
  }

  private func listName(for task: SeptenaTask) -> String? {
    let snapshot = StructureCache.snapshot(in: context)
    if let id = task.project, let project = snapshot.projects.first(where: { $0.id == id }) {
      return project.title
    }
    if let id = task.area, let area = snapshot.areas.first(where: { $0.id == id }) {
      return area.title
    }
    return nil
  }

  /// Populate a composer cell — title, notes, pills — and wire its actions.
  /// Called ONLY when the cell is first dequeued for a task (`viewFor:`).
  /// Never call this on a refresh; see `refreshComposerRow`.
  private func wireComposer(_ cell: KitComposerCell, task: SeptenaTask) {
    cell.configure(with: task, listName: listName(for: task))
    composerNotesHeight = cell.currentNotesHeight
    bindComposerActions(cell, task: task)
  }

  /// The pill/checkbox action closures, all closing over `task` by value —
  /// shared by the initial wire-up and every post-pill refresh, so a stale
  /// closure never lingers after the task actually changes underneath it.
  private func bindComposerActions(_ cell: KitComposerCell, task: SeptenaTask) {
    cell.onNotesVisibilityChanged = { [weak self, weak cell] in
      guard let self, let cell,
            let row = self.rows.firstIndex(where: { $0.task?.id == task.id }) else { return }
      self.composerNotesHeight = cell.currentNotesHeight
      self.animateComposerHeight(ofRow: row)
    }
    cell.onNotesHeightChanged = { [weak self, weak cell] in
      guard let self, let cell,
            let row = self.rows.firstIndex(where: { $0.task?.id == task.id }) else { return }
      let next = cell.currentNotesHeight
      guard self.composerNotesHeight != next else { return }
      self.composerNotesHeight = next
      // Typing growth should track the caret immediately — no open/close easing.
      self.animateComposerHeight(ofRow: row, animated: false)
    }

    cell.onCommit = { [weak self] title, notes in
      guard let self else { return }
      let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty, trimmed != task.title {
        self.mutator.update(id: task.id, title: trimmed)
      }
      if notes != task.notes {
        self.mutator.update(id: task.id, notes: notes)
      }
    }
    cell.onCollapse = { [weak self] in self?.collapseComposer(commit: false) }

    cell.onAction = { [weak self] action in
      guard let self else { return }
      switch action {
      case .discuss:
        // Local on-device kickoff (`ConversationEngine.advance`), the same call
        // SwiftUI's Discuss pill makes — no gateway in the loop, which is why
        // the pill can exist here at all. The reload afterwards is what puts
        // the first turn on screen in the inspector.
        cell.setDiscussWorking(true)
        Task { @MainActor [weak self] in
          _ = await ConversationEngine.advance(task: task)
          cell.setDiscussWorking(false)
          self?.reload()
        }
      case .toggleComplete:
        let wasOpen = task.status == .open
        self.recordUndo(name: wasOpen
                          ? String(localized: "Complete Task", comment: "SeptaskKit: undo action")
                          : String(localized: "Reopen Task", comment: "SeptaskKit: undo action"),
                        undo: { [weak self] in
                          if wasOpen { self?.mutator.uncomplete(id: task.id) }
                          else { self?.mutator.complete(id: task.id) }
                          self?.reload()
                        },
                        redo: { [weak self] in
                          if wasOpen { self?.mutator.complete(id: task.id) }
                          else { self?.mutator.uncomplete(id: task.id) }
                          self?.reload()
                        })
        if wasOpen {
          self.mutator.complete(id: task.id)
          self.mutator.acknowledge(id: task.id)
        } else {
          self.mutator.uncomplete(id: task.id)
        }
        self.collapseComposer(commit: true)

      case .toggleToday:
        if task.today {
          self.mutator.removeFromToday(id: task.id)
        } else {
          self.mutator.moveToToday(id: task.id)
        }
        self.mutator.acknowledge(id: task.id)
        self.refreshComposerRow(taskId: task.id)

      case .when(let anchor):
        SeptaskKitDatePopover.present(kind: .when,
                                      initial: KitDayFormat.date(fromWire: task.scheduled),
                                      relativeTo: anchor.bounds, of: anchor) { [weak self] date, today in
          guard let self else { return }
          if today {
            self.mutator.moveToToday(id: task.id)
          } else {
            self.mutator.schedule(id: task.id, date: date)
            self.mutator.removeFromToday(id: task.id)
          }
          self.mutator.acknowledge(id: task.id)
          self.refreshComposerRow(taskId: task.id)
        }

      case .deadline(let anchor):
        SeptaskKitDatePopover.present(kind: .deadline,
                                      initial: KitDayFormat.date(fromWire: task.deadline),
                                      relativeTo: anchor.bounds, of: anchor) { [weak self] date, _ in
          self?.mutator.setDeadline(id: task.id, date: date)
          self?.mutator.acknowledge(id: task.id)
          self?.refreshComposerRow(taskId: task.id)
        }

      case .list(let anchor):
        // Reuses the exact destination list ⌘M / ⌘⇧M pops up — one picker, not a
        // second to keep in sync — anchored to the pill the user clicked. It
        // acts on the current selection, which is this row (selecting it is
        // how compose mode began).
        self.presentMoveMenu(anchor: .rect(anchor.bounds, anchor))
        self.refreshComposerRow(taskId: task.id)

      case .repeatRule(let anchor):
        self.presentRecurrencePanel(anchor: .rect(anchor.bounds, anchor))
        self.refreshComposerRow(taskId: task.id)
      }
    }
  }

  // MARK: - Context menu (same commands + equivalents as the Task menu)

  /// Same commands, same order, same bindings as the menu bar's Task menu and
  /// as `TaskRowCommands` in the SwiftUI shell — one vocabulary everywhere.
  /// Terminal outcomes (complete / cancel / delete) share one submenu so the
  /// three stay next to each other instead of Delete living alone at the bottom.
  private func buildContextMenu() -> NSMenu {
    let menu = NSMenu()
    menu.delegate = self
    menu.addItem(item(String(localized: "Rename", comment: "SeptaskKit: context menu"),
                      #selector(menuRename), "r", [.command]))
    infoMenuItem.action = #selector(menuInspector)
    infoMenuItem.target = self
    infoMenuItem.keyEquivalent = "i"
    infoMenuItem.keyEquivalentModifierMask = [.command, .option]
    menu.addItem(infoMenuItem)
    menu.addItem(item(String(localized: "Copy", comment: "SeptaskKit: context menu"),
                      #selector(menuCopy), "c", [.command]))
    menu.addItem(item(String(localized: "Duplicate", comment: "SeptaskKit: context menu"),
                      #selector(menuDuplicate), "d", [.command]))
    menu.addItem(.separator())

    let completeItem = NSMenuItem(
      title: String(localized: "Complete", comment: "SeptaskKit: context menu"),
      action: nil, keyEquivalent: "")
    let completeMenu = NSMenu()
    completeMenu.addItem(item(String(localized: "Mark as Complete", comment: "SeptaskKit: context menu"),
                              #selector(menuToggleComplete), "k", [.command]))
    completeMenu.addItem(item(String(localized: "Cancel Task", comment: "SeptaskKit: context menu"),
                              #selector(menuCancel), "", []))
    completeMenu.addItem(.separator())
    completeMenu.addItem(item(String(localized: "Delete", comment: "SeptaskKit: context menu"),
                              #selector(menuDelete), "\u{8}", [.command]))
    completeItem.submenu = completeMenu
    menu.addItem(completeItem)

    // Titles and visibility are set in `menuNeedsUpdate` — "Toggle Today" is
    // never shown as a bare toggle; on the Today list the item is hidden
    // entirely (Clear Schedule is the exit).
    todayMenuItem.action = #selector(menuToggleToday)
    todayMenuItem.target = self
    todayMenuItem.keyEquivalent = "t"
    todayMenuItem.keyEquivalentModifierMask = [.command]
    menu.addItem(todayMenuItem)

    menu.addItem(item(String(localized: "When…", comment: "SeptaskKit: context menu"),
                      #selector(menuWhen), "s", [.command]))
    menu.addItem(item(String(localized: "Deadline…", comment: "SeptaskKit: context menu"),
                      #selector(menuDeadline), "d", [.command, .shift]))

    clearScheduleMenuItem.title = String(localized: "Clear Schedule",
                                         comment: "SeptaskKit: context menu")
    clearScheduleMenuItem.action = #selector(menuClearSchedule)
    clearScheduleMenuItem.target = self
    clearScheduleMenuItem.keyEquivalent = "."
    clearScheduleMenuItem.keyEquivalentModifierMask = [.command, .shift]
    menu.addItem(clearScheduleMenuItem)

    // Move remains a bounded destination submenu. Repeat is a full editor,
    // however, so it opens a panel rather than forcing the rule through a
    // preset submenu.
    moveMenuItem.title = String(localized: "Move to", comment: "SeptaskKit: context menu")
    moveMenuItem.keyEquivalent = "m"
    moveMenuItem.keyEquivalentModifierMask = [.command, .shift]
    menu.addItem(moveMenuItem)

    menu.addItem(item(String(localized: "Repeat…", comment: "SeptaskKit: context menu"),
                      #selector(menuRepeat), "", []))
    pauseRepeatMenuItem.action = #selector(menuPauseResumeRepeat)
    pauseRepeatMenuItem.target = self
    pauseRepeatMenuItem.title = String(localized: "Pause Repeat", comment: "SeptaskKit: recurrence")
    menu.addItem(pauseRepeatMenuItem)
    menu.addItem(item(String(localized: "Create Next Copy", comment: "SeptaskKit: recurrence"),
                      #selector(menuCreateNextCopy), "", []))
    return menu
  }

  /// The trash's own vocabulary — nothing else on the normal menu (rename,
  /// complete, dates…) means anything for an already-deleted row.
  private func buildRecentlyDeletedMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(item(String(localized: "Restore", comment: "SeptaskKit: context menu"),
                      #selector(menuRestore), "", []))
    menu.addItem(.separator())
    menu.addItem(item(String(localized: "Delete Permanently", comment: "SeptaskKit: context menu"),
                      #selector(menuDelete), "\u{8}", [.command]))
    return menu
  }

  @objc private func menuRestore() { restoreTasks(actionableSelection.map(\.id)) }

  // MARK: - Headings (project sections)
  //
  // A heading is a real task (`isHeading`, `kind == "heading"`) — creating,
  // renaming, and deleting one call the SAME `TaskMutator` methods and use
  // the SAME confirmation copy the SwiftUI project page does
  // (`TaskListView.commitHeadingCreate`/`commitHeadingRename`, and the
  // "Delete this section?" dialog), so a section behaves identically in
  // either shell. Project pages GROUP by heading (`projectGrouped`) and
  // drag-filing calls `setHeading` (`acceptGroupedTaskDrop`) — same
  // shape as SwiftUI's `handleGroupedTaskDrop`/`handleHeadingDrop`.

  /// Right-click on blank list space, project pages only — where "New
  /// Section" lives when there's no heading row to right-click yet.
  private func buildBlankSpaceMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(item(String(localized: "New Section", comment: "SeptaskKit: heading CRUD"),
                      #selector(menuNewSection), "", []))
    return menu
  }

  /// The page title's own navigation dropdown — the AppKit counterpart of
  /// `TaskNavMenu`: every sidebar destination in the SAME order (smart
  /// lists, top-level projects, each area + its projects, Recently Deleted
  /// when non-empty), a checkmark on whichever one is current, jump on
  /// click.
  ///
  /// The smart-list set and order come from
  /// `KitSidebarDestination.smartLists` — the SAME list the AppKit sidebar
  /// builds its rows from (and, one level down, the same
  /// `TaskDestinations.sidebarRoutes` the SwiftUI sidebar and `TaskNavMenu`
  /// read). That's what keeps the dropdown from drifting: it used to spell
  /// its four rows out by hand and silently lost Next and Repeating when the
  /// sidebar gained them. Titles and icons ride off `Route` for the same
  /// reason. Built fresh on every click (like `TaskNavMenu`'s lazy
  /// `menuContent`), not cached — structure changes shouldn't leave a stale
  /// menu around.
  private func buildNavMenu() -> NSMenu {
    let menu = NSMenu()
    let snapshot = StructureCache.snapshot(in: context)

    // One row per destination. Title and icon both ride off the destination
    // (`Route`-backed), so a menu row can't label or picture a list
    // differently from its sidebar row.
    func destItem(_ destination: KitSidebarDestination) -> NSMenuItem {
      let menuItem = NSMenuItem(title: destination.title,
                                action: #selector(navMenuSelect(_:)), keyEquivalent: "")
      menuItem.target = self
      menuItem.image = NSImage(systemSymbolName: destination.symbol,
                               accessibilityDescription: nil)
      menuItem.representedObject = destination
      // Next is its own pane, so the task list never reads as current while
      // it's showing — the checkmark only ever lands on a filter row.
      if case .filter(let destFilter, _) = destination {
        menuItem.state = destFilter == self.filter ? .on : .off
      }
      return menuItem
    }

    func projectItem(_ project: Project) -> NSMenuItem {
      destItem(.filter(.project(project.id), title: project.title))
    }

    for destination in KitSidebarDestination.smartLists {
      menu.addItem(destItem(destination))
    }

    let topLevel = snapshot.projects.filter { $0.area == nil && $0.status == .active }
    if !topLevel.isEmpty {
      menu.addItem(.separator())
      for project in topLevel { menu.addItem(projectItem(project)) }
    }

    for area in snapshot.areas {
      let areaProjects = snapshot.projects.filter { $0.area == area.id && $0.status == .active }
      menu.addItem(.separator())
      menu.addItem(destItem(.filter(.area(area.id), title: area.title)))
      for project in areaProjects { menu.addItem(projectItem(project)) }
    }

    if !LocalCache.tasks(in: context, filter: .recentlyDeleted).isEmpty {
      menu.addItem(.separator())
      menu.addItem(destItem(.filter(.recentlyDeleted, title: TaskFilter.recentlyDeleted.title)))
    }

    return menu
  }

  @objc private func navMenuSelect(_ sender: NSMenuItem) {
    guard let destination = sender.representedObject as? KitSidebarDestination else { return }
    // Same path Quick Find and a group-header click use — steer the
    // sidebar, which drives the list, so a jump always leaves the two in
    // agreement.
    onNavigate?(destination)
  }

  /// Right-click on a heading row: rename (same field-editor path as any
  /// task) and delete — nothing else on the normal task menu applies to a
  /// section divider.
  private func buildHeadingContextMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(item(String(localized: "Rename", comment: "SeptaskKit: context menu"),
                      #selector(menuRename), "r", [.command]))
    menu.addItem(.separator())
    menu.addItem(item(String(localized: "Delete Section", comment: "SeptaskKit: heading CRUD"),
                      #selector(menuDeleteHeading), "", []))
    return menu
  }

  /// New Section lands as a named row and opens for editing, the way ⌘N lands
  /// a new task and the way Finder lands a new folder. It used to stop the app
  /// with a modal text prompt while the row it was about to create sat right
  /// there, editable.
  @objc private func menuNewSection() {
    guard case .project(let projectId) = filter else { return }
    let heading = mutator.createHeading(
      title: String(localized: "New Section", comment: "SeptaskKit: heading CRUD"),
      project: projectId)
    reload()
    guard let id = heading?.id,
          let row = rows.firstIndex(where: { $0.task?.id == id }) else { return }
    tableView.selectRowIndexes([row], byExtendingSelection: false)
    tableView.scrollRowToVisible(row)
    beginEditingRow(row)
  }

  @objc private func menuDeleteHeading() {
    let row = tableView.selectedRow
    guard row >= 0, let heading = rows[row].task, heading.isHeading else { return }
    // Exact copy from TaskListView's confirmationDialog — same story either shell.
    guard KitPrompt.confirmDestructive(
      title: String(localized: "Delete this section?", comment: "Project heading delete confirm"),
      message: String(localized: "Its tasks stay in the project.",
                      comment: "Project heading delete confirm"),
      confirmTitle: String(localized: "Delete Section", comment: "SeptaskKit: heading CRUD")
    ) else { return }
    mutator.delete(id: heading.id)
    reload()
  }

  private func item(_ title: String, _ action: Selector, _ key: String,
                    _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    item.target = self
    return item
  }

  @objc private func menuToggleComplete() { toggleCompleteSelection() }
  @objc private func menuCancel() { cancelSelection() }
  @objc private func menuToggleToday() { toggleTodaySelection() }
  @objc private func menuRename() { beginEditSelectedRow() }
  @objc private func menuInspector() { onToggleInspector?() }
  @objc private func menuCopy() { copySelection() }
  @objc private func menuDuplicate() { duplicateSelection() }

  @objc private func menuMoveTo(_ sender: NSMenuItem) {
    let snapshot = StructureCache.snapshot(in: context)
    guard let destination = KitMoveMenu.destination(for: sender,
                                                    areas: snapshot.areas,
                                                    projects: snapshot.projects)
    else { return }
    move(to: destination)
  }

  /// A pick from the "Suggested" section. The tag indexes `menuSuggestions`,
  /// which `menuNeedsUpdate` rebuilt for the row that is still selected.
  @objc private func menuApplySuggestion(_ sender: NSMenuItem) {
    let selection = actionableSelection
    guard selection.count == 1, let task = selection.first,
          menuSuggestions.indices.contains(sender.tag) else { return }
    applyFilingSuggestion(taskID: task.id, suggestion: menuSuggestions[sender.tag])
  }

  @objc private func menuWhen() { presentDatePopover(kind: .when) }
  @objc private func menuDeadline() { presentDatePopover(kind: .deadline) }
  @objc private func menuClearSchedule() { clearScheduleSelection() }

  @objc private func menuRepeat() { presentRecurrencePanel() }

  @objc private func menuPauseResumeRepeat() {
    let selection = actionableSelection.filter { $0.recurrence != nil }
    guard !selection.isEmpty else { return }
    setRecurrencePaused(!selection.allSatisfy(\.recurrencePaused))
  }
  @objc private func menuCreateNextCopy() { createNextCopySelection() }
  @objc private func menuDelete() { deleteSelection() }
}

// MARK: - Context menu freshness

extension SeptaskKitTaskListController: NSMenuDelegate {
  /// Refresh selection-dependent items each time the menu opens — move
  /// destinations from live structure, and Today / Clear Schedule from the
  /// current selection (see `refreshPlacementMenuItems`).
  func menuNeedsUpdate(_ menu: NSMenu) {
    let snapshot = StructureCache.snapshot(in: context)
    moveMenuItem.submenu = KitMoveMenu.build(areas: snapshot.areas,
                                             projects: snapshot.projects,
                                             target: self,
                                             action: #selector(menuMoveTo(_:)))
    refreshSuggestedMenuSection(menu, projects: snapshot.projects)
    refreshPlacementMenuItems()
  }

  /// The "Suggested" section — the same ranked filing picks the row capsule
  /// offers, as menu items. The capsule is the one-tap path for the TOP pick;
  /// this is where the runners-up live, exactly like the SwiftUI menu's
  /// `Section("Suggested")` (`TaskListContextMenu`). Single selection only:
  /// the picks are ranked for one title, so a multi-selection has no subject.
  private func refreshSuggestedMenuSection(_ menu: NSMenu, projects: [Project]) {
    for item in suggestedMenuItems { menu.removeItem(item) }
    suggestedMenuItems = []
    menuSuggestions = []

    let selection = actionableSelection
    guard selection.count == 1, let task = selection.first else { return }
    // Same GATE as the capsule — `TaskFilingSuggestions` decides which rows
    // are suggestible, so the menu and the capsule can never disagree.
    guard let ranked = TaskFilingSuggestions.ranked(
      for: task, filter: filter, engine: SuggestionEngine.shared,
      childProjectIds: Self.childProjectIds(in: projects)), !ranked.isEmpty
    else { return }

    // Above the placement commands, so the section sits where SwiftUI puts it
    // — read the row, then act on where it should go.
    let anchor = menu.index(of: todayMenuItem)
    guard anchor >= 0 else { return }

    menuSuggestions = ranked
    var items: [NSMenuItem] = [
      NSMenuItem.sectionHeader(title: String(localized: "Suggested",
                                             comment: "SeptaskKit: context menu section"))
    ]
    for (index, suggestion) in ranked.enumerated() {
      let item = NSMenuItem(title: String(localized: "Move to \(suggestion.title)",
                                          comment: "SeptaskKit: filing suggestion menu item"),
                            action: #selector(menuApplySuggestion(_:)), keyEquivalent: "")
      item.target = self
      item.tag = index
      item.image = NSImage(systemSymbolName: suggestion.kind == .area ? "tray" : "folder",
                           accessibilityDescription: nil)
      items.append(item)
    }
    items.append(.separator())
    for (offset, item) in items.enumerated() { menu.insertItem(item, at: anchor + offset) }
    suggestedMenuItems = items
  }

  /// Area → its active child projects, the shape `TaskFilingSuggestions` asks
  /// for. One builder, so the capsule and the menu rank an area-direct row
  /// against the same set of destinations.
  private static func childProjectIds(in projects: [Project]) -> (String) -> Set<String> {
    { areaId in
      Set(projects.filter { $0.area == areaId && $0.status == .active }.map(\.id))
    }
  }

  /// Directional Today labels; hide the Today item on the Today list (you're
  /// already there — Clear Schedule is the exit). Hide Clear Schedule when
  /// nothing would change.
  private func refreshPlacementMenuItems() {
    let selection = actionableSelection

    infoMenuItem.title = UserDefaults.standard.bool(forKey: SettingsKey.septaskInspectorVisible)
      ? String(localized: "Hide Info", comment: "SeptaskKit: context menu")
      : String(localized: "Show Info", comment: "SeptaskKit: context menu")

    // On Today: every row is already "on Today", so a Today action just
    // competes with Clear Schedule. Hide it; ⌘T still works via the key
    // binding on the table.
    if filter == .today || selection.isEmpty {
      todayMenuItem.isHidden = true
    } else if selection.allSatisfy(\.isOnToday) {
      todayMenuItem.isHidden = false
      todayMenuItem.title = String(localized: "Remove from Today",
                                   comment: "SeptaskKit: context menu")
    } else {
      todayMenuItem.isHidden = false
      todayMenuItem.title = String(localized: "Move to Today",
                                   comment: "SeptaskKit: context menu")
    }

    let canClear = selection.contains { $0.isOnToday || $0.scheduled != nil }
    clearScheduleMenuItem.isHidden = !canClear

    let repeating = !selection.isEmpty && selection.allSatisfy { $0.recurrence != nil }
    pauseRepeatMenuItem.isHidden = !repeating
    if repeating {
      let paused = selection.allSatisfy(\.recurrencePaused)
      pauseRepeatMenuItem.title = paused
        ? String(localized: "Resume Repeat", comment: "SeptaskKit: recurrence")
        : String(localized: "Pause Repeat", comment: "SeptaskKit: recurrence")
    }
  }
}

// MARK: - Table data source / delegate

extension SeptaskKitTaskListController: NSTableViewDataSource, NSTableViewDelegate {
  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

  /// Always false, deliberately — NOT `if case .header = rows[row] { true }`.
  /// A `.header` row already gets full custom appearance from `KitCardRowView`
  /// + `KitGroupHeaderCell` (the same mechanism `.screenTitle` uses, which
  /// DOES render at its intended size). Marking it a group row on top of that
  /// let AppKit's own system "section header" text style — small, secondary
  /// color, semibold — fight the cell's own font, and it wins: that's why
  /// `KitGroupHeaderCell`'s font bumps kept visually not-landing no matter
  /// how large `Self.font` was set. `shouldSelectRow` already excludes
  /// headers from selection on its own (`rows[row].task != nil`), so nothing
  /// downstream actually needed `isGroupRow` to be true.
  func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { false }

  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
    // The "New task" line is selectable even though it carries no task, so
    // arrow-nav reaches it and Return activates it — same contract as SwiftUI,
    // where the trigger row joins `keyboardOrderedTaskIds`. Every other
    // taskless row (headers, screen title, logged footer) stays unselectable.
    if case .newTask = rows[row] { return true }
    return rows[row].task != nil
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    // Selecting a different row while composing has to fold the open row
    // shut first — otherwise clicking elsewhere leaves an orphaned composer
    // (and any typed edits unsaved).
    if let composingId = composingTaskId,
       !(rows.indices.contains(tableView.selectedRow)
         && rows[tableView.selectedRow].task?.id == composingId) {
      collapseComposer(commit: true)
    }
    // Contiguous selection rounding depends on neighbors' selected-ness —
    // refresh every on-screen row so a former run-end re-squares when the
    // next row joins (AppKit only redraws the rows whose selected bit flipped).
    refreshSelectionJoins()
    // The inspector shows a single row; a multi-selection has no one subject.
    let selection = actionableSelection
    onSelectionChange?(selection.count == 1 ? selection.first : nil)
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    switch rows[row] {
    // Headers carry the air between cards, so they're taller than their text.
    // Section-starting headers get EXTRA margin above them (matching the
    // sidebar's per-top-level-area treatment) — area/project headers and
    // Upcoming's day headers; "Inbox"/"Agenda" are sub-groups within Today's
    // own flow and don't need the same visual break.
    case .header(let id, _, _, _):
      // Kept in sync with `KitGroupHeaderCell.font` (17pt).
      let base = 17 * FontScale.shared.factor + 26
      return headerStartsSection(id) ? base + 10 : base
    // The page's own title — noticeably taller than an in-list header, the
    // same visual weight a big navigation title would carry.
    case .screenTitle: return SeptenaTypeScale.size(.title2) + 40
    case .projectTarget: return SeptaskKitTheme.rowHeight
    case .task(let task, _, _):
      if task.isHeading {
        // Section break between cards — room above matching SwiftUI's
        // `headingRow` top padding so the divider isn't flush to the card.
        return SeptaskKitTheme.heading.pointSize + 28
      }
      if task.id == composingTaskId {
        return KitComposerCell.height(notesHeight: composerNotesHeight)
      }
      return SeptaskKitTheme.rowHeight
        + (taskContextText(for: task) == nil ? 0 : 14)
    case .event: return SeptaskKitTheme.rowHeight
    case .loggedFooter: return SeptenaTypeScale.size(.footnote) + 24
    case .newTask: return SeptaskKitTheme.rowHeight
    // Same band as the logged footer — both are quiet meta-font page footers.
    case .addSection: return SeptenaTypeScale.size(.footnote) + 24
    // Reminder rows read as task rows (they become tasks on click); their
    // header sits on the page like every other group header.
    case .reminder: return SeptaskKitTheme.rowHeight
    case .importAllReminders: return SeptaskKitTheme.rowHeight
    // Meta-height notice on the page, not a full card row.
    case .rolledInBanner: return SeptenaTypeScale.size(.footnote) + 22
    // A pressable card row, so it stands at row height like the rest.
    case .reconnectCue: return SeptaskKitTheme.rowHeight
    }
  }

  /// Card geometry: a run of task rows between headers draws as one card,
  /// rounded only at its ends (KitCardRowView). Headers sit on the page.
  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    let identifier = NSUserInterfaceItemIdentifier("cardRow")
    let rowView = tableView.makeView(withIdentifier: identifier, owner: nil) as? KitCardRowView
      ?? {
        let fresh = KitCardRowView()
        fresh.identifier = identifier
        return fresh
      }()
    rowView.selectionHighlightStyle = .none
    // Row views are recycled: a wash still fading on the row this view USED to
    // be would otherwise ride along onto an unrelated task.
    rowView.cancelPromoteWash()
    applyCardGeometry(rowView, atRow: row)
    return rowView
  }

  private func applyCardGeometry(_ rowView: KitCardRowView, atRow row: Int) {
    // Compare only when the row HAS a task: `Optional == Optional` makes
    // nil == nil true, so every taskless row (the New task line, headers)
    // read as composing AND title-editing whenever nothing was — which
    // suppressed `KitCardRowView`'s selection wash, so the selectable New
    // task line could be selected but never looked it.
    let taskId = rows[row].task?.id
    let composing = taskId != nil && taskId == composingTaskId
    rowView.isComposing = composing
    rowView.isEditingTitle = taskId != nil && taskId == editingTaskId
    if rows[row].isCardRow {
      rowView.isCard = true
      // The open composer is its own rounded slice (Things' elevated edit
      // card) — it breaks the card run so neighbors round off against it
      // instead of squaring into a mid-card join that no longer exists.
      // `!isComposingRow(...)`, NOT `task?.id != composingTaskId`. That
      // comparison is the same `Optional == Optional` trap the comment above
      // describes, and it was still live here: a TASKLESS card row (the
      // reminder rows, the "New task" line, calendar events, the bulk-import
      // line) has `task?.id == nil`, so with nothing composing the test read
      // `nil != nil` → false → "my neighbour isn't on the card" → both rows
      // rounded off and the Inbox rendered as two stacked cards with a gap
      // instead of one run. Any run containing a taskless row was segmented.
      let previousOnCard = row > 0
        && rows[row - 1].isCardRow
        && !isComposingRow(row - 1)
      let nextOnCard = row + 1 < rows.count
        && rows[row + 1].isCardRow
        && !isComposingRow(row + 1)
      rowView.isFirstInGroup = composing || !previousOnCard
      rowView.isLastInGroup = composing || !nextOnCard
    } else {
      rowView.isCard = false
    }
    applySelectionJoins(rowView, atRow: row)
    applyDropLine(rowView, atRow: row)
    rowView.needsDisplay = true
  }

  /// Is the row at `index` the one currently expanded into the composer?
  /// False for every taskless row, which is the point — see the note in
  /// `applyCardGeometry`.
  private func isComposingRow(_ index: Int) -> Bool {
    guard let composingTaskId, let id = rows[index].task?.id else { return false }
    return id == composingTaskId
  }

  /// Selection-run joins for contiguous multi-select rounding. Only joins
  /// through adjacent card rows that are also selected — a header between
  /// two selected tasks breaks the visual run the same way it breaks a card.
  private func applySelectionJoins(_ rowView: KitCardRowView, atRow row: Int) {
    let selected = tableView.selectedRowIndexes
    guard selected.contains(row) else {
      rowView.joinsSelectedAbove = false
      rowView.joinsSelectedBelow = false
      return
    }
    rowView.joinsSelectedAbove = row > 0
      && selected.contains(row - 1)
      && rows[row - 1].isCardRow
    rowView.joinsSelectedBelow = row + 1 < rows.count
      && selected.contains(row + 1)
      && rows[row + 1].isCardRow
  }

  /// A row's corner rounding depends on its NEIGHBORS' card-row-ness
  /// (`isFirstInGroup`/`isLastInGroup`), not just its own content — so
  /// inserting/removing/moving a row can change the correct geometry for a
  /// SURVIVING neighbor that itself didn't change (e.g. completing the last
  /// item in a card leaves the new last item still square-cornered on the
  /// bottom, since `apply`'s content-diff only reloads rows whose own `Row`
  /// value changed, never a neighbor purely because it's now first/last).
  /// `insertRows`/`removeRows`/`moveRow` don't re-invoke `rowViewForRow` for
  /// unaffected rows, so on-screen row views need to be corrected directly
  /// rather than through the delegate. Only touches rows already on screen —
  /// cheap, and anything off-screen gets correct geometry the moment
  /// `rowViewForRow` dequeues it fresh.
  private func refreshCardGeometry() {
    tableView.enumerateAvailableRowViews { rowView, row in
      guard let cardRow = rowView as? KitCardRowView, rows.indices.contains(row) else { return }
      applyCardGeometry(cardRow, atRow: row)
    }
  }

  /// Same walk as `refreshCardGeometry`, but only the selection-join flags —
  /// called from `tableViewSelectionDidChange` so contiguous multi-select
  /// corners stay continuous without a full geometry pass.
  private func refreshSelectionJoins() {
    tableView.enumerateAvailableRowViews { rowView, row in
      guard let cardRow = rowView as? KitCardRowView, rows.indices.contains(row) else { return }
      applySelectionJoins(cardRow, atRow: row)
      cardRow.needsDisplay = true
    }
  }

  private func applyDropLine(_ rowView: KitCardRowView, atRow row: Int) {
    guard let drop = dropAboveRow else {
      rowView.dropLine = .none
      return
    }
    if drop == row {
      rowView.dropLine = .top
    } else if drop >= rows.count && row == rows.count - 1 {
      rowView.dropLine = .bottom
    } else {
      rowView.dropLine = .none
    }
  }

  private func refreshDropIndicator() {
    tableView.enumerateAvailableRowViews { rowView, row in
      guard let cardRow = rowView as? KitCardRowView, rows.indices.contains(row) else { return }
      applyDropLine(cardRow, atRow: row)
    }
  }

  // MARK: Drag & drop (reorder + re-file)

  /// Manual reorder applies wherever manual order is what's shown; archives
  /// don't reorder.
  private var allowsReorder: Bool {
    switch filter {
    case .logbook, .recentlyDeleted: return false
    default: return true
    }
  }

  func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int)
    -> NSPasteboardWriting? {
    guard let task = rows[row].task else { return nil }
    // Headings drag only on a project page (reorder among themselves).
    // Everywhere else they're not a row the user should lift.
    if task.isHeading {
      guard case .project = filter else { return nil }
    }
    let item = NSPasteboardItem()
    item.setString(task.id, forType: .septaskTask)
    return item
  }

  func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                 proposedRow row: Int,
                 proposedDropOperation operation: NSTableView.DropOperation)
    -> NSDragOperation {
    guard allowsReorder, !KitDrag.ids(from: info).isEmpty else {
      dropAboveRow = nil
      return []
    }
    // Never drop into the logged-footer / completed block — clamp the
    // indicator to the open-work region above it.
    let target = clampDropRow(row) ?? row
    if target != row {
      tableView.setDropRow(target, dropOperation: .above)
    } else if operation == .on {
      tableView.setDropRow(row, dropOperation: .above)
    }
    dropAboveRow = target
    return .move
  }

  func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                 row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
    dropAboveRow = nil
    let ids = KitDrag.ids(from: info)
    guard !ids.isEmpty else { return false }
    let insertAt = clampDropRow(row) ?? row

    // Project pages: group-aware drop (file under a heading + reorder
    // within the group, or reorder headings among themselves). Mirrors
    // `TaskListView.handleGroupedTaskDrop` / `handleHeadingDrop`.
    if case .project(let projectId) = filter {
      return acceptProjectDrop(ids: ids, at: insertAt, projectId: projectId)
    }

    let dragged = Set(ids)

    // Neighbor order keys around the insertion gap, skipping headers and the
    // rows being moved. TaskOrder.positions spaces the drop between them.
    // (The midpoint-exhaustion renumber pass is shared via `applyManualOrder`.)
    var aboveKey: Double?
    for index in stride(from: insertAt - 1, through: 0, by: -1) {
      if let task = rows[index].task, !task.isHeading, !dragged.contains(task.id) {
        aboveKey = task.orderKey
        break
      }
    }
    var belowKey: Double?
    for index in insertAt..<rows.count {
      if let task = rows[index].task, !task.isHeading, !dragged.contains(task.id) {
        belowKey = task.orderKey
        break
      }
    }

    let positions = TaskOrder.positions(count: ids.count, above: aboveKey, below: belowKey)
    for (id, position) in zip(ids, positions) {
      mutator.reorder(id: id, toPosition: position)
    }
    refileIfGroupedDrop(ids: ids, at: insertAt, dragged: dragged)
    reload()
    return true
  }

  /// Drop row clamped to the open-work region — never into the logged
  /// footer or the completed rows it expands. Returns nil when `row` is
  /// already valid (so validateDrop can avoid a redundant setDropRow).
  private func clampDropRow(_ row: Int) -> Int? {
    guard let footer = rows.firstIndex(where: {
      if case .loggedFooter = $0 { return true }
      return false
    }), row > footer else { return nil }
    return footer
  }

  /// Persist a manual-order drop — same midpoint-with-renumber-fallback
  /// `TaskListView.applyManualOrder` uses, so exhausted gaps don't silently
  /// land adjacent to the wrong neighbor.
  private func applyManualOrder(ids: [String], into sequence: [SeptenaTask], at insertion: Int) {
    let above = insertion > 0 ? sequence[insertion - 1].orderKey : nil
    let below = insertion < sequence.count ? sequence[insertion].orderKey : nil
    let slots = TaskOrder.positions(count: ids.count, above: above, below: below)
    let strictlyPlaced =
      zip(slots, slots.dropFirst()).allSatisfy { $0 < $1 }
      && (above.map { slots.first! > $0 } ?? true)
      && (below.map { slots.last! < $0 } ?? true)
    if strictlyPlaced {
      for (id, pos) in zip(ids, slots) { mutator.reorder(id: id, toPosition: pos) }
      return
    }
    var final = sequence.map(\.id)
    final.insert(contentsOf: ids, at: insertion)
    let base = sequence.first?.orderKey ?? TaskOrder.gap
    for (i, id) in final.enumerated() {
      let pos = base + TaskOrder.gap * Double(i)
      mutator.reorder(id: id, toPosition: pos == 0 ? TaskOrder.gap / 2 : pos)
    }
  }

  /// Project-page drop: headings reorder among headings; tasks join the
  /// destination group's `heading` and take positions around the gap.
  private func acceptProjectDrop(ids: [String], at row: Int, projectId: String) -> Bool {
    let headings = LocalCache.headings(inProject: projectId, in: context)
    let headingIds = Set(headings.map(\.id))
    let draggingHeading = ids.contains { headingIds.contains($0) }
    let allHeadings = ids.allSatisfy { headingIds.contains($0) }
    // Mixed heading+task drags aren't meaningful in either shell.
    if draggingHeading && !allHeadings { return false }
    if allHeadings {
      return acceptHeadingReorder(ids: ids, at: row, headings: headings)
    }
    return acceptGroupedTaskDrop(ids: ids, at: row, headingIds: headingIds)
  }

  /// Headings dragged onto the heading strip — reorder among themselves
  /// (`TaskListView.handleHeadingDrop`'s heading branch).
  private func acceptHeadingReorder(ids: [String], at row: Int,
                                    headings: [SeptenaTask]) -> Bool {
    let dragged = Set(ids)
    guard !ids.isEmpty else { return false }
    let remaining = headings.filter { !dragged.contains($0.id) }
    // Insert before the first non-dragged heading at or below the gap;
    // none → append.
    var insertion = remaining.count
    for index in row..<rows.count {
      if let task = rows[index].task, task.isHeading, !dragged.contains(task.id),
         let ti = remaining.firstIndex(where: { $0.id == task.id }) {
        insertion = ti
        break
      }
    }
    applyManualOrder(ids: ids, into: remaining, at: insertion)
    reload()
    return true
  }

  /// Task drop inside a project's grouped list. Destination group is read
  /// from the row ABOVE the insertion gap: a heading → file under it (at
  /// top); a task → join that task's heading; screen title / nothing →
  /// un-headed block. Same contract as `handleGroupedTaskDrop`, adapted
  /// to NSTableView's gap-based (`.above`) drop model.
  private func acceptGroupedTaskDrop(ids: [String], at row: Int,
                                     headingIds: Set<String>) -> Bool {
    let dragged = Set(ids)
    guard !ids.isEmpty else { return false }

    let group = destinationHeading(aboveRow: row - 1, headingIds: headingIds)
    let byId = Dictionary(rows.compactMap(\.task).map { ($0.id, $0) },
                          uniquingKeysWith: { a, _ in a })
    // Refuse dragging a heading through the task path (defensive — the
    // caller already splits pure-heading drags out).
    if ids.contains(where: { byId[$0]?.isHeading == true }) { return false }

    let groupRows = openTasksInRenderedOrder().filter { task in
      resolvedHeading(task, headingIds: headingIds) == group
        && !dragged.contains(task.id)
    }

    var insertion = 0
    if row > 0, let above = rows[row - 1].task, !above.isHeading,
       !dragged.contains(above.id),
       resolvedHeading(above, headingIds: headingIds) == group,
       let idx = groupRows.firstIndex(where: { $0.id == above.id }) {
      insertion = idx + 1
    }

    for id in ids {
      guard let task = byId[id] else { continue }
      if resolvedHeading(task, headingIds: headingIds) != group {
        mutator.setHeading(id: id, heading: group)
      }
    }
    applyManualOrder(ids: ids, into: groupRows, at: insertion)
    reload()
    return true
  }

  /// Open (non-heading) tasks in the order currently on screen — the
  /// sequence `applyManualOrder` / group filters read against.
  private func openTasksInRenderedOrder() -> [SeptenaTask] {
    rows.compactMap { row in
      guard let task = row.task, !task.isHeading, task.status == .open else { return nil }
      return task
    }
  }

  /// Heading membership for grouping: a stale FK to a deleted heading
  /// counts as un-headed, matching `projectGrouped`.
  private func resolvedHeading(_ task: SeptenaTask, headingIds: Set<String>) -> String? {
    guard let h = task.heading, headingIds.contains(h) else { return nil }
    return h
  }

  /// Destination `heading` id for a gap whose row above is `index`.
  /// `nil` = the un-headed block at the top of the project.
  private func destinationHeading(aboveRow index: Int, headingIds: Set<String>) -> String? {
    guard index >= 0, rows.indices.contains(index),
          let task = rows[index].task else { return nil }
    if task.isHeading { return task.id }
    return resolvedHeading(task, headingIds: headingIds)
  }

  /// In the grouped Today/Anytime views, a drop inside another area/project
  /// group also re-files the task there (Things behavior): the receiving
  /// group is the nearest header above the insertion gap; none means the
  /// loose zone.
  private func refileIfGroupedDrop(ids: [String], at row: Int, dragged: Set<String>) {
    let grouped: Bool
    switch filter {
    case .today: grouped = todayGroupsByList
    case .unscheduled: grouped = true
    default: grouped = false
    }
    guard grouped else { return }

    var targetProject: String?
    var targetArea: String?
    for index in stride(from: row - 1, through: 0, by: -1) {
      if case .header(let id, _, _, _) = rows[index] {
        if id.hasPrefix("p-") { targetProject = String(id.dropFirst(2)) }
        if id.hasPrefix("a-") { targetArea = String(id.dropFirst(2)) }
        break
      }
    }

    let byId = Dictionary(rows.compactMap(\.task).map { ($0.id, $0) },
                          uniquingKeysWith: { a, _ in a })
    for id in ids {
      guard let task = byId[id] else { continue }
      var moved = false
      if task.project != targetProject {
        mutator.moveToProject(id: id, project: targetProject)
        moved = true
      }
      // Area only matters outside a project group (a project implies its area).
      if targetProject == nil, task.area != targetArea {
        mutator.moveToArea(id: id, area: targetArea)
        moved = true
      }
      if moved { mutator.acknowledge(id: id) }
    }
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                 row: Int) -> NSView? {
    switch rows[row] {
    case .header(let id, let title, let icon, let count):
      let identifier = NSUserInterfaceItemIdentifier("headerCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? KitGroupHeaderCell
        ?? KitGroupHeaderCell(identifier: identifier)
      // Only area/project headers have a leaf to drill into — "Inbox" and
      // "Agenda" aren't destinations of their own.
      let target = navigationTarget(forHeaderId: id)
      cell.configure(title: title, icon: icon, count: count,
                     isNavigable: target != nil,
                     showsQuickAdd: showsGroupedHeaderQuickAdd && target != nil)
      cell.onTap = target.map { filter in
        { [weak self] in self?.onNavigate?(.filter(filter, title: filter.title)) }
      }
      cell.onQuickAdd = { [weak self] in self?.createTask(underHeaderId: id) }
      return cell

    case .screenTitle(let title, let icon):
      let identifier = NSUserInterfaceItemIdentifier("screenTitleCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? KitScreenTitleCell
        ?? KitScreenTitleCell(identifier: identifier)
      cell.configure(title: title, icon: icon)
      // The title IS the navigation dropdown (Things-style) — same contract
      // as SwiftUI's `TaskNavMenu`. Built fresh per click via the closure
      // rather than once here, so it can never show a stale structure.
      cell.onOpenNavMenu = { [weak self] in self?.buildNavMenu() }
      return cell

    case .projectTarget(let id, let title, let progress):
      let identifier = NSUserInterfaceItemIdentifier("projectTargetCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil)
        as? KitProjectTargetCell
        ?? KitProjectTargetCell(identifier: identifier)
      cell.configure(title: title, progress: progress)
      cell.onTap = { [weak self] in
        self?.onNavigate?(.filter(.project(id), title: title))
      }
      return cell

    case .loggedFooter(let count, let expanded):
      let identifier = NSUserInterfaceItemIdentifier("loggedFooterCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? KitLoggedFooterCell
        ?? KitLoggedFooterCell(identifier: identifier)
      cell.configure(count: count, expanded: expanded)
      cell.onTap = { [weak self] in self?.toggleLoggedExpanded() }
      return cell

    case .newTask:
      let identifier = NSUserInterfaceItemIdentifier("newTaskCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? KitNewTaskCell
        ?? KitNewTaskCell(identifier: identifier)
      cell.onTap = { [weak self] in self?.createTask(inInbox: true) }
      return cell

    case .addSection:
      let identifier = NSUserInterfaceItemIdentifier("addSectionCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? KitAddSectionCell
        ?? KitAddSectionCell(identifier: identifier)
      cell.onTap = { [weak self] in self?.menuNewSection() }
      return cell

    case .importAllReminders(let count, let importing):
      let identifier = NSUserInterfaceItemIdentifier("importAllRemindersCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil)
        as? KitImportAllRemindersCell
        ?? KitImportAllRemindersCell(identifier: identifier)
      cell.configure(count: count, importing: importing)
      cell.onTap = { [weak self] in self?.importAllReminders() }
      return cell

    case .rolledInBanner(let count):
      let identifier = NSUserInterfaceItemIdentifier("rolledInBannerCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil)
        as? KitRolledInBannerCell
        ?? KitRolledInBannerCell(identifier: identifier)
      cell.configure(count: count)
      cell.onDismiss = { [weak self] in self?.dismissRolledInBanner() }
      return cell

    case .reconnectCue(let state):
      let identifier = NSUserInterfaceItemIdentifier("reconnectCueCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil)
        as? KitReconnectCueCell
        ?? KitReconnectCueCell(identifier: identifier)
      cell.configure(state: state)
      cell.onTap = { [weak self] in self?.reconnectClaude() }
      return cell

    case .reminder(let item, let importing):
      let identifier = NSUserInterfaceItemIdentifier("reminderCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? KitReminderCell
        ?? KitReminderCell(identifier: identifier)
      cell.configure(with: item, importing: importing)
      cell.onTap = { [weak self] in self?.importReminder(item.id) }
      return cell

    case .task(let task, let chip, let suggestion):
      if task.id == composingTaskId {
        let identifier = NSUserInterfaceItemIdentifier("composerCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? KitComposerCell
          ?? KitComposerCell(identifier: identifier)
        wireComposer(cell, task: task)
        return cell
      }
      let identifier = NSUserInterfaceItemIdentifier("taskCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? SeptaskKitTaskCell
        ?? SeptaskKitTaskCell(identifier: identifier)
      cell.configure(with: task, filter: filter, chip: chip,
                     contextText: taskContextText(for: task))
      cell.configureSuggestion(suggestion) { [weak self] in
        self?.applyFilingSuggestion(taskID: task.id)
      }
      cell.onToggle = { [weak self] id in self?.toggle(id: id) }
      // Deferred one runloop tick — same reentrancy hazard as the composer's
      // `deferCommitAndCollapse` (see its doc comment): `onRename` fires from
      // `controlTextDidEndEditing`, itself mid-resign-first-responder, and
      // `commitRename`'s mutator write posts synchronously, which can cascade
      // back into `makeFirstResponder` (via the sidebar's reselect) before
      // this call has even returned. Running the commit on a fresh tick keeps
      // that reentrant call off an in-progress first-responder transition —
      // the "Esc/click-away doesn't close the row" bug.
      cell.onRename = { [weak self] id, title in
        DispatchQueue.main.async { self?.commitRename(id: id, title: title) }
      }
      return cell

    case .event(let event):
      let identifier = NSUserInterfaceItemIdentifier("eventCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? KitEventCell
        ?? KitEventCell(identifier: identifier)
      cell.configure(with: event)
      return cell
    }
  }

  /// Matches SwiftUI `TaskListView.staticRow`'s project/area suppression:
  /// scoped pages already name their context, while grouped Today/Anytime
  /// pages use headers; the remaining surfaces keep the quiet second line.
  private func taskContextText(for task: SeptenaTask) -> String? {
    let snapshot = StructureCache.snapshot(in: context)
    let suppressProject: Bool = switch filter {
    case .project, .unscheduled: true
    case .today: todayGroupsByList
    default: false
    }
    let suppressArea: Bool = switch filter {
    case .project, .area, .unscheduled: true
    case .today: todayGroupsByList
    default: false
    }

    if !suppressProject, let projectID = task.project,
       let project = snapshot.projects.first(where: { $0.id == projectID }) {
      return project.title
    }
    if !suppressArea, let areaID = task.area,
       let area = snapshot.areas.first(where: { $0.id == areaID }) {
      return area.title
    }
    return nil
  }
}

// MARK: - Motion

/// AppKit mirror of the SwiftUI a11y gate (`A11yMotion`): every row animation
/// resolves through here so Reduce Motion collapses it to an instant change.
@MainActor
enum KitMotion {
  static var reduce: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }
  static var insertRows: NSTableView.AnimationOptions { [.effectFade, .slideDown] }
  static var removeRows: NSTableView.AnimationOptions { [.effectFade, .slideUp] }
  /// How long a checked row keeps its place, visibly completed, before it
  /// leaves the list. Long enough to read as "yes, that one" and to undo by
  /// eye; the pause itself isn't motion, so it survives Reduce Motion and only
  /// the fade afterwards collapses.
  static let settleDelay: TimeInterval = 2.5
  /// Inline composer expand/collapse — `Theme.Motion.quick`-adjacent. Zero
  /// under Reduce Motion so `noteHeightOfRows` jumps.
  static let composerDuration: TimeInterval = 0.22
  static var composerAnimationDuration: TimeInterval { reduce ? 0 : composerDuration }
}

// MARK: - Row cell

/// Checkbox + title + trailing meta (deadline / scheduled / repeat), on the
/// shared type ladder via SeptaskKitTheme. The title field is non-editable at
/// rest and becomes the field editor only through `beginEditing()` — the
/// native answer to the SwiftUI Text→TextField swap that corrupts List
/// selection (CLAUDE.md trap).
@MainActor
final class SeptaskKitTaskCell: NSTableCellView, NSTextFieldDelegate {
  var onToggle: ((String) -> Void)?
  var onRename: ((String, String) -> Void)?

  private let checkbox = KitCheckboxView()
  private let title = NSTextField(labelWithString: "")
  private let contextLabel = NSTextField(labelWithString: "")
  private let notesGlyph = NSImageView()
  private let chip = KitChipView()
  private let suggestionChip = KitSuggestionChipView()
  private let scheduleGlyph = NSImageView()
  private let detail = NSTextField(labelWithString: "")
  private let repeatGlyph = NSImageView()
  private var taskId = ""
  private var plainTitle = ""
  private var editing = false
  // Content floats in a centered, max-width column (Things-style) rather than
  // stretching edge-to-edge — see `layout()`.
  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    checkbox.translatesAutoresizingMaskIntoConstraints = false
    checkbox.onToggle = { [weak self] in
      guard let self else { return }
      self.onToggle?(self.taskId)
    }

    // Single-line, truncate with ellipsis — denser list rhythm; full title
    // is on the tooltip / inspector / composer.
    title.maximumNumberOfLines = 1
    title.cell?.wraps = false
    title.cell?.truncatesLastVisibleLine = true
    title.lineBreakMode = .byTruncatingTail
    title.isEditable = false
    title.isSelectable = false
    title.isBordered = false
    title.isBezeled = false
    title.drawsBackground = false
    title.backgroundColor = .clear
    title.focusRingType = .none
    // Must live on the control itself, not only on attributedStringValue —
    // beginEditing swaps to plain stringValue, and the field editor inherits
    // `font`. Without this, edit mode falls back to the label default (~1–2pt
    // smaller than SeptaskKitTheme.taskTitle).
    title.font = SeptaskKitTheme.taskTitle
    title.delegate = self
    title.translatesAutoresizingMaskIntoConstraints = false
    // Low hugging + compression so the title fills checkbox→trailing and
    // truncates there — without a trailing pin an empty ⌘N title collapses
    // to intrinsic (~1 glyph) width and the field editor inherits that frame.
    title.setContentHuggingPriority(.defaultLow, for: .horizontal)
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    contextLabel.font = SeptaskKitTheme.meta
    contextLabel.textColor = SeptaskKitTheme.inkSecondary
    contextLabel.maximumNumberOfLines = 1
    contextLabel.lineBreakMode = .byTruncatingTail
    contextLabel.isHidden = true
    contextLabel.translatesAutoresizingMaskIntoConstraints = false
    contextLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    notesGlyph.translatesAutoresizingMaskIntoConstraints = false
    notesGlyph.contentTintColor = SeptaskKitTheme.iconMuted
    notesGlyph.image = NSImage(systemSymbolName: "text.alignleft",
                               accessibilityDescription: TaskA11y.hasNotes)?
      .withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
    notesGlyph.setContentHuggingPriority(.required, for: .horizontal)
    notesGlyph.setContentCompressionResistancePriority(.required, for: .horizontal)
    notesGlyph.kitA11yIgnore()

    detail.lineBreakMode = .byClipping
    detail.isEditable = false
    detail.isSelectable = false
    detail.kitA11yIgnore()
    detail.setContentHuggingPriority(.required, for: .horizontal)
    detail.setContentCompressionResistancePriority(.required, for: .horizontal)
    scheduleGlyph.setContentHuggingPriority(.required, for: .horizontal)
    scheduleGlyph.setContentCompressionResistancePriority(.required, for: .horizontal)

    // The repeat marker is the SAME SF Symbol the SwiftUI row uses, in its own
    // glyph view rather than a "↻" concatenated onto the date string — per the
    // DesignSpec, a glyph is a view, never baked into a formatted label.
    repeatGlyph.translatesAutoresizingMaskIntoConstraints = false
    repeatGlyph.contentTintColor = SeptaskKitTheme.inkSecondary
    repeatGlyph.image = NSImage(systemSymbolName: "arrow.clockwise",
                                accessibilityDescription: TaskA11y.recurring)?
      .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
    repeatGlyph.setContentHuggingPriority(.required, for: .horizontal)
    repeatGlyph.setContentCompressionResistancePriority(.required, for: .horizontal)
    repeatGlyph.kitA11yIgnore()

    // Trailing cluster hugs the row's right edge. Order matches the row language
    // spec: variable meta inboard, micro-glyphs outboard
    // (chip · date · recurrence · notes). A leading spacer absorbs any extra
    // width if Auto Layout stretches the stack — without it, NSStackView's
    // default gravity packs visible glyphs to the title and the notes marker
    // stairs down the middle of the row.
    let trailingShove = NSView()
    trailingShove.setContentHuggingPriority(.defaultLow, for: .horizontal)
    trailingShove.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
    let trailing = NSStackView(views: [trailingShove, suggestionChip, chip, scheduleGlyph,
                                      detail, repeatGlyph, notesGlyph])
    trailing.orientation = .horizontal
    trailing.alignment = .centerY
    trailing.distribution = .fill
    trailing.spacing = 6
    trailing.translatesAutoresizingMaskIntoConstraints = false
    trailing.setContentHuggingPriority(.required, for: .horizontal)
    trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
    trailing.setHuggingPriority(.required, for: .horizontal)
    // Collapsed by default. The spacer and the title carry the SAME hugging
    // (.defaultLow), so on a row with every trailing glyph hidden — exactly a
    // freshly-created task — the tie let the spacer absorb the row's free
    // width and the title collapsed to ~0, opening its field editor one glyph
    // wide. Pinning it to 0 at .defaultHigh makes the title the only expandable
    // member, while still yielding if a required constraint genuinely
    // stretches the stack (the case this spacer exists for).
    let shoveCollapsed = trailingShove.widthAnchor.constraint(equalToConstant: 0)
    shoveCollapsed.priority = .defaultHigh
    shoveCollapsed.isActive = true
    trailing.kitA11yIgnore()
    chip.kitA11yIgnore()

    addSubview(checkbox)
    addSubview(title)
    addSubview(contextLabel)
    addSubview(trailing)
    textField = title
    // Row announces as one unit (title + notes); the checkbox stays its own
    // element so VoiceOver can still toggle without hopping through glyphs.
    title.kitA11yIgnore()
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    leadingConstraint = checkbox.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: KitCardRowView.horizontalInset + 6)
    trailingConstraint = trailing.trailingAnchor.constraint(
      equalTo: trailingAnchor, constant: -(KitCardRowView.horizontalInset + 8))
    NSLayoutConstraint.activate([
      leadingConstraint,
      checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
      checkbox.widthAnchor.constraint(equalToConstant: KitCheckboxView.tapSize),
      checkbox.heightAnchor.constraint(equalToConstant: KitCheckboxView.tapSize),
      title.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 7),
      title.centerYAnchor.constraint(equalTo: centerYAnchor),
      // Pin through to the trailing cluster so the title (and its field
      // editor) always spans the row — empty create titles have ~0 intrinsic
      // width, which is what made ⌘N open a one-glyph-wide editor.
      title.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -8),
      contextLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      contextLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
      trailing.leadingAnchor.constraint(greaterThanOrEqualTo: contextLabel.trailingAnchor, constant: 8),
      trailingConstraint,
      trailing.centerYAnchor.constraint(equalTo: title.centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("SeptaskKitTaskCell is code-only") }

  /// Checkbox stays reachable under the combined row label; decorative
  /// trailing glyphs stay hidden (`kitA11yIgnore`).
  override func accessibilityChildren() -> [Any]? {
    checkbox.isHidden ? [] : [checkbox]
  }

  /// Recompute the centered-column inset for the row's current width — called
  /// on every resize (AppKit's normal layout pass), same margin the card
  /// background (`KitCardRowView.cardPath`) draws to.
  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + 6
    trailingConstraint.constant = -(inset + 8)
    super.layout()
  }

  /// Forwarded to the checkbox — the promote cue's ring half. Kept on the cell
  /// so the controller talks to one row object, not to its internals.
  func playTodayPromotePulse() { checkbox.playTodayPromotePulse() }

  /// Show (or hide) the one-tap filing capsule. Separate from `configure` so
  /// the controller owns the suggestion snapshot and the cell stays a renderer.
  func configureSuggestion(_ suggestion: SuggestionEngine.Suggestion?,
                           onApply: (() -> Void)?) {
    guard let suggestion else {
      suggestionChip.isHidden = true
      suggestionChip.onApply = nil
      return
    }
    suggestionChip.isHidden = false
    suggestionChip.configure(title: suggestion.title)
    suggestionChip.onApply = onApply
  }

  func configure(with task: SeptenaTask, filter: TaskFilter,
                 chip chipValue: SeptaskKitTaskListController.Chip?,
                 contextText: String?) {
    taskId = task.id
    plainTitle = task.title
    editing = false
    title.isEditable = false

    if task.isHeading {
      checkbox.isHidden = true
      checkbox.kitA11yIgnore()
      notesGlyph.isHidden = true
      chip.isHidden = true
      scheduleGlyph.isHidden = true
      contextLabel.isHidden = true
      detail.stringValue = ""
      title.font = SeptaskKitTheme.heading
      title.attributedStringValue = NSAttributedString(
        string: task.title,
        attributes: [
          .font: SeptaskKitTheme.heading,
          .foregroundColor: NSColor.labelColor,
        ])
      let label = TaskA11y.rowLabel(title: task.title, hasNotes: false, isHeading: true)
      kitA11yHeader(label: label)
      return
    }

    checkbox.isHidden = false
    checkbox.setAccessibilityElement(true)
    title.font = SeptaskKitTheme.taskTitle
    contextLabel.font = SeptaskKitTheme.meta
    contextLabel.stringValue = contextText ?? ""
    contextLabel.isHidden = contextText == nil
    let done = task.status != .open
    checkbox.isDone = done
    // The box carries readiness and Today the same way TaskCheckbox does:
    // dashed = unratified proposal, gold = promoted to Today.
    let isProposal = task.isInTriageBand && task.source == TaskSource.mcp
    checkbox.isDashed = !done && isProposal
    // Matches `TaskCheckboxModel.isToday = task.isOnToday && showsTodayIndicator`
    // exactly: the solid pinned badge is suppressed ON the Today screen
    // itself (redundant there — everything on screen is already "on Today"),
    // where the tenure fade below carries the cue instead. Elsewhere (moved
    // in via a scheduled/deadline date counts too, not just the pinned flag —
    // `isOnToday`, not the raw `today` field) it shows solid.
    checkbox.isToday = task.isOnToday && filter != .today
    // The remaining cue vocabulary, matching `TaskCheckboxModel`: gold tenure
    // dial for days carried on Today, corner dot for unread agent context on a
    // committed row (proposals are excluded — they already read as dashed),
    // and the cue ring while an agent row is fresh and unengaged.
    // Gated on Settings ▸ Tasks ▸ Today ▸ "Show aging on Today", the same
    // flag the SwiftUI row reads (`TaskCheckboxModel`) — without it the AppKit
    // Today list kept drawing gold after the user turned aging off.
    checkbox.tenureFill = (done || !TaskRowFlags.agingEnabled) ? nil : task.todayTenureFill()
    checkbox.cornerDot = !done && !isProposal && task.conversation.hasStarted
    checkbox.agentCue = !done && task.showsAgentCue()

    var titleAttributes: [NSAttributedString.Key: Any] = [
      .font: SeptaskKitTheme.taskTitle,
      .foregroundColor: NSColor.labelColor,
    ]
    if done {
      titleAttributes[.foregroundColor] = SeptaskKitTheme.inkSecondary
      titleAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
    }
    title.attributedStringValue = NSAttributedString(string: task.title,
                                                     attributes: titleAttributes)

    let hasNotes = !(task.notes ?? "").isEmpty
    notesGlyph.isHidden = !hasNotes
    if let chipValue {
      chip.isHidden = false
      chip.configure(symbol: chipValue.symbol, title: chipValue.title)
    } else {
      chip.isHidden = true
    }

    configureDetail(with: task, filter: filter, done: done)

    setAccessibilityRole(.group)
    setAccessibilityLabel(TaskA11y.rowLabel(title: task.title,
                                            hasNotes: hasNotes,
                                            isHeading: false))
    setAccessibilityRoleDescription(nil)
  }

  /// Trailing meta mirrors SwiftUI's `TaskRow.trailingDate`: completed date,
  /// due urgency, future deadlines, and scheduled dates each get their own
  /// semantic glyph/treatment instead of collapsing into plain date text.
  private func configureDetail(with task: SeptenaTask, filter: TaskFilter, done: Bool) {
    scheduleGlyph.isHidden = true
    scheduleGlyph.image = nil
    detail.font = SeptaskKitTheme.meta
    detail.textColor = SeptaskKitTheme.iconMuted
    detail.stringValue = ""
    detail.isHidden = true
    // Independent of every date branch below. It used to ride the date string,
    // so a recurring task scheduled TODAY and viewed in Today — the exact state
    // a weekly task is in on its own day — hit the branch that hides the date
    // and lost its repeat marker entirely.
    repeatGlyph.isHidden = task.recurrence == nil

    if done, let completedAt = task.completedAt {
      let day = String(completedAt.prefix(10))
      guard !day.isEmpty else { return }
      configureScheduleGlyph(named: "checkmark", color: SeptaskKitTheme.iconMuted)
      detail.stringValue = KitDayFormat.taskDate(day)
      detail.isHidden = false
      return
    }

    if let deadline = task.deadline, let date = KitDayFormat.date(fromWire: deadline) {
      let today = KitDayFormat.todayDate() ?? Date()
      let dueDay = Calendar.current.startOfDay(for: date)
      let todayDay = Calendar.current.startOfDay(for: today)
      if dueDay <= todayDay {
        detail.font = .monospacedDigitSystemFont(
          ofSize: SeptenaTypeScale.size(.footnote), weight: .semibold)
        detail.textColor = SeptaskKitTheme.overdueRed
        detail.stringValue = KitDayFormat.taskDate(deadline)
      } else {
        configureScheduleGlyph(named: "flag.fill", color: SeptaskKitTheme.inkSecondary)
        detail.stringValue = KitDayFormat.taskDate(deadline)
      }
      detail.isHidden = false
      return
    }

    if let scheduled = task.scheduled, let date = KitDayFormat.date(fromWire: scheduled) {
      let today = KitDayFormat.todayDate() ?? Date()
      let scheduledDay = Calendar.current.startOfDay(for: date)
      let todayDay = Calendar.current.startOfDay(for: today)
      // Today already communicates its own current-day membership. Match
      // SwiftUI by hiding past/today When dates there, while future dates and
      // all scheduled dates on other surfaces remain visible.
      if filter != .today || scheduledDay > todayDay {
        configureScheduleGlyph(named: "calendar", color: SeptaskKitTheme.inkSecondary)
        detail.stringValue = KitDayFormat.taskDate(scheduled)
        detail.isHidden = false
      }
    }
  }

  private func configureScheduleGlyph(named name: String, color: NSColor) {
    scheduleGlyph.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
    scheduleGlyph.contentTintColor = color
    scheduleGlyph.isHidden = false
  }

  // MARK: - Field-editor rename

  func beginEditing() {
    guard !editing else { return }
    editing = true
    title.isEditable = true
    // Truncation while the field editor is attached makes AppKit fight the
    // insertion-point scroll — the caret jumps to the far right as you type
    // or arrow through a long title. Clip for the duration of the edit.
    title.lineBreakMode = .byClipping
    title.cell?.truncatesLastVisibleLine = false
    // Keep the configure-time font (taskTitle / heading) on the plain string
    // so the field editor doesn't drop to the control default.
    let font = title.font ?? SeptaskKitTheme.taskTitle
    title.font = font
    title.stringValue = plainTitle
    // Fresh ⌘N rows can reach here before the first layout pass — without
    // this the title's trailing pin hasn't resolved and the field editor
    // attaches to a near-zero frame (the one-glyph-wide editor bug).
    layoutSubtreeIfNeeded()
    window?.makeFirstResponder(title)
    // Field editor inherits the text field's frame (now full-width via the
    // trailing pin) and defaults to an opaque white fill — clear it so rename
    // reads as in-row text, same as the composer title. Also re-assert font:
    // the shared field editor can carry a stale face from a prior edit.
    if let editor = title.currentEditor() as? NSTextView {
      editor.drawsBackground = false
      editor.backgroundColor = .clear
      editor.insertionPointColor = .labelColor
      editor.font = font
      editor.typingAttributes = [
        .font: font,
        .foregroundColor: NSColor.labelColor,
      ]
      editor.selectAll(nil)
    }
  }

  /// Rename holds one line too — flatten a pasted block before it reaches
  /// `controlTextDidEndEditing` and gets written as the title.
  func controlTextDidChange(_ obj: Notification) {
    title.septaskFlattenPastedLineBreaks()
  }

  func controlTextDidEndEditing(_ obj: Notification) {
    guard editing else { return }
    editing = false
    title.isEditable = false
    title.lineBreakMode = .byTruncatingTail
    title.cell?.truncatesLastVisibleLine = true
    onRename?(taskId, title.stringValue)
  }

  func control(_ control: NSControl, textView: NSTextView,
               doCommandBy commandSelector: Selector) -> Bool {
    // Escape cancels: restore the original title, then let editing end —
    // controlTextDidEndEditing sees an unchanged string and commits nothing.
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      title.stringValue = plainTitle
      window?.makeFirstResponder(nil)
      return true
    }
    return false
  }
}

// MARK: - Area project target

/// A project listed inside its parent Area page. This is intentionally a card
/// row rather than a task row: project tasks stay behind the project target,
/// and clicking the row drills into that project's own list.
@MainActor
final class KitProjectTargetCell: NSTableCellView {
  /// Keeps the overlay inside the content column — see `KitContentColumnPin`.
  private var hitPin: KitContentColumnPin!
  private let progress = NSImageView()
  private let title = NSTextField(labelWithString: "")
  private let chevron = NSImageView()
  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!
  /// The whole row is the click target, and it has to be a real `NSButton`:
  /// `NSTableView` claims clicks on label and image cell content, so a
  /// recognizer, a `mouseDown`/`mouseUp` pair, or a `hitTest` override on this
  /// cell never runs. Same transparent full-bleed overlay `KitNewTaskCell`
  /// uses. See `KitScreenTitleCell` for the archaeology.
  private let hit = NSButton()

  var onTap: (() -> Void)?

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    progress.translatesAutoresizingMaskIntoConstraints = false
    title.translatesAutoresizingMaskIntoConstraints = false
    title.lineBreakMode = .byTruncatingTail
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    chevron.translatesAutoresizingMaskIntoConstraints = false
    chevron.setContentHuggingPriority(.required, for: .horizontal)
    chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
    chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
    chevron.contentTintColor = SeptaskKitTheme.iconMuted

    hit.translatesAutoresizingMaskIntoConstraints = false
    hit.isBordered = false
    hit.isTransparent = true
    hit.title = ""
    hit.setButtonType(.momentaryChange)
    hit.refusesFirstResponder = true
    hit.target = self
    hit.action = #selector(fire)
    hit.kitA11yIgnore()

    progress.kitA11yIgnore()
    title.kitA11yIgnore()
    chevron.kitA11yIgnore()

    addSubview(progress)
    addSubview(title)
    addSubview(chevron)
    // Last, so it layers above the content and takes every click in the row.
    addSubview(hit)
    textField = title
    setAccessibilityElement(true)
    leadingConstraint = progress.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: KitCardRowView.horizontalInset + 6)
    trailingConstraint = chevron.trailingAnchor.constraint(
      lessThanOrEqualTo: trailingAnchor, constant: -(KitCardRowView.horizontalInset + 8))
    hitPin = KitContentColumnPin(hit, in: self)
    NSLayoutConstraint.activate([
      leadingConstraint,
      progress.centerYAnchor.constraint(equalTo: centerYAnchor),
      progress.widthAnchor.constraint(equalToConstant: 20),
      progress.heightAnchor.constraint(equalToConstant: 20),
      title.leadingAnchor.constraint(equalTo: progress.trailingAnchor, constant: 7),
      title.centerYAnchor.constraint(equalTo: centerYAnchor),
      chevron.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 6),
      chevron.centerYAnchor.constraint(equalTo: title.centerYAnchor),
      trailingConstraint,
      hit.topAnchor.constraint(equalTo: topAnchor),
      hit.bottomAnchor.constraint(equalTo: bottomAnchor),
    ] + hitPin.constraints + [
    ])
  }

  required init?(coder: NSCoder) { fatalError("KitProjectTargetCell is code-only") }

  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + 6
    trailingConstraint.constant = -(inset + 8)
    hitPin.update(width: bounds.width)
    super.layout()
  }

  func configure(title titleText: String, progress progressValue: Double) {
    self.progress.image = KitGlyph.progress(progressValue, diameter: 13)
    title.attributedStringValue = NSAttributedString(
      string: titleText,
      attributes: [
        .font: NSFont.systemFont(ofSize: SeptenaTypeScale.size(.body) + 1,
                                 weight: .semibold),
        .foregroundColor: NSColor.labelColor,
      ])
    title.toolTip = titleText
    // Plain title, like a navigable `KitGroupHeaderCell` — this row drills
    // into the project, it does not open the nav menu.
    kitA11yButton(label: titleText)
    window?.invalidateCursorRects(for: self)
  }

  @objc private func fire() { onTap?() }

  override func accessibilityPerformPress() -> Bool {
    onTap?()
    return true
  }

  override func resetCursorRects() {
    // Scoped to the button, never the whole cell: a cursor rect does NOT go
    // through hit-testing, so a whole-cell rect happily advertises the page
    // padding as clickable when it is not. That false signal is what cost
    // three rounds of debugging in the 2026-08-09 pass.
    addCursorRect(hit.frame, cursor: .pointingHand)
  }
}

// MARK: - Calendar event cell

/// A calendar event woven into the agenda: a tinted dot where the checkbox
/// would be (nothing here is completable), the event's title, and its time.
@MainActor
final class KitEventCell: NSTableCellView {
  private let dot = NSImageView()
  private let title = NSTextField(labelWithString: "")
  private let time = NSTextField(labelWithString: "")
  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    dot.translatesAutoresizingMaskIntoConstraints = false
    dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 6, weight: .regular))
    dot.contentTintColor = SeptaskKitTheme.iconMuted

    title.translatesAutoresizingMaskIntoConstraints = false
    title.font = SeptaskKitTheme.taskTitle
    title.textColor = SeptaskKitTheme.inkSecondary
    title.lineBreakMode = .byTruncatingTail
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    time.translatesAutoresizingMaskIntoConstraints = false
    time.font = SeptaskKitTheme.meta
    time.textColor = SeptaskKitTheme.iconMuted
    time.setContentHuggingPriority(.required, for: .horizontal)
    time.setContentCompressionResistancePriority(.required, for: .horizontal)

    addSubview(dot)
    addSubview(title)
    addSubview(time)
    textField = title
    leadingConstraint = dot.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: KitCardRowView.horizontalInset + 6)
    trailingConstraint = time.trailingAnchor.constraint(
      equalTo: trailingAnchor, constant: -(KitCardRowView.horizontalInset + 8))
    NSLayoutConstraint.activate([
      leadingConstraint,
      dot.centerYAnchor.constraint(equalTo: centerYAnchor),
      dot.widthAnchor.constraint(equalToConstant: 20),
      title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 7),
      title.centerYAnchor.constraint(equalTo: centerYAnchor),
      time.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
      trailingConstraint,
      time.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("KitEventCell is code-only") }

  /// Same centered-column margin as `SeptaskKitTaskCell` — see its `layout()`.
  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + 6
    trailingConstraint.constant = -(inset + 8)
    super.layout()
  }

  func configure(with event: SeptaskKitTaskListController.Event) {
    title.stringValue = event.title
    time.stringValue = event.time
  }
}

// MARK: - Project/area screen title

/// The page's own big title — an area's emoji/dot or a project's completion
/// ring, plus its name at a larger rung than an in-list group header. The
/// title IS the navigation dropdown (Things-style, matching SwiftUI's
/// `TaskNavMenu`/`ScreenTitleMenuLabel`) — clicking it (or the trailing
/// chevron) jumps anywhere without the sidebar.
@MainActor
final class KitScreenTitleCell: NSTableCellView {
  private let icon = NSImageView()
  private let emoji = NSTextField(labelWithString: "")
  /// The title + chevron ARE the control — a real `NSButton`, not a label with
  /// hand-tracked mouse handling. Three attempts to make a custom view receive
  /// this click failed at the event layer (a click recognizer, then
  /// mouseDown/mouseUp overrides, then a `hitTest` override); an `NSControl`
  /// is what `NSTableView` is built to host in a cell, and it brings its own
  /// tracking, highlight, accessibility, and keyboard activation. This is the
  /// "use standard components, never get creative" rule in CLAUDE.md, arrived
  /// at the hard way.
  private let button = NSButton()
  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!
  /// Builds the dropdown fresh on every click — see the call site's comment
  /// on why this isn't built once and cached. Optional-returning to match
  /// the `[weak self]` closure the controller wires it up with.
  var onOpenNavMenu: (() -> NSMenu?)?

  private static var font: NSFont { .systemFont(ofSize: SeptenaTypeScale.size(.title2), weight: .bold) }

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    icon.translatesAutoresizingMaskIntoConstraints = false
    emoji.translatesAutoresizingMaskIntoConstraints = false
    emoji.font = .systemFont(ofSize: SeptenaTypeScale.size(.title3))

    button.translatesAutoresizingMaskIntoConstraints = false
    button.isBordered = false
    button.bezelStyle = .inline
    button.font = Self.font
    button.image = NSImage(systemSymbolName: "chevron.down",
                           accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
    button.imagePosition = .imageTrailing
    button.contentTintColor = .labelColor
    button.lineBreakMode = .byTruncatingTail
    button.target = self
    button.action = #selector(openNavMenu)
    // Keyboard focus stays on the table — this is a pointer affordance, and
    // the same jumps are already on the menu bar. Matches the checkbox.
    button.refusesFirstResponder = true
    button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    icon.kitA11yIgnore()
    emoji.kitA11yIgnore()

    addSubview(icon)
    addSubview(emoji)
    addSubview(button)
    leadingConstraint = icon.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: KitCardRowView.horizontalInset + 4)
    trailingConstraint = button.trailingAnchor.constraint(
      lessThanOrEqualTo: trailingAnchor, constant: -(KitCardRowView.horizontalInset + 8))
    NSLayoutConstraint.activate([
      leadingConstraint,
      icon.centerYAnchor.constraint(equalTo: button.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 18),
      emoji.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
      emoji.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
      // -2 keeps the glyph's optical left edge where the label's used to sit:
      // a borderless NSButton still carries a small internal content inset.
      button.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
      button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
      trailingConstraint,
    ])
  }

  required init?(coder: NSCoder) { fatalError("KitScreenTitleCell is code-only") }

  /// Fired by the button's own target/action — no hand-tracked mouse handling.
  @objc private func openNavMenu() {
    guard let menu = onOpenNavMenu?() else { return }
    // Dropped from the button's own bottom-left, the standard pull-down
    // geometry. `popUp(positioning:at:in:)` takes the point in the anchor
    // view's coordinates; `NSButton` is unflipped, so its bottom edge is y=0.
    menu.popUp(positioning: nil,
               at: NSPoint(x: 0, y: -4),
               in: button)
  }

  /// The pointing-hand cursor is the platform's "this is a link/button"
  /// signal — matches `KitGroupHeaderCell`'s navigable headers. Scoped to the
  /// BUTTON's frame now, not the whole cell: the cursor should promise a click
  /// only where one actually lands. (The old whole-cell rect was what made the
  /// dead title look live for three rounds of debugging.)
  override func resetCursorRects() {
    addCursorRect(button.frame, cursor: .pointingHand)
  }

  /// Same width-dependent centered-column margin as every other row.
  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + 4
    trailingConstraint.constant = -(inset + 8)
    super.layout()
  }

  func configure(title titleText: String, icon iconKind: SeptaskKitTaskListController.GroupIcon) {
    // `attributedTitle`, not `title`: a borderless NSButton otherwise paints
    // its label in the control's default color, which loses the page title's
    // full-strength ink.
    button.attributedTitle = NSAttributedString(
      string: titleText,
      attributes: [.font: Self.font, .foregroundColor: NSColor.labelColor])
    emoji.isHidden = true
    icon.isHidden = false
    switch iconKind {
    case .emoji(let glyph):
      emoji.isHidden = false
      emoji.stringValue = glyph
      icon.isHidden = true
    case .areaDot:
      icon.image = KitGlyph.areaDot()
    case .project(let progress):
      icon.image = KitGlyph.progress(progress)
    case .symbol(let name):
      icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
      icon.contentTintColor = SeptaskKitTheme.inkSecondary
    }
    // The BUTTON is the accessibility element now — it carries the press
    // action natively, so the cell doesn't need to fake one.
    setAccessibilityElement(false)
    button.setAccessibilityLabel(TaskA11y.navigationTitle(titleText))
    // A reused cell carries a stale cursor rect otherwise — matches
    // `KitGroupHeaderCell.configure`'s identical call.
    window?.invalidateCursorRects(for: self)
  }
}

// MARK: - Logged footer ("Show N logged items")

/// Things-style footer on project/area pages — a quiet link that expands
/// completed tasks for that page. Matches `TaskListView.scopeLoggedToggleRow`
/// exactly: same copy, meta font, secondary ink, left-aligned on the content
/// column (not the wider page gutter).
@MainActor
final class KitLoggedFooterCell: NSTableCellView {
  /// Keeps the overlay inside the content column — see `KitContentColumnPin`.
  private var hitPin: KitContentColumnPin!
  private let label = NSTextField(labelWithString: "")
  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!
  /// A real `NSButton`, not a `hitTest`/`mouseUp` override on the cell —
  /// `NSTableView` claims clicks on an `NSTextField` label, so none of those
  /// overrides ever ran and this footer was inert. Transparent full-bleed
  /// overlay, the `KitNewTaskCell` pattern.
  private let hit = NSButton()
  var onTap: (() -> Void)?

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = SeptaskKitTheme.meta
    label.textColor = SeptaskKitTheme.inkSecondary
    label.kitA11yIgnore()

    hit.translatesAutoresizingMaskIntoConstraints = false
    hit.isBordered = false
    hit.isTransparent = true
    hit.title = ""
    hit.setButtonType(.momentaryChange)
    hit.refusesFirstResponder = true
    hit.target = self
    hit.action = #selector(fire)
    hit.kitA11yIgnore()

    addSubview(label)
    // Last, so it layers above the label and takes every click in the row.
    addSubview(hit)
    textField = label
    setAccessibilityElement(true)
    leadingConstraint = label.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: KitCardRowView.horizontalInset + 6)
    trailingConstraint = label.trailingAnchor.constraint(
      lessThanOrEqualTo: trailingAnchor, constant: -(KitCardRowView.horizontalInset + 8))
    hitPin = KitContentColumnPin(hit, in: self)
    NSLayoutConstraint.activate([
      leadingConstraint,
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      trailingConstraint,
      hit.topAnchor.constraint(equalTo: topAnchor),
      hit.bottomAnchor.constraint(equalTo: bottomAnchor),
    ] + hitPin.constraints + [
    ])
  }

  required init?(coder: NSCoder) { fatalError("KitLoggedFooterCell is code-only") }

  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + 6
    trailingConstraint.constant = -(inset + 8)
    hitPin.update(width: bounds.width)
    super.layout()
  }

  func configure(count: Int, expanded: Bool) {
    let text = expanded
      ? String(localized: "Hide \(count) logged items",
               comment: "Project/area footer — collapse completed tasks (plural)")
      : String(localized: "Show \(count) logged items",
               comment: "Project/area footer — expand completed tasks (plural)")
    label.stringValue = text
    kitA11yButton(label: text)
  }

  @objc private func fire() { onTap?() }

  override func accessibilityPerformPress() -> Bool {
    onTap?()
    return true
  }

  override func resetCursorRects() {
    // Scoped to the button, never the whole cell: a cursor rect does NOT go
    // through hit-testing, so a whole-cell rect happily advertises the page
    // padding as clickable when it is not. That false signal is what cost
    // three rounds of debugging in the 2026-08-09 pass.
    addCursorRect(hit.frame, cursor: .pointingHand)
  }
}

// MARK: - New task cell

/// Foot of Today's Inbox card: the clickable "New task" line, the AppKit
/// counterpart of SwiftUI's `QuickAddTriggerRow`.
///
/// Geometry is `SeptaskKitTaskCell`'s, not an approximation of it — the real
/// `KitCheckboxView` at `tapSize`, pinned `inset + 6` from the leading edge,
/// with the title `7` after the box at `SeptaskKitTheme.taskTitle`. The row
/// has to line up glyph-for-glyph with the task rows it sits under.
///
/// Clicks go to a transparent full-bleed `NSButton` layered over that content
/// rather than to a `hitTest`/`mouseUp` override on the cell. A bare
/// `NSTextField` under the pointer is claimed by the table and no override on
/// the surrounding cell runs, while `resetCursorRects` still paints the
/// pointing hand — so a dead target looks alive. Only a real `NSControl`
/// reliably receives the click.
@MainActor
final class KitNewTaskCell: NSTableCellView {
  /// Keeps the overlay inside the content column — see `KitContentColumnPin`.
  private var hitPin: KitContentColumnPin!
  private let checkbox = KitCheckboxView()
  private let label = NSTextField(labelWithString: "")
  private let hit = NSButton()
  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!
  var onTap: (() -> Void)?

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    let title = String(localized: "New task",
                       comment: "Quick-add line at the foot of Today's Inbox")

    checkbox.translatesAutoresizingMaskIntoConstraints = false
    // Same empty-box language as SwiftUI's trigger row: never done, never
    // Today, dashed under the v2 row language.
    checkbox.isDone = false
    checkbox.isToday = false
    checkbox.isDashed = TaskRowFlags.languageV2
    // Decorative here — the whole row is the button, so the box must not be
    // separately clickable or focusable.
    checkbox.isEnabled = false
    checkbox.kitA11yIgnore()

    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = SeptaskKitTheme.taskTitle
    label.textColor = SeptaskKitTheme.inkSecondary
    label.stringValue = title
    label.kitA11yIgnore()

    hit.translatesAutoresizingMaskIntoConstraints = false
    hit.isBordered = false
    hit.isTransparent = true
    hit.title = ""
    hit.setButtonType(.momentaryChange)
    hit.refusesFirstResponder = true
    hit.target = self
    hit.action = #selector(fire)

    addSubview(checkbox)
    addSubview(label)
    // Last, so it layers above the content and takes every click in the row.
    addSubview(hit)
    textField = label
    kitA11yButton(label: title)

    leadingConstraint = checkbox.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: KitCardRowView.horizontalInset + 6)
    trailingConstraint = label.trailingAnchor.constraint(
      lessThanOrEqualTo: trailingAnchor, constant: -(KitCardRowView.horizontalInset + 8))
    hitPin = KitContentColumnPin(hit, in: self)
    NSLayoutConstraint.activate([
      leadingConstraint,
      checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
      checkbox.widthAnchor.constraint(equalToConstant: KitCheckboxView.tapSize),
      checkbox.heightAnchor.constraint(equalToConstant: KitCheckboxView.tapSize),
      label.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 7),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      trailingConstraint,
      hit.topAnchor.constraint(equalTo: topAnchor),
      hit.bottomAnchor.constraint(equalTo: bottomAnchor),
    ] + hitPin.constraints + [
    ])
  }

  required init?(coder: NSCoder) { fatalError("KitNewTaskCell is code-only") }

  /// Same centered-column inset the task rows and the card background use.
  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + 6
    trailingConstraint.constant = -(inset + 8)
    hitPin.update(width: bounds.width)
    super.layout()
  }

  override func accessibilityPerformPress() -> Bool {
    onTap?()
    return true
  }

  override func resetCursorRects() {
    // Scoped to the button, never the whole cell: a cursor rect does NOT go
    // through hit-testing, so a whole-cell rect happily advertises the page
    // padding as clickable when it is not. That false signal is what cost
    // three rounds of debugging in the 2026-08-09 pass.
    addCursorRect(hit.frame, cursor: .pointingHand)
  }

  @objc private func fire() { onTap?() }
}

// MARK: - Content-column click targets

/// Constraints pinning a full-bleed click target to the CONTENT COLUMN — the
/// same band the card occupies (`KitCardRowView` insets its card by
/// `SeptaskKitLayout.inset(for:)` on each side).
///
/// A click target that spans the whole row width reaches into the page's side
/// padding, so clicking the empty gutter beside a row would fire that row's
/// button. The padding is page, not row. Owners call `update(width:)` from
/// their own `layout()`, alongside the inset they already apply to content.
@MainActor
struct KitContentColumnPin {
  let leading: NSLayoutConstraint
  let trailing: NSLayoutConstraint

  init(_ target: NSView, in container: NSView) {
    leading = target.leadingAnchor.constraint(equalTo: container.leadingAnchor)
    trailing = target.trailingAnchor.constraint(equalTo: container.trailingAnchor)
  }

  var constraints: [NSLayoutConstraint] { [leading, trailing] }

  func update(width: CGFloat) {
    let inset = SeptaskKitLayout.inset(for: width)
    leading.constant = inset
    trailing.constant = -inset
  }
}

// MARK: - Add-section cell

/// Foot of a project page: the quiet "+ Add Section" line, the AppKit
/// counterpart of `TaskListView.addSectionButton` — same copy, same meta font
/// and secondary ink, left-aligned on the content column.
///
/// Clicks go to a transparent full-bleed `NSButton`, for the reason spelled
/// out on `KitNewTaskCell`: `NSTableView` claims clicks on label and image
/// content, so only a real `NSControl` reliably receives them.
@MainActor
final class KitAddSectionCell: NSTableCellView {
  /// Keeps the overlay inside the content column — see `KitContentColumnPin`.
  private var hitPin: KitContentColumnPin!
  private let plus = NSImageView()
  private let label = NSTextField(labelWithString: "")
  private let hit = NSButton()
  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!
  var onTap: (() -> Void)?

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    let title = String(localized: "Add Section",
                       comment: "Foot of a project page — create a section heading")

    plus.translatesAutoresizingMaskIntoConstraints = false
    plus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: SeptenaTypeScale.size(.footnote),
                                     weight: .semibold))
    plus.contentTintColor = SeptaskKitTheme.inkSecondary
    plus.setContentHuggingPriority(.required, for: .horizontal)
    plus.kitA11yIgnore()

    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = SeptaskKitTheme.meta
    label.textColor = SeptaskKitTheme.inkSecondary
    label.stringValue = title
    label.kitA11yIgnore()

    hit.translatesAutoresizingMaskIntoConstraints = false
    hit.isBordered = false
    hit.isTransparent = true
    hit.title = ""
    hit.setButtonType(.momentaryChange)
    hit.refusesFirstResponder = true
    hit.target = self
    hit.action = #selector(fire)
    hit.kitA11yIgnore()

    addSubview(plus)
    addSubview(label)
    // Last, so it layers above the content and takes every click in the row.
    addSubview(hit)
    textField = label
    kitA11yButton(label: title)

    // Same content-column origin as the logged footer, so the two page
    // footers line up with each other and with the cards above them.
    leadingConstraint = plus.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: KitCardRowView.horizontalInset + 6)
    trailingConstraint = label.trailingAnchor.constraint(
      lessThanOrEqualTo: trailingAnchor, constant: -(KitCardRowView.horizontalInset + 8))
    hitPin = KitContentColumnPin(hit, in: self)
    NSLayoutConstraint.activate([
      leadingConstraint,
      plus.centerYAnchor.constraint(equalTo: centerYAnchor),
      label.leadingAnchor.constraint(equalTo: plus.trailingAnchor, constant: 6),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      trailingConstraint,
      hit.topAnchor.constraint(equalTo: topAnchor),
      hit.bottomAnchor.constraint(equalTo: bottomAnchor),
    ] + hitPin.constraints + [
    ])
  }

  required init?(coder: NSCoder) { fatalError("KitAddSectionCell is code-only") }

  /// Same width-dependent centered-column margin as every other row.
  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + 6
    trailingConstraint.constant = -(inset + 8)
    hitPin.update(width: bounds.width)
    super.layout()
  }

  override func accessibilityPerformPress() -> Bool {
    onTap?()
    return true
  }

  override func resetCursorRects() {
    // Scoped to the button, never the whole cell: a cursor rect does NOT go
    // through hit-testing, so a whole-cell rect happily advertises the page
    // padding as clickable when it is not. That false signal is what cost
    // three rounds of debugging in the 2026-08-09 pass.
    addCursorRect(hit.frame, cursor: .pointingHand)
  }

  @objc private func fire() { onTap?() }
}

// MARK: - Rolled-into-Today banner cell

/// "N tasks rolled into Today", with a Dismiss button.
///
/// A NOTICE, and it must not look like an item. It used to wear the same
/// fill, radius and margin as a task card, which made a statement ABOUT your
/// list read as a row OF it — the only action on it is "go away", so looking
/// actionable was a lie. It now sits on the page background at meta size,
/// like a group header does, at roughly half the height it had.
///
/// Still deliberately NOT a filled colour band with a filled button: per
/// `TaskListView.newTodosBanner`, that is Things' treatment and a saturated
/// slab is the loudest thing on a screen whose language is quiet cards. The
/// gold is spent in exactly one place — the glyph.
@MainActor
final class KitRolledInBannerCell: NSTableCellView {
  private let glyph = NSImageView()
  private let label = NSTextField(labelWithString: "")
  private let dismiss = NSButton()
  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!
  var onDismiss: (() -> Void)?

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    glyph.translatesAutoresizingMaskIntoConstraints = false
    // Outline, not `.fill`: a filled disc reads as a status dot demanding
    // attention. The outline states the fact and stops.
    glyph.image = NSImage(systemSymbolName: "arrow.down.circle",
                          accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: SeptenaTypeScale.size(.footnote) + 1,
                                     weight: .regular))
    // NEUTRAL, not gold. Gold is already spoken for on this screen: it is the
    // Today tenure dial inside checkboxes, where it carries data (days
    // carried). Spending it again on a dismissible notice made the least
    // important thing the only coloured thing, and made one colour mean two
    // unrelated things. A notice should be the quietest thing on screen.
    glyph.contentTintColor = SeptaskKitTheme.iconMuted
    glyph.setContentHuggingPriority(.required, for: .horizontal)
    glyph.kitA11yIgnore()

    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = SeptaskKitTheme.meta
    label.textColor = SeptaskKitTheme.inkSecondary
    label.lineBreakMode = .byTruncatingTail
    label.kitA11yIgnore()

    dismiss.translatesAutoresizingMaskIntoConstraints = false
    dismiss.isBordered = false
    dismiss.setButtonType(.momentaryChange)
    dismiss.refusesFirstResponder = true
    dismiss.target = self
    dismiss.action = #selector(fireDismiss)
    dismiss.setContentHuggingPriority(.required, for: .horizontal)
    let dismissTitle = String(localized: "Dismiss",
                              comment: "SeptaskKit: dismiss the rolled-into-Today notice")
    // Same font and ink as the message itself. Semibold made the way OUT
    // louder than the thing being said, which is backwards for a notice you
    // can ignore.
    dismiss.attributedTitle = NSAttributedString(
      string: dismissTitle,
      attributes: [
        .font: SeptaskKitTheme.meta,
        .foregroundColor: SeptaskKitTheme.inkSecondary,
      ])
    dismiss.setAccessibilityLabel(dismissTitle)

    addSubview(glyph)
    addSubview(label)
    addSubview(dismiss)
    textField = label

    leadingConstraint = glyph.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: KitCardRowView.horizontalInset + 6)
    trailingConstraint = dismiss.trailingAnchor.constraint(
      equalTo: trailingAnchor, constant: -(KitCardRowView.horizontalInset + 8))
    NSLayoutConstraint.activate([
      leadingConstraint,
      glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
      label.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 6),
      label.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
      dismiss.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
      trailingConstraint,
      dismiss.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("KitRolledInBannerCell is code-only") }

  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + 6
    trailingConstraint.constant = -(inset + 8)
    super.layout()
  }

  func configure(count: Int) {
    label.stringValue = count == 1
      ? String(localized: "1 task rolled into Today",
               comment: "SeptaskKit: start-of-day rolled-in notice, singular")
      : String(localized: "\(count) tasks rolled into Today",
               comment: "SeptaskKit: start-of-day rolled-in notice, plural")
    kitA11yElement(role: .staticText, label: label.stringValue, value: nil, help: nil)
    window?.invalidateCursorRects(for: self)
  }

  override func resetCursorRects() {
    addCursorRect(dismiss.frame, cursor: .pointingHand)
  }

  @objc private func fireDismiss() { onDismiss?() }
}

// MARK: - Claude reconnect cue cell

/// "Reconnect" — the row that re-mints the Claude gateway token. The AppKit
/// twin of `ClaudeReconnectCue(.card)`: same glyph vocabulary, same copy,
/// same one-press action.
///
/// The default framing is a SECURITY CHECKPOINT, not a fault. The token lapses
/// by design, so the resting glyph is the device's biometry mark ("verify it's
/// you"), and the orange warning triangle appears only when a reconnect
/// genuinely failed. The whole row is the button, like `KitReminderCell` —
/// a `.plain`-style label with dead trailing space is the row-dead-zone bug.
@MainActor
final class KitReconnectCueCell: NSTableCellView {
  /// Keeps the overlay inside the content column — see `KitContentColumnPin`.
  private var hitPin: KitContentColumnPin!
  private let glyph = NSImageView()
  private let title = NSTextField(labelWithString: "")
  private let subtitle = NSTextField(labelWithString: "")
  private let spinner = NSProgressIndicator()
  private let hit = NSButton()
  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!
  var onTap: (() -> Void)?

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    glyph.translatesAutoresizingMaskIntoConstraints = false
    glyph.setContentHuggingPriority(.required, for: .horizontal)
    glyph.kitA11yIgnore()

    title.translatesAutoresizingMaskIntoConstraints = false
    title.font = .systemFont(ofSize: SeptenaTypeScale.size(.subheadline), weight: .semibold)
    title.setContentHuggingPriority(.required, for: .horizontal)
    title.setContentCompressionResistancePriority(.required, for: .horizontal)
    title.kitA11yIgnore()

    subtitle.translatesAutoresizingMaskIntoConstraints = false
    subtitle.font = .systemFont(ofSize: SeptenaTypeScale.size(.subheadline))
    subtitle.textColor = SeptaskKitTheme.iconMuted
    subtitle.lineBreakMode = .byTruncatingTail
    subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    subtitle.kitA11yIgnore()

    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    spinner.kitA11yIgnore()

    hit.translatesAutoresizingMaskIntoConstraints = false
    hit.isBordered = false
    hit.isTransparent = true
    hit.title = ""
    hit.setButtonType(.momentaryChange)
    hit.refusesFirstResponder = true
    hit.target = self
    hit.action = #selector(fire)
    hit.kitA11yIgnore()

    addSubview(glyph)
    addSubview(title)
    addSubview(subtitle)
    addSubview(spinner)
    // Last, so it layers above the content and takes every click in the row.
    addSubview(hit)
    textField = title

    leadingConstraint = glyph.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: KitCardRowView.horizontalInset + 6)
    trailingConstraint = spinner.trailingAnchor.constraint(
      equalTo: trailingAnchor, constant: -(KitCardRowView.horizontalInset + 8))
    hitPin = KitContentColumnPin(hit, in: self)
    NSLayoutConstraint.activate([
      leadingConstraint,
      glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
      glyph.widthAnchor.constraint(equalToConstant: 20),
      title.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 7),
      title.centerYAnchor.constraint(equalTo: centerYAnchor),
      subtitle.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
      subtitle.centerYAnchor.constraint(equalTo: centerYAnchor),
      spinner.leadingAnchor.constraint(greaterThanOrEqualTo: subtitle.trailingAnchor,
                                       constant: 8),
      trailingConstraint,
      spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
      hit.topAnchor.constraint(equalTo: topAnchor),
      hit.bottomAnchor.constraint(equalTo: bottomAnchor),
    ] + hitPin.constraints)
  }

  required init?(coder: NSCoder) { fatalError("KitReconnectCueCell is code-only") }

  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + 6
    trailingConstraint.constant = -(inset + 8)
    hitPin.update(width: bounds.width)
    super.layout()
  }

  func configure(state: SeptaskKitTaskListController.ReconnectCueState) {
    let reconnected = state == .reconnected
    title.stringValue = reconnected
      ? String(localized: "Reconnected", comment: "Claude gateway reconnect cue")
      : String(localized: "Reconnect", comment: "Claude gateway reconnect cue")
    title.textColor = reconnected ? .systemGreen : SeptaskKitTheme.claudeAccent

    switch state {
    case .reconnected:
      // A green lock, not a check: the connection is SECURE again, echoing the
      // biometry language of the resting state.
      glyph.image = Self.symbol("lock.fill")
      glyph.contentTintColor = .systemGreen
      subtitle.stringValue = ""
    case .failed:
      glyph.image = Self.symbol("exclamationmark.triangle.fill")
      glyph.contentTintColor = .systemOrange
      subtitle.stringValue = String(localized: "Couldn’t reconnect — tap to retry",
                                    comment: "Claude gateway reconnect cue")
    case .idle, .refreshing:
      // Biometry mark (Face/Touch/Optic ID): a lapsed token is an auth
      // checkpoint, not a problem to alarm about.
      glyph.image = Self.symbol(BiometrySymbol.systemName)
      glyph.contentTintColor = SeptaskKitTheme.claudeAccent
      subtitle.stringValue = String(localized: "Verify it’s you to reconnect",
                                    comment: "Claude gateway reconnect cue")
    }

    if state == .refreshing { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    // Pressing again mid-flight or during the flash would do nothing — say so
    // in the cursor and the hit target rather than swallowing the click.
    hit.isEnabled = state != .refreshing && !reconnected
    kitA11yButton(label: reconnected
      ? String(localized: "Reconnected", comment: "Claude gateway reconnect cue")
      : String(localized: "Reconnect Claude", comment: "Claude gateway reconnect cue"))
    window?.invalidateCursorRects(for: self)
  }

  private static func symbol(_ name: String) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: SeptenaTypeScale.size(.subheadline),
                                     weight: .regular))
  }

  override func accessibilityPerformPress() -> Bool {
    onTap?()
    return true
  }

  override func resetCursorRects() {
    guard hit.isEnabled else { return }
    addCursorRect(hit.frame, cursor: .pointingHand)
  }

  @objc private func fire() { onTap?() }
}

// MARK: - Reminders inbox cells

/// "Import all N from Reminders" — a quiet action line at the foot of the
/// reminder run inside the Inbox, shown only when more than one is waiting.
///
/// A LINE, not a header button: the Inbox header's trailing slot belongs to
/// the `+`, and this action is consequential enough to want a full row and a
/// sentence rather than a glyph. Same shape as the "Add Section" footer —
/// the shell's established vocabulary for a quiet in-list action.
///
/// The subtitle says what it costs, because importing DELETES the originals
/// from Apple Reminders and undo cannot reach them. That is the only place in
/// the app where one click removes another app's data, so it says so up front
/// rather than confirming after the fact.
@MainActor
final class KitImportAllRemindersCell: NSTableCellView {
  /// Keeps the overlay inside the content column — see `KitContentColumnPin`.
  private var hitPin: KitContentColumnPin!
  private let glyph = NSImageView()
  private let label = NSTextField(labelWithString: "")
  private let spinner = NSProgressIndicator()
  private let hit = NSButton()
  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!
  var onTap: (() -> Void)?

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    glyph.translatesAutoresizingMaskIntoConstraints = false
    glyph.image = NSImage(systemSymbolName: "arrow.down.circle",
                          accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: SeptenaTypeScale.size(.footnote),
                                     weight: .semibold))
    glyph.contentTintColor = SeptaskKitTheme.inkSecondary
    glyph.setContentHuggingPriority(.required, for: .horizontal)
    glyph.kitA11yIgnore()

    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = SeptaskKitTheme.meta
    label.textColor = SeptaskKitTheme.inkSecondary
    label.lineBreakMode = .byTruncatingTail
    label.kitA11yIgnore()

    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false

    hit.translatesAutoresizingMaskIntoConstraints = false
    hit.isBordered = false
    hit.isTransparent = true
    hit.title = ""
    hit.setButtonType(.momentaryChange)
    hit.refusesFirstResponder = true
    hit.target = self
    hit.action = #selector(fire)
    hit.kitA11yIgnore()

    addSubview(glyph)
    addSubview(label)
    addSubview(spinner)
    // Last, so it layers above the content and takes every click in the row.
    addSubview(hit)
    textField = label

    leadingConstraint = glyph.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: KitCardRowView.horizontalInset + 6)
    trailingConstraint = spinner.trailingAnchor.constraint(
      equalTo: trailingAnchor, constant: -(KitCardRowView.horizontalInset + 8))
    hitPin = KitContentColumnPin(hit, in: self)
    NSLayoutConstraint.activate([
      leadingConstraint,
      glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
      glyph.widthAnchor.constraint(equalToConstant: 20),
      label.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 7),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      spinner.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor,
                                       constant: 8),
      trailingConstraint,
      spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
      hit.topAnchor.constraint(equalTo: topAnchor),
      hit.bottomAnchor.constraint(equalTo: bottomAnchor),
    ] + hitPin.constraints + [
    ])
  }

  required init?(coder: NSCoder) { fatalError("KitImportAllRemindersCell is code-only") }

  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + 6
    trailingConstraint.constant = -(inset + 8)
    hitPin.update(width: bounds.width)
    super.layout()
  }

  func configure(count: Int, importing: Bool) {
    let title = importing
      ? String(localized: "Importing…", comment: "SeptaskKit: reminders import in flight")
      : String(localized: "Import all \(count) from Reminders — removes them there",
               comment: "SeptaskKit: bulk import action line")
    label.stringValue = title
    hit.isEnabled = !importing
    alphaValue = importing ? 0.6 : 1
    if importing { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    kitA11yButton(label: title)
    window?.invalidateCursorRects(for: self)
  }

  override func accessibilityPerformPress() -> Bool {
    onTap?()
    return true
  }

  override func resetCursorRects() {
    guard hit.isEnabled else { return }
    addCursorRect(hit.frame, cursor: .pointingHand)
  }

  @objc private func fire() { onTap?() }
}

/// One pending Apple Reminder. The whole row is the import button — the
/// SwiftUI row behaves the same way, and there is no second action to
/// disambiguate from.
@MainActor
final class KitReminderCell: NSTableCellView {
  /// Keeps the overlay inside the content column — see `KitContentColumnPin`.
  private var hitPin: KitContentColumnPin!
  private let arrow = NSImageView()
  private let title = NSTextField(labelWithString: "")
  private let due = NSTextField(labelWithString: "")
  private let hit = NSButton()
  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!
  var onTap: (() -> Void)?

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    arrow.translatesAutoresizingMaskIntoConstraints = false
    arrow.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: SeptenaTypeScale.size(.footnote),
                                     weight: .semibold))
    arrow.contentTintColor = SeptaskKitTheme.iconMuted
    arrow.kitA11yIgnore()

    title.translatesAutoresizingMaskIntoConstraints = false
    title.font = SeptaskKitTheme.taskTitle
    title.textColor = SeptaskKitTheme.inkPrimary
    title.lineBreakMode = .byTruncatingTail
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    title.kitA11yIgnore()

    due.translatesAutoresizingMaskIntoConstraints = false
    due.font = SeptaskKitTheme.meta
    due.setContentHuggingPriority(.required, for: .horizontal)
    due.setContentCompressionResistancePriority(.required, for: .horizontal)
    due.kitA11yIgnore()

    hit.translatesAutoresizingMaskIntoConstraints = false
    hit.isBordered = false
    hit.isTransparent = true
    hit.title = ""
    hit.setButtonType(.momentaryChange)
    hit.refusesFirstResponder = true
    hit.target = self
    hit.action = #selector(fire)
    hit.kitA11yIgnore()

    addSubview(arrow)
    addSubview(title)
    addSubview(due)
    // Last, so it layers above the content and takes every click in the row.
    addSubview(hit)
    textField = title

    leadingConstraint = arrow.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: KitCardRowView.horizontalInset + 6)
    trailingConstraint = due.trailingAnchor.constraint(
      equalTo: trailingAnchor, constant: -(KitCardRowView.horizontalInset + 8))
    hitPin = KitContentColumnPin(hit, in: self)
    NSLayoutConstraint.activate([
      leadingConstraint,
      arrow.centerYAnchor.constraint(equalTo: centerYAnchor),
      arrow.widthAnchor.constraint(equalToConstant: 20),
      title.leadingAnchor.constraint(equalTo: arrow.trailingAnchor, constant: 7),
      title.centerYAnchor.constraint(equalTo: centerYAnchor),
      due.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
      trailingConstraint,
      due.centerYAnchor.constraint(equalTo: centerYAnchor),
      hit.topAnchor.constraint(equalTo: topAnchor),
      hit.bottomAnchor.constraint(equalTo: bottomAnchor),
    ] + hitPin.constraints + [
    ])
  }

  required init?(coder: NSCoder) { fatalError("KitReminderCell is code-only") }

  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + 6
    trailingConstraint.constant = -(inset + 8)
    hitPin.update(width: bounds.width)
    super.layout()
  }

  func configure(with item: ImportedReminder, importing: Bool) {
    title.stringValue = item.title
    title.toolTip = item.title
    if let date = item.dueDate {
      due.stringValue = Self.shortDate(date)
      due.textColor = Self.isOverdue(date)
        ? SeptaskKitTheme.overdueRed
        : SeptaskKitTheme.inkSecondary
    } else {
      due.stringValue = ""
    }
    hit.isEnabled = !importing
    alphaValue = importing ? 0.5 : 1
    kitA11yButton(label: String(localized: "Import “\(item.title)” from Reminders",
                                comment: "SeptaskKit: reminder row accessibility label"))
    window?.invalidateCursorRects(for: self)
  }

  /// Same wording as `RemindersInboxSection.shortDate`.
  private static func shortDate(_ date: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(date) {
      return String(localized: "Today", comment: "Smart list title")
    }
    if cal.isDateInTomorrow(date) {
      return String(localized: "Tomorrow", comment: "Relative day label")
    }
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("MMMd")
    return f.string(from: date)
  }

  /// Reads `SeptenaDate.today` rather than `Date()`, so time travel moves this
  /// cue with everything else.
  private static func isOverdue(_ date: Date) -> Bool {
    let today = SeptenaDate.startOfDay(for: SeptenaDate.today)
      ?? Calendar.current.startOfDay(for: Date())
    return Calendar.current.startOfDay(for: date) <= today
  }

  override func accessibilityPerformPress() -> Bool {
    onTap?()
    return true
  }

  override func resetCursorRects() {
    guard hit.isEnabled else { return }
    addCursorRect(hit.frame, cursor: .pointingHand)
  }

  @objc private func fire() { onTap?() }
}

// MARK: - Group header cell

/// The header above a run of rows: the group's glyph, its name, and its count
/// — the same trio the sidebar row shows, so a group reads as the sidebar
/// entry it came from.
@MainActor
final class KitGroupHeaderCell: NSTableCellView {
  private let icon = NSImageView()
  private let emoji = NSTextField(labelWithString: "")
  private let title = NSTextField(labelWithString: "")
  private let count = NSTextField(labelWithString: "")
  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!
  /// Set only for area/project headers (see `configure`) — clicking drills
  /// into that list, the same destination its sidebar row goes to. Whether a
  /// header is clickable is entirely a matter of this being non-nil
  /// (`resetCursorRects` below) — NOT a font distinction; every header in
  /// the list reads at ONE size, "Inbox" and "Agenda" included, so a glance
  /// down the list shows one consistent rung of section title.
  var onTap: (() -> Void)?

  /// The click target for a navigable header. It has to be a real `NSButton`
  /// — `NSTableView` claims clicks on the `NSTextField` title and the
  /// `NSImageView` glyph, so the `hitTest`/`mouseDown`/`mouseUp` overrides
  /// this cell used to carry never ran.
  ///
  /// Scoped to the TITLE's own frame — not the row, and not the content
  /// column. The row is mostly empty space, and the header's whole reason for
  /// being tall is the air ABOVE it that separates one card from the next;
  /// neither should navigate. `TaskListView.groupHeaderBody` says the same
  /// outright: "Tappable target is JUST the title (+ chevron) — not the whole
  /// row… so clicks in empty horizontal space don't navigate." A full-bleed
  /// overlay here would also swallow `plus` below.
  /// Hidden for a non-navigable header so its clicks reach the table.
  private let hit = NSButton()

  /// Trailing quick-add — the AppKit counterpart of SwiftUI's
  /// `HeaderQuickAddButton`. Creates straight into this header's area/project
  /// rather than deriving filing from the list being looked at. Shown on the
  /// same terms as SwiftUI's `showsGroupedHeaderQuickAdd`: grouped Today only,
  /// and only on a header that names a real list.
  private let plus = NSButton()
  private var plusTrailingConstraint: NSLayoutConstraint!
  var onQuickAdd: (() -> Void)?

  /// Matches SwiftUI's ACTUAL group header exactly —
  /// `sectionGroupHeaderTitleStyle()` (`Theme.groupHeaderFontSize` = 15 on
  /// macOS, `.semibold`) — rather than another guessed offset off
  /// `.headline`. Every earlier pass here (`+9`, `+14`, `+10`, `.bold`) was
  /// tuning a number disconnected from the real target, which is why each
  /// round kept reading "wrong" no matter which way it was nudged. A `var`,
  /// not `let`: `FontScale.shared.factor` can change at runtime (Settings ▸
  /// Text Size), and SwiftUI's `scaledFont` reacts live — this should too.
  /// READ THE TOKEN — this had drifted back to a hardcoded `17` while saying
  /// it was 15, so an area/project header link outsized its own rows.
  private static var font: NSFont {
    .systemFont(ofSize: Theme.groupHeaderFontSize * FontScale.shared.factor,
                weight: .semibold)
  }
  /// The icon COLUMN width — same as a task row's checkbox column
  /// (`Theme.checkboxTap` = 22 on macOS) — so header glyphs and row
  /// checkboxes sit at one X. NOT the glyph's own size: SwiftUI sizes each
  /// icon KIND differently within this column (`TaskListView.groupHeaderBody`
  /// — `AreaIcon(diameter: 21)`, `ProjectProgressIcon(diameter: 14)`, a
  /// system symbol at `.scaledFont(size: 16)`), so `configure` matches those
  /// per case rather than forcing one shared diameter.
  private static let iconColumnWidth: CGFloat = 22

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    for field in [emoji, title, count] {
      field.translatesAutoresizingMaskIntoConstraints = false
    }
    icon.translatesAutoresizingMaskIntoConstraints = false
    title.font = SeptaskKitTheme.groupTitle
    title.textColor = .labelColor
    title.lineBreakMode = .byTruncatingTail
    // Sized to roughly fill the 21pt area-icon slot (matches `AreaIcon`'s
    // emoji sizing), not the title's own font. Dialed down 2pt after visual
    // review — 16 read a touch heavy next to the 17pt title.
    emoji.font = .systemFont(ofSize: 14 * FontScale.shared.factor)
    count.font = SeptaskKitTheme.meta

    count.textColor = SeptaskKitTheme.iconMuted

    hit.translatesAutoresizingMaskIntoConstraints = false
    hit.isBordered = false
    hit.isTransparent = true
    hit.title = ""
    hit.setButtonType(.momentaryChange)
    hit.refusesFirstResponder = true
    hit.isHidden = true
    hit.target = self
    hit.action = #selector(fire)
    hit.kitA11yIgnore()

    plus.translatesAutoresizingMaskIntoConstraints = false
    plus.isBordered = false
    plus.bezelStyle = .inline
    plus.imagePosition = .imageOnly
    plus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
    plus.contentTintColor = SeptaskKitTheme.iconMuted
    plus.target = self
    plus.action = #selector(quickAdd)
    // Pointer affordance only — arrow keys stay with the table, the same
    // contract the checkbox and the screen-title dropdown keep.
    plus.refusesFirstResponder = true
    plus.isHidden = true

    addSubview(icon)
    addSubview(emoji)
    addSubview(title)
    addSubview(count)
    addSubview(plus)
    // Last, so it layers above the title it covers.
    addSubview(hit)
    textField = title
    icon.kitA11yIgnore()
    emoji.kitA11yIgnore()
    title.kitA11yIgnore()
    count.kitA11yIgnore()
    setAccessibilityElement(true)
    leadingConstraint = icon.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: KitCardRowView.horizontalInset + 4)
    trailingConstraint = count.trailingAnchor.constraint(
      lessThanOrEqualTo: trailingAnchor, constant: -(KitCardRowView.horizontalInset + 8))
    plusTrailingConstraint = plus.trailingAnchor.constraint(
      equalTo: trailingAnchor, constant: -(KitCardRowView.horizontalInset + 6))
    NSLayoutConstraint.activate([
      leadingConstraint,
      icon.centerYAnchor.constraint(equalTo: title.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: Self.iconColumnWidth),
      emoji.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
      emoji.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
      title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
      // Bottom-aligned: the header's air belongs above it, separating cards.
      // -5 (was -4) — 1pt more breathing room below the title before the
      // list underneath starts.
      title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
      count.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
      count.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
      trailingConstraint,
      // The target IS the title: the same box, plus a little vertical slack so
      // a click just off the glyphs still lands.
      hit.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      hit.trailingAnchor.constraint(equalTo: title.trailingAnchor),
      hit.topAnchor.constraint(equalTo: title.topAnchor, constant: -2),
      hit.bottomAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
      plus.centerYAnchor.constraint(equalTo: title.centerYAnchor),
      plus.widthAnchor.constraint(equalToConstant: 20),
      plus.heightAnchor.constraint(equalToConstant: 20),
      plusTrailingConstraint,
    ])
  }

  required init?(coder: NSCoder) { fatalError("KitGroupHeaderCell is code-only") }

  /// Same centered-column margin as the row cells, so the header's left/right
  /// edges line up with the cards below it.
  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + 4
    trailingConstraint.constant = -(inset + 8)
    plusTrailingConstraint.constant = -(inset + 6)
    super.layout()
  }

  func configure(title titleText: String,
                 icon iconKind: SeptaskKitTaskListController.GroupIcon,
                 count countValue: Int,
                 isNavigable: Bool,
                 showsQuickAdd: Bool) {
    // Attributed, not `stringValue` + `.font`: a bare font assignment on an
    // NSTableCellView's textField is what AppKit overrides for any
    // `rowSizeStyle` other than `.custom` — belt and braces alongside setting
    // that, since this font carrying is the whole point of the row.
    title.attributedStringValue = NSAttributedString(
      string: titleText,
      attributes: [.font: Self.font, .foregroundColor: NSColor.labelColor])
    // No trailing count on any header, by request — the field stays in the
    // view for layout stability but is never populated.
    count.stringValue = ""
    _ = countValue

    emoji.isHidden = true
    icon.isHidden = false
    switch iconKind {
    case .emoji(let glyph):
      emoji.isHidden = false
      emoji.stringValue = glyph
      icon.isHidden = true
    case .areaDot:
      // 21 — matches `AreaIcon(diameter: 21)` in `TaskListView.groupHeaderBody`.
      icon.image = KitGlyph.areaDot(diameter: 21)
    case .project(let progress):
      // 13 — SwiftUI's own `ProjectProgressIcon(diameter: 14)`, dialed down
      // 1pt after visual review to sit better against the 17pt title.
      icon.image = KitGlyph.progress(progress, diameter: 13)
    case .symbol(let name):
      icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
      icon.contentTintColor = SeptaskKitTheme.inkSecondary
    }
    if isNavigable {
      kitA11yButton(label: titleText)
    } else {
      kitA11yHeader(label: titleText)
    }
    // A recycled cell keeps the previous row's overlay state otherwise, which
    // would make a plain "Inbox" header swallow clicks the table should get.
    hit.isHidden = !isNavigable
    plus.isHidden = !showsQuickAdd
    plus.setAccessibilityLabel(TaskA11y.addTaskTo(titleText))
    // Reused cells carry a stale cursor rect otherwise — a scrolled-in
    // non-navigable header could keep the pointing-hand from whatever row
    // used to occupy this recycled view.
    window?.invalidateCursorRects(for: self)
  }

  @objc private func fire() { onTap?() }

  @objc private func quickAdd() { onQuickAdd?() }

  override func accessibilityPerformPress() -> Bool {
    guard onTap != nil else { return false }
    onTap?()
    return true
  }

  /// The pointing-hand cursor is the platform's "this text is a link/button"
  /// signal — it's what makes "clickable" discoverable without a hover state
  /// to lean on in an `NSTableCellView`.
  override func resetCursorRects() {
    // Both live controls, and only them — the title text and the "+". A
    // cursor rect does NOT go through hit-testing, so anything wider would
    // advertise dead space as clickable; that false signal is what cost three
    // rounds of debugging in the 2026-08-09 pass. The `isHidden` checks stand
    // in for "is this header navigable / does it offer quick-add".
    if !hit.isHidden { addCursorRect(hit.frame, cursor: .pointingHand) }
    if !plus.isHidden { addCursorRect(plus.frame, cursor: .pointingHand) }
  }
}

/// "YYYY-MM-DD" wire dates → short localized display ("Jun 12").
@MainActor
enum KitDayFormat {
  private static let parse: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
  }()

  private static let render: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMMd")
    return formatter
  }()

  static func display(_ isoDay: String) -> String {
    guard let date = parse.date(from: isoDay) else { return isoDay }
    return render.string(from: date)
  }

  /// Short task-row date treatment, matching SwiftUI's Today/Tomorrow labels
  /// before falling back to the localized month/day form.
  static func taskDate(_ isoDay: String) -> String {
    guard let date = parse.date(from: isoDay), let today = todayDate() else {
      return display(isoDay)
    }
    let calendar = Calendar.current
    if calendar.isDate(date, inSameDayAs: today) { return "Today" }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
       calendar.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow" }
    return render.string(from: date)
  }

  /// The app's today (SeptenaDate.today, honoring time-travel), not the wall
  /// clock — per the DayClock invariant.
  static func todayDate() -> Date? {
    parse.date(from: SeptenaDate.today)
  }

  /// `offset` days from the app's today.
  static func day(offset: Int) -> Date? {
    guard let today = todayDate() else { return nil }
    return Calendar.current.date(byAdding: .day, value: offset, to: today)
  }

  static func tomorrow() -> Date? { day(offset: 1) }

  private static let clock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    formatter.dateStyle = .none
    return formatter
  }()

  private static let dayAndClock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMMd jm")
    return formatter
  }()

  /// An event's time as the row shows it: the clock alone on Today (the day
  /// is implied), day + time on Upcoming.
  static func eventTime(_ event: EKEvent, on filter: TaskFilter) -> String {
    guard let start = event.startDate else { return "" }
    if event.isAllDay {
      return filter == .today
        ? String(localized: "All day", comment: "SeptaskKit: calendar event time")
        : dayOnly.string(from: start)
    }
    return filter == .today ? clock.string(from: start) : dayAndClock.string(from: start)
  }

  private static let dayOnly: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMMd")
    return formatter
  }()

  /// Wire form ("YYYY-MM-DD") of a picked date, for reading a task's current
  /// value back into a picker.
  static func date(fromWire wire: String?) -> Date? {
    guard let wire else { return nil }
    return parse.date(from: wire)
  }
}

// MARK: - Table subclass (keyboard)

/// Keyboard seam: the `TaskRowShortcuts` equivalents intercept on the
/// responder chain ahead of the menu bar (whose SwiftUI items are disabled in
/// this window anyway — no focused task-list publisher), Return opens the
/// rename field editor. Everything else — arrows, type-select, ⇧-extension —
/// is stock NSTableView.
@MainActor
final class SeptaskKitTableView: NSTableView {

  /// Selection emphasis is computed per draw (`septaskSelectionIsActive`), so
  /// the rows must repaint when focus enters or leaves this table. AppKit
  /// posts no notification for a first-responder change — these two overrides
  /// are the hook.
  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { septaskRefreshSelectionEmphasis() }
    return accepted
  }

  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    if resigned { septaskRefreshSelectionEmphasis() }
    return resigned
  }
  var onToggleComplete: (() -> Void)?
  var onToggleToday: (() -> Void)?
  /// ⌘R — bare-title rename.
  var onBeginEdit: (() -> Void)?
  /// Return / double-click — the full inline composer.
  var onOpenComposer: (() -> Void)?
  var onDelete: (() -> Void)?
  var onNewTask: (() -> Void)?
  var onWhen: (() -> Void)?
  var onDeadline: (() -> Void)?
  var onClearSchedule: (() -> Void)?
  var onToggleInspector: (() -> Void)?
  var onQuickFind: (() -> Void)?
  var onDuplicate: (() -> Void)?
  var onMove: (() -> Void)?
  var onCopy: (() -> Void)?
  var canCopy: (() -> Bool)?
  var onPaste: (() -> Void)?
  var canPaste: (() -> Bool)?
  /// Tab / Shift-Tab — two-pane keyboard nav, sidebar ⇄ list (mirrors the
  /// sidebar's own `onTab` in `KitSidebarOutlineView`).
  var onFocusSidebar: (() -> Void)?
  /// Drag left the table or ended — clear the insertion line. `validateDrop`
  /// is not called on exit, so the table has to report this itself.
  var onDragEnded: (() -> Void)?

  /// A click in the page's side padding is a click on the PAGE, not on the
  /// row that happens to share its y. The card occupies the content column
  /// only (`KitCardRowView` insets its card by `SeptaskKitLayout.inset` on
  /// each side), so selection has to stop at the same edges — otherwise the
  /// ~10% gutter either side selects whatever row is level with the pointer,
  /// which reads as the list grabbing clicks meant for empty space.
  ///
  /// Deselecting is the same thing `NSTableView` already does for a click
  /// below the last row, so the gutter behaves like the rest of the page
  /// background. This override sits on the TABLE, not on a cell — the house
  /// rule against `mouseDown` overrides is about cell views, whose clicks the
  /// table claims before they ever arrive.
  override func mouseDown(with event: NSEvent) {
    guard isInsideContentColumn(event) else {
      deselectAll(nil)
      window?.makeFirstResponder(self)
      return
    }
    super.mouseDown(with: event)
  }

  /// Right-click follows the same rule, so the gutter can't raise a row's
  /// context menu for a row you didn't click.
  override func menu(for event: NSEvent) -> NSMenu? {
    guard isInsideContentColumn(event) else { return nil }
    return super.menu(for: event)
  }

  private func isInsideContentColumn(_ event: NSEvent) -> Bool {
    let x = convert(event.locationInWindow, from: nil).x
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    return x >= inset && x <= bounds.width - inset
  }

  /// Standard responder-chain copy, so Edit ▸ Copy (and its ⌘C) reaches the
  /// task list without a competing menu item.
  @objc func copy(_ sender: Any?) { onCopy?() }

  /// Same responder-chain contract as `copy(_:)` — Edit ▸ Paste and its ⌘V
  /// reach the task list without a competing menu item.
  @objc func paste(_ sender: Any?) { onPaste?() }

  override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(copy(_:)) { return canCopy?() ?? false }
    if item.action == #selector(paste(_:)) { return canPaste?() ?? false }
    return super.validateUserInterfaceItem(item)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

    // ⌥⌘I — the platform's inspector toggle.
    if flags == [.command, .option],
       event.charactersIgnoringModifiers?.lowercased() == "i" {
      onToggleInspector?()
      return true
    }

    // ⌘⇧D / ⌘⇧. — deliberately the shifted forms (bare ⌘. is the system
    // Cancel equivalent), matching TaskRowShortcuts. ⌘⇧F is Quick Find, the
    // same binding the SwiftUI window uses.
    if flags == [.command, .shift] {
      switch event.charactersIgnoringModifiers?.lowercased() {
      case "d": onDeadline?(); return true
      case ".": onClearSchedule?(); return true
      case "f": onQuickFind?(); return true
      case "m": onMove?(); return true
      default: return super.performKeyEquivalent(with: event)
      }
    }

    guard flags == .command else {
      return super.performKeyEquivalent(with: event)
    }
    switch event.charactersIgnoringModifiers {
    case "k": onToggleComplete?(); return true
    case "t": onToggleToday?(); return true
    case "r": onBeginEdit?(); return true
    case "n": onNewTask?(); return true
    case "s": onWhen?(); return true
    case "d": onDuplicate?(); return true
    case "m": onMove?(); return true
    case ",": SeptaskKitSettingsWindow.show(); return true
    case "\u{7F}": onDelete?(); return true   // ⌘⌫, matching TaskRowShortcuts.delete
    default: return super.performKeyEquivalent(with: event)
    }
  }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 36, 76:  // Return / keypad Enter — opens the composer, not a bare rename.
      onOpenComposer?()
    case 48:  // Tab / Shift-Tab — only two stops in the loop, so either
      // direction just crosses to the sidebar (no field editor is live here;
      // one is first responder instead and eats Tab before this fires).
      onFocusSidebar?()
    default:
      super.keyDown(with: event)
    }
  }

  /// Escape clears the selection — the standard AppKit responder method for
  /// "back out of the current state", and the only reliable way to unselect on
  /// a FULL list: clicking the background works, but a list that fills the
  /// view has no background left to click, and the gutter beside a card is
  /// still that row's rect (clicking it selects rather than deselects).
  /// Editing takes priority: while a field editor is live it owns Escape (it
  /// cancels the edit) and this never fires.
  override func cancelOperation(_ sender: Any?) {
    guard !selectedRowIndexes.isEmpty else { return }
    deselectAll(nil)
  }

  /// Finder-standard context-menu targeting: right-click inside the selection
  /// acts on the selection; outside it, the clicked row becomes the selection.
  var onRightClick: ((NSEvent) -> Void)?

  /// Deliberately does NOT call super — see the comment where `onRightClick`
  /// is wired up. `NSTableView`'s default secondary-click handling is what
  /// paints the native row highlight we're avoiding, so this replaces it
  /// entirely rather than adding to it.
  override func rightMouseDown(with event: NSEvent) {
    onRightClick?(event)
  }

  override func draggingExited(_ sender: (any NSDraggingInfo)?) {
    super.draggingExited(sender)
    onDragEnded?()
  }

  override func draggingEnded(_ sender: any NSDraggingInfo) {
    super.draggingEnded(sender)
    onDragEnded?()
  }
}
#endif
