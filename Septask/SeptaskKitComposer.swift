#if os(macOS)
import AppKit

// The inline composer: a task row that expands in place into an editor —
// title, then a rail of elective pills (Today / When / Deadline / List /
// Repeat / Notes), then an optional notes field. The AppKit counterpart of
// `TaskComposerCard` in `.inline` mode + `TaskAttributeBar`.
//
// The pills don't own any pickers of their own: each opens the SAME popover or
// panel the row commands use (`SeptaskKitDatePopover`, `KitMoveMenu`, and the
// full Repeat editor), so the composer and the ⌘S / ⌘⇧D / ⌘⇧M / Repeat paths
// can't drift into two different pickers.
//
// Edits autosave on collapse, matching the SwiftUI inline host's contract.
@MainActor
final class KitComposerCell: NSTableCellView, NSTextViewDelegate, NSTextFieldDelegate {

  /// Which pill was activated — the controller owns every mutation, this view
  /// only says what was asked for.
  enum Action {
    case toggleToday
    case when(NSView)
    case deadline(NSView)
    case list(NSView)
    case repeatRule(NSView)
    case toggleComplete
    /// AI kickoff — starts a conversation on this task. Shown only when there
    /// is none yet and on-device AI is available, mirroring SwiftUI's
    /// `TaskAttributeBar.showsDiscuss`.
    case discuss
  }

  var onAction: ((Action) -> Void)?
  /// Title + notes as they stand; the controller writes them through the
  /// mutator. Notes is nil when the field was never shown or is empty.
  var onCommit: ((String, String?) -> Void)?
  /// Fold the row shut (Return, or Esc).
  var onCollapse: (() -> Void)?

  private let checkbox = KitCheckboxView()
  private let titleField = NSTextField()
  private let pillRow = NSStackView()
  private let notesView = NSTextView()
  private let notesScroll = NSScrollView()

  private let todayPill = KitPillButton()
  private let whenPill = KitPillButton()
  private let deadlinePill = KitPillButton()
  private let listPill = KitPillButton()
  private let repeatPill = KitPillButton()
  private let discussPill = KitPillButton()
  private let notesPill = KitPillButton()

  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!
  private var notesHeightConstraint: NSLayoutConstraint!
  private var notesShown = false
  /// Last measured notes field height (clamped). Drives both the scroll
  /// view's constraint and `KitComposerCell.height(notesHeight:)`.
  private var measuredNotesHeight: CGFloat = KitComposerCell.notesMinHeight

  // MARK: - Height

  fileprivate static let pillRowHeight: CGFloat = 24
  /// Empty / short notes — room for a couple of lines before the row grows.
  private static let notesMinHeight: CGFloat = 72
  /// Caps growth so a novel-length note scrolls inside the field instead of
  /// eating the whole list. Matches SwiftUI `TaskMarkdownNotesEditor`.
  private static let notesMaxHeight: CGFloat = 360
  /// Breathing room under the pill rail (and notes). The TOP of the composer
  /// is not padded separately — it reuses the closed row's vertical band so
  /// the title doesn't travel when the row expands.
  private static let bottomPadding: CGFloat = 10
  private static let interRowGap: CGFloat = 8

  /// The row height the controller must return for an expanded row. Kept here
  /// so the geometry lives with the layout that produces it.
  ///
  /// Layout: a closed-row-height band at the top (checkbox + title centered
  /// exactly as `SeptaskKitTaskCell`), then pills/notes hanging below. Enter
  /// only grows the row downward — the title's screen position stays put.
  /// Pass the live notes field height when notes are visible; `nil` folds
  /// the notes band away.
  static func height(notesHeight: CGFloat?) -> CGFloat {
    var height = SeptaskKitTheme.rowHeight + interRowGap + pillRowHeight + bottomPadding
    if let notesHeight { height += interRowGap + notesHeight }
    return height
  }

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    checkbox.translatesAutoresizingMaskIntoConstraints = false
    checkbox.onToggle = { [weak self] in self?.onAction?(.toggleComplete) }

