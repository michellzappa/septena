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
    // focus starts on the TASK LIST, not the sidebar.
    controller.list?.focusList()
  }

  /// The pieces the menu bar drives. Held so `SeptaskKitCommands` can route a
  /// menu selection to the shell when its window is the one in front.
  private var list: SeptaskKitTaskListController?
  private var next: SeptaskKitNextController?
  private var detail: KitDetailPaneController?
  private var inspector: SeptaskKitInspectorController?
  private var sidebar: SeptaskKitSidebarController?
  private var splitController: NSSplitViewController?
  private var inspectorItem: NSSplitViewItem?

  private init() {
    let list = SeptaskKitTaskListController()
    let next = SeptaskKitNextController()
    let detail = KitDetailPaneController()
    let sidebar = SeptaskKitSidebarController()
    let inspector = SeptaskKitInspectorController()
    // Tab / Shift-Tab crosses between the two panes — the only two stops in
    // this window's keyboard-nav loop. (`sidebar.onSelect` itself is wired
    // below, after `super.init`, since `show(_:)` captures `self`.)
    sidebar.onFocusList = { [weak list] in list?.focusList() }
    list.onFocusSidebar = { [weak sidebar] in sidebar?.focusSidebar() }
    detail.display(list)

    list.onSelectionChange = { [weak inspector] task in
      inspector?.show(task)
    }
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
    // note when it closes so nothing typed is lost on collapse. Hidden while
    // Next is showing (no task selection to inspect).
    let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
    inspectorItem.minimumThickness = 260
    inspectorItem.maximumThickness = 380
    inspectorItem.isCollapsed = true
    // The pane always builds collapsed, so the menu's mirror starts false.
    UserDefaults.standard.set(false, forKey: SettingsKey.septaskInspectorVisible)
    split.addSplitViewItem(inspectorItem)
    split.splitView.autosaveName = "SeptaskKitSplit"

    // Quick Find steers the sidebar, which drives the detail — so a jump
    // always leaves the two in agreement — then selects the row it found.
    let quickFind = SeptaskKitQuickFind { [weak sidebar, weak list] destination in
      sidebar?.select(destination.filter)
      if let taskId = destination.taskId {
        list?.select(taskId: taskId)
      }
    }
    list.onQuickFind = { [weak quickFind] in quickFind?.show() }
    // Same path Quick Find uses: steer the sidebar, which drives the list —
    // so a group-header click always leaves the two in agreement.
    list.onNavigate = { [weak sidebar] destination in sidebar?.select(destination) }
    // The Next page's title dropdown is the same affordance on a SwiftUI page,
    // so it lands in the same place — a `Route`, because that's the vocabulary
    // `TaskNavMenu` speaks.
    next.onNavigate = { [weak sidebar] route in sidebar?.select(route) }

    let window = NSWindow(contentViewController: split)
    window.title = String(localized: "Septask (AppKit)",
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
    // The title names the DESTINATION ("Today", "Next", a project) — the same
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
    self.next = next
    self.detail = detail
    self.sidebar = sidebar
    self.splitController = split
    self.inspector = inspector
    self.inspectorItem = inspectorItem
    self.quickFind = quickFind
    self.toggleInspector = { [weak list] in list?.onToggleInspector?() }

    // Wired after super.init — capturing `self` in the closures below would
    // be "used before super.init".
    sidebar.onSelect = { [weak self] destination in
      self?.show(destination)
    }
    list.onToggleInspector = { [weak self] in
      self?.setInspector(visible: inspectorItem.isCollapsed)
    }
    // Escape inside the pane closes it — the inspector owns no chrome of its
    // own, so the shell that added the split item does the closing.
    inspector.onRequestClose = { [weak self] in
      self?.setInspector(visible: false)
    }
    // ⌘↩ in the pane's title/notes commits and returns the keyboard to the
    // list — the pane stays open, following the selection as before.
    inspector.onRequestFocusList = { [weak list] in list?.focusList() }

    // The SwiftUI root normally starts the runtime; harmless if already up
    // (start() memoizes), load-bearing if this window somehow opens first.
    Task { await SeptenaServices.shared.start() }
    sidebar.selectDefault()
  }

  /// Sidebar → detail. Task filters keep the NSTableView list; Next swaps in
  /// the hosted SwiftUI feed. Inspector collapses off Next (nothing to show).
  private func show(_ destination: KitSidebarDestination) {
    switch destination {
    case .filter(let filter, let title):
      guard let list, let detail else { return }
      // The title is set HERE, not inside `list.show`, which returns early
      // when the destination is already current — coming back to Today from
      // Next hits exactly that early return, and a title set behind it would
      // stay reading "Next".
      window?.title = title
      detail.display(list)
      list.show(filter)
      // Ahead of the first scroll event, so a fresh page starts in the right
      // state (and coming back from Next, where the title is always shown).
      list.syncWindowTitle()
      list.focusList()
    case .next:
      guard let next, let detail else { return }
      setInspector(visible: false)
      window?.title = Route.next.title
      detail.display(next)
      // Same handoff as a task page: the page's own big title owns the top of
      // the window until it scrolls away. Next is a hosted SwiftUI page, so it
      // reports its own scroll position rather than being read off a clip view
      // — but the shell applies the identical rule, ahead of the first report.
      next.syncWindowTitle()
    }
  }

  /// One place that opens and closes the inspector, so every path — ⌥⌘I, the
  /// menu item, Escape inside the pane, switching to Next — commits pending
  /// edits, hands focus back to the list, and leaves the menu title truthful.
  private func setInspector(visible: Bool) {
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
  // Spelled out: `select` is overloaded for TaskFilter / KitSidebarDestination
  // / Route, and both KitSidebarDestination and Route have a `next`, so the
  // leading-dot form is ambiguous.
  func goNext() { sidebar?.select(KitSidebarDestination.next) }
  func newTask() { list?.createTask() }
  func newProject() { sidebar?.newProject() }
  func newArea() { sidebar?.newArea() }
  func showQuickFind() { quickFind?.show() }
  func showInspector() { toggleInspector?() }
  func toggleSidebar() { splitController?.toggleSidebar(nil) }
  func toggleSidebarCounts() { sidebar?.toggleShowsCounts() }

  var canActOnSelection: Bool { list?.hasActionableSelection ?? false }

  func rowCommand(_ command: RowCommand) {
    guard let list else { return }
    switch command {
    case .toggleComplete: list.toggleCompleteSelection()
    case .cancel: list.cancelSelection()
    case .toggleToday: list.toggleTodaySelection()
    case .rename: list.beginEditSelectedRow()
    case .when: list.presentDatePopover(kind: .when)
    case .deadline: list.presentDatePopover(kind: .deadline)
    case .clearSchedule: list.clearScheduleSelection()
    case .delete: list.deleteSelection()
    case .repeatEditor: list.presentRecurrencePanel()
    case .createNextCopy: list.createNextCopySelection()
    case .duplicate: list.duplicateSelection()
    case .move: list.presentMoveMenu()
    }
  }

  enum RowCommand {
    case toggleComplete, cancel, toggleToday, rename, when, deadline, clearSchedule, delete
    case duplicate, move, createNextCopy
    case repeatEditor
  }

  required init?(coder: NSCoder) { fatalError("SeptaskKitWindowController is code-only") }

  func windowWillClose(_ notification: Notification) {
    Self.current = nil
  }
}

/// Swaps the middle split pane between the task list and the Next host without
/// rebuilding the `NSSplitViewController` — both children stay alive so
/// returning to a list keeps selection / scroll position.
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
  static var canActOnSelection: Bool { shell?.canActOnSelection ?? false }

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
