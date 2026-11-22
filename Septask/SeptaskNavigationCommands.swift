import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Window-scoped commands published by the active Septask scene. App services
/// stay shared, but route selection, presentation, and sidebar visibility must
/// belong to the window the person is actually using.
struct SeptaskNavigationActions {
  var go: (TaskFilter) -> Void
  var newTask: () -> Void
  var newProject: () -> Void
  var newArea: () -> Void
  var toggleSidebar: () -> Void
  var sidebarVisibility: NavigationSplitViewVisibility
  var showQuickFind: () -> Void
  var showQuickAdd: () -> Void
  var showSettings: () -> Void
  var showKeyboardShortcuts: () -> Void
}

private struct SeptaskNavigationActionsKey: FocusedValueKey {
  typealias Value = SeptaskNavigationActions
}

extension FocusedValues {
  var septaskNavigationActions: SeptaskNavigationActions? {
    get { self[SeptaskNavigationActionsKey.self] }
    set { self[SeptaskNavigationActionsKey.self] = newValue }
  }
}

#if os(macOS)
/// Opens the classic SwiftUI window. It's suppressed at launch now that the
/// AppKit shell is the default, but it still hosts everything the shell hasn't
/// covered — so it stays one menu item away.
private struct ClassicWindowCommand: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("Classic Window") { openWindow(id: "main") }
      .keyboardShortcut("0", modifiers: [.command, .option])
  }
}
#endif

/// The Task menu, rendered from the registry's `menuBar` `task` menu — the
/// same items, order, titles and bindings in either shell. Copy is absent on
/// purpose: it lives in the standard Edit menu.
///
/// On macOS the AppKit shell drives it when no SwiftUI scene is focused (the
/// shell publishes no `taskActions`); each item is enabled on its own, since
/// the shell routes row commands to the pane that holds the keyboard (see
/// `SeptaskKitWindowController.canRun`).
private struct SeptaskTaskMenu: View {
  let navigation: SeptaskNavigationActions?
  let canNavigate: Bool
  @FocusedValue(\.taskActions) private var taskActions
  @FocusedValue(\.nextListActions) private var nextActions

  private var usesKit: Bool {
    #if os(macOS)
    return navigation == nil
    #else
    return false
    #endif
  }

  var body: some View {
    let nodes = RegistryMenuResolver.resolve(
      RegistryActions.menuBarMenu("task")?.items ?? [], bind: bind)
    RegistryMenuContent(nodes: nodes)
    #if os(macOS)
    // NSMenuItem has one visible key-equivalent slot. Alternate bindings
    // (bare ⌘M for Move…) and the SwiftUI list's row commands the menu does
    // not show (⌘C) ride as hidden items, so Window ▸ Minimize cannot win the
    // event. The AppKit list handles both keys itself.
    if !usesKit {
      ForEach(hiddenBindings(nodes), id: \.id) { binding in
        Button(binding.title) { binding.perform?() }
          .keyboardShortcut(binding.shortcut.keyboardShortcut)
          .disabled(binding.perform == nil)
          .hidden()
      }
    }
    #endif
  }

  private func bind(_ id: String) -> RegistryActionBinding? {
    switch id {
    case "sidebar.newProject":
      return .init(perform: canNavigate ? newProject : nil)
    case "sidebar.newArea":
      return .init(perform: canNavigate ? newArea : nil)
    default:
      break
    }
    #if os(macOS)
    if usesKit {
      guard let command = Self.kitCommand(for: id) else { return nil }
      return .init(perform: SeptaskKitCommands.canRun(command) ? { SeptaskKitCommands.row(command) } : nil)
    }
    #endif
    guard TaskActions.supports(id) else { return nil }
    let action = taskActions?.handler(for: id)
      ?? (id == "task.toggleComplete" ? nextActions?.toggleComplete : nil)
    #if os(iOS)
    // iPad: the task list can't publish `\.taskActions` (a focused scene
    // value from the split-view detail SIGKILLs iPad, see TaskListView), so
    // the list's own hidden shortcut buttons serve its rows. Show only what
    // has a live handler here (the Next checklist's ⌘K), so the hold-⌘ HUD
    // lists each command once.
    guard action != nil else { return nil }
    #endif
    return .init(perform: action)
  }