    // Chrome-less title — same ink/type as the closed row, no bezel/fill so
    // the field editor doesn't paint a second white "input" surface on the
    // card (Things: caret in the title, not a boxed TextField).
    titleField.font = SeptaskKitTheme.taskTitle
    titleField.textColor = .labelColor
    titleField.isBordered = false
    titleField.isBezeled = false
    titleField.drawsBackground = false
    titleField.backgroundColor = .clear
    titleField.focusRingType = .none
    titleField.lineBreakMode = .byClipping
    titleField.cell?.wraps = false
    titleField.cell?.truncatesLastVisibleLine = false
    titleField.delegate = self
    titleField.translatesAutoresizingMaskIntoConstraints = false

    pillRow.orientation = .horizontal
    pillRow.spacing = 6
    pillRow.alignment = .centerY
    pillRow.translatesAutoresizingMaskIntoConstraints = false

    todayPill.title = String(localized: "Today", comment: "Smart list title")
    todayPill.onPress = { [weak self] _ in self?.onAction?(.toggleToday) }
    whenPill.onPress = { [weak self] view in self?.onAction?(.when(view)) }
    deadlinePill.onPress = { [weak self] view in self?.onAction?(.deadline(view)) }
    listPill.onPress = { [weak self] view in self?.onAction?(.list(view)) }
    repeatPill.onPress = { [weak self] view in self?.onAction?(.repeatRule(view)) }
    notesPill.title = String(localized: "Notes", comment: "SeptaskKit: composer pill")
    notesPill.onPress = { [weak self] _ in self?.toggleNotes() }
    discussPill.title = String(localized: "Discuss", comment: "SeptaskKit: composer pill")
    discussPill.onPress = { [weak self] _ in self?.onAction?(.discuss) }
    for pill in [todayPill, whenPill, deadlinePill, listPill, repeatPill, notesPill,
                 discussPill] {
      pillRow.addArrangedSubview(pill)
    }

    notesView.delegate = self
    notesView.isRichText = true
    notesView.importsGraphics = false
    notesView.allowsUndo = true
    notesView.isAutomaticQuoteSubstitutionEnabled = false
    notesView.drawsBackground = false
    notesView.textContainerInset = NSSize(width: 2, height: 4)
    notesView.isHorizontallyResizable = false
    notesView.isVerticallyResizable = true
    notesView.textContainer?.widthTracksTextView = true
    notesView.textContainer?.lineFragmentPadding = 0
    notesView.typingAttributes = MarkdownNotesStyle.baseAttributes(
      fontSize: SeptaskKitTheme.notesFontSize)
    notesScroll.documentView = notesView
    notesScroll.hasVerticalScroller = false
    notesScroll.autohidesScrollers = true
    notesScroll.drawsBackground = false
    notesScroll.borderType = .noBorder
    notesScroll.translatesAutoresizingMaskIntoConstraints = false
    notesScroll.isHidden = true

    addSubview(checkbox)
    addSubview(titleField)
    addSubview(pillRow)
    addSubview(notesScroll)
    textField = titleField

