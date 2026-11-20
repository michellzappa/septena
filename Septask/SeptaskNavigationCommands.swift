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
/// The AppKit shell's row commands, with the same titles and bindings as
/// `TaskRowCommands` so the two shells teach one set of muscle memory.
private struct SeptaskKitRowCommands: View {
  var body: some View {
    // Same set, order, and bindings as the shell's context menu and as
    // `TaskRowCommands` in the SwiftUI shell. Copy is deliberately absent:
    // it lives in the standard Edit menu, which reaches the task list through
    // the responder chain — a second ⌘C here would fight it for the binding.
    // Each item is enabled on its own: the shell routes these to the pane
    // that holds the keyboard, and on the sidebar only Rename and Delete have
    // a target (an area or project) — see `SeptaskKitWindowController.canRun`.
    Group {
      Button("Rename") { SeptaskKitCommands.row(.rename) }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(!SeptaskKitCommands.canRun(.rename))
      Button("Duplicate") { SeptaskKitCommands.row(.duplicate) }
        .keyboardShortcut("d", modifiers: .command)
        .disabled(!SeptaskKitCommands.canRun(.duplicate))
      Divider()
      Menu("Complete") {
        Button("Mark as Complete") { SeptaskKitCommands.row(.toggleComplete) }
          .keyboardShortcut(TaskRowShortcuts.markComplete)
          .disabled(!SeptaskKitCommands.canRun(.toggleComplete))
        Button("Cancel Task") { SeptaskKitCommands.row(.cancel) }
          .keyboardShortcut(TaskRowShortcuts.cancel)
          .disabled(!SeptaskKitCommands.canRun(.cancel))
        Divider()
        Button("Delete") { SeptaskKitCommands.row(.delete) }
          .keyboardShortcut(.delete, modifiers: .command)
          .disabled(!SeptaskKitCommands.canRun(.delete))
      }
      Button("Toggle Today") { SeptaskKitCommands.row(.toggleToday) }
        .keyboardShortcut("t", modifiers: .command)
        .disabled(!SeptaskKitCommands.canRun(.toggleToday))
      Button("When…") { SeptaskKitCommands.row(.when) }
        .keyboardShortcut("s", modifiers: .command)
        .disabled(!SeptaskKitCommands.canRun(.when))
      Button("Deadline…") { SeptaskKitCommands.row(.deadline) }
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .disabled(!SeptaskKitCommands.canRun(.deadline))
      Button("Move…") { SeptaskKitCommands.row(.move) }
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .disabled(!SeptaskKitCommands.canRun(.move))
      // Bare ⌘M is intentionally reclaimed by the focused task list. Keep
      // this alias hidden so Window ▸ Minimize cannot win the event.
      Button("Move…") { SeptaskKitCommands.row(.move) }
        .keyboardShortcut("m", modifiers: .command)
        .disabled(!SeptaskKitCommands.canRun(.move))
        .hidden()
      Button("Clear Schedule") { SeptaskKitCommands.row(.clearSchedule) }
        .keyboardShortcut(".", modifiers: [.command, .shift])
        .disabled(!SeptaskKitCommands.canRun(.clearSchedule))
      Button("Repeat…") { SeptaskKitCommands.row(.repeatEditor) }
        .disabled(!SeptaskKitCommands.canRun(.repeatEditor))
      Button("Create Next Copy") { SeptaskKitCommands.row(.createNextCopy) }
        .disabled(!SeptaskKitCommands.canRun(.createNextCopy))
    }
  }
}

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

/// The app-level menu shell reads the focused main-window actions instead of a
/// NavigationState stored on `App`. This keeps two restored/windows scenes from
/// steering each other while preserving the standard menu shortcuts.
struct SeptaskCommandMenus: Commands {
  @FocusedValue(\.septaskNavigationActions) private var actions
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

