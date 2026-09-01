import SwiftUI

// A read-only reference of every keyboard shortcut, grouped by area.
// Presented as a sheet from the Help menu (⌘?) and discoverable on both
// macOS and iPad (where it complements the hold-⌘ HUD).
//
// The list is hand-maintained here as the single human-facing catalogue —
// the shortcuts themselves are defined in the various CommandMenus
// (App.swift, TaskCommands.swift) and view-level onKeyPress handlers. Keep
// this in sync when adding or changing a binding.

struct KeyboardShortcut2: Identifiable {
  let id = UUID()
  /// Ordered key tokens, e.g. ["⌘", "⇧", "F"] — rendered as keycap chips.
  let keys: [String]
  let label: String
}

struct KeyboardShortcutGroup: Identifiable {
  let id = UUID()
  let title: String
  let shortcuts: [KeyboardShortcut2]
}

enum KeyboardShortcutsCatalogue {
  // Navigation differs per shell: Septena's tab hops + smart-list jumps vs
  // Septask's plain ⌘1–4 smart lists (its Go menu — see SeptaskApp).
  private static var navigation: KeyboardShortcutGroup {
    #if SEPTASK
    KeyboardShortcutGroup(title: "Navigation", shortcuts: [
      KeyboardShortcut2(keys: ["⌘", "1"], label: "Today"),
      KeyboardShortcut2(keys: ["⌘", "2"], label: "Upcoming"),
      KeyboardShortcut2(keys: ["⌘", "3"], label: "Anytime"),
      KeyboardShortcut2(keys: ["⌘", "4"], label: "Logbook"),
    ])
    #else
    KeyboardShortcutGroup(title: "Navigation", shortcuts: [
      KeyboardShortcut2(keys: ["⌘", "1"], label: "Week tab"),
      KeyboardShortcut2(keys: ["⌘", "2"], label: "Next tab"),
      KeyboardShortcut2(keys: ["⌘", "3"], label: "Tasks tab"),
      KeyboardShortcut2(keys: ["⌘", "4"], label: "Goals tab"),
      KeyboardShortcut2(keys: ["⌥", "⌘", "1"], label: "Inbox"),
      KeyboardShortcut2(keys: ["⌥", "⌘", "2"], label: "Today"),
      KeyboardShortcut2(keys: ["⌥", "⌘", "3"], label: "Next list"),
      KeyboardShortcut2(keys: ["⌥", "⌘", "4"], label: "Upcoming"),
      KeyboardShortcut2(keys: ["⌥", "⌘", "5"], label: "Unscheduled"),
    ])
    #endif
  }

  /// Row commands are GENERATED from `TaskRowCommands` — the same registry the
  /// Task menu and the iPad shortcut buttons render from — so this sheet can no
  /// longer advertise a binding the app doesn't have. Only the keys that
  /// aren't row commands — the selection/navigation keys the list handles
  /// itself — are listed by hand.
  private static var taskList: KeyboardShortcutGroup {
    var shortcuts = [
      KeyboardShortcut2(keys: ["↑", "↓"], label: "Move selection"),
      KeyboardShortcut2(keys: ["return"], label: "Open / edit"),
      KeyboardShortcut2(keys: ["esc"], label: "Clear selection"),
      KeyboardShortcut2(keys: ["⌘", "N"], label: "New to-do"),
    ]
    #if SEPTASK
    // AppKit-list only (Septask's table owns this key directly), so it isn't a
    // `TaskRowCommands` entry — listing it there would advertise it in Septena.
    shortcuts.append(KeyboardShortcut2(keys: ["⌥", "⌘", "M"],
                                       label: "Move to suggested list"))
    #endif
    shortcuts += TaskRowCommands.all.flatMap { command in
      command.allShortcuts.map { shortcut in
        KeyboardShortcut2(keys: TaskRowCommand.keycaps(for: shortcut), label: command.title)
      }
    }
    return KeyboardShortcutGroup(title: "Task list", shortcuts: shortcuts)
  }

  private static var quickCaptureLabel: String {
    #if SEPTASK
    "New to-do — quick capture"
    #else
    "Add Info — quick capture"
    #endif
  }

  static let groups: [KeyboardShortcutGroup] = [
    navigation,
    KeyboardShortcutGroup(title: "General", shortcuts: [
      KeyboardShortcut2(keys: ["⌘", "I"], label: quickCaptureLabel),
      KeyboardShortcut2(keys: ["⌘", "⇧", "F"], label: "Quick Find"),
      KeyboardShortcut2(keys: ["⌘", "/"], label: "Show / hide sidebar"),
      KeyboardShortcut2(keys: ["⌘", ","], label: "Settings"),
      KeyboardShortcut2(keys: ["⌘", "⇧", "/"], label: "Keyboard shortcuts (this sheet)"),
    ]),
    taskList,
    KeyboardShortcutGroup(title: "Edit & section sheets", shortcuts: [
      KeyboardShortcut2(keys: ["⌘", "N"], label: "Quick-add in an open section"),
      KeyboardShortcut2(keys: ["←"], label: "Time travel: previous day"),
      KeyboardShortcut2(keys: ["→"], label: "Time travel: next day"),
      KeyboardShortcut2(keys: ["return"], label: "Save the open edit form"),
      KeyboardShortcut2(keys: ["esc"], label: "Cancel the open edit form"),
    ]),
  ]
}

struct KeyboardShortcutsView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        ForEach(KeyboardShortcutsCatalogue.groups) { group in
          Section(group.title) {
            ForEach(group.shortcuts) { shortcut in
              HStack(spacing: 12) {
                Text(shortcut.label)
                Spacer(minLength: 16)
                HStack(spacing: 4) {
                  ForEach(Array(shortcut.keys.enumerated()), id: \.offset) { _, key in
                    KeycapView(key: key)
                  }
                }
              }
            }
          }
        }
      }
      .navigationTitle("Keyboard Shortcuts")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .keyboardShortcut(.cancelAction) // Esc closes
        }
      }
    }
  }
}

/// A single key rendered as a small keycap chip.
private struct KeycapView: View {
  let key: String

  var body: some View {
    Text(key)
      .font(.system(.callout, design: .monospaced).weight(.medium))
      .frame(minWidth: 22)
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(.quaternary)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .strokeBorder(.tertiary, lineWidth: 0.5)
      )
  }
}
