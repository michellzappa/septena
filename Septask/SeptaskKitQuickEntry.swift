#if os(macOS)
import AppKit
import Carbon.HIToolbox

// Things-style Quick Entry for the AppKit shell: floats a small capture
// panel without switching apps. A TIER 2 surface (SeptaskKitSurface.swift) —
// it captures into the app at large, so it has no row to anchor to and wears
// the shared `KitSurfacePanel` chrome. Return files the capture to the Inbox (the
// triage band — the app's one home for loose captures); ⌘Return sends it
// straight to Today; Esc or clicking away dismisses. Writes go through
// TaskMutator like every other surface.
//
// The global hotkey uses the Carbon RegisterEventHotKey API — the sanctioned,
// sandbox-safe mechanism every quick-entry app uses (no event monitors, no
// accessibility permission) — but installHotKey() is currently NOT called
// (see SeptaskLaunch.swift): ⌃Space also contends with Moom's own binding,
// so the global shortcut is disabled for now and Quick Entry is reachable
// only via the Window ▸ Quick Entry menu item. Pick a non-conflicting
// key/modifier before re-enabling.
@MainActor
final class SeptaskKitQuickEntry: NSObject, NSTextFieldDelegate, NSWindowDelegate {

  static let shared = SeptaskKitQuickEntry()

  private var panel: KitSurfacePanel?
  private let field = NSTextField()
  private static var hotKeyRef: EventHotKeyRef?

  // MARK: - Hotkey

  /// Idempotent; called once from the app root's launch task.
  static func installHotKey() {
    guard hotKeyRef == nil else { return }
    var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                  eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
      Task { @MainActor in SeptaskKitQuickEntry.show() }
      return noErr
    }, 1, &eventType, nil, nil)
    let hotKeyID = EventHotKeyID(signature: OSType(0x5350_5145) /* "SPQE" */, id: 1)
    RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey), hotKeyID,
                        GetApplicationEventTarget(), 0, &hotKeyRef)
  }

  // MARK: - Panel

  static func show() { shared.present() }

  private func present() {
    let panel = ensurePanel()
    field.stringValue = ""
    if let screen = NSScreen.main {
      let frame = screen.visibleFrame
      let size = panel.frame.size
      // Upper third of the screen, centered — where every quick-entry
      // panel on the platform sits.
      panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                   y: frame.minY + frame.height * 0.62))
    }
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(field)
  }

  private func dismiss() {
    panel?.orderOut(nil)
  }

  private func ensurePanel() -> KitSurfacePanel {
    if let panel { return panel }

    field.placeholderString = String(localized: "New task…",
                                     comment: "SeptaskKit: quick entry placeholder")
    field.font = KitSurface.fieldFont
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.delegate = self
    field.translatesAutoresizingMaskIntoConstraints = false

    let hint = NSTextField(labelWithString: String(
      localized: "↩ Inbox    ⌘↩ Today    esc Cancel",
      comment: "SeptaskKit: quick entry shortcut legend"))
    hint.font = SeptaskKitTheme.meta
    hint.textColor = SeptaskKitTheme.iconMuted
    hint.translatesAutoresizingMaskIntoConstraints = false

    let body = NSView()
    body.addSubview(field)
    body.addSubview(hint)
    let inset = KitSurface.listInset + 2
    NSLayoutConstraint.activate([
      field.topAnchor.constraint(equalTo: body.topAnchor, constant: 16),
      field.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: inset),
      field.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -inset),
      hint.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
      hint.leadingAnchor.constraint(equalTo: field.leadingAnchor),
      hint.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -12),
    ])

    let panel = KitSurfacePanel.make(
      size: NSSize(width: 560, height: 78),
      a11yTitle: String(localized: "Quick Entry",
                        comment: "SeptaskKit: quick entry panel a11y title"))
    panel.install(body)
    panel.delegate = self
    panel.onCommandReturn = { [weak self] in self?.save(today: true) }
    self.panel = panel
    return panel
  }

  // MARK: - Saving

  private func save(today: Bool) {
    let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    dismiss()
    guard !title.isEmpty else { return }
    Task { @MainActor in
      // The panel can fire before the runtime is warm (start() memoizes).
      await SeptenaServices.shared.start()
      _ = SeptenaServices.shared.taskMutator.create(title: title, today: today)
      // Local mutations don't broadcast on their own; both shells listen for
      // this, so the capture appears everywhere at once.
      NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    }
  }

  // MARK: - NSTextFieldDelegate / NSWindowDelegate

  /// One task, one line: flatten a pasted multi-line string as it lands rather
  /// than letting the panel hold breaks it will never save.
  func controlTextDidChange(_ obj: Notification) {
    field.septaskFlattenPastedLineBreaks()
  }

  func control(_ control: NSControl, textView: NSTextView,
               doCommandBy commandSelector: Selector) -> Bool {
    switch commandSelector {
    case #selector(NSResponder.insertNewline(_:)):
      let command = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
      save(today: command)
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      dismiss()
      return true
    default:
      return false
    }
  }

  /// Clicking anywhere else dismisses, like every transient panel.
  func windowDidResignKey(_ notification: Notification) {
    dismiss()
  }
}

#endif
