#if os(macOS)
import AppKit
import SwiftUI

// SeptaskKit — the AppKit shell spike (see docs/SEPTASK.md).
//
// Evaluates porting SeptaskMac's keyboard surfaces to AppKit: a native
// NSSplitViewController window (NSOutlineView sidebar + NSTableView task list)
// over the exact same core seam the SwiftUI shell uses — LocalCache/
// StructureCache for reads, TaskMutator for writes. Opened side-by-side with
// the SwiftUI window (Go ▸ AppKit Shell) so the keyboard feel can be A/B'd
// against the same live data. No new data paths, no new entitlements.
//
// Deliberately NOT wired into navigation, quick find, or the composer — this
// window exists to answer one question: does native responder-chain keyboard
// handling feel enough better to justify the port.
@MainActor
final class SeptaskKitWindowController: NSWindowController, NSWindowDelegate {
  /// One shell window per process; reopening the menu item fronts it.
  private static var current: SeptaskKitWindowController?

  /// The live shell, if one is open — the menu router's entry point.
  static var existing: SeptaskKitWindowController? { current }

  /// Owned here so the panel outlives each invocation (it keeps its state and
  /// its position between shows).
  private var quickFind: SeptaskKitQuickFind?

  static func show() {
    if let existing = current {
      existing.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = SeptaskKitWindowController()
    current = controller
    controller.window?.makeKeyAndOrderFront(nil)
    // After the window is on screen, so `makeFirstResponder` sticks: keyboard
    // focus starts on the DETAIL pane (the task list), not the sidebar.
    controller.focusDetail()
  }

  /// The pieces the menu bar drives. Held so `SeptaskKitCommands` can route a
  /// menu selection to the shell when its window is the one in front.
  private var list: SeptaskKitTaskListController?
  private var detail: KitDetailPaneController?
  private var inspector: SeptaskKitInspectorController?
  private var sidebar: SeptaskKitSidebarController?
  private var splitController: NSSplitViewController?
  private var inspectorItem: NSSplitViewItem?
  /// Key of the destination on screen, so a sidebar re-emit of the SAME
  /// destination (every structure rebuild re-selects its row) never commits
  /// an open edit or moves focus.
  private var currentDestinationKey: String?
  /// Split-view resize observer (sidebar-hidden mirror). Process-lived like
  /// the window, but removed on close all the same.
  private var layoutObserver: NSObjectProtocol?

  private init() {
    let list = SeptaskKitTaskListController()
    let detail = KitDetailPaneController()
    let sidebar = SeptaskKitSidebarController()
    let inspector = SeptaskKitInspectorController()
    // Tab / Shift-Tab crosses between the two panes — the only two stops in
    // this window's keyboard-nav loop. (`sidebar.onSelect` and
    // `sidebar.onFocusList` are wired below, after `super.init`, since they
    // capture `self`.)
    list.onFocusSidebar = { [weak sidebar] in sidebar?.focusSidebar() }
    detail.display(list)

    list.onStoreChanged = { [weak inspector] in
      inspector?.refresh()
    }

    let split = NSSplitViewController()
    let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
    sidebarItem.minimumThickness = 190
    sidebarItem.maximumThickness = 320
    split.addSplitViewItem(sidebarItem)
    let listItem = NSSplitViewItem(viewController: detail)
    listItem.minimumThickness = 380
    split.addSplitViewItem(listItem)
    // Native inspector pane — collapsed until ⌥⌘I, and it commits any pending
    // note when it closes so nothing typed is lost on collapse.
    let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
    inspectorItem.minimumThickness = 260
    inspectorItem.maximumThickness = 380
    // Restored: the pane opens the way it was left. The same key is the
    // menu's Show/Hide Info mirror, so the two agree from the first frame.
    inspectorItem.isCollapsed = !UserDefaults.standard.bool(
      forKey: SettingsKey.septaskInspectorVisible)
    split.addSplitViewItem(inspectorItem)
    list.onSelectionChange = { [weak inspector, weak inspectorItem] task in
      inspector?.show(task, isVisible: inspectorItem?.isCollapsed == false)
    }
    split.splitView.autosaveName = "SeptaskKitSplit"
    // Keep the View menu's Show/Hide Sidebar title truthful however the pane
    // collapsed (menu, ⌃⌘S, or dragging the divider shut).
    layoutObserver = NotificationCenter.default.addObserver(
      forName: NSSplitView.didResizeSubviewsNotification, object: split.splitView, queue: .main
    ) { [weak sidebarItem] _ in
      MainActor.assumeIsolated {
        guard let sidebarItem else { return }
        let hidden = sidebarItem.isCollapsed
        if UserDefaults.standard.bool(forKey: SeptaskKitStateKey.sidebarHidden) != hidden {
          UserDefaults.standard.set(hidden, forKey: SeptaskKitStateKey.sidebarHidden)
        }
      }
    }
    // Same path Quick Find uses: steer the sidebar, which drives the list —
    // so a group-header click always leaves the two in agreement.
    list.onNavigate = { [weak sidebar] destination in sidebar?.select(destination) }

    let window = KitShellWindow(contentViewController: split)
    window.title = String(localized: "Septena",
                          comment: "SeptaskKit: window title")
    // Full-size content view, so the list scrolls UNDER the title bar and the
    // sidebar runs the whole window height — plus a toolbar, which is what
    // gives that bar its MATERIAL. The toolbar frosts the band and adds the
    // automatic hairline separator once content is under it, instead of
    // letting rows collide with the title; and it splits correctly over a
    // `.sidebar` split item (sidebar material on the left, content material
    // over the list), which a bare `titlebarAppearsTransparent` bar cannot do.
    // The toolbar carries no items on purpose: it exists for the title, the
    // material, and the drag region.
    let toolbar = NSToolbar(identifier: "SeptaskKitToolbar")
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    window.toolbar = toolbar
    window.toolbarStyle = .unified

    // Sync status rides a TITLEBAR ACCESSORY, not a toolbar item. The toolbar
    // above is deliberately item-less (title, material, drag region), and
    // giving it one item means giving it a delegate and an item vocabulary it
    // otherwise has no use for. An accessory reaches the same strip of chrome
    // and stays out of that decision. `SyncIndicator` draws nothing when idle,
    // so the accessory collapses to zero width between syncs; it only takes
    // space while a fetch/send is in flight, or during the first-run download
    // where it also carries the running item count.
    let syncHost = NSHostingView(
      rootView: SyncIndicator()
        .environment(SeptenaServices.shared.ckEngine)
        .padding(.trailing, 12)
    )
    syncHost.frame.size = syncHost.fittingSize
    let syncAccessory = NSTitlebarAccessoryViewController()
    syncAccessory.view = syncHost
    syncAccessory.layoutAttribute = .trailing
    window.addTitlebarAccessoryViewController(syncAccessory)
    // The title names the DESTINATION ("Today", a project) — the same
    // string the SwiftUI shell puts in its page header. Hiding it left nothing
    // to name the window: the list ran straight to the top edge and the drag
    // strip read as a row of tasks. `SeptaskKitTaskListController` reveals and
    // hides it against its own in-content page title; the string set here only
    // covers the frame before the sidebar picks its default.
    window.titleVisibility = .visible
    window.styleMask.insert(.fullSizeContentView)
    window.setContentSize(NSSize(width: 980, height: 700))
    window.center()
    window.setFrameAutosaveName("SeptaskKitWindow")
    super.init(window: window)
    window.delegate = self
    self.list = list
    self.detail = detail
    self.sidebar = sidebar
    self.splitController = split
    self.inspector = inspector
    self.inspectorItem = inspectorItem
    self.toggleInspector = { [weak list] in list?.onToggleInspector?() }

    // Wired after super.init — capturing `self` in the closures below would
    // be "used before super.init".

    // Quick Find steers the sidebar, which drives the detail — so a jump
    // always leaves the two in agreement — then selects the row it found.
    let quickFind = SeptaskKitQuickFind { [weak self] destination in
      guard let self else { return }
      self.sidebar?.select(destination.filter)
      if let taskId = destination.taskId {
        self.list?.select(taskId: taskId)
      } else {
        self.focusDetail()
      }
    }
    self.quickFind = quickFind
    list.onQuickFind = { [weak quickFind] in quickFind?.show() }

    sidebar.onSelect = { [weak self] destination in
      self?.show(destination)
    }
    // Return / Tab / a mouse click in the sidebar hand the keyboard to
    // the task list in the detail pane.
    sidebar.onFocusList = { [weak self] in self?.focusDetail() }
    list.onToggleInspector = { [weak self] in
      self?.setInspector(visible: inspectorItem.isCollapsed, focusTitle: true)
    }
    // Escape inside the pane closes it — the inspector owns no chrome of its
    // own, so the shell that added the split item does the closing.
    inspector.onRequestClose = { [weak self] in
      self?.setInspector(visible: false)
    }
    // ⌘↩ / Esc / Return in the pane's title or notes commits and returns the
    // keyboard to the list — the pane stays open, following the selection.
    inspector.onRequestFocusList = { [weak list] in list?.focusList() }
    // ⌘↩ is caught at the WINDOW, ahead of every view's key equivalents, so
    // the task table can never swallow it while the inspector holds focus.
    window.onCommandReturn = { [weak inspector] in
      inspector?.handleCommandReturn() ?? false
    }

    // The SwiftUI root normally starts the runtime; harmless if already up
    // (start() memoizes), load-bearing if this window somehow opens first.
    Task { await SeptenaServices.shared.start() }
    // Restore the list that was showing last time; Today when it is gone.
    // That fallback also covers a saved "next" from before Septask's Next
    // page was removed (2026-11-19): no row has that key any more.
    if let key = UserDefaults.standard.string(forKey: SeptaskKitStateKey.lastDestination),
       sidebar.select(key: key) {
      // Selected — `onSelect` already showed it.
    } else {
      sidebar.selectDefault()
    }
  }

  /// Sidebar → detail. Every destination is a task list in the NSTableView.
  private func show(_ destination: KitSidebarDestination) {
    let changed = destination.key != currentDestinationKey
    // Was the keyboard in the detail pane (or nowhere)? Then it follows the
    // destination. Arrowing through the sidebar keeps it in the sidebar, and a
    // structure rebuild (same destination) never moves it.
    let detailHadFocus: Bool = {
      guard let responder = window?.firstResponder else { return true }
      if responder === window { return true }
      guard let view = responder as? NSView, let detailView = detail?.view else { return false }
      return view.isDescendant(of: detailView)
    }()
    if changed {
      // Leaving a list saves whatever row is open in it (composer or
      // rename), and whatever the inspector holds — navigation never drops
      // typed text.
      list?.commitOpenEdits()
      inspector?.flushPendingEdits()
      currentDestinationKey = destination.key
      UserDefaults.standard.set(destination.key, forKey: SeptaskKitStateKey.lastDestination)
    }
    switch destination {
    case .filter(let filter, let title):
      guard let list, let detail else { return }
      // The title is set HERE, not inside `list.show`, which returns early
      // when the destination is already current.
      window?.title = title
      detail.display(list)
      list.show(filter)
      // Ahead of the first scroll event, so a fresh page starts in the right
      // state.
      list.syncWindowTitle()
    }
    if changed, detailHadFocus { focusDetail() }
  }

  /// Give the keyboard to the detail pane — the task list.
  func focusDetail() {
    list?.focusList()
  }

  /// Save every open editor in the window: the list's open row (composer or
  /// rename) and the inspector's fields. Called on window close and on quit,
  /// where no blur happens to commit them.
  func commitAllEdits() {
    inspector?.flushPendingEdits()
    list?.commitOpenEdits()
  }

  /// One place that opens and closes the inspector, so every path — ⌥⌘I, the
  /// menu item, Escape inside the pane — commits pending
  /// edits, hands focus back to the list, and leaves the menu title truthful.
  private func setInspector(visible: Bool, focusTitle: Bool = false) {
    guard let inspectorItem else { return }
    if !visible {
      inspector?.flushPendingEdits()
    }
    inspectorItem.animator().isCollapsed = !visible
    UserDefaults.standard.set(visible, forKey: SettingsKey.septaskInspectorVisible)
    // Collapsing a pane that holds key focus leaves the window with nowhere to
    // type; the list is where the person was before they opened it.
    if !visible,
       let responder = window?.firstResponder as? NSView,
       responder.isDescendant(of: inspectorItem.viewController.view) {
      list?.focusList()
    }
    if visible {
      inspector?.noteBecameVisible()
    }
    // Opening from the keyboard (⌥⌘I / Show Info) is a request to edit:
    // the title takes the keyboard. Next run-loop turn, once the pane is
    // un-collapsed and its fields can become first responder.
    if visible, focusTitle {
      DispatchQueue.main.async { [weak self] in self?.inspector?.focusTitle() }
    }
  }

  // MARK: - Menu-bar surface

  private var toggleInspector: (() -> Void)?

  /// True while this shell owns the menu bar — i.e. its window is key. The
  /// SwiftUI window publishes its own focused actions, so the two never both
  /// claim a command.
  var isFrontmost: Bool { window?.isKeyWindow == true }

  /// Bring the shell forward — used by the navigation commands, which can now
  /// fire while a panel or the Settings window is key.
  func focusWindow() { window?.makeKeyAndOrderFront(nil) }

  func go(to filter: TaskFilter) { sidebar?.select(filter) }
  func newTask() { list?.createTask() }
  func newProject() { sidebar?.newProject() }
  func newArea() { sidebar?.newArea() }
  func showQuickFind() { quickFind?.show() }
  func showInspector() { toggleInspector?() }
  func toggleSidebar() {
    splitController?.toggleSidebar(nil)
  }
  func toggleSidebarCounts() { sidebar?.toggleShowsCounts() }

  /// Whether a Task-menu row command has a target. The menu acts on the pane
  /// that holds the keyboard: on the sidebar only Rename and Delete exist
  /// (for an area or project), and otherwise
  /// the list's selection decides.
  /// The caret is in a text view or field editor anywhere in the window. The
  /// list's own key handling already passes text keys through; this keeps the
  /// Task menu's copies of the same shortcuts from firing behind the caret.
  private var editingText: NSTextView? { window?.firstResponder as? NSTextView }

  func canRun(_ command: RowCommand) -> Bool {
    if editingText != nil { return false }
    if let sidebar, sidebar.hasKeyboardFocus {
      switch command {
      case .rename, .delete: return sidebar.selectionIsStructure
      default: return false
      }
    }
    // ⌘K also ticks a selected Get started step; nothing else applies to one.
    if command == .toggleComplete { return list?.hasCompletableSelection ?? false }
    return list?.hasActionableSelection ?? false
  }

  func rowCommand(_ command: RowCommand) {
    // A menu key equivalent wins over the text view's own key bindings, so a
    // stale enabled Delete item would swallow ⌘⌫ while typing. Give the text
    // its standard meaning (delete to the start of the line) instead.
    if let text = editingText {
      if command == .delete { text.deleteToBeginningOfLine(nil) }
      return
    }
    guard canRun(command), let list else { return }
    if let sidebar, sidebar.hasKeyboardFocus {
      switch command {
      case .rename: sidebar.renameSelectedItem()
      case .delete: sidebar.deleteSelectedItem()
      default: break
      }
      return
    }
    switch command {
    case .toggleComplete: list.toggleCompleteSelection()
    case .cancel: list.cancelSelection()
    case .toggleToday: list.toggleTodaySelection()
    case .toggleStar: list.toggleStarSelection()
    case .rename: list.beginEditSelectedRow()
    case .when: list.presentDatePopover(kind: .when)
    case .deadline: list.presentDatePopover(kind: .deadline)
    case .reminder: list.presentReminderPopover()
    case .clearSchedule: list.clearScheduleSelection()
    case .delete: list.deleteSelection()
    case .repeatEditor: list.presentRecurrencePanel()
    case .createNextCopy: list.createNextCopySelection()
    case .duplicate: list.duplicateSelection()
    case .move: list.presentMoveMenu()
    }
  }

  enum RowCommand {
    case toggleComplete, cancel, toggleToday, toggleStar, rename, when, deadline, reminder, clearSchedule, delete
    case duplicate, move, createNextCopy
    case repeatEditor
  }

  required init?(coder: NSCoder) { fatalError("SeptaskKitWindowController is code-only") }

  func windowWillClose(_ notification: Notification) {
    // ⌘W blurs nothing, so nothing commits on its own: save first.
    commitAllEdits()
    if let layoutObserver { NotificationCenter.default.removeObserver(layoutObserver) }
    layoutObserver = nil
    Self.current = nil
  }

  /// The window's undo manager is the ONE shared task stack, whatever pane
  /// holds focus — ⌘Z must not depend on whether the sidebar, the list or
  /// the inspector was clicked last. Text editors that want local typing
  /// undo supply their own manager ahead of this one (the composer's and the
  /// inspector's `textUndo`).
  func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
    TaskUndo.manager
  }
}

