#if os(macOS)
import AppKit
import EventKit
import SwiftData
import SwiftUI

extension NSPasteboard.PasteboardType {
  /// Dragged task rows carry their stable task id — the same identity every
  /// wire and mutator speaks (docs/IDENTIFIERS.md).
  static let septaskTask = NSPasteboard.PasteboardType("com.septena.septask.task-id")
  /// Dragged SIDEBAR STRUCTURE rows (area/project reordering) — carries the
  /// node's `key` ("area:<id>" / "project:<id>"), distinct from
  /// `.septaskTask` so the sidebar's single drop handler can tell "reorder
  /// the sidebar itself" apart from "file a dragged task".
  static let septaskStructureItem = NSPasteboard.PasteboardType("com.septena.septask.structure-item")
  /// Dragged special smart-list rows (sidebar smart-list reordering) — carries
  /// the canonical `RegistryDestination.id`, distinct from `.septaskStructureItem`
  /// so smart lists can only reorder within their own top cluster and never mix
  /// with areas or projects below.
  static let septaskSmartListItem = NSPasteboard.PasteboardType("com.septena.septask.smart-list-item")
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
// Keyboard map — same bindings as the registry shortcuts (`RegistryActions`, registry/actions.json),
// so the two shells never teach conflicting muscle memory:
//   ↑/↓, ⇧-arrows, type-select, Home/End — native NSTableView
//   ⌘K — toggle complete          ⌘T — toggle Today
//   ⌘N — new task in this list    ⌘, — settings
//   ⌘R — bare rename via the field editor
//   Return, double-click — inline composer on the title
//   ⌥↩ — opens the composer straight into notes
//   ⌘↩ — commits and folds the open row from anywhere in it. ↓ on the
//        title's last line drops into notes, ↑ on the first notes line goes
//        back up to the title.
//   ONE edit contract for the composer AND the bare field editor: Esc,
//   Return, ⌘↩, click-away, a list change and window close all SAVE and
//   close. ⌘Z undoes the save (`TaskUndo`). Nothing discards typed text.
//   ⌘↑ / ⌘↓ — move the selected task(s) one slot (manual-order lists only)
//   ⌘⌫ — delete (soft; lands in Recently Deleted)
//   ⌥⌘M — file into the suggested list (the "→ Suggested" capsule's pick)
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

  /// A calendar event flattened to a value — the row diff compares rows, and
  /// EKEvent is a live reference whose identity says nothing about content.
  struct Event: Equatable {
    let id: String
    let title: String
    let time: String
  }

  /// Sub-view inside Logbook (issue #202): Completed tasks vs. Recently Deleted.
  enum LogbookTab: Int, Equatable {
    case completed = 0
    case deleted = 1
  }

  /// One list line: a synthetic group header, a task row, a calendar event,
  /// the project/area page's own big title, or the "N logged items" footer.
  /// `key` is the stable identity the animated diff runs on.
  private enum Row: Equatable {
    case header(id: String, title: String, icon: GroupIcon, count: Int)
    case screenTitle(title: String, icon: GroupIcon)
    case logbookBar(tab: LogbookTab, deletedCount: Int, showsSegmented: Bool, canEmptyTrash: Bool)
    case tagFilterBar(tags: [TaskTag], active: [String])
    case projectTarget(id: String, title: String, progress: Double, count: Int)
    case task(SeptenaTask, chip: Chip?, suggestion: SuggestionEngine.Suggestion?)
    case event(Event)
    case fadedFooter(count: Int, expanded: Bool)
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
    /// A notice on top of Today (sign in, rolled in, an explainer). Which
    /// ones show, and in what order, is decided by `TaskNotices`.
    case notice(TaskNotice)
    /// One Get started step under its notice: a real, selectable row (↑/↓,
    /// Return, ⌘K, type-select, right-click) that is never a task. Every task
    /// command reads `task`, which is nil here, so it does nothing.
    case noticeStep(TaskNoticeStep)
    /// An agent's proposed brief update, rendered directly above the notes row
    /// (`KitNotesProposalCell`, ADR 0012, #123). Not selectable.
    case notesProposal(isArea: Bool, id: String, currentNotes: String, proposal: NotesProposal)
    /// The project's or area's notes, under the page title
    /// (`KitContainerNotesCell`, ADR 0012). Not selectable: it carries no
    /// task, and a click opens its editor popover.
    case containerNotes(isArea: Bool, id: String, text: String)

    var key: String {
      switch self {
      case .header(let id, _, _, _): return "h:" + id
      case .screenTitle: return "screen-title"
      case .logbookBar: return "logbook-bar"
      case .tagFilterBar: return "tag-filter-bar"
      case .projectTarget(let id, _, _, _): return "project-target:" + id
      case .task(let task, _, _): return task.id
      case .event(let event): return "e:" + event.id
      case .fadedFooter: return "faded-footer"
      case .loggedFooter: return "logged-footer"
      case .newTask: return "new-task"
      case .addSection: return "add-section"
      case .reminder(let item, _): return "reminder:" + item.id
      case .notice(let notice): return "notice:" + notice.id.rawValue
      case .noticeStep(let step): return step.selectionID
      case .importAllReminders: return "import-all-reminders"
      case .notesProposal: return "notes-proposal"
      case .containerNotes: return "container-notes"
      }
    }

    var task: SeptenaTask? {
      if case .task(let task, _, _) = self { return task }
      return nil
    }

    var noticeStep: TaskNoticeStep? {
      if case .noticeStep(let step) = self { return step }
      return nil
    }

    /// A standalone notice (no steps under it). It is a selectable row: ↑/↓
    /// reach it, ⌘K dismisses it, Return does its action. A notice that heads
    /// Get started steps is not: its steps are the rows.
    var standaloneNotice: TaskNotice? {
      if case .notice(let notice) = self, notice.steps.isEmpty { return notice }
      return nil
    }

    /// Rows that draw on a card (tasks and events), vs. headers on the page.
    /// Project section headings sit BETWEEN cards (SwiftUI's `headingRow`),
    /// so they break the card run the same way a Today area/project header does.
    var isCardRow: Bool {
      switch self {
      case .header, .screenTitle, .logbookBar, .tagFilterBar, .fadedFooter, .loggedFooter, .addSection, .notesProposal, .containerNotes: return false
      // A standalone notice sits on the page with its own card fill. A notice
      // with checklist steps (`Get started`) heads its steps' card so the
      // header and rows share one seamless frosted surface (matching iOS).
      case .notice(let notice): return !notice.steps.isEmpty
      // Rides the Inbox card with the reminder rows it acts on.
      case .importAllReminders: return true
      case .projectTarget, .event, .newTask, .reminder: return true
      // Get started steps read as tasks, so they ride a card like tasks.
      case .noticeStep: return true
      case .task(let task, _, _): return !task.isHeading
      }
    }
  }

  private let tableView = SeptaskKitTableView()
  private let scrollView = NSScrollView()
  private let headerWashView = KitHeaderWashView()
  private let emptyLabel = NSTextField(labelWithString: RegistryDestinations.GenericEmpty.title)
  private let emptyDetailLabel = NSTextField(wrappingLabelWithString: "")
  private let emptyStack = NSStackView()
  private var rows: [Row] = []
  private var filter: TaskFilter = .today
  private var logbookTab: LogbookTab = .completed
  private var observers: [NSObjectProtocol] = []

  /// True when the list is displaying soft-deleted tasks — either inside
  /// Logbook's Deleted sub-view or via a direct `.recentlyDeleted` filter.
  private var showingRecentlyDeleted: Bool {
    filter == .recentlyDeleted || (filter == .logbook && logbookTab == .deleted)
  }

  /// Effective filter backing the current rows and empty state.
  private var activeFilter: TaskFilter {
    showingRecentlyDeleted ? .recentlyDeleted : filter
  }
  /// A ⌘N row whose first title is still being typed — abandoned (empty on
  /// commit) it's purged, so escaping a fresh row leaves nothing behind.
  private var pendingNewTaskId: String?
  /// True while the rolled-back-save sheet is on screen, so a run of failures
  /// raises one report instead of one sheet per failed write.
  private var storeHealthSheetUp = false
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
  /// intent has to outlive the mutation by exactly one reload. Rows that
  /// arrive on Today from ANOTHER device queue here too
  /// (`queueTodayArrivalFlashes`), so a remote promote lands with the same
  /// cue a local one does.
  /// The AppKit counterpart of SwiftUI's `PromoteFlashStore`.
  private var pendingPromoteFlash: Set<String> = []
  /// How many remote arrivals per reload get the promote cue — a batch sync
  /// after a day away must not pulse the whole list. Same cap as
  /// `RemoteTaskSync.flashTodayPromotes`.
  private static let arrivalFlashCap = 3
  /// task id → top filing pick, the "→ Suggested" capsule's contents. Snapshot
  /// per reload (like `TaskListModel.filingSuggestions`) rather than read live
  /// off the engine, so a row and its capsule always agree.
  private var filingSuggestions: [String: SuggestionEngine.Suggestion] = [:]
  /// Live notes-band height while the composer is open (`nil` = notes folded).
  /// The open composer row's live height (wrapping title + notes + rail),
  /// cached from `KitComposerCell.expandedHeight` so `heightOfRow` never has
  /// to reach into a cell. Nil while no row is composing.
  private var composerRowHeight: CGFloat?
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
  /// Completed rows are lingering on screen (see `beginSettle`). Reloads still
  /// run meanwhile; they keep `settlingIDs` pinned on screen (`pinned`).
  private var isSettling = false
  /// The rows lingering in the settle window — restyled done/cancelled, held
  /// on screen by `reload` until the settle ends.
  private var settlingIDs: Set<String> = []
  /// A drag is over (or was started from) this table. Reloads wait for the
  /// drop, so the row indexes `validateDrop` showed are still the ones
  /// `acceptDrop` resolves — a sync batch landing mid-drag would otherwise
  /// shift them under the pointer.
  private var isDragActive = false
  /// A reload was held back by `isApplyingMove` / `isDragActive`; run it when
  /// the gate clears (`flushHeldReload`).
  private var heldReload = false
  private var settleWorkItem: DispatchWorkItem?
  /// Shared trigger, once-a-day budget, and interruption state for Inbox zero
  /// header motion (`docs/INBOX_ZERO_MOTION_SPEC.md`, #298).
  private var inboxZeroTracker = InboxZeroMotionTracker()
  private var inboxZeroHoldWorkItem: DispatchWorkItem?
  /// Notifications are synchronous, but a single user gesture can emit several
  /// of them (move-to-area, date changes, batch completion). Keep the payload
  /// and repaint once on the next run-loop turn instead of rebuilding the table
  /// once per field write.
  private var reloadWorkItem: DispatchWorkItem?
  private var pendingReloadIDs: Set<String> = []
  /// A move batch is mid-flight. `moveToList` is one write per task, but a
  /// batch is several, and each posts synchronously. Keep the table stable
  /// until the whole batch lands; otherwise an intermediate diff can remove a
  /// row before the rest of the batch has been written.
  private var isApplyingMove = false
  /// Composer rows still running their close animation. The commit that
  /// closed them posts a change notification, and its scheduled reload lands
  /// mid-fold: a new task's reload also brings back the "New task" line and
  /// the row's filing capsule, so the diff re-rendered the row as a closed
  /// cell in the still-tall frame and the title jumped. Scheduled reloads
  /// wait for the fold, whose completion reloads anyway. Direct `reload()`
  /// calls (⌘N, a list switch) still run at once.
  private var foldingComposerIDs: Set<String> = []
  private var checklistCounts: [String: (done: Int, total: Int)] = [:]
  private var attachmentCounts: [String: Int] = [:]
  /// The kind of a task's `from` reference, for the row icon.
  private var fromRefKinds: [String: String] = [:]
  /// The newest `issue` reference of the Review rows.
  private var issueRefs: [String: TaskRefRow] = [:]
  private var tagsByID: [String: TaskTag] = [:]
  private var activeTagFilterIDs: Set<String> = []

  /// The inspector follows the selection; the window owns the wiring.
  var onSelectionChange: ((SeptenaTask?) -> Void)?
  /// A refresh landed — anything showing this data should re-read.
  var onStoreChanged: (() -> Void)?
  var onToggleInspector: (() -> Void)?
  /// Open (`task.open`): show the inspector pane for the selection and never
  /// close it. On the Mac the task page is the inspector (ADR 0029).
  var onOpenInspector: (() -> Void)?
  /// Send back on a Review row: open the inspector for the selected row with
  /// its Send back field open and focused.
  var onOpenSendBack: (() -> Void)?
  var onQuickFind: (() -> Void)?
  /// Jump to another destination — a grouped Today/Anytime area or project
  /// header was clicked, or the title dropdown picked a list. Carries a
  /// `KitSidebarDestination` (not a bare `TaskFilter`) because Next is a
  /// sidebar destination without a filter of its own.
  var onNavigate: ((KitSidebarDestination) -> Void)?
  /// Tab pressed while the list holds focus — the window owns moving focus
  /// to the sidebar (see `focusList()`'s sibling, `focusSidebar()`).
  var onFocusSidebar: (() -> Void)?
  /// True while the split view's sidebar is visible on screen. When true, the
  /// page title renders as plain static text without a navigation dropdown.
  private var isSidebarVisible = true

  private var context: ModelContext { LocalStore.shared.container.mainContext }

  /// Task ids captured when the Move picker opens. The picker is a separate
  /// surface and can outlive a list refresh; applying to the live row index
  /// after it closes can otherwise target a different similarly named task.
  private var pendingMoveIDs: [String] = []

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

  /// Thin wrappers over the SHARED `TaskUndo` helpers. Every inverse below
  /// captures the mutator, never this controller: an undo closure that held
  /// the controller weakly went inert once the window closed, so ⌘Z from the
  /// SwiftUI window (or after reopening this one) silently did nothing. The
  /// list refreshes itself from the mutators' change notifications, so no
  /// closure needs to reach back here to reload.
  private func recordUndo(name: String,
                          undo undoAction: @escaping @MainActor () -> Void,
                          redo redoAction: @escaping @MainActor () -> Void) {
    TaskUndo.record(name: name, undo: undoAction, redo: redoAction)
  }

  private func scheduleSnapshot(_ task: SeptenaTask) -> TaskUndo.ScheduleSnapshot {
    TaskUndo.ScheduleSnapshot(task)
  }

  /// Register undo for a change to the scheduling fields. Call it AFTER the
  /// change, with `before` captured beforehand (`TaskUndo.recordScheduleChange`).
  private func recordScheduleUndo(name: String, before: [TaskUndo.ScheduleSnapshot]) {
    TaskUndo.recordScheduleChange(name: name, before: before,
                                  context: context, mutator: mutator)
  }

  /// Undo for freshly created tasks (`TaskUndo.recordCreate`). `rebuild` must
  /// not capture the controller — pass it values and the mutator.
  private func recordCreateUndo(name: String, ids: [String],
                                rebuild: @escaping @MainActor () -> [String]) {
    TaskUndo.recordCreate(name: name, ids: ids, mutator: mutator, rebuild: rebuild)
  }

  /// Undo for a ⌘N row that has just been given a real title. The undoable
  /// act is the CREATION, not a rename from the empty placeholder the row was
  /// born with — reading the row's own filing back out means redo re-creates
  /// it exactly where it was.
  private func recordNewTaskUndo(id: String) {
    guard let task = LocalCache.task(id: id, in: context)
    else { return }
    let title = task.title
    let notes = task.notes
    let area = task.area
    let project = task.project
    let scheduled = KitDayFormat.date(fromWire: task.scheduled)
    let today = task.today
    let mutator = self.mutator
    recordCreateUndo(name: RegistryActions.title(.appNewTask),
                     ids: [id],
                     rebuild: {
                       [mutator.create(title: title, area: area, project: project,
                                       scheduled: scheduled, today: today, notes: notes,
                                       atBottom: false).id]
                     })
  }

  private var mutator: TaskMutator { SeptenaServices.shared.taskMutator }

  /// An empty list is a lie while the first pull from the task backend is still
  /// running for a signed-in account — the list is empty because the data
  /// hasn't arrived yet. Signed out (free no-account mode) is a real empty
  /// local list, never a sign-in gate (docs/SYNC_SUBSCRIPTION_SPEC.md §3, §7).
  private func refreshEmptyLabel() {
    let sync = TaskSyncEngine.shared
    if sync.signedIn && sync.isSyncing && sync.lastPull == nil {
      emptyLabel.stringValue = RegistryDestinations.GenericEmpty.syncingTitle
      emptyDetailLabel.stringValue = ""
      emptyDetailLabel.isHidden = true
    } else {
      // Registry copy (`registry/destinations.json`), the same words the
      // SwiftUI list's empty state shows.
      emptyLabel.stringValue = activeFilter.emptyTitle
      emptyDetailLabel.stringValue = activeFilter.emptyDetail
      emptyDetailLabel.isHidden = false
    }
  }

