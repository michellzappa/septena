#if os(macOS)
import AppKit

// TIER 3 of SeptaskKitSurface.swift: the alert. It is for decisions that are
// irreversible or genuinely forked — never for editing a value, and never for
// naming something. Naming happens inline in the row that holds the name, the
// way Finder renames a file, so the shell no longer stops the whole app to ask
// for a string.
//
// Every alert in the AppKit shell is built here. There used to be a third one
// hand-rolled inside the task list, which is exactly how alert copy and button
// order drift apart.
@MainActor
enum KitPrompt {

  /// A destructive yes/no. The confirm button carries the destructive role, so
  /// the platform paints it.
  static func confirmDestructive(title: String, message: String,
                                 confirmTitle: String? = nil) -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    let confirm = confirmTitle
      ?? String(localized: "Delete", comment: "SeptaskKit: prompt confirm")
    alert.addButton(withTitle: confirm)
    alert.buttons.first?.hasDestructiveAction = true
    alert.addButton(withTitle: String(localized: "Cancel", comment: "SeptaskKit: prompt dismiss"))
    return alert.runModal() == .alertFirstButtonReturn
  }

  /// A fork with more than two answers — the reschedule-repeating question is
  /// the shell's only one. Returns the index of the chosen option, or nil when
  /// the user cancelled. Cancel is appended here so no caller can forget it.
  static func choice(title: String, message: String, options: [String]) -> Int? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    for option in options { alert.addButton(withTitle: option) }
    alert.addButton(withTitle: String(localized: "Cancel", comment: "SeptaskKit: prompt dismiss"))
    let chosen = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    guard chosen >= 0, chosen < options.count else { return nil }
    return chosen
  }
}
#endif
