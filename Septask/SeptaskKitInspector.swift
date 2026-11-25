#if os(macOS)
import AppKit
import SwiftData

// The task inspector: title, notes, and the scheduling attributes for the
// selected row, in a native split-view inspector pane (⌥⌘I). This is where
// notes live in the AppKit shell — the equivalent of the SwiftUI drawer
// inspector, and the reason task detail doesn't need a sheet.
//
// The form is the task page (ADR 0029, docs/TASK_PAGE_SPEC.md): its sections
// follow `RegistrySurfaces.taskPageBlocks(.page, …)`, one builder per block
// kind, and its attribute rows follow `RegistrySurfaces.taskAttributes`. An
// attribute row opens the same picker as the row menu and the composer pill
// (`onOpenPicker` → `SeptaskKitTaskListController.openPicker`). Here the
// picker folds open in the pane, directly under its row, not in a popover:
// the rows are `KitInlineSurfaceAnchor`s and this pane is their
// `KitInlineSurfaceHost` (SeptaskKitSurface.swift). Only the container
// changes; the picker is the same one. A second click on the row folds it
// closed and is Cancel. The conversation sits directly under the attribute
// rows, under the Discuss heading, the way the iOS task page draws it in the
// Discuss card (docs/TASK_PAGE_SPEC.md).
//
// Writes go through TaskMutator like every other surface. Edits commit on
// blur and on selection change (`flushPendingEdits`), never on every
// keystroke — a per-keystroke write would push a CloudKit change per letter.
@MainActor
final class SeptaskKitInspectorController: NSViewController, NSTextViewDelegate, NSTextFieldDelegate,
                                           KitInlineSurfaceHost {

  private let titleField = NSTextField()
  /// The list (area › project), one read-only line under the title. Shown
  /// only at the review depth (docs/AGENT_PROMPT_SPEC.md "Review page"): the
  /// full page has the List row instead.
  private let reviewListLabel = NSTextField(labelWithString: "")
  private let notesView = NSTextView()
  private let whenButton = KitInspectorAttributeButton()
  private let deadlineButton = KitInspectorAttributeButton()
  private let reminderButton = KitInspectorAttributeButton()
  private let repeatButton = KitInspectorAttributeButton()
  private let starButton = KitInspectorAttributeButton()
  private let tagsButton = KitInspectorAttributeButton()
  private let listButton = KitInspectorAttributeButton()
  private let notesLabel = NSTextField(labelWithString: "")
  private let notesScroll = NSScrollView()
  private let addChecklistButton = NSButton()
  private let checklistLabel = NSTextField(labelWithString: "")
  private let checklistView = KitChecklistView()
  private let attachFileButton = NSButton()
  /// Opens the History panel: the registry `history` attribute, the same
  /// one the SwiftUI rail shows as a pill.
  private let historyButton = NSButton()
  private let attachmentsLabel = NSTextField(labelWithString: "")
  private let attachmentsView = KitAttachmentsView()
  private let referencesLabel = NSTextField(labelWithString: "")
  private let referencesView = KitReferencesView()
  private let addReferenceButton = NSButton()
  private let placeholder = NSTextField(labelWithString: String(localized: "No Selection",
                                                                 comment: "SeptaskKit: inspector empty"))
  private let form = NSStackView()
  /// Views of the blocks the review depth leaves out, keyed by block kind.
  /// A task waiting for the user to accept it hides them (ADR 0029 `review`).
  private var pageOnlyViews: [RegistryTaskPageBlockKind: [NSView]] = [:]
  private var showsReviewDepth = false
  /// Task Conversations — the agent's work log for this row. Shown only when
  /// a conversation exists; a task with no agent history gets no header and no
  /// empty box (docs/SEPTASK_CONVERSATIONS_PLAN.md).
  private let conversationLabel = NSTextField(labelWithString: "")
  private let conversationView = KitConversationView()
  /// Who changed the task and what (SeptaskKitHistory.swift). Loads only
  /// while open.
  private let historyView = KitHistoryView()
  /// Who added the task and when (`taskPage.provenance`): permanent,
  /// read-only metadata. The glyph shows only for an agent author.
  private let provenanceLabel = NSTextField(labelWithString: "")
  private let provenanceGlyph = NSImageView()
  private let provenanceValue = NSTextField(labelWithString: "")
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
  /// An attribute row asks for its picker: the attribute id and the row to
  /// anchor to. The shell routes it to the task list, which opens the same
  /// picker the row menu opens for that attribute's action.
  var onOpenPicker: ((RegistryTaskAttributeID, KitSurfaceAnchor) -> Void)?

  /// The attribute rows the inspector shows, by registry attribute id. The
  /// form places them in `RegistrySurfaces.taskAttributes` order.
  private lazy var attributeButtons: [RegistryTaskAttributeID: KitInspectorAttributeButton] = [
    .when: whenButton, .deadline: deadlineButton, .reminder: reminderButton,
    .repeat: repeatButton, .star: starButton, .list: listButton, .tags: tagsButton,
  ]
  /// Attribute rows in registry order, for the form and the key-view loop.
  private var orderedAttributeButtons: [NSButton] = []
  /// Width constraints of the views the blocks placed in the form. A block
  /// the registry leaves out has no view in the form, so it gets none.
  private var blockConstraints: [NSLayoutConstraint] = []

  /// The picker folded open under an attribute row, if any. One at a time.
  private var fold: KitInlineFold?
  /// The row the open fold hangs under — a second click on it is Cancel.
  private weak var foldAnchor: NSView?
  /// Where the keyboard enters the open fold (the picker's focus view).
  private weak var foldKeyView: NSView?
  /// The pane's minimum width before a fold widened it, restored on close.
  private var thicknessBeforeFold: CGFloat?
  /// The conversation sits directly under the attribute rows (`loadView`).
  private var conversationUnderRows = false

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

    for (id, button) in attributeButtons {
      // The row's picker folds open in this pane, under the row.
      button.inlineHost = self
      button.bezelStyle = .rounded
      button.target = self
      button.action = #selector(attributeRowClicked(_:))
      button.alignment = .left
      button.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
    }
    for (button, action) in [(addChecklistButton, #selector(addChecklistStep)),
                             (attachFileButton, #selector(attachFile)),
                             (addReferenceButton, #selector(addReference)),
                             (historyButton, #selector(toggleHistory))] {
      button.bezelStyle = .rounded
      button.target = self
      button.action = action
      button.alignment = .left
    }
    addChecklistButton.title = String(localized: "Add Checklist…", comment: "SeptaskKit: inspector add checklist")
    attachFileButton.title = String(localized: "Attach File…", comment: "SeptaskKit: inspector attach file")
    let historyAttr = RegistrySurfaces.taskAttribute(.history)
    historyButton.title = historyAttr.label
    historyButton.image = NSImage(systemSymbolName: historyAttr.sfSymbol, accessibilityDescription: nil)
    historyButton.imagePosition = .imageLeading
    historyButton.setButtonType(.pushOnPushOff)

    form.orientation = .vertical
    form.alignment = .leading
    form.spacing = 8
    form.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
    form.translatesAutoresizingMaskIntoConstraints = false
    // The registry owns which sections show and their order. No section
    // order is written here.
    let blocks = RegistrySurfaces.taskPageBlocks(.page, on: RegistryPlatform.current)
    // Discuss holds the conversation (docs/TASK_PAGE_SPEC.md): when the
    // registry shows a conversation block, it sits directly under the
    // attribute rows, not as a separate section further down.
    let conversationBlock = blocks.first { $0.kind == .conversation }
    var conversationPlaced = false
    for block in blocks {
      let last: NSView?
      switch block.kind {
      case .header: last = addHeaderBlock()
      case .notes: last = addNotesBlock(block)
      case .attributes:
        let rows = addAttributesBlock()
        if let conversationBlock {
          conversationPlaced = true
          conversationUnderRows = true
          last = addConversationBlock(conversationBlock)
        } else {
          last = rows
        }
      case .checklist: last = addChecklistBlock(block)
      case .attachments: last = addAttachmentsBlock(block)
      case .references: last = addReferencesBlock(block)
      case .conversation:
        if conversationPlaced {
          last = nil
        } else {
          conversationPlaced = true
          last = addConversationBlock(block)
        }
      case .provenance: last = addProvenanceBlock(block)
      case .history: last = addHistoryBlock()
      }
      if let last { form.setCustomSpacing(14, after: last) }
    }
    let reviewKinds = Set(RegistrySurfaces.taskPageBlocks(.review, on: RegistryPlatform.current).map(\.kind))
    for block in blocks where !reviewKinds.contains(block.kind) {
      switch block.kind {
      case .attributes: pageOnlyViews[.attributes] = orderedAttributeButtons
      case .checklist: pageOnlyViews[.checklist] = [checklistLabel, addChecklistButton, checklistView]
      case .attachments: pageOnlyViews[.attachments] = [attachmentsLabel, attachmentsView, attachFileButton]
      case .references: pageOnlyViews[.references] = [referencesLabel, referencesView, addReferenceButton]
      case .history: pageOnlyViews[.history] = [historyButton, historyView]
      case .header, .notes, .conversation, .provenance: break
      }
    }

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
      closeButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
      closeButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
      closeButton.widthAnchor.constraint(equalToConstant: 20),
      closeButton.heightAnchor.constraint(equalToConstant: 20),
      placeholder.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      placeholder.centerYAnchor.constraint(equalTo: root.centerYAnchor),
    ] + blockConstraints)
    view = root

    rebuildKeyLoop()
    // A task selected before the pane was first opened is already held in
    // `task` (see `show`). Load it now that the form exists.
    let held = task
    task = nil
    form.isHidden = true
    show(held)
  }

  /// Explicit keyboard order through the pane: title → notes → the
  /// attribute rows in registry order → back to the title. An open fold
  /// joins the loop right after its row. (The buttons join the loop only
  /// with Full Keyboard Access on — AppKit skips them otherwise.)
  private func rebuildKeyLoop() {
    var loop: [NSView] = [titleField, notesView]
    for button in orderedAttributeButtons {
      loop.append(button)
      if button === foldAnchor, let entry = foldKeyView { loop.append(entry) }
    }
    for (index, view) in loop.enumerated() {
      view.nextKeyView = loop[(index + 1) % loop.count]
    }
  }

  // MARK: - Blocks (one builder per `RegistryTaskPageBlockKind`)

  /// Each builder adds its block's views to the form and returns the last
  /// one, which gets the space between sections.

  /// A section heading in the pane's chip style. The text is the block's
  /// registry `label`.
  private func styleHeading(_ label: NSTextField, _ block: RegistryTaskPageBlock) {
    label.stringValue = block.label ?? ""
    label.font = SeptaskKitTheme.chip
    label.textColor = SeptaskKitTheme.iconMuted
  }

  /// Full pane width less the form's insets.
  private func fillWidth(_ view: NSView, inset: CGFloat = -28) {
    blockConstraints.append(view.widthAnchor.constraint(equalTo: form.widthAnchor, constant: inset))
  }

  private func addHeaderBlock() -> NSView {
    form.addArrangedSubview(titleField)
    // -52, not the -28 the notes field uses: the title shares its band with
    // the close button and must not run under it.
    fillWidth(titleField, inset: -52)
    reviewListLabel.font = SeptaskKitTheme.meta
    reviewListLabel.textColor = SeptaskKitTheme.inkSecondary
    reviewListLabel.lineBreakMode = .byTruncatingTail
    reviewListLabel.isSelectable = true
    reviewListLabel.isHidden = true
    form.addArrangedSubview(reviewListLabel)
    fillWidth(reviewListLabel)
    // The title's own gap follows the line (`applyDepth`): tight above it
    // when shown, the section gap when it is hidden and detached.
    form.setCustomSpacing(14, after: titleField)
    return reviewListLabel
  }

  private func addNotesBlock(_ block: RegistryTaskPageBlock) -> NSView {
    styleHeading(notesLabel, block)
    form.addArrangedSubview(notesLabel)
    form.addArrangedSubview(notesScroll)
    fillWidth(notesScroll)
    blockConstraints.append(notesScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120))
    return notesScroll
  }

  /// The attribute rows in `RegistrySurfaces.taskAttributes` order, limited
  /// to the attributes this pane has a row for and that ship on this
  /// platform.
  private func addAttributesBlock() -> NSView? {
    orderedAttributeButtons = RegistrySurfaces.taskAttributes
      .filter { $0.applies(to: RegistryPlatform.current) }
      .compactMap { attributeButtons[$0.id] }
    for button in orderedAttributeButtons { form.addArrangedSubview(button) }
    return orderedAttributeButtons.last
  }

  private func addChecklistBlock(_ block: RegistryTaskPageBlock) -> NSView {
    styleHeading(checklistLabel, block)
    checklistView.translatesAutoresizingMaskIntoConstraints = false
    checklistView.onLeave = { [weak self] delta in
      guard let self, delta < 0 else { return }
      self.view.window?.makeFirstResponder(self.notesView)
      self.notesView.setSelectedRange(NSRange(location: (self.notesView.string as NSString).length, length: 0))
    }
    checklistView.onChanged = { [weak self] in
      guard let self else { return }
      self.updateChecklistVisibility()
      NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    }
    // The heading shows when steps exist, the add button when none do.
    form.addArrangedSubview(checklistLabel)
    form.addArrangedSubview(addChecklistButton)
    form.addArrangedSubview(checklistView)
    fillWidth(checklistView)
    return checklistView
  }

  private func addAttachmentsBlock(_ block: RegistryTaskPageBlock) -> NSView {
    styleHeading(attachmentsLabel, block)
    attachmentsView.translatesAutoresizingMaskIntoConstraints = false
    attachmentsView.onChanged = { [weak self] in
      guard let self else { return }
      self.updateAttachmentsVisibility()
      NotificationCenter.default.post(name: .septenaTasksChanged, object: nil)
    }
    form.addArrangedSubview(attachmentsLabel)
    form.addArrangedSubview(attachmentsView)
    form.addArrangedSubview(attachFileButton)
    fillWidth(attachmentsView)
    return attachFileButton
  }

  /// References (docs/TASK_REFERENCES_SPEC.md §8). The page always offers Add
  /// Reference, also on a task that has none.
  private func addReferencesBlock(_ block: RegistryTaskPageBlock) -> NSView {
    styleHeading(referencesLabel, block)
    referencesView.translatesAutoresizingMaskIntoConstraints = false
    referencesView.onTakeSuggestion = { [weak self] offer in
      guard let self, let task = self.task else { return }
      _ = TaskRefActions.add(offer.input, to: task.id)
      self.refreshReferences(task)
    }
    addReferenceButton.title = RegistryActions.title(.taskAddReference)
    form.addArrangedSubview(referencesLabel)
    form.addArrangedSubview(referencesView)
    form.addArrangedSubview(addReferenceButton)
    fillWidth(referencesView)
    return addReferenceButton
  }

  private func refreshReferences(_ next: SeptenaTask) {
    referencesView.reload(taskID: next.id, title: titleField.stringValue, notes: notesView.string)
    let canAdd = TaskRefActions.canAdd && next.deletedAt == nil
    referencesLabel.isHidden = referencesView.isEmpty && !canAdd
    referencesView.isHidden = referencesView.isEmpty
    addReferenceButton.isHidden = !canAdd
    // The section gap follows the last view that shows.
    form.setCustomSpacing(addReferenceButton.isHidden ? 14 : form.spacing, after: referencesView)
  }

  @objc private func addReference() {
    guard let task else { return }
    SeptaskKitAddReferencePopover.present(taskID: task.id, relativeTo: addReferenceButton.bounds,
                                          of: addReferenceButton)
  }

  /// The conversation, under the Discuss heading: the pane has no Discuss
  /// row, so the heading carries the Discuss attribute's registry label and
  /// the block sits directly under the attribute rows (see `loadView`), the
  /// way the iOS task page draws it inside the Discuss card.
  private func addConversationBlock(_ block: RegistryTaskPageBlock) -> NSView {
    styleHeading(conversationLabel, block)
    conversationLabel.stringValue = RegistrySurfaces.taskAttribute(.discuss).label
    conversationView.translatesAutoresizingMaskIntoConstraints = false
    // A reply appends a turn, which posts a task change; re-read so the new
    // turn lands in the transcript the same way an agent turn would.
    conversationView.onAppend = { [weak self] in self?.refresh() }
    // A sent or cancelled reply hands the keyboard back to the list, the
    // same exit the title and notes use.
    conversationView.onEndReply = { [weak self] in self?.onRequestFocusList?() }
    form.addArrangedSubview(conversationLabel)
    form.addArrangedSubview(conversationView)
    fillWidth(conversationView)
    return conversationView
  }

  /// Provenance: the "Added by" heading and one line under it — the agent
  /// glyph (agent rows only) and "Claude · 24 Nov 2026 at 09:03" or "You · …".
  private func addProvenanceBlock(_ block: RegistryTaskPageBlock) -> NSView {
    styleHeading(provenanceLabel, block)
    provenanceGlyph.image = NSImage(systemSymbolName: RegistrySurfaces.provenanceAgentSymbol,
                                    accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
    provenanceGlyph.contentTintColor = SeptaskKitTheme.inkSecondary
    provenanceGlyph.kitA11yIgnore()
    provenanceValue.font = SeptaskKitTheme.meta
    provenanceValue.textColor = .labelColor
    provenanceValue.isSelectable = true
    let line = NSStackView(views: [provenanceGlyph, provenanceValue])
    line.orientation = .horizontal
    line.alignment = .centerY
    line.spacing = 5
    form.addArrangedSubview(provenanceLabel)
    form.addArrangedSubview(line)
    return line
  }

  /// History: the registry `history` attribute as a button (the SwiftUI rail
  /// shows it as a pill), and the panel it opens. The log loads only while
  /// the panel is open (`KitHistoryView`).
  private func addHistoryBlock() -> NSView {
    historyView.translatesAutoresizingMaskIntoConstraints = false
    historyView.listTitle = { [weak self] id in
      guard let self else { return nil }
      let snapshot = StructureCache.snapshot(in: self.context)
      return snapshot.projects.first { $0.id == id }?.title ?? snapshot.areas.first { $0.id == id }?.title
    }
    form.addArrangedSubview(historyButton)
    form.addArrangedSubview(historyView)
    fillWidth(historyView)
    return historyView
  }

  @objc private func toggleHistory() {
    historyView.setExpanded(historyButton.state == .on)
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
    guard isViewLoaded else { return false }
    // ⌘↩ in the conversation's reply field sends the reply.
    if conversationView.handleCommandReturn() { return true }
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
  ///
  /// AppKit loads a collapsed split-view pane only when it first opens, and
  /// the form is empty until then. Until the view is loaded this only holds
  /// the task; `loadView` shows it. Configuring the empty form raised in
  /// `NSStackView.setCustomSpacing`, inside the shell window's `init`, so the
  /// app ran with no window.
  func show(_ next: SeptenaTask?, isVisible: Bool = false) {
    guard isViewLoaded else {
      task = next
      return
    }
    guard next?.id != task?.id else {
      task = next
      if let next {
        reloadTextIfIdle(next)
        refreshReadOnlyFields(next)
        refreshReferences(next)
        refreshConversation(next)
        historyButton.isHidden = !historyView.configure(taskID: next.id)
        applyDepth(for: next)
      }
      return
    }
    flushPendingEdits()
    // A fold belongs to the task it opened on. Switching rows cancels it
    // (no draft is written to the row being left).
    fold?.cancel()
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
    attachmentsView.configure(taskID: next.id)
    updateAttachmentsVisibility()
    refreshReadOnlyFields(next)
    refreshReferences(next)
    refreshConversation(next)
    historyButton.isHidden = !historyView.configure(taskID: next.id)
    applyDepth(for: next)
    formScroll?.contentView.scroll(to: .zero)
  }

  /// A task waiting for the user to accept it shows the review depth: title,
  /// notes, the conversation (with Accept and Send back) and who added it.
  /// Same rule as the SwiftUI task page.
  private func applyDepth(for task: SeptenaTask) {
    let review = task.conversation.needsHumanReview
    let listPath = review ? KitListPath.text(for: task, in: context) : nil
    reviewListLabel.stringValue = listPath ?? ""
    reviewListLabel.isHidden = listPath == nil
    form.setCustomSpacing(listPath == nil ? 14 : 2, after: titleField)
    if review {
      for views in pageOnlyViews.values { views.forEach { $0.isHidden = true } }
    } else if showsReviewDepth {
      for views in pageOnlyViews.values { views.forEach { $0.isHidden = false } }
      updateChecklistVisibility()
      updateAttachmentsVisibility()
      refreshReferences(task)
      historyButton.isHidden = !historyView.configure(taskID: task.id)
    }
    showsReviewDepth = review
  }

  /// Send back on a Review row: open the conversation's Send back field for
  /// the shown task and give it the keyboard. No-op when the shown task is
  /// not waiting for review.
  func openSendBack() {
    loadViewIfNeeded()
    guard let task, !form.isHidden else { return }
    applyDepth(for: task)
    conversationView.openSendBack()
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
    provenanceGlyph.isHidden = !next.isAgentAuthored
    provenanceValue.stringValue = next.addedByDetail
    let whenBase: String = if next.today {
      TaskFilter.today.title
    } else if let scheduled = next.scheduled {
      KitDayFormat.display(scheduled)
    } else {
      TaskFilter.unscheduled.title
    }
    let when = next.timeSlotLabel.map { "\(whenBase) · \($0)" } ?? whenBase
    whenButton.title = Self.field(.when, when)
    let deadlineValue = next.deadline.map(KitDayFormat.display)
      ?? String(localized: "None", comment: "No deadline")
    deadlineButton.title = Self.field(.deadline, deadlineValue)
    if let badge = next.reminder?.badgeText() {
      reminderButton.title = Self.field(.reminder, badge.text)
    } else {
      reminderButton.title = RegistryActions.alternateTitles[.taskReminder]?["addTitle"]
        ?? RegistrySurfaces.taskAttribute(.reminder).label
    }
    updateListButton(for: next)

    let repeatValue = next.recurrence.map { rule in
      let paused = next.recurrencePaused
        ? String(localized: " (Paused)", comment: "Repeat paused suffix")
        : ""
      return "\(rule.shortLabel)\(paused)"
    } ?? String(localized: "None", comment: "No repeat")
    repeatButton.title = Self.field(.repeat, repeatValue)
    let starTitles = RegistryActions.alternateTitles[.taskToggleStar] ?? [:]
    let starLabel = RegistrySurfaces.taskAttribute(.star).label
    starButton.title = next.starred
      ? starTitles["removeTitle"] ?? starLabel
      : starTitles["addTitle"] ?? starLabel
    let resolvedTags = LocalCache.resolvedTags(for: next, tagsByID: LocalCache.tagsByID(in: context))
    tagsButton.title = resolvedTags.isEmpty
      ? String(localized: "Add Tags…", comment: "SeptaskKit: inspector add tags")
      : Self.field(.tags, resolvedTags.map(\.name).joined(separator: ", "))
  }

  /// "Label: value" for an inspector row, the label from the registry's
  /// `taskAttributes` (ADR 0020) so it matches the composer pill.
  private static func field(_ id: RegistryTaskAttributeID, _ value: String) -> String {
    "\(RegistrySurfaces.taskAttribute(id).label): \(value)"
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
    // Rows and conversation read as one unit: the normal gap between them,
    // the section gap after the rows when there is no conversation.
    if conversationUnderRows, let lastRow = orderedAttributeButtons.last {
      form.setCustomSpacing(shown ? form.spacing : 14, after: lastRow)
    }
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

  private func updateListButton(for task: SeptenaTask) {
    let snapshot = StructureCache.snapshot(in: context)
    listButton.imagePosition = .imageLeading
    if let id = task.project,
       let project = snapshot.projects.first(where: { $0.id == id }) {
      let progress = LocalCache.projectCompletionRatios(in: context)[project.id] ?? 0
      listButton.image = KitGlyph.progress(progress, tint: SeptaskKitTheme.inkSecondary, diameter: 12)
      listButton.title = String(localized: "In \(project.title)",
                                comment: "SeptaskKit: inspector list affiliation")
      return
    }
    if let id = task.area,
       let area = snapshot.areas.first(where: { $0.id == id }) {
      listButton.image = KitGlyph.area(emoji: area.emoji, diameter: 14)
      listButton.title = String(localized: "In \(area.title)",
                                comment: "SeptaskKit: inspector list affiliation")
      return
    }
    listButton.image = KitGlyph.symbol(RegistrySurfaces.taskAttribute(.list).sfSymbol,
                                       color: SeptaskKitTheme.iconMuted,
                                       cacheTag: "iconMuted",
                                       size: 14)
    listButton.title = String(localized: "No list", comment: "SeptaskKit: inspector list affiliation")
  }

  // MARK: - Commits

  /// Commit whatever is in the fields. Safe to call repeatedly — it only
  /// writes when a value actually differs from what was loaded.
  func flushPendingEdits() {
    // No view yet means no fields, so nothing was typed.
    guard isViewLoaded else { return }
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
                   notes: notesChanged ? notes : nil, notesFrom: beforeNotes)
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
    // ↓ on the last line of notes walks into the checklist steps, like the
    // open row's composer; ↑ off the first step comes back (`onLeave`).
    case #selector(NSResponder.moveDown(_:))
      where checklistView.hasItems && textView.caretOnLastLine:
      checklistView.focusFirstItem()
      return true
    default:
      return false
    }
  }

  // MARK: - Attribute rows

  /// An attribute row: Star toggles in place; every other row opens its
  /// picker through the task list, the same path as the row menu and the
  /// composer pill (ADR 0029). The picker folds open under the row
  /// (`foldOpen`). A second click on the row folds it closed: Cancel.
  @objc private func attributeRowClicked(_ sender: NSButton) {
    guard task != nil,
          let raw = sender.identifier?.rawValue,
          let id = RegistryTaskAttributeID(rawValue: raw) else { return }
    if let fold, foldAnchor === sender {
      fold.cancel()
      return
    }
    // One fold at a time.
    fold?.cancel()
    if id == .star {
      toggleStar()
      return
    }
    onOpenPicker?(id, .rect(sender.bounds, sender))
  }

  // MARK: - Folds (KitInlineSurfaceHost)

  /// Put a picker in the pane directly under `anchor`, in place of the
  /// popover the same picker opens from the row menu. The picker keeps its
  /// own keys and commit contract; this owns only the place it sits.
  func foldOpen(_ content: NSView, size: NSSize?, under anchor: NSView,
                focus: NSView?, onClose: (() -> Void)?) -> KitInlineFold {
    fold?.cancel()

    let container = NSView()
    container.translatesAutoresizingMaskIntoConstraints = false
    content.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(content)
    var constraints = [
      content.topAnchor.constraint(equalTo: container.topAnchor),
      content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      container.widthAnchor.constraint(equalTo: form.widthAnchor, constant: -28),
    ]
    // A picker with no width of its own (Move) fills the row's width. A
    // picker with a fixed width (the date board) keeps it.
    let fill = content.trailingAnchor.constraint(equalTo: container.trailingAnchor)
    fill.priority = .defaultHigh
    constraints.append(fill)
    // A popover gave this content its height (Move): keep that height here.
    if let size {
      constraints.append(content.heightAnchor.constraint(equalToConstant: size.height))
    }
    let index = form.arrangedSubviews.firstIndex(of: anchor).map { $0 + 1 }
      ?? form.arrangedSubviews.count
    form.insertArrangedSubview(container, at: index)
    NSLayoutConstraint.activate(constraints)
    widenPaneToFit(content)

    let made = KitInlineFold(container: container, onClose: onClose) { [weak self] ended in
      self?.removeFold(ended, content: content)
    }
    fold = made
    foldAnchor = anchor
    foldKeyView = focus ?? content
    rebuildKeyLoop()

    view.layoutSubtreeIfNeeded()
    container.scrollToVisible(container.bounds)
    view.window?.makeFirstResponder(focus ?? content)
    return made
  }

  func inlineAnchor(forAttribute attributeId: RegistryTaskAttributeID) -> KitSurfaceAnchor? {
    guard let button = attributeButtons[attributeId],
          orderedAttributeButtons.contains(where: { $0 === button }) else { return nil }
    return .rect(button.bounds, button)
  }

  private func removeFold(_ ended: KitInlineFold, content: NSView) {
    let container = ended.container
    let hadKeyboard = (view.window?.firstResponder as? NSView)?.isDescendant(of: container) ?? false
    let anchor = foldAnchor
    container.removeFromSuperview()
    content.removeFromSuperview()
    // A later fold may already be open (When's Repeat row hands off to the
    // Repeat row): only the current one clears the state.
    guard fold === ended else { return }
    fold = nil
    foldAnchor = nil
    foldKeyView = nil
    restorePaneWidth()
    rebuildKeyLoop()
    // Keyboard back to the row that opened the picker, when the row can take
    // it (Full Keyboard Access).
    if hadKeyboard, let anchor { view.window?.makeFirstResponder(anchor) }
  }

  /// A picker has a fixed width (the date board's week strip). While it is
  /// open, the pane is at least that wide, up to the pane's maximum, so the
  /// strip is not cut off. Restored when the fold closes.
  private func widenPaneToFit(_ content: NSView) {
    guard let item = (parent as? NSSplitViewController)?.splitViewItem(for: self) else { return }
    let needed = min(content.fittingSize.width + 28, item.maximumThickness)
    guard needed > item.minimumThickness else { return }
    if thicknessBeforeFold == nil { thicknessBeforeFold = item.minimumThickness }
    item.minimumThickness = needed
  }

  private func restorePaneWidth() {
    guard let before = thicknessBeforeFold,
          let item = (parent as? NSSplitViewController)?.splitViewItem(for: self) else { return }
    item.minimumThickness = before
    thicknessBeforeFold = nil
  }

  private func toggleStar() {
    guard let current = task else { return }
    let nextStarred = !current.starred
    let before = [TaskUndo.ScheduleSnapshot(current)]
    mutator.setStarred(id: current.id, starred: nextStarred)
    TaskUndo.recordScheduleChange(
      name: nextStarred
        ? RegistryActions.title(.taskToggleStar, .add)
        : RegistryActions.title(.taskToggleStar, .remove),
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

  @objc private func attachFile() {
    attachmentsView.pickFilesToAttach()
  }

  private func updateAttachmentsVisibility() {
    let count = attachmentsView.attachmentCount
    attachmentsLabel.isHidden = count == 0
    attachFileButton.title = count == 0
      ? String(localized: "Attach File…", comment: "SeptaskKit: inspector attach file")
      : String(localized: "Attach Another File…", comment: "SeptaskKit: inspector attach another file")
  }
}

/// An inspector attribute row. Its picker folds open in the pane under it
/// (`KitInlineSurfaceAnchor`) instead of in a popover.
@MainActor
private final class KitInspectorAttributeButton: NSButton, KitInlineSurfaceAnchor {
  weak var inlineHost: KitInlineSurfaceHost?
}

/// Document view for the inspector's scrolling form: flipped, so the form
/// hangs from the top of the pane instead of the bottom.
@MainActor
private final class KitFlippedView: NSView {
  override var isFlipped: Bool { true }
}
#endif
