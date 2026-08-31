#if os(macOS)
import AppKit

// The AppKit shell's date pickers: ⌘S "When" and ⌘⇧D "Deadline". TIER 1
// surfaces (SeptaskKitSurface.swift): each edits one attribute of one row, so
// each is a popover anchored to that row — no sheet, no modal window. The
// Repeat editor below is the third member of that family.
//
// Layout is a ONE-WEEK day strip starting at TODAY, then "Pick another date",
// then Clear: scheduling answers "which of the next few days", so the popover
// shows seven labeled cells (weekday over day number) instead of a month grid.
// Today is the strip's FIRST CELL, and its weekday line reads "Today". There
// used to be a separate Today row above a strip that started tomorrow — one
// question asked by two controls in two vocabularies — and the two were
// collapsed into the strip.
//
// Anything further out than the strip lives behind "Pick another date", which
// swaps the board for `NSDatePicker`'s month calendar in place (a nested
// popover would dismiss this transient one). That row is the AppKit twin of
// SwiftUI's, so both boards offer the same four things: the week, a month, a
// clear, and nothing else.
//
// The board is keyboard-first and walks ONE axis — time. ↓ and → step later,
// ↑ and ← step earlier, straight through the seven days → Pick another date →
// Clear. Return picks, Escape closes. On the calendar page the same four keys
// move the date itself (←/→ a day, ↑/↓ a week), Return commits it and Escape
// returns to the week. One highlight language throughout — the shell's
// `SeptaskKitTheme.listSelectionFill` wash, moved by BOTH keyboard and hover,
// so a keyboard highlight never competes with a mouse one.
//
// "When" writes scheduled/today; "Deadline" writes the hard date. Both offer
// Clear. Every write goes through TaskMutator via the caller's closure — this
// type owns presentation only.
@MainActor
enum SeptaskKitDatePopover {

  enum Kind {
    case when
    case deadline

    var clearTitle: String {
      switch self {
      case .when:
        return String(localized: "Clear (Anytime)", comment: "SeptaskKit: date popover clear")
      case .deadline:
        return String(localized: "No Deadline", comment: "SeptaskKit: date popover clear")
      }
    }
  }

  /// `nil` date = the caller clears; `today` distinguishes the Today flag
  /// from a dated schedule for `.when`.
  typealias Handler = (_ date: Date?, _ today: Bool) -> Void

  /// Anchor to `rect` in `view` and show. The handler fires on choice, and the
  /// popover closes itself. Chrome, material and radius come from
  /// `KitPopover` — this type owns the board, not the glass.
  static func present(kind: Kind, initial: Date?, relativeTo rect: NSRect,
                      of view: NSView, handler: @escaping Handler) {
    let handle = KitPopoverHandle()
    let board = KitDateBoard(kind: kind, initial: initial) { date, today in
      handler(date, today)
      handle.close()
    } onCancel: {
      handle.close()
    }
    // `focus:` claims first responder on appear. Without it the popover routes
    // keys nowhere and the picker is mouse-only.
    KitPopover.present(board, relativeTo: rect, of: view, focus: board, handle: handle)
  }
}

// MARK: - Repeat editor

/// What the Repeat editor opens on. Built from ONE row or from a whole
/// selection: each axis carries the value every selected row agrees on, or
/// `nil` when they differ. `nil` is a real state, not "unset" — the editor
/// renders it as no choice marked, and never writes an axis it was not asked
/// about.
struct SeptaskKitRepeatSelection {
  var count: Int
  var unit: Recurrence.Unit?
  var interval: Int?
  var afterCompletion: Bool?
  var paused: Bool?
  /// At least one selected row already repeats — gates the Pause / Don't
  /// Repeat rows.
  var anyRepeats: Bool
  /// EVERY selected row can honor a fixed schedule: it has a date to advance
  /// from, or already carries a fixed rule. Quantified over the whole
  /// selection on purpose — writing a fixed rule to a dateless row lands
  /// `recurrenceAnchorDate` nil, and the "fixed" rule then quietly behaves
  /// like an after-completion one and never catches up.
  var canUseFixedSchedule: Bool

  init(_ tasks: [SeptenaTask]) {
    let rules = tasks.map(\.recurrence)
    count = tasks.count
    unit = Self.agreed(rules.map { $0?.unit })
    interval = Self.agreed(rules.map { $0?.interval })
    afterCompletion = Self.agreed(rules.map { $0?.afterCompletion })
    paused = Self.agreed(tasks.map { $0.recurrence == nil ? nil : $0.recurrencePaused })
    anyRepeats = rules.contains { $0 != nil }
    canUseFixedSchedule = !tasks.isEmpty && tasks.allSatisfy {
      $0.scheduled != nil || $0.recurrence?.afterCompletion == false
    }
  }

  /// The one value every row carries — nil if they differ, or if any row has
  /// none. A repeating row selected alongside a non-repeating one is a
  /// disagreement, not a default.
  private static func agreed<T: Equatable>(_ values: [T?]) -> T? {
    let present = values.compactMap { $0 }
    guard present.count == values.count, let first = present.first,
          present.allSatisfy({ $0 == first }) else { return nil }
    return first
  }
}