  private func newProject() {
    if let navigation {
      navigation.newProject()
    } else {
      #if os(macOS)
      SeptaskKitCommands.newProject()
      #endif
    }
  }

  private func newArea() {
    if let navigation {
      navigation.newArea()
    } else {
      #if os(macOS)
      SeptaskKitCommands.newArea()
      #endif
    }
  }

  #if os(macOS)
  private struct HiddenBinding {
    let id: String
    let title: String
    let shortcut: RegistryShortcut
    let perform: (() -> Void)?
  }

  /// Alternate shortcuts of the menu's items, plus row commands from the
  /// shortcuts sheet that the SwiftUI list serves but the menu leaves out.
  private func hiddenBindings(_ nodes: [RegistryMenuNode]) -> [HiddenBinding] {
    var shown = Set<String>()
    var out: [HiddenBinding] = []
    func walk(_ nodes: [RegistryMenuNode]) {
      for node in nodes {
        switch node {
        case .item(let entry):
          shown.insert(entry.id)
          for (index, alternate) in (RegistryActions.shortcut(for: entry.id)?.alternates ?? []).enumerated() {
            out.append(HiddenBinding(id: "\(entry.id).alt\(index)", title: entry.title,
                                     shortcut: alternate, perform: entry.perform))
          }
        case .submenu(_, _, _, let children):
          walk(children)
        case .divider:
          break
        }
      }
    }
    walk(nodes)
    for id in TaskActions.rowCommandIds where !shown.contains(id) {
      guard let shortcut = RegistryActions.shortcut(for: id) else { continue }
      out.append(HiddenBinding(id: id, title: RegistryActions.title(id), shortcut: shortcut,
                               perform: taskActions?.handler(for: id)))
    }
    return out
  }

  /// The AppKit shell's row command for a registry action.
  private static func kitCommand(for id: String) -> SeptaskKitWindowController.RowCommand? {
    switch id {
    case "task.editDetails": return .rename
    case "task.duplicate": return .duplicate
    case "task.toggleComplete": return .toggleComplete
    case "task.cancel": return .cancel
    case "task.delete": return .delete
    case "task.toggleToday": return .toggleToday
    case "task.toggleStar": return .toggleStar
    case "task.tags": return .editTags
    case "task.addChecklistItem": return .addChecklistItem
    case "task.when": return .when
    case "task.deadline": return .deadline
    case "task.reminder": return .reminder
    case "task.move": return .move
    case "task.clearSchedule": return .clearSchedule
    case "task.repeat": return .repeatEditor
    case "task.createNextCopy": return .createNextCopy
    default: return nil
    }
  }
  #endif
}

/// The app-level menu shell reads the focused main-window actions instead of a
/// NavigationState stored on `App`. This keeps two restored/windows scenes from
/// steering each other while preserving the standard menu shortcuts.
///
/// Every menu except Go renders from the registry's `menuBar` composition
/// (`registry/actions.json`): the App, File, View, Task and Help items, their
/// order, titles and shortcuts. This struct binds each action ID to a handler.
struct SeptaskCommandMenus: Commands {
  @FocusedValue(\.septaskNavigationActions) private var actions
  @FocusedValue(\.taskActions) private var taskActions
  @AppStorage(SettingsKey.textSizeStep) private var textSizeRaw = 0

  /// A navigation command has a target when a SwiftUI window is focused, or —
  /// on macOS, where it's the default window — when the AppKit shell is.
  private var canNavigate: Bool {
    #if os(macOS)
    return actions != nil || SeptaskKitCommands.canNavigate
    #else
    return actions != nil
    #endif
  }