/// The shell's window. Exists for one hook: ⌘↩ is routed to the inspector
/// BEFORE the view hierarchy's key equivalents run. `NSWindow` walks its views
/// in order, and the task table (earlier in the split than the inspector)
/// answers ⌘↩ for its own composer — so a key equivalent on the inspector's
/// own view could be shadowed. The window asks first; when the inspector does
/// not hold the keyboard it declines and the normal path runs.
@MainActor
final class KitShellWindow: NSWindow {
  var onCommandReturn: (() -> Bool)?

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let isReturn = event.keyCode == 36 || event.keyCode == 76
    if isReturn, flags.contains(.command),
       flags.isDisjoint(with: [.shift, .option, .control]),
       onCommandReturn?() == true {
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}



/// Stable UserDefaults keys for the AppKit shell's own window state. Local to
/// the shell (the SwiftUI shell restores through its scene storage). Top-level
/// and non-isolated so the SwiftUI menu's `@AppStorage` can name them.
enum SeptaskKitStateKey {
  /// `KitSidebarDestination.key` of the last list shown — restored at launch.
  static let lastDestination = "septaskKitLastDestination"
  /// Mirror of the sidebar split item's collapsed state, so View ▸
  /// Show/Hide Sidebar can name the action it will take.
  static let sidebarHidden = "septaskKitSidebarHidden"
}

/// Hosts the middle split pane's child (the task list) with manual
/// containment. It swapped between the list and the Next page until Septask's
/// Next was removed (2026-11-19); kept as the seam for any future second pane.
@MainActor
private final class KitDetailPaneController: NSViewController {
  private weak var current: NSViewController?