/// What the Repeat editor commits: ONLY the axes the user actually answered.
///
/// A selection can hold three different cadences, so the editor returns a
/// PATCH rather than a finished rule. It used to hand back one whole
/// `Recurrence` built from row ONE — so changing the unit across a
/// multi-selection also stamped row one's interval and anchor onto every
/// other row, silently flattening them. The caller overlays this on each
/// row's own rule instead, and an axis the user never touched is left alone.
struct SeptaskKitRecurrencePanelResult {
  /// "Don't Repeat" — clear the rule on every selected row. When true, every
  /// other field is ignored.
  var clears = false
  var unit: Recurrence.Unit?
  var interval: Int?
  var afterCompletion: Bool?
  var paused: Bool?

  /// Overlay the patch on one row's existing rule. A row with no rule yet
  /// starts from the editor's own defaults, so a bare "make these monthly"
  /// still produces a whole, valid rule.
  func applied(to current: Recurrence?) -> Recurrence {
    Recurrence(unit: unit ?? current?.unit ?? .week,
               interval: interval ?? current?.interval ?? 1,
               afterCompletion: afterCompletion ?? current?.afterCompletion ?? true)
  }
}

/// The Repeat editor — a TIER 1 anchored popover, exactly like When and
/// Deadline (SeptaskKitSurface.swift). It edits one attribute of one row, so
/// it hangs off that row.
///
/// It used to be a titled floating utility window with its own title bar, a
/// second in-content heading, a hardcoded blue icon badge, and an OK button:
/// four kinds of chrome no other surface in the shell has, for a job the other
/// surfaces do with none. All four are gone.
///
/// Commit contract is `close-commits`, the shell's contract for a surface with
/// SEVERAL fields (the inspector's is the same): the controls edit a draft and
/// dismissal accepts it. Writing on every step would push one CloudKit change
/// per click of the stepper. "Don't Repeat" is terminal — it writes and closes
/// on the spot, the way the date board's "Clear (Anytime)" row does.
@MainActor
enum SeptaskKitRepeatPopover {
  static func present(selection: SeptaskKitRepeatSelection,
                      relativeTo rect: NSRect, of view: NSView,
                      onCommit: @escaping (SeptaskKitRecurrencePanelResult) -> Void) {
    let board = KitRepeatBoard(selection: selection)
    let handle = KitPopoverHandle()
    board.onTerminal = { result in
      onCommit(result)
      handle.close()
    }
    board.onCancel = { handle.close() }
    KitPopover.present(board, relativeTo: rect, of: view, focus: board, handle: handle) {
      // Dismissal accepts the draft — unless a terminal row already answered,
      // the draft was cancelled, or nothing was actually chosen.
      guard let result = board.pendingResult else { return }
      onCommit(result)
    }
  }
}

/// The Repeat popover's body — built from the SAME parts as the date board:
/// a strip of `KitDateCell` choices, separators, terminal rows, and ONE
/// highlight language (the focus wash painted OVER a neutral current-value
/// ground). It used to be three different control species in one panel — an
/// `NSTextField`, an `NSStepper`, and two `NSSegmentedControl`s — none of
/// which appear anywhere else in the shell. The number is the only typed
/// value now; every other answer is a cell.
///
/// It walks ONE linear axis, like the date board: ↑/← back, ↓/→ forward,
/// Return chooses, Escape CANCELS. Reading order is the sentence the editor
/// asks — how many, of what, counted from where.
///
/// Commit contract is `close-commits`, the shell's contract for a surface
/// with several fields (the inspector's is the same): the cells edit a draft
/// and dismissal accepts it, so a stepper click doesn't push one CloudKit
/// change per press. Three things bound it, and each was a real bug:
///   • Dismissal commits only if something was actually CHOSEN (`didEdit`).
///     The draft is pre-populated, so "differs from `initial`" read as an
///     edit — opening the editor on a non-repeating task and pressing Escape
///     wrote a weekly repeat nobody asked for.
///   • Escape cancels. It used to fall through to the popover's close, which
///     is the commit path.
///   • The typed interval is flushed out of the field editor before it is
///     read. Closing the popover with "3" still in the field committed the
///     old number.
/// "Don't Repeat" is terminal — it writes and closes on the spot, the way the
/// date board's "Clear (Anytime)" row does.
///
/// It edits ONE row or a whole selection with the same body. A selection that
/// disagrees on an axis shows that axis with nothing marked — the standard
/// mixed state — and the draft it hands back is a PATCH, so an axis nobody
/// answered is never written. See `SeptaskKitRecurrencePanelResult`.
@MainActor
private final class KitRepeatBoard: NSView {

  /// Fired by a terminal row ("Don't Repeat") — commits and closes at once.
  var onTerminal: ((SeptaskKitRecurrencePanelResult) -> Void)?
  /// Fired by Escape — closes WITHOUT committing the draft.
  var onCancel: (() -> Void)?

  /// The state the editor opened on. Every axis is compared back to this, so
  /// re-picking the value a row already has writes nothing.
  private let selection: SeptaskKitRepeatSelection
  /// The draft. `nil` on an axis means "the selection disagrees and the user
  /// has not answered" — never a default. That distinction is the whole
  /// multi-selection fix: a nil axis is not written.
  private var unit: Recurrence.Unit?
  private var afterCompletion: Bool?
  private var paused: Bool?
  /// True once a cell or the stepper actually answered the question. Nothing
  /// is written without it — see the commit contract above.
  private var didEdit = false
  private var didFinish = false

  private let intervalField = NSTextField(string: "1")
  private let intervalStepper = NSStepper()
  private let cadenceDescription = NSTextField(labelWithString: "")
  private var unitCells: [KitDateCell] = []
  private var anchorCells: [KitDateCell] = []
  private var pauseCell: KitDateCell?