  /// `TaskSyncEngine` is `@Observable`, which drives SwiftUI automatically but
  /// does nothing for an NSViewController. Re-arm a one-shot observation after
  /// each change: the empty label follows the sync state, and a sign-in or
  /// sign-out reloads the list (Today's sign-in notice comes and goes).
  private func observeBootstrapState() {
    let wasSignedIn = TaskSyncEngine.shared.signedIn
    let hadAccount = TaskSyncEngine.shared.hadAccount
    withObservationTracking {
      let sync = TaskSyncEngine.shared
      _ = sync.signedIn
      _ = sync.hadAccount
      _ = sync.isSyncing
      _ = sync.lastPull
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.refreshEmptyLabel()
        if TaskSyncEngine.shared.signedIn != wasSignedIn
          || TaskSyncEngine.shared.hadAccount != hadAccount {
          self.reload()
        }
        self.observeBootstrapState()
      }
    }
  }

  /// One toast per window (`SeptaskKitToast.swift`). A new one replaces the
  /// current one; it never stacks.
  private let toastStore = SeptenaToastStore()
  /// The completed ids the project/area logged footer counts, captured on
  /// each reload. "Clear Logged…" (issue #208) clears exactly this set, so
  /// the prompt's count matches the footer and no other page is touched.
  private var loggedClearIDs: [String] = []
  private lazy var toastHost = KitToastHost(store: toastStore)

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
    // `.none` keeps the card intact; we draw SwiftUI's `TaskInsertionMark` instead.
    tableView.draggingDestinationFeedbackStyle = .none
    tableView.dataSource = self
    tableView.delegate = self
    tableView.target = self
    tableView.doubleAction = #selector(beginEditFromDoubleClick)
    tableView.onToggleComplete = { [weak self] in self?.toggleCompleteSelection() }
    tableView.onToggleToday = { [weak self] in self?.toggleTodaySelection() }
    tableView.onBeginEdit = { [weak self] in self?.beginEditSelectedRow() }
    tableView.onCommitEditing = { [weak self] in self?.commitComposerEditing() }
    tableView.onOpenNotes = { [weak self] in self?.beginComposingSelectedRowInNotes() }
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
    tableView.onFileSuggested = { [weak self] in self?.fileSuggestedSelection() }
    tableView.onReminder = { [weak self] in self?.presentReminderPopover() }
    tableView.onToggleStar = { [weak self] in self?.toggleStarSelection() }
    tableView.onEditTags = { [weak self] in self?.presentTagPopover() }
    tableView.onAddChecklistItem = { [weak self] in self?.addChecklistItemToSelection() }
    tableView.onClearTagFilter = { [weak self] in self?.clearTagFilterIfActive() ?? false }
    tableView.onPasteAttachment = { [weak self] in self?.pasteAttachmentToSelection() ?? false }
    tableView.onFocusSidebar = { [weak self] in self?.onFocusSidebar?() }
    tableView.onMoveSelection = { [weak self] up in self?.moveSelectionOneSlot(up: up) }
    tableView.isComposing = { [weak self] in self?.composingTaskId != nil }
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
    // Every row menu is rendered from the registry (`registry/actions.json`)
    // fresh on each click, from the current selection.
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
      // A Get started step has its own short menu: no task command applies.
      if self.rows.indices.contains(row), self.rows[row].noticeStep != nil {
        if !tableView.selectedRowIndexes.contains(row) {
          tableView.selectRowIndexes([row], byExtendingSelection: false)
        }
        self.buildNoticeStepMenu().popUp(positioning: nil, at: point, in: tableView)
        return
      }
      // The project/area logged footer has its own one-item menu (registry
      // `scope.loggedFooter`). Today's footer has none: it is not a scope.
      if self.rows.indices.contains(row), case .loggedFooter = self.rows[row],
         self.scopeId != nil, !self.loggedClearIDs.isEmpty {
        self.buildLoggedFooterMenu().popUp(positioning: nil, at: point, in: tableView)
        return
      }
      // Only a TASK row has a task menu. A header, an event, the "New task"
      // line or a reminder used to get the full menu, with every command
      // aimed at whatever happened to be selected elsewhere. On a project
      // page, right-clicking the page title, project notes, or Add Section
      // row offers the same "New Section" menu as blank space below the list.
      guard self.rows.indices.contains(row) else { return }
      guard self.rows[row].task != nil else {
        if case .project = self.filter {
          switch self.rows[row] {
          case .screenTitle, .containerNotes, .addSection:
            self.buildBlankSpaceMenu().popUp(positioning: nil, at: point, in: tableView)
          default:
            break
          }
        }
        return
      }
      if !tableView.selectedRowIndexes.contains(row) {
        tableView.selectRowIndexes([row], byExtendingSelection: false)
      }
      let menu: NSMenu
      if let task = self.rows[row].task, task.isHeading {
        menu = self.buildHeadingContextMenu()
      } else if self.showingRecentlyDeleted {
        menu = self.buildRecentlyDeletedMenu()
      } else if self.filter == .faded || (self.rows[row].task?.isFaded == true) {
        menu = self.buildFadedMenu()
      } else {
        menu = self.buildContextMenu()
      }
      menu.popUp(positioning: nil, at: point, in: tableView)
    }
    tableView.registerForDraggedTypes([.septaskTask, .fileURL])
    tableView.setDraggingSourceOperationMask(.move, forLocal: true)
    tableView.onDragEnded = { [weak self] in self?.endDragHold() }

    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.contentView.drawsBackground = false
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

    // Backdrop hosts the solid page fill + top-bleed procedural Header Wash
    // behind the transparent scroll view so geometry extends all the way up
    // behind the unified title bar and breathes behind translucent top cards.
    let container = KitPageBackdropView()
    headerWashView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(headerWashView)
    container.addSubview(scrollView)
    NSLayoutConstraint.activate([
      headerWashView.topAnchor.constraint(equalTo: container.topAnchor),
      headerWashView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      headerWashView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      headerWashView.heightAnchor.constraint(equalToConstant: 394),
      scrollView.topAnchor.constraint(equalTo: container.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    view = container

    emptyLabel.font = SeptaskKitTheme.taskTitle
    emptyLabel.textColor = SeptaskKitTheme.iconMuted
    emptyLabel.alignment = .center
    emptyDetailLabel.font = SeptaskKitTheme.meta
    emptyDetailLabel.textColor = SeptaskKitTheme.inkSecondary
    emptyDetailLabel.alignment = .center
    emptyDetailLabel.maximumNumberOfLines = 3
    emptyDetailLabel.isHidden = true
    emptyStack.orientation = .vertical
    emptyStack.alignment = .centerX
    emptyStack.spacing = 6
    emptyStack.translatesAutoresizingMaskIntoConstraints = false
    emptyStack.addArrangedSubview(emptyLabel)
    emptyStack.addArrangedSubview(emptyDetailLabel)
    view.addSubview(emptyStack)
    NSLayoutConstraint.activate([
      emptyStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      emptyStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      emptyStack.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
      emptyStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
      emptyStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
    ])
    refreshEmptyLabel()
    // The bottom toast (move / defer / delete confirmations), on top of the
    // list like the SwiftUI shell's overlay. It sizes itself to the capsule.
    view.addSubview(toastHost)
    NSLayoutConstraint.activate([
      toastHost.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      toastHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      toastHost.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor),
    ])
    observeBootstrapState()

    // CloudKit batches post .septenaTasksChanged; mutations made in the
    // SwiftUI window don't post anything (its views refresh themselves), so
    // window-becomes-key covers the cross-window A/B case.
    for name in [Notification.Name.septenaTasksChanged, .septenaStructureChanged,
                 .septenaDataChanged, .septaskSettingsPulled] {
      observers.append(NotificationCenter.default.addObserver(
        forName: name, object: nil, queue: .main
      ) { [weak self] note in
        // A local mutation names its ids (`TaskChange.post`); a CloudKit
        // batch, a structure change and a migration don't. The ids keep this
        // process's own edits off the passive-sync cues (`ghostCheck…` /
        // `queueTodayArrivalFlashes` in `reload`). Notifications are posted
        // synchronously, but the actual repaint is coalesced so a multi-field
        // gesture does not rebuild the whole page once per write.
        MainActor.assumeIsolated {
          guard let self else { return }
          self.scheduleReload(locallyChanged: note.changedTaskIDs ?? [])
          if let id = self.composingTaskId { self.composerCell(for: id)?.refreshReferences() }
        }
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
    // Midnight. Today / Upcoming / day headers are all computed against the
    // current day, so a window left open overnight must re-read when the day
    // flips — `NSCalendarDayChanged` is the same signal `DayClock` and
    // `SeptenaServices` (fixed-repeat catch-up) use; wake covers a Mac that
    // slept through it. Coalesced like every other refresh, so the catch-up's
    // own task notifications land in the same repaint.
    observers.append(NotificationCenter.default.addObserver(
      forName: .NSCalendarDayChanged, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.reloadIfDayChanged(force: true) }
    })
    observers.append(NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.reloadIfDayChanged(force: false) }
    })
    observers.append(NotificationCenter.default.addObserver(
      forName: .septenaTextSizeDidChange, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshTextSize() }
    })
    // A rolled-back save. This shell is pure AppKit, so it cannot use the
    // SwiftUI `.storeHealthAlert()` the Septena surfaces carry — it listens for
    // the notification and raises the same report as a window sheet.
    observers.append(NotificationCenter.default.addObserver(
      forName: StoreHealthState.failureNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.reportStoreHealthFailure() }
    })
    // View ▸ Group Today by List. This table reads the setting straight from
    // UserDefaults, so it needs telling — and a full rebuild, not a diff
    // (see `refreshViewOptions`).
    observers.append(NotificationCenter.default.addObserver(
      forName: .septenaTaskViewOptionsChanged, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshViewOptions() }
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
    observers.append(NotificationCenter.default.addObserver(
      forName: .septenaAppearanceChanged, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshAppearance() }
    })
  }

  /// Repaint the Header Wash, frosted glass cards/notices, selection washes,
  /// and custom fruit checkboxes live when Appearance settings change.
  private func refreshAppearance() {
    view.needsDisplay = true
    headerWashView.reloadConfig()
    tableView.enumerateAvailableRowViews { rowView, _ in
      if let cardRow = rowView as? KitCardRowView {
        cardRow.refreshAppearance()
      } else {
        rowView.needsDisplay = true
      }
      for col in 0..<rowView.numberOfColumns {
        if let cell = rowView.view(atColumn: col) as? NSView {
          Self.refreshAppearanceSubviews(in: cell)
        }
      }
    }
  }

  private static func refreshAppearanceSubviews(in view: NSView) {
    if let checkbox = view as? KitCheckboxView {
      checkbox.refreshAppearance()
      return
    }
    if let noticeFill = view as? KitNoticeFill {
      noticeFill.refreshAppearance()
    }
    for sub in view.subviews {
      refreshAppearanceSubviews(in: sub)
    }
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
    remeasureNotesRowIfWidthChanged()
  }

  /// The table width the notes row was last measured at.
  private var notesRowMeasuredWidth: CGFloat = 0

  /// The notes row wraps, so its height depends on the width: re-note it when
  /// the width moves. Guarded on a real change, for the same re-entry reason
  /// as the inset above.
  private func remeasureNotesRowIfWidthChanged() {
    let width = tableView.bounds.width
    guard abs(width - notesRowMeasuredWidth) > 0.5 else { return }
    notesRowMeasuredWidth = width
    let indexes = IndexSet(rows.indices.filter { idx in
      guard idx < tableView.numberOfRows else { return false }
      switch rows[idx] {
      case .containerNotes, .notesProposal: return true
      default: return false
      }
    })
    guard !indexes.isEmpty else { return }
    tableView.noteHeightOfRows(withIndexesChanged: indexes)
  }

  override func viewWillDisappear() {
    super.viewWillDisappear()
    cancelInboxZeroMotion()
  }

  deinit {
    reloadWorkItem?.cancel()
    inboxZeroHoldWorkItem?.cancel()
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
  }

  /// The day the rows on screen were computed for (see `reloadIfDayChanged`).
  private var renderedDay = SeptenaDate.today

  /// Re-read when the calendar day has moved since the last paint.
  private func reloadIfDayChanged(force: Bool) {
    let today = SeptenaDate.today
    guard force || today != renderedDay else { return }
    renderedDay = today
    headerWashView.dayISO = today
    scheduleReload(locallyChanged: [])
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
    // The window commits before it navigates; this is the backstop, so a
    // composer can never ride along (pinned) into a different list.
    commitOpenEdits()
    cancelSettle()
    resetInboxZeroMotionForFilterChange()
    activeTagFilterIDs.removeAll()
    logbookTab = .completed
    self.filter = filter
    if case .project(let id) = filter {
      headerWashView.projectID = id
    } else {
      headerWashView.projectID = nil
    }
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

  /// Update the page-title cell when the split view's sidebar collapses or
  /// expands — showing the dropdown chevron/menu only when the sidebar is
  /// hidden, without reloading the table or disturbing open edits.
  func setSidebarVisible(_ visible: Bool) {
    guard isSidebarVisible != visible else { return }
    isSidebarVisible = visible
    guard let row = rows.firstIndex(where: {
      if case .screenTitle = $0 { return true }
      return false
    }),
    let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? KitScreenTitleCell
    else { return }
    cell.setShowsNavMenu(!isSidebarVisible)
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

  /// True while any text view in this window holds the caret. The menu-bar
  /// fallback that routes Task-menu commands here should disable row
  /// commands then: the table already leaves those keys to the text, but a
  /// menu item with the same key equivalent would still fire.
  var isEditingText: Bool { view.window?.firstResponder is NSText }

  /// Save and close whatever edit is open in this list — the inline composer
  /// and the bare field editor (⌘R rename, the Inbox "New task" line, a
  /// header "+"). Synchronous: when it returns, the typed text is in the
  /// store and the row is closed. Safe to call when nothing is open.
  ///
  /// The window calls it on sidebar navigation, the Next page, window close
  /// and app quit — the "list change and window close SAVE" half of the one
  /// edit contract. ⌘N, delete and `show(_:)` call it too.
  func commitOpenEdits() {
    commitFieldEditorNow()
    if composingTaskId != nil { collapseComposer(commit: true, animated: false) }
  }

  /// Commit a live field-editor edit synchronously. The cell's own end-edit
  /// path defers its commit one tick (first-responder reentrancy, see
  /// `viewFor:`'s `onRename`); a caller about to create a row or leave the
  /// list can't wait for that tick, so the text is taken out of the editor
  /// FIRST and committed outside any responder transition.
  private func commitFieldEditorNow() {
    guard let id = editingTaskId,
          let row = rows.firstIndex(where: { $0.task?.id == id }),
          let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
            as? SeptaskKitTaskCell,
          let text = cell.takeEditForCommit()
    else {
      // An editor this list doesn't track by id: end it the standard way.
      // It still commits (Esc no longer reverts), one tick later.
      if isTitleEditorActive { view.window?.makeFirstResponder(tableView) }
      return
    }
    commitRename(id: id, title: text)
  }

  /// Native AppKit cells do not observe `FontScale` the way SwiftUI font
  /// tokens do. Reload the visible table cells and invalidate row heights so
  /// View ▸ Text Size takes effect immediately in the main shell.
  func refreshTextSize() {
    emptyLabel.font = SeptaskKitTheme.taskTitle
    emptyDetailLabel.font = SeptaskKitTheme.meta
    tableView.reloadData()
    if tableView.numberOfRows > 0 {
      tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<tableView.numberOfRows))
    }
    tableView.needsLayout = true
  }

  /// View ▸ Group Today by List flipped. Not a `reload()`: the setting is read
  /// globally (`todayGroupsByList`, and `taskContextText` through it), not
  /// carried in the `Row` value, so the animated diff can't see that a
  /// surviving row now wants a context subtitle and a taller slot — it kept
  /// its cached one-line height and clipped the second line. Rebuild hard
  /// (`animated: false` takes `apply`'s `reloadData()` path) and invalidate
  /// every height, the same treatment a text-size change needs.
  func refreshViewOptions() {
    reload(animated: false)
    if tableView.numberOfRows > 0 {
      tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<tableView.numberOfRows))
    }
    tableView.needsLayout = true
  }

  /// Select and reveal a row by task id — how a jump (Quick Find) lands on
  /// the thing it was asked to find. No-op when the task isn't in this list.
  /// Returns false when the task isn't in this list, so the caller (Quick
  /// Find) can fall back.
  @discardableResult
  func select(taskId: String) -> Bool {
    guard let row = rows.firstIndex(where: { $0.task?.id == taskId }) else { return false }
    tableView.selectRowIndexes([row], byExtendingSelection: false)
    tableView.scrollRowToVisible(row)
    view.window?.makeFirstResponder(tableView)
    return true
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

  /// Defer one repaint to the next main-run-loop turn and merge all task ids
  /// posted during the current gesture. Direct callers of `reload()` cancel
  /// this work and consume the same ids, so legacy explicit reloads remain
  /// immediate without causing a second pass.
  private func scheduleReload(locallyChanged ids: Set<String>) {
    pendingReloadIDs.formUnion(ids)
    guard reloadWorkItem == nil else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.reloadWorkItem = nil
      // The fold's own completion reloads and takes the queued ids.
      guard self.foldingComposerIDs.isEmpty else { return }
      self.reload()
    }
    reloadWorkItem = work
    DispatchQueue.main.async(execute: work)
  }

  /// Take pending notification metadata for an immediate reload. If a move
  /// batch or a drag holds reloads back, `reload()` returns before this is
  /// called, leaving the metadata queued for the next real repaint.
  private func takePendingReloadIDs() -> Set<String> {
    reloadWorkItem?.cancel()
    reloadWorkItem = nil
    let ids = pendingReloadIDs
    pendingReloadIDs.removeAll()
    return ids
  }

  /// `locallyChanged` is the id set a local mutation's notification carried
  /// (empty for a CloudKit batch or a direct call). Those rows are this
  /// process's own doing and are kept off the passive-sync cues below.
  private func reload(animated: Bool = true, locallyChanged: Set<String> = []) {
    // Only two states HOLD a reload back, and both end in one of their own:
    // a move batch (one write per task, see `move(to:taskIDs:)`) and a drag
    // (drop targets must not shift between validate and accept). Editing,
    // composing and the settle window no longer skip — they PIN their rows
    // (see `pinned`) and let everything else update, so a list never sits
    // stale behind an open editor or a lingering completion.
    if isApplyingMove || isDragActive {
      heldReload = true
      return
    }
    heldReload = false
    checklistCounts = LocalCache.checklistSummaryByTask(in: context)
    attachmentCounts = SeptenaServices.shared.taskAttachmentStore.attachmentCountsByTask()
    fromRefKinds = LocalCache.fromRefKinds(in: context)
    issueRefs = filter == .review ? LocalCache.newestIssueRefs(in: context) : [:]
    tagsByID = LocalCache.tagsByID(in: context)

    let locallyChanged = locallyChanged.union(takePendingReloadIDs())
    renderedDay = SeptenaDate.today

    // What's on screen right now, for the passive-sync diff below.
    let priorTasks = rows.compactMap(\.task)

    let selected = Set(tableView.selectedRowIndexes.compactMap { row in
      rows.indices.contains(row) ? rows[row].task?.id : nil
    })
    // Where the selection sat, for the fallback below: when every selected
    // row leaves (complete, move, delete, a remote change), the selection
    // falls to the next task by id instead of to nothing.
    let lastSelectedIndex = tableView.selectedRowIndexes.last

    // Today and its triage band come from one fetch of the open rows; the
    // band feeds the suggestion snapshot, the tag bar and `triageBand(_:)`.
    let logbookDeletedCount = filter == .logbook ? LocalCache.recentlyDeletedCount(in: context) : 0
    let todayLists = filter == .today ? LocalCache.todayAndTriage(in: context) : nil
    let rawPool = todayLists?.today ?? LocalCache.tasks(in: context, filter: activeFilter)
    let rawTriage = todayLists?.triage ?? []
    // Progressive disclosure: discover ONLY tags actually present in this list;
    // when none exist, no tag filter bar appears (docs/TAGS_SPEC.md §3).
    let listTags: [TaskTag] = {
      guard !showingRecentlyDeleted else { return [] }
      var ids = Set<String>()
      for t in rawPool { for tid in t.tags { ids.insert(tid) } }
      for t in rawTriage { for tid in t.tags { ids.insert(tid) } }
      guard !ids.isEmpty else { return [] }
      return ids
        .compactMap { tagsByID[$0] }
        .sorted { lhs, rhs in
          let lp = lhs.position ?? Int.max
          let rp = rhs.position ?? Int.max
          if lp != rp { return lp < rp }
          let cmp = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
          if cmp != .orderedSame { return cmp == .orderedAscending }
          return lhs.id < rhs.id
        }
    }()
    if !activeTagFilterIDs.isEmpty {
      activeTagFilterIDs = activeTagFilterIDs.intersection(Set(listTags.map(\.id)))
    }
    let pool = activeTagFilterIDs.isEmpty
      ? rawPool
      : rawPool.filter { $0.isHeading || activeTagFilterIDs.isSubset(of: Set($0.tags)) }
    // Capsules first: `chipped()` reads the snapshot, so it has to be current
    // before any row is built. Includes the triage band, which `pool` omits on
    // Today — the band is exactly where most suggestions land.
    refreshFilingSuggestions(pool: pool + rawTriage)
    // One standard title row, on every page — computed once here rather than
    // duplicated into each branch below, followed by Logbook's Deleted toggle
    // bar (issue #202) and the progressive-disclosure tag filter bar.
    let showsLogbookSegmented = filter == .logbook && (logbookDeletedCount > 0 || logbookTab == .deleted)
    let showsLogbookBar = showsLogbookSegmented || (showingRecentlyDeleted && !rawPool.isEmpty)
    let logbookBarRows: [Row] = showsLogbookBar
      ? [.logbookBar(tab: logbookTab,
                     deletedCount: logbookDeletedCount,
                     showsSegmented: showsLogbookSegmented,
                     canEmptyTrash: showingRecentlyDeleted && !rawPool.isEmpty)]
      : []
    let tagBarRows: [Row] = listTags.isEmpty
      ? []
      : [.tagFilterBar(tags: listTags, active: Array(activeTagFilterIDs).sorted())]
    let titleRows: [Row] = (screenTitleRow().map { [$0] } ?? []) + logbookBarRows + tagBarRows
    var newRows: [Row]
    loggedClearIDs = []
    switch filter {
    case .today where todayGroupsByList:
      newRows = titleRows + noticeRows(pool) + agenda() + triageBand(rawTriage)
        + groupedByList(withoutTriage(pool))
        + todayLoggedRows()
    case .today:
      // Flat Today: due-first ordering, per the setting's documented contract
      // — but only for CLASSIFIED work. The Inbox run still leads the page:
      // the triage band, then the loose rows, exactly as `groupedByList`
      // orders them one case up. Sorting the loose rows in with the rest
      // scattered Inbox through the list.
      // SwiftUI's `ungroupedOpenItems` makes the same split — it renders only
      // tasks carrying a project or area, because Inbox is drawn above it.
      let rest = withoutTriage(pool)
      let loose = rest.filter(\.isUnfiled)
      // Flat still follows the SIDEBAR's order — area by area, each area's
      // projects after its direct work — so removing the headers changes what
      // you SEE, not the sequence you already know. `TaskListOrder.byList` is
      // the same ordering `groupedByList` emits its headers in.
      let structure = StructureCache.snapshot(in: context)
      let classified = TaskListOrder.byList(
        rest.filter { $0.project != nil || $0.area != nil },
        areas: structure.areas, projects: structure.projects)
      // One divider under the Inbox run, drawn as an ordinary group header so
      // it breaks the card exactly the way an area / project header does in
      // grouped mode — flat Today collapses the MANY list headers into this
      // single one, it doesn't drop the idea of a divider.
      let listsHeader: [Row] = classified.isEmpty ? [] : [
        .header(id: Self.flatListsHeaderId,
                title: String(localized: "Lists",
                              comment: "SeptaskKit: flat Today divider above tasks filed in an area or project"),
                icon: .symbol("list.bullet"), count: classified.count)
      ]
      newRows = titleRows + noticeRows(pool) + agenda() + triageBand(rawTriage)
        + loose.map(chipped)
        + listsHeader
        + classified.map(chipped)
        + todayLoggedRows()
    case .upcoming:
      newRows = titleRows + upcomingBuckets(pool)
    case .agent:
      newRows = titleRows + agentStageRows(pool)
    case .unscheduled, .starred:
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
      loggedClearIDs = completed.map(\.id)

      let open = pool.filter { $0.status == .open }
      let faded = showsFadedInLists ? LocalCache.fadedTasks(in: context, scope: filter) : []
      let notesRows = containerNotesRows()
      if case .project(let projectId) = filter {
        newRows = titleRows + notesRows + projectGrouped(open: open, projectId: projectId)
          + fadedFooterRows(faded: faded)
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
            let openCounts = SeptaskKitSidebarController.showsCounts ? LocalCache.projectOpenCounts(in: context) : [:]
            projectRows = [.header(id: "area-projects-\(areaID)",
                                   title: String(localized: "Projects",
                                                 comment: "SeptaskKit: area page section"),
                                   icon: .symbol("folder"),
                                   count: areaProjects.count)]
              + areaProjects.map {
                .projectTarget(id: $0.id,
                               title: $0.title,
                               progress: progress[$0.id] ?? 0,
                               count: openCounts[$0.id] ?? 0)
              }
          }
        }
        newRows = titleRows + notesRows + direct.map(unchipped)
          + projectRows
          + fadedFooterRows(faded: faded)
          + loggedFooterRows(completed: completed)
      }
    case .logbook:
      if logbookTab == .deleted {
        newRows = titleRows + pool.map(chipped)
      } else {
        // Already most-recent-first from LocalCache; cap what one screen needs.
        newRows = titleRows + pool.prefix(200).map(chipped)
      }
    case .faded:
      var fadedRows = titleRows
      if !pool.isEmpty {
        fadedRows.append(.notice(TaskNotices.fadedPile))
      }
      newRows = fadedRows + pool.map(chipped)
    default:
      newRows = titleRows + pool.map(chipped)
    }

    // Passive-sync cues — the AppKit half of `TaskListModel.merge`. A change
    // another device made should look like a touch, not a blink: a row
    // completed elsewhere gets the same check-then-linger beat a local ⌘K
    // does (and holds this reload back for the settle window, exactly as a
    // local completion does), and a row that landed on Today from elsewhere
    // gets the promote cue on top of the diff's slide-in. Only on an animated
    // diff against a populated list — a filter swap (`show`) and the first
    // paint rebuild cold, where "arrived" would mean the whole page.
    if animated, !priorTasks.isEmpty {
      let freshIDs = Set(newRows.compactMap { $0.task?.id })
      if ghostCheckRemoteCompletions(prior: priorTasks, freshIDs: freshIDs,
                                     excluding: locallyChanged) {
        return
      }
      let priorIDs = Set(priorTasks.map(\.id))
      queueTodayArrivalFlashes(newRows.compactMap { row in
        guard let task = row.task, !priorIDs.contains(task.id),
              !locallyChanged.contains(task.id) else { return nil }
        return task
      })
    }

    let priorRows = rows
    let live = liveEditorIDs
    var nextRows = pinned(newRows, liveEditors: live)
    let currentInboxIDs = visibleInboxIDs(in: nextRows)
    if filter == .today,
       let headerIndex = nextRows.firstIndex(where: {
         if case .header(let id, _, _, _) = $0 { return id == "inbox" }
         return false
       }) {
      let restingSymbol = currentInboxIDs.isEmpty
        ? InboxZeroMotion.emptyTraySymbol
        : InboxZeroMotion.filledTraySymbol
      nextRows[headerIndex] = .header(
        id: "inbox",
        title: TaskFilter.triage.title,
        icon: .symbol(restingSymbol),
        count: currentInboxIDs.count
      )
    }
    let inboxZeroOutcome = inboxZeroTracker.observe(
      isToday: filter == .today,
      inboxIDs: currentInboxIDs,
      tagFilterActive: !activeTagFilterIDs.isEmpty,
      isCollapsed: false,
      today: DayClock.appToday,
      settingEnabled: InboxZeroMotion.isEnabled(),
      reduceMotion: KitMotion.reduce
    )
    let preserveInboxHeader = inboxZeroOutcome.playVisualMotion
      || inboxZeroTracker.phase == .checkmark
    apply(nextRows, animated: animated, preserving: live, preserveInboxHeader: preserveInboxHeader)
    applyInboxZeroOutcome(inboxZeroOutcome, inboxCount: currentInboxIDs.count)
    let hasContent = rows.contains { row in
      switch row {
      case .screenTitle, .logbookBar: return false
      default: return true
      }
    }
    emptyStack.isHidden = hasContent
    refreshEmptyLabel()
    onStoreChanged?()

    if !selected.isEmpty {
      let indexes = IndexSet(rows.indices.filter {
        guard let id = rows[$0].task?.id else { return false }
        return selected.contains(id)
      })
      if !indexes.isEmpty {
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
      } else if let successor = successorTaskId(in: priorRows, after: lastSelectedIndex,
                                                excluding: selected),
                let row = rows.firstIndex(where: { $0.task?.id == successor }) {
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
      } else {
        tableView.deselectAll(nil)
      }
    }
  }

  /// Rows whose CELL holds live state a reload must not touch: the open
  /// composer and a live ⌘R / new-task field editor.
  private var liveEditorIDs: Set<String> {
    var ids: Set<String> = []
    if let composingTaskId { ids.insert(composingTaskId) }
    if isTitleEditorActive, let editingTaskId { ids.insert(editingTaskId) }
    return ids
  }

  /// Keep pinned rows on screen through a reload: the live editors, and the
  /// rows lingering in the settle window. A pinned row the fresh read still
  /// has keeps its ON-SCREEN value (the restyled-done copy, or the pre-edit
  /// copy under a live editor, whose cell must not be reconfigured); one the
  /// fresh read dropped is put back after the nearest surviving row that sat
  /// above it. The group headers above a pinned row are pinned with it: when
  /// the last open task of a project is completed, the fresh read drops the
  /// project header, and without its header the lingering row reads as part
  /// of the group above. Everything else takes the fresh read. The pins come
  /// off when their state ends — settle end, composer collapse and edit
  /// commit all reload, and then the rows go wherever the data says.
  private func pinned(_ fresh: [Row], liveEditors: Set<String>) -> [Row] {
    let pins = liveEditors.union(settlingIDs)
    guard !pins.isEmpty else { return fresh }
    var result = fresh
    let oldByKey = Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    for index in result.indices {
      guard let id = result[index].task?.id, pins.contains(id),
            let old = oldByKey[result[index].key] else { continue }
      result[index] = old
    }
    let pinnedHeaderKeys = headerKeys(above: pins)
    var present = Set(result.map(\.key))
    for (oldIndex, old) in rows.enumerated() {
      let isPinnedTask = old.task.map { pins.contains($0.id) } ?? false
      guard isPinnedTask || pinnedHeaderKeys.contains(old.key),
            !present.contains(old.key) else { continue }
      var insertAt = 0
      for above in stride(from: oldIndex - 1, through: 0, by: -1) {
        if let anchor = result.firstIndex(where: { $0.key == rows[above].key }) {
          insertAt = anchor + 1
          break
        }
      }
      result.insert(old, at: insertAt)
      present.insert(old.key)
    }
    return result
  }

  /// Keys of the on-screen group headers that own the given task rows: the
  /// nearest header above each row, plus any header stacked directly above
  /// that one (an area header over its first project header).
  private func headerKeys(above taskIDs: Set<String>) -> Set<String> {
    var keys: Set<String> = []
    for (index, row) in rows.enumerated() {
      guard let id = row.task?.id, taskIDs.contains(id) else { continue }
      var above = index - 1
      while above >= 0, case .task = rows[above] { above -= 1 }
      while above >= 0, case .header = rows[above] {
        keys.insert(rows[above].key)
        above -= 1
      }
    }
    return keys
  }

  /// The task that should take the selection once every selected row has
  /// left: the first surviving task BELOW the old selection, else the nearest
  /// one above. Task rows only (never a header, an event or the "New task"
  /// line), and never a section heading.
  private func successorTaskId(in prior: [Row], after index: Int?,
                               excluding gone: Set<String>) -> String? {
    guard let index, prior.indices.contains(index) else { return nil }
    let survivors = Set(rows.compactMap { row -> String? in
      guard let task = row.task, !task.isHeading else { return nil }
      return task.id
    })
    func candidate(_ row: Row) -> String? {
      guard let task = row.task, !task.isHeading, !gone.contains(task.id),
            survivors.contains(task.id) else { return nil }
      return task.id
    }
    for row in prior[(index + 1)...] {
      if let id = candidate(row) { return id }
    }
    for row in prior[..<index].reversed() {
      if let id = candidate(row) { return id }
    }
    return nil
  }

  /// Run a reload that `isApplyingMove` / `isDragActive` held back.
  private func flushHeldReload() {
    guard heldReload, !isApplyingMove, !isDragActive else { return }
    reload()
  }

  /// Gated on the setting AND on access already being granted — this shell
  /// never triggers the permission prompt itself; Settings ▸ Integrations
  /// owns that, same as `agenda()`/`upcomingBuckets()` below.
  private var showsCalendarEvents: Bool {
    let enabled = UserDefaults.standard.object(forKey: SettingsKey.tasksShowCalendarEvents) == nil
      ? RegistrySettings.Defaults.tasksShowCalendarEvents
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
      for event in CalendarBridge.shared.upcomingEvents(days: RegistryRules.upcomingCalendarDays) {
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
  // MARK: - Notices
  //
  // Which notices sit on top of Today, their order and their dismissal live
  // in `TaskNotices` (Septena/Shell/Tasks), shared with the SwiftUI list. This
  // shell only draws them (`KitNoticeCell`) and wires each one's action.

  /// Today's notices, from the shared `TaskNotices` (the SwiftUI list reads
  /// the same function). Sign-in state changes reload through
  /// `observeBootstrapState`.
  private func noticeRows(_ pool: [SeptenaTask]) -> [Row] {
    let sync = TaskSyncEngine.shared
    return TaskNotices.today(pool: pool, requiresSignIn: !sync.signedIn && sync.hadAccount,
                             today: SeptenaDate.today, context: context)
      .flatMap { [Row.notice($0)] + $0.steps.map(Row.noticeStep) }
  }

  // MARK: - Inline notices (one component: `KitNoticeCell`)

  private func noticeCell(_ notice: KitNotice) -> KitNoticeCell {
    let identifier = NSUserInterfaceItemIdentifier("noticeCell")
    let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? KitNoticeCell
      ?? KitNoticeCell(identifier: identifier)
    cell.configure(notice)
    return cell
  }

  /// Does a Get started step: opens the Settings page that sets it up, or
  /// opens Quick Entry for a first task.
  private func openNoticeStep(_ id: TaskNoticeStep.ID) {
    switch id {
    case .addTask:
      SeptaskKitQuickEntry.show()
    case .connectAI, .importTasks:
      let pageID = id == .connectAI
        ? RegistrySettings.PageID.claudePairing
        : RegistrySettings.PageID.importExport
      SeptaskSettingsLink.request(pageID)
      SeptaskKitSettingsWindow.show()
    }
  }

  private func dismissNotice(_ id: TaskNotice.ID) {
    TaskNotices.dismiss(id, today: SeptenaDate.today, context: context)
    reload()
  }

  /// ⌘K on selected notices: dismisses each one, the same as its close
  /// button. Selection moves to the row that takes the first notice's place.
  private func dismissSelectedNotices() {
    let notices = selectedDismissibleNotices
    guard !notices.isEmpty else { return }
    let anchor = tableView.selectedRowIndexes.first ?? 0
    for notice in notices {
      TaskNotices.dismiss(notice.id, today: SeptenaDate.today, context: context)
    }
    reload()
    let next = (anchor..<rows.count).first { self.tableView(self.tableView, shouldSelectRow: $0) }
    if let next {
      tableView.selectRowIndexes([next], byExtendingSelection: false)
      tableView.scrollRowToVisible(next)
    }
  }

  /// The bordered button of a notice, if it has one. The cell's button and
  /// Return on the selected notice both run this.
  private func noticePrimaryAction(_ id: TaskNotice.ID) -> (() -> Void)? {
    switch id {
    case .signIn: return { SeptaskAppKitSignIn.shared.start() }
    case .weeklySweep: return { [weak self] in self?.presentWeeklySweepSheet() }
    case .trialEnd, .secondDevice:
      guard let upsell = RegistryNotices.byId[id.registryID]?.upsellId else { return nil }
      return { [weak self] in self?.presentPlusSheet(upsellID: upsell) }
    default: return nil
    }
  }

  /// The Plus sheet for an upsell moment (spec §3.2, §7.1). Opening it from
  /// the notice marks the moment seen, so the notice leaves Today.
  private func presentPlusSheet(upsellID: String) {
    SeptaskPlusSheet.present(upsellID: upsellID, from: self)
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
  // MARK: - Passive-sync cues

  /// Ghost-check: rows that were open on screen, are gone from the fresh
  /// read, and are `.done` in the store were completed on ANOTHER device.
  /// Replay the local beat for them — checkbox pulse, restyled checked in
  /// place, then the settle window's own reload fades them out — instead of
  /// letting the diff yank them. Silent: no sound, no celebration, the same
  /// contract as SwiftUI's `ghostCheckRemoteCompletions`.
  ///
  /// Returns true when it took the reload over: the fresh rows are NOT
  /// applied, the settle-end reload picks them up (any arrivals in the same
  /// batch get their cue then). Lists that keep completed rows (Logbook,
  /// Recently Deleted) never ghost — there a remote completion is
  /// present-but-flipped, which the ordinary content diff repaints.
  ///
  /// `excluding` are this process's own ids: a local completion has already
  /// restyled and opened the window before its notification lands
  /// (`apply(completing:)`), and an undo/redo's `complete` is a deliberate
  /// gesture that takes the immediate path, not a phantom one.
  private func ghostCheckRemoteCompletions(prior: [SeptenaTask],
                                           freshIDs: Set<String>,
                                           excluding: Set<String>) -> Bool {
    switch filter {
    case .logbook, .faded, .recentlyDeleted: return false
    default: break
    }
    let vanished = Set(prior.compactMap { task in
      task.status == .open && !freshIDs.contains(task.id) && !excluding.contains(task.id)
        ? task.id : nil
    })
    guard !vanished.isEmpty else { return false }
    // Store read, not a fresh-list read: a completed row is absent from every
    // drop-done filter, so the list alone can't tell "done" from "deleted"
    // or "moved away" — only the first earns the beat.
    let ghosted = LocalCache.completedIDs(among: vanished, in: context)
    guard !ghosted.isEmpty else { return false }
    for (index, row) in rows.enumerated() where ghosted.contains(row.task?.id ?? "") {
      (tableView.view(atColumn: 0, row: index, makeIfNecessary: false)
        as? SeptaskKitTaskCell)?.playGhostCheckPulse()
    }
    settlingIDs.formUnion(ghosted)
    restyle(ids: Array(ghosted), to: .done)
    beginSettle()
    return true
  }

  /// Rows that just arrived from another device and landed on Today get the
  /// promote cue (gold ring + row wash) on top of the diff's slide-in — the
  /// AppKit half of `RemoteTaskSync.flashTodayPromotes`. Capped in list
  /// order so a batch sync pulses the first few, not the page. Played one
  /// turn later: the cue needs the row's CELL, which the insert batch only
  /// has once it has laid out.
  private func queueTodayArrivalFlashes(_ arrived: [SeptenaTask]) {
    let landed = arrived.filter(\.isOnToday).prefix(Self.arrivalFlashCap)
    guard !landed.isEmpty else { return }
    for task in landed { pendingPromoteFlash.insert(task.id) }
    DispatchQueue.main.async { [weak self] in
      self?.playPendingPromoteFlashes()
    }
  }

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
    noteInboxGesture(ids: ["reminder:\(id)"])
    importingReminderID = id
    reload()
    let created = mutator.create(title: pair.view.title,
                                 deadline: pair.view.dueDate,
                                 notes: pair.view.notes)
    try? RemindersBridge.shared.delete([pair.reminder])
    reminderPairs.removeAll { $0.view.id == id }
    importingReminderID = nil
    TaskNotices.completeStep(.importTasks)
    // Undoable like any other create. Redo re-creates (purge is a real
    // delete), and it deliberately does NOT put the reminder back in Apple
    // Reminders — that row is gone from EventKit and re-creating it there
    // would be a write to another app's data on the user's behalf.
    TaskUndo.recordCreate(
      name: String(localized: "Import Reminder", comment: "SeptaskKit: undo action"),
      ids: [created.id], mutator: mutator,
      rebuild: { [mutator] in
        [mutator.create(title: pair.view.title,
                        deadline: pair.view.dueDate,
                        notes: pair.view.notes).id]
      })
    reload()
  }

  private func importAllReminders() {
    guard !bulkImportingReminders, !reminderPairs.isEmpty else { return }
    noteInboxGesture(ids: reminderPairs.map { "reminder:\($0.view.id)" })
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
    TaskNotices.completeStep(.importTasks)
    TaskUndo.recordCreate(
      name: String(localized: "Import Reminders", comment: "SeptaskKit: undo action"),
      ids: createdIDs, mutator: mutator,
      rebuild: { [mutator] in
        pairs.map { pair in
          mutator.create(title: pair.view.title,
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
  private func triageBand(_ rawBand: [SeptenaTask]) -> [Row] {
    let band = activeTagFilterIDs.isEmpty
      ? rawBand
      : rawBand.filter { activeTagFilterIDs.isSubset(of: Set($0.tags)) }
    let reminders = reminderRows()
    // The count includes pending reminders — they ARE Inbox items now, and a
    // header that excluded them would be lying about what sits below it. The
    // bulk-import line is an action, not an item, so it doesn't count.
    let count = band.count + reminderPairs.count
    return [.header(id: "inbox",
                    title: TaskFilter.triage.title,
                    icon: .symbol(count > 0 ? InboxZeroMotion.filledTraySymbol : InboxZeroMotion.emptyTraySymbol),
                    count: count)]
      + reminders
      + band.map(chipped)
  }

  // MARK: - Inbox zero motion (docs/INBOX_ZERO_MOTION_SPEC.md, #298)

  /// Every visible Inbox row under `.header(id: "inbox")` on Today — pending
  /// Apple Reminders, triage-band rows, loose unfiled Today tasks, and any
  /// settling Inbox rows kept alive by `pinned(_:liveEditors:)`.
  private func visibleInboxIDs(in candidateRows: [Row]) -> Set<String> {
    guard filter == .today,
          let headerIndex = candidateRows.firstIndex(where: {
            if case .header(let id, _, _, _) = $0 { return id == "inbox" }
            return false
          })
    else { return [] }
    var ids: Set<String> = []
    for index in (headerIndex + 1)..<candidateRows.count {
      switch candidateRows[index] {
      case .reminder(let item, _):
        ids.insert("reminder:\(item.id)")
      case .importAllReminders, .newTask:
        continue
      case .task(let task, _, _):
        ids.insert(task.id)
      case .header, .loggedFooter, .fadedFooter, .addSection,
           .screenTitle, .logbookBar, .tagFilterBar, .projectTarget, .containerNotes,
           .notice, .noticeStep, .event, .notesProposal:
        return ids
      }
    }
    return ids
  }

  private func noteInboxGesture(ids: [String], clearedTodayArc: Bool = false) {
    guard filter == .today, !ids.isEmpty else { return }
    inboxZeroTracker.recordGesture(
      itemIDs: ids,
      currentInboxIDs: visibleInboxIDs(in: rows),
      clearedTodayArc: clearedTodayArc
    )
  }

  private func inboxHeaderCell() -> KitGroupHeaderCell? {
    guard let index = rows.firstIndex(where: {
      if case .header(let id, _, _, _) = $0 { return id == "inbox" }
      return false
    }) else { return nil }
    return tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? KitGroupHeaderCell
  }

  private func applyInboxZeroOutcome(_ outcome: InboxZeroMotionTracker.Outcome, inboxCount: Int) {
    if outcome.cancelInFlightMotion {
      inboxZeroHoldWorkItem?.cancel()
      inboxZeroHoldWorkItem = nil
      let symbol = inboxCount > 0 ? InboxZeroMotion.filledTraySymbol : InboxZeroMotion.emptyTraySymbol
      inboxHeaderCell()?.cancelInboxZeroMotion(symbolName: symbol)
      return
    }
    if outcome.announceVoiceOver {
      A11y.announce(InboxZeroMotion.announcementText)
    }
    // macOS has no haptic (spec §4).
    if outcome.playVisualMotion {
      inboxZeroHoldWorkItem?.cancel()
      inboxHeaderCell()?.playInboxZeroCheckmark()
      let work = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.inboxZeroHoldWorkItem = nil
        guard self.inboxZeroTracker.phase == .checkmark else { return }
        self.inboxZeroTracker.finishMotion()
        self.inboxHeaderCell()?.finishInboxZeroToEmptyTray()
      }
      inboxZeroHoldWorkItem = work
      DispatchQueue.main.asyncAfter(deadline: .now() + InboxZeroMotion.holdDuration, execute: work)
    }
  }

  private func cancelInboxZeroMotion() {
    inboxZeroHoldWorkItem?.cancel()
    inboxZeroHoldWorkItem = nil
    if inboxZeroTracker.cancelMotion() {
      let count = visibleInboxIDs(in: rows).count
      let symbol = count > 0 ? InboxZeroMotion.filledTraySymbol : InboxZeroMotion.emptyTraySymbol
      inboxHeaderCell()?.cancelInboxZeroMotion(symbolName: symbol)
    }
  }

  private func resetInboxZeroMotionForFilterChange() {
    inboxZeroHoldWorkItem?.cancel()
    inboxZeroHoldWorkItem = nil
    inboxZeroTracker.resetForFilterChange()
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
  /// context. Inline filing capsules live strictly on Inbox (never on Area or
  /// Project pages — those keep their suggestion inside the Move submenu).
  private func unchipped(_ task: SeptenaTask) -> Row {
    .task(task, chip: nil, suggestion: filingSuggestions[task.id])
  }

  private func chipped(_ task: SeptenaTask) -> Row {
    .task(task, chip: chip(for: task), suggestion: filingSuggestions[task.id])
  }

  /// Per-row top filing pick for the inline capsule, snapshotted each reload
  /// so the capsule paints on the same frame as the row. The GATE is
  /// `TaskFilingSuggestions.capsuleTop`, shared with the SwiftUI list — inline
  /// pills appear strictly on Inbox while `prime` keeps the model warm for the
  /// context menu's Move submenu on Area pages too.
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
      if let top = TaskFilingSuggestions.capsuleTop(for: task, filter: filter,
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
    guard let task = LocalCache.task(id: taskID, in: context)
    else { return }
    applyFilingSuggestions([(task, suggestion)])
  }

  /// ⌥⌘M — file every selected row into ITS OWN top pick, the keyboard twin of
  /// tapping each row's "→ Suggested" capsule. Rows the gate gave no pick are
  /// simply absent from `filingSuggestions`, so a mixed selection files what it
  /// can and leaves the rest alone — the shortcut is a no-op exactly when no
  /// capsule is on screen.
  func fileSuggestedSelection() {
    applyFilingSuggestions(actionableSelection.compactMap { task in
      filingSuggestions[task.id].map { (task, $0) }
    })
  }

  /// One batch, one undo entry, one reload. Filing row-by-row through repeated
  /// `applyFilingSuggestion` would push N entries onto the SHARED undo stack
  /// (⌘Z would then un-file the batch a row at a time) and reload between each,
  /// which invalidates the `filingSuggestions` snapshot mid-loop.
  private func applyFilingSuggestions(
    _ picks: [(task: SeptenaTask, suggestion: SuggestionEngine.Suggestion)]
  ) {
    guard !picks.isEmpty else { return }
    noteInboxGesture(ids: picks.map(\.task.id))
    let before = picks.map { TaskUndo.FilingSnapshot($0.task) }
    for (task, suggestion) in picks {
      let wasInTriage = task.isInTriageBand
      // Implicit "not this": the user accepted THIS pick, so there is nothing
      // to reject — rejection only fires when they file somewhere else.
      // Clearing stops the engine re-offering a pick that has been acted on.
      SuggestionEngine.shared.clearSuggestion(for: task.id)
      switch suggestion.kind {
      case .area: mutator.moveToArea(id: task.id, area: suggestion.id)
      case .project: mutator.moveToProject(id: task.id, project: suggestion.id)
      }
      // Filing is engagement — clears the agent cue so the row leaves the Inbox.
      mutator.acknowledge(id: task.id)
      if filter == .today, wasInTriage { pendingPromoteFlash.insert(task.id) }
    }
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

  /// Agent smart list (docs/TASK_FACTORY_SPEC.md §3): one header per
  /// non-empty `AgentStage`, in registry order, then that stage's tasks. The
  /// AppKit twin of `TaskListView.agentStageRows`.
  private func agentStageRows(_ pool: [SeptenaTask]) -> [Row] {
    // A claim lease is backend wall-clock time, not the app's day.
    let now = Date()
    let byStage = Dictionary(grouping: pool.filter { !$0.isHeading }) {
      $0.conversation.agentStage(at: now) ?? .queued
    }
    var result: [Row] = []
    for stage in AgentStage.allCases {
      guard let tasks = byStage[stage], !tasks.isEmpty else { continue }
      result.append(.header(id: "agent-\(stage.rawValue)",
                            title: stage.group?.title ?? stage.rawValue,
                            icon: .symbol(stage.group?.sfSymbol ?? "circle"),
                            count: tasks.count))
      result += tasks.map(chipped)
    }
    return result
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
      return .screenTitle(title: TaskFilter.today.title,
                          icon: .symbol("sun.max.fill"))
    case .triage:
      return .screenTitle(title: TaskFilter.triage.title,
                          icon: .symbol("tray"))
    case .review:
      return .screenTitle(title: TaskFilter.review.title,
                          icon: .symbol("eye"))
    case .agent:
      return .screenTitle(title: TaskFilter.agent.title,
                          icon: .symbol(Route.filter(.agent).icon))
    case .upcoming:
      return .screenTitle(title: TaskFilter.upcoming.title,
                          icon: .symbol("calendar"))
    case .repeating:
      return .screenTitle(title: TaskFilter.repeating.title,
                          icon: .symbol("arrow.clockwise"))
    case .unscheduled:
      return .screenTitle(title: TaskFilter.unscheduled.title,
                          icon: .symbol("rectangle.stack.fill"))
    case .starred:
      return .screenTitle(title: TaskFilter.starred.title,
                          icon: .symbol("star.fill"))
    case .logbook:
      return .screenTitle(title: TaskFilter.logbook.title,
                          icon: .symbol("checkmark"))
    case .faded:
      return .screenTitle(title: TaskFilter.faded.title,
                          icon: .symbol("circle.dashed"))
    case .recentlyDeleted:
      return .screenTitle(title: TaskFilter.recentlyDeleted.title,
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

  /// The notes row (plus any open proposal card directly above it) under a
  /// project's or area's title — always one click away (ADR 0012).
  private func containerNotesRows() -> [Row] {
    let snapshot = StructureCache.snapshot(in: context)
    switch filter {
    case .project(let id):
      guard let project = snapshot.projects.first(where: { $0.id == id }) else { return [] }
      let text = project.notes ?? ""
      var out: [Row] = []
      if let proposal = project.notesProposal {
        out.append(.notesProposal(isArea: false, id: id, currentNotes: text, proposal: proposal))
      }
      out.append(.containerNotes(isArea: false, id: id, text: text))
      return out
    case .area(let id):
      guard let area = snapshot.areas.first(where: { $0.id == id }) else { return [] }
      let text = area.context ?? ""
      var out: [Row] = []
      if let proposal = area.notesProposal {
        out.append(.notesProposal(isArea: true, id: id, currentNotes: text, proposal: proposal))
      }
      out.append(.containerNotes(isArea: true, id: id, text: text))
      return out
    default:
      return []
    }
  }

  /// Opens the notes editor anchored to the notes row; closing it saves
  /// through the same mutators the SwiftUI project and area pages use.
  private func editContainerNotes(isArea: Bool, id: String, text: String, anchor: NSView) {
    KitContainerNotesPopover.present(
      isArea: isArea,
      notes: text,
      relativeTo: anchor,
      onHistory: { [weak self] in
        self?.showContainerNotesHistory(isArea: isArea, id: id)
      }
    ) { [weak self] newText in
      let value: String? = newText.isEmpty ? nil : newText
      Task { @MainActor in
        do {
          if isArea {
            try await SeptenaServices.shared.areasMutator.setContext(id: id, context: value)
          } else {
            try await SeptenaServices.shared.projectsMutator.setNotes(id: id, notes: value)
          }
        } catch {
          SeptenaLog.error("[notes] save failed for \(isArea ? "area" : "project") \(id)", error)
        }
        self?.reload()
      }
    }
  }

  private func acceptContainerNotesProposal(isArea: Bool, id: String, currentNotes: String, proposal: NotesProposal) {
    let before: String? = currentNotes.isEmpty ? nil : currentNotes
    let merged = ContainerNotes.replacingBrief(in: before, with: proposal.body)
    let after: String? = merged.isEmpty ? nil : merged
    if isArea {
      TaskUndo.recordAreaProposalDecision(
        id: id, accepted: true, beforeNotes: before, afterNotes: after,
        proposal: proposal, areas: SeptenaServices.shared.areasMutator)
    } else {
      TaskUndo.recordProjectProposalDecision(
        id: id, accepted: true, beforeNotes: before, afterNotes: after,
        proposal: proposal, projects: SeptenaServices.shared.projectsMutator)
    }
    Task { @MainActor in
      do {
        if isArea {
          try await SeptenaServices.shared.areasMutator.acceptNotesProposal(id: id)
        } else {
          try await SeptenaServices.shared.projectsMutator.acceptNotesProposal(id: id)
        }
      } catch {
        SeptenaLog.error("[notes] accept proposal failed for \(isArea ? "area" : "project") \(id)", error)
      }
      self.reload()
    }
  }

  private func rejectContainerNotesProposal(isArea: Bool, id: String, currentNotes: String, proposal: NotesProposal) {
    let current: String? = currentNotes.isEmpty ? nil : currentNotes
    if isArea {
      TaskUndo.recordAreaProposalDecision(
        id: id, accepted: false, beforeNotes: current, afterNotes: current,
        proposal: proposal, areas: SeptenaServices.shared.areasMutator)
    } else {
      TaskUndo.recordProjectProposalDecision(
        id: id, accepted: false, beforeNotes: current, afterNotes: current,
        proposal: proposal, projects: SeptenaServices.shared.projectsMutator)
    }
    Task { @MainActor in
      do {
        if isArea {
          try await SeptenaServices.shared.areasMutator.rejectNotesProposal(id: id)
        } else {
          try await SeptenaServices.shared.projectsMutator.rejectNotesProposal(id: id)
        }
      } catch {
        SeptenaLog.error("[notes] reject proposal failed for \(isArea ? "area" : "project") \(id)", error)
      }
      self.reload()
    }
  }

  private func showContainerNotesHistory(isArea: Bool, id: String) {
    let snapshot = StructureCache.snapshot(in: context)
    let title: String
    let currentNotes: String
    if isArea {
      let area = snapshot.areas.first(where: { $0.id == id })
      title = area?.title ?? ""
      currentNotes = area?.context ?? ""
    } else {
      let project = snapshot.projects.first(where: { $0.id == id })
      title = project?.title ?? ""
      currentNotes = project?.notes ?? ""
    }
    KitNotesHistorySheet.present(
      container: isArea ? .area : .project,
      id: id,
      title: title,
      currentNotes: currentNotes,
      from: self
    ) { [weak self] restored in
      let before: String? = currentNotes.isEmpty ? nil : currentNotes
      let after: String? = restored.isEmpty ? nil : restored
      if isArea {
        TaskUndo.recordAreaNotesRestore(id: id, before: before, after: after,
                                        areas: SeptenaServices.shared.areasMutator)
      } else {
        TaskUndo.recordProjectNotesRestore(id: id, before: before, after: after,
                                           projects: SeptenaServices.shared.projectsMutator)
      }
      Task { @MainActor in
        do {
          if isArea {
            try await SeptenaServices.shared.areasMutator.setContext(id: id, context: after)
          } else {
            try await SeptenaServices.shared.projectsMutator.setNotes(id: id, notes: after)
          }
        } catch {
          SeptenaLog.error("[notes] restore failed for \(isArea ? "area" : "project") \(id)", error)
        }
        self?.reload()
      }
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
    guard let key = loggedScopeKey, !completed.isEmpty else { return [] }
    let expanded = loggedIsExpanded(key)
    var rows: [Row] = [.loggedFooter(count: completed.count, expanded: expanded)]
    if expanded {
      rows.append(contentsOf: completed.map(unchipped))
    }
    return rows
  }

  /// Today's entry in the shared expanded-set. Its MEMBERSHIP MEANS
  /// COLLAPSED, the inverse of a project/area id: Today's footer exists only
  /// while Settings ▸ Tasks ▸ Today ▸ Show completed tasks is on, and that
  /// setting promises the rows are shown, so they start open. The name says
  /// so, and can't collide with a project or area id in the same set.
  private static let todayLoggedCollapsedKey = "today-collapsed"

  /// The footer's key in the expanded-set: the project/area id, or Today's
  /// inverted key. Nil on every other page (no footer).
  private var loggedScopeKey: String? {
    if filter == .today { return Self.todayLoggedCollapsedKey }
    return scopeId
  }

  private func loggedIsExpanded(_ key: String) -> Bool {
    let member = loggedExpandedIds().contains(key)
    return key == Self.todayLoggedCollapsedKey ? !member : member
  }

  /// Mirrors SettingsKey.todayShowCompleted's contract: absent → on.
  private var todayShowsCompleted: Bool {
    UserDefaults.standard.object(forKey: SettingsKey.todayShowCompleted) == nil
      ? true
      : UserDefaults.standard.bool(forKey: SettingsKey.todayShowCompleted)
  }

  /// Today's logged block: what was finished (or cancelled) today, newest
  /// first — the same set the Septena Today drawer's "Done" section shows
  /// (`TasksDestinationView.reload`). Empty when the setting is off.
  private func todayLoggedRows() -> [Row] {
    guard todayShowsCompleted else { return [] }
    let today = SeptenaDate.today
    let done = LocalCache.tasksCompleted(onDay: today, in: context)
      .sorted { ($0.completedAt ?? "") > ($1.completedAt ?? "") }
    return loggedFooterRows(completed: done)
  }

  func toggleLoggedExpanded() {
    guard let scopeId = loggedScopeKey else { return }
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

  /// Mirrors SettingsKey.tasksShowFaded's contract: absent → on.
  private var showsFadedInLists: Bool {
    UserDefaults.standard.object(forKey: SettingsKey.tasksShowFaded) == nil
      ? RegistrySettings.Defaults.tasksShowFaded
      : UserDefaults.standard.bool(forKey: SettingsKey.tasksShowFaded)
  }

  private static let fadedCollapsedKey = "septena.tasks.projectFadedCollapsed"

  private func fadedCollapsedIds() -> Set<String> {
    guard let data = UserDefaults.standard.data(forKey: Self.fadedCollapsedKey) else { return [] }
    return (try? JSONDecoder().decode(Set<String>.self, from: data)) ?? []
  }

  /// Collapsible faded-tasks section for projects & areas. Starts expanded
  /// while Settings ▸ Lists ▸ Show faded tasks is on (mirrors Today's
  /// completed footer); clicking folds or unfolds per list.
  private func fadedFooterRows(faded: [SeptenaTask]) -> [Row] {
    guard let key = scopeId, !faded.isEmpty else { return [] }
    let expanded = !fadedCollapsedIds().contains(key)
    var rows: [Row] = [.fadedFooter(count: faded.count, expanded: expanded)]
    if expanded {
      rows.append(contentsOf: faded.map(unchipped))
    }
    return rows
  }

  func toggleFadedExpanded() {
    guard let key = scopeId else { return }
    var ids = fadedCollapsedIds()
    if ids.contains(key) { ids.remove(key) } else { ids.insert(key) }
    UserDefaults.standard.set((try? JSONEncoder().encode(ids)) ?? Data(),
                              forKey: Self.fadedCollapsedKey)
    reload(animated: false)
  }

  private func groupedByList(_ pool: [SeptenaTask]) -> [Row] {
    let snapshot = StructureCache.snapshot(in: context)
    let byProject = Dictionary(grouping: pool.filter { $0.project != nil },
                               by: { $0.project! })
    let byArea = Dictionary(grouping: pool.filter { $0.project == nil && $0.area != nil },
                            by: { $0.area! })
    let loose = pool.filter(\.isUnfiled)
    let progress = projectProgress()

    // Loose rows keep their chips: an agent proposal can name a project while
    // still sitting in the ungrouped band.
    var result: [Row] = loose.map(chipped)
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
    // Keep this aggregate at the entity layer: the AppKit list asks for it on
    // every grouped refresh, and allocating one DTO per live task here is
    // unnecessary work.
    LocalCache.projectCompletionRatios(in: context)
  }

  /// Animated structural diff: rows keep identity by `key`, so completes fade
  /// out where they sit, arrivals slide in, and everything else stays put.
  /// Falls back to a hard reload for filter switches / first population, and
  /// collapses to an instant swap under Reduce Motion.
  /// `preserving` are rows whose cell holds a live editor: they are never
  /// re-rendered here, and their presence forces the diff path even when a
  /// hard reload was asked for — `reloadData()` would tear the editor down
  /// mid-keystroke. Under Reduce Motion that diff runs without animation.
  private func apply(_ new: [Row], animated: Bool, preserving: Set<String> = [],
                     preserveInboxHeader: Bool = false) {
    let old = rows
    rows = new

    let diffable = !old.isEmpty && (animated && !KitMotion.reduce || !preserving.isEmpty || preserveInboxHeader)
    guard diffable else {
      tableView.reloadData()
      return
    }
    let moving = animated && !KitMotion.reduce
    let removeAnimation: NSTableView.AnimationOptions = moving ? KitMotion.removeRows : []
    let insertAnimation: NSTableView.AnimationOptions = moving ? KitMotion.insertRows : []
    func isPreserved(_ index: Int) -> Bool {
      if preserveInboxHeader, case .header(let id, _, _, _) = new[index], id == "inbox" {
        return true
      }
      guard let id = new[index].task?.id else { return false }
      return preserving.contains(id)
    }

    let oldKeys = old.map(\.key)
    let newKeys = new.map(\.key)
    if oldKeys == newKeys {
      var changed = IndexSet()
      for index in new.indices where new[index] != old[index] && !isPreserved(index) {
        changed.insert(index)
      }
      if !changed.isEmpty {
        // Heights are CACHED: `reloadData(forRowIndexes:)` re-renders a cell
        // but never re-asks `heightOfRow`, so a row that just gained (or lost)
        // its context subtitle would draw two lines in a one-line slot and
        // clip. Invalidate first, then re-render.
        tableView.noteHeightOfRows(withIndexesChanged: changed)
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
        tableView.removeRows(at: [offset], withAnimation: removeAnimation)
      case .insert(let offset, _, _):
        tableView.insertRows(at: [offset], withAnimation: insertAnimation)
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
    for index in new.indices where !isPreserved(index) {
      if let previous = oldByKey[new[index].key], previous != new[index] {
        changed.insert(index)
      }
    }
    if !changed.isEmpty {
      // Same cached-height rule as the equal-keys path above.
      tableView.noteHeightOfRows(withIndexesChanged: changed)
      tableView.reloadData(forRowIndexes: changed, columnIndexes: [0])
    }
  }

  /// Whether a row command has anything to act on — drives menu enablement.
  var hasActionableSelection: Bool { !actionableSelection.isEmpty }
  /// Exactly one task row is selected: the inspector has one subject.
  var hasSingleActionableSelection: Bool { actionableSelection.count == 1 }

  /// The selected Get started steps. They take Return (open), ⌘K (tick) and
  /// their own context menu; no task command sees them.
  private var selectedNoticeSteps: [TaskNoticeStep] {
    tableView.selectedRowIndexes.compactMap { row in
      rows.indices.contains(row) ? rows[row].noticeStep : nil
    }
  }

  /// The selected standalone notices that a ⌘K can dismiss.
  private var selectedDismissibleNotices: [TaskNotice] {
    tableView.selectedRowIndexes.compactMap { row in
      guard rows.indices.contains(row), let notice = rows[row].standaloneNotice,
            notice.dismissible else { return nil }
      return notice
    }
  }

  /// ⌘K and Task ▸ Complete have a target: a task, a Get started step, or a
  /// dismissible notice.
  var hasCompletableSelection: Bool {
    hasActionableSelection || !selectedNoticeSteps.isEmpty || !selectedDismissibleNotices.isEmpty
  }

  /// Copy the selection's titles — one per line. Reached through Edit ▸ Copy
  /// (the table implements `copy(_:)`, so the standard menu item finds it on
  /// the responder chain).
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
    // Re-create rather than un-purge on redo: a purge is a real delete, so
    // there is no row left to restore.
    let mutator = self.mutator
    recordCreateUndo(name: String(localized: "Paste Tasks", comment: "SeptaskKit: undo action"),
                     ids: created,
                     rebuild: {
                       titles.reversed().map { title in
                         mutator.create(title: title, area: context.area,
                                        project: context.project,
                                        scheduled: context.scheduled, today: context.today,
                                        atBottom: false).id
                       }
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
    let mutator = self.mutator
    let ids = originals.map { mutator.duplicate($0).id }
    reload()
    recordCreateUndo(name: String(localized: "Duplicate Task",
                                  comment: "SeptaskKit: undo action"),
                     ids: ids,
                     rebuild: { originals.map { mutator.duplicate($0).id } })
  }

  /// File the selection. `nil` area+project is the loose "Inbox" case.
  func move(to destination: KitMoveMenu.Destination) {
    move(to: destination, taskIDs: actionableSelection.map(\.id))
  }

  private func move(to destination: KitMoveMenu.Destination, taskIDs: [String]) {
    let liveByID = Dictionary(LocalCache.liveTasks(ids: taskIDs, in: context).map { ($0.id, $0) },
                              uniquingKeysWith: { current, _ in current })
    // A task already filed at `destination` is a no-op: no write and no undo
    // step (⌘Z must not "undo" nothing and skip the real action behind it).
    let selection = taskIDs.compactMap { liveByID[$0] }.filter { task in
      switch destination {
      case .none: return task.area != nil || task.project != nil
      case .area(let areaId): return task.project != nil || task.area != areaId
      case .project(let projectId): return task.project != projectId
      }
    }
    guard !selection.isEmpty else { return }
    switch destination {
    case .none:
      cancelInboxZeroMotion()
    case .area, .project:
      noteInboxGesture(ids: selection.map(\.id))
    }
    // Captured before mutating, so undo can restore each task's exact prior
    // filing, including a heading. A batch move can start from several
    // different lists at once.
    let previous = selection.map(TaskUndo.FilingSnapshot.init)

    func apply(_ destination: KitMoveMenu.Destination, id: String) {
      switch destination {
      case .none:
        mutator.moveToList(id: id, area: nil, project: nil)
      case .area(let areaId):
        mutator.moveToList(id: id, area: areaId, project: nil)
      case .project(let projectId):
        mutator.moveToList(id: id, area: nil, project: projectId)
      }
    }

    isApplyingMove = true
    for entry in previous {
      apply(destination, id: entry.id)
      mutator.acknowledge(id: entry.id)
    }
    isApplyingMove = false
    // An open composer's List pill names the new home right away.
    for entry in previous { refreshComposerRow(taskId: entry.id) }
    // Redo is re-read from the store (`recordMove`), so the undo closures
    // hold only the mutator and outlive this window.
    TaskUndo.recordMove(before: previous, context: context, mutator: mutator)
    // The toast's Undo reverses through the same stack entry (the ticket), so
    // it and ⌘Z can never both fire — the SwiftUI row menu's contract.
    let ticket = TaskUndoTicket()
    let structure = StructureCache.snapshot(in: context)
    let destinationName: String = switch destination {
    case .none: TaskFilter.triage.title
    case .area(let areaId): structure.areas.first { $0.id == areaId }?.title ?? TaskFilter.triage.title
    case .project(let projectId): structure.projects.first { $0.id == projectId }?.title ?? TaskFilter.triage.title
    }
    toastStore.show(RegistryToasts.moved(destination: destinationName)) { [weak self, mutator] in
      ticket.undo { TaskUndo.restore(previous, using: mutator) }
      self?.reload()
    }
    // Each mutator posts synchronously, but `isApplyingMove` held every
    // intermediate reload back, so this is ONE diff against the final rows:
    // the moved rows animate out instead of the page blinking. The
    // selection falls to the next task by id (see `reload`).
    reload()
    onStoreChanged?()
  }

  /// ⌘M / ⌘⇧M — the type-to-filter Move picker (`SeptaskKitMovePicker`), the
  /// AppKit counterpart of SwiftUI's `MovePickerSheet`. Built once, reused —
  /// it re-reads structure fresh on every `show`.
  private lazy var movePicker = SeptaskKitMovePicker { [weak self] destination in
    guard let self else { return }
    let taskIDs = self.pendingMoveIDs
    self.pendingMoveIDs = []
    self.move(to: destination, taskIDs: taskIDs)
  }

  /// Exact destination for the picker's checkmark — project if filed there,
  /// otherwise the area, otherwise Inbox.
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
    commitComposerTextIfOpen()
    let selection = actionableSelection
    guard !selection.isEmpty else { return }
    let single = selection.count == 1
    let title = single
      ? RegistryActions.title(.taskMove, .short)
      : String(localized: "Move \(selection.count) Tasks",
               comment: "SeptaskKit: Move picker title (plural)")
    let current = single ? currentMoveDestination(for: selection[0]) : nil
    pendingMoveIDs = selection.map(\.id)
    movePicker.show(current: current, title: title,
                    anchor: single ? (anchor ?? selectedRowAnchor ?? .window) : .window)
  }

  /// The focused row's rect, for a Tier 1 surface to anchor to.
  private var selectedRowAnchor: KitSurfaceAnchor? {
    guard tableView.selectedRow >= 0 else { return nil }
    return .rect(tableView.rect(ofRow: tableView.selectedRow), tableView)
  }

  /// Open the Reminder popover (⌥⌘R) for the current selection, anchored to
  /// the row or composer pill. Progressive disclosure — only sets/clears the
  /// reminder without altering the task's `scheduled` date.
  func presentReminderPopover(anchor: KitSurfaceAnchor? = nil) {
    commitComposerTextIfOpen()
    let selection = actionableSelection
    guard !selection.isEmpty else { NSSound.beep(); return }
    guard case .rect(let rect, let host)? = anchor ?? selectedRowAnchor else {
      NSSound.beep()
      return
    }
    let initial = selection.count == 1 ? selection[0].reminder : nil
    let anyHasReminder = selection.contains { $0.reminder != nil }
    SeptaskKitReminderPopover.present(
      initial: initial,
      anyHasReminder: anyHasReminder,
      relativeTo: rect,
      of: host
    ) { [weak self] reminder in
      guard let self else { return }
      let before = selection.map(self.scheduleSnapshot)
      for task in selection {
        self.mutator.setReminder(id: task.id, reminder: reminder)
        self.refreshComposerRow(taskId: task.id)
      }
      self.reload()
      self.recordScheduleUndo(name: String(localized: "Change Reminder",
                                           comment: "SeptaskKit: undo action"),
                              before: before)
      self.onStoreChanged?()
    }
  }

  /// Open the type-to-filter/assign/create Tag popover (`⇧⌘T`) for the current
  /// selection (single or multi-select), anchored to the row or composer pill.
  func presentTagPopover(anchor: KitSurfaceAnchor? = nil) {
    commitComposerTextIfOpen()
    let selection = actionableSelection
    guard !selection.isEmpty else { NSSound.beep(); return }
    guard case .rect(let rect, let host)? = anchor ?? selectedRowAnchor else {
      NSSound.beep()
      return
    }
    let ids = selection.map(\.id)
    SeptaskKitTagPopover.present(
      taskIDs: ids,
      relativeTo: rect,
      of: host
    ) { [weak self] in
      guard let self else { return }
      for id in ids { self.refreshComposerRow(taskId: id) }
      self.reload()
      self.onStoreChanged?()
    }
  }

  /// Add Reference for the selected row, anchored to it.
  func presentAddReference() {
    commitComposerTextIfOpen()
    guard TaskRefActions.canAdd, let task = actionableSelection.first,
          case .rect(let rect, let host)? = selectedRowAnchor else {
      NSSound.beep()
      return
    }
    SeptaskKitAddReferencePopover.present(taskID: task.id, relativeTo: rect, of: host)
  }

  private func toggleTagFilter(_ tagID: String) {
    if activeTagFilterIDs.contains(tagID) {
      activeTagFilterIDs.remove(tagID)
    } else {
      activeTagFilterIDs.insert(tagID)
    }
    reload(animated: true)
  }

  @discardableResult
  private func clearTagFilterIfActive() -> Bool {
    guard !activeTagFilterIDs.isEmpty else { return false }
    activeTagFilterIDs.removeAll()
    reload(animated: true)
    return true
  }

  /// ⌘V on a selected task row (when not editing text): attach file(s) or a
  /// clipboard image directly to the selected task (`docs/ATTACHMENTS_MAC_PARITY_SPEC.md` §3).
  private func pasteAttachmentToSelection() -> Bool {
    guard !isEditingText, let target = actionableSelection.first else { return false }
    guard KitAttachmentPasteHelper.attachFromPasteboard(to: target.id, presentErrorIn: view.window) else {
      return false
    }
    refreshComposerRow(taskId: target.id)
    reload()
    onStoreChanged?()
    return true
  }

  /// Open the Repeat editor for the current selection, anchored to the row it
  /// edits like When and Deadline. It is intentionally the only AppKit rule
  /// picker: no preset submenu can silently flatten a fixed schedule into an
  /// after-completion rule.
  func presentRecurrencePanel(anchor: KitSurfaceAnchor? = nil) {
    commitComposerTextIfOpen()
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
                       ? RegistryActions.title(.taskPauseResumeRepeat)
                       : RegistryActions.title(.taskPauseResumeRepeat, .active),
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

  /// ⌘↑ / ⌘↓ — move the selected task(s) one slot within their group, the
  /// keyboard twin of a drag reorder: same lists (`allowsReorder`), same
  /// group bounds as a drop (`groupBounds`), same write
  /// (`applyManualOrder`), same undo (`TaskUndo.recordReorder`). On Today
  /// it moves the Today order only (`orderLane`, #66). A
  /// selection that spans groups, or is already at the group's edge, beeps.
  /// Only manual order changes; the row never changes list this way.
  func moveSelectionOneSlot(up: Bool) {
    guard allowsReorder, composingTaskId == nil else { NSSound.beep(); return }
    let picked = tableView.selectedRowIndexes.filter { index in
      guard rows.indices.contains(index), let task = rows[index].task else { return false }
      return !task.isHeading && task.status == .open
    }
    guard let first = picked.first, let last = picked.last else { NSSound.beep(); return }
    let bounds = groupBounds(aroundGap: first)
    guard bounds.contains(first), bounds.contains(last) else { NSSound.beep(); return }
    let ids = picked.compactMap { rows[$0].task?.id }
    let chosen = Set(ids)
    let groupTasks = rows[bounds].compactMap { row -> SeptenaTask? in
      guard let task = row.task, !task.isHeading, task.status == .open else { return nil }
      return task
    }
    guard let firstPos = groupTasks.firstIndex(where: { chosen.contains($0.id) }),
          let lastPos = groupTasks.lastIndex(where: { chosen.contains($0.id) })
    else { NSSound.beep(); return }
    let sequence = groupTasks.filter { !chosen.contains($0.id) }
    let neighbor: SeptenaTask? = up
      ? groupTasks[..<firstPos].last
      : groupTasks[(lastPos + 1)...].first
    guard let neighbor,
          let neighborPos = sequence.firstIndex(where: { $0.id == neighbor.id })
    else { NSSound.beep(); return }
    let before = TaskUndo.reorderSnapshot(of: groupTasks.map(\.id), lane: orderLane, in: context)
    applyManualOrder(ids: ids, into: sequence, at: up ? neighborPos : neighborPos + 1)
    TaskUndo.recordReorder(before, context: context, mutator: mutator)
    reload()
    if let moved = rows.firstIndex(where: { $0.task.map { chosen.contains($0.id) } ?? false }) {
      tableView.scrollRowToVisible(moved)
    }
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
    // ⌘K on a focused checklist step ticks the step (composer or inspector).
    if KitChecklistView.toggleFocusedStep(in: tableView.window) { return }
    // ⌘K with the row open: save the typed text, close, complete (Things).
    if composingTaskId != nil {
      completeComposingTask()
      return
    }
    // Mark-complete has no meaning in the trash — checkbox tap and ⌘K both
    // route to restore there (see `toggle(id:)`).
    guard !showingRecentlyDeleted else {
      restoreTasks(actionableSelection.map(\.id))
      return
    }
    // Read the task selection BEFORE dismissing notices: a dismiss moves the
    // selection to the next row, and reading it after would complete a task
    // the user never selected.
    let selection = actionableSelection
    toggleSelectedNoticeSteps()
    dismissSelectedNotices()
    guard !selection.isEmpty else { return }
    apply(completing: selection.filter { $0.status == .open },
         reopening: selection.filter { $0.status != .open })
  }

  /// ⌘K on Get started steps: ticks them, or unticks them when every
  /// selected step is already done (the task rule for a mixed selection).
  private func toggleSelectedNoticeSteps() {
    let steps = selectedNoticeSteps
    guard !steps.isEmpty else { return }
    let reopen = steps.allSatisfy(\.done)
    for step in steps {
      if reopen { TaskNotices.reopenStep(step.id) } else { TaskNotices.completeStep(step.id) }
    }
    reload()
  }

  /// Cancel open tasks in the selection — same settle beat as complete
  /// (linger struck-through, then leave for the Logbook). Already-finished
  /// rows are left alone; trash has nothing to cancel.
  func cancelSelection() {
    guard !showingRecentlyDeleted else { return }
    let open = actionableSelection.filter { $0.status == .open }
    guard !open.isEmpty else { return }
    applyCancel(open)
  }

  private func toggle(id: String) {
    // In the trash, a checkbox tap means "bring this back" — mark-complete
    // has no meaning for an already-deleted row.
    guard !showingRecentlyDeleted else {
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
    let mutator = self.mutator
    recordUndo(name: String(localized: "Restore Task", comment: "SeptaskKit: undo action"),
              undo: { for id in ids { mutator.delete(id: id) } },
              redo: { for id in ids { mutator.restore(id: id) } })
    for id in ids { mutator.restore(id: id) }
    reload()
  }

  private func purgeTasks(_ ids: [String]) {
    // No undo: purge is a real SwiftData delete, not a tombstone — there is
    // no state left to restore from.
    for id in ids { mutator.purge(id: id) }
    reload()
  }

  private func emptyTrash() {
    let ids = LocalCache.tasks(in: context, filter: .recentlyDeleted).map(\.id)
    guard !ids.isEmpty else { return }
    KitPrompt.confirmDestructive(RegistryPrompts.emptyTrash(count: ids.count),
                                 in: view.window) { [weak self] in
      self?.purgeTasks(ids)
    }
  }

  private func selectLogbookTab(_ tab: LogbookTab) {
    guard tab != logbookTab else { return }
    commitOpenEdits()
    logbookTab = tab
    tableView.deselectAll(nil)
    reload(animated: false)
  }

  /// Complete/reopen a batch. Completed rows in drop-done lists get the
  /// settle beat — restyled checked in place, then removed after a beat by
  /// the diffed reload's fade. Views that keep completed rows (Logbook) and
  /// pure reopens refresh immediately.
  ///
  /// Restyling and the `settlingIDs` pin happen BEFORE any `mutator` call —
  /// `TaskMutator.complete`/`uncomplete` post `.septenaTasksChanged`
  /// SYNCHRONOUSLY (`commitAndPush` → `TaskChange.post`, on the calling
  /// thread, before the call returns). Any reload that runs from there keeps
  /// the pinned rows on screen (`pinned`) while the rest of the list
  /// updates, so the pin has to be in place by the time the first mutator
  /// call fires — set afterward, a reload could wipe the row before the
  /// linger ever started.
  private func apply(completing: [SeptenaTask], reopening: [SeptenaTask]) {
    if !completing.isEmpty || !reopening.isEmpty {
      let completingIds = completing.map(\.id)
      let reopeningIds = reopening.map(\.id)
      let mutator = self.mutator
      recordUndo(name: completingIds.isEmpty
                    ? String(localized: "Reopen Task", comment: "SeptaskKit: undo action")
                    : String(localized: "Complete Task", comment: "SeptaskKit: undo action"),
                undo: {
                  for id in completingIds { mutator.uncomplete(id: id) }
                  for id in reopeningIds { mutator.complete(id: id) }
                },
                redo: {
                  for id in completingIds { mutator.complete(id: id) }
                  for id in reopeningIds { mutator.uncomplete(id: id) }
                })
    }
    guard !completing.isEmpty else {
      if isSettling {
        // Un-checking a row that is still lingering. It's on screen, restyled
        // done but not yet dropped, so ⌘K (or a second checkbox tap) has to
        // read as "unchecked" right now — those seconds are exactly the window
        // in which the completion is meant to be reversible. `reload()` is
        // pinned while settling (that pin IS the linger), so
        // restyle in place and let the settle timer's own reload resolve the
        // list. Rows still lingering from the same batch keep their beat.
        settlingIDs.subtract(reopening.map(\.id))
        inboxZeroTracker.cancelGesture(itemIDs: reopening.map(\.id))
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
    settlingIDs.formUnion(completing.map(\.id))
    noteInboxGesture(ids: completing.map(\.id))
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
    TaskUndo.recordCancel(ids: ids, mutator: mutator)

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
    settlingIDs.formUnion(ids)
    noteInboxGesture(ids: ids)
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
    // A row under a live editor keeps its cell: re-rendering it would drop
    // the typed text and the caret. Its value still changes, and the
    // composer's own checkbox is refreshed by `refreshComposerRow`.
    let live = liveEditorIDs
    var restyled = IndexSet()
    for index in rows.indices {
      if case .task(var task, let chip, let suggestion) = rows[index],
         wanted.contains(task.id) {
        task.status = status
        rows[index] = .task(task, chip: chip, suggestion: suggestion)
        if !live.contains(task.id) { restyled.insert(index) }
      }
    }
    guard !restyled.isEmpty else { return }
    tableView.reloadData(forRowIndexes: restyled, columnIndexes: [0])
  }

  /// Hold the list still for the settle window, then let the completed rows
  /// fade out on the next diffed reload.
  ///
  /// The settling rows are PINNED meanwhile (reloads still run for the rest of
  /// the list): completing a
  /// task queues a CloudKit change, and the batch's `.septenaTasksChanged`
  /// would otherwise land mid-linger and yank the row out early — which is
  /// exactly the "row vanishes the instant you check it" feel this removes.
  private func beginSettle() {
    settleWorkItem?.cancel()
    isSettling = true
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.isSettling = false
      self.settlingIDs.removeAll()
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
    settlingIDs.removeAll()
  }

  // MARK: - Dates (⌘S When, ⌘⇧D Deadline, ⌘⇧. Clear)

  /// Anchor a date popover to the focused row (or to `anchor`: a composer
  /// pill or an inspector row) and apply the choice to the whole actionable
  /// selection. The ONE When / Deadline picker path (ADR 0029).
  func presentDatePopover(kind: SeptaskKitDatePopover.Kind, anchor: KitSurfaceAnchor? = nil) {
    commitComposerTextIfOpen()
    let selection = actionableSelection
    guard !selection.isEmpty, tableView.selectedRow >= 0 else { return }
    guard case .rect(let anchorRect, let anchorView)? = anchor ?? selectedRowAnchor else { return }

    let initial: Date? = switch kind {
    case .when: KitDayFormat.date(fromWire: selection.first?.scheduled)
    case .deadline: KitDayFormat.date(fromWire: selection.first?.deadline)
    }

    SeptaskKitDatePopover.present(
      kind: kind,
      initial: initial,
      initialStartTime: kind == .when && selection.count == 1 ? selection[0].startTime : nil,
      initialDurationMinutes: kind == .when && selection.count == 1 ? selection[0].durationMinutes : nil,
      relativeTo: anchorRect,
      of: anchorView,
      onTimeSlotChange: kind == .when ? { [weak self] start, duration in
        guard let self else { return }
        let liveSel = selection.map { LocalCache.task(id: $0.id, in: self.context) ?? $0 }
        let before = liveSel.map(self.scheduleSnapshot)
        for task in liveSel {
          self.mutator.apply(.setTimeSlot(startTime: start, durationMinutes: duration,
                                          timeZone: nil), to: task.id)
          self.refreshComposerRow(taskId: task.id)
        }
        self.reload()
        self.recordScheduleUndo(
          name: String(localized: "Change Time", comment: "SeptaskKit: undo action"),
          before: before)
        self.onStoreChanged?()
      } : nil,
      // Repeat lives in the When picker (docs/TASK_ROW_MENU_SPEC.md). The
      // title names the rule only when every selected row agrees on it.
      repeatTitle: kind == .when
        ? TaskRepeatLabel.title(Set(selection.map(\.recurrence)).count == 1 ? selection.first?.recurrence : nil)
        : nil,
      // The Repeat editor hangs off the same control as this picker. In the
      // inspector, where When folds open under its row, Repeat folds open
      // under the Repeat row instead (the iOS task page does the same).
      onRepeat: kind == .when ? { [weak self] in
        self?.presentRecurrencePanel(anchor: anchor?.inlineSibling(attribute: .repeat) ?? anchor)
      } : nil
    ) { [weak self] date, today in
      guard let self else { return }
      // Read the rows again from the store: a time-slot change in the same
      // popover can have moved them on since it opened.
      let liveSel = selection.map { LocalCache.task(id: $0.id, in: self.context) ?? $0 }
      self.noteInboxGesture(ids: liveSel.map(\.id))
      let before = liveSel.map(self.scheduleSnapshot)
      var deferredTo: Date?
      for task in liveSel {
        switch kind {
        case .when:
          // Field rules: `TaskDateActions` (spec §4 A1 / A2 / A5).
          if today {
            let target = KitDayFormat.todayDate()
            guard let mode = self.rescheduleMode(for: task, newDate: target) else { continue }
            self.mutator.apply(.putOnToday, to: task.id, mode: mode)
          } else if let date {
            guard let mode = self.rescheduleMode(for: task, newDate: date) else { continue }
            self.mutator.apply(.scheduleFor(date), to: task.id, mode: mode)
            deferredTo = date
          } else {
            self.mutator.apply(.clearWhenDate, to: task.id)
          }
        case .deadline:
          self.mutator.apply(.setDeadline(date), to: task.id)
        }
        self.refreshComposerRow(taskId: task.id)
      }
      self.reload()
      self.showDeferredToast(deferredTo)
      self.recordScheduleUndo(
        name: kind == .when
          ? String(localized: "Change When", comment: "SeptaskKit: undo action")
          : String(localized: "Change Deadline", comment: "SeptaskKit: undo action"),
        before: before)
      // The inspector shows the new date when it opened this picker.
      self.onStoreChanged?()
    }
  }

  // MARK: - One picker per attribute (ADR 0029)

  /// Open the picker for the action `actionId` (`RegistryActions.opensAttribute`)
  /// on the current selection. The row menu, the Task menu, the composer
  /// pills and the inspector rows all come here, so one attribute has one
  /// picker with the same options from every entry point. `anchor` is the
  /// control that asked; nil anchors to the selected row.
  func openPicker(action actionId: RegistryActionID, anchor: KitSurfaceAnchor? = nil) {
    switch actionId {
    case .taskWhen: presentDatePopover(kind: .when, anchor: anchor)
    case .taskDeadline: presentDatePopover(kind: .deadline, anchor: anchor)
    case .taskReminder: presentReminderPopover(anchor: anchor)
    case .taskRepeat: presentRecurrencePanel(anchor: anchor)
    case .taskMove: presentMoveMenu(anchor: anchor)
    case .taskTags: presentTagPopover(anchor: anchor)
    default: assertionFailure("no AppKit picker for \(actionId)")
    }
  }

  /// Open the picker for the task attribute `attributeId` (a composer pill or
  /// an inspector row). The registry names the action that owns the picker.
  func openPicker(attribute attributeId: RegistryTaskAttributeID, anchor: KitSurfaceAnchor?) {
    guard let actionId = RegistryActions.action(opening: attributeId) else {
      assertionFailure("attribute \(attributeId) has no picker")
      return
    }
    openPicker(action: actionId, anchor: anchor)
  }

  /// "Deferred to …" for a new date after today, as the SwiftUI row menu says
  /// it. No Undo button there either: ⌘Z takes it back.
  private func showDeferredToast(_ date: Date?) {
    guard let date, !Calendar.current.isDateInToday(date) else { return }
    toastStore.show(RegistryToasts.deferred(to: date))
  }

  /// Fixed-schedule repeats get the same two-way decision as the iOS shell.
  /// Returning nil means the user cancelled the move for that row.
  private func rescheduleMode(for task: SeptenaTask,
                              newDate: Date?) -> RecurrenceRescheduleMode? {
    guard let rule = task.recurrence, !rule.afterCompletion,
          SeptenaDate.format(newDate) != task.scheduled else {
      return .makeException
    }

    switch KitPrompt.choice(RegistryPrompts.prompt(.rescheduleFixedRepeat)) {
    case .exception: return .makeException
    case .updateRule: return .updateRule
    default: return nil
    }
  }

  /// ⌘⇧. — drop the When date, the deadline and the Today pin, leaving the
  /// task in Anytime. Matches the registry shortcut of `task.clearSchedule`.
  func clearScheduleSelection() {
    let before = actionableSelection.map(scheduleSnapshot)
    noteInboxGesture(ids: actionableSelection.map(\.id))
    for task in actionableSelection {
      mutator.apply(.clearWhen, to: task.id)
    }
    reload()
    recordScheduleUndo(name: String(localized: "Clear Dates",
                                    comment: "SeptaskKit: undo action"),
                       before: before)
  }

  func toggleTodaySelection() {
    // Typed text first: the reload below keeps an open composer's cell, but
    // the store must already hold what was typed.
    commitComposerTextIfOpen()
    let before = actionableSelection.map(scheduleSnapshot)
    noteInboxGesture(ids: actionableSelection.map(\.id))
    // Spec §4 A4: decided on `isOnToday` (pin OR arrived date), the same
    // test the menu label uses, never the raw pin.
    let joined = mutator.toggleToday(ids: actionableSelection.map(\.id))
    pendingPromoteFlash.formUnion(joined)
    for task in actionableSelection { refreshComposerRow(taskId: task.id) }
    reload()
    playPendingPromoteFlashes()
    recordScheduleUndo(name: RegistryActions.title(.taskToggleToday), before: before)
  }

  /// ⌥⌘S — star or unstar the current selection (if all are starred, unstar
  /// all; otherwise star all). Recorded on the shared `TaskUndo` stack.
  func toggleStarSelection() {
    commitComposerTextIfOpen()
    let selection = actionableSelection
    guard !selection.isEmpty else { NSSound.beep(); return }
    let nextStarred = !selection.allSatisfy(\.starred)
    let before = selection.map(scheduleSnapshot)
    for task in selection {
      mutator.setStarred(id: task.id, starred: nextStarred)
      refreshComposerRow(taskId: task.id)
    }
    reload()
    recordScheduleUndo(
      name: nextStarred
        ? RegistryActions.title(.taskToggleStar, .add)
        : RegistryActions.title(.taskToggleStar, .remove),
      before: before
    )
    onStoreChanged?()
  }

  /// ⇧⌘C — reveal the checklist on the selected/composing task, insert a step,
  /// and move focus into it (docs/CHECKLISTS_SPEC.md §4).
  func addChecklistItemToSelection() {
    if let composingTaskId,
       let row = rows.firstIndex(where: { $0.task?.id == composingTaskId }),
       let composer = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? KitComposerCell {
      composer.addChecklistItemAndFocus()
      return
    }
    guard let task = actionableSelection.first else { NSSound.beep(); return }
    beginComposing(id: task.id)
    DispatchQueue.main.async { [weak self] in
      guard let self,
            let row = self.rows.firstIndex(where: { $0.task?.id == task.id }),
            let composer = self.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? KitComposerCell
      else { return }
      composer.addChecklistItemAndFocus()
    }
  }

  func deleteSelection() {
    // A deleted row must not stay pinned open as a composer (`reload` keeps
    // the composing row on screen), so save and fold it first.
    commitOpenEdits()
    let victims = actionableSelection
    guard !victims.isEmpty else { return }
    let ids = victims.map(\.id)
    if showingRecentlyDeleted {
      // ⌘⌫ already means "delete" everywhere else; in the trash itself that
      // naturally reads as the final, permanent delete — which has no undo,
      // so it asks first.
      confirmPurge(count: ids.count) { [weak self] in self?.purgeTasks(ids) }
      return
    }
    TaskUndo.recordDelete(ids: ids, mutator: mutator)
    noteInboxGesture(ids: ids)
    let ticket = TaskUndoTicket()
    for id in ids { mutator.delete(id: id) }
    let message = victims.count == 1
      ? RegistryToasts.deletedSingle(title: victims[0].title)
      : RegistryToasts.deletedBulk(count: victims.count)
    toastStore.show(message) { [weak self, mutator] in
      ticket.undo { for id in ids { mutator.restore(id: id) } }
      self?.reload()
    }
    // Selection falls to the next task by id (see `reload`), never to a raw
    // index that can land on a header, an event or the "New task" line.
    reload()
  }

  /// Permanent delete is the one task command with no undo, so it confirms
  /// first — as a sheet on this window, Cancel the Return-safe default
  /// (`KitPrompt`'s sheet form).
  private func confirmPurge(count: Int, then purge: @escaping @MainActor () -> Void) {
    KitPrompt.confirmDestructive(RegistryPrompts.deletePermanently(count: count),
                                 in: view.window, onConfirm: purge)
  }

  private func commitRename(id: String, title: String) {
    if editingTaskId == id { clearEditingTitle() }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let wasNew = (id == pendingNewTaskId)
    // Only THIS row's marker. A ⌘N made while this rename was still live
    // owns the marker now, and wiping it would leave that row unpurgeable.
    if wasNew { pendingNewTaskId = nil }
    if wasNew, trimmed.isEmpty {
      // The ⌘N / New Section row was escaped/committed empty — it never really
      // existed for the user, so remove it entirely rather than soft-deleting.
      mutator.purge(id: id)
    } else if wasNew, let existing = LocalCache.task(id: id, in: context), existing.isHeading {
      // Brand-new project heading created via New Section (#209): update title
      // if edited and record creation undo (never rename-back-to-placeholder).
      var landed = true
      if trimmed != existing.title {
        landed = mutator.update(id: id, title: trimmed)
      }
      if landed, let projectId = existing.project {
        TaskUndo.recordHeadingCreate(id: id, title: trimmed, project: projectId,
                                     position: existing.position, mutator: mutator)
      } else if !landed {
        SeptenaLog.error(
          "[SeptaskKit] title for new heading id=\(id) did not land — no undo entry registered", nil)
      }
    } else if wasNew, let existing = LocalCache.task(id: id, in: context),
              let match = headingPrefixForNewTask(title: trimmed, task: existing) {
      // `# Heading` shortcut on a new task inside a project (#209).
      convertNewTaskDraftToHeading(draft: existing, title: match.title, projectId: match.projectId)
    } else if wasNew {
      // The row was born titleless, so undo here means "un-create", not
      // "rename back to empty" — which is what the rename branch below used
      // to register for a brand-new row.
      //
      // Register the undo only when the title actually landed. A rolled-back
      // write leaves a still-untitled row, and an "un-create" entry for it
      // would put a purge on the undo stack for a task the user never got.
      if mutator.update(id: id, title: trimmed) {
        recordNewTaskUndo(id: id)
      } else {
        SeptenaLog.error(
          "[SeptaskKit] title for new task id=\(id) did not land — no undo entry registered", nil)
      }
    } else if let task = LocalCache.task(id: id, in: context),
              !trimmed.isEmpty, trimmed != task.title {
      // Read the STORE for "before": `rows` can hold a pinned pre-edit copy.
      // Same rule for a plain rename: the undo entry describes a write that
      // happened, so it is registered after the write reports success. A
      // rolled-back rename otherwise left ⌘Z claiming it could restore a
      // title that was never replaced.
      let previousTitle = task.title
      guard mutator.update(id: id, title: trimmed) else {
        SeptenaLog.error("[SeptaskKit] rename of id=\(id) did not land — title unchanged", nil)
        reload()
        view.window?.makeFirstResponder(tableView)
        return
      }
      TaskUndo.recordRename(id: id, before: previousTitle, after: trimmed, mutator: mutator)
    }
    reload()
    // Take the keyboard back only when nothing else claimed it while this
    // commit waited a tick: a composer or field editor opened since (⌘N
    // during a live rename), or a click into the sidebar / inspector, keeps
    // its focus.
    let responder = view.window?.firstResponder
    let claimedElsewhere: Bool
    if responder is NSText {
      claimedElsewhere = true
    } else if let other = responder as? NSView {
      claimedElsewhere = !other.isDescendant(of: tableView)
    } else {
      claimedElsewhere = false
    }
    if !claimedElsewhere { view.window?.makeFirstResponder(tableView) }
  }

  // MARK: - Store health

  /// Tell the user a write was rolled back. The AppKit counterpart of the
  /// SwiftUI `.storeHealthAlert()` — same words, same once-per-failure
  /// contract, raised as a window sheet.
  ///
  /// `storeHealthSheetUp` guards against stacking: a run of failures (a wedged
  /// context fails every save the same way) would otherwise queue one sheet
  /// per write and make the app unusable. One sheet reports the condition; the
  /// running count lives in Settings.
  private func reportStoreHealthFailure() {
    guard !storeHealthSheetUp else { return }
    guard let window = view.window else { return }
    guard StoreHealthState.shared.unreportedFailure != nil else { return }
    storeHealthSheetUp = true
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = StoreHealthState.alertTitle
    alert.informativeText = StoreHealthState.alertMessage
    alert.addButton(withTitle: RegistryPrompts.errorConfirmTitle)
    alert.beginSheetModal(for: window) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.storeHealthSheetUp = false
        StoreHealthState.shared.acknowledge()
      }
    }
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
    // Save and close whatever is open FIRST, synchronously — a live ⌘R
    // rename included, whose own commit would otherwise land a tick later,
    // on top of the row this creates. Read the anchor afterwards: closing a
    // composer reselects its row.
    commitOpenEdits()

    guard let context = creationContext(inInbox: inInbox) else {
      NSSound.beep()
      return
    }
    // Things: a new task lands directly BELOW the selected one when it joins
    // that task's list. Captured before the create changes the selection.
    let anchor = inInbox ? nil : focusedTaskForCreate()

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
    let landsInInboxRun = inInbox || TaskInbox.isUnfiled(area: context.area, project: context.project)
    if landsInInboxRun {
      cancelInboxZeroMotion()
    }
    let task = mutator.create(title: "", area: context.area, project: context.project,
                              scheduled: context.scheduled, today: context.today,
                              deferPush: true,
                              atBottom: landsInInboxRun)
    if filter == .starred {
      mutator.setStarred(id: task.id, starred: true)
    }
    pendingNewTaskId = task.id
    if let anchor { place(newTaskId: task.id, below: anchor, context: context) }
    // Not gated by the settle window any more (it pins its rows instead of
    // skipping the reload), so ⌘N within a completion's linger still finds
    // the row it just made.
    reload(animated: false)
    guard let row = rows.firstIndex(where: { $0.task?.id == task.id }) else { return }
    tableView.selectRowIndexes([row], byExtendingSelection: false)
    tableView.scrollRowToVisible(row)
    // Every new task opens the full composer, the "New task" line included
    // (#205), so it can be given its When / Deadline / List / Repeat without a
    // second gesture, the same as SwiftUI's inline create. The bare field
    // editor is still one keystroke away as ⌘R.
    beginComposing(id: task.id)
  }

  /// Move a just-created task to sit directly below `anchor`, when it landed
  /// in the anchor's own list (same area / project; Upcoming excluded, where
  /// the new row's day need not be the anchor's). Elsewhere the default
  /// placement stands. On a project page the new row also joins the anchor's
  /// section. The slot is the midpoint to the anchor's next neighbour in the
  /// rendered group; if precision has run out there, the default placement
  /// stands rather than renumbering the whole list for one new row.
  ///
  /// Known cost: `reorder` pushes immediately, so this draft reaches CloudKit
  /// before its first title (the create itself defers its push). Fixing that
  /// needs a `position` on `TaskMutator.create`.
  private func place(newTaskId id: String, below anchor: SeptenaTask,
                     context filing: (area: String?, project: String?, today: Bool, scheduled: Date?)) {
    guard filter != .upcoming, allowsReorder, !anchor.isHeading,
          anchor.area == filing.area, anchor.project == filing.project,
          let anchorRow = rows.firstIndex(where: { $0.task?.id == anchor.id })
    else { return }
    var below: Double?
    for index in (anchorRow + 1)..<rows.count {
      if case .header = rows[index] { break }
      guard let next = rows[index].task else { continue }
      if next.isHeading { break }
      guard next.status == .open, next.area == anchor.area,
            next.project == anchor.project, next.heading == anchor.heading
      else { break }
      below = next.orderKey(in: orderLane)
      break
    }
    let above = anchor.orderKey(in: orderLane)
    guard let slot = TaskOrder.positions(count: 1, above: above, below: below).first,
          slot > above, below.map({ slot < $0 }) ?? true
    else { return }
    if case .project = filter, let heading = anchor.heading {
      mutator.setHeading(id: id, heading: heading)
    }
    mutator.reorder(id: id, toPosition: slot, in: orderLane)
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
    case .unscheduled, .starred:
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
    case .review, .agent, .repeating, .logbook, .faded, .recentlyDeleted: return nil
    }
    return (area, project, today, scheduled)
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
    // Retry by task ID, never by the captured index: a reload in between
    // (a sync batch, a settle ending) can put a different row at that index.
    guard let id = rows.indices.contains(row) ? rows[row].task?.id : nil else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self,
            let fresh = self.rows.firstIndex(where: { $0.task?.id == id }) else { return }
      if let cell = self.tableView.view(atColumn: 0, row: fresh, makeIfNecessary: true)
        as? SeptaskKitTaskCell {
        self.markEditingTitle(atRow: fresh)
        cell.beginEditing()
      }
    }
  }

  /// Flag the row as title-editing and repaint just that row view — NOT a
  /// `reloadData`, which would tear down the field editor we are about to
  /// attach (the same hazard `reload` avoids by preserving `liveEditorIDs`).
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
    guard !showingRecentlyDeleted else {
      restoreTasks(actionableSelection.map(\.id))
      return
    }
    let row = tableView.selectedRow
    // Return on the "New task" line creates, exactly as clicking it does.
    if rows.indices.contains(row), case .newTask = rows[row] {
      createTask(inInbox: true)
      return
    }
    // Return on a Get started step does the step.
    if rows.indices.contains(row), let step = rows[row].noticeStep {
      openNoticeStep(step.id)
      return
    }
    // Return on a notice does its button (Sweep, Sign In). A notice with no
    // button takes no Return.
    if rows.indices.contains(row), let notice = rows[row].standaloneNotice {
      noticePrimaryAction(notice.id)?()
      return
    }
    guard row >= 0, let task = rows[row].task else { return }
    // A section heading has no pills/notes to open a full composer for —
    // same as the SwiftUI project page, renaming it is a bare title edit.
    guard !task.isHeading else {
      beginEditingRow(row)
      return
    }
    // A Review row opens the task page (the inspector), same as iPhone. It
    // never expands inline: the review cell is not a task row.
    if filter == .review {
      onOpenInspector?()
      return
    }
    beginComposing(id: task.id)
  }

  /// ⌘↩ — commit and close the open row, wherever the caret happens to be
  /// (title, notes, or a focused pill). ONE meaning, matching the platform's
  /// ⌘↩ ("finish this": Mail's Send, a sheet's default action) and matching
  /// Escape, which already commits and folds.
  ///
  /// It deliberately does NOT descend into notes any more. Overloading it as
  /// "go one level deeper" from the title while it meant "exit entirely" from
  /// notes made it not its own inverse: two presses from the title landed on a
  /// closed row rather than back where you started, and — since Return in
  /// notes is prose, not a submit — there was no way back up to the title at
  /// all. Descending is `↓` on the title's last line or Tab, both of which
  /// read top-to-bottom instead of as a chord.
  func commitComposerEditing() {
    // ⌘↩ in a bare field editor (⌘R, the "New task" line) finishes it too.
    if composingTaskId == nil, isTitleEditorActive {
      commitFieldEditorNow()
      return
    }
    guard let id = composingTaskId else { return }
    // Deferred one tick for the same first-responder reentrancy reason as
    // `KitComposerCell.deferCommitAndCollapse` — the key event that asked is
    // still on the stack. Keyed to the row that asked, so a second ⌘↩ (or a
    // composer opened in between) can't fold a different row.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.composingTaskId == id else { return }
      self.collapseComposer(commit: true)
    }
  }

  /// Write the open composer's typed title / notes to the store WITHOUT
  /// closing it — before a command that acts on the composing row (⌘T, ⌘S,
  /// ⌘⇧D, ⌘M, Repeat) and may re-read it. Idempotent: the cell only reports
  /// text that differs from what it last committed.
  private func commitComposerTextIfOpen() {
    guard let id = composingTaskId else { return }
    composerCell(for: id)?.commit()
  }

  /// ⌘K or the composer's own checkbox with the row open: save the typed
  /// text, close the row, then complete it through the ordinary path (undo,
  /// settle beat) — Things' "complete from the open task".
  private func completeComposingTask() {
    guard let id = composingTaskId else { return }
    collapseComposer(commit: true, animated: false)
    guard rows.contains(where: { $0.task?.id == id }) else { return }
    toggle(id: id)
  }

  /// ⌥↩ — open the closed selected row straight into its notes (revealed,
  /// caret at the end). One modifier off Return, which opens the same composer
  /// into the title; ⌘↩ no longer does this, it only ever finishes.
  func beginComposingSelectedRowInNotes() {
    guard composingTaskId == nil else { return }
    guard !showingRecentlyDeleted else { return }
    let row = tableView.selectedRow
    guard row >= 0, let task = rows[row].task, !task.isHeading else { return }
    beginComposing(id: task.id, focusNotes: true)
  }

  /// The live composer cell for `id`, if it is on screen.
  private func composerCell(for id: String) -> KitComposerCell? {
    guard let row = rows.firstIndex(where: { $0.task?.id == id }) else { return nil }
    return tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? KitComposerCell
  }

  @objc private func beginEditFromDoubleClick() {
    guard tableView.clickedRow >= 0,
          rows[tableView.clickedRow].task != nil || rows[tableView.clickedRow].noticeStep != nil
    else { return }
    tableView.selectRowIndexes([tableView.clickedRow], byExtendingSelection: false)
    beginComposingSelectedRow()
  }

  // MARK: - Inline composer (title + elective pills + notes)

  /// `focusNotes` opens straight into the notes field (⌥↩) instead of the title.
  func beginComposing(id: String, focusNotes: Bool = false) {
    guard composingTaskId != id else { return }
    // Switching rows: fold the open one instantly so two height animations
    // don't fight; the newly opened row still expands.
    // Opening to peek must NOT acknowledge — cue == Inbox membership for
    // agent rows (same contract as SwiftUI `TaskComposer`). Disposition
    // paths (complete / when / move / today) ratify.
    if composingTaskId != nil { collapseComposer(commit: true, animated: false) }
    // Opening a faded task keeps it (`docs/TASK_FADE_SPEC.md` §4): clears
    // `fadedAt`, stamps `touchedAt`, and records undo.
    if let existing = LocalCache.task(id: id, in: context), existing.isFaded {
      let snap = TaskUndo.FadedSnapshot(existing)
      mutator.keepFaded(ids: [id])
      TaskUndo.recordKeepFaded(before: [snap], mutator: mutator)
    }
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
    // Measure at the row's REAL width before the height animation asks
    // `heightOfRow` — `wireComposer` ran inside `viewFor:`, before the table
    // gave the cell its frame, so a title that wraps was still an unknown.
    // Without this the row opens one line tall and jumps on the next pass.
    // Also flush the cell's initial layout with animations disabled BEFORE
    // `animateComposerHeight` starts: otherwise its first Auto Layout pass
    // runs inside the implicit-animation context and visibly shifts the title.
    if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
        as? KitComposerCell {
      composerRowHeight = cell.expandedHeight
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0
        ctx.allowsImplicitAnimation = false
        cell.layoutSubtreeIfNeeded()
      }
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
      if focusNotes { cell.focusNotes() } else { cell.focusTitle() }
    }
  }

  /// Fold the composing row back to a normal row. `commit` is false when the
  /// cell already committed itself (Return/Esc inside the title/notes field —
  /// see `KitComposerCell.control(_:doCommandBy:)`), true for every other path
  /// (switching to a different row, selecting elsewhere) so nothing typed is
  /// silently dropped.
  private func collapseComposer(commit: Bool, animated: Bool = true) {
    guard let taskId = composingTaskId else { return }
    // The live cell, fetched whether or not we are the one committing: its
    // field contents are what the USER typed, and the purge decision below
    // needs that independently of whether the write reached the store.
    let composerCell = rows.firstIndex(where: { $0.task?.id == taskId }).flatMap {
      tableView.view(atColumn: 0, row: $0, makeIfNecessary: false) as? KitComposerCell
    }
    let typedTitle = composerCell?.pendingTitle ?? ""
    if commit, let composerCell {
      // The mutator's notification coalesces onto the next run-loop turn
      // (`scheduleReload`), so the height animation below owns the visual
      // fold; the reload at its end lands whatever changed meanwhile.
      composerCell.commit()
    }
    // Resign before the height fold — a live field editor would keep edit
    // chrome attached through the shrink.
    view.window?.makeFirstResponder(tableView)
    composingTaskId = nil
    composerRowHeight = nil

    // ⌘N now opens the composer rather than the bare field editor, so the
    // abandoned-new-task rule has to live here too — a row created and closed
    // without ever being titled never existed for the user, so purge it
    // instead of folding an empty row back into the list. Same contract as
    // `commitRename`'s branch, and read AFTER `cell.commit()` so a title the
    // user did type has already landed on the model.
    if taskId == pendingNewTaskId {
      pendingNewTaskId = nil
      // `# Heading` shortcut inside a project (#209): convert the brand-new
      // task draft into a project heading on commit, purge the placeholder,
      // and record creation undo.
      if let existing = LocalCache.task(id: taskId, in: context),
         let match = headingPrefixForNewTask(title: typedTitle, task: existing) {
        convertNewTaskDraftToHeading(draft: existing, title: match.title, projectId: match.projectId)
        return
      }
      // Read the STORE, not `rows` — `SeptenaTask` is a struct, so the row
      // array still holds the pre-commit copy and a title the user just typed
      // would look empty here and get the row purged out from under them.
      let trimmedTyped = typedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
      var stored = LocalCache.task(id: taskId, in: context)?.title ?? ""
      // If `onCommit` deferred writing a `# ` title while in a project and the
      // user moved the draft out of the project before closing, persist it now.
      if !trimmedTyped.isEmpty,
         stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
         !mutator.lastWriteFailed(id: taskId),
         mutator.update(id: taskId, title: trimmedTyped) {
        stored = trimmedTyped
      }
      // Purge needs BOTH to be empty. The store alone is not enough evidence:
      // `cell.commit()` routes through `StoreHealth.save`, which ROLLS BACK a
      // failed write — so a title the user really did type can leave the store
      // reading empty, and purging on that destroyed their task outright (no
      // trash entry, nothing to restore). `typedTitle` is read straight off
      // the field, so it survives a rolled-back save and keeps the row alive.
      // A wrongly-kept blank row is one ⌘⌫ away; a wrongly-purged task is gone.
      let nothingTyped = trimmedTyped.isEmpty
      let nothingStored = stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      if nothingTyped, nothingStored, !mutator.lastWriteFailed(id: taskId) {
        mutator.purge(id: taskId)
        reload()
        return
      }
      if !nothingTyped, nothingStored {
        SeptenaLog.error(
          "[SeptaskKit] new task id=\(taskId) was typed but the store shows no title — keeping the row rather than purging it",
          nil)
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
    // Put the row and its neighbours in their CLOSED look before the shrink,
    // the mirror of `beginComposing`, which applies the open look before it
    // grows. Done at the end instead, the composing card style rode the whole
    // shrink and then everything snapped at once (glass backdrop restored,
    // selection wash back): the janky fold.
    refreshCardGeometry()
    foldingComposerIDs.insert(taskId)
    animateComposerHeight(ofRow: row, animated: animated, reveal: false) { [weak self] in
      guard let self else { return }
      self.foldingComposerIDs.remove(taskId)
      // By ID, not the index captured before the fold: a reload during the
      // animation can have moved the row.
      if let closed = self.rows.firstIndex(where: { $0.task?.id == taskId }),
         self.composingTaskId != taskId {
        self.tableView.reloadData(forRowIndexes: [closed], columnIndexes: [0])
        self.refreshCardGeometry()
        // Keep the just-closed task selected so Esc returns to the closed-row
        // keyboard surface (arrows / ⌘K / …) instead of an empty selection —
        // unless the user already selected something else meanwhile.
        let current = self.tableView.selectedRowIndexes
        if self.composingTaskId == nil, current.isEmpty || current == [closed] {
          self.tableView.selectRowIndexes([closed], byExtendingSelection: false)
        }
      }
      // The pin is off: anything that changed while the row was open (a sync
      // batch, a ⌘T that took it off this list) lands now.
      self.reload()
    }
  }

  /// Re-read one task from the store into `rows` without a full list rebuild —
  /// enough for the closed cell after a composer commit to show the new title.
  private func refreshTaskRowInPlace(id: String) {
    guard let index = rows.firstIndex(where: { $0.task?.id == id }),
          case .task(_, let chip, let suggestion) = rows[index],
          let fresh = LocalCache.task(id: id, in: context)
    else { return }
    rows[index] = .task(fresh, chip: chip, suggestion: suggestion)
  }

  /// Animate (or jump, under Reduce Motion) a row's height to whatever
  /// `heightOfRow` currently returns — used for composer open/close, the
  /// notes expand inside an already-open composer, and typing growth. With
  /// `reveal` (every path but collapse) the list then scrolls so the taller
  /// row — or the caret, if the row outgrows the viewport — stays in view.
  private func animateComposerHeight(ofRow row: Int, animated: Bool = true,
                                     reveal: Bool = true,
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
      if reveal { revealComposerRow(row) }
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
      DispatchQueue.main.async { [weak self] in
        if reveal { self?.revealComposerRow(row) }
        completion?()
      }
    })
  }

  /// Keep the open row in view after its height changed. A row that fits the
  /// viewport is shown whole — the expand pushed its notes/pills below the
  /// fold at a fixed window height, this pulls them back. A row taller than
  /// the viewport follows the caret instead: that's the line being typed,
  /// and showing the row's top would hide it. `scrollToVisible` respects the
  /// scroll view's content insets, like `scrollRowToVisible`.
  private func revealComposerRow(_ row: Int) {
    guard rows.indices.contains(row) else { return }
    let rowRect = tableView.rect(ofRow: row)
    if rowRect.height <= tableView.visibleRect.height {
      tableView.scrollToVisible(rowRect)
    } else if let caret = composerCaretRect() {
      tableView.scrollToVisible(caret.insetBy(dx: 0, dy: -SeptaskKitTheme.rowHeight))
    }
  }

  /// The insertion point of whichever composer text view holds the keyboard,
  /// in table coordinates; nil when no text view in the list is editing.
  private func composerCaretRect() -> NSRect? {
    guard let editor = view.window?.firstResponder as? NSTextView,
          editor.isDescendant(of: tableView), let window = editor.window else { return nil }
    let caret = editor.selectedRange()
    let onScreen = editor.firstRect(forCharacterRange: NSRange(location: caret.location, length: 0),
                                    actualRange: nil)
    guard onScreen.height > 0 else { return nil }
    return tableView.convert(window.convertFromScreen(onScreen), from: nil)
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
          let fresh = LocalCache.liveTasks(ids: [taskId], in: context).first,
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
  /// Flat Today's single "Lists" divider (see the `.today` branch of `reload`).
  static let flatListsHeaderId = "today-lists"

  private func headerStartsSection(_ id: String) -> Bool {
    // The flat divider stands where an area / project header would, so it
    // takes the same extra break above it — "Inbox"/"Agenda" are sub-groups
    // inside Today's own flow and deliberately don't.
    isNavigableHeaderId(id) || id.hasPrefix("day-") || id == Self.flatListsHeaderId
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
    composerRowHeight = cell.expandedHeight
    bindComposerActions(cell, task: task)
  }

  /// The pill/checkbox action closures, all closing over `task` by value —
  /// shared by the initial wire-up and every post-pill refresh, so a stale
  /// closure never lingers after the task actually changes underneath it.
  private func bindComposerActions(_ cell: KitComposerCell, task: SeptenaTask) {
    cell.onNotesVisibilityChanged = { [weak self, weak cell] in
      guard let self, let cell,
            let row = self.rows.firstIndex(where: { $0.task?.id == task.id }) else { return }
      self.composerRowHeight = cell.expandedHeight
      self.animateComposerHeight(ofRow: row)
    }
    cell.onContentHeightChanged = { [weak self, weak cell] in
      guard let self, let cell,
            let row = self.rows.firstIndex(where: { $0.task?.id == task.id }) else { return }
      let next = cell.expandedHeight
      guard self.composerRowHeight != next else { return }
      self.composerRowHeight = next
      // Typing growth (a title wrapping onto a new line, notes growing) should
      // track the caret immediately — no open/close easing.
      self.animateComposerHeight(ofRow: row, animated: false)
    }

    cell.onCommit = { [weak self] title, notes in
      guard let self,
            // Compare against the STORE, not the `task` this closure captured:
            // a pill, a sync batch or an earlier commit may have moved it on.
            let current = LocalCache.task(id: task.id, in: self.context) else { return }
      let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
      // A brand-new `# Heading` draft inside a project converts on collapse
      // (`collapseComposer`) — don't push the raw `# ...` string as a task first.
      if task.id == self.pendingNewTaskId,
         self.headingPrefixForNewTask(title: trimmed, task: current) != nil {
        return
      }
      let titleChanged = !trimmed.isEmpty && trimmed != current.title
      // Same normalization on both sides as the cell applies to what it
      // saves (trailing whitespace only), so an untouched row never rewrites
      // its notes — and never syncs a no-op.
      let storedNotes = KitComposerCell.normalizedNotes(current.notes)
      let notesChanged = KitComposerCell.normalizedNotes(notes) != storedNotes
      guard titleChanged || notesChanged else { return }
      // Title and notes are one logical edit. Send one save/notification; an
      // empty notes string is intentional because the backend uses it to clear
      // the optional notes field.
      self.mutator.update(id: task.id,
                          title: titleChanged ? trimmed : nil,
                          notes: notesChanged ? (notes ?? "") : nil)
      // A brand-new row's first save is its CREATION, recorded when it closes
      // (`collapseComposer` → `recordNewTaskUndo`); an edit to an existing row
      // is undoable as an edit.
      if task.id != self.pendingNewTaskId {
        TaskUndo.recordEdit(id: task.id,
                            beforeTitle: current.title,
                            afterTitle: titleChanged ? trimmed : current.title,
                            beforeNotes: current.notes,
                            afterNotes: notesChanged ? (notes ?? "") : current.notes,
                            mutator: self.mutator)
      }
    }
    // Keyed to this row: a deferred collapse that lands after a different row
    // opened must not fold that one.
    cell.onCollapse = { [weak self] in
      guard let self, self.composingTaskId == task.id else { return }
      self.collapseComposer(commit: true)
    }

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
        // Same path as ⌘K from the open row: save, close, then complete with
        // the ordinary undo and settle beat.
        self.completeComposingTask()

      case .toggleToday:
        // ⌘T's own path, so the pill gets the same undo and promote cue.
        self.toggleTodaySelection()

      // Every picker pill opens the picker the row menu opens for the same
      // attribute (`openPicker`, ADR 0029). It acts on the current selection,
      // which is this row: selecting it is how compose mode began.
      case .when(let anchor):
        self.openPicker(attribute: .when, anchor: .rect(anchor.bounds, anchor))
        self.refreshComposerRow(taskId: task.id)

      case .deadline(let anchor):
        self.openPicker(attribute: .deadline, anchor: .rect(anchor.bounds, anchor))
        self.refreshComposerRow(taskId: task.id)

      case .reminder(let anchor):
        self.openPicker(attribute: .reminder, anchor: .rect(anchor.bounds, anchor))
        self.refreshComposerRow(taskId: task.id)

      case .toggleStar:
        self.toggleStarSelection()

      case .tags(let anchor):
        self.openPicker(attribute: .tags, anchor: .rect(anchor.bounds, anchor))
        self.refreshComposerRow(taskId: task.id)

      case .list(let anchor):
        // Reuses the exact destination list ⌘M / ⌘⇧M pops up — one picker, not a
        // second to keep in sync — anchored to the pill the user clicked. It
        // acts on the current selection, which is this row (selecting it is
        // how compose mode began).
        self.openPicker(attribute: .list, anchor: .rect(anchor.bounds, anchor))
        self.refreshComposerRow(taskId: task.id)

      case .repeatRule(let anchor):
        self.openPicker(attribute: .repeat, anchor: .rect(anchor.bounds, anchor))
        self.refreshComposerRow(taskId: task.id)
      }
    }
  }

  // MARK: - Context menus (registry `task.row`, `task.recentlyDeleted`, `task.faded`)

  /// The row menu, rendered from the registry menu `task.row` — the same
  /// tree the SwiftUI shell's `TaskListRowContextMenu` renders, so items,
  /// order, titles and key equivalents match in both shells. Built fresh on
  /// every click, so titles and visibility follow the current selection.
  private func buildContextMenu() -> NSMenu {
    let selection = actionableSelection
    let single = selection.count == 1 ? selection.first : nil
    let plural: RegistryTitleVariant = selection.count > 1 ? .plural : .base
    return KitRegistryMenu.build(RegistryActions.menu(.taskRow), bind: { [weak self] id in
      guard let self else { return nil }
      switch id {
      case .taskEditDetails: return .init { self.beginEditSelectedRow() }
      // Open = the task page (ADR 0029): on the Mac that is the inspector
      // pane. A row double-click and Return stay the inline composer. The
      // inspector follows the selection, so an open pane needs no toggle.
      case .taskOpen:
        guard single != nil else { return nil }
        return .init { self.onOpenInspector?() }
      case .taskShare:
        guard !selection.isEmpty else { return nil }
        return .init { self.shareSelection() }
      case .taskAcceptReview:
        guard let single, single.conversation.needsHumanReview else { return nil }
        return .init { self.acceptReviewTask(id: single.id) }
      case .taskSendBackReview:
        guard let single, single.conversation.needsHumanReview else { return nil }
        return .init { self.presentSendBackForSelectedRow(taskID: single.id) }
      case .taskToggleInfo:
        let visible = UserDefaults.standard.bool(forKey: SettingsKey.septaskInspectorVisible)
        return .init(variant: visible ? .active : .base) { self.onToggleInspector?() }
      case .taskDuplicate: return .init(variant: plural) { self.duplicateSelection() }
      case .taskToggleComplete:
        // Several tasks only: one task completes from its checkbox
        // (docs/TASK_ROW_MENU_SPEC.md). ⌘K and the menu bar still do one.
        guard selection.count > 1 else { return nil }
        return .init { self.toggleCompleteSelection() }
      case .taskCancel: return .init(variant: plural) { self.cancelSelection() }
      case .taskDelete: return .init(variant: plural) { self.deleteSelection() }
      case .taskToggleToday:
        // On Today every row is already "on Today", so a Today action just
        // competes with Clear Schedule. Hide it; ⌘T still works via the key
        // binding on the table.
        guard self.filter != .today, !selection.isEmpty else { return nil }
        let remove = selection.allSatisfy(\.isOnToday)
        return .init(variant: remove ? .remove : .add) { self.toggleTodaySelection() }
      case .taskToggleStar:
        guard !selection.isEmpty else { return nil }
        let allStarred = selection.allSatisfy(\.starred)
        return .init(variant: allStarred ? .remove : .add) { self.toggleStarSelection() }
      case .taskAddReference:
        guard single != nil, TaskRefActions.canAdd else { return nil }
        return .init { self.presentAddReference() }
      case .taskTags, .taskWhen, .taskDeadline: return .init { self.openPicker(action: id) }
      case .taskReminder:
        guard single != nil else { return nil }
        return .init { self.openPicker(action: id) }
      case .taskClearSchedule:
        guard selection.contains(where: { $0.isOnToday || $0.scheduled != nil || $0.deadline != nil })
        else { return nil }
        return .init { self.clearScheduleSelection() }
      case .taskMove: return .init { self.openPicker(action: id) }
      case .taskRepeat:
        guard single != nil else { return nil }
        return .init { self.openPicker(action: id) }
      case .taskPauseResumeRepeat:
        guard !selection.isEmpty, selection.allSatisfy({ $0.recurrence != nil }) else { return nil }
        let paused = selection.allSatisfy(\.recurrencePaused)
        return .init(variant: paused ? .active : .base) { self.setRecurrencePaused(!paused) }
      case .taskCreateNextCopy:
        guard let single, single.recurrence != nil else { return nil }
        return .init { self.createNextCopySelection() }
      default:
        return nil
      }
    }, slot: { [weak self] id in
      guard let self else { return [] }
      switch id {
      case "moveDestinations": return self.moveDestinationNodes(selection: selection)
      case "sectionDestinations": return self.sectionDestinationNodes(selection: selection)
      case "filingSuggestion": return self.filingSuggestionNodes(selection: selection)
      default: return []
      }
    })
  }

  /// "File in <list>" — the row capsule's pick, first in the menu for an
  /// Inbox row. The Move submenu then leaves its Suggested entry out.
  private func filingSuggestionNodes(selection: [SeptenaTask]) -> [RegistryMenuNode] {
    guard selection.count == 1, let task = selection.first,
          let suggestion = filingSuggestions[task.id] else { return [] }
    return [RegistryMenuEntry.slot(
      id: "fileSuggested",
      title: String(localized: "File in \(suggestion.title)",
                    comment: "SeptaskKit: row menu, file an Inbox task in its suggested list"),
      sfSymbol: suggestion.kind == .project ? "number" : "folder") { [weak self] in
        self?.applyFilingSuggestion(taskID: task.id, suggestion: suggestion)
      }]
  }

  /// Share… (`task.share`): the system share picker, anchored to the row.
  private func shareSelection() {
    let text = TaskShareText.text(for: actionableSelection)
    guard !text.isEmpty, tableView.selectedRow >= 0 else { return }
    NSSharingServicePicker(items: [text])
      .show(relativeTo: tableView.rect(ofRow: tableView.selectedRow),
            of: tableView, preferredEdge: .maxY)
  }

  /// Send Back… from the row menu: the same path as the row's button — the
  /// inspector opens with the Send back field open and focused.
  private func presentSendBackForSelectedRow(taskID: String) {
    openSendBack(taskID: taskID)
  }

  /// The trash's own vocabulary (registry `task.recentlyDeleted`) — nothing
  /// else on the normal menu means anything for an already-deleted row.
  private func buildRecentlyDeletedMenu() -> NSMenu {
    KitRegistryMenu.build(RegistryActions.menu(.taskRecentlyDeleted)) { [weak self] id in
      guard let self else { return nil }
      switch id {
      case .taskRestore: return .init { self.restoreTasks(self.actionableSelection.map(\.id)) }
      case .taskDeletePermanently: return .init { self.deleteSelection() }
      default: return nil
      }
    }
  }

  /// The Faded pile's menu (registry `task.faded`).
  private func buildFadedMenu() -> NSMenu {
    let plural: RegistryTitleVariant = actionableSelection.count > 1 ? .plural : .base
    return KitRegistryMenu.build(RegistryActions.menu(.taskFaded)) { [weak self] id in
      guard let self else { return nil }
      switch id {
      case .taskKeepFaded: return .init { self.menuKeepFaded() }
      case .taskLetGoFaded: return .init { self.menuDropFaded() }
      case .taskDelete: return .init(variant: plural) { self.deleteSelection() }
      default: return nil
      }
    }
  }

  /// The Move submenu's destinations — the same set the SwiftUI menu shows:
  /// the filing suggestion first, then Inbox (unless every row is already in
  /// it), every area and every top-level project.
  private func moveDestinationNodes(selection: [SeptenaTask]) -> [RegistryMenuNode] {
    let snapshot = StructureCache.snapshot(in: context)
    var nodes: [RegistryMenuNode] = []
    if let suggested = suggestedMoveNode(selection: selection, projects: snapshot.projects) {
      nodes.append(suggested)
      nodes.append(.divider(id: "suggested.divider"))
    }
    if !selection.allSatisfy(\.isInTriageBand) {
      nodes.append(RegistryMenuEntry.slot(
        id: "inbox", title: TaskFilter.triage.title,
        sfSymbol: RegistryIcons.sfSymbol(for: "list.inbox")) { [weak self] in
          self?.move(to: .none)
        })
    }
    let topLevel = snapshot.projects.filter { $0.area == nil && $0.status == .active }
    if !snapshot.areas.isEmpty || !topLevel.isEmpty {
      nodes.append(.divider(id: "destinations.divider"))
      for area in snapshot.areas {
        let title = (area.emoji?.isEmpty == false) ? "\(area.emoji ?? "")  \(area.title)" : area.title
        nodes.append(RegistryMenuEntry.slot(id: "area.\(area.id)", title: title) { [weak self] in
          self?.move(to: .area(area.id))
        })
      }
      for project in topLevel {
        nodes.append(RegistryMenuEntry.slot(
          id: "project.\(project.id)", title: project.title,
          sfSymbol: RegistryIcons.sfSymbol(for: "place.project")) { [weak self] in
            self?.move(to: .project(project.id))
          })
      }
    }
    return nodes
  }

  /// "Suggested: <List>" — the same pick the row's "→ Suggested" capsule
  /// shows, so the menu and the capsule never name different lists. Single
  /// selection only: a pick is ranked for one title.
  private func suggestedMoveNode(selection: [SeptenaTask], projects: [Project]) -> RegistryMenuNode? {
    guard selection.count == 1, let task = selection.first else { return nil }
    // An Inbox row's pick leads the whole menu ("File in …"), so the Move
    // submenu doesn't repeat it.
    guard filingSuggestions[task.id] == nil else { return nil }
    // The same GATE live (`TaskFilingSuggestions.top`), so Area pages still
    // offer a suggested child project inside the Move submenu without a row
    // capsule.
    guard let suggestion = TaskFilingSuggestions.top(
        for: task, filter: filter, engine: SuggestionEngine.shared,
        childProjectIds: Self.childProjectIds(in: projects))
    else { return nil }
    return RegistryMenuEntry.slot(
      id: "suggested",
      title: String(localized: "Suggested: \(suggestion.title)",
                    comment: "SeptaskKit: Move submenu, the filing suggestion"),
      sfSymbol: suggestion.kind == .project ? "number" : "folder") { [weak self] in
        self?.applyFilingSuggestion(taskID: task.id, suggestion: suggestion)
      }
  }

  /// Area → its active child projects, the shape `TaskFilingSuggestions` asks
  /// for. One builder, so the capsule and the menu rank an area-direct row
  /// against the same set of destinations.
  private static func childProjectIds(in projects: [Project]) -> (String) -> Set<String> {
    { areaId in
      Set(projects.filter { $0.area == areaId && $0.status == .active }.map(\.id))
    }
  }

  /// Move to Section ▸ — No Section, then every heading of the project page.
  private func sectionDestinationNodes(selection: [SeptenaTask]) -> [RegistryMenuNode] {
    guard case .project = filter, !selection.isEmpty else { return [] }
    let headings = rows.compactMap(\.task).filter(\.isHeading)
    guard !headings.isEmpty else { return [] }
    let ids = selection.map(\.id)
    var nodes: [RegistryMenuNode] = [
      RegistryMenuEntry.slot(id: "section.none", title: String(localized: "No Section")) { [weak self] in
        self?.fileIntoHeading(ids, heading: nil)
      },
      .divider(id: "sections.divider"),
    ]
    for heading in headings {
      nodes.append(RegistryMenuEntry.slot(id: "section.\(heading.id)", title: heading.title) { [weak self] in
        self?.fileIntoHeading(ids, heading: heading.id)
      })
    }
    return nodes
  }

  /// File `ids` under `heading` (nil = the un-headed block) at the foot of
  /// that group — the same rule as the SwiftUI project page.
  private func fileIntoHeading(_ ids: [String], heading: String?) {
    let members = rows.compactMap(\.task)
      .filter { !$0.isHeading && $0.heading == heading && !ids.contains($0.id) }
    let slots = TaskOrder.positions(count: ids.count,
                                    above: members.last?.orderKey(in: orderLane), below: nil)
    for (id, position) in zip(ids, slots) {
      mutator.setHeading(id: id, heading: heading)
      mutator.reorder(id: id, toPosition: position, in: orderLane)
    }
    reload()
  }

  @objc private func menuKeepFaded() {
    let selected = actionableSelection.filter(\.isFaded)
    guard !selected.isEmpty else { return }
    let snapshots = selected.map(TaskUndo.FadedSnapshot.init)
    mutator.keepFaded(ids: selected.map(\.id))
    TaskUndo.recordKeepFaded(before: snapshots, mutator: mutator)
    reload()
  }

  @objc private func menuDropFaded() {
    let selected = actionableSelection.filter(\.isFaded)
    guard !selected.isEmpty else { return }
    let snapshots = selected.map(TaskUndo.FadedSnapshot.init)
    mutator.dropFaded(ids: selected.map(\.id))
    TaskUndo.recordSweepDrop(before: snapshots, mutator: mutator)
    reload()
  }

  private func presentWeeklySweepSheet() {
    let tasks: [SeptenaTask] = filter == .faded
      ? LocalCache.tasks(in: context, filter: .faded)
      : TaskNotices.sweepCandidates(context: context)
    guard !tasks.isEmpty else { return }
    let structure = StructureCache.snapshot(in: context)
    var host: NSHostingController<AnyView>?
    let sheet = TaskFadeSweepSheet(
      tasks: tasks,
      areas: structure.areas,
      projects: structure.projects,
      onClose: { [weak self] in
        if let host { self?.dismiss(host) }
        self?.reload()
      }
    )
    .environment(mutator)
    let controller = NSHostingController(rootView: AnyView(sheet))
    host = controller
    presentAsSheet(controller)
  }

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
  /// Section" lives when there's no heading row to right-click yet
  /// (registry `project.blankSpace`).
  private func buildBlankSpaceMenu() -> NSMenu {
    KitRegistryMenu.build(RegistryActions.menu(.projectBlankSpace)) { [weak self] id in
      guard let self, id == .sectionNew, case .project = self.filter else { return nil }
      return .init { self.menuNewSection() }
    }
  }

  /// The page title's own navigation dropdown — the AppKit counterpart of
  /// `TaskNavMenu`: every sidebar destination in the SAME order (smart
  /// lists, top-level projects, each area + its projects), a checkmark on
  /// whichever one is current, jump on click.
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

    for destination in KitSidebarDestination.smartLists(in: .top, context: context) {
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

    let bottomSmartLists = KitSidebarDestination.smartLists(in: .bottom, context: context)
    if !bottomSmartLists.isEmpty {
      menu.addItem(.separator())
      for destination in bottomSmartLists { menu.addItem(destItem(destination)) }
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

  /// Right-click on a heading row (registry `project.heading`): rename (same
  /// field-editor path as any task), a new task in the section, and delete —
  /// nothing else on the normal task menu applies to a section divider.
  private func buildHeadingContextMenu() -> NSMenu {
    KitRegistryMenu.build(RegistryActions.menu(.projectHeading)) { [weak self] id in
      guard let self else { return nil }
      switch id {
      case .sectionRename: return .init { self.beginEditSelectedRow() }
      case .sectionNewTask: return .init { self.createTaskUnderSelectedHeading() }
      case .sectionDelete: return .init { self.menuDeleteHeading() }
      default: return nil
      }
    }
  }

  /// Right-click on a Get started step (registry `notice.getStartedStep`):
  /// the same things the keyboard does (Return, ⌘K) plus hiding the
  /// checklist. Nothing from the task menu applies to a step.
  private func buildNoticeStepMenu() -> NSMenu {
    let steps = selectedNoticeSteps
    let allDone = !steps.isEmpty && steps.allSatisfy(\.done)
    return KitRegistryMenu.build(RegistryActions.menu(.noticeGetStartedStep)) { [weak self] id in
      guard let self else { return nil }
      switch id {
      case .noticeOpenStep:
        return .init(perform: steps.isEmpty ? nil : { self.menuOpenNoticeStep() })
      case .noticeToggleStep:
        return .init(variant: allDone ? .active : .base,
                     perform: steps.isEmpty ? nil : { self.toggleSelectedNoticeSteps() })
      case .noticeHideGetStarted: return .init { self.dismissNotice(.getStarted) }
      default: return nil
      }
    }
  }

  /// New Task in Section: a titleless row filed under the selected heading,
  /// open for typing — the same as the SwiftUI page's heading menu.
  private func createTaskUnderSelectedHeading() {
    let row = tableView.selectedRow
    guard rows.indices.contains(row), let heading = rows[row].task, heading.isHeading,
          case .project(let projectId) = filter else { return }
    commitOpenEdits()
    let task = mutator.create(title: "", area: nil, project: projectId,
                              scheduled: nil, today: false, deferPush: true, atBottom: true)
    mutator.setHeading(id: task.id, heading: heading.id)
    pendingNewTaskId = task.id
    reload(animated: false)
    guard let newRow = rows.firstIndex(where: { $0.task?.id == task.id }) else { return }
    tableView.selectRowIndexes([newRow], byExtendingSelection: false)
    tableView.scrollRowToVisible(newRow)
    beginEditingRow(newRow)
  }

  private func menuOpenNoticeStep() {
    guard let step = selectedNoticeSteps.first else { return }
    openNoticeStep(step.id)
  }

  /// True when the list is showing a project (the only surface where headings live).
  var isViewingProject: Bool {
    if case .project = filter { return true }
    return false
  }

  /// Create a new heading in the current project and focus its title for typing.
  func createSection() {
    menuNewSection()
  }

  /// Project header `…` overflow menu: New Section + New Task, built from
  /// canonical registry titles so the Mac project header mirrors iOS's `…`.
  private func buildProjectOverflowMenu() -> NSMenu {
    KitRegistryMenu.build([
      RegistryMenuEntry.slot(
        id: "project.newSection",
        title: RegistryActions.title(.sectionNew),
        sfSymbol: "rectangle.split.1x2"
      ) { [weak self] in self?.menuNewSection() },
      RegistryMenuEntry.slot(
        id: "project.newTask",
        title: RegistryActions.title(.appNewTask),
        sfSymbol: "checkmark.circle"
      ) { [weak self] in self?.createTask() },
    ])
  }

  /// Non-nil when a brand-new task draft inside a project starts with `# `
  /// and should convert into a project heading on commit (#209). Never fires
  /// outside projects, never on edits, and never on `## ` or bare `# `.
  private func headingPrefixForNewTask(
    title: String,
    task: SeptenaTask
  ) -> (title: String, projectId: String)? {
    guard case .project(let projectId) = filter,
          !task.isHeading,
          task.project == projectId,
          let headingTitle = TaskTitleText.headingPrefixTitle(title)
    else { return nil }
    return (headingTitle, projectId)
  }

  /// Replace a brand-new push-deferred task draft with a project heading
  /// (`# Design` → heading `Design`), record creation undo, reload, and select it.
  private func convertNewTaskDraftToHeading(draft: SeptenaTask,
                                            title: String,
                                            projectId: String) {
    let created = mutator.createHeading(title: title, project: projectId,
                                        afterHeadingID: draft.heading)
    mutator.purge(id: draft.id)
    if let created {
      TaskUndo.recordHeadingCreate(id: created.id, title: title,
                                   project: projectId, position: created.position,
                                   mutator: mutator)
    }
    reload(animated: false)
    if let id = created?.id,
       let row = rows.firstIndex(where: { $0.task?.id == id }) {
      tableView.selectRowIndexes([row], byExtendingSelection: false)
      tableView.scrollRowToVisible(row)
    }
  }

  /// New Section lands as a named row and opens for editing, the way ⌘N lands
  /// a new task and the way Finder lands a new folder. It used to stop the app
  /// with a modal text prompt while the row it was about to create sat right
  /// there, editable.
  private func menuNewSection() {
    guard case .project(let projectId) = filter else { return }
    commitOpenEdits()
    guard let heading = mutator.createHeading(
      title: RegistryActions.title(.sectionNew),
      project: projectId) else { return }
    pendingNewTaskId = heading.id
    reload(animated: false)
    guard let row = rows.firstIndex(where: { $0.task?.id == heading.id }) else { return }
    tableView.selectRowIndexes([row], byExtendingSelection: false)
    tableView.scrollRowToVisible(row)
    beginEditingRow(row)
  }

  // MARK: - Clear logged (issue #208)

  /// Right-click on a project's or area's logged footer: "Clear Logged…",
  /// the same registry menu the SwiftUI footer shows on long press.
  private func buildLoggedFooterMenu() -> NSMenu {
    KitRegistryMenu.build(RegistryActions.menu(.scopeLoggedFooter)) { [weak self] id in
      guard let self, id == .loggedClear else { return nil }
      return .init { self.menuClearLogged() }
    }
  }

  /// The project's or area's own name for the clear prompt.
  private var scopeDisplayName: String {
    let snapshot = StructureCache.snapshot(in: context)
    let name: String?
    switch filter {
    case .project(let id): name = snapshot.projects.first { $0.id == id }?.title
    case .area(let id): name = snapshot.areas.first { $0.id == id }?.title
    default: name = nil
    }
    guard let name, !name.isEmpty else { return filter.title }
    return name
  }

  /// Ask with the registry `clearLogged` copy (page name and exact count),
  /// then soft-delete to Recently Deleted. Undo is recorded at the gesture;
  /// the toast undoes this batch only, same ticket pattern as
  /// `deleteSelection`.
  private func menuClearLogged() {
    commitOpenEdits()
    let ids = loggedClearIDs
    guard !ids.isEmpty else { return }
    let copy = RegistryPrompts.clearLogged(count: ids.count, name: scopeDisplayName)
    KitPrompt.confirmDestructive(copy, in: view.window) { [weak self] in
      guard let self else { return }
      TaskUndo.recordDelete(ids: ids, mutator: self.mutator)
      let ticket = TaskUndoTicket()
      for id in ids { self.mutator.delete(id: id) }
      self.toastStore.show(RegistryToasts.deletedBulk(count: ids.count)) { [weak self, mutator] in
        ticket.undo { for id in ids { mutator.restore(id: id) } }
        self?.reload()
      }
      self.reload()
    }
  }

  private func menuDeleteHeading() {
    let row = tableView.selectedRow
    guard row >= 0, let heading = rows[row].task, heading.isHeading else { return }
    // Registry copy, the same prompt TaskListView's confirmationDialog shows.
    let headingId = heading.id
    KitPrompt.confirmDestructive(RegistryPrompts.prompt(.deleteSection), in: view.window) { [weak self] in
      guard let self else { return }
      self.mutator.delete(id: headingId)
      self.reload()
    }
  }
}

// MARK: - Menu validation

extension SeptaskKitTaskListController: NSMenuItemValidation {
  /// The page title's navigation dropdown is the one selector-based menu
  /// left here; the row menus are registry menus whose items carry their own
  /// enabled state (`KitRegistryMenu`).
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(navMenuSelect(_:)):
      return true
    default:
      return hasActionableSelection
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

  /// Type-select matches the task TITLE — the cell's own string would be the
  /// chip or the date. Rows with no task (headers, events, the "New task"
  /// line) don't take part.
  func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?,
                 row: Int) -> String? {
    guard rows.indices.contains(row) else { return nil }
    return rows[row].task?.title ?? rows[row].noticeStep?.title
      ?? rows[row].standaloneNotice?.title
  }

  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
    // The "New task" line is selectable even though it carries no task, so
    // arrow-nav reaches it and Return activates it — same contract as SwiftUI,
    // where the trigger row joins `keyboardOrderedTaskIds`. Every other
    // taskless row (headers, screen title, logged footer) stays unselectable.
    if case .newTask = rows[row] { return true }
    // Get started steps are list rows too; the notice header above them is
    // not (it has no task and no step).
    if case .noticeStep = rows[row] { return true }
    // A standalone notice is a row too: ↑/↓ reach it, ⌘K dismisses it.
    if rows[row].standaloneNotice != nil { return true }
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
    case .logbookBar: return 38
    case .tagFilterBar: return 34
    case .projectTarget: return SeptaskKitTheme.rowHeight
    case .task(let task, _, _):
      if task.isHeading {
        // Section break between cards — room above matching SwiftUI's
        // `headingRow` top padding so the divider isn't flush to the card.
        return SeptaskKitTheme.heading.pointSize + 28
      }
      if task.id == composingTaskId {
        return composerRowHeight ?? KitComposerCell.baseHeight
      }
      if filter == .review {
        return KitReviewTaskCell.height(for: task, issue: issueRefs[task.id],
                                        contextText: KitListPath.text(for: task, in: context),
                                        width: tableView.bounds.width)
      }
      return SeptaskKitTheme.rowHeight
    case .event: return SeptaskKitTheme.rowHeight
    // Blank band above it as tall as a group title, so the footer reads as
    // its own section, not glued to the last task (mz, 2026-11-20).
    case .fadedFooter, .loggedFooter:
      return KitLoggedFooterCell.topGap + SeptenaTypeScale.size(.footnote) + 24
    case .newTask: return SeptaskKitTheme.rowHeight
    // Same band as the logged footer — both are quiet meta-font page footers.
    case .addSection: return SeptenaTypeScale.size(.footnote) + 24
    case .notesProposal(_, _, let currentNotes, let proposal):
      return KitNotesProposalLayout.height(
        currentNotes: currentNotes,
        proposal: proposal,
        rowWidth: tableView.bounds.width)
    case .containerNotes(let isArea, _, let text):
      return KitContainerNotes.height(
        text: text,
        placeholder: isArea ? ContainerNotes.areaPlaceholder : ContainerNotes.projectPlaceholder,
        rowWidth: tableView.bounds.width)
    // Reminder rows read as task rows (they become tasks on click); their
    // header sits on the page like every other group header.
    case .reminder: return SeptaskKitTheme.rowHeight
    case .importAllReminders: return SeptaskKitTheme.rowHeight
    // Inline notices: one component, its height follows its content.
    case .notice(let notice): return KitNoticeCell.height(for: KitNotice(notice))
    case .noticeStep: return SeptaskKitTheme.rowHeight
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
      // Every card row — including an open inline composer (create or edit) —
      // rides inside its continuous card run and inherits the corner rounding
      // of its group position (top / middle / bottom / solo), so neither the
      // composer nor its adjacent closed rows round off mid-group (#204).
      let previousOnCard = row > 0 && rows[row - 1].isCardRow
      let nextOnCard = row + 1 < rows.count && rows[row + 1].isCardRow
      rowView.isFirstInGroup = !previousOnCard
      rowView.isLastInGroup = !nextOnCard
    } else {
      rowView.isCard = false
    }
    applySelectionJoins(rowView, atRow: row)
    applyDropLine(rowView, atRow: row)
    rowView.needsDisplay = true
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
      // A notice draws its selection on its own fill, over the row.
      if let notice = cardRow.view(atColumn: 0) as? KitNoticeCell {
        notice.isRowSelected = tableView.selectedRowIndexes.contains(row)
      }
    }
  }

  private func applyDropLine(_ rowView: KitCardRowView, atRow row: Int) {
    guard let drop = dropAboveRow else {
      rowView.dropLine = .none
      return
    }
    // Above a card row the bar sits on the row before it, like SwiftUI's
    // `taskInsertionMark`: between cells, and clear of the card's rounded top.
    let onRowBefore = drop > 0 && (drop >= rows.count || rows[drop].isCardRow)
    if onRowBefore {
      rowView.dropLine = row == min(drop, rows.count) - 1 ? .bottom : .none
    } else {
      rowView.dropLine = row == drop ? .top : .none
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
    case .review, .agent, .logbook, .faded, .recentlyDeleted: return false
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

  /// A drag that starts here holds reloads until it ends (`isDragActive`).
  func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                 willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
    isDragActive = true
  }

  func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                 endedAt screenPoint: NSPoint, operation: NSDragOperation) {
    endDragHold()
  }

  /// Let held reloads through again — the drag dropped, ended, or left.
  private func endDragHold() {
    dropAboveRow = nil
    guard isDragActive else { return }
    isDragActive = false
    flushHeldReload()
  }

  func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                 proposedRow row: Int,
                 proposedDropOperation operation: NSTableView.DropOperation)
    -> NSDragOperation {
    if KitDrag.ids(from: info).isEmpty {
      // External Finder file drop onto a task row (`docs/ATTACHMENTS_MAC_PARITY_SPEC.md` §3).
      if rows.indices.contains(row),
         let targetTask = rows[row].task, !targetTask.isHeading,
         let urls = info.draggingPasteboard.readObjects(
           forClasses: [NSURL.self],
           options: [.urlReadingFileURLsOnly: true]
         ) as? [URL], !urls.isEmpty {
        dropAboveRow = nil
        tableView.setDropRow(row, dropOperation: .on)
        return .copy
      }
      dropAboveRow = nil
      return []
    }
    guard allowsReorder else {
      dropAboveRow = nil
      return []
    }
    // From the first hover until the drop, the rows this indicator points
    // at must be the rows `acceptDrop` resolves: hold sync reloads.
    isDragActive = true
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
    // Release the hold BEFORE writing: `rows` is still exactly what the
    // indicator showed (nothing reloads until the explicit `reload()` below —
    // the mutators' notifications coalesce onto the next run-loop turn).
    isDragActive = false
    // Every exit (a refused drop included) lets a held sync reload through.
    defer { flushHeldReload() }
    let ids = KitDrag.ids(from: info)
    if ids.isEmpty {
      guard rows.indices.contains(row),
            let targetTask = rows[row].task, !targetTask.isHeading,
            let urls = info.draggingPasteboard.readObjects(
              forClasses: [NSURL.self],
              options: [.urlReadingFileURLsOnly: true]
            ) as? [URL], !urls.isEmpty else { return false }
      let added = KitAttachmentPasteHelper.attachFiles(urls, to: targetTask.id, presentErrorIn: view.window)
      if added > 0 {
        refreshComposerRow(taskId: targetTask.id)
        reload()
        onStoreChanged?()
      }
      return added > 0
    }
    let insertAt = clampDropRow(row) ?? row

    // Project pages: group-aware drop (file under a heading + reorder
    // within the group, or reorder headings among themselves). Mirrors
    // `TaskListView.handleGroupedTaskDrop` / `handleHeadingDrop`.
    if case .project(let projectId) = filter {
      return acceptProjectDrop(ids: ids, at: insertAt, projectId: projectId)
    }

    let dragged = Set(ids)
    // Order within the RECEIVING group only — the open task rows between the
    // headers around the gap. A neighbour from a different group (grouped
    // Today's next list, Upcoming's next day) has an unrelated order key.
    let bounds = groupBounds(aroundGap: insertAt)
    func orderable(_ row: Row) -> SeptenaTask? {
      guard let task = row.task, !task.isHeading, task.status == .open,
            !dragged.contains(task.id) else { return nil }
      return task
    }
    let sequence = rows[bounds].compactMap(orderable)
    let insertion = rows[bounds.lowerBound..<max(bounds.lowerBound, insertAt)]
      .compactMap(orderable).count

    // Undo: one ⌘Z puts back order, filing and day together (one event, one
    // undo group). Captured before any write.
    let positionsBefore = TaskUndo.reorderSnapshot(of: sequence.map(\.id) + ids, lane: orderLane, in: context)
    let draggedTasks = ids.compactMap { LocalCache.task(id: $0, in: context) }
    let filingBefore = draggedTasks.map(TaskUndo.FilingSnapshot.init)
    let scheduleBefore = draggedTasks.map(TaskUndo.ScheduleSnapshot.init)

    // Re-file and re-date FIRST: re-homing resets `position` to the top of
    // the new home, so ordering has to be written after it, not before.
    let refiled = refileIfGroupedDrop(ids: ids, at: insertAt)
    let rescheduled = rescheduleIfUpcomingDrop(ids: ids, at: insertAt)
    // Through the shared midpoint-with-renumber fallback, so an exhausted
    // gap can't land the row next to the wrong neighbour.
    applyManualOrder(ids: ids, into: sequence, at: insertion)

    if refiled {
      TaskUndo.recordMove(before: filingBefore, context: context, mutator: mutator)
    }
    if rescheduled {
      TaskUndo.recordScheduleChange(
        name: String(localized: "Change When", comment: "SeptaskKit: undo action"),
        before: scheduleBefore, context: context, mutator: mutator)
    }
    TaskUndo.recordReorder(positionsBefore, context: context, mutator: mutator)
    reload()
    return true
  }

  /// The rows of the group around a drop gap (or a row): from just below the
  /// nearest header / section heading above, to just above the next one.
  private func groupBounds(aroundGap gap: Int) -> Range<Int> {
    func isBreak(_ row: Row) -> Bool {
      if case .header = row { return true }
      return row.task?.isHeading == true
    }
    let gap = min(max(gap, 0), rows.count)
    var start = 0
    for index in stride(from: gap - 1, through: 0, by: -1) where isBreak(rows[index]) {
      start = index + 1
      break
    }
    var end = rows.count
    for index in gap..<rows.count where isBreak(rows[index]) {
      end = index
      break
    }
    return start..<max(start, end)
  }

  /// Upcoming: a drop under another day's header moves the task to THAT day
  /// (Things). The same write the When popover makes for a future date —
  /// `reschedule`, with the fixed-repeat question, then off Today — so the
  /// row lands in the bucket it was dropped in. Returns whether anything
  /// changed.
  private func rescheduleIfUpcomingDrop(ids: [String], at gap: Int) -> Bool {
    guard filter == .upcoming else { return false }
    var dayKey: String?
    for index in stride(from: min(gap, rows.count) - 1, through: 0, by: -1) {
      if case .header(let id, _, _, _) = rows[index] {
        if id.hasPrefix("day-") { dayKey = String(id.dropFirst(4)) }
        break
      }
    }
    guard let dayKey, let date = SeptenaDate.parse(dayKey) else { return false }
    let today = SeptenaDate.today
    var changed = false
    for id in ids {
      guard let task = LocalCache.task(id: id, in: context) else { continue }
      // The bucket `upcomingBuckets` filed it under — already there: no-op.
      let bucket = [task.scheduled, task.deadline].compactMap { $0 }.filter { $0 > today }.min()
      guard bucket != dayKey, let mode = rescheduleMode(for: task, newDate: date) else { continue }
      mutator.apply(.scheduleFor(date), to: id, mode: mode)
      changed = true
    }
    return changed
  }

  /// Drop row clamped to the open-work region — never into the logged
  /// footer or the completed rows it expands. Returns nil when `row` is
  /// already valid (so validateDrop can avoid a redundant setDropRow).
  private func clampDropRow(_ row: Int) -> Int? {
    guard let footer = rows.firstIndex(where: {
      switch $0 {
      case .fadedFooter, .loggedFooter: return true
      default: return false
      }
    }), row > footer else { return nil }
    return footer
  }

  /// Persist a manual-order drop — same midpoint-with-renumber-fallback
  /// `TaskListView.applyManualOrder` uses, so exhausted gaps don't silently
  /// land adjacent to the wrong neighbor. Writes the order of `orderLane`:
  /// Today's own order on Today, `position` everywhere else (#66).
  private func applyManualOrder(ids: [String], into sequence: [SeptenaTask], at insertion: Int) {
    let lane = orderLane
    let above = insertion > 0 ? sequence[insertion - 1].orderKey(in: lane) : nil
    let below = insertion < sequence.count ? sequence[insertion].orderKey(in: lane) : nil
    let slots = TaskOrder.positions(count: ids.count, above: above, below: below)
    let strictlyPlaced =
      zip(slots, slots.dropFirst()).allSatisfy { $0 < $1 }
      && (above.map { slots.first! > $0 } ?? true)
      && (below.map { slots.last! < $0 } ?? true)
    if strictlyPlaced {
      for (id, pos) in zip(ids, slots) { mutator.reorder(id: id, toPosition: pos, in: lane) }
      return
    }
    var final = sequence.map(\.id)
    final.insert(contentsOf: ids, at: insertion)
    let base = sequence.first?.orderKey(in: lane) ?? TaskOrder.gap
    for (i, id) in final.enumerated() {
      let pos = base + TaskOrder.gap * Double(i)
      mutator.reorder(id: id, toPosition: pos == 0 ? TaskOrder.gap / 2 : pos, in: lane)
    }
  }

  /// The manual order this list shows and a reorder writes: Today has its
  /// own (`todayPosition`), so reordering Today never moves a task in its
  /// area / project list (#66).
  private var orderLane: TaskOrderLane { filter == .today ? .today : .list }

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
    let positionsBefore = TaskUndo.positions(of: headings.map(\.id), in: context)
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
    TaskUndo.recordReorder(before: positionsBefore, context: context, mutator: mutator)
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

    // Undo puts back both the section and the order — one gesture.
    let positionsBefore = TaskUndo.positions(of: groupRows.map(\.id) + ids, in: context)
    let filingBefore = ids.compactMap { LocalCache.task(id: $0, in: context) }
      .map(TaskUndo.FilingSnapshot.init)
    var refiled = false
    for id in ids {
      guard let task = byId[id] else { continue }
      if resolvedHeading(task, headingIds: headingIds) != group {
        mutator.setHeading(id: id, heading: group)
        refiled = true
      }
    }
    applyManualOrder(ids: ids, into: groupRows, at: insertion)
    if refiled {
      TaskUndo.recordMove(before: filingBefore, context: context, mutator: mutator)
    }
    TaskUndo.recordReorder(before: positionsBefore, context: context, mutator: mutator)
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
  /// Returns whether any task changed list (so the caller records a move).
  private func refileIfGroupedDrop(ids: [String], at row: Int) -> Bool {
    let grouped: Bool
    switch filter {
    case .today: grouped = todayGroupsByList
    case .unscheduled, .starred: grouped = true
    default: grouped = false
    }
    guard grouped else { return false }

    var targetProject: String?
    var targetArea: String?
    for index in stride(from: row - 1, through: 0, by: -1) {
      if case .header(let id, _, _, _) = rows[index] {
        if id.hasPrefix("p-") { targetProject = String(id.dropFirst(2)) }
        if id.hasPrefix("a-") { targetArea = String(id.dropFirst(2)) }
        break
      }
    }

    var movedIDs: [String] = []
    for id in ids {
      // The store, not `rows`: a drag from another window's list carries ids
      // this table may not be showing.
      guard let task = LocalCache.task(id: id, in: context) else { continue }
      // Area only matters outside a project group (a project implies its area).
      let destinationChanged = task.project != targetProject
        || (targetProject == nil && task.area != targetArea)
      if destinationChanged {
        mutator.moveToList(id: id, area: targetArea, project: targetProject)
        mutator.acknowledge(id: id)
        movedIDs.append(id)
      }
    }
    if !movedIDs.isEmpty {
      if targetProject != nil || targetArea != nil {
        noteInboxGesture(ids: movedIDs)
      } else {
        cancelInboxZeroMotion()
      }
    }
    return !movedIDs.isEmpty
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
      let keepCheckmark = (id == "inbox" && inboxZeroTracker.phase == .checkmark)
      cell.configure(title: title, icon: icon, count: count,
                     isNavigable: target != nil,
                     keepAnimatedCheckmark: keepCheckmark)
      cell.onTap = target.map { filter in
        { [weak self] in self?.onNavigate?(.filter(filter, title: filter.title)) }
      }
      return cell

    case .screenTitle(let title, let icon):
      let identifier = NSUserInterfaceItemIdentifier("screenTitleCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? KitScreenTitleCell
        ?? KitScreenTitleCell(identifier: identifier)
      cell.configure(title: title, icon: icon, showsNavMenu: !isSidebarVisible)
      // The title IS the navigation dropdown (Things-style) when the sidebar is
      // collapsed — same contract as SwiftUI's `TaskNavMenu`. Built fresh per
      // click via the closure rather than once here, so it can never show a
      // stale structure.
      cell.onOpenNavMenu = { [weak self] in self?.buildNavMenu() }
      if case .area(let areaID) = filter {
        cell.onPickGlyph = { [weak self] anchor in
          guard let self,
                let area = StructureCache.snapshot(in: self.context).areas.first(where: { $0.id == areaID })
          else { return }
          KitEmojiPopover.present(for: area, relativeTo: anchor.bounds, of: anchor)
        }
      } else {
        cell.onPickGlyph = nil
      }
      if case .project = filter {
        cell.onOpenOverflowMenu = { [weak self] in self?.buildProjectOverflowMenu() }
      } else {
        cell.onOpenOverflowMenu = nil
      }
      return cell

    case .logbookBar(let tab, let deletedCount, let showsSegmented, let canEmptyTrash):
      let identifier = NSUserInterfaceItemIdentifier("logbookBarCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? KitLogbookBarCell
        ?? KitLogbookBarCell(identifier: identifier)
      cell.configure(tab: tab,
                     deletedCount: deletedCount,
                     showsSegmented: showsSegmented,
                     canEmptyTrash: canEmptyTrash)
      cell.onSelectTab = { [weak self] next in self?.selectLogbookTab(next) }
      cell.onEmptyTrash = { [weak self] in self?.emptyTrash() }
      return cell

    case .tagFilterBar(let tags, let active):
      let identifier = NSUserInterfaceItemIdentifier("tagFilterBarCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? KitTagFilterBarCell
        ?? KitTagFilterBarCell(identifier: identifier)
      cell.configure(tags: tags, activeIDs: Set(active))
      cell.onToggleTag = { [weak self] id in self?.toggleTagFilter(id) }
      cell.onClear = { [weak self] in _ = self?.clearTagFilterIfActive() }
      return cell

    case .projectTarget(let id, let title, let progress, let count):
      let identifier = NSUserInterfaceItemIdentifier("projectTargetCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil)
        as? KitProjectTargetCell
        ?? KitProjectTargetCell(identifier: identifier)
      cell.configure(title: title, progress: progress, count: count)
      cell.onTap = { [weak self] in
        self?.onNavigate?(.filter(.project(id), title: title))
      }
      return cell

    case .fadedFooter(let count, let expanded):
      let identifier = NSUserInterfaceItemIdentifier("loggedFooterCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? KitLoggedFooterCell
        ?? KitLoggedFooterCell(identifier: identifier)
      cell.configure(count: count, expanded: expanded, kind: .faded)
      cell.onTap = { [weak self] in self?.toggleFadedExpanded() }
      return cell

    case .loggedFooter(let count, let expanded):
      let identifier = NSUserInterfaceItemIdentifier("loggedFooterCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? KitLoggedFooterCell
        ?? KitLoggedFooterCell(identifier: identifier)
      cell.configure(count: count, expanded: expanded, kind: .logged)
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

    case .notesProposal(let isArea, let id, let currentNotes, let proposal):
      let identifier = NSUserInterfaceItemIdentifier("notesProposalCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? KitNotesProposalCell
        ?? KitNotesProposalCell(identifier: identifier)
      cell.configure(currentNotes: currentNotes, proposal: proposal)
      cell.onAccept = { [weak self] in
        self?.acceptContainerNotesProposal(isArea: isArea, id: id, currentNotes: currentNotes, proposal: proposal)
      }
      cell.onReject = { [weak self] in
        self?.rejectContainerNotesProposal(isArea: isArea, id: id, currentNotes: currentNotes, proposal: proposal)
      }
      return cell

    case .containerNotes(let isArea, let id, let text):
      let identifier = NSUserInterfaceItemIdentifier("containerNotesCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? KitContainerNotesCell
        ?? KitContainerNotesCell(identifier: identifier)
      cell.configure(text: text,
                     placeholder: isArea ? ContainerNotes.areaPlaceholder : ContainerNotes.projectPlaceholder)
      cell.onEdit = { [weak self] anchor in
        self?.editContainerNotes(isArea: isArea, id: id, text: text, anchor: anchor)
      }
      cell.onHistory = { [weak self] in
        self?.showContainerNotesHistory(isArea: isArea, id: id)
      }
      return cell

    case .importAllReminders(let count, let importing):
      let identifier = NSUserInterfaceItemIdentifier("importAllRemindersCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil)
        as? KitImportAllRemindersCell
        ?? KitImportAllRemindersCell(identifier: identifier)
      cell.configure(count: count, importing: importing)
      cell.onTap = { [weak self] in self?.importAllReminders() }
      return cell

    case .notice(let notice):
      let cell = noticeCell(KitNotice(notice))
      cell.isRowSelected = tableView.selectedRowIndexes.contains(row)
      cell.onPrimary = noticePrimaryAction(notice.id)
      cell.onDismiss = notice.dismissible ? { [weak self] in self?.dismissNotice(notice.id) } : nil
      return cell

    case .noticeStep(let step):
      let identifier = NSUserInterfaceItemIdentifier("noticeStepCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? KitNoticeStepCell
        ?? KitNoticeStepCell(identifier: identifier)
      cell.configure(step)
      // The checkbox ticks and unticks, like a task's.
      cell.onToggle = { [weak self] in
        TaskNotices.toggleStep(step)
        self?.reload()
      }
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
      if filter == .review, !task.isHeading {
        let identifier = NSUserInterfaceItemIdentifier("reviewTaskCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? KitReviewTaskCell
          ?? KitReviewTaskCell(identifier: identifier)
        cell.configure(with: task, issue: issueRefs[task.id],
                       contextText: KitListPath.text(for: task, in: context))
        cell.onAccept = { [weak self] id in self?.acceptReviewTask(id: id) }
        cell.onSendBack = { [weak self] id in self?.openSendBack(taskID: id) }
        return cell
      }
      let identifier = NSUserInterfaceItemIdentifier("taskCell")
      let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? SeptaskKitTaskCell
        ?? SeptaskKitTaskCell(identifier: identifier)
      cell.configure(with: task, filter: filter, chip: chip,
                     contextText: taskContextText(for: task),
                     checklistSummary: checklistCounts[task.id],
                     attachmentCount: attachmentCounts[task.id] ?? 0,
                     fromKind: fromRefKinds[task.id].map(RegistryTaskReferences.kind),
                     tags: LocalCache.resolvedTags(for: task, tagsByID: tagsByID))
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

  /// Accept a `needs_verify` task from the Review stage: completes it with
  /// lossless undo back into Review (`needs_verify` + check note).
  private func acceptReviewTask(id: String) {
    guard let task = LocalCache.task(id: id, in: context), task.status == .open else { return }
    let previousNote = task.conversation.endStateNote
    mutator.complete(id: id)
    mutator.acknowledge(id: id)
    TaskUndo.recordAcceptReview(id: id, previousNote: previousNote, mutator: mutator)
    reload()
  }

  /// Send back from a Review row: the row does not open a field of its own.
  /// It selects the row (so the inspector shows this task) and asks the
  /// shell to open the inspector with the Send back field open and focused
  /// (docs/AGENT_PROMPT_SPEC.md). The send, its undo and the reload run in
  /// the inspector's conversation view, the same path as its own Send back.
  private func openSendBack(taskID: String) {
    guard select(taskId: taskID) else { return }
    onOpenSendBack?()
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
  private let notesGlyph = NSImageView()
  /// Permanent "an agent added this" glyph (`taskPage.provenance`). Unlike
  /// the checkbox's agent cue it never clears.
  private let agentGlyph = NSImageView()
  private let chip = KitChipView()
  private let statusChip = KitChipView()
  private let suggestionChip = KitSuggestionChipView()
  /// The item the task was created from (its `from` reference).
  private let fromGlyph = NSImageView()
  private let scheduleGlyph = NSImageView()
  private let detail = NSTextField(labelWithString: "")
  private let reminderGlyph = NSImageView()
  private let reminderLabel = NSTextField(labelWithString: "")
  private let checklistGlyph = NSImageView()
  private let checklistLabel = NSTextField(labelWithString: "")
  private let attachmentGlyph = NSImageView()
  private let attachmentLabel = NSTextField(labelWithString: "")
  private let tagStack = NSStackView()
  private let repeatGlyph = NSImageView()
  private let starGlyph = NSImageView()
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


    notesGlyph.translatesAutoresizingMaskIntoConstraints = false
    notesGlyph.contentTintColor = SeptaskKitTheme.iconMuted
    notesGlyph.image = NSImage(systemSymbolName: "text.alignleft",
                               accessibilityDescription: TaskA11y.hasNotes)?
      .withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
    notesGlyph.setContentHuggingPriority(.required, for: .horizontal)
    notesGlyph.setContentCompressionResistancePriority(.required, for: .horizontal)
    notesGlyph.kitA11yIgnore()

    agentGlyph.translatesAutoresizingMaskIntoConstraints = false
    agentGlyph.contentTintColor = SeptaskKitTheme.iconMuted
    agentGlyph.image = NSImage(systemSymbolName: RegistrySurfaces.provenanceAgentSymbol,
                               accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
    agentGlyph.setContentHuggingPriority(.required, for: .horizontal)
    agentGlyph.setContentCompressionResistancePriority(.required, for: .horizontal)
    // The row's accessibility label speaks the provenance (`TaskA11y.rowLabel`).
    agentGlyph.kitA11yIgnore()
    agentGlyph.isHidden = true

    fromGlyph.translatesAutoresizingMaskIntoConstraints = false
    fromGlyph.contentTintColor = SeptaskKitTheme.iconMuted
    fromGlyph.setContentHuggingPriority(.required, for: .horizontal)
    fromGlyph.setContentCompressionResistancePriority(.required, for: .horizontal)
    // The row's accessibility label speaks it, as for the agent glyph.
    fromGlyph.kitA11yIgnore()
    fromGlyph.isHidden = true

    detail.lineBreakMode = .byClipping
    detail.isEditable = false
    detail.isSelectable = false
    detail.kitA11yIgnore()
    detail.setContentHuggingPriority(.required, for: .horizontal)
    detail.setContentCompressionResistancePriority(.required, for: .horizontal)
    scheduleGlyph.setContentHuggingPriority(.required, for: .horizontal)
    scheduleGlyph.setContentCompressionResistancePriority(.required, for: .horizontal)

    reminderGlyph.translatesAutoresizingMaskIntoConstraints = false
    reminderGlyph.image = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
    reminderGlyph.contentTintColor = SeptaskKitTheme.inkSecondary
    reminderGlyph.setContentHuggingPriority(.required, for: .horizontal)
    reminderGlyph.setContentCompressionResistancePriority(.required, for: .horizontal)
    reminderGlyph.kitA11yIgnore()
    reminderGlyph.isHidden = true

    reminderLabel.font = SeptaskKitTheme.meta
    reminderLabel.textColor = SeptaskKitTheme.inkSecondary
    reminderLabel.lineBreakMode = .byClipping
    reminderLabel.isEditable = false
    reminderLabel.isSelectable = false
    reminderLabel.setContentHuggingPriority(.required, for: .horizontal)
    reminderLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    reminderLabel.kitA11yIgnore()
    reminderLabel.isHidden = true

    checklistGlyph.translatesAutoresizingMaskIntoConstraints = false
    checklistGlyph.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
    checklistGlyph.contentTintColor = SeptaskKitTheme.inkSecondary
    checklistGlyph.setContentHuggingPriority(.required, for: .horizontal)
    checklistGlyph.setContentCompressionResistancePriority(.required, for: .horizontal)
    checklistGlyph.kitA11yIgnore()
    checklistGlyph.isHidden = true

    checklistLabel.font = SeptaskKitTheme.meta
    checklistLabel.textColor = SeptaskKitTheme.inkSecondary
    checklistLabel.lineBreakMode = .byClipping
    checklistLabel.isEditable = false
    checklistLabel.isSelectable = false
    checklistLabel.setContentHuggingPriority(.required, for: .horizontal)
    checklistLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    checklistLabel.kitA11yIgnore()
    checklistLabel.isHidden = true

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

    starGlyph.translatesAutoresizingMaskIntoConstraints = false
    starGlyph.contentTintColor = SeptaskKitTheme.todayAccent
    starGlyph.image = NSImage(systemSymbolName: RegistryIcons.sfSymbol(for: "action.star", on: true),
                              accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
    starGlyph.setContentHuggingPriority(.required, for: .horizontal)
    starGlyph.setContentCompressionResistancePriority(.required, for: .horizontal)
    starGlyph.kitA11yIgnore()
    starGlyph.isHidden = true

    tagStack.orientation = .horizontal
    tagStack.alignment = .centerY
    tagStack.spacing = 4
    tagStack.translatesAutoresizingMaskIntoConstraints = false
    tagStack.setContentHuggingPriority(.required, for: .horizontal)
    tagStack.setContentCompressionResistancePriority(.required, for: .horizontal)
    tagStack.isHidden = true

    attachmentGlyph.translatesAutoresizingMaskIntoConstraints = false
    attachmentGlyph.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
    attachmentGlyph.contentTintColor = SeptaskKitTheme.inkSecondary
    attachmentGlyph.setContentHuggingPriority(.required, for: .horizontal)
    attachmentGlyph.setContentCompressionResistancePriority(.required, for: .horizontal)
    attachmentGlyph.kitA11yIgnore()
    attachmentGlyph.isHidden = true

    attachmentLabel.translatesAutoresizingMaskIntoConstraints = false
    attachmentLabel.font = SeptaskKitTheme.meta
    attachmentLabel.textColor = SeptaskKitTheme.inkSecondary
    attachmentLabel.setContentHuggingPriority(.required, for: .horizontal)
    attachmentLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    attachmentLabel.kitA11yIgnore()
    attachmentLabel.isHidden = true

    // Trailing cluster hugs the row's right edge. Order matches the row language
    // spec: variable meta inboard, micro-glyphs outboard
    // (chip · date · recurrence · notes). A leading spacer absorbs any extra
    // width if Auto Layout stretches the stack — without it, NSStackView's
    // default gravity packs visible glyphs to the title and the notes marker
    // stairs down the middle of the row.
    let trailingShove = NSView()
    trailingShove.setContentHuggingPriority(.defaultLow, for: .horizontal)
    trailingShove.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
    let trailing = NSStackView(views: [trailingShove, suggestionChip, chip, statusChip,
                                      tagStack, attachmentGlyph, attachmentLabel,
                                      checklistGlyph, checklistLabel, reminderGlyph, reminderLabel,
                                      scheduleGlyph, detail, repeatGlyph, starGlyph, fromGlyph, notesGlyph, agentGlyph])
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
    statusChip.kitA11yIgnore()

    addSubview(checkbox)
    addSubview(title)
    addSubview(trailing)
    textField = title
    // Row announces as one unit (title + notes); the checkbox stays its own
    // element so VoiceOver can still toggle without hopping through glyphs.
    title.kitA11yIgnore()
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    leadingConstraint = checkbox.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: KitCardRowView.horizontalInset + SeptaskKitLayout.rowLeadingPad)
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
      trailingConstraint,
      // The row's centerline, NOT the title's: with a context line the title
      // sits high inside the taller row, and a chip pinned to it rode up with
      // it while the checkbox stayed centered — two different alignments on
      // one row.
      trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
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
    leadingConstraint.constant = inset + SeptaskKitLayout.rowLeadingPad
    trailingConstraint.constant = -(inset + 8)
    super.layout()
  }

  /// Forwarded to the checkbox — the promote cue's ring half. Kept on the cell
  /// so the controller talks to one row object, not to its internals.
  func playTodayPromotePulse() { checkbox.playTodayPromotePulse() }

  /// The ordinary check-landing ring, played for a completion that happened
  /// on another device (`ghostCheckRemoteCompletions`) — the same pulse a
  /// click plays in `KitCheckboxView.fire`, so a phantom check reads as a
  /// touch. The click path keeps its own trigger; this one is controller-driven.
  func playGhostCheckPulse() {
    guard !KitMotion.reduce else { return }
    checkbox.playPulse(color: SeptaskKitTheme.checkboxFill)
  }

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
                 contextText: String?,
                 checklistSummary: (done: Int, total: Int)? = nil,
                 attachmentCount: Int = 0,
                 fromKind: RegistryTaskReferenceKind? = nil,
                 tags: [TaskTag] = []) {
    taskId = task.id
    plainTitle = task.title
    editing = false
    title.isEditable = false

    if task.isHeading {
      checkbox.isHidden = true
      checkbox.kitA11yIgnore()
      notesGlyph.isHidden = true
      agentGlyph.isHidden = true
      chip.isHidden = true
      statusChip.isHidden = true
      fromGlyph.isHidden = true
      tagStack.isHidden = true
      attachmentGlyph.isHidden = true
      attachmentLabel.isHidden = true
      checklistGlyph.isHidden = true
      checklistLabel.isHidden = true
      reminderGlyph.isHidden = true
      reminderLabel.isHidden = true
      scheduleGlyph.isHidden = true
      repeatGlyph.isHidden = true
      starGlyph.isHidden = true
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
    // Recently Deleted rows are out of every list, Today included: no gold
    // Today badge there.
    let showFadedInScope = task.isFaded && filter != .faded
    checkbox.isToday = task.isOnToday && filter != .today && task.deletedAt == nil && !task.isFaded
    // Countdown toward the 14-day fade window in every open list
    // (`docs/TASK_FADE_SPEC.md` §4). Inside the Faded pile itself rows stay at
    // full opacity; inside projects and areas faded rows render visibly faded.
    if showFadedInScope {
      checkbox.tenureFill = 1.0
    } else {
      checkbox.tenureFill = (done || !TaskRowFlags.agingEnabled || filter == .recentlyDeleted || task.deletedAt != nil || filter == .faded)
        ? nil : task.fadeFill()
    }
    // The whole row fades, checkbox included: same curve as `CheckableRow`.
    let fade = CGFloat(TaskFade.rowOpacity(checkbox.tenureFill))
    for view in [checkbox, title, notesGlyph, agentGlyph, fromGlyph, chip, statusChip, suggestionChip,
                 tagStack, attachmentGlyph, attachmentLabel, checklistGlyph, checklistLabel,
                 reminderGlyph, reminderLabel, scheduleGlyph, detail, repeatGlyph, starGlyph] as [NSView] {
      view.alphaValue = fade
    }
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
    // The list name rides the TITLE LINE as a dimmed suffix rather than a
    // second line: it keeps rows single-height (a subtitle cost +14pt each,
    // ~a quarter of a screenful on a long Today) and keeps the reading order
    // left-to-right — title, then where it lives — instead of parking the
    // answer in a right-edge pill, which reads as a filterable token and sat
    // next to the genuinely tappable filing capsule. A long title truncates
    // the suffix away with it; that is the accepted cost of the one-line row.
    let composed = NSMutableAttributedString(string: task.title, attributes: titleAttributes)
    if let contextText, !contextText.isEmpty {
      composed.append(NSAttributedString(
        string: "  " + contextText,
        // Deliberately NOT `titleAttributes`: the suffix keeps its quiet meta
        // font and never takes the strikethrough of a completed title — the
        // task is done, its list is not.
        attributes: [.font: SeptaskKitTheme.meta,
                     .foregroundColor: SeptaskKitTheme.inkSecondary]))
    }
    title.attributedStringValue = composed

    let hasNotes = !(task.notes ?? "").isEmpty
    // The agent glyph already says "there is more here" (same rule as the
    // SwiftUI row): an agent-authored row never also wears the notes glyph.
    notesGlyph.isHidden = !hasNotes || task.isAgentAuthored
    agentGlyph.isHidden = !task.isAgentAuthored
    fromGlyph.isHidden = fromKind == nil
    fromGlyph.image = fromKind.flatMap {
      NSImage(systemSymbolName: $0.sfSymbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
    }
    // The chip and the inline title suffix answer the SAME question — "which
    // list is this in" — so a row never wears both. The suffix wins where it
    // is shown (flat Today): it sits on the title line where the eye already
    // is, and a pill repeating it on the far right is noise, not emphasis.
    if let chipValue, contextText == nil {
      chip.isHidden = false
      chip.configure(symbol: chipValue.symbol, title: chipValue.title)
    } else {
      chip.isHidden = true
    }

    if showFadedInScope {
      statusChip.isHidden = false
      statusChip.configure(symbol: "circle.dashed",
                           title: TaskFilter.faded.title)
    } else if !done && task.isOnToday && filter != .today && task.deletedAt == nil && !task.isFaded {
      statusChip.isHidden = false
      statusChip.configure(symbol: "sun.max.fill",
                           title: TaskFilter.today.title)
    } else {
      statusChip.isHidden = true
    }

    if attachmentCount > 0 {
      attachmentGlyph.isHidden = false
      if attachmentCount > 1 {
        attachmentLabel.stringValue = "\(attachmentCount)"
        attachmentLabel.isHidden = false
      } else {
        attachmentLabel.stringValue = ""
        attachmentLabel.isHidden = true
      }
    } else {
      attachmentGlyph.isHidden = true
      attachmentLabel.stringValue = ""
      attachmentLabel.isHidden = true
    }

    if let summary = checklistSummary, summary.total > 0 {
      checklistLabel.stringValue = "\(summary.done)/\(summary.total)"
      checklistGlyph.isHidden = false
      checklistLabel.isHidden = false
    } else {
      checklistLabel.stringValue = ""
      checklistGlyph.isHidden = true
      checklistLabel.isHidden = true
    }

    for v in tagStack.arrangedSubviews {
      tagStack.removeArrangedSubview(v)
      v.removeFromSuperview()
    }
    if !tags.isEmpty {
      let shown = Array(tags.prefix(3))
      let overflow = max(0, tags.count - shown.count)
      for tag in shown {
        tagStack.addArrangedSubview(KitTagChipView(name: tag.name, colorToken: tag.color))
      }
      if overflow > 0 {
        let more = NSTextField(labelWithString: "+\(overflow)")
        more.font = .systemFont(ofSize: SeptenaTypeScale.size(.caption1))
        more.textColor = SeptaskKitTheme.inkSecondary
        tagStack.addArrangedSubview(more)
      }
      tagStack.isHidden = false
    } else {
      tagStack.isHidden = true
    }

    configureDetail(with: task, filter: filter, done: done)

    setAccessibilityRole(.group)
    setAccessibilityLabel(TaskA11y.rowLabel(title: task.title,
                                            hasNotes: hasNotes,
                                            isHeading: false,
                                            addedBy: task.isAgentAuthored ? task.addedByPhrase : nil,
                                            createdFrom: fromKind?.label))
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
    starGlyph.isHidden = !task.starred

    // Quiet trailing bell + time badge only when an open task has an active
    // reminder (progressive disclosure: zero chrome otherwise).
    if !done && task.status == .open && task.deletedAt == nil,
       let badge = task.reminder?.badgeText() {
      let tint = badge.isPastDue ? SeptaskKitTheme.overdueRed : SeptaskKitTheme.inkSecondary
      reminderGlyph.contentTintColor = tint
      reminderLabel.textColor = tint
      reminderLabel.stringValue = badge.text
      reminderGlyph.isHidden = false
      reminderLabel.isHidden = false
    } else {
      reminderGlyph.isHidden = true
      reminderLabel.isHidden = true
      reminderLabel.stringValue = ""
    }

    if task.status == .done, let completedAt = task.completedAt {
      let day = String(completedAt.prefix(10))
      guard !day.isEmpty else { return }
      configureScheduleGlyph(named: "checkmark", color: SeptaskKitTheme.iconMuted)
      detail.stringValue = KitDayFormat.taskDate(day)
      detail.isHidden = false
      return
    }

    if task.status == .cancelled {
      let label = task.dropReason != nil
        ? String(localized: "Let go", comment: "Logbook label for dropped task")
        : String(localized: "Cancelled", comment: "Logbook label for cancelled task")
      if let completedAt = task.completedAt {
        let day = String(completedAt.prefix(10))
        detail.stringValue = day.isEmpty ? label : "\(label) · \(KitDayFormat.taskDate(day))"
      } else {
        detail.stringValue = label
      }
      detail.isHidden = false
      return
    }

    if let deadline = task.deadline, KitDayFormat.date(fromWire: deadline) != nil {
      // `docs/TASK_DATES_SPEC.md` R3 / R4: due today and overdue are both
      // red; the label says which.
      let todayISO = SeptenaDate.format(KitDayFormat.todayDate()) ?? SeptenaDate.today
      let state = task.deadlineState(today: todayISO)
      if state == .dueToday || state == .overdue {
        detail.font = .monospacedDigitSystemFont(
          ofSize: SeptenaTypeScale.size(.footnote), weight: .semibold)
        detail.textColor = SeptaskKitTheme.overdueRed
        detail.stringValue = state == .overdue
          ? RegistrySurfaces.taskDateBoardOverdueLabel
          : String(localized: "Today", comment: "Deadline label: due today")
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
      // Today already communicates its own current-day membership, and off-Today
      // surfaces show a trailing Today pill for on-Today tasks. Hide redundant
      // today/past When dates in both cases while keeping future When dates.
      let coveredByTodayPill = !done && task.isOnToday && filter != .today && task.deletedAt == nil && !task.isFaded && scheduledDay <= todayDay
      if !coveredByTodayPill && (filter != .today || scheduledDay > todayDay) {
        configureScheduleGlyph(named: "calendar", color: SeptaskKitTheme.inkSecondary)
        let dateText = KitDayFormat.taskDate(scheduled)
        detail.stringValue = task.timeSlotLabel.map { "\(dateText) · \($0)" } ?? dateText
        detail.isHidden = false
      } else if let slot = task.timeSlotLabel, !done {
        configureScheduleGlyph(named: "clock", color: SeptaskKitTheme.inkSecondary)
        detail.stringValue = slot
        detail.isHidden = false
      }
    } else if let slot = task.timeSlotLabel, !done {
      configureScheduleGlyph(named: "clock", color: SeptaskKitTheme.inkSecondary)
      detail.stringValue = slot
      detail.isHidden = false
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
    // or arrow through a long title. Clip and scroll horizontally for the
    // duration of the edit so a long title never reflows vertically.
    title.usesSingleLineMode = true
    title.cell?.isScrollable = true
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
    // reads as in-row text, same as the composer title. Also re-assert font
    // and container geometry: the window's shared field editor can carry a
    // stale face or textContainerInset from another control in the window,
    // which visibly shifted the title vertically on first responder.
    if let editor = title.currentEditor() as? NSTextView {
      editor.drawsBackground = false
      editor.backgroundColor = .clear
      editor.insertionPointColor = .labelColor
      editor.textContainerInset = .zero
      editor.textContainer?.lineFragmentPadding = 2
      editor.font = font
      editor.typingAttributes = [
        .font: font,
        .foregroundColor: NSColor.labelColor,
      ]
      editor.enclosingScrollView?.contentView.scroll(to: .zero)
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
    title.usesSingleLineMode = false
    title.cell?.isScrollable = false
    title.lineBreakMode = .byTruncatingTail
    title.cell?.truncatesLastVisibleLine = true
    onRename?(taskId, title.stringValue)
  }

  /// End the edit NOW and hand back what was typed, without firing
  /// `onRename` — for a caller that commits synchronously itself
  /// (`SeptaskKitTaskListController.commitOpenEdits`). Nil when no edit is
  /// live. `editing` drops first, so the end-editing notification that
  /// `abortEditing` may post finds nothing to commit.
  func takeEditForCommit() -> String? {
    guard editing else { return nil }
    let text = title.currentEditor()?.string ?? title.stringValue
    editing = false
    _ = title.abortEditing()
    title.isEditable = false
    title.usesSingleLineMode = false
    title.cell?.isScrollable = false
    title.lineBreakMode = .byTruncatingTail
    title.cell?.truncatesLastVisibleLine = true
    return text
  }

  func control(_ control: NSControl, textView: NSTextView,
               doCommandBy commandSelector: Selector) -> Bool {
    // Escape SAVES, like Return and click-away — one edit contract for every
    // editor in the list; ⌘Z takes a save back. It used to revert, which
    // threw away a new row's typed title and then purged the row as empty.
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
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
  /// Open tasks, in the sidebar badge's style. Empty at zero, and with View ▸
  /// Show Sidebar Counts off.
  private let badge = NSTextField(labelWithString: "")
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
    badge.translatesAutoresizingMaskIntoConstraints = false
    badge.textColor = SeptaskKitTheme.iconMuted
    badge.setContentHuggingPriority(.required, for: .horizontal)
    badge.setContentCompressionResistancePriority(.required, for: .horizontal)

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
    badge.kitA11yIgnore()

    addSubview(progress)
    addSubview(title)
    addSubview(chevron)
    addSubview(badge)
    // Last, so it layers above the content and takes every click in the row.
    addSubview(hit)
    textField = title
    setAccessibilityElement(true)
    leadingConstraint = progress.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: KitCardRowView.horizontalInset + SeptaskKitLayout.rowLeadingPad)
    trailingConstraint = badge.trailingAnchor.constraint(
      equalTo: trailingAnchor, constant: -(KitCardRowView.horizontalInset + 8))
    hitPin = KitContentColumnPin(hit, in: self)
    NSLayoutConstraint.activate([
      leadingConstraint,
      progress.centerYAnchor.constraint(equalTo: centerYAnchor),
      // The checkbox's tap column, so the ring's center and the title's
      // leading edge match a task row's (`SeptaskKitLayout.leadingGlyphCenterX`).
      progress.widthAnchor.constraint(equalToConstant: KitCheckboxView.tapSize),
      progress.heightAnchor.constraint(equalToConstant: KitCheckboxView.tapSize),
      title.leadingAnchor.constraint(equalTo: progress.trailingAnchor, constant: 7),
      title.centerYAnchor.constraint(equalTo: centerYAnchor),
      chevron.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 6),
      chevron.centerYAnchor.constraint(equalTo: title.centerYAnchor),
      chevron.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -6),
      badge.centerYAnchor.constraint(equalTo: title.centerYAnchor),
      trailingConstraint,
      hit.topAnchor.constraint(equalTo: topAnchor),
      hit.bottomAnchor.constraint(equalTo: bottomAnchor),
    ] + hitPin.constraints + [
    ])
  }

  required init?(coder: NSCoder) { fatalError("KitProjectTargetCell is code-only") }

  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + SeptaskKitLayout.rowLeadingPad
    trailingConstraint.constant = -(inset + 8)
    hitPin.update(width: bounds.width)
    super.layout()
  }

  func configure(title titleText: String, progress progressValue: Double, count: Int) {
    self.progress.image = KitGlyph.progress(progressValue, diameter: 13)
    title.attributedStringValue = NSAttributedString(
      string: titleText,
      attributes: [
        .font: NSFont.systemFont(ofSize: SeptenaTypeScale.size(.body) + 1,
                                 weight: .semibold),
        .foregroundColor: NSColor.labelColor,
      ])
    title.toolTip = titleText
    badge.font = SeptaskKitTheme.meta
    badge.stringValue = count > 0 ? String(count) : ""
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
      equalTo: leadingAnchor, constant: KitCardRowView.horizontalInset + SeptaskKitLayout.rowLeadingPad)
    trailingConstraint = time.trailingAnchor.constraint(
      equalTo: trailingAnchor, constant: -(KitCardRowView.horizontalInset + 8))
    NSLayoutConstraint.activate([
      leadingConstraint,
      dot.centerYAnchor.constraint(equalTo: centerYAnchor),
      // The checkbox's tap column — the dot "where the checkbox would be"
      // shares its center, and the title starts where a task title does.
      dot.widthAnchor.constraint(equalToConstant: KitCheckboxView.tapSize),
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
    leadingConstraint.constant = inset + SeptaskKitLayout.rowLeadingPad
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
/// ring, plus its name at a larger rung than an in-list group header. When the
/// sidebar is collapsed (`showsNavMenu == true`), the title IS the navigation
/// dropdown (Things-style, matching SwiftUI's `TaskNavMenu`/
/// `ScreenTitleMenuLabel`); when the sidebar is visible, it renders as a plain
/// static heading without the chevron or menu popup.
@MainActor
final class KitScreenTitleCell: NSTableCellView {
  private let icon = NSImageView()
  private let emoji = NSTextField(labelWithString: "")
  /// The title + chevron ARE the control when the sidebar is collapsed — a real
  /// `NSButton`, not a label with hand-tracked mouse handling. Three attempts
  /// to make a custom view receive this click failed at the event layer (a
  /// click recognizer, then mouseDown/mouseUp overrides, then a `hitTest`
  /// override); an `NSControl` is what `NSTableView` is built to host in a
  /// cell, and it brings its own tracking, highlight, accessibility, and
  /// keyboard activation. This is the "use standard components, never get
  /// creative" rule in CLAUDE.md, arrived at the hard way.
  private let button = NSButton()
  /// Plain static heading shown instead of `button` while the sidebar is
  /// visible on screen — full-strength label ink, no chevron, no press
  /// highlight, and static-text accessibility.
  private let titleLabel = NSTextField(labelWithString: "")
  private var showsNavMenu = false
  /// Glyph CENTER on the checkbox axis (`SeptaskKitLayout.leadingGlyphCenterX`).
  private var leadingConstraint: NSLayoutConstraint!
  /// Title button leading, pinned to the content inset — independent of the
  /// glyph, so re-centering the glyph never moves the title.
  private var buttonLeadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!
  private var labelTrailingConstraint: NSLayoutConstraint!
  /// Builds the dropdown fresh on every click — see the call site's comment
  /// on why this isn't built once and cached. Optional-returning to match
  /// the `[weak self]` closure the controller wires it up with.
  var onOpenNavMenu: (() -> NSMenu?)?
  /// An area page's glyph opens the emoji picker, anchored on the glyph — the
  /// same affordance as the SwiftUI area page's icon button. Nil on every
  /// other page, which leaves the glyph inert.
  var onPickGlyph: ((NSView) -> Void)? {
    didSet { glyphButton.isHidden = onPickGlyph == nil }
  }
  /// A borderless, title-less `NSButton` over the glyph slot — an
  /// `NSControl` for the same reason as `button` above.
  private let glyphButton = NSButton()
  /// Project page trailing `…` overflow menu button (New Section, New Task —
  /// #209). Hidden on every non-project page.
  var onOpenOverflowMenu: (() -> NSMenu?)? {
    didSet {
      moreButton.isHidden = onOpenOverflowMenu == nil
      window?.invalidateCursorRects(for: self)
    }
  }
  private let moreButton = NSButton()
  private var moreTrailingConstraint: NSLayoutConstraint!

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
    button.isHidden = true

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = Self.font
    titleLabel.textColor = .labelColor
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.maximumNumberOfLines = 1
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    glyphButton.translatesAutoresizingMaskIntoConstraints = false
    glyphButton.isBordered = false
    glyphButton.bezelStyle = .inline
    glyphButton.title = ""
    glyphButton.target = self
    glyphButton.action = #selector(pickGlyph)
    glyphButton.refusesFirstResponder = true
    glyphButton.isHidden = true
    glyphButton.setAccessibilityLabel(RegistryActions.title(.areaChangeEmoji))

    moreButton.translatesAutoresizingMaskIntoConstraints = false
    moreButton.isBordered = false
    moreButton.bezelStyle = .inline
    moreButton.title = ""
    moreButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
    moreButton.imagePosition = .imageOnly
    moreButton.contentTintColor = SeptaskKitTheme.inkSecondary
    moreButton.target = self
    moreButton.action = #selector(openOverflowMenu)
    moreButton.refusesFirstResponder = true
    moreButton.isHidden = true
    moreButton.toolTip = RegistryActions.title(.sectionNew)
    moreButton.setAccessibilityLabel(RegistryActions.title(.sectionNew))

    icon.kitA11yIgnore()
    emoji.kitA11yIgnore()

    addSubview(icon)
    addSubview(emoji)
    addSubview(button)
    addSubview(titleLabel)
    addSubview(glyphButton)
    addSubview(moreButton)
    leadingConstraint = icon.centerXAnchor.constraint(
      equalTo: leadingAnchor,
      constant: KitCardRowView.horizontalInset + SeptaskKitLayout.leadingGlyphCenterX)
    buttonLeadingConstraint = button.leadingAnchor.constraint(
      equalTo: leadingAnchor,
      constant: KitCardRowView.horizontalInset + SeptaskKitLayout.screenTitleLeading)
    moreTrailingConstraint = moreButton.trailingAnchor.constraint(
      equalTo: trailingAnchor, constant: -(KitCardRowView.horizontalInset + 8))
    trailingConstraint = button.trailingAnchor.constraint(
      lessThanOrEqualTo: moreButton.leadingAnchor, constant: -6)
    labelTrailingConstraint = titleLabel.trailingAnchor.constraint(
      lessThanOrEqualTo: moreButton.leadingAnchor, constant: -6)
    NSLayoutConstraint.activate([
      leadingConstraint,
      buttonLeadingConstraint,
      icon.centerYAnchor.constraint(equalTo: button.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 18),
      emoji.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
      emoji.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
      glyphButton.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
      glyphButton.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
      glyphButton.widthAnchor.constraint(equalToConstant: 28),
      glyphButton.heightAnchor.constraint(equalToConstant: 28),
      moreTrailingConstraint,
      moreButton.centerYAnchor.constraint(equalTo: button.centerYAnchor),
      moreButton.widthAnchor.constraint(equalToConstant: 28),
      moreButton.heightAnchor.constraint(equalToConstant: 28),
      button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
      trailingConstraint,
      titleLabel.leadingAnchor.constraint(equalTo: button.leadingAnchor),
      titleLabel.firstBaselineAnchor.constraint(equalTo: button.firstBaselineAnchor),
      labelTrailingConstraint,
    ])
  }

  required init?(coder: NSCoder) { fatalError("KitScreenTitleCell is code-only") }

  @objc private func pickGlyph() {
    onPickGlyph?(glyphButton)
  }

  @objc private func openOverflowMenu() {
    guard let menu = onOpenOverflowMenu?() else { return }
    menu.popUp(positioning: nil,
               at: NSPoint(x: 0, y: -4),
               in: moreButton)
  }

  /// Fired by the button's own target/action — no hand-tracked mouse handling.
  @objc private func openNavMenu() {
    guard showsNavMenu, let menu = onOpenNavMenu?() else { return }
    // Dropped from the button's own bottom-left, the standard pull-down
    // geometry. `popUp(positioning:at:in:)` takes the point in the anchor
    // view's coordinates; `NSButton` is unflipped, so its bottom edge is y=0.
    menu.popUp(positioning: nil,
               at: NSPoint(x: 0, y: -4),
               in: button)
  }

  /// The pointing-hand cursor is the platform's "this is a link/button"
  /// signal — matches `KitGroupHeaderCell`'s navigable headers. Scoped to the
  /// BUTTON's frame now, not the whole cell, and only active while the nav
  /// dropdown is enabled (sidebar collapsed).
  override func resetCursorRects() {
    if showsNavMenu {
      addCursorRect(button.frame, cursor: .pointingHand)
    }
    if !moreButton.isHidden {
      addCursorRect(moreButton.frame, cursor: .pointingHand)
    }
  }

  /// Same width-dependent centered-column margin as every other row.
  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + SeptaskKitLayout.leadingGlyphCenterX
    buttonLeadingConstraint.constant = inset + SeptaskKitLayout.screenTitleLeading
    moreTrailingConstraint.constant = -(inset + 8)
    super.layout()
  }

  func setShowsNavMenu(_ shows: Bool) {
    guard showsNavMenu != shows else { return }
    showsNavMenu = shows
    button.isHidden = !shows
    titleLabel.isHidden = shows
    window?.invalidateCursorRects(for: self)
  }

  func configure(title titleText: String,
                 icon iconKind: SeptaskKitTaskListController.GroupIcon,
                 showsNavMenu: Bool) {
    // `attributedTitle`, not `title`: a borderless NSButton otherwise paints
    // its label in the control's default color, which loses the page title's
    // full-strength ink. Populate both the button and the static label so
    // their baselines always match with zero shift when toggling the sidebar.
    let attributed = NSAttributedString(
      string: titleText,
      attributes: [.font: Self.font, .foregroundColor: NSColor.labelColor])
    button.attributedTitle = attributed
    titleLabel.attributedStringValue = attributed
    self.showsNavMenu = showsNavMenu
    button.isHidden = !showsNavMenu
    titleLabel.isHidden = showsNavMenu
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
    // The visible control (`button` when the dropdown is active, `titleLabel`
    // otherwise) is the accessibility element directly.
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
  /// Empty space above the footer text: one group-title row (the same
  /// `17 * factor + 26` a `.header` row is tall).
  static var topGap: CGFloat { 17 * FontScale.shared.factor + 26 }

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
      // Centered in the band below the title-height gap.
      label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: Self.topGap / 2),
      trailingConstraint,
      hit.topAnchor.constraint(equalTo: topAnchor, constant: Self.topGap),
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

  enum Kind { case logged, faded }

  func configure(count: Int, expanded: Bool, kind: Kind = .logged) {
    let text: String
    switch kind {
    case .logged:
      text = expanded
        ? String(localized: "Hide \(count) logged items",
                 comment: "Project/area footer — collapse completed tasks (plural)")
        : String(localized: "Show \(count) logged items",
                 comment: "Project/area footer — expand completed tasks (plural)")
    case .faded:
      if expanded {
        text = count == 1
          ? String(localized: "Hide 1 faded item",
                   comment: "Project/area footer — collapse faded tasks (singular)")
          : String(localized: "Hide \(count) faded items",
                   comment: "Project/area footer — collapse faded tasks (plural)")
      } else {
        text = count == 1
          ? String(localized: "Show 1 faded item",
                   comment: "Project/area footer — expand faded tasks (singular)")
          : String(localized: "Show \(count) faded items",
                   comment: "Project/area footer — expand faded tasks (plural)")
      }
    }
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
      : String(localized: "Import all \(count). Each one leaves Reminders.",
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
      return TaskFilter.today.title
    }
    if cal.isDateInTomorrow(date) {
      return RegistrySurfaces.tomorrowLabel
    }
    return SeptenaDate.monthDay(date)
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
  /// Glyph CENTER on the checkbox axis (`SeptaskKitLayout.leadingGlyphCenterX`).
  private var leadingConstraint: NSLayoutConstraint!
  /// Title leading, pinned to the content inset — independent of the glyph.
  private var titleLeadingConstraint: NSLayoutConstraint!
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
  /// row… so clicks in empty horizontal space don't navigate."
  /// Hidden for a non-navigable header so its clicks reach the table.
  private let hit = NSButton()

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
  /// (`Theme.checkboxTap` = 22 on macOS). Its CENTER is pinned to the
  /// checkbox axis (`SeptaskKitLayout.leadingGlyphCenterX`), so header glyphs
  /// and row checkboxes share one center X; a wider glyph grows equally both
  /// ways, i.e. left of the text column. NOT the glyph's own size: SwiftUI sizes each
  /// icon KIND differently within this column (`TaskListView.groupHeaderBody`
  /// — `AreaIcon(diameter: 21)`, `ProjectProgressIcon(diameter: 14)`, a
  /// system symbol at `.scaledFont(size: 16)`), so `configure` matches those
  /// per case rather than forcing one shared diameter.
  private static let iconColumnWidth: CGFloat = KitCheckboxView.tapSize

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

    addSubview(icon)
    addSubview(emoji)
    addSubview(title)
    addSubview(count)
    // Last, so it layers above the title it covers.
    addSubview(hit)
    textField = title
    icon.kitA11yIgnore()
    emoji.kitA11yIgnore()
    title.kitA11yIgnore()
    count.kitA11yIgnore()
    setAccessibilityElement(true)
    leadingConstraint = icon.centerXAnchor.constraint(
      equalTo: leadingAnchor,
      constant: KitCardRowView.horizontalInset + SeptaskKitLayout.leadingGlyphCenterX)
    titleLeadingConstraint = title.leadingAnchor.constraint(
      equalTo: leadingAnchor,
      constant: KitCardRowView.horizontalInset + SeptaskKitLayout.headerTitleLeading)
    trailingConstraint = count.trailingAnchor.constraint(
      lessThanOrEqualTo: trailingAnchor, constant: -(KitCardRowView.horizontalInset + 8))
    NSLayoutConstraint.activate([
      leadingConstraint,
      icon.centerYAnchor.constraint(equalTo: title.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: Self.iconColumnWidth),
      emoji.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
      emoji.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
      titleLeadingConstraint,
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
    ])
  }

  required init?(coder: NSCoder) { fatalError("KitGroupHeaderCell is code-only") }

  /// Same centered-column margin as the row cells, so the header's left/right
  /// edges line up with the cards below it.
  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + SeptaskKitLayout.leadingGlyphCenterX
    titleLeadingConstraint.constant = inset + SeptaskKitLayout.headerTitleLeading
    trailingConstraint.constant = -(inset + 8)
    super.layout()
  }

  private static func symbolImage(named name: String) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
  }

  /// Spec §3: filled tray → check mark (SF Symbols replace + draw-on effect).
  func playInboxZeroCheckmark() {
    emoji.isHidden = true
    icon.isHidden = false
    icon.contentTintColor = SeptaskKitTheme.inkSecondary
    icon.removeAllSymbolEffects(animated: false)
    if icon.image == nil {
      icon.image = Self.symbolImage(named: InboxZeroMotion.filledTraySymbol)
    }
    if let check = Self.symbolImage(named: InboxZeroMotion.checkmarkSymbol) {
      icon.setSymbolImage(check, contentTransition: .replace)
      icon.addSymbolEffect(.drawOn)
    }
  }

  /// Spec §3 (+0.9 s): check mark → empty tray (`tray`) with replace transition.
  func finishInboxZeroToEmptyTray() {
    emoji.isHidden = true
    icon.isHidden = false
    icon.contentTintColor = SeptaskKitTheme.inkSecondary
    icon.removeAllSymbolEffects(animated: false)
    if let emptyTray = Self.symbolImage(named: InboxZeroMotion.emptyTraySymbol) {
      icon.setSymbolImage(emptyTray, contentTransition: .replace)
    }
  }

  /// Spec §5: cancel any in-flight motion straight to the resting symbol with
  /// no reverse animation.
  func cancelInboxZeroMotion(symbolName: String) {
    emoji.isHidden = true
    icon.isHidden = false
    icon.contentTintColor = SeptaskKitTheme.inkSecondary
    icon.removeAllSymbolEffects(animated: false)
    icon.image = Self.symbolImage(named: symbolName)
  }

  func configure(title titleText: String,
                 icon iconKind: SeptaskKitTaskListController.GroupIcon,
                 count countValue: Int,
                 isNavigable: Bool,
                 keepAnimatedCheckmark: Bool = false) {
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
    if keepAnimatedCheckmark {
      icon.contentTintColor = SeptaskKitTheme.inkSecondary
      if icon.image == nil {
        icon.image = Self.symbolImage(named: InboxZeroMotion.checkmarkSymbol)
      }
    } else {
      icon.removeAllSymbolEffects(animated: false)
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
        icon.image = Self.symbolImage(named: name)
        icon.contentTintColor = SeptaskKitTheme.inkSecondary
      }
    }
    if isNavigable {
      kitA11yButton(label: titleText)
    } else {
      kitA11yHeader(label: titleText)
    }
    // A recycled cell keeps the previous row's overlay state otherwise, which
    // would make a plain "Inbox" header swallow clicks the table should get.
    hit.isHidden = !isNavigable
    // Reused cells carry a stale cursor rect otherwise — a scrolled-in
    // non-navigable header could keep the pointing-hand from whatever row
    // used to occupy this recycled view.
    window?.invalidateCursorRects(for: self)
  }

  @objc private func fire() { onTap?() }

  override func accessibilityPerformPress() -> Bool {
    guard onTap != nil else { return false }
    onTap?()
    return true
  }

  /// The pointing-hand cursor is the platform's "this text is a link/button"
  /// signal — it's what makes "clickable" discoverable without a hover state
  /// to lean on in an `NSTableCellView`.
  override func resetCursorRects() {
    // The title text, and only it. A cursor rect does NOT go through
    // hit-testing, so anything wider would advertise dead space as clickable;
    // that false signal is what cost three rounds of debugging in the
    // 2026-08-09 pass. `isHidden` stands in for "is this header navigable".
    if !hit.isHidden { addCursorRect(hit.frame, cursor: .pointingHand) }
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
       calendar.isDate(date, inSameDayAs: tomorrow) { return RegistrySurfaces.tomorrowLabel }
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

/// Keyboard seam: the registry shortcut equivalents intercept on the
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
  /// ⌘↩ — commit and close the open row, from wherever the caret is.
  var onCommitEditing: (() -> Void)?
  /// ⌥↩ — open a closed selected row straight into its notes.
  var onOpenNotes: (() -> Void)?
  var onDelete: (() -> Void)?
  var onNewTask: (() -> Void)?
  var onWhen: (() -> Void)?
  var onDeadline: (() -> Void)?
  var onClearSchedule: (() -> Void)?
  var onToggleInspector: (() -> Void)?
  var onQuickFind: (() -> Void)?
  var onDuplicate: (() -> Void)?
  var onMove: (() -> Void)?
  /// ⌥⌘M — file the selection into its suggested list (the row capsule's pick).
  var onFileSuggested: (() -> Void)?
  var onReminder: (() -> Void)?
  var onToggleStar: (() -> Void)?
  var onEditTags: (() -> Void)?
  var onAddChecklistItem: (() -> Void)?
  var onClearTagFilter: (() -> Bool)?
  var onPasteAttachment: (() -> Bool)?
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
  /// ⌘↑ (true) / ⌘↓ (false) — move the selection one slot.
  var onMoveSelection: ((Bool) -> Void)?
  /// The inline composer is open — decides which commands still reach a row
  /// while one of ITS text views holds the caret.
  var isComposing: (() -> Bool)?

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

  /// Where the keyboard is, as far as row commands are concerned.
  private enum TextFocus {
    /// No text view holds the caret — every row command applies.
    case noText
    /// A text view OUTSIDE this table (inspector, sidebar rename, a search
    /// field). `performKeyEquivalent` walks the whole window, so without this
    /// the list would steal ⌘K / ⌘⌫ / ⌘R from text the user is typing there.
    case elsewhere
    /// The open composer's title or notes.
    case composer
    /// A bare field editor in a row (⌘R rename, "New task" line, header "+").
    case fieldEditor
  }

  private var textFocus: TextFocus {
    guard let text = window?.firstResponder as? NSText else { return .noText }
    guard text.isDescendant(of: self) else { return .elsewhere }
    return isComposing?() == true ? .composer : .fieldEditor
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    // Only the four real modifiers: arrows carry `.function` / `.numericPad`,
    // and Caps Lock must not turn ⌘K into an unknown chord.
    let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
    let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
    let focus = textFocus

    // Typing elsewhere in the window: none of this list's bindings apply.
    if focus == .elsewhere { return super.performKeyEquivalent(with: event) }

    // While a text view in a row holds the caret, only commands that make
    // sense mid-edit get through, and each saves what was typed first (the
    // controller does that). Everything else — ⌘⌫ (delete to line start),
    // ⌘↑/⌘↓, ⌘R, ⌘D … — belongs to the text.
    if focus != .noText {
      let composer = focus == .composer
      let command = flags == .command
      let commandShift = flags == [.command, .shift]
      let commandOption = flags == [.command, .option]
      let allowed: Bool
      if command, ["\r", "\u{3}", "n", ","].contains(key) {
        allowed = true            // ⌘↩ save + close, ⌘N save then create, ⌘, settings
      } else if (commandShift && key == "f") || (commandOption && key == "i") {
        allowed = true            // Quick Find, inspector: window-level, no row write
      } else if (command && ["k", "t", "s", "m"].contains(key))
                  || (commandShift && ["m", "d", "c"].contains(key))
                  || (commandOption && ["r", "s"].contains(key)) {
        allowed = composer        // act on the composing row (text saved first)
      } else {
        allowed = false
      }
      guard allowed else { return super.performKeyEquivalent(with: event) }
    }

    // ⌘↑ / ⌘↓ — keyboard reorder. Arrow keys report their function-key
    // characters, never letters.
    if flags == [.command], let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first {
      switch Int(scalar.value) {
      case NSUpArrowFunctionKey: onMoveSelection?(true); return true
      case NSDownArrowFunctionKey: onMoveSelection?(false); return true
      default: break
      }
    }

    if flags == [.command, .option] {
      switch key {
      // ⌥⌘I — the platform's inspector toggle.
      case "i": onToggleInspector?(); return true
      // ⌥⌘M — file into the SUGGESTED list, deliberately one modifier from
      // ⌘M (Move…): same family — both answer "where does this go?" — but the
      // suggested one commits without a picker, so it must be impossible to
      // hit by accident. Same relationship ⌥⌘K has to ⌘K.
      case "m": onFileSuggested?(); return true
      // ⌥⌘R — set/edit timed reminder (docs/TIMED_REMINDERS_SPEC.md §5).
      case "r": onReminder?(); return true
      // ⌥⌘S — star / unstar selected tasks (docs/STAR_PRIORITY_SPEC.md §3).
      case "s": onToggleStar?(); return true
      default: return super.performKeyEquivalent(with: event)
      }
    }

    // ⌘⇧D / ⌘⇧. — deliberately the shifted forms (bare ⌘. is the system
    // Cancel equivalent), matching the registry shortcuts. ⌘⇧F is Quick Find, the
    // same binding the SwiftUI window uses.
    if flags == [.command, .shift] {
      switch key {
      case "d": onDeadline?(); return true
      case ".": onClearSchedule?(); return true
      case "f": onQuickFind?(); return true
      case "m": onMove?(); return true
      // ⇧⌘C — reveal checklist & insert a step (docs/CHECKLISTS_SPEC.md §4).
      case "c": onAddChecklistItem?(); return true
      // ⇧⌘T — open type-to-assign/create Tag popover (docs/TAGS_SPEC.md §4).
      case "t": onEditTags?(); return true
      default: return super.performKeyEquivalent(with: event)
      }
    }

    guard flags == .command else {
      return super.performKeyEquivalent(with: event)
    }
    switch key {
    // ⌘↩ / ⌘keypad-Enter — save and close the open row (composer or field
    // editor), the platform's "finish this". Caught here rather than in the
    // composer cell so ONE handler covers the caret being in the title, in
    // notes, or on a pill. With nothing open it is not ours: pass it on.
    case "\r", "\u{3}":
      guard isComposing?() == true || focus == .fieldEditor else {
        return super.performKeyEquivalent(with: event)
      }
      onCommitEditing?()
      return true
    case "k": onToggleComplete?(); return true
    case "t": onToggleToday?(); return true
    case "r": onBeginEdit?(); return true
    case "n": onNewTask?(); return true
    case "s": onWhen?(); return true
    case "d": onDuplicate?(); return true
    case "m": onMove?(); return true
    case "v": if onPasteAttachment?() == true { return true }; return super.performKeyEquivalent(with: event)
    case ",": SeptaskKitSettingsWindow.show(); return true
    case "\u{7f}": onDelete?(); return true   // ⌘⌫, matching registry task.delete
    default: return super.performKeyEquivalent(with: event)
    }
  }

  override func keyDown(with event: NSEvent) {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    switch event.keyCode {
    case 36, 76:  // Return / keypad Enter — opens the composer, not a bare rename.
      // ⌥↩ opens the same composer but with the caret already in notes. It
      // arrives here rather than in `performKeyEquivalent` because that only
      // handles command-key combinations; Option alone falls through to the
      // regular key path.
      if flags.contains(.option) { onOpenNotes?() } else { onOpenComposer?() }
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
    if onClearTagFilter?() == true { return }
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

  /// `draggingEnded:` is an OPTIONAL `NSDraggingDestination` method, and
  /// NSTableView does not implement it on macOS 27: an unguarded
  /// `super.draggingEnded` threw "unrecognized selector" and killed the app
  /// at the end of a drag (Inbox row onto a project).
  override func draggingEnded(_ sender: any NSDraggingInfo) {
    if NSTableView.instancesRespond(to: #selector(NSDraggingDestination.draggingEnded(_:))) {
      super.draggingEnded(sender)
    }
    onDragEnded?()
  }
}

// MARK: - Quiet hairline tag capsule & visual in-list tag filter bar (docs/TAGS_SPEC.md)

@MainActor
private final class KitTagChipView: NSView {
  init(name: String, colorToken: String?) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.borderWidth = 0.75
    layer?.borderColor = NSColor.secondaryLabelColor.withAlphaComponent(0.28).cgColor

    let stack = NSStackView()
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 4
    stack.translatesAutoresizingMaskIntoConstraints = false

    if colorToken != nil {
      let dot = NSView()
      dot.wantsLayer = true
      dot.layer?.cornerRadius = 2.5
      dot.layer?.backgroundColor = TagColorPalette.nsColor(for: colorToken).cgColor
      dot.translatesAutoresizingMaskIntoConstraints = false
      dot.widthAnchor.constraint(equalToConstant: 5).isActive = true
      dot.heightAnchor.constraint(equalToConstant: 5).isActive = true
      stack.addArrangedSubview(dot)
    }

    let label = NSTextField(labelWithString: name)
    label.font = .systemFont(ofSize: SeptenaTypeScale.size(.caption1))
    label.textColor = SeptaskKitTheme.inkSecondary
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    stack.addArrangedSubview(label)

    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 1.5),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1.5),
    ])
    setContentHuggingPriority(.required, for: .horizontal)
    setContentCompressionResistancePriority(.required, for: .horizontal)
  }

  required init?(coder: NSCoder) { fatalError("KitTagChipView is code-only") }
}

@MainActor
private final class KitTagFilterBarCell: NSTableCellView {
  var onToggleTag: ((String) -> Void)?
  var onClear: (() -> Void)?

  private let stack = NSStackView()
  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 6
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    leadingConstraint = stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SeptaskKitLayout.rowLeadingPad)
    trailingConstraint = stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
    NSLayoutConstraint.activate([
      leadingConstraint,
      trailingConstraint,
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("KitTagFilterBarCell is code-only") }

  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + SeptaskKitLayout.rowLeadingPad
    trailingConstraint.constant = -(inset + 8)
    super.layout()
  }

  func configure(tags: [TaskTag], activeIDs: Set<String>) {
    for v in stack.arrangedSubviews {
      stack.removeArrangedSubview(v)
      v.removeFromSuperview()
    }
    for tag in tags {
      let isOn = activeIDs.contains(tag.id)
      let pill = KitPillButton()
      pill.title = tag.name
      pill.isOn = isOn
      pill.onPress = { [weak self] _ in self?.onToggleTag?(tag.id) }
      stack.addArrangedSubview(pill)
    }
    if !activeIDs.isEmpty {
      let clear = NSButton()
      clear.isBordered = false
      clear.bezelStyle = .inline
      clear.title = String(localized: "Clear", comment: "SeptaskKit: clear tag filter")
      clear.font = .systemFont(ofSize: SeptenaTypeScale.size(.caption1))
      clear.contentTintColor = SeptaskKitTheme.inkSecondary
      clear.target = self
      clear.action = #selector(clearPressed)
      stack.addArrangedSubview(clear)
    }
  }

  @objc private func clearPressed() {
    onClear?()
  }
}

/// Logbook sub-view bar (issue #202): segmented `Completed | Deleted (N)`
/// switcher + trailing destructive `Empty Trash` action when viewing Deleted.
@MainActor
private final class KitLogbookBarCell: NSTableCellView {
  var onSelectTab: ((SeptaskKitTaskListController.LogbookTab) -> Void)?
  var onEmptyTrash: (() -> Void)?

  private let segmented = NSSegmentedControl(labels: ["", ""], trackingMode: .selectOne, target: nil, action: nil)
  private let emptyTrashButton = NSButton()
  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    segmented.translatesAutoresizingMaskIntoConstraints = false
    segmented.segmentStyle = .automatic
    segmented.controlSize = .regular
    segmented.refusesFirstResponder = true
    segmented.target = self
    segmented.action = #selector(segmentChanged)

    emptyTrashButton.translatesAutoresizingMaskIntoConstraints = false
    emptyTrashButton.isBordered = false
    emptyTrashButton.bezelStyle = .inline
    emptyTrashButton.font = .systemFont(ofSize: SeptenaTypeScale.size(.caption1), weight: .medium)
    emptyTrashButton.contentTintColor = .systemRed
    emptyTrashButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
    emptyTrashButton.imagePosition = .imageLeading
    emptyTrashButton.refusesFirstResponder = true
    emptyTrashButton.target = self
    emptyTrashButton.action = #selector(emptyTrashPressed)

    addSubview(segmented)
    addSubview(emptyTrashButton)

    leadingConstraint = segmented.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SeptaskKitLayout.rowLeadingPad)
    trailingConstraint = emptyTrashButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SeptaskKitLayout.rowLeadingPad)
    NSLayoutConstraint.activate([
      leadingConstraint,
      segmented.centerYAnchor.constraint(equalTo: centerYAnchor),
      trailingConstraint,
      emptyTrashButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      emptyTrashButton.leadingAnchor.constraint(greaterThanOrEqualTo: segmented.trailingAnchor, constant: 12),
    ])
  }

  required init?(coder: NSCoder) { fatalError("KitLogbookBarCell is code-only") }

  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + SeptaskKitLayout.rowLeadingPad
    trailingConstraint.constant = -(inset + SeptaskKitLayout.rowLeadingPad)
    super.layout()
  }

  override func resetCursorRects() {
    if !emptyTrashButton.isHidden {
      addCursorRect(emptyTrashButton.frame, cursor: .pointingHand)
    }
  }

  func configure(tab: SeptaskKitTaskListController.LogbookTab,
                 deletedCount: Int,
                 showsSegmented: Bool,
                 canEmptyTrash: Bool) {
    segmented.isHidden = !showsSegmented
    segmented.setLabel(RegistrySurfaces.quickFindCompletedLabel, forSegment: 0)
    let deletedBase = TaskFilter.recentlyDeleted.title
    let deletedLabel = deletedCount > 0 ? "\(deletedBase) (\(deletedCount))" : deletedBase
    segmented.setLabel(deletedLabel, forSegment: 1)
    segmented.selectedSegment = tab.rawValue

    emptyTrashButton.isHidden = !canEmptyTrash
    let emptyTitle = RegistryActions.title(.taskEmptyTrash)
    emptyTrashButton.attributedTitle = NSAttributedString(
      string: emptyTitle,
      attributes: [
        .font: NSFont.systemFont(ofSize: SeptenaTypeScale.size(.caption1), weight: .medium),
        .foregroundColor: NSColor.systemRed,
      ])
    window?.invalidateCursorRects(for: self)
  }

  @objc private func segmentChanged() {
    guard let tab = SeptaskKitTaskListController.LogbookTab(rawValue: segmented.selectedSegment) else { return }
    onSelectTab?(tab)
  }

  @objc private func emptyTrashPressed() {
    onEmptyTrash?()
  }
}
#endif