  override func loadView() {
    view = NSView()
  }

  func display(_ child: NSViewController) {
    if current === child { return }
    if let current {
      // Manual containment (`addChild`/`addSubview`, not one of AppKit's
      // built-in container APIs) doesn't forward appearance transitions on
      // its own — has to be done by hand here, or an `NSHostingController`
      // child never gets its `viewDidAppear`, which is what actually starts
      // its SwiftUI content running (`.task`/`.onAppear` never fire without
      // it). The task list controller never needed this (pure AppKit, no
      // SwiftUI lifecycle dependency) — this only bit once a hosted SwiftUI
      // controller (`SeptaskKitNextController`) became a second thing this
      // swaps to: the page rendered permanently blank, `.task` never having
      // fired to load its data.
      current.viewWillDisappear()
      current.view.removeFromSuperview()
      current.removeFromParent()
      current.viewDidDisappear()
    }
    addChild(child)
    child.view.translatesAutoresizingMaskIntoConstraints = false
    child.viewWillAppear()
    view.addSubview(child.view)
    NSLayoutConstraint.activate([
      child.view.topAnchor.constraint(equalTo: view.topAnchor),
      child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    child.viewDidAppear()
    current = child
  }
}

/// Menu-bar routing for the AppKit shell.
///
/// The app's menus are still SwiftUI `Commands`, which act on the focused
/// SwiftUI scene. With the shell as the default window there usually is no
/// such scene, so each command falls back to here — one menu bar, either
/// shell, no duplicate items.
@MainActor
enum SeptaskKitCommands {
  private static var shell: SeptaskKitWindowController? {
    let controller = SeptaskKitWindowController.existing
    return controller?.isFrontmost == true ? controller : nil
  }

  /// A command with no SwiftUI scene to act on is enabled when the shell can
  /// take it — otherwise the whole menu reads as dead.
  static var canHandle: Bool { shell != nil }

  /// Navigation targets the shell whenever one EXISTS, not only when its
  /// window is key. Keying it to `isKeyWindow` is what made ⌘1–4 look
  /// unreliable: Quick Find, Quick Entry and the Move panel are all
  /// `NSPanel`s with `canBecomeKey`, and the Settings window is a window of
  /// its own, so while any of them was up the shell was not key, `canHandle`
  /// was false, and the whole Go menu greyed out. Row commands deliberately
  /// stay keyed to the frontmost shell — those act on a selection, and acting
  /// on a list you cannot see is worse than a disabled menu item.
  static var canNavigate: Bool { shellExists }

  /// A shell exists, frontmost or not. Used by commands that stay available
  /// from an auxiliary window (Settings, opened over the shell).
  static var shellExists: Bool { SeptaskKitWindowController.existing != nil }
  static func canRun(_ command: SeptaskKitWindowController.RowCommand) -> Bool {
    shell?.canRun(command) ?? false
  }

  /// Fronts the shell before navigating: the command can now arrive while a
  /// panel or the Settings window holds key, and changing the list behind a
  /// panel that stays up would leave the user looking at the wrong thing.
  static func go(_ filter: TaskFilter) {
    guard let controller = SeptaskKitWindowController.existing else { return }
    controller.focusWindow()
    controller.go(to: filter)
  }
  static func newTask() { shell?.newTask() }
  static func newProject() { shell?.newProject() }
  static func newArea() { shell?.newArea() }
  static func quickFind() { shell?.showQuickFind() }
  static func showInspector() { shell?.showInspector() }
  static func toggleSidebar() { shell?.toggleSidebar() }
  static func toggleSidebarCounts() { shell?.toggleSidebarCounts() }
  static func row(_ command: SeptaskKitWindowController.RowCommand) {
    shell?.rowCommand(command)
  }
}
#endif
