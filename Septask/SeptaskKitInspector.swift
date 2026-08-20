#if os(macOS)
import AppKit
import SwiftData

// The task inspector: title, notes, and the scheduling attributes for the
// selected row, in a native split-view inspector pane (⌥⌘I). This is where
// notes live in the AppKit shell — the equivalent of the SwiftUI drawer
// inspector, and the reason task detail doesn't need a sheet.
//
// Writes go through TaskMutator like every other surface. Edits commit on
// blur and on selection change (`flushPendingEdits`), never on every
// keystroke — a per-keystroke write would push a CloudKit change per letter.
@MainActor
final class SeptaskKitInspectorController: NSViewController, NSTextViewDelegate, NSTextFieldDelegate {

  private let titleField = NSTextField()
  private let notesView = NSTextView()
  private let whenButton = NSButton()
  private let deadlineButton = NSButton()
  private let repeatButton = NSButton()
  private let listLabel = NSTextField(labelWithString: "")
  private let placeholder = NSTextField(labelWithString: String(localized: "No Selection",
                                                                 comment: "SeptaskKit: inspector empty"))
  private let form = NSStackView()
  /// The pane's own close control — the VISIBLE twin of `cancelOperation`'s
  /// Escape handling. The inspector is a plain split-view item with no title
  /// bar of its own, so without this the only ways out are Escape and ⌥⌘I,
  /// neither of which you can find by looking at the pane.
  private let closeButton = NSButton()

  /// Escape asks the shell to collapse the pane. The inspector is a plain
  /// split-view item with no chrome of its own, so it reports the intent and
  /// `SeptaskKitWindowController` does the closing.
  var onRequestClose: (() -> Void)?

  private var task: SeptenaTask?
  /// What was loaded into the fields, so a commit can tell "the user changed
  /// this" from "this is what the store already says".
  private var loadedTitle = ""
  private var loadedNotes = ""

  private var mutator: TaskMutator { SeptenaServices.shared.taskMutator }
  private var context: ModelContext { LocalStore.shared.container.mainContext }

  override func loadView() {
    let root = NSView()

    titleField.font = .systemFont(ofSize: SeptenaTypeScale.size(.headline), weight: .semibold)
    titleField.isBordered = false
    titleField.drawsBackground = false
    titleField.focusRingType = .none
    titleField.lineBreakMode = .byTruncatingTail
    titleField.delegate = self
    titleField.translatesAutoresizingMaskIntoConstraints = false

    let notesScroll = NSScrollView()
    notesScroll.hasVerticalScroller = true
    notesScroll.drawsBackground = false
    notesScroll.translatesAutoresizingMaskIntoConstraints = false
    notesView.delegate = self
    notesView.isRichText = true
    notesView.importsGraphics = false
    notesView.allowsUndo = true
    notesView.drawsBackground = false
    notesView.textContainerInset = NSSize(width: 2, height: 6)
    notesView.isAutomaticQuoteSubstitutionEnabled = false
    notesView.typingAttributes = MarkdownNotesStyle.baseAttributes(
      fontSize: SeptaskKitTheme.notesFontSize)
    notesScroll.documentView = notesView

    let notesLabel = NSTextField(labelWithString: String(localized: "Notes",
                                                         comment: "SeptaskKit: inspector field"))
    notesLabel.font = SeptaskKitTheme.chip
    notesLabel.textColor = SeptaskKitTheme.iconMuted

    for (button, action) in [(whenButton, #selector(editWhen)),
                             (deadlineButton, #selector(editDeadline))] {
      button.bezelStyle = .rounded
      button.target = self
      button.action = action
      button.alignment = .left
    }
    repeatButton.bezelStyle = .rounded
    repeatButton.target = self
    repeatButton.action = #selector(editRepeat)
    repeatButton.alignment = .left
    listLabel.font = SeptaskKitTheme.meta
    listLabel.textColor = SeptaskKitTheme.inkSecondary

    form.orientation = .vertical
    form.alignment = .leading
    form.spacing = 8
    form.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
    form.translatesAutoresizingMaskIntoConstraints = false
    form.addArrangedSubview(titleField)
    form.addArrangedSubview(listLabel)
    form.addArrangedSubview(whenButton)
    form.addArrangedSubview(deadlineButton)
    form.addArrangedSubview(repeatButton)
    form.addArrangedSubview(notesLabel)
    form.addArrangedSubview(notesScroll)
    form.setCustomSpacing(14, after: repeatButton)

    placeholder.textColor = SeptaskKitTheme.iconMuted
    placeholder.translatesAutoresizingMaskIntoConstraints = false

    let closeLabel = String(localized: "Close Inspector",
                            comment: "SeptaskKit: inspector close button")
    closeButton.translatesAutoresizingMaskIntoConstraints = false
    closeButton.isBordered = false
    closeButton.bezelStyle = .inline
    closeButton.imagePosition = .imageOnly
    closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
    closeButton.contentTintColor = SeptaskKitTheme.iconMuted
    closeButton.target = self
    closeButton.action = #selector(closePane)
    // Keyboard focus belongs to the fields — Escape and ⌥⌘I are the key
    // paths out. Same reason the list's checkbox refuses first responder.
    closeButton.refusesFirstResponder = true
    closeButton.setAccessibilityLabel(closeLabel)
    // Icon-only chrome control: the tooltip is how you learn what it does.
    // (Distinct from task rows, which carry no tooltips by design.)
    closeButton.toolTip = closeLabel

    root.addSubview(form)
    root.addSubview(placeholder)
    // Last, so it layers above the form's title field.
    root.addSubview(closeButton)
    NSLayoutConstraint.activate([
      form.topAnchor.constraint(equalTo: root.topAnchor),
      form.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      form.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      form.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      // -52, not the -28 the notes field uses: the title shares its band with
      // the close button and must not run under it.
      titleField.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -52),
      closeButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
      closeButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
      closeButton.widthAnchor.constraint(equalToConstant: 20),
      closeButton.heightAnchor.constraint(equalToConstant: 20),
      notesScroll.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -28),
      notesScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
      placeholder.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      placeholder.centerYAnchor.constraint(equalTo: root.centerYAnchor),
    ])
    view = root
    show(nil)
  }