  /// Every focusable cell in reading order: the three units, the two anchors,
  /// then Pause and Don't Repeat. A cell the board cannot offer (the fixed
  /// schedule with no date on the task) is built but left OUT of this list,
  /// so the walk never lands somewhere that does nothing.
  private var cells: [KitDateCell] = []
  private var focusIndex = 0

  /// Matches `KitDateBoard`'s outer width (its 344pt strip plus the same 8pt
  /// padding) so the two members of the family don't resize the popover
  /// between them.
  private static let width: CGFloat = 360
  private static let padding: CGFloat = 8
  private static let rowHeight: CGFloat = 32
  private static let unitHeight: CGFloat = 36
  private static let unitSpacing: CGFloat = 6

  private static let unitOptions: [(unit: Recurrence.Unit, title: String)] = [
    (.day, String(localized: "day", comment: "Repeat unit")),
    (.week, String(localized: "week", comment: "Repeat unit")),
    (.month, String(localized: "month", comment: "Repeat unit")),
  ]

  init(selection: SeptaskKitRepeatSelection) {
    self.selection = selection
    // Seeded from what the selection AGREES on — including agreeing on
    // nothing. Never invent an anchor: a task with no date can only repeat
    // after completion, but an EXISTING fixed-schedule rule keeps its mode
    // even if the date was cleared. Forcing `true` here (which the hidden
    // segmented control did) rewrote the series' meaning without saying so,
    // and `setRecurrence` then dropped its `recurrenceAnchorDate` too.
    self.unit = selection.unit
    self.afterCompletion = selection.afterCompletion
    self.paused = selection.paused
    super.init(frame: .zero)
    build()
  }

  required init?(coder: NSCoder) { fatalError("KitRepeatBoard is code-only") }

  override var acceptsFirstResponder: Bool { true }
  override func becomeFirstResponder() -> Bool { true }

  /// A fixed schedule needs a date to advance from, on EVERY row it will be
  /// written to. The row stays offerable for a task that already carries such
  /// a rule, so opening the editor can never be the thing that silently
  /// converts it.
  private var canPickFixedSchedule: Bool { selection.canUseFixedSchedule }

  /// What dismissal should commit — nil once a terminal row has answered (so
  /// closing never writes twice), nil when nothing was chosen (so looking at
  /// the editor and closing it is not an edit), and nil when the draft still
  /// matches what was opened (so it pushes no CloudKit change and no undo
  /// entry).
  var pendingResult: SeptaskKitRecurrencePanelResult? {
    guard !didFinish else { return nil }
    // A live field editor holds the typed interval until it commits, and the
    // popover's close does not end editing for us.
    window?.endEditing(for: nil)
    guard didEdit else { return nil }
    // Axis by axis against what was opened, so re-picking a value the
    // selection already carries pushes no CloudKit change and no undo entry.
    guard unit != selection.unit
            || interval != selection.interval
            || afterCompletion != selection.afterCompletion
            || paused != selection.paused else { return nil }
    return SeptaskKitRecurrencePanelResult(unit: unit, interval: interval,
                                           afterCompletion: afterCompletion,
                                           paused: paused)
  }

  // MARK: Build

