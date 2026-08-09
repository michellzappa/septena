#if os(macOS)
import AppKit

// The inline composer: a task row that expands in place into an editor —
// title, then a rail of elective pills (Today / When / Deadline / List /
// Repeat / Notes), then an optional notes field. The AppKit counterpart of
// `TaskComposerCard` in `.inline` mode + `TaskAttributeBar`.
//
// The pills don't own any pickers of their own: each opens the SAME popover or
// menu the row commands use (`SeptaskKitDatePopover`, `KitMoveMenu`,
// `KitRecurrenceMenu`), so the composer and the ⌘S / ⌘⇧D / ⌘⇧M / Repeat paths
// can't drift into two different date pickers.
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
  private let notesPill = KitPillButton()

  private var leadingConstraint: NSLayoutConstraint!
  private var trailingConstraint: NSLayoutConstraint!
  private var notesShown = false

  // MARK: - Height

  private static let titleLineHeight: CGFloat = 24
  private static let pillRowHeight: CGFloat = 24
  private static let notesHeight: CGFloat = 76
  private static let verticalPadding: CGFloat = 10
  private static let interRowGap: CGFloat = 8

  /// The row height the controller must return for an expanded row. Kept here
  /// so the geometry lives with the layout that produces it.
  static func height(showsNotes: Bool) -> CGFloat {
    var height = verticalPadding * 2 + titleLineHeight + interRowGap + pillRowHeight
    if showsNotes { height += interRowGap + notesHeight }
    return height
  }

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier

    checkbox.translatesAutoresizingMaskIntoConstraints = false
    checkbox.onToggle = { [weak self] in self?.onAction?(.toggleComplete) }

    titleField.font = SeptaskKitTheme.taskTitle
    titleField.isBordered = false
    titleField.drawsBackground = false
    titleField.focusRingType = .none
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
    for pill in [todayPill, whenPill, deadlinePill, listPill, repeatPill, notesPill] {
      pillRow.addArrangedSubview(pill)
    }

    notesView.delegate = self
    notesView.font = .systemFont(ofSize: SeptenaTypeScale.size(.subheadline))
    notesView.isRichText = false
    notesView.drawsBackground = false
    notesView.textContainerInset = NSSize(width: 2, height: 4)
    notesScroll.documentView = notesView
    notesScroll.hasVerticalScroller = true
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
    NSLayoutConstraint.activate([
      leadingConstraint,
      checkbox.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalPadding + 2),
      checkbox.widthAnchor.constraint(equalToConstant: 20),
      checkbox.heightAnchor.constraint(equalToConstant: 20),
      titleField.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 7),
      titleField.centerYAnchor.constraint(equalTo: checkbox.centerYAnchor),
      trailingConstraint,

      pillRow.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
      pillRow.topAnchor.constraint(equalTo: titleField.bottomAnchor,
                                   constant: Self.interRowGap),
      pillRow.heightAnchor.constraint(equalToConstant: Self.pillRowHeight),
      pillRow.trailingAnchor.constraint(lessThanOrEqualTo: titleField.trailingAnchor),

      notesScroll.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
      notesScroll.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
      notesScroll.topAnchor.constraint(equalTo: pillRow.bottomAnchor,
                                       constant: Self.interRowGap),
      notesScroll.heightAnchor.constraint(equalToConstant: Self.notesHeight),
    ])

    // Tab walks title → pills → notes, which is the composer's keyboard cursor
    // (the SwiftUI rail's `.pill(attr)` focus chain).
    titleField.nextKeyView = todayPill
    todayPill.nextKeyView = whenPill
    whenPill.nextKeyView = deadlinePill
    deadlinePill.nextKeyView = listPill
    listPill.nextKeyView = repeatPill
    repeatPill.nextKeyView = notesPill
    notesPill.nextKeyView = titleField
  }

  required init?(coder: NSCoder) { fatalError("KitComposerCell is code-only") }

  override func layout() {
    let inset = SeptaskKitLayout.inset(for: bounds.width)
    leadingConstraint.constant = inset + 6
    trailingConstraint.constant = -(inset + 8)
    super.layout()
  }

  // MARK: - Populate

  /// Full load — title AND notes included. Call ONLY when the composer is
  /// first opened for a task; never on a mid-edit refresh (see `refreshPills`).
  func configure(with task: SeptenaTask, listName: String?) {
    titleField.stringValue = task.title
    notesView.string = task.notes ?? ""
    notesShown = !(task.notes ?? "").isEmpty
    notesScroll.isHidden = !notesShown
    notesPill.isOn = notesShown
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
    checkbox.tenureFill = task.todayTenureFill()
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
  }

  /// Whether the notes field is on screen — the controller needs this to size
  /// the row.
  var showsNotes: Bool { notesShown }

  func focusTitle() {
    window?.makeFirstResponder(titleField)
    titleField.currentEditor()?.selectAll(nil)
  }

  private func toggleNotes() {
    notesShown.toggle()
    notesScroll.isHidden = !notesShown
    notesPill.isOn = notesShown
    onNotesVisibilityChanged?()
    if notesShown { window?.makeFirstResponder(notesView) }
  }

  /// The row has to change height when notes appear/disappear.
  var onNotesVisibilityChanged: (() -> Void)?

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
    // Esc leaves the notes field for the title rather than closing the row —
    // Return has to stay a newline inside notes.
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      window?.makeFirstResponder(titleField)
      return true
    }
    return false
  }
}

// MARK: - Pill

/// One elective pill. A recessed `NSButton` is the platform's own capsule-with
/// -on-state control, so this needs no custom drawing — `isOn` gets the filled
/// treatment, matching the SwiftUI rail's "filled pills wear a gray capsule,
/// not the section accent".
@MainActor
final class KitPillButton: NSButton {
  var onPress: ((NSView) -> Void)?

  var isOn: Bool {
    get { state == .on }
    set { state = newValue ? .on : .off }
  }

  init() {
    super.init(frame: .zero)
    bezelStyle = .recessed
    setButtonType(.pushOnPushOff)
    font = SeptaskKitTheme.chip
    translatesAutoresizingMaskIntoConstraints = false
    target = self
    action = #selector(pressed)
  }

  required init?(coder: NSCoder) { fatalError("KitPillButton is code-only") }

  @objc private func pressed() { onPress?(self) }
}
#endif