  // MARK: - Selection

  /// Load a task (or clear). Any in-flight edit for the previous task commits
  /// first, so switching rows can't silently drop what was typed.
  ///
  /// Re-showing the SAME task (e.g. `refresh()` after a background sync)
  /// does NOT touch `titleField`/`notesView` — only the read-only fields
  /// (dates, list, repeat) resync. This is load-bearing, not cosmetic: this
  /// method used to overwrite the title field unconditionally, so a refresh
  /// landing between typing and committing silently reverted whatever the
  /// user had typed back to the stored value — and since that reset BOTH the
  /// field and `loadedTitle` together, the next commit's "did it change"
  /// check then saw no difference and never wrote the edit. `refresh()`'s
  /// `isEditing` guard was supposed to prevent this, but a field/store
  /// mismatch shouldn't be possible in the first place — belt and braces.
  func show(_ next: SeptenaTask?) {
    guard next?.id != task?.id else {
      task = next
      if let next { refreshReadOnlyFields(next) }
      return
    }
    flushPendingEdits()
    task = next

    guard let next, !next.isHeading else {
      form.isHidden = true
      placeholder.isHidden = false
      return
    }
    form.isHidden = false
    placeholder.isHidden = true

    // Opening to peek must NOT acknowledge. Cue == Inbox membership for
    // agent rows, so ratifying here would yank a proposal the moment it
    // became the selected row (even with this pane collapsed). Same
    // contract as SwiftUI `TaskComposer`. Disposition paths below ack.

    loadedTitle = next.title
    loadedNotes = next.notes ?? ""
    titleField.stringValue = loadedTitle
    let fontSize = SeptaskKitTheme.notesFontSize
    notesView.textStorage?.setAttributedString(
      MarkdownNotesStyle.attributed(loadedNotes, fontSize: fontSize))
    notesView.typingAttributes = MarkdownNotesStyle.baseAttributes(fontSize: fontSize)
    refreshReadOnlyFields(next)
  }

  /// The dates/list/repeat controls — safe to resync on every re-show,
  /// same-task or not, since nothing here is a live text edit in progress.
  private func refreshReadOnlyFields(_ next: SeptenaTask) {
    let when: String = if next.today {
      String(localized: "Today", comment: "Smart list title")
    } else if let scheduled = next.scheduled {
      KitDayFormat.display(scheduled)
    } else {
      String(localized: "Anytime", comment: "Smart list title")
    }
    whenButton.title = String(localized: "When: \(when)",
                              comment: "SeptaskKit: inspector when field")
    let deadlineValue = next.deadline.map(KitDayFormat.display)
      ?? String(localized: "None", comment: "No deadline")
    deadlineButton.title = String(localized: "Deadline: \(deadlineValue)",
                                  comment: "SeptaskKit: inspector deadline field")
    listLabel.stringValue = listDescription(for: next)

    let repeatValue = next.recurrence.map { rule in
      let paused = next.recurrencePaused
        ? String(localized: " (Paused)", comment: "Repeat paused suffix")
        : ""
      return "\(rule.shortLabel)\(paused)"
    } ?? String(localized: "None", comment: "No repeat")
    repeatButton.title = String(localized: "Repeat: \(repeatValue)",
                                comment: "SeptaskKit: inspector repeat field")
  }