  private func build() {
    var views: [NSView] = [buildIntervalRow(), buildUnitStrip()]

    cadenceDescription.font = .systemFont(ofSize: SeptenaTypeScale.size(.footnote))
    cadenceDescription.textColor = SeptaskKitTheme.inkSecondary
    cadenceDescription.lineBreakMode = .byWordWrapping
    cadenceDescription.maximumNumberOfLines = 3
    views.append(cadenceDescription)

    views.append(KitSurface.separator())
    views.append(contentsOf: buildAnchorCells())

    // Terminal rows — only a task that already repeats can be paused or
    // stopped. Same row shape and same highlight as the date board's Clear.
    if selection.anyRepeats {
      views.append(KitSurface.separator())

      let pause = KitDateCell(radius: 8, height: Self.rowHeight) { [weak self] in
        self?.togglePaused()
      }
      pause.fillRow(symbol: pauseSymbol, tint: SeptaskKitTheme.iconMuted, title: pauseTitle)
      pauseCell = pause
      views.append(pause)
      cells.append(pause)

      let stop = KitDateCell(radius: 8, height: Self.rowHeight) { [weak self] in
        self?.stopRepeating()
      }
      stop.fillRow(symbol: "xmark.circle", tint: SeptaskKitTheme.iconMuted,
                   title: String(localized: "Don’t Repeat", comment: "Repeat editor stop"))
      views.append(stop)
      cells.append(stop)
    }

    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.setCustomSpacing(6, after: views[0])
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    let pad = Self.padding
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: Self.width),
      stack.topAnchor.constraint(equalTo: topAnchor, constant: pad),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
    ])
    for view in views {
      view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    // Start the walk on the unit the task already repeats by, the way the
    // date board starts on the day it is already scheduled for.
    focusIndex = unit.flatMap { current in
      Self.unitOptions.firstIndex { $0.unit == current }
    } ?? 0
    for cell in cells {
      cell.onHover = { [weak self] hovered in self?.focus(cell: hovered) }
    }
    updateValues()
  }

  /// "Every [2] ⬍" — the number is the one typed value on the board.
  private func buildIntervalRow() -> NSView {
    let every = NSTextField(labelWithString: String(localized: "Every",
                                                    comment: "Repeat interval prefix"))
    every.font = .systemFont(ofSize: SeptenaTypeScale.size(.body))
    every.textColor = SeptaskKitTheme.inkPrimary
    every.setContentHuggingPriority(.required, for: .horizontal)

    intervalField.alignment = .right
    intervalField.font = .systemFont(ofSize: SeptenaTypeScale.size(.body))
    intervalField.bezelStyle = .roundedBezel
    intervalField.drawsBackground = true
    intervalField.backgroundColor = .controlBackgroundColor
    intervalField.target = self
    intervalField.action = #selector(intervalChanged)
    let formatter = NumberFormatter()
    formatter.minimum = 1
    formatter.maximum = 99
    intervalField.formatter = formatter
    // A selection that disagrees on the interval opens EMPTY, with a mixed
    // placeholder — not on row one's number, which is what used to get
    // stamped across the whole selection.
    intervalField.placeholderString = "—"
    intervalField.widthAnchor.constraint(equalToConstant: 46).isActive = true
    intervalField.setAccessibilityTitle(String(localized: "Repeat every",
                                               comment: "SeptaskKit: repeat interval a11y"))

    intervalStepper.minValue = 1
    intervalStepper.maxValue = 99
    intervalStepper.increment = 1
    intervalStepper.valueWraps = false
    intervalStepper.target = self
    intervalStepper.action = #selector(stepperChanged)

    // The trailing spacer keeps the field left-aligned with the unit strip
    // below it, rather than letting NSStackView stretch the controls.
    let shove = NSView()
    shove.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = NSStackView(views: [every, intervalField, intervalStepper, shove])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 6
    return row
  }

  /// day / week / month as three choice cells — the repeat board's answer to
  /// the date board's day strip, in the same cell, wash, and walk.
  private func buildUnitStrip() -> NSView {
    let strip = NSStackView()
    strip.orientation = .horizontal
    strip.spacing = Self.unitSpacing
    strip.distribution = .fillEqually
    for option in Self.unitOptions {
      let cell = KitDateCell(radius: 10, height: Self.unitHeight) { [weak self] in
        self?.choose(unit: option.unit)
      }
      cell.fillTitle(option.title)
      strip.addArrangedSubview(cell)
      unitCells.append(cell)
      cells.append(cell)
    }
    return strip
  }

  /// The two anchors, as rows rather than a segmented control: "after it's
  /// checked off" and "on the scheduled date". Both are always VISIBLE — the
  /// fixed one is dimmed and unwalkable when the task has no date to advance
  /// from, with the reason in its own subtitle instead of a hint that
  /// replaced the control entirely.
  private func buildAnchorCells() -> [NSView] {
    let completion = KitDateCell(radius: 8, height: Self.rowHeight) { [weak self] in
      self?.choose(afterCompletion: true)
    }
    completion.fillRow(symbol: "checkmark.circle", tint: SeptaskKitTheme.inkSecondary,
                       title: String(localized: "After it’s checked off",
                                     comment: "Repeat anchor mode"))

    let offerable = canPickFixedSchedule
    let scheduled = KitDateCell(radius: 8, height: Self.rowHeight) { [weak self] in
      guard offerable else { NSSound.beep(); return }
      self?.choose(afterCompletion: false)
    }
    scheduled.fillRow(
      symbol: "calendar",
      tint: offerable ? SeptaskKitTheme.inkSecondary : SeptaskKitTheme.iconMuted,
      title: offerable
        ? String(localized: "On the scheduled date", comment: "Repeat anchor mode")
        : String(localized: "On the scheduled date — needs a date",
                 comment: "Repeat anchor mode, unavailable"),
      titleColor: offerable ? SeptaskKitTheme.inkPrimary : SeptaskKitTheme.iconMuted)

    anchorCells = [completion, scheduled]
    cells.append(completion)
    if offerable { cells.append(scheduled) }
    return anchorCells
  }

  // MARK: Values

  /// The typed interval, or nil while a disagreeing selection is unanswered.
  private var interval: Int? {
    let text = intervalField.stringValue.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty, let value = Int(text) else { return nil }
    return min(99, max(1, value))
  }

  /// Mixed paused state offers the action that makes the selection uniform.
  private var pauseTitle: String {
    paused == true
      ? String(localized: "Resume Repeat", comment: "Repeat editor pause action")
      : String(localized: "Pause Repeat", comment: "Repeat editor pause action")
  }

  private var pauseSymbol: String { paused == true ? "play.circle" : "pause.circle" }

  private func updateValues() {
    if let value = interval ?? selection.interval {
      intervalField.integerValue = value
      intervalStepper.integerValue = value
    } else {
      intervalField.stringValue = ""      // mixed — the placeholder shows
      intervalStepper.integerValue = 1
    }
    // Current value = the neutral ground; focus = the accent wash painted
    // over it. One language, two states — the same if/else the day strip
    // uses for today-vs-focus. A mixed axis marks NOTHING, which is exactly
    // what "these rows disagree" should look like.
    for (index, cell) in unitCells.enumerated() {
      cell.isCurrentValue = unit != nil && Self.unitOptions[index].unit == unit
    }
    anchorCells[0].isCurrentValue = afterCompletion == true
    anchorCells[1].isCurrentValue = afterCompletion == false
    applyFocus()
    updateDescription()
  }

  /// The sentence under the controls. It can only be written when the draft
  /// answers every axis — a selection still holding two cadences has no
  /// single sentence, so it says what WILL happen instead: only the axes the
  /// user answers get written.
  private func updateDescription() {
    let rows = selection.count
    guard let unit, let afterCompletion, let count = interval ?? selection.interval else {
      cadenceDescription.stringValue = String(
        localized: "\(rows) tasks with different repeat settings. Only what you change is written.",
        comment: "Repeat editor summary, mixed selection")
      return
    }
    let unitName: String
    switch unit {
    case .day:
      unitName = count == 1
        ? String(localized: "day", comment: "Repeat cadence unit")
        : String(localized: "days", comment: "Repeat cadence unit, plural")
    case .week:
      unitName = count == 1
        ? String(localized: "week", comment: "Repeat cadence unit")
        : String(localized: "weeks", comment: "Repeat cadence unit, plural")
    case .month:
      unitName = count == 1
        ? String(localized: "month", comment: "Repeat cadence unit")
        : String(localized: "months", comment: "Repeat cadence unit, plural")
    }
    let sentence = afterCompletion
      ? String(localized: "A new copy \(count) \(unitName) after this one is checked off.",
               comment: "Repeat editor summary, after completion")
      : String(localized: "A new copy \(count) \(unitName) after the previous scheduled date.",
               comment: "Repeat editor summary, fixed schedule")
    cadenceDescription.stringValue = rows > 1
      ? sentence + " " + String(localized: "Applies to \(rows) tasks.",
                                comment: "Repeat editor multi-selection footnote")
      : sentence
  }

  // MARK: Focus

  private func focus(cell: KitDateCell) {
    guard let index = cells.firstIndex(where: { $0 === cell }) else { return }
    focusIndex = index
    applyFocus()
  }

  /// Clamped, not wrapping — walking off either end stays put rather than
  /// teleporting to the other end of the board.
  private func step(_ delta: Int) {
    guard !cells.isEmpty else { return }
    focusIndex = min(cells.count - 1, max(0, focusIndex + delta))
    applyFocus()
  }

  private func applyFocus() {
    for (index, cell) in cells.enumerated() { cell.isFocused = index == focusIndex }
  }

  // MARK: Actions

  private func choose(unit newUnit: Recurrence.Unit) {
    didEdit = true
    unit = newUnit
    updateValues()
  }

  private func choose(afterCompletion newValue: Bool) {
    didEdit = true
    afterCompletion = newValue
    updateValues()
  }

  @objc private func intervalChanged() {
    didEdit = true
    // Clearing the field is how a mixed selection stays mixed on this axis.
    if let value = interval {
      intervalStepper.integerValue = value
      intervalField.integerValue = value
    }
    updateDescription()
  }

  @objc private func stepperChanged() {
    didEdit = true
    intervalField.integerValue = intervalStepper.integerValue
    updateDescription()
  }

  /// Mixed pause resolves to paused — the action the row's label offered.
  private func togglePaused() {
    didEdit = true
    paused = !(paused ?? false)
    pauseCell?.updateRow(symbol: pauseSymbol, title: pauseTitle)
  }

  private func stopRepeating() {
    guard !didFinish else { return }
    didFinish = true
    onTerminal?(SeptaskKitRecurrencePanelResult(clears: true))
  }

  // MARK: Keys

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 126, 123: step(-1)                     // ↑ / ← — back
    case 125, 124: step(1)                      // ↓ / → — forward
    case 36, 76:                                // Return / Enter — choose
      guard cells.indices.contains(focusIndex) else { return }
      cells[focusIndex].activate()
    default: super.keyDown(with: event)
    }
  }

  /// Escape is a CANCEL, not a commit. `didFinish` suppresses the
  /// close-commits path on the way out.
  override func cancelOperation(_ sender: Any?) {
    didFinish = true
    onCancel?()
  }
}