    leadingConstraint = checkbox.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: KitCardRowView.horizontalInset + 6)
    trailingConstraint = titleField.trailingAnchor.constraint(
      equalTo: trailingAnchor, constant: -(KitCardRowView.horizontalInset + 8))
    notesHeightConstraint = notesScroll.heightAnchor.constraint(
      equalToConstant: Self.notesMinHeight)
    NSLayoutConstraint.activate([
      leadingConstraint,
      // Match `SeptaskKitTaskCell`: checkbox + title sit on the vertical
      // center of a standard-height row. Expansion adds space BELOW this
      // band, so Enter doesn't nudge the glyphs.
      checkbox.centerYAnchor.constraint(equalTo: topAnchor,
                                        constant: SeptaskKitTheme.rowHeight / 2),
      checkbox.widthAnchor.constraint(equalToConstant: KitCheckboxView.tapSize),
      checkbox.heightAnchor.constraint(equalToConstant: KitCheckboxView.tapSize),
      titleField.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 7),
      titleField.centerYAnchor.constraint(equalTo: checkbox.centerYAnchor),
      trailingConstraint,

      pillRow.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
      // Hang off the closed-row band, not the title's intrinsic bottom — keeps
      // the gap stable regardless of field-editor metrics.
      pillRow.topAnchor.constraint(equalTo: topAnchor,
                                   constant: SeptaskKitTheme.rowHeight + Self.interRowGap),
      pillRow.heightAnchor.constraint(equalToConstant: Self.pillRowHeight),
      pillRow.trailingAnchor.constraint(lessThanOrEqualTo: titleField.trailingAnchor),

      notesScroll.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
      notesScroll.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
      notesScroll.topAnchor.constraint(equalTo: pillRow.bottomAnchor,
                                       constant: Self.interRowGap),
      notesHeightConstraint,
    ])

    // Tab walks title → pills → notes, which is the composer's keyboard cursor
    // (the SwiftUI rail's `.pill(attr)` focus chain).
    titleField.nextKeyView = todayPill
    todayPill.nextKeyView = whenPill
    whenPill.nextKeyView = deadlinePill
    deadlinePill.nextKeyView = listPill
    listPill.nextKeyView = repeatPill
    repeatPill.nextKeyView = notesPill
    notesPill.nextKeyView = discussPill
    discussPill.nextKeyView = titleField
  }

  required init?(coder: NSCoder) { fatalError("KitComposerCell is code-only") }

  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + 6
    trailingConstraint.constant = -(inset + 8)
    super.layout()
    // Width can change on window resize — re-wrap and grow/shrink the field.
    // Defer the table notify so we don't re-enter layout via noteHeightOfRows.
    if recomputeNotesHeight(notify: false) {
      DispatchQueue.main.async { [weak self] in
        self?.onNotesHeightChanged?()
      }
    }
  }

  // MARK: - Populate

  /// Full load — title AND notes included. Call ONLY when the composer is
  /// first opened for a task; never on a mid-edit refresh (see `refreshPills`).
  func configure(with task: SeptenaTask, listName: String?) {
    titleField.stringValue = task.title
    let notes = task.notes ?? ""
    let fontSize = SeptaskKitTheme.notesFontSize
    notesView.textStorage?.setAttributedString(
      MarkdownNotesStyle.attributed(notes, fontSize: fontSize))
    notesView.typingAttributes = MarkdownNotesStyle.baseAttributes(fontSize: fontSize)
    notesShown = !notes.isEmpty
    notesScroll.isHidden = !notesShown
    notesPill.isOn = notesShown
    recomputeNotesHeight(notify: false)
    refreshPills(with: task, listName: listName)
  }

  /// Pills + checkbox cues only — deliberately does NOT touch `titleField` or
  /// `notesView`. Called after a pill writes through the mutator (When,
  /// Deadline, List, Repeat, Today all re-read the task afterward to update
  /// their own labels), where the title/notes fields may hold an edit the
  /// user hasn't committed yet — overwriting them here is exactly what used
  /// to silently revert an in-progress title edit the moment any OTHER pill
  /// was touched.
  func refreshPills(with task: SeptenaTask, listName: String?) {
    checkbox.isDone = task.status != .open
    checkbox.isDashed = task.status == .open && task.isInTriageBand
    checkbox.isToday = task.today
    checkbox.tenureFill = TaskRowFlags.agingEnabled ? task.todayTenureFill() : nil
    checkbox.cornerDot = task.conversation.hasStarted && !task.isInTriageBand
    checkbox.agentCue = task.showsAgentCue()

    todayPill.isOn = task.today
    whenPill.title = {
      if let scheduled = task.scheduled {
        let display = KitDayFormat.display(scheduled)
        return String(localized: "When: \(display)",
                      comment: "SeptaskKit: composer pill with date")
      }
      return String(localized: "When", comment: "SeptaskKit: composer pill")
    }()
    whenPill.isOn = task.scheduled != nil
    deadlinePill.title = {
      if let deadline = task.deadline {
        let display = KitDayFormat.display(deadline)
        return String(localized: "Due: \(display)",
                      comment: "SeptaskKit: composer pill with date")
      }
      return String(localized: "Deadline", comment: "SeptaskKit: composer pill")
    }()
    deadlinePill.isOn = task.deadline != nil
    listPill.title = {
      if let listName {
        return String(localized: "List: \(listName)",
                      comment: "SeptaskKit: composer pill with list name")
      }
      return String(localized: "List", comment: "SeptaskKit: composer pill")
    }()
    listPill.isOn = listName != nil
    repeatPill.title = {
      if let recurrence = task.recurrence {
        let label = recurrence.shortLabel
        return String(localized: "Repeat: \(label)",
                      comment: "SeptaskKit: composer pill with cadence")
      }
      return String(localized: "Repeat", comment: "SeptaskKit: composer pill")
    }()
    repeatPill.isOn = task.recurrence != nil

    // Same gate as SwiftUI's `showsDiscuss`: only before a conversation
    // exists, and only when a local model can actually answer. A pill that
    // starts nothing would be worse than no pill.
    discussPill.isHidden = task.conversation.hasStarted || !OnDeviceAI.isAvailable
    discussPill.isEnabled = !discussWorking
    discussPill.title = discussWorking
      ? String(localized: "Thinking…", comment: "SeptaskKit: discuss pill working")
      : String(localized: "Discuss", comment: "SeptaskKit: composer pill")
  }

  /// True while `ConversationEngine.advance` is in flight — the pill says so
  /// rather than looking inert, since the first turn can take a moment.
  private var discussWorking = false

  func setDiscussWorking(_ working: Bool) {
    discussWorking = working
    discussPill.isEnabled = !working
    discussPill.title = working
      ? String(localized: "Thinking…", comment: "SeptaskKit: discuss pill working")
      : String(localized: "Discuss", comment: "SeptaskKit: composer pill")
  }

  /// Whether the notes field is on screen — the controller needs this to size
  /// the row.
  var showsNotes: Bool { notesShown }

  /// Live notes-band height for `heightOfRow`, or `nil` when the field is folded.
  var currentNotesHeight: CGFloat? { notesShown ? measuredNotesHeight : nil }

  func focusTitle() {
    // A freshly-opened composer reaches here before its first layout pass —
    // `beginComposing` swaps the cell in and focuses one runloop turn later,
    // while the row is still animating open, so `titleField`'s trailing pin
    // (set in `layout()`) has not resolved. Without this flush the field
    // editor inherits a near-zero frame and you can only see the glyph you
    // just typed. Same guard, same reason as `SeptaskKitTaskCell.beginEditing`.
    layoutSubtreeIfNeeded()
    window?.makeFirstResponder(titleField)
    polishFieldEditor(selectAll: false)
  }

  /// The window's shared field editor defaults to an opaque white fill — that
  /// is the "separate input box" sitting on the card. Clear it, and prefer a
  /// caret at the end (Things) over a selected-all block that reads as a
  /// second surface. `selectAll` stays available for call sites that want it.
  private func polishFieldEditor(selectAll: Bool) {
    guard let editor = titleField.currentEditor() as? NSTextView else { return }
    editor.drawsBackground = false
    editor.backgroundColor = .clear
    editor.insertionPointColor = .labelColor
    // Match the closed-row / composer title face — the shared field editor
    // otherwise keeps whatever font the last client left on it (often the
    // control default, 1–2pt smaller than taskTitle).
    let font = titleField.font ?? SeptaskKitTheme.taskTitle
    editor.font = font
    editor.typingAttributes = [
      .font: font,
      .foregroundColor: NSColor.labelColor,
    ]
    if selectAll {
      editor.selectAll(nil)
    } else {
      // Collapse AppKit's default select-all; leave a user-placed caret (or
      // a partial selection) alone. Unconditionally jumping to `end` is what
      // yanked the insertion point to the far right after a click-to-edit
      // or a field-editor restart mid-keystroke.
      let selected = editor.selectedRange()
      let end = (editor.string as NSString).length
      if end > 0, selected.location == 0, selected.length == end {
        editor.setSelectedRange(NSRange(location: end, length: 0))
      }
    }
  }

  func controlTextDidBeginEditing(_ obj: Notification) {
    // Field editor is attached by the time this fires; clear it again in case
    // focus arrived without going through `focusTitle()` (e.g. Tab back).
    polishFieldEditor(selectAll: false)
  }

  private func toggleNotes() {
    notesShown.toggle()
    notesScroll.isHidden = !notesShown
    notesPill.isOn = notesShown
    recomputeNotesHeight(notify: false)
    onNotesVisibilityChanged?()
    if notesShown { window?.makeFirstResponder(notesView) }
  }

  /// The row has to change height when notes appear/disappear.
  var onNotesVisibilityChanged: (() -> Void)?
  /// Fired when typed notes grow/shrink the field (no show/hide animation —
  /// the controller should jump the row height).
  var onNotesHeightChanged: (() -> Void)?

  /// Fit the notes scroll view to its text, clamped to min/max. Returns
  /// whether the measured height changed enough to matter for row sizing.
  @discardableResult
  private func recomputeNotesHeight(notify: Bool) -> Bool {
    guard notesShown else {
      let changed = abs(measuredNotesHeight - Self.notesMinHeight) > 0.5
      measuredNotesHeight = Self.notesMinHeight
      notesHeightConstraint.constant = Self.notesMinHeight
      notesScroll.hasVerticalScroller = false
      return changed
    }

    let width = max(notesScroll.bounds.width, 1)
    notesView.textContainer?.containerSize = CGSize(width: width,
                                                    height: .greatestFiniteMagnitude)
    notesView.frame.size.width = width
    guard let manager = notesView.layoutManager,
          let container = notesView.textContainer else { return false }
    manager.ensureLayout(for: container)
    let used = manager.usedRect(for: container)
    let inset = notesView.textContainerInset.height * 2
    let next = min(Self.notesMaxHeight,
                   max(Self.notesMinHeight, ceil(used.height + inset)))
    let changed = abs(next - measuredNotesHeight) > 0.5
    measuredNotesHeight = next
    notesHeightConstraint.constant = next
    notesScroll.hasVerticalScroller = next >= Self.notesMaxHeight - 1
    if changed, notify { onNotesHeightChanged?() }
    return changed
  }

  /// Current field contents, for the controller's autosave.
  var pendingTitle: String { titleField.stringValue }
  var pendingNotes: String? {
    let text = notesView.string.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }

  func commit() {
    onCommit?(pendingTitle, pendingNotes)
  }

  // MARK: - Keyboard

  func control(_ control: NSControl, textView: NSTextView,
               doCommandBy commandSelector: Selector) -> Bool {
    switch commandSelector {
    case #selector(NSResponder.insertNewline(_:)):
      deferCommitAndCollapse()
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      // Autosaves like the SwiftUI inline host — Esc folds the row, it doesn't
      // discard what was typed.
      deferCommitAndCollapse()
      return true
    default:
      return false
    }
  }

  /// `commit()` calls through to `TaskMutator`, which posts its change
  /// notification SYNCHRONOUSLY — and that notification's OWN observers (the
  /// sidebar rebuild in particular) can reselect and call back down into
  /// `focusList()`, i.e. `makeFirstResponder`, on the very row/field editor
  /// whose `doCommandBy:` is still on the call stack asking it to resign.
  /// AppKit's first-responder machinery isn't safely reentrant like that —
  /// this is what "Esc doesn't close the row, and clicking away doesn't
  /// either" traced back to: a first-responder fight left mid-transition with
  /// a defunct field editor still visually attached, no longer wired to
  /// anything real. Deferring one runloop tick — the same trick used
  /// elsewhere in this file for "let the current event finish first" AppKit
  /// hazards — runs the commit AFTER this `doCommandBy:` call has already
  /// returned and the text system has finished its own resign-first-responder
  /// sequence, so the reentrant `makeFirstResponder` lands on a clean stack.
  private func deferCommitAndCollapse() {
    DispatchQueue.main.async { [weak self] in
      self?.commit()
      self?.onCollapse?()
    }
  }

  func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    // Same Esc contract as the title field: one press commits and folds the
    // row, leaving the task selected. (Previously Esc only hopped notes →
    // title, so closing needed two presses.)
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      deferCommitAndCollapse()
      return true
    }
    return false
  }

  /// Esc on a focused pill (or anything else in this cell that doesn't eat
  /// the command) also folds — "anywhere in open-task mode".
  override func cancelOperation(_ sender: Any?) {
    deferCommitAndCollapse()
  }

  /// A title is one line. A pasted multi-line string would otherwise sit in the
  /// field with its breaks intact and clip at the first one. Notes keeps its
  /// breaks — that field is prose (`textDidChange` below).
  func controlTextDidChange(_ obj: Notification) {
    guard let field = obj.object as? NSTextField, field === titleField else { return }
    field.septaskFlattenPastedLineBreaks()
  }

  func textDidChange(_ notification: Notification) {
    guard let textView = notification.object as? NSTextView, textView === notesView else { return }
    MarkdownNotesStyle.restyle(textView, fontSize: SeptaskKitTheme.notesFontSize)
    recomputeNotesHeight(notify: true)
  }
}