  var body: some Commands {
    CommandMenu("Go") {
      Button("Today") { go(.today) }
        .keyboardShortcut("1", modifiers: .command)
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

    CommandMenu("Task") {
      Button("New Project") {
        if let actions {
          actions.newProject()
        } else {
          #if os(macOS)
          SeptaskKitCommands.newProject()
          #endif
        }
      }
      .disabled(!canNavigate)
      Button("New Area") {
        if let actions {
          actions.newArea()
        } else {
          #if os(macOS)
          SeptaskKitCommands.newArea()
          #endif
        }
      }
      .disabled(!canNavigate)
      Divider()
      #if os(macOS)
      // The shell publishes no `taskActions` (that's a SwiftUI focused value),
      // so it gets its own row commands with the same bindings rather than a
      // menu full of permanently-disabled items.
      if actions == nil {
        SeptaskKitRowCommands()
      } else {
        TaskCommandsMenu()
      }
      #else
      TaskCommandsMenu()
      #endif
    }

    CommandGroup(after: .sidebar) {
      Button(sidebarIsHidden ? "Show Sidebar" : "Hide Sidebar") {
        if let actions {
          actions.toggleSidebar()
        } else {
          #if os(macOS)
          SeptaskKitCommands.toggleSidebar()
          #endif
        }
      }
      #if os(macOS)
      // ⌃⌘S — the platform's standard sidebar toggle. macOS only: on iOS the
      // system already owns ⌃⌘S (its own Show Sidebar command), and UIKit
      // aborts the app at launch on a duplicate menu shortcut (2026-11-19).
      .keyboardShortcut("s", modifiers: [.control, .command])
      #endif
      .disabled(!canNavigate)

      #if os(macOS)
      Button(inspectorVisible ? "Hide Info" : "Show Info") {
        SeptaskKitCommands.showInspector()
      }
      .keyboardShortcut("i", modifiers: [.command, .option])
      .disabled(actions != nil || !SeptaskKitCommands.canHandle)

      // AppKit-shell-only for now (the SwiftUI sidebar has no count-hiding
      // toggle) — so this is unconditionally gated on the shell, not on
      // `actions == nil` like the other rows here. Dynamic title, same
      // pattern as "Show/Hide Sidebar" above — the setting lives in
      // UserDefaults (read by the AppKit sidebar directly), not a SwiftUI
      // published value, so this reads it fresh rather than binding to it.
      Button(sidebarCountsHidden ? "Show Sidebar Counts" : "Hide Sidebar Counts") {
        SeptaskKitCommands.toggleSidebarCounts()
      }
      .disabled(!SeptaskKitCommands.canHandle)
      #endif

      // View options for the lists themselves. Not shell-gated: it writes a
      // stored preference both shells read, and on iPadOS this same group is
      // what fills the hardware menu bar.
      Divider()
      TaskViewOptions()
    }

    // Standard macOS text-size affordances: the View menu exposes both a
    // discoverable five-step scale and the familiar increase/decrease/reset
    // shortcuts. This writes the same preference as Settings → Text Size.
    CommandGroup(after: .toolbar) {
      Menu("Text Size") {
        Picker("Text Size", selection: textSizeSelection) {
          ForEach(TextSizeStep.allCases) { step in
            Text(step.label).tag(step.rawValue)
          }
        }
        Divider()
        Button("Increase Text Size") { adjustTextSize(by: 1) }
          .keyboardShortcut("+", modifiers: .command)
          .disabled(TextSizeStep.resolve(textSizeRaw) == .xLarge)
        Button("Decrease Text Size") { adjustTextSize(by: -1) }
          .keyboardShortcut("-", modifiers: .command)
          .disabled(TextSizeStep.resolve(textSizeRaw) == .xSmall)
        Button("Reset Text Size") { textSizeSelection.wrappedValue = TextSizeStep.normal.rawValue }
          .keyboardShortcut("0", modifiers: .command)
          .disabled(TextSizeStep.resolve(textSizeRaw) == .normal)
      }
    }

    #if os(macOS)
    // ⌘N belongs to whichever shell is in front; the shared NewTaskCommand
    // only knows about SwiftUI scenes.
    CommandGroup(replacing: .newItem) {
      if actions == nil {
        Button("New To-Do") { SeptaskKitCommands.newTask() }
          .keyboardShortcut("n", modifiers: .command)
          .disabled(!SeptaskKitCommands.canHandle)
      } else {
        NewTaskCommand()
      }
    }
    #else
    CommandGroup(replacing: .newItem) { NewTaskCommand() }
    #endif

    #if os(macOS)
    CommandGroup(replacing: .undoRedo) { SeptaskUndoRedoCommands() }
    #endif

    CommandGroup(after: .newItem) {
      #if os(macOS)
      // SwiftUI-window only: the AppKit shell has no Quick Add sheet (Quick
      // Entry covers capture), and a permanently disabled item is worse
      // than none.
      if actions != nil {
        Button("Quick Add…") { actions?.showQuickAdd() }
          .keyboardShortcut("i", modifiers: .command)
      }
      #else
      Button("Quick Add…") { actions?.showQuickAdd() }
        .keyboardShortcut("i", modifiers: .command)
        .disabled(actions == nil)
      #endif
    }

    CommandGroup(replacing: .appSettings) {
      Button("Settings…") { showSettings() }
        .keyboardShortcut(",", modifiers: .command)
      // Stays available from the Settings window itself, which is why this
      // checks "a shell exists" rather than "a shell is frontmost".
      .disabled(!canOpenSettings)
    }

    CommandGroup(after: .help) {
      #if os(macOS)
      // SwiftUI-window only, for the same reason as Quick Add above.
      if actions != nil {
        Button("Keyboard Shortcuts") { actions?.showKeyboardShortcuts() }
          .keyboardShortcut("/", modifiers: [.command, .shift])
      }
      #else
      Button("Keyboard Shortcuts") { actions?.showKeyboardShortcuts() }
        .keyboardShortcut("/", modifiers: [.command, .shift])
        .disabled(actions == nil)
      #endif
    }

    #if os(macOS)
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
    #endif
  }
}

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