// MARK: - Board

/// The popover's body: a seven-day strip starting today, "Pick another date",
/// and Clear — plus the key handling that walks them.
///
/// Navigation is LINEAR, not grid-shaped: each day in order → Pick another
/// date → Clear. ↓ and → both step forward in time, ↑ and ← both step back, so
/// "down" always means "later" no matter which part of the board holds focus.
/// A ragged (row, column) model made ↓ jump from a day to Clear, which reads
/// as a different axis than the one the user is walking.
@MainActor
private final class KitDateBoard: NSView {

  private let kind: SeptaskKitDatePopover.Kind
  private let onPick: (Date?, Bool) -> Void
  private let onCancel: () -> Void

  /// Every focusable cell in time order: the seven days, then Pick another
  /// date, then Clear.
  private var cells: [KitDateCell] = []
  private var focusIndex = 0

  /// The one child of `pageHost` — the week board, or the month calendar.
  private let pageHost = NSView()
  private var boardPage: NSView?
  private var calendarPage: NSView?
  private let calendar = NSDatePicker()
  private var setCell: KitDateCell?
  /// The date the calendar page holds. Committed only by "Set", never by
  /// moving through months, so paging the calendar can't schedule anything.
  private var calendarDate = Date()
  private var showingCalendar: Bool { calendarPage?.superview != nil }

  /// Panel padding. The highlight is INSET from the popover edge (the
  /// palette shape in `SelectionLanguage`, not the full-bleed list-row one),
  /// so a selected row never collides with the popover's rounded corners.
  private static let padding: CGFloat = 8
  private static let rowHeight: CGFloat = 32
  /// 44, not 40, so the first cell's "Today" label fits without shrinking.
  private static let dayWidth: CGFloat = 44
  private static let dayHeight: CGFloat = 48
  private static let daySpacing: CGFloat = 6
  /// TODAY through six days out — the same window as SwiftUI's `WeekStrip`
  /// (`.upcoming` = offsets 0...6), so the two surfaces offer the same days.
  private static let dayOffsets = Array(0...6)
  /// The strip sets the popover's width, and the calendar page matches it, so
  /// the popover doesn't resize when the pages swap.
  private static var boardWidth: CGFloat {
    CGFloat(dayOffsets.count) * dayWidth
      + CGFloat(dayOffsets.count - 1) * daySpacing
  }

