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
//
// The copy is the registry's (`registry/surfaces.json` `prompts`, generated as
// `RegistryPrompts`): the SwiftUI dialogs read the same `RegistryPromptCopy`,
// so the two shells can never word one question differently.
@MainActor
enum KitPrompt {

  /// A destructive yes/no, app-modal. Cancel is the FIRST button, so it is
  /// the default (Return) — a reflexive Return can never destroy anything —
  /// and Escape also maps to it. The confirm button carries the destructive
  /// role, so the platform paints it. Prefer the sheet form below whenever a
  /// window is at hand; this one remains for callers that need a synchronous
  /// answer.
  static func confirmDestructive(_ copy: RegistryPromptCopy) -> Bool {
    destructiveAlert(copy).runModal() == .alertSecondButtonReturn
  }

  /// The same question as a window-modal sheet: it blocks only the window it
  /// is about, not the whole app. `onConfirm` runs only on the destructive
  /// answer. Falls back to the app-modal form when there is no window.
  static func confirmDestructive(_ copy: RegistryPromptCopy,
                                 in window: NSWindow?,
                                 onConfirm: @escaping @MainActor () -> Void) {
    let alert = destructiveAlert(copy)
    guard let window else {
      if alert.runModal() == .alertSecondButtonReturn { onConfirm() }
      return
    }
    alert.beginSheetModal(for: window) { response in
      guard response == .alertSecondButtonReturn else { return }
      MainActor.assumeIsolated { onConfirm() }
    }
  }

  private static func destructiveAlert(_ copy: RegistryPromptCopy) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = copy.title
    alert.informativeText = copy.message
    // Cancel first: the first button is the default (Return) button.
    // Set explicitly: AppKit also hands a button titled "Cancel" the Escape
    // equivalent, and Return must stay on Cancel.
    let cancel = alert.addButton(withTitle: RegistryPrompts.cancelTitle)
    cancel.keyEquivalent = "\r"
    let destructive = alert.addButton(withTitle: copy.confirmTitle ?? copy.title)
    destructive.keyEquivalent = ""
    destructive.hasDestructiveAction = true
    return alert
  }

  /// A fork with more than two answers — the reschedule-repeating question is
  /// the shell's only one. Returns the id of the chosen option, or nil when
  /// the user cancelled. Cancel is appended here so no caller can forget it.
  static func choice(_ copy: RegistryPromptCopy) -> RegistryPromptOptionID? {
    let alert = NSAlert()
    alert.messageText = copy.title
    alert.informativeText = copy.message
    for option in copy.options { alert.addButton(withTitle: option.title) }
    alert.addButton(withTitle: RegistryPrompts.cancelTitle)
    let chosen = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    guard chosen >= 0, chosen < copy.options.count else { return nil }
    return copy.options[chosen].id
  }
}
#endif
