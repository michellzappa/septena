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
  private let reminderButton = NSButton()
  private let repeatButton = NSButton()
  private let starButton = NSButton()
  private let tagsButton = NSButton()
  private let addChecklistButton = NSButton()
  private let checklistLabel = NSTextField(labelWithString:
    String(localized: "Checklist", comment: "SeptaskKit: inspector section"))
  private let checklistView = KitChecklistView()
  private let listLabel = NSTextField(labelWithString: "")
  private let placeholder = NSTextField(labelWithString: String(localized: "No Selection",
                                                                 comment: "SeptaskKit: inspector empty"))
  private let form = NSStackView()
  /// Task Conversations — the agent's work log for this row. Shown only when
  /// a conversation exists; a task with no agent history gets no header and no
  /// empty box (docs/SEPTASK_CONVERSATIONS_PLAN.md).
  private let conversationLabel = NSTextField(labelWithString:
    String(localized: "Conversation", comment: "SeptaskKit: inspector section"))
  private let conversationView = KitConversationView()
  /// Who changed the task and what (SeptaskKitHistory.swift). Loads only
  /// while open.
  private let historyView = KitHistoryView()
  /// The pane's own close control — the VISIBLE twin of `cancelOperation`'s
  /// Escape handling. The inspector is a plain split-view item with no title
  /// bar of its own, so without this the only ways out are Escape and ⌥⌘I,
  /// neither of which you can find by looking at the pane.
  private let closeButton = NSButton()

  /// Escape asks the shell to collapse the pane. The inspector is a plain
  /// split-view item with no chrome of its own, so it reports the intent and
  /// `SeptaskKitWindowController` does the closing.
  var onRequestClose: (() -> Void)?
  /// ⌘↩ inside the pane — commit and hand the keyboard back to the list, the
  /// same "leave notes" gesture the inline composer answers. The pane stays
  /// open; ⌘↩ is the notes exit, Escape is the pane's.
  var onRequestFocusList: (() -> Void)?

  private var task: SeptenaTask?
  /// What was loaded into the fields, so a commit can tell "the user changed
  /// this" from "this is what the store already says". `loadedNotes` is held
  /// in its SAVED form (`Self.savedNotes`), so a field that differs only by a
  /// trailing newline never reads as an edit.
  private var loadedTitle = ""
  private var loadedNotes = ""
  /// Typing undo stays LOCAL to the pane while a field is being edited, like
  /// the composer's: ⌘Z mid-word undoes the word, not the last task command.
  /// Cleared after every commit, so a later ⌘Z never replays keystrokes into
  /// a field showing a different task. Outside a field the window's manager
  /// (the shared `TaskUndo` stack) answers.
  private let textUndo = UndoManager()

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
    notesScroll.borderType = .noBorder
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
                             (deadlineButton, #selector(editDeadline)),
                             (reminderButton, #selector(editReminder)),
                             (starButton, #selector(toggleStar)),
                             (tagsButton, #selector(editTags)),
                             (addChecklistButton, #selector(addChecklistStep))] {
      button.bezelStyle = .rounded
      button.target = self
      button.action = action
      button.alignment = .left
    }
    addChecklistButton.title = String(localized: "Add Checklist…", comment: "SeptaskKit: inspector add checklist")
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
    form.addArrangedSubview(reminderButton)
    form.addArrangedSubview(repeatButton)
    form.addArrangedSubview(starButton)
    form.addArrangedSubview(tagsButton)
    form.addArrangedSubview(addChecklistButton)
    form.addArrangedSubview(notesLabel)
    form.addArrangedSubview(notesScroll)
    checklistLabel.font = SeptaskKitTheme.chip
    checklistLabel.textColor = SeptaskKitTheme.iconMuted
    checklistView.translatesAutoresizingMaskIntoConstraints = false
    checklistView.onChanged = { [weak self] in
      guard let self else { return }
      self.updateChecklistVisibility()
      NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    }
    form.addArrangedSubview(checklistLabel)
    form.addArrangedSubview(checklistView)
    conversationLabel.font = SeptaskKitTheme.chip
    conversationLabel.textColor = SeptaskKitTheme.iconMuted
    conversationView.translatesAutoresizingMaskIntoConstraints = false
    // A reply appends a turn, which posts a task change; re-read so the new
    // turn lands in the transcript the same way an agent turn would.
    conversationView.onAppend = { [weak self] in self?.refresh() }
    form.addArrangedSubview(conversationLabel)
    form.addArrangedSubview(conversationView)
    historyView.translatesAutoresizingMaskIntoConstraints = false
    historyView.listTitle = { [weak self] id in
      guard let self else { return nil }
      let snapshot = StructureCache.snapshot(in: self.context)
      return snapshot.projects.first { $0.id == id }?.title ?? snapshot.areas.first { $0.id == id }?.title
    }
    form.addArrangedSubview(historyView)
    form.setCustomSpacing(14, after: addChecklistButton)
    form.setCustomSpacing(14, after: notesScroll)
    form.setCustomSpacing(14, after: checklistView)
    form.setCustomSpacing(14, after: conversationView)

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

    // The form scrolls: a long conversation (or a short window) used to push
    // the lower controls off the bottom with no way to reach them. The
    // document view is flipped so the form hangs from the top, and it is at
    // least as tall as the visible area so short content does not float.
    let formScroll = NSScrollView()
    formScroll.translatesAutoresizingMaskIntoConstraints = false
    formScroll.hasVerticalScroller = true
    formScroll.autohidesScrollers = true
    formScroll.drawsBackground = false
    formScroll.borderType = .noBorder
    let document = KitFlippedView()
    document.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(form)
    formScroll.documentView = document
    self.formScroll = formScroll

    root.addSubview(formScroll)
    root.addSubview(placeholder)
    // Last, so it layers above the form's title field.
    root.addSubview(closeButton)
    let clip = formScroll.contentView
    NSLayoutConstraint.activate([
      formScroll.topAnchor.constraint(equalTo: root.topAnchor),
      formScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      formScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      formScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      document.topAnchor.constraint(equalTo: clip.topAnchor),
      document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
      document.widthAnchor.constraint(equalTo: clip.widthAnchor),
      document.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor),
      form.topAnchor.constraint(equalTo: document.topAnchor),
      form.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      form.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      form.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),
      // Low priority: the document is exactly as tall as the form unless the
      // visible area is taller (the `>=` above wins then).
      {
        let hug = document.bottomAnchor.constraint(equalTo: form.bottomAnchor)
        hug.priority = .defaultLow
        return hug
      }(),
      // -52, not the -28 the notes field uses: the title shares its band with
      // the close button and must not run under it.
      titleField.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -52),
      closeButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
      closeButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
      closeButton.widthAnchor.constraint(equalToConstant: 20),
      closeButton.heightAnchor.constraint(equalToConstant: 20),
      notesScroll.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -28),
      checklistView.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -28),
      conversationView.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -28),
      historyView.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -28),
      notesScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
      placeholder.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      placeholder.centerYAnchor.constraint(equalTo: root.centerYAnchor),
    ])
    view = root

    // Explicit keyboard order through the pane: title → notes → the date
    // controls → back to the title. (The buttons join the loop only with
    // Full Keyboard Access on — AppKit skips them otherwise.)
    titleField.nextKeyView = notesView
    notesView.nextKeyView = whenButton
    whenButton.nextKeyView = deadlineButton
    deadlineButton.nextKeyView = reminderButton
    reminderButton.nextKeyView = repeatButton
    repeatButton.nextKeyView = starButton
    starButton.nextKeyView = tagsButton
    tagsButton.nextKeyView = titleField
    show(nil)
  }

  private var formScroll: NSScrollView?

  /// ⌥⌘I / Show Info opened the pane from the keyboard: the title takes it,
  /// caret at the end. No-op with nothing selected.
  func focusTitle() {
    guard task != nil, !form.isHidden, let window = view.window else { return }
    window.makeFirstResponder(titleField)
    if let editor = titleField.currentEditor() {
      editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
    }
  }

  /// ⌘↩ while the keyboard is in the pane: save and hand the keyboard back
  /// to the list. The shell's window calls this AHEAD of the view hierarchy's
  /// key equivalents (`KitShellWindow`). Returns false — and does nothing —
  /// when the keyboard is elsewhere, so the list's own ⌘↩ still works.
  func handleCommandReturn() -> Bool {
    guard let responder = view.window?.firstResponder as? NSView,
          responder.isDescendant(of: view) else { return false }
    // Deferred a tick: the commit's synchronous mutator notification can call
    // `makeFirstResponder` back into the list while this key event is still
    // on the stack — same hazard `KitComposerCell.deferCommitAndCollapse`
    // documents.
    DispatchQueue.main.async { [weak self] in self?.commitAndReturnToList() }
    return true
  }

  /// Save both fields and give the keyboard back to the list (the pane stays
  /// open). The exit for Esc / Return in the title, Esc in notes, and ⌘↩.
  private func commitAndReturnToList() {
    flushPendingEdits()
    onRequestFocusList?()
  }

  /// The pane's undo manager: the local typing stack while a text field here
  /// is being edited, the shared task stack otherwise. Reached through the
  /// responder chain from the title's field editor and the notes view (which
  /// also asks its delegate, `undoManager(for:)`, below).
  override var undoManager: UndoManager? {
    isEditing ? textUndo : TaskUndo.manager
  }

  func undoManager(for view: NSTextView) -> UndoManager? { textUndo }

  // MARK: - Selection

  /// Load a task (or clear). Any in-flight edit for the previous task commits
  /// first, so switching rows can't silently drop what was typed.
  ///
  /// Re-showing the SAME task (e.g. `refresh()` after a sync or an undo)
  /// reloads the title / notes only into a field that is not being typed in
  /// and only when the store differs from what was loaded
  /// (`reloadTextIfIdle`). A live edit is never overwritten — the old
  /// unconditional reload reverted typing mid-word and then lost the edit,
  /// because `loadedTitle` was reset along with the field.
  func show(_ next: SeptenaTask?, isVisible: Bool = false) {
    guard next?.id != task?.id else {
      task = next
      if let next {
        reloadTextIfIdle(next)
        refreshReadOnlyFields(next)
        refreshConversation(next)
        historyView.configure(taskID: next.id)
      }
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
    // Opening a FADED task in a visible inspector keeps it (`docs/TASK_FADE_SPEC.md` §4).
    if isVisible, next.isFaded {
      keepFaded(next)
    }

    textUndo.removeAllActions()
    loadTitle(next.title)
    loadNotes(next.notes ?? "")
    checklistView.configure(taskID: next.id)
    updateChecklistVisibility()
    refreshReadOnlyFields(next)
    refreshConversation(next)
    historyView.configure(taskID: next.id)
    formScroll?.contentView.scroll(to: .zero)
  }

  /// Called when the inspector opens from collapsed state; keeps the loaded
  /// task if it is faded (`docs/TASK_FADE_SPEC.md` §4).
  func noteBecameVisible() {
    guard let current = task, !current.isHeading, current.isFaded else { return }
    keepFaded(current)
  }

  private func keepFaded(_ fadedTask: SeptenaTask) {
    let snap = TaskUndo.FadedSnapshot(fadedTask)
    mutator.keepFaded(ids: [fadedTask.id])
    TaskUndo.recordKeepFaded(before: [snap], mutator: mutator)
  }

  private func loadTitle(_ title: String) {
    loadedTitle = title
    titleField.stringValue = title
  }

  private func loadNotes(_ notes: String) {
    loadedNotes = Self.savedNotes(notes)
    let fontSize = SeptaskKitTheme.notesFontSize
    notesView.textStorage?.setAttributedString(
      MarkdownNotesStyle.attributed(notes, fontSize: fontSize))
    notesView.typingAttributes = MarkdownNotesStyle.baseAttributes(fontSize: fontSize)
  }

  /// Same task, newer store values (an undo, a sync, an edit from the list's
  /// composer): put them in the fields — but only into a field that is NOT
  /// being typed in, and only when the store actually differs from what the
  /// field was loaded with. Without this the pane kept showing the stale text,
  /// and its next blur wrote that stale text back over the newer value.
  private func reloadTextIfIdle(_ fresh: SeptenaTask) {
    if !isEditingTitle, fresh.title != loadedTitle {
      loadTitle(fresh.title)
    }
    if !isEditingNotes, Self.savedNotes(fresh.notes ?? "") != loadedNotes {
      loadNotes(fresh.notes ?? "")
    }
  }

  /// Notes as they are stored: trailing whitespace and newlines dropped,
  /// leading indentation and every internal line kept (Markdown lists and
  /// code depend on them). Empty clears the stored notes.
  static func savedNotes(_ text: String) -> String {
    var trimmed = Substring(text)
    while let last = trimmed.last, last.isWhitespace || last.isNewline {
      trimmed = trimmed.dropLast()
    }
    return String(trimmed)
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
    if let badge = next.reminder?.badgeText() {
      reminderButton.title = String(localized: "Reminder: \(badge.text)",
                                    comment: "SeptaskKit: inspector reminder field")
    } else {
      reminderButton.title = String(localized: "Add Reminder…",
                                    comment: "SeptaskKit: inspector add reminder")
    }
    listLabel.stringValue = listDescription(for: next)

    let repeatValue = next.recurrence.map { rule in
      let paused = next.recurrencePaused
        ? String(localized: " (Paused)", comment: "Repeat paused suffix")
        : ""
      return "\(rule.shortLabel)\(paused)"
    } ?? String(localized: "None", comment: "No repeat")
    repeatButton.title = String(localized: "Repeat: \(repeatValue)",
                                comment: "SeptaskKit: inspector repeat field")
    starButton.title = next.starred
      ? String(localized: "Starred ★", comment: "SeptaskKit: inspector starred active")
      : String(localized: "Star", comment: "SeptaskKit: inspector star button")
    let resolvedTags = LocalCache.resolvedTags(for: next, tagsByID: LocalCache.tagsByID(in: context))
    tagsButton.title = resolvedTags.isEmpty
      ? String(localized: "Add Tags…", comment: "SeptaskKit: inspector add tags")
      : String(localized: "Tags: \(resolvedTags.map(\.name).joined(separator: ", "))",
               comment: "SeptaskKit: inspector tags field")
  }

  /// Show or hide the conversation section. Hiding the LABEL too is the point:
  /// a task with no agent history should look like a task with no agent
  /// history, not like one whose conversation failed to load.
  ///
  /// Deliberately does NOT `acknowledge` — the plan called for that, but the
  /// inspector's own contract (see `show(_:)`) is that opening to peek must
  /// never ratify: the cue IS Inbox membership for agent rows, so acking here
  /// would yank a proposal out of the Inbox merely because it became the
  /// selected row. Disposition paths ack; looking does not.
  private func refreshConversation(_ next: SeptenaTask) {
    let shown = conversationView.configure(taskID: next.id,
                                           convo: next.conversation,
                                           isTaskOpen: next.status == .open)
    conversationLabel.isHidden = !shown
  }

  /// Re-read the shown task from the store — used when a refresh lands while
  /// the inspector is open. `show(_:)`'s own same-id guard is now the real
  /// protection for in-progress title/notes edits; `isEditing` here just
  /// avoids pointless work while actively typing.
  func refresh() {
    // No blanket "is editing" bail-out any more: each text field guards
    // itself (`reloadTextIfIdle`), the conversation keeps a live reply
    // (`KitConversationView.configure`), and the read-only controls always
    // resync.
    guard let id = task?.id else { return }
    // The inspector needs one row, not a complete live-task snapshot. This is
    // called after every AppKit store refresh, so a point read matters here.
    let fresh = LocalCache.task(id: id, in: context)
    show(fresh)
  }

  private var isEditingTitle: Bool {
    (view.window?.firstResponder as? NSTextView)?.delegate === titleField
  }

  private var isEditingNotes: Bool {
    view.window?.firstResponder === notesView
  }

  /// Any text entry in the pane, the conversation's reply field included.
  private var isEditing: Bool {
    isEditingTitle || isEditingNotes || conversationView.isEditingReply
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
    checklistView.flushPendingEdits()
    guard let current = task else { return }
    let beforeTitle = loadedTitle
    let beforeNotes = loadedNotes
    var titlePatch: String?
    let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if !title.isEmpty, title != loadedTitle {
      titlePatch = title
      loadedTitle = title
    }

    let notes = Self.savedNotes(notesView.string)
    let notesChanged = notes != loadedNotes
    if notesChanged {
      loadedNotes = notes
    }

    guard titlePatch != nil || notesChanged else { return }
    // Keystrokes are now part of a saved value; the task-level undo below
    // is how this edit comes back.
    textUndo.removeAllActions()
    // Blur can commit title and notes together. One backend update means one
    // SwiftData save and one task-change notification instead of up to three
    // refresh cascades. An empty string deliberately clears stored notes.
    mutator.update(id: current.id, title: titlePatch,
                   notes: notesChanged ? notes : nil)
    // On the ONE shared stack, the same entry the list's composer records.
    TaskUndo.recordEdit(id: current.id,
                        beforeTitle: beforeTitle, afterTitle: loadedTitle,
                        beforeNotes: beforeNotes, afterNotes: loadedNotes,
                        mutator: mutator)
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
  /// controller when focus is inside the inspector but NOT in a text field
  /// (those answer Escape themselves — save and back to the list).
  override func cancelOperation(_ sender: Any?) { onRequestClose?() }

  /// The title's keys. Escape and Return both SAVE and hand the keyboard back
  /// to the list — Escape never discards, and never opens NSTextView's
  /// completion list (its default answer to Escape in a field editor).
  func control(_ control: NSControl, textView: NSTextView,
               doCommandBy commandSelector: Selector) -> Bool {
    guard control === titleField else { return false }
    switch commandSelector {
    case #selector(NSResponder.cancelOperation(_:)),
         #selector(NSResponder.insertNewline(_:)),
         #selector(NSResponder.complete(_:)):
      DispatchQueue.main.async { [weak self] in self?.commitAndReturnToList() }
      return true
    default:
      return false
    }
  }

  @objc private func closePane() {
    // Commit first: the pane can be closed mid-edit, and the field's own
    // end-editing notification does not fire when the view goes away.
    flushPendingEdits()
    onRequestClose?()
  }

  /// Notes keys. NSTextView answers Escape with completion, which would
  /// swallow it: here Escape saves and returns to the list, like the title.
  /// Notes is prose, so Return inserts a line; Tab moves on through the
  /// pane's key-view loop (⌥Tab, `insertTabIgnoringFieldEditor`, still types
  /// a tab character).
  func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    guard textView === notesView else { return false }
    switch commandSelector {
    case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
      DispatchQueue.main.async { [weak self] in self?.commitAndReturnToList() }
      return true
    case #selector(NSResponder.insertTab(_:)):
      view.window?.selectNextKeyView(textView)
      return true
    case #selector(NSResponder.insertBacktab(_:)):
      view.window?.selectPreviousKeyView(textView)
      return true
    default:
      return false
    }
  }

  // MARK: - Dates

  @objc private func editTags() {
    guard let current = task else { return }
    SeptaskKitTagPopover.present(
      taskIDs: [current.id],
      relativeTo: tagsButton.bounds,
      of: tagsButton
    ) { [weak self] in
      NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
      self?.refresh()
    }
  }

  @objc private func editRepeat() {
    guard let current = task else { return }
    SeptaskKitRepeatPopover.present(
      selection: SeptaskKitRepeatSelection([current]),
      relativeTo: repeatButton.bounds, of: repeatButton
    ) { [weak self] result in
      guard let self else { return }
      let before = [TaskUndo.ScheduleSnapshot(current)]
      if result.clears {
        self.mutator.setRecurrence(id: current.id, recurrence: nil)
      } else {
        // Same patch overlay as the list's editor — one row is just a
        // selection of one.
        self.mutator.setRecurrence(id: current.id,
                                   recurrence: result.applied(to: current.recurrence))
        if result.paused ?? current.recurrencePaused {
          self.mutator.setRecurrencePaused(id: current.id, paused: true)
        }
      }
      TaskUndo.recordScheduleChange(
        name: String(localized: "Change Repeat", comment: "SeptaskKit: undo action"),
        before: before, context: self.context, mutator: self.mutator)
      NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
      self.refresh()
    }
  }

  @objc private func editWhen() { presentPopover(kind: .when, from: whenButton) }
  @objc private func editDeadline() { presentPopover(kind: .deadline, from: deadlineButton) }

  @objc private func toggleStar() {
    guard let current = task else { return }
    let nextStarred = !current.starred
    let before = [TaskUndo.ScheduleSnapshot(current)]
    mutator.setStarred(id: current.id, starred: nextStarred)
    TaskUndo.recordScheduleChange(
      name: nextStarred
        ? String(localized: "Star", comment: "SeptaskKit: undo action")
        : String(localized: "Remove Star", comment: "SeptaskKit: undo action"),
      before: before, context: context, mutator: mutator)
    NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    refresh()
  }

  @objc private func addChecklistStep() {
    guard task != nil else { return }
    checklistView.appendItemAndFocus()
    updateChecklistVisibility()
  }

  private func updateChecklistVisibility() {
    let hasItems = checklistView.summary.total > 0
    checklistLabel.isHidden = !hasItems
    addChecklistButton.isHidden = hasItems
  }

  @objc private func editReminder() {
    guard let current = task else { return }
    SeptaskKitReminderPopover.present(
      initial: current.reminder,
      relativeTo: reminderButton.bounds,
      of: reminderButton
    ) { [weak self] reminder in
      guard let self else { return }
      let before = [TaskUndo.ScheduleSnapshot(current)]
      self.mutator.setReminder(id: current.id, reminder: reminder)
      TaskUndo.recordScheduleChange(
        name: String(localized: "Change Reminder", comment: "SeptaskKit: undo action"),
        before: before, context: self.context, mutator: self.mutator)
      NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
      self.refresh()
    }
  }

  private func presentPopover(kind: SeptaskKitDatePopover.Kind, from button: NSButton) {
    guard let current = task else { return }
    let initial: Date? = switch kind {
    case .when: KitDayFormat.date(fromWire: current.scheduled)
    case .deadline: KitDayFormat.date(fromWire: current.deadline)
    }

    SeptaskKitDatePopover.present(kind: kind, initial: initial,
                                  relativeTo: button.bounds, of: button) { [weak self] date, today in
      guard let self else { return }
      // Same shared stack as the list's own date popover — an inspector edit
      // has to be as undoable as the ⌘S one, or ⌘Z means different things on
      // two panes of one window.
      let before = [TaskUndo.ScheduleSnapshot(current)]
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
      TaskUndo.recordScheduleChange(
        name: kind == .when
          ? String(localized: "Change When", comment: "SeptaskKit: undo action")
          : String(localized: "Change Deadline", comment: "SeptaskKit: undo action"),
        before: before, context: self.context, mutator: self.mutator)
      NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
      self.refresh()
    }
  }
}

/// Document view for the inspector's scrolling form: flipped, so the form
/// hangs from the top of the pane instead of the bottom.
@MainActor
private final class KitFlippedView: NSView {
  override var isFlipped: Bool { true }
}
#endif