  init(kind: SeptaskKitDatePopover.Kind, initial: Date?,
       onPick: @escaping (Date?, Bool) -> Void, onCancel: @escaping () -> Void) {
    self.kind = kind
    self.onPick = onPick
    self.onCancel = onCancel
    super.init(frame: .zero)
    build(initial: initial)
  }

  required init?(coder: NSCoder) { fatalError("KitDateBoard is code-only") }

  override var acceptsFirstResponder: Bool { true }
  override func becomeFirstResponder() -> Bool { true }

  // MARK: Build

  private func build(initial: Date?) {
    pageHost.translatesAutoresizingMaskIntoConstraints = false
    addSubview(pageHost)
    // Padding lives in these constants, NOT in `stack.edgeInsets` — the
    // insets came out flush against the popover edge, and a constraint
    // constant is unambiguous.
    let pad = Self.padding
    NSLayoutConstraint.activate([
      pageHost.topAnchor.constraint(equalTo: topAnchor, constant: pad),
      pageHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
      pageHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
      pageHost.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
      pageHost.widthAnchor.constraint(equalToConstant: Self.boardWidth),
    ])

    buildBoardPage(initial: initial)
    showBoard()
  }

  private func buildBoardPage(initial: Date?) {
    // The app's today (DayClock/SeptenaDate), never the wall clock.
    let today = KitDayFormat.todayDate() ?? Date()

    let strip = NSStackView()
    strip.orientation = .horizontal
    strip.spacing = Self.daySpacing
    strip.distribution = .fillEqually
    var dayCells: [KitDateCell] = []
    for offset in Self.dayOffsets {
      let date = KitDayFormat.day(offset: offset) ?? today
      let cell = KitDateCell(radius: 10, height: Self.dayHeight) { [weak self] in
        self?.pick(date)
      }
      cell.fillDay(date, isToday: offset == 0)
      cell.widthAnchor.constraint(equalToConstant: Self.dayWidth).isActive = true
      strip.addArrangedSubview(cell)
      dayCells.append(cell)
    }

    let calendarCell = KitDateCell(radius: 8, height: Self.rowHeight) { [weak self] in
      self?.showCalendar()
    }
    calendarCell.fillRow(symbol: "calendar", tint: SeptaskKitTheme.inkSecondary,
                         title: String(localized: "Pick another date",
                                       comment: "SeptaskKit: date popover calendar row"))

    let clearCell = KitDateCell(radius: 8, height: Self.rowHeight) { [weak self] in
      self?.onPick(nil, false)
    }
    clearCell.fillRow(symbol: "xmark.circle", tint: SeptaskKitTheme.iconMuted,
                      title: kind.clearTitle)

    let topSeparator = NSBox()
    topSeparator.boxType = .separator
    let bottomSeparator = NSBox()
    bottomSeparator.boxType = .separator

    let stack = NSStackView(views: [strip, topSeparator, calendarCell,
                                    bottomSeparator, clearCell])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.setCustomSpacing(8, after: strip)
    stack.setCustomSpacing(4, after: topSeparator)
    stack.setCustomSpacing(8, after: calendarCell)
    stack.setCustomSpacing(4, after: bottomSeparator)

    // The strip sets the width; the single-cell rows match it so every
    // highlight spans the same column.
    for view in [calendarCell, clearCell, topSeparator, bottomSeparator] as [NSView] {
      view.widthAnchor.constraint(equalTo: strip.widthAnchor).isActive = true
    }

    cells = dayCells + [calendarCell, clearCell]
    for cell in cells {
      cell.onHover = { [weak self] hovered in self?.focus(cell: hovered) }
    }

    // Start on the cell that already holds the task's value, so the arrows
    // walk from where the user is rather than from the top. With no value,
    // that is today — the first cell.
    if let initial, let index = Self.dayOffsets.firstIndex(where: { offset in
      guard let date = KitDayFormat.day(offset: offset) else { return false }
      return Calendar.current.isDate(date, inSameDayAs: initial)
    }) {
      focusIndex = index
    }
    boardPage = stack
  }

  // MARK: Pages

