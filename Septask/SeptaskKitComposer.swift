#if os(macOS)
import AppKit

// The inline composer: a task row that expands in place into an editor —
// title, then notes (when the task has any, or the Notes pill reveals them),
// then a rail of elective pills (Today / When / Deadline / List / Repeat /
// Notes). The AppKit counterpart of `TaskComposerCard` in `.inline` mode +
// `TaskAttributeBar`, in the SAME top-to-bottom order — title, notes, rail —
// which is also the open-task anatomy Things and Reminders share: prose hangs
// off the title, the controls sit under the prose.
//
// Title and notes are both `NSTextView`s rather than a field-editor-backed
// `NSTextField`. A long title has to WRAP and grow the row as you type — the
// single-line field editor clipped it at the row's width, so the overflow was
// simply invisible while editing — and one layout manager gives both fields
// the same measurement path. The title still behaves as one line
// semantically (Return commits, pasted breaks flatten); it only wraps
// visually. The closed row keeps truncating to one line for list rhythm.
//
// The pills don't own any pickers of their own: each opens the SAME popover or
// panel the row commands use (`SeptaskKitDatePopover`, `KitMoveMenu`, and the
// full Repeat editor), so the composer and the ⌘S / ⌘⇧D / ⌘⇧M / Repeat paths
// can't drift into two different pickers.
//
// Edits autosave on collapse, matching the SwiftUI inline host's contract.
// Keyboard: Return in the title (or Esc anywhere) commits and folds. ⌘↩ is
// the NOTES toggle — it reveals and focuses notes, and from inside notes it
// commits and folds; the table catches it (`SeptaskKitTableView.onEditNotes`)
// so the same key also opens a closed selected row straight into notes. ↓ on
// the title's last line drops the caret into notes (↑/↓ then stay inside
// notes); Tab walks title → notes → pills (Shift-Tab back).
@MainActor
final class KitComposerCell: NSTableCellView, NSTextViewDelegate {

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
  /// Fold the row shut (Return, ⌘↩, or Esc).
  var onCollapse: (() -> Void)?
  /// The notes band appeared or disappeared — the controller animates the
  /// row to `expandedHeight`.
  var onNotesVisibilityChanged: (() -> Void)?
  /// Typing (or a resize re-wrap) grew or shrank the title or notes — the
  /// controller should JUMP the row to `expandedHeight`, no easing, so the
  /// caret line is never briefly clipped.
  var onContentHeightChanged: (() -> Void)?

  private let checkbox = KitCheckboxView()
  private let titleView = KitComposerTextView()
  private let titleScroll = NSScrollView()
  private let notesView = KitComposerTextView()
  private let notesScroll = NSScrollView()
  /// Title, notes, pills — stacked. A hidden notes scroll view detaches from
  /// the stack, so the rail closes up under the title on its own.
  private let column = NSStackView()
  private let pillRow = NSStackView()

  private let todayPill = KitPillButton()
  private let whenPill = KitPillButton()
  private let deadlinePill = KitPillButton()
  private let listPill = KitPillButton()
  private let repeatPill = KitPillButton()
  private let discussPill = KitPillButton()
  private let notesPill = KitPillButton()

  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!
  private var titleHeightConstraint: NSLayoutConstraint!
  private var notesHeightConstraint: NSLayoutConstraint!
  private var notesShown = false
  /// Last measured heights. Both drive their scroll view's constraint and
  /// `expandedHeight`; the title is never shorter than one line.
  private var measuredTitleHeight: CGFloat = KitComposerCell.titleLineHeight
  private var measuredNotesHeight: CGFloat = KitComposerCell.notesMinHeight
  /// Text-edit undo stays LOCAL to the open row. Both text views would
  /// otherwise fall through to the window's undo manager — the shared task
  /// stack (`TaskUndo`) — and a ⌘Z after the row folded would "undo" keystrokes
  /// into a field that is no longer on screen. Reset on every `configure`.
  private let textUndo = UndoManager()

