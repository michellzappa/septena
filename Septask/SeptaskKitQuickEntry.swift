#if os(macOS)
import AppKit
import Carbon.HIToolbox

// Things-style Quick Entry for the AppKit shell: ⌃Space anywhere (while
// Septask is running) floats a small capture panel without switching apps.
// Return files the capture to the Inbox (the triage band — the app's one
// home for loose captures); ⌘Return sends it straight to Today; Esc or
// clicking away dismisses. Writes go through TaskMutator like every other
// surface.
//
// The global hotkey uses the Carbon RegisterEventHotKey API — the sanctioned,
// sandbox-safe mechanism every quick-entry app uses (no event monitors, no
// accessibility permission). If Things is still running with its own ⌃Space
// registration, the two contend; quitting Things resolves it.
@MainActor
final class SeptaskKitQuickEntry: NSObject, NSTextFieldDelegate, NSWindowDelegate {

  static let shared = SeptaskKitQuickEntry()

  private var panel: NSPanel?
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

  private func ensurePanel() -> NSPanel {
    if let panel { return panel }

    let width: CGFloat = 560
    let content = NSVisualEffectView()
    content.material = .popover
    content.state = .active
    content.wantsLayer = true
    content.layer?.cornerRadius = 12
    content.layer?.masksToBounds = true

    field.placeholderString = String(localized: "New task…",
                                     comment: "SeptaskKit: quick entry placeholder")
    field.font = .systemFont(ofSize: SeptenaTypeScale.size(.title3))
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

    content.addSubview(field)
    content.addSubview(hint)
    NSLayoutConstraint.activate([
      field.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
      field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
      field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
      hint.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
      hint.leadingAnchor.constraint(equalTo: field.leadingAnchor),
      hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
    ])

    let panel = QuickEntryPanel(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 78),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.contentView = content
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
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

/// Borderless panels refuse key status by default; this one must take it so
/// the field can edit. ⌘Return is caught here because command-keys route via
/// performKeyEquivalent, not the field editor.
private final class QuickEntryPanel: NSPanel {
  var onCommandReturn: (() -> Void)?

  override var canBecomeKey: Bool { true }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
       event.keyCode == 36 {
      onCommandReturn?()
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}
#endif