// MARK: - Pill

/// One elective pill, drawn as a true stadium (corner radius = half height)
/// matching SwiftUI's `AttributePill`. `NSButton.BezelStyle.recessed` is a
/// rounded rect, not a capsule — that's why the rail read as chips. Filled
/// pills wear a gray wash plus matching ink (never a black slab with white
/// text), same as the SwiftUI inline rail's `neutral` treatment.
@MainActor
final class KitPillButton: NSButton {
  var onPress: ((NSView) -> Void)?

  var isOn: Bool {
    get { state == .on }
    set {
      state = newValue ? .on : .off
      restyle()
    }
  }

  /// `attributedTitle` writes back through `title`; without this the restyle
  /// would recurse. `title` still has to restyle so a label change ("When" →
  /// "When: Friday") keeps the fill/ink pairing.
  private var isRestyling = false

  override var title: String {
    get { super.title }
    set {
      super.title = newValue
      restyle()
      invalidateIntrinsicContentSize()
    }
  }

  init() {
    super.init(frame: .zero)
    isBordered = false
    bezelStyle = .inline
    setButtonType(.momentaryPushIn)
    (cell as? NSButtonCell)?.highlightsBy = []
    (cell as? NSButtonCell)?.showsStateBy = []
    alignment = .center
    lineBreakMode = .byTruncatingTail
    font = SeptaskKitTheme.chip
    focusRingType = .exterior
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.masksToBounds = true
    layer?.cornerCurve = .continuous
    target = self
    action = #selector(pressed)
    heightAnchor.constraint(equalToConstant: KitComposerCell.pillRowHeight).isActive = true
    restyle()
  }

