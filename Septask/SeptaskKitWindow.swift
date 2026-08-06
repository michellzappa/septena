#if os(macOS)
import AppKit

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
  private var sidebar: SeptaskKitSidebarController?
  private var splitController: NSSplitViewController?

  private init() {
    let list = SeptaskKitTaskListController()
    let sidebar = SeptaskKitSidebarController()
    let inspector = SeptaskKitInspectorController()
    sidebar.onSelect = { [weak list] filter, title in
      list?.show(filter, title: title)
    }
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
    let listItem = NSSplitViewItem(viewController: list)
    listItem.minimumThickness = 380
    split.addSplitViewItem(listItem)
    // Native inspector pane — collapsed until ⌥⌘I, and it commits any pending
    // note when it closes so nothing typed is lost on collapse.
    let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
    inspectorItem.minimumThickness = 260
    inspectorItem.maximumThickness = 380
    inspectorItem.isCollapsed = true
    split.addSplitViewItem(inspectorItem)
    split.splitView.autosaveName = "SeptaskKitSplit"

    list.onToggleInspector = { [weak inspector] in
      guard !inspectorItem.isCollapsed else {
        inspectorItem.animator().isCollapsed = false
        return
      }
      inspector?.flushPendingEdits()
      inspectorItem.animator().isCollapsed = true
    }

    // Quick Find steers the sidebar, which drives the list — so a jump always
    // leaves the two in agreement — then selects the row it found.
    let quickFind = SeptaskKitQuickFind { [weak sidebar, weak list] destination in
      sidebar?.select(destination.filter)
      if let taskId = destination.taskId {
        list?.select(taskId: taskId)
      }
    }
    self.quickFind = quickFind
    list.onQuickFind = { [weak quickFind] in quickFind?.show() }
    // Same path Quick Find uses: steer the sidebar, which drives the list —
    // so a group-header click always leaves the two in agreement.
    list.onNavigateToGroup = { [weak sidebar] filter in sidebar?.select(filter) }

    let window = NSWindow(contentViewController: split)
    window.title = "Septask (AppKit)"
    // Matches the SwiftUI scene's `.windowStyle(.hiddenTitleBar)`: content
    // runs under a transparent title bar, traffic lights float over the
    // sidebar. The title still names the window in the Window menu.
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.styleMask.insert(.fullSizeContentView)
    window.setContentSize(NSSize(width: 980, height: 700))
    window.center()
    window.setFrameAutosaveName("SeptaskKitWindow")
    super.init(window: window)
    window.delegate = self
    self.list = list
    self.sidebar = sidebar
    self.splitController = split
    self.toggleInspector = { [weak list] in list?.onToggleInspector?() }

    // The SwiftUI root normally starts the runtime; harmless if already up
    // (start() memoizes), load-bearing if this window somehow opens first.
    Task { await SeptenaServices.shared.start() }
    sidebar.selectDefault()
  }

  // MARK: - Menu-bar surface

  private var toggleInspector: (() -> Void)?

  /// True while this shell owns the menu bar — i.e. its window is key. The
  /// SwiftUI window publishes its own focused actions, so the two never both
  /// claim a command.
  var isFrontmost: Bool { window?.isKeyWindow == true }

  func go(to filter: TaskFilter) { sidebar?.select(filter) }
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
    case .toggleToday: list.toggleTodaySelection()
    case .rename: list.beginEditSelectedRow()
    case .when: list.presentDatePopover(kind: .when)
    case .deadline: list.presentDatePopover(kind: .deadline)
    case .clearSchedule: list.clearScheduleSelection()
    case .delete: list.deleteSelection()
    case .setRecurrence(let rule): list.setRecurrence(rule)
    case .duplicate: list.duplicateSelection()
    case .move: list.presentMoveMenu()
    }
  }

  enum RowCommand {
    case toggleComplete, toggleToday, rename, when, deadline, clearSchedule, delete
    case duplicate, move
    case setRecurrence(Recurrence?)
  }

  required init?(coder: NSCoder) { fatalError("SeptaskKitWindowController is code-only") }

  func windowWillClose(_ notification: Notification) {
    Self.current = nil
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

  /// A shell exists, frontmost or not. Used by commands that stay available
  /// from an auxiliary window (Settings, opened over the shell).
  static var shellExists: Bool { SeptaskKitWindowController.existing != nil }
  static var canActOnSelection: Bool { shell?.canActOnSelection ?? false }

  static func go(_ filter: TaskFilter) { shell?.go(to: filter) }
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