  // MARK: - Height

  fileprivate static let pillRowHeight: CGFloat = 24
  /// Empty / short notes — two lines of room before the field grows. Things'
  /// open to-do shows about this much under the title.
  private static var notesMinHeight: CGFloat {
    ceil(NSLayoutManager().defaultLineHeight(
      for: .systemFont(ofSize: SeptaskKitTheme.notesFontSize)) * 2 + notesInset.height * 2)
  }
  /// Caps growth so a novel-length note scrolls inside the field instead of
  /// eating the whole list. Matches SwiftUI `TaskMarkdownNotesEditor`.
  private static let notesMaxHeight: CGFloat = 360
  private static let notesInset = NSSize(width: 2, height: 4)
  /// Breathing room under the pill rail. The TOP of the composer is not
  /// padded separately — it reuses the closed row's vertical band so the
  /// title doesn't travel when the row expands.
  private static let bottomPadding: CGFloat = 10
  private static let interRowGap: CGFloat = 8

  /// One line of title. The first line sits centered in the closed-row band
  /// exactly where `SeptaskKitTaskCell`'s label draws, so opening the row
  /// doesn't nudge the glyphs; every further wrapped line adds to the row
  /// below it. This is the one knob if the open/closed title ever drifts.
  static var titleLineHeight: CGFloat {
    ceil(NSLayoutManager().defaultLineHeight(for: SeptaskKitTheme.taskTitle))
  }
  private static var titleTop: CGFloat { (SeptaskKitTheme.rowHeight - titleLineHeight) / 2 }

  /// Row height for a one-line title with no notes — the controller's answer
  /// until the live cell has measured itself (`expandedHeight`).
  static var baseHeight: CGFloat { height(titleHeight: titleLineHeight, notesHeight: nil) }

  /// Layout: a closed-row-height band at the top (checkbox + first title line
  /// centered exactly as `SeptaskKitTaskCell`), any extra title lines, then
  /// notes and pills hanging below. Enter only grows the row downward.
  private static func height(titleHeight: CGFloat, notesHeight: CGFloat?) -> CGFloat {
    var height = SeptaskKitTheme.rowHeight + max(0, titleHeight - titleLineHeight) + interRowGap
    if let notesHeight { height += notesHeight + interRowGap }
    return height + pillRowHeight + bottomPadding
  }

  /// The row height the controller must return for this expanded row, from
  /// the live title/notes measurements. Re-measures first when the cell has
  /// a real width, so a caller that reads it right after the table sized the
  /// cell gets the wrapped-title answer without waiting for a layout pass.
  var expandedHeight: CGFloat {
    recomputeContentHeights(notify: false)
    return Self.height(titleHeight: measuredTitleHeight,
                       notesHeight: notesShown ? measuredNotesHeight : nil)
  }

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    checkbox.translatesAutoresizingMaskIntoConstraints = false
    checkbox.onToggle = { [weak self] in self?.onAction?(.toggleComplete) }

    // Chrome-less title — same ink/type as the closed row, no bezel/fill, so
    // it reads as the row's own text with a caret in it (Things), not a boxed
    // input sitting on the card.
    titleView.isRichText = false
    titleView.usesFontPanel = false
    titleView.isAutomaticLinkDetectionEnabled = false
    titleView.isAutomaticDataDetectionEnabled = false
    titleView.font = SeptaskKitTheme.taskTitle
    titleView.textColor = .labelColor
    titleView.typingAttributes = Self.titleAttributes
    titleView.textContainerInset = .zero
    titleView.placeholder = String(localized: "New Task",
                                   comment: "SeptaskKit: composer title placeholder")
    Self.styleTextView(titleView, in: titleScroll)