  #if os(macOS)
  /// Mirror of the AppKit shell's inspector state (see
  /// `SettingsKey.septaskInspectorVisible`). `@AppStorage` rather than a raw
  /// read because a `Commands` body has to re-evaluate when it flips — a
  /// permanent "Show Info" on an open pane is what made the toggle unfindable.
  @AppStorage(SettingsKey.septaskInspectorVisible) private var inspectorVisible = false
  /// Mirror of the AppKit shell's sidebar collapse, for the same reason.
  @AppStorage(SeptaskKitStateKey.sidebarHidden)
  private var kitSidebarHidden = false

  private var sidebarCountsHidden: Bool {
    UserDefaults.standard.object(forKey: SettingsKey.septaskSidebarCounts) == nil
      ? false
      : !UserDefaults.standard.bool(forKey: SettingsKey.septaskSidebarCounts)
  }
  #endif

  /// Settings opens its own window on macOS and needs no shell behind it,
  /// so it is ALWAYS available there — closing the last shell window must
  /// not grey out ⌘,.
  private var canOpenSettings: Bool {
    #if os(macOS)
    return true
    #else
    return actions != nil
    #endif
  }

  /// Show/Hide Sidebar names the action it will take, in either shell.
  private var sidebarIsHidden: Bool {
    if let actions { return actions.sidebarVisibility == .detailOnly }
    #if os(macOS)
    return kitSidebarHidden
    #else
    return false
    #endif
  }

  private func go(_ filter: TaskFilter) {
    if let actions {
      actions.go(filter)
    } else {
      #if os(macOS)
      SeptaskKitCommands.go(filter)
      #endif
    }
  }

  private func showQuickFind() {
    if let actions {
      actions.showQuickFind()
    } else {
      #if os(macOS)
      SeptaskKitCommands.quickFind()
      #endif
    }
  }

  private func showSettings() {
    #if os(macOS)
    // The AppKit shell is the default macOS surface. Do not route through a
    // stale focused value from the suppressed SwiftUI WindowGroup: that only
    // flips state on an invisible scene and makes Settings appear inert.
    SeptaskKitSettingsWindow.show()
    #else
    actions?.showSettings()
    #endif
  }

  private var textSizeSelection: Binding<Int> {
    Binding(
      get: { TextSizeStep.resolve(textSizeRaw).rawValue },
      set: { raw in
        let step = TextSizeStep.resolve(raw).rawValue
        textSizeRaw = step
        #if os(macOS)
        FontScale.shared.setStep(step)
        #endif
      }
    )
  }

  private func adjustTextSize(by delta: Int) {
    let current = TextSizeStep.resolve(textSizeRaw).rawValue
    textSizeSelection.wrappedValue = current + delta
  }

  /// One registry `menuBar` menu, resolved against `bind`.
  private func menuBar(_ id: String, slot: (String) -> [RegistryMenuNode] = { _ in [] }) -> RegistryMenuContent {
    RegistryMenuContent(nodes: RegistryMenuResolver.resolve(
      RegistryActions.menuBarMenu(id)?.items ?? [], bind: bind, slot: slot))
  }

  // MARK: - Bindings (App, File, View, Help)

