#if os(macOS)
import AppKit

// Small NSAlert-based prompts shared by the sidebar (area/project CRUD) and
// the task list (heading CRUD) — one text-entry dialog and one destructive
// confirmation, rather than each surface growing its own copy.
@MainActor
enum KitPrompt {
  static func text(title: String, placeholder: String,
                   initial: String = "", confirmTitle: String) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.addButton(withTitle: confirmTitle)
    alert.addButton(withTitle: String(localized: "Cancel", comment: "SeptaskKit: prompt dismiss"))
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.placeholderString = placeholder
    field.stringValue = initial
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

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
}
#endif
