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
    alert.addButton(withTitle: "Cancel")
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
                                 confirmTitle: String = "Delete") -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: confirmTitle)
    alert.buttons.first?.hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }
}
#endif