    notesView.isRichText = true
    notesView.textContainerInset = Self.notesInset
    notesView.typingAttributes = MarkdownNotesStyle.baseAttributes(
      fontSize: SeptaskKitTheme.notesFontSize)
    notesView.font = .systemFont(ofSize: SeptaskKitTheme.notesFontSize)
    notesView.placeholder = String(localized: "Notes",
                                   comment: "SeptaskKit: composer notes placeholder")
    Self.styleTextView(notesView, in: notesScroll)
    notesScroll.isHidden = true

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

    column.orientation = .vertical
    column.alignment = .leading
    column.spacing = Self.interRowGap
    column.translatesAutoresizingMaskIntoConstraints = false
    column.addArrangedSubview(titleScroll)
    column.addArrangedSubview(notesScroll)
    column.addArrangedSubview(pillRow)
    // The one-line title ends `titleTop` short of the closed-row band's
    // bottom; add that back so the rail hangs `interRowGap` under the BAND
    // (where it always sat), not under the glyphs.
    column.setCustomSpacing(Self.titleTop + Self.interRowGap, after: titleScroll)

    addSubview(checkbox)
    addSubview(column)

    leadingConstraint = checkbox.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: KitCardRowView.horizontalInset + 6)
    trailingConstraint = column.trailingAnchor.constraint(
      equalTo: trailingAnchor, constant: -(KitCardRowView.horizontalInset + 8))
    titleHeightConstraint = titleScroll.heightAnchor.constraint(
      equalToConstant: Self.titleLineHeight)
    notesHeightConstraint = notesScroll.heightAnchor.constraint(
      equalToConstant: Self.notesMinHeight)
    NSLayoutConstraint.activate([
      leadingConstraint,
      // Match `SeptaskKitTaskCell`: checkbox on the vertical center of a
      // standard-height row, the title's FIRST line centered on it. Extra
      // lines and the rest of the column add space BELOW this band.
      checkbox.centerYAnchor.constraint(equalTo: topAnchor,
                                        constant: SeptaskKitTheme.rowHeight / 2),
      checkbox.widthAnchor.constraint(equalToConstant: KitCheckboxView.tapSize),
      checkbox.heightAnchor.constraint(equalToConstant: KitCheckboxView.tapSize),
      column.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 7),
      column.topAnchor.constraint(equalTo: topAnchor, constant: Self.titleTop),
      trailingConstraint,

      titleScroll.widthAnchor.constraint(equalTo: column.widthAnchor),
      titleHeightConstraint,
      notesScroll.widthAnchor.constraint(equalTo: column.widthAnchor),
      notesHeightConstraint,
      pillRow.heightAnchor.constraint(equalToConstant: Self.pillRowHeight),
      pillRow.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor),
    ])

    // Tab walks title → notes (when shown) → pills, which is the composer's
    // keyboard cursor (the SwiftUI form's `focusOrder`). The title's link is
    // re-pointed as notes show/hide (`updateKeyChain`).
    notesView.nextKeyView = todayPill
    todayPill.nextKeyView = whenPill
    whenPill.nextKeyView = deadlinePill
    deadlinePill.nextKeyView = listPill
    listPill.nextKeyView = repeatPill
    repeatPill.nextKeyView = notesPill
    notesPill.nextKeyView = discussPill
    discussPill.nextKeyView = titleView
    updateKeyChain()
  }

  required init?(coder: NSCoder) { fatalError("KitComposerCell is code-only") }

  private static var titleAttributes: [NSAttributedString.Key: Any] {
    [.font: SeptaskKitTheme.taskTitle, .foregroundColor: NSColor.labelColor]
  }

  /// The shared text-view setup: borderless, transparent, width-tracking, and
  /// hosted in a scroll view whose height WE set from the measured text (the
  /// documentView arrangement is the one `NSTextView` sizing mode that plays
  /// cleanly with Auto Layout). Scrollers only ever appear on notes at its cap.
  private static func styleTextView(_ view: KitComposerTextView, in scroll: NSScrollView) {
    view.importsGraphics = false
    view.allowsUndo = true
    view.isAutomaticQuoteSubstitutionEnabled = false
    view.drawsBackground = false
    view.focusRingType = .none
    view.insertionPointColor = .labelColor
    view.isHorizontallyResizable = false
    view.isVerticallyResizable = true
    view.minSize = .zero
    view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                          height: CGFloat.greatestFiniteMagnitude)
    view.textContainer?.widthTracksTextView = true
    view.textContainer?.lineFragmentPadding = 0
    scroll.documentView = view
    scroll.hasVerticalScroller = false
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.translatesAutoresizingMaskIntoConstraints = false
  }

  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + 6
    trailingConstraint.constant = -(inset + 8)
    super.layout()
    // Width can change on window resize — re-wrap and grow/shrink both fields.
    // Defer the table notify so we don't re-enter layout via noteHeightOfRows.
    if recomputeContentHeights(notify: false) {
      DispatchQueue.main.async { [weak self] in
        self?.onContentHeightChanged?()
      }
    }
  }

  /// The text column's width, from the cell's own bounds rather than the
  /// scroll views' — those are still zero before the first layout pass, and
  /// `expandedHeight` is read before it. Nil until the table has sized the
  /// cell at all (a fresh dequeue), when no measurement would be meaningful.
  private var textColumnWidth: CGFloat? {
    guard bounds.width > 60 else { return nil }
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    return bounds.width - (inset + 6 + KitCheckboxView.tapSize + 7) - (inset + 8)
  }

  // MARK: - Populate

  /// Full load — title AND notes included. Call ONLY when the composer is
  /// first opened for a task; never on a mid-edit refresh (see `refreshPills`).
  func configure(with task: SeptenaTask, listName: String?) {
    textUndo.removeAllActions()
    titleView.textStorage?.setAttributedString(
      NSAttributedString(string: task.title, attributes: Self.titleAttributes))
    titleView.typingAttributes = Self.titleAttributes
    let notes = task.notes ?? ""
    let fontSize = SeptaskKitTheme.notesFontSize
    notesView.textStorage?.setAttributedString(
      MarkdownNotesStyle.attributed(notes, fontSize: fontSize))
    notesView.typingAttributes = MarkdownNotesStyle.baseAttributes(fontSize: fontSize)
    notesShown = !notes.isEmpty
    notesScroll.isHidden = !notesShown
    notesPill.isOn = notesShown
    titleView.needsDisplay = true
    notesView.needsDisplay = true
    updateKeyChain()
    recomputeContentHeights(notify: false)
    refreshPills(with: task, listName: listName)
  }

  /// Pills + checkbox cues only — deliberately does NOT touch `titleView` or
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

  // MARK: - Focus

  func focusTitle() {
    // A freshly-opened composer reaches here before its first layout pass —
    // `beginComposing` swaps the cell in and focuses one runloop turn later,
    // while the row is still animating open, so the column's trailing pin
    // (set in `layout()`) has not resolved. Without this flush the text view
    // inherits a near-zero frame and you can only see the glyph you just
    // typed. Same guard, same reason as `SeptaskKitTaskCell.beginEditing`.
    layoutSubtreeIfNeeded()
    window?.makeFirstResponder(titleView)
    // Caret at the end (Things), not AppKit's select-all block — a selected
    // title reads as a second surface, and one stray keystroke replaces it.
    let end = (titleView.string as NSString).length
    titleView.setSelectedRange(NSRange(location: end, length: 0))
  }

  /// Title → notes while notes are on screen, straight to the rail otherwise;
  /// notes → rail is fixed.
  private func updateKeyChain() {
    titleView.nextKeyView = notesShown ? notesView : todayPill
  }

  /// True while the notes field holds the keyboard — what ⌘↩ toggles on.
  var isEditingNotes: Bool { window?.firstResponder === notesView }

  /// Reveal notes if they're folded and put the caret at their end.
  func focusNotes() {
    if !notesShown {
      toggleNotes()  // reveals, resizes the row, and focuses
      return
    }
    window?.makeFirstResponder(notesView)
    let end = (notesView.string as NSString).length
    notesView.setSelectedRange(NSRange(location: end, length: 0))
  }

  /// Whether the caret sits on the last visual line of a wrapped text view —
  /// ↓ there leaves the field; ↓ on an earlier line is a normal line move.
  private func caretOnLastLine(of view: NSTextView) -> Bool {
    guard let manager = view.layoutManager, let container = view.textContainer else { return true }
    manager.ensureLayout(for: container)
    let glyphCount = manager.numberOfGlyphs
    let length = (view.string as NSString).length
    guard glyphCount > 0, length > 0 else { return true }
    let caret = min(view.selectedRange().location, length - 1)
    let glyph = min(manager.glyphIndexForCharacter(at: caret), glyphCount - 1)
    let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    return line.maxY >= manager.usedRect(for: container).maxY - 1
  }

  private func toggleNotes() {
    notesShown.toggle()
    notesScroll.isHidden = !notesShown
    notesPill.isOn = notesShown
    updateKeyChain()
    recomputeContentHeights(notify: false)
    onNotesVisibilityChanged?()
    if notesShown { window?.makeFirstResponder(notesView) }
  }

  // MARK: - Measurement

  /// Fit both scroll views to their text — the title unclamped above one
  /// line, notes clamped to min/max. Returns whether either measurement
  /// changed enough to matter for row sizing. A no-op (false) before the
  /// table has given the cell a width.
  @discardableResult
  private func recomputeContentHeights(notify: Bool) -> Bool {
    guard let width = textColumnWidth else { return false }
    var changed = false

    let titleHeight = max(Self.titleLineHeight, measured(titleView, width: width))
    if abs(titleHeight - measuredTitleHeight) > 0.5 {
      measuredTitleHeight = titleHeight
      titleHeightConstraint.constant = titleHeight
      changed = true
    }

    if notesShown {
      let next = min(Self.notesMaxHeight,
                     max(Self.notesMinHeight, measured(notesView, width: width)))
      if abs(next - measuredNotesHeight) > 0.5 {
        measuredNotesHeight = next
        notesHeightConstraint.constant = next
        changed = true
      }
      notesScroll.hasVerticalScroller = next >= Self.notesMaxHeight - 1
    } else if abs(measuredNotesHeight - Self.notesMinHeight) > 0.5 {
      measuredNotesHeight = Self.notesMinHeight
      notesHeightConstraint.constant = Self.notesMinHeight
      notesScroll.hasVerticalScroller = false
      changed = true
    }

    if changed, notify { onContentHeightChanged?() }
    return changed
  }

  /// Wrapped text height at `width`, insets included.
  private func measured(_ view: NSTextView, width: CGFloat) -> CGFloat {
    view.textContainer?.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
    view.frame.size.width = width
    guard let manager = view.layoutManager, let container = view.textContainer else { return 0 }
    manager.ensureLayout(for: container)
    let used = manager.usedRect(for: container)
    return ceil(used.height + view.textContainerInset.height * 2)
  }

  // MARK: - Commit

  /// Current field contents, for the controller's autosave.
  var pendingTitle: String { titleView.string }
  var pendingNotes: String? {
    let text = notesView.string.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }

  func commit() {
    onCommit?(pendingTitle, pendingNotes)
  }

  // MARK: - Keyboard

  func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    switch commandSelector {
    // Return opened the row, so Return in the title closes it. Notes is prose
    // — Return inserts a line there; ⌘↩ (caught by the table, see
    // `SeptaskKitTaskListController.toggleNotesEditing`) is its exit.
    case #selector(NSResponder.insertNewline(_:)) where textView === titleView:
      deferCommitAndCollapse()
      return true
    // ↓ on the title's LAST line moves the caret into notes, revealing them
    // if folded — the open row reads top-to-bottom like a document. Notes
    // never hands focus back up on ↑: it's prose, the caret stays inside.
    case #selector(NSResponder.moveDown(_:))
      where textView === titleView && caretOnLastLine(of: titleView):
      focusNotes()
      return true
    // Autosaves like the SwiftUI inline host — Esc folds the row, it doesn't
    // discard what was typed. One press from either field (notes used to hop
    // to the title first, so closing took two).
    case #selector(NSResponder.cancelOperation(_:)):
      deferCommitAndCollapse()
      return true
    // Tab moves the keyboard cursor along the composer instead of inserting
    // a tab character — same as the SwiftUI form's `.tab` handler on both
    // fields. `nextKeyView` decides where (title → notes → rail).
    case #selector(NSResponder.insertTab(_:)):
      window?.selectNextKeyView(nil)
      return true
    case #selector(NSResponder.insertBacktab(_:)):
      window?.selectPreviousKeyView(nil)
      return true
    default:
      return false
    }
  }

  /// `commit()` calls through to `TaskMutator`, which posts its change
  /// notification SYNCHRONOUSLY — and that notification's OWN observers (the
  /// sidebar rebuild in particular) can reselect and call back down into
  /// `focusList()`, i.e. `makeFirstResponder`, on the very row/text view
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

  /// Esc on a focused pill (or anything else in this cell that doesn't eat
  /// the command) also folds — "anywhere in open-task mode".
  override func cancelOperation(_ sender: Any?) {
    deferCommitAndCollapse()
  }

  /// Both text views' edits keep their undo in the row-local manager (see
  /// `textUndo`), never on the shared task stack.
  func undoManager(for view: NSTextView) -> UndoManager? { textUndo }

  func textDidChange(_ notification: Notification) {
    guard let textView = notification.object as? NSTextView else { return }
    if textView === titleView {
      flattenTitleLineBreaks()
    } else if textView === notesView {
      MarkdownNotesStyle.restyle(notesView, fontSize: SeptaskKitTheme.notesFontSize)
    }
    recomputeContentHeights(notify: true)
  }

  /// A title is one line. A pasted multi-line string would otherwise sit in
  /// the view with its breaks intact and be written to the model that way.
  /// Notes keeps its breaks — that field is prose. Same contract as
  /// `NSTextField.septaskFlattenPastedLineBreaks` on the bare-rename path:
  /// `TaskTitleText.singleLine` joins with one space so words don't fuse, and
  /// the caret lands at the end (a paste puts it there anyway).
  private func flattenTitleLineBreaks() {
    let raw = titleView.string
    guard raw.contains(where: \.isNewline) else { return }
    let flat = TaskTitleText.singleLine(raw)
    titleView.textStorage?.setAttributedString(
      NSAttributedString(string: flat, attributes: Self.titleAttributes))
    titleView.setSelectedRange(NSRange(location: (flat as NSString).length, length: 0))
  }
}

// MARK: - Text view with placeholder

/// `NSTextView` has no placeholder of its own. Drawing it inside the view (at
/// the text origin, in the view's own font) keeps it exactly where the first
/// glyph will land — an overlaid label never quite lines up with a text
/// container's origin. Reminders' "Add Note" / Things' "Notes" do the same.
@MainActor
final class KitComposerTextView: NSTextView {
  var placeholder = "" {
    didSet { needsDisplay = true }
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard string.isEmpty, !placeholder.isEmpty else { return }
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font ?? .systemFont(ofSize: NSFont.systemFontSize),
      .foregroundColor: NSColor.placeholderTextColor,
    ]
    let origin = NSPoint(
      x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0),
      y: textContainerOrigin.y)
    (placeholder as NSString).draw(at: origin, withAttributes: attributes)
  }

  /// Empty ↔ non-empty flips the placeholder; the text system only redraws
  /// the glyph rects, which are empty when the string is.
  override func didChangeText() {
    super.didChangeText()
    needsDisplay = true
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
