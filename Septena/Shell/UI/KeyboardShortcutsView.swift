import SwiftUI

// A read-only reference of every keyboard shortcut, grouped by area.
// Presented as a sheet from the Help menu (⇧⌘/) and discoverable on iPad
// (where it complements the hold-⌘ HUD).
//
// Built from the registry (`registry/actions.json`, `RegistryActions`), so it
// lists only what this platform binds: an action whose `availability.platforms`
// leaves this platform out, or whose shortcut excludes it, is not shown
// (#577). Only the list's own selection keys are written by hand below.

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
  // Septask's plain ⌘-digit smart lists (its Go menu), numbered by the
  // user's sidebar.
  @MainActor private static var navigation: KeyboardShortcutGroup {
    let prefs = SmartListPreferences.shared
    let digits = prefs.digitShortcuts
    let items: [KeyboardShortcut2] = prefs.enabledDestinations.compactMap { dest in
      digits[dest.id].map { KeyboardShortcut2(keys: $0.keycaps, label: dest.title) }
    }
    return KeyboardShortcutGroup(title: "Navigation", shortcuts: items)
  }

  private static var currentPlatformKey: String {
    #if os(macOS)
    "macos"
    #else
    "ipados"
    #endif
  }

  private static func fromRegistry(_ entries: [RegistryShortcutEntry]) -> [KeyboardShortcut2] {
    let platform = currentPlatformKey
    return entries
      .filter { !$0.excludePlatforms.contains(platform) }
      .filter { entry in
        let platforms = RegistryActions.availability[entry.actionId]?.platforms ?? []
        return platforms.isEmpty || platforms.contains(platform)
      }
      .map { KeyboardShortcut2(keys: $0.keycaps, label: $0.label) }
  }

  private static var generalGroup: KeyboardShortcutGroup {
    KeyboardShortcutGroup(title: "General", shortcuts: fromRegistry(RegistryActions.shortcutsGeneral))
  }

  /// Row commands are GENERATED from `RegistryActions` so
  /// this sheet can no longer advertise a binding the app doesn't have. Only
  /// the keys that aren't row commands — the selection/navigation keys the list
  /// handles itself — are listed by hand.
  private static var taskList: KeyboardShortcutGroup {
    var shortcuts = [
      KeyboardShortcut2(keys: ["↑", "↓"], label: "Move selection"),
      KeyboardShortcut2(keys: ["return"], label: "Open / edit"),
      KeyboardShortcut2(keys: ["esc"], label: "Clear selection"),
      KeyboardShortcut2(keys: ["esc"], label: "Save and close the open task"),
    ]
    shortcuts += fromRegistry(RegistryActions.shortcutsTaskList)
    return KeyboardShortcutGroup(title: "Task list", shortcuts: shortcuts)
  }

  @MainActor static var groups: [KeyboardShortcutGroup] { [
    navigation,
    generalGroup,
    taskList,
  ] }
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
      .navigationTitle(RegistryActions.title(.appKeyboardShortcuts))
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