  private func show(page: NSView) {
    pageHost.subviews.forEach { $0.removeFromSuperview() }
    page.translatesAutoresizingMaskIntoConstraints = false
    pageHost.addSubview(page)
    NSLayoutConstraint.activate([
      page.topAnchor.constraint(equalTo: pageHost.topAnchor),
      page.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor),
      page.trailingAnchor.constraint(equalTo: pageHost.trailingAnchor),
      page.bottomAnchor.constraint(equalTo: pageHost.bottomAnchor),
    ])
    window?.makeFirstResponder(self)
  }

  private func showBoard() {
    guard let boardPage else { return }
    show(page: boardPage)
    applyFocus()
  }

  /// The "further out" path. The strip already covers the coming week, so the
  /// month calendar hides behind one row — and it takes the board's place
  /// rather than opening a second popover, which would dismiss this transient
  /// one on the spot.
  private func showCalendar() {
    calendarDate = currentFocusDate() ?? KitDayFormat.todayDate() ?? Date()
    show(page: calendarPage ?? buildCalendarPage())
    calendar.dateValue = calendarDate
    refreshSetCell()
  }

  private func buildCalendarPage() -> NSView {
    calendar.datePickerStyle = .clockAndCalendar
    calendar.datePickerElements = [.yearMonthDay]
    calendar.datePickerMode = .single
    calendar.drawsBackground = false
    calendar.isBezeled = false
    // The BOARD keeps key focus on this page: the four arrows move the date
    // itself (←/→ a day, ↑/↓ a week) and Return commits, which is the same
    // one-axis model the week strip walks. Handing first responder to the
    // picker would leave Return and Escape doing nothing.
    calendar.refusesFirstResponder = true
    calendar.target = self
    calendar.action = #selector(calendarChanged)

    let set = KitDateCell(radius: 8, height: Self.rowHeight) { [weak self] in
      guard let self else { return }
      self.pick(Calendar.current.startOfDay(for: self.calendarDate))
    }
    set.fillRow(symbol: "checkmark.circle", tint: SeptaskKitTheme.inkPrimary, title: "")
    setCell = set

    let separator = NSBox()
    separator.boxType = .separator

    let stack = NSStackView(views: [calendar, separator, set])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 6
    stack.setCustomSpacing(8, after: calendar)
    stack.setCustomSpacing(4, after: separator)
    set.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    // The Set row is the page's only focusable cell, so it always wears the
    // highlight — there is nowhere else for focus to be.
    set.isFocused = true
    calendarPage = stack
    return stack
  }

  @objc private func calendarChanged() {
    calendarDate = calendar.dateValue
    refreshSetCell()
  }

  private func moveCalendar(byDays days: Int) {
    guard let next = Calendar.current.date(byAdding: .day, value: days, to: calendarDate)
    else { return }
    calendarDate = next
    calendar.dateValue = next
    refreshSetCell()
  }

  private func refreshSetCell() {
    let title = String(format: String(localized: "Set %@",
                                      comment: "SeptaskKit: date popover commit row"),
                       Self.setFormatter.string(from: calendarDate))
    setCell?.updateRow(symbol: "checkmark.circle", title: title)
  }

  private static let setFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
    return formatter
  }()

  /// The date the focused strip cell stands for, so the calendar opens where
  /// the user already was rather than on today.
  private func currentFocusDate() -> Date? {
    guard Self.dayOffsets.indices.contains(focusIndex) else { return nil }
    return KitDayFormat.day(offset: Self.dayOffsets[focusIndex])
  }

  /// Scheduling a task to today IS the today flag for `.when`, so the strip's
  /// first cell writes the flag, not a dated schedule — and so does the
  /// calendar page when the user lands back on today. `.deadline` has no flag
  /// and always writes the date.
  private func pick(_ date: Date) {
    let today = KitDayFormat.todayDate() ?? Date()
    if kind == .when, Calendar.current.isDate(date, inSameDayAs: today) {
      onPick(nil, true)
    } else {
      onPick(date, false)
    }
  }

  // MARK: Focus

  private func applyFocus() {
    for (index, cell) in cells.enumerated() {
      cell.isFocused = index == focusIndex
    }
  }

  private func focus(cell: KitDateCell) {
    guard let index = cells.firstIndex(where: { $0 === cell }) else { return }
    focusIndex = index
    applyFocus()
  }

  /// Clamped, not wrapping: walking off either end of a short list and
  /// silently landing at the other end is how a user picks the wrong date.
  private func step(_ delta: Int) {
    let next = focusIndex + delta
    guard cells.indices.contains(next) else { return }
    focusIndex = next
    applyFocus()
  }

  // MARK: Keys

  override func keyDown(with event: NSEvent) {
    // Same four keys, same axis, on both pages: on the week they move focus
    // through time, on the calendar they move the date through time.
    if showingCalendar {
      switch event.keyCode {
      case 126: moveCalendar(byDays: -7)        // ↑ — a week earlier
      case 125: moveCalendar(byDays: 7)         // ↓ — a week later
      case 123: moveCalendar(byDays: -1)        // ← — a day earlier
      case 124: moveCalendar(byDays: 1)         // → — a day later
      case 36, 76, 49: setCell?.activate()      // Return / Enter / Space
      case 53: showBoard()                      // Escape — back to the week
      default: super.keyDown(with: event)
      }
      return
    }
    switch event.keyCode {
    case 126, 123: step(-1)                     // ↑ / ← — earlier
    case 125, 124: step(1)                      // ↓ / → — later
    case 36, 76, 49: cells[focusIndex].activate()  // Return / Enter / Space
    case 53: onCancel()                         // Escape
    default: super.keyDown(with: event)
    }
  }

  /// Escape drills back out of the calendar before it closes the popover, so
  /// one key never skips a level.
  override func cancelOperation(_ sender: Any?) {
    if showingCalendar { showBoard() } else { onCancel() }
  }
}

// MARK: - Cell

/// One focusable target on the board — a full-width row or a day in the strip.
/// Both paint the SAME highlight (`listSelectionFill`), so keyboard focus and
/// hover share one visual language.
@MainActor
private final class KitDateCell: NSView {

  private let radius: CGFloat
  private let action: () -> Void
  private var tracking: NSTrackingArea?