  private func bind(_ id: String) -> RegistryActionBinding? {
    switch id {
    case "app.settings":
      return .init(perform: canOpenSettings ? showSettings : nil)

    case "app.newTask":
      return newTaskBinding

    case "app.quickAdd":
      // The registry gates Quick Add off macOS (Quick Entry covers capture).
      return .init(perform: actions.map { actions in { actions.showQuickAdd() } })

    case "app.keyboardShortcuts":
      #if os(macOS)
      // SwiftUI-window only: the AppKit shell has no shortcuts sheet, and a
      // permanently disabled item is worse than none.
      guard let actions else { return nil }
      return .init { actions.showKeyboardShortcuts() }
      #else
      return .init(perform: actions.map { actions in { actions.showKeyboardShortcuts() } })
      #endif

    case "app.toggleSidebar":
      // ⌃⌘S is macOS only: the registry excludes it on iOS, where the system
      // already owns ⌃⌘S and UIKit aborts the app on a duplicate shortcut.
      return .init(variant: sidebarIsHidden ? .add : .remove,
                   perform: canNavigate ? toggleSidebar : nil)

    #if os(macOS)
    case "task.toggleInfo":
      return .init(variant: inspectorVisible ? .active : .base,
                   perform: actions == nil && SeptaskKitCommands.canHandle
                     ? { SeptaskKitCommands.showInspector() } : nil)

    case "app.toggleSidebarCounts":
      // AppKit-shell-only (the SwiftUI sidebar has no count-hiding toggle).
      return .init(variant: sidebarCountsHidden ? .base : .active,
                   perform: SeptaskKitCommands.canHandle ? { SeptaskKitCommands.toggleSidebarCounts() } : nil)
    #endif

    case "app.textSizeIncrease":
      return .init(perform: TextSizeStep.resolve(textSizeRaw) == .xLarge ? nil : { adjustTextSize(by: 1) })
    case "app.textSizeDecrease":
      return .init(perform: TextSizeStep.resolve(textSizeRaw) == .xSmall ? nil : { adjustTextSize(by: -1) })
    case "app.textSizeReset":
      return .init(perform: TextSizeStep.resolve(textSizeRaw) == .normal
                   ? nil : { textSizeSelection.wrappedValue = TextSizeStep.normal.rawValue })

    default:
      return nil
    }
  }

  /// View ▸ Text Size ▸ the five steps, the current one checked. Writes the
  /// same preference as Settings → Text Size.
  private func textSizeSteps(_ id: String) -> [RegistryMenuNode] {
    guard id == "textSizeSteps" else { return [] }
    let current = TextSizeStep.resolve(textSizeRaw)
    return TextSizeStep.allCases.map { step in
      RegistryMenuEntry.slot(id: "textSize.\(step.rawValue)", title: step.label,
                             isOn: step == current) {
        textSizeSelection.wrappedValue = step.rawValue
      }
    }
  }

  /// ⌘N belongs to whichever shell is in front: a focused task list makes
  /// the new row inherit its project / area; otherwise the window's own
  /// new-task path (Inbox + draft row) runs.
  private var newTaskBinding: RegistryActionBinding {
    #if os(macOS)
    if actions == nil {
      return .init(perform: SeptaskKitCommands.canHandle ? { SeptaskKitCommands.newTask() } : nil)
    }
    #endif
    let taskActions = taskActions
    let actions = actions
    return .init {
      if let taskActions {
        taskActions.newTask()
      } else {
        actions?.newTask()
      }
    }
  }

  private func toggleSidebar() {
    if let actions {
      actions.toggleSidebar()
    } else {
      #if os(macOS)
      SeptaskKitCommands.toggleSidebar()
      #endif
    }
  }

