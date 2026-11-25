#if os(macOS)
import AppKit
import Carbon.HIToolbox

// Things-style Quick Entry for the AppKit shell: floats a small capture
// panel without switching apps. A TIER 2 surface (SeptaskKitSurface.swift) —
// it captures into the app at large, so it has no row to anchor to and wears
// the shared `KitSurfacePanel` chrome. Return files the capture to the Inbox (the
// triage band — the app's one home for loose captures); ⌘Return sends it
// straight to Today. Esc discards the draft and dismisses; clicking away only
// hides the panel and KEEPS the draft, so a half-typed capture is still there
// on the next show. Add and Do files the capture and starts a Do of it
// (docs/DO_SPEC.md §4.1). Writes go through TaskMutator like every other surface.
//
// The global hotkey is ⌃⌥Space, through the Carbon RegisterEventHotKey API —
// the sanctioned, sandbox-safe mechanism every quick-entry app uses (no event
// monitors, no Accessibility permission). Not ⌃Space: that is the system's
// input-source switch, and Moom also binds it. Installed at launch by
// `SeptaskMacAppDelegate`; Go ▸ Quick Entry shows the same combination.
@MainActor
final class SeptaskKitQuickEntry: NSObject, NSTextFieldDelegate, NSWindowDelegate {

  static let shared = SeptaskKitQuickEntry()

  private var panel: KitSurfacePanel?
  private let field = NSTextField()
  private static var hotKeyRef: EventHotKeyRef?

  // MARK: - Hotkey

  /// The global combination — keep `SeptaskCommandMenus`' Go ▸ Quick Entry
  /// item showing the same keys.
  private static let hotKeyCode = UInt32(kVK_Space)
  private static let hotKeyModifiers = UInt32(controlKey | optionKey)

  /// Idempotent; called once from the app delegate at launch.
  static func installHotKey() {
    guard hotKeyRef == nil else { return }
    var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                  eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
      Task { @MainActor in SeptaskKitQuickEntry.show() }
      return noErr
    }, 1, &eventType, nil, nil)
    let hotKeyID = EventHotKeyID(signature: OSType(0x5350_5145) /* "SPQE" */, id: 1)
    let status = RegisterEventHotKey(hotKeyCode, hotKeyModifiers, hotKeyID,
                                     GetApplicationEventTarget(), 0, &hotKeyRef)
    if status != noErr {
      // Another app (or a system shortcut) already owns the combination. The
      // menu item still opens the panel.
      hotKeyRef = nil
      SeptenaLog.info("[QuickEntry] global hotkey not registered (\(status))")
    }
  }

  // MARK: - Panel

  static func show() { shared.present() }

  private func present() {
    let panel = ensurePanel()
    // The draft is NOT cleared here: clicking away keeps it (see
    // `windowDidResignKey`). Only a save or an explicit Esc empties it.
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
    field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.utf16.count,
                                                   length: 0)
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

    let addAndDo = SeptaskKitDo.button(.doAddAndDo, target: self, action: #selector(addAndDoPressed))
    addAndDo.controlSize = .small
    addAndDo.isHidden = !RegistryActions.isAvailableOnPlatform(.doAddAndDo)
    addAndDo.translatesAutoresizingMaskIntoConstraints = false

    let body = NSView()
    body.addSubview(field)
    body.addSubview(hint)
    body.addSubview(addAndDo)
    let inset = KitSurface.listInset + 2
    NSLayoutConstraint.activate([
      field.topAnchor.constraint(equalTo: body.topAnchor, constant: 16),
      field.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: inset),
      field.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -inset),
      hint.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
      hint.leadingAnchor.constraint(equalTo: field.leadingAnchor),
      hint.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -12),
      addAndDo.trailingAnchor.constraint(equalTo: field.trailingAnchor),
      addAndDo.centerYAnchor.constraint(equalTo: hint.centerYAnchor),
    ])

    let panel = KitSurfacePanel.make(
      size: NSSize(width: 560, height: 78),
      a11yTitle: RegistryActions.title(.appQuickEntry))
    panel.install(body)
    panel.delegate = self
    panel.onCommandReturn = { [weak self] in self?.save(today: true) }
    self.panel = panel
    return panel
  }

  // MARK: - Saving

  @objc private func addAndDoPressed() { save(today: false, startsDo: true) }

  private func save(today: Bool, startsDo: Bool = false) {
    let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    dismiss()
    guard !title.isEmpty else { return }
    // Saved: the draft is spent.
    field.stringValue = ""
    Task { @MainActor in
      // The panel can fire before the runtime is warm (start() memoizes).
      await SeptenaServices.shared.start()
      let task = SeptenaServices.shared.taskMutator.create(title: title, today: today)
      // Local mutations don't broadcast on their own; both shells listen for
      // this, so the capture appears everywhere at once.
      NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
      if startsDo {
        SeptaskKitDo.shared.begin(taskID: task.id)
        SeptaskKitDo.shared.showShell()
      }
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
      // Explicit Esc is the one gesture that throws the draft away.
      field.stringValue = ""
      dismiss()
      return true
    default:
      return false
    }
  }

  /// Clicking anywhere else hides the panel, like every transient panel, but
  /// keeps the draft for the next show.
  func windowDidResignKey(_ notification: Notification) {
    dismiss()
  }
}

#endif
