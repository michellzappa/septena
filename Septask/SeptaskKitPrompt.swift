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

  /// A destructive yes/no, app-modal. Cancel is the FIRST button, so it is
  /// the default (Return) — a reflexive Return can never destroy anything —
  /// and Escape also maps to it. The confirm button carries the destructive
  /// role, so the platform paints it. Prefer the sheet form below whenever a
  /// window is at hand; this one remains for callers that need a synchronous
  /// answer.
  static func confirmDestructive(title: String, message: String,
                                 confirmTitle: String? = nil) -> Bool {
    let alert = destructiveAlert(title: title, message: message, confirmTitle: confirmTitle)
    return alert.runModal() == .alertSecondButtonReturn
  }

  /// The same question as a window-modal sheet: it blocks only the window it
  /// is about, not the whole app. `onConfirm` runs only on the destructive
  /// answer. Falls back to the app-modal form when there is no window.
  static func confirmDestructive(title: String, message: String,
                                 confirmTitle: String? = nil,
                                 in window: NSWindow?,
                                 onConfirm: @escaping @MainActor () -> Void) {
    let alert = destructiveAlert(title: title, message: message, confirmTitle: confirmTitle)
    guard let window else {
      if alert.runModal() == .alertSecondButtonReturn { onConfirm() }
      return
    }
    alert.beginSheetModal(for: window) { response in
      guard response == .alertSecondButtonReturn else { return }
      MainActor.assumeIsolated { onConfirm() }
    }
  }

  private static func destructiveAlert(title: String, message: String,
                                       confirmTitle: String?) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    // Cancel first: the first button is the default (Return) button.
    // Set explicitly: AppKit also hands a button titled "Cancel" the Escape
    // equivalent, and Return must stay on Cancel.
    let cancel = alert.addButton(withTitle: String(localized: "Cancel",
                                                   comment: "SeptaskKit: prompt dismiss"))
    cancel.keyEquivalent = "\r"
    let confirm = confirmTitle
      ?? String(localized: "Delete", comment: "SeptaskKit: prompt confirm")
    let destructive = alert.addButton(withTitle: confirm)
    destructive.keyEquivalent = ""
    destructive.hasDestructiveAction = true
    return alert
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