  required init?(coder: NSCoder) { fatalError("KitPillButton is code-only") }

  override var intrinsicContentSize: NSSize {
    let text = attributedTitle.size()
    return NSSize(width: ceil(text.width) + Self.horizontalPadding * 2,
                  height: KitComposerCell.pillRowHeight)
  }

  override func layout() {
    super.layout()
    applyCapsule()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    restyle()
  }

  /// So the system focus ring follows the stadium, not a rounded-rect bezel.
  override func drawFocusRingMask() {
    NSBezierPath(roundedRect: bounds,
                 xRadius: bounds.height / 2,
                 yRadius: bounds.height / 2).fill()
  }

  private func restyle() {
    guard !isRestyling else { return }
    isRestyling = true
    attributedTitle = NSAttributedString(
      string: super.title,
      attributes: [
        .font: SeptaskKitTheme.chip,
        .foregroundColor: isOn ? SeptaskKitTheme.inkPrimary : SeptaskKitTheme.inkSecondary,
      ])
    isRestyling = false
    applyCapsule()
  }

  private func applyCapsule() {
    guard let layer else { return }
    layer.cornerRadius = bounds.height / 2
    layer.cornerCurve = .continuous
    layer.backgroundColor = (isOn ? SeptaskKitTheme.pillOnFill : SeptaskKitTheme.chipFill).cgColor
  }

  @objc private func pressed() { onPress?(self) }

  private static let horizontalPadding: CGFloat = 12
}
#endif