  var onHover: ((KitDateCell) -> Void)?
  var isFocused = false { didSet { needsDisplay = true } }
  /// Held so a row's label and glyph can change in place (the Repeat board's
  /// Pause row flips between two states). Re-calling `fillRow` would stack a
  /// second copy of the content on top of the first.
  private weak var rowIcon: NSImageView?
  private weak var rowLabel: NSTextField?
  /// Saturday/Sunday get a faint neutral ground so the week's shape is
  /// readable at a glance. Neutral on purpose — the accent belongs to focus
  /// alone, and focus paints OVER this rather than beside it, so the two
  /// never read as two competing highlights.
  private var isWeekend = false
  /// Today's cell carries a faint neutral ground of its own — the mark the
  /// separate Today row used to carry. Neutral for the same reason the
  /// weekend ground is: focus paints OVER it, never beside it.
  private var isToday = false
  /// "This cell holds the value the task already has" — the Repeat board's
  /// chosen unit and anchor. Deliberately the SAME neutral ground as
  /// `isToday` rather than a second highlight: current-value and focus are
  /// two states of one language, not two languages (DesignSpec §4.5).
  var isCurrentValue = false { didSet { needsDisplay = true } }

  init(radius: CGFloat, height: CGFloat, action: @escaping () -> Void) {
    self.radius = radius
    self.action = action
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: height).isActive = true
  }

  required init?(coder: NSCoder) { fatalError("KitDateCell is code-only") }

  func activate() { action() }

  // MARK: Content

  /// Symbol + title — the shape of a menu row. `titleColor` is the one knob:
  /// a row the board is showing but cannot offer dims its text to match its
  /// glyph, rather than disappearing and leaving the reader to guess.
  func fillRow(symbol: String, tint: NSColor, title: String,
               titleColor: NSColor = SeptaskKitTheme.inkPrimary) {
    let image = NSImageView()
    image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    image.symbolConfiguration = NSImage.SymbolConfiguration(
      pointSize: SeptenaTypeScale.size(.body), weight: .regular)
    image.contentTintColor = tint

    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: SeptenaTypeScale.size(.body))
    label.textColor = titleColor

    let stack = NSStackView(views: [image, label])
    stack.orientation = .horizontal
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
    embed(stack)
    rowIcon = image
    rowLabel = label
    setAccessibilityTitle(title)
  }

  /// Re-label a row built by `fillRow`, keeping its one set of subviews.
  func updateRow(symbol: String, title: String) {
    rowIcon?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    rowLabel?.stringValue = title
    setAccessibilityTitle(title)
  }

  /// A centered word — the Repeat board's unit strip. Same cell as the day
  /// strip, one line instead of two, so the two strips read as one component.
  func fillTitle(_ title: String) {
    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: SeptenaTypeScale.size(.body))
    label.textColor = SeptaskKitTheme.inkPrimary
    label.alignment = .center

    let stack = NSStackView(views: [label])
    stack.orientation = .vertical
    stack.alignment = .centerX
    embed(stack)
    setAccessibilityTitle(title)
  }

  /// Weekday over day number — the strip's cell, matched to SwiftUI's
  /// `WeekStrip` (11pt medium weekday, 17pt semibold rounded number) so the
  /// two surfaces read as one component. The strip starts at today, whose
  /// cell reads "Today" on the weekday line instead of the weekday name.
  func fillDay(_ date: Date, isToday: Bool) {
    isWeekend = Calendar.current.isDateInWeekend(date)
    self.isToday = isToday

    let weekdayText = isToday
      ? String(localized: "Today", comment: "Relative date")
      : Self.weekday.string(from: date)
    let weekday = NSTextField(labelWithString: weekdayText)
    weekday.font = .systemFont(ofSize: 11, weight: .medium)
    weekday.textColor = SeptaskKitTheme.inkSecondary
    weekday.alignment = .center
    weekday.maximumNumberOfLines = 1
    weekday.lineBreakMode = .byTruncatingTail

    let number = NSTextField(labelWithString: Self.number.string(from: date))
    number.font = Self.rounded(size: 17, weight: .semibold)
    number.textColor = SeptaskKitTheme.inkPrimary
    number.alignment = .center

    let stack = NSStackView(views: [weekday, number])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 2
    embed(stack)
    setAccessibilityTitle(Self.accessible.string(from: date))
  }

  private func embed(_ stack: NSStackView) {
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  // MARK: Paint & input

  override func draw(_ dirtyRect: NSRect) {
    // Focus replaces the weekend ground rather than stacking on it — the same
    // if/else the SwiftUI `WeekStrip` uses, and the same 0.09 secondary-ink
    // wash, so the two strips shade the weekend identically.
    if isFocused {
      SeptaskKitTheme.listSelectionFill(emphasized: true).setFill()
    } else if isToday || isCurrentValue {
      NSColor.labelColor.withAlphaComponent(0.12).setFill()
    } else if isWeekend {
      NSColor.secondaryLabelColor.withAlphaComponent(0.09).setFill()
    } else {
      return
    }
    NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: bounds,
                              options: [.mouseEnteredAndExited, .activeInKeyWindow],
                              owner: self, userInfo: nil)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { onHover?(self) }

  override func mouseUp(with event: NSEvent) { action() }

  // MARK: Fonts & formatters

  /// SF Rounded, the face SwiftUI's `WeekStrip` uses for the day number.
  private static func rounded(size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
    return NSFont(descriptor: descriptor, size: size) ?? base
  }

  private static let weekday: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("EEE")
    return formatter
  }()

  private static let number: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("d")
    return formatter
  }()

  private static let accessible: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("EEEEMMMd")
    return formatter
  }()
}
#endif