  var body: some Commands {
    CommandMenu("Go") {
      Button("Today") { go(.today) }
        .keyboardShortcut("1", modifiers: .command)
        .disabled(!canNavigate)
      Button("Review") { go(.review) }
        .disabled(!canNavigate)
      Button(TaskFilter.agent.title) { go(.agent) }
        .disabled(!canNavigate)
      Button("Upcoming") { go(.upcoming) }
        .keyboardShortcut("2", modifiers: .command)
        .disabled(!canNavigate)
      Button("Repeating") { go(.repeating) }
        .disabled(!canNavigate)
      Button("Anytime") { go(.unscheduled) }
        .keyboardShortcut("3", modifiers: .command)
        .disabled(!canNavigate)
      Button("Logbook") { go(.logbook) }
        .keyboardShortcut("4", modifiers: .command)
        .disabled(!canNavigate)

      Divider()

      Button("Quick Find…") { showQuickFind() }
        .keyboardShortcut("f", modifiers: [.command, .shift])
        .disabled(!canNavigate)

      #if os(macOS)
      Divider()

      // The AppKit shell is the default window on macOS; this reopens it if
      // it was closed. No shortcut: ⌘0 is Reset Text Size, ⌘1–4 are the
      // lists, and the Dock icon reopens the window too.
      Button("Septena Window") { SeptaskKitWindowController.show() }
      ClassicWindowCommand()

      // Shows the global hotkey `SeptaskKitQuickEntry.installHotKey()`
      // registers (⌃⌥Space), so the combination is discoverable here.
      // Not a task-row binding: it carries two modifiers and opens the
      // capture panel, so it cannot reach a row checkbox.
      Button("Quick Entry") { SeptaskKitQuickEntry.show() }
        .keyboardShortcut(.space, modifiers: [.control, .option]) // septena-lint:allow task-space-binding — global ⌃⌥Space capture hotkey, not a row key
      #endif
    }

    CommandMenu(RegistryActions.menuBarMenu("task")?.title ?? "Task") {
      SeptaskTaskMenu(navigation: actions, canNavigate: canNavigate)
    }

    CommandGroup(after: .sidebar) {
      // Registry View menu: sidebar, Info, sidebar counts, Text Size ▸.
      menuBar("view", slot: textSizeSteps)

      // View options for the lists themselves. Not shell-gated: it writes a
      // stored preference both shells read, and on iPadOS this same group is
      // what fills the hardware menu bar.
      Divider()
      TaskViewOptions()
    }

    CommandGroup(replacing: .newItem) { menuBar("file") }

    #if os(macOS)
    CommandGroup(replacing: .undoRedo) { SeptaskUndoRedoCommands() }
    #endif

    CommandGroup(replacing: .appSettings) { menuBar("app") }

    CommandGroup(after: .help) { menuBar("help") }

    #if os(macOS)
    SeptaskMacAppCommands()
    #endif
  }
}


#if os(macOS)
/// Extracted so `SeptaskCommandMenus.body` stays within SwiftUI's 10-child
/// `CommandsBuilder` limit.
private struct SeptaskMacAppCommands: Commands {
  var body: some Commands {
    CommandGroup(after: .appInfo) {
      Button("Check for Updates…") {
        Task { @MainActor in SeptaskUpdater.shared.checkForUpdates() }
      }
      #if DEBUG
      .disabled(true)
      #else
      .disabled(!SeptaskUpdater.isConfigured)
      #endif
    }
  }
}
#endif

#if os(macOS)
/// Edit ▸ Undo / Redo. SwiftUI's built-in items follow the SwiftUI scene's
/// undo manager, so they stay greyed over the AppKit task window even when
/// `TaskUndo` has steps. These replace them with one rule for both windows:
/// while the caret is in a text field, the text's own typing undo answers
/// (sent through the responder chain, so the composer's and the inspector's
/// local stacks win); everywhere else the shared task stack does.
private struct SeptaskUndoRedoCommands: View {
  @State private var undoName = TaskUndo.undoActionName
  @State private var redoName = TaskUndo.manager.redoActionName

  var body: some View {
    Group {
      Button(undoName.isEmpty ? "Undo" : "Undo \(undoName)") { perform(undo: true) }
        .keyboardShortcut("z", modifiers: .command)
      Button(redoName.isEmpty ? "Redo" : "Redo \(redoName)") { perform(undo: false) }
        .keyboardShortcut("z", modifiers: [.command, .shift])
    }
    .onReceive(NotificationCenter.default.publisher(for: TaskUndo.changed)) { _ in
      undoName = TaskUndo.undoActionName
      redoName = TaskUndo.manager.redoActionName
    }
  }

  private func perform(undo: Bool) {
    let selector = undo ? Selector(("undo:")) : Selector(("redo:"))
    if NSApp.keyWindow?.firstResponder is NSText {
      NSApp.sendAction(selector, to: nil, from: nil)
      return
    }
    if undo, TaskUndo.canUndo {
      TaskUndo.undo()
    } else if !undo, TaskUndo.canRedo {
      TaskUndo.redo()
    } else {
      NSSound.beep()
    }
  }
}
#endif
