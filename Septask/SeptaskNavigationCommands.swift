import SwiftUI

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

/// The app-level menu shell reads the focused main-window actions instead of a
/// NavigationState stored on `App`. This keeps two restored/windows scenes from
/// steering each other while preserving the standard menu shortcuts.
struct SeptaskCommandMenus: Commands {
  @FocusedValue(\.septaskNavigationActions) private var actions

  var body: some Commands {
    CommandMenu("Go") {
      Button("Today") { actions?.go(.today) }
        .keyboardShortcut("1", modifiers: .command)
        .disabled(actions == nil)
      Button("Upcoming") { actions?.go(.upcoming) }
        .keyboardShortcut("2", modifiers: .command)
        .disabled(actions == nil)
      Button("Anytime") { actions?.go(.unscheduled) }
        .keyboardShortcut("3", modifiers: .command)
        .disabled(actions == nil)
      Button("Logbook") { actions?.go(.logbook) }
        .keyboardShortcut("4", modifiers: .command)
        .disabled(actions == nil)

      Divider()

      Button("Quick Find…") { actions?.showQuickFind() }
        .keyboardShortcut("f", modifiers: [.command, .shift])
        .disabled(actions == nil)
    }

    CommandMenu("Task") {
      Button("New Project") { actions?.newProject() }
        .disabled(actions == nil)
      Button("New Area") { actions?.newArea() }
        .disabled(actions == nil)
      Divider()
      TaskCommandsMenu()
    }

    CommandGroup(after: .sidebar) {
      Button(actions?.sidebarVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar") {
        actions?.toggleSidebar()
      }
      .keyboardShortcut("/", modifiers: .command)
      .disabled(actions == nil)
    }

    CommandGroup(replacing: .newItem) { NewTaskCommand() }

    CommandGroup(after: .newItem) {
      Button("Quick Add…") { actions?.showQuickAdd() }
        .keyboardShortcut("i", modifiers: .command)
        .disabled(actions == nil)
    }

    CommandGroup(replacing: .appSettings) {
      Button("Settings…") { actions?.showSettings() }
        .keyboardShortcut(",", modifiers: .command)
        .disabled(actions == nil)
    }

    CommandGroup(after: .help) {
      Button("Keyboard Shortcuts") { actions?.showKeyboardShortcuts() }
        .keyboardShortcut("/", modifiers: [.command, .shift])
        .disabled(actions == nil)
    }
  }
}