  /// Re-read the shown task from the store — used when a refresh lands while
  /// the inspector is open. `show(_:)`'s own same-id guard is now the real
  /// protection for in-progress title/notes edits; `isEditing` here just
  /// avoids pointless work while actively typing.
  func refresh() {
    guard let id = task?.id, !isEditing else { return }
    let fresh = LocalCache.allTasks(in: context).first { $0.id == id }
    show(fresh)
  }

  private var isEditing: Bool {
    view.window?.firstResponder === notesView
      || (view.window?.firstResponder as? NSTextView)?.delegate === titleField
  }

  private func listDescription(for task: SeptenaTask) -> String {
    let snapshot = StructureCache.snapshot(in: context)
    if let id = task.project,
       let project = snapshot.projects.first(where: { $0.id == id }) {
      return String(localized: "In \(project.title)",
                    comment: "SeptaskKit: inspector list affiliation")
    }
    if let id = task.area,
       let area = snapshot.areas.first(where: { $0.id == id }) {
      return String(localized: "In \(area.title)",
                    comment: "SeptaskKit: inspector list affiliation")
    }
    return String(localized: "No list", comment: "SeptaskKit: inspector list affiliation")
  }

  // MARK: - Commits

  /// Commit whatever is in the fields. Safe to call repeatedly — it only
  /// writes when a value actually differs from what was loaded.
  func flushPendingEdits() {
    guard let current = task else { return }
    var changed = false

    let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if !title.isEmpty, title != loadedTitle {
      mutator.update(id: current.id, title: title)
      loadedTitle = title
      changed = true
    }

    let notes = notesView.string
    if notes != loadedNotes {
      // Empty clears the note rather than storing an empty string.
      mutator.update(id: current.id, notes: notes.isEmpty ? nil : notes)
      loadedNotes = notes
      changed = true
    }

    if changed {
      NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    }
  }

  func controlTextDidBeginEditing(_ obj: Notification) {
    // Truncation fights the field-editor scroll and jumps the caret to the
    // far right while typing or arrowing through a long title.
    titleField.lineBreakMode = .byClipping
  }

  func controlTextDidEndEditing(_ obj: Notification) {
    titleField.lineBreakMode = .byTruncatingTail
    flushPendingEdits()
  }

  func textDidChange(_ notification: Notification) {
    guard let textView = notification.object as? NSTextView, textView === notesView else { return }
    MarkdownNotesStyle.restyle(textView, fontSize: SeptaskKitTheme.notesFontSize)
  }

  func textDidEndEditing(_ notification: Notification) { flushPendingEdits() }

  /// The standard "back out of this pane" responder method. It reaches the
  /// controller whenever focus is inside the inspector and no field editor
  /// claimed Escape first — a live title edit still cancels itself on the
  /// first Escape (platform behavior), and the second one closes the pane.
  override func cancelOperation(_ sender: Any?) { onRequestClose?() }

  @objc private func closePane() {
    // Commit first: the pane can be closed mid-edit, and the field's own
    // end-editing notification does not fire when the view goes away.
    flushPendingEdits()
    onRequestClose?()
  }

  /// NSTextView answers Escape with autocomplete, which would swallow it, so
  /// the notes view routes Escape to the same close as everything else.
  func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    guard textView === notesView,
          commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
    onRequestClose?()
    return true
  }

  // MARK: - Dates

  @objc private func editRepeat() {
    guard let current = task else { return }
    SeptaskKitRecurrencePanelController.present(
      initial: current.recurrence,
      paused: current.recurrencePaused,
      hasScheduledDate: current.scheduled != nil
    ) { [weak self] result in
      guard let self else { return }
      if let recurrence = result.recurrence {
        self.mutator.setRecurrence(id: current.id, recurrence: recurrence)
        self.mutator.setRecurrencePaused(id: current.id, paused: result.paused)
      } else {
        self.mutator.setRecurrence(id: current.id, recurrence: nil)
      }
      NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
      self.refresh()
    }
  }

  @objc private func editWhen() { presentPopover(kind: .when, from: whenButton) }
  @objc private func editDeadline() { presentPopover(kind: .deadline, from: deadlineButton) }

  private func presentPopover(kind: SeptaskKitDatePopover.Kind, from button: NSButton) {
    guard let current = task else { return }
    let initial: Date? = switch kind {
    case .when: KitDayFormat.date(fromWire: current.scheduled)
    case .deadline: KitDayFormat.date(fromWire: current.deadline)
    }

    SeptaskKitDatePopover.present(kind: kind, initial: initial,
                                  relativeTo: button.bounds, of: button) { [weak self] date, today in
      guard let self else { return }
      switch kind {
      case .when:
        if today {
          self.mutator.moveToToday(id: current.id)
        } else {
          self.mutator.schedule(id: current.id, date: date)
          self.mutator.removeFromToday(id: current.id)
        }
      case .deadline:
        self.mutator.setDeadline(id: current.id, date: date)
      }
      self.mutator.acknowledge(id: current.id)
      NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
      self.refresh()
    }
  }
}
#endif
