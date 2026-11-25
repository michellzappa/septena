#if os(macOS)
import AppKit
import SwiftData
import SwiftUI

// The AppKit shell's date pickers: ⌘S "When" and ⌘⇧D "Deadline". TIER 1
// surfaces (SeptaskKitSurface.swift): each edits one attribute of one row, so
// each is a popover anchored to that row — no sheet, no modal window. The
// Repeat editor below is the third member of that family.
//
// Layout is a ONE-WEEK day strip starting at TODAY, then one list of rows
// (Tomorrow, Pick another date, Clear, Repeat, Add time). The rows, their order
// and their words come from the registry (`RegistrySurfaces.dateBoardRows`),
// and every row is the same `KitDateCell`. Tomorrow is also the strip's second
// cell; its row stays because "tomorrow" is an answer people look for by name
// (decided 2026-11-24). Scheduling answers "which of the next few days", so the
// popover shows seven labeled cells (weekday over day number) instead of a
// month grid.
// Today is the strip's FIRST CELL, and its weekday line reads "Today". There
// used to be a separate Today row above a strip that started tomorrow — one
// question asked by two controls in two vocabularies — and the two were
// collapsed into the strip.
//
// Anything further out than the strip lives behind "Pick another date", which
// swaps the board for `NSDatePicker`'s month calendar in place (a nested
// popover would dismiss this transient one). That row is the AppKit twin of
// SwiftUI's, so both boards offer the same things: the week, tomorrow, a month,
// a clear, and (When only) the repeat and the time.
//
// The board is keyboard-first and walks ONE axis — time. ↓ and → step later,
// ↑ and ← step earlier, straight through the seven days and then down the
// rows. Return picks, Escape closes. On the calendar page the same four keys
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

  typealias Kind = RegistryDateBoardAttribute

  /// `nil` date = the caller clears; `today` distinguishes the Today flag
  /// from a dated schedule for `.when`.
  typealias Handler = (_ date: Date?, _ today: Bool) -> Void

  /// Anchor to `rect` in `view` and show. The handler fires on choice, and the
  /// popover closes itself. Chrome, material and radius come from
  /// `KitPopover` — this type owns the board, not the glass.
  static func present(kind: Kind, initial: Date?,
                      initialStartTime: String? = nil,
                      initialDurationMinutes: Int? = nil,
                      relativeTo rect: NSRect,
                      of view: NSView,
                      onTimeSlotChange: ((String?, Int?) -> Void)? = nil,
                      repeatTitle: String? = nil,
                      onRepeat: (() -> Void)? = nil,
                      handler: @escaping Handler) {
    let handle = KitPopoverHandle()
    // The Repeat row closes this popover first, then opens the Repeat editor
    // on the next turn: a transient popover can't host a second one.
    let openRepeat: (() -> Void)? = onRepeat.map { open in
      {
        handle.close()
        DispatchQueue.main.async { open() }
      }
    }
    let board = KitDateBoard(kind: kind, initial: initial,
                             initialStartTime: initialStartTime,
                             initialDurationMinutes: initialDurationMinutes,
                             onTimeSlotChange: onTimeSlotChange,
                             repeatTitle: kind == .when ? repeatTitle : nil,
                             onRepeat: kind == .when ? openRepeat : nil) { date, today in
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
  /// Agreed V2 schedule details across the selection (nil when absent or mixed).
  var weekdays: [Int]?
  var monthDay: Int?
  var ordinalWeekday: RecurrenceOrdinalWeekday?
  /// Single-row (or agreed) scheduled date used purely for live "Next: …" preview.
  var sampleScheduled: String?
  /// At least one selected row already repeats — gates the Pause / Don't
  /// Repeat rows.
  var anyRepeats: Bool
  /// EVERY selected row can honor a fixed schedule: it has a date to advance
  /// from, or already carries a fixed rule. Quantified over the whole
  /// selection on purpose — writing a fixed rule to a dateless row lands
  /// `recurrenceAnchorDate` nil, and the "fixed" rule then quietly behaves
  /// like an after-completion one and never catches up.
  var canUseFixedSchedule: Bool

  var hasCustomRule: Bool {
    weekdays != nil || monthDay != nil || ordinalWeekday != nil
  }

  init(_ tasks: [SeptenaTask]) {
    let rules = tasks.map(\.recurrence)
    count = tasks.count
    unit = Self.agreed(rules.map { $0?.unit })
    interval = Self.agreed(rules.map { $0?.interval })
    afterCompletion = Self.agreed(rules.map { $0?.afterCompletion })
    paused = Self.agreed(tasks.map { $0.recurrence == nil ? nil : $0.recurrencePaused })
    weekdays = Self.agreed(rules.map { $0?.weekdays })
    monthDay = Self.agreed(rules.map { $0?.monthDay })
    ordinalWeekday = Self.agreed(rules.map { $0?.ordinalWeekday })
    sampleScheduled = Self.agreed(tasks.map(\.scheduled))
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
  /// True when the user explicitly edited a V2 fixed-schedule detail (weekday
  /// set, day of month, or ordinal weekday) or chose the Weekdays preset.
  var setsScheduleDetail = false
  var weekdays: [Int]?
  var monthDay: Int?
  var ordinalWeekday: RecurrenceOrdinalWeekday?

  /// Overlay the patch on one row's existing rule. A row with no rule yet
  /// starts from the editor's own defaults, so a bare "make these monthly"
  /// still produces a whole, valid rule.
  func applied(to current: Recurrence?) -> Recurrence {
    Recurrence(unit: unit ?? current?.unit ?? .week,
               interval: interval ?? current?.interval ?? 1,
               afterCompletion: afterCompletion ?? current?.afterCompletion ?? true,
               weekdays: setsScheduleDetail ? weekdays : current?.weekdays,
               monthDay: setsScheduleDetail ? monthDay : current?.monthDay,
               ordinalWeekday: setsScheduleDetail ? ordinalWeekday : current?.ordinalWeekday)
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
  private var weekdays: Set<Int>
  private enum MonthlyMode: Int { case anchor = 0, dayOfMonth = 1, ordinal = 2 }
  private var monthlyMode: MonthlyMode
  private var monthDay: Int
  private var ordinal: Int
  private var ordinalWeekdayNum: Int
  private var customExpanded: Bool
  private var didEditScheduleDetail = false
  /// True once a cell or the stepper actually answered the question. Nothing
  /// is written without it — see the commit contract above.
  private var didEdit = false
  private var didFinish = false

  private let intervalField = NSTextField(string: "1")
  private let intervalStepper = NSStepper()
  private let cadenceDescription = NSTextField(labelWithString: "")
  private var unitCells: [KitDateCell] = []
  private var weekdaysPresetCell: KitDateCell?
  private var anchorCells: [KitDateCell] = []
  private var customToggleCell: KitDateCell?
  private let customContainer = NSStackView()
  private let weekdaySection = NSStackView()
  private var weekdayCells: [(weekday: Int, cell: KitDateCell)] = []
  private let monthlySection = NSStackView()
  private var monthlyModeCells: [(mode: MonthlyMode, cell: KitDateCell)] = []
  private let monthDayRow = NSStackView()
  private let monthDayPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private let ordinalRow = NSStackView()
  private let ordinalPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private let ordinalWeekdayPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private var pauseCell: KitDateCell?
  private var stopCell: KitDateCell?

  /// Every currently visible focusable cell in reading order. Rebuilt whenever
  /// progressive-disclosure sections expand or collapse so arrow navigation
  /// never lands on a hidden control.
  private var cells: [KitDateCell] = []
  private var focusIndex = 0

  /// Matches `KitDateBoard`'s outer width (its 344pt strip plus the same 8pt
  /// padding) so the two members of the family don't resize the popover
  /// between them.
  private static let width: CGFloat = 360
  private static let padding: CGFloat = 8
  private static let rowHeight: CGFloat = 32
  private static let unitHeight: CGFloat = 36
  private static let pillHeight: CGFloat = 30
  private static let unitSpacing: CGFloat = 6

  private static let unitOptions: [(unit: Recurrence.Unit, title: String)] = [
    (.day, String(localized: "day", comment: "Repeat unit")),
    (.week, String(localized: "week", comment: "Repeat unit")),
    (.month, String(localized: "month", comment: "Repeat unit")),
    (.year, String(localized: "year", comment: "Repeat unit")),
  ]

  /// ISO Monday-first order for weekday pills (matching `Recurrence.shortLabel`).
  private static let weekdayOptions: [(weekday: Int, short: String, full: String)] = [
    (2, "M", String(localized: "Monday", comment: "Weekday name")),
    (3, "T", String(localized: "Tuesday", comment: "Weekday name")),
    (4, "W", String(localized: "Wednesday", comment: "Weekday name")),
    (5, "T", String(localized: "Thursday", comment: "Weekday name")),
    (6, "F", String(localized: "Friday", comment: "Weekday name")),
    (7, "S", String(localized: "Saturday", comment: "Weekday name")),
    (1, "S", String(localized: "Sunday", comment: "Weekday name")),
  ]

  private static let ordinalOptions: [(value: Int, title: String)] = [
    (1, String(localized: "1st", comment: "Ordinal position")),
    (2, String(localized: "2nd", comment: "Ordinal position")),
    (3, String(localized: "3rd", comment: "Ordinal position")),
    (4, String(localized: "4th", comment: "Ordinal position")),
    (-1, String(localized: "Last", comment: "Ordinal position")),
  ]

  private static let fullWeekdayOptions: [(value: Int, title: String)] = [
    (1, String(localized: "Sunday", comment: "Weekday name")),
    (2, String(localized: "Monday", comment: "Weekday name")),
    (3, String(localized: "Tuesday", comment: "Weekday name")),
    (4, String(localized: "Wednesday", comment: "Weekday name")),
    (5, String(localized: "Thursday", comment: "Weekday name")),
    (6, String(localized: "Friday", comment: "Weekday name")),
    (7, String(localized: "Saturday", comment: "Weekday name")),
  ]

  private static let nextPreviewFormatter: DateFormatter = {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("EEEMMMd")
    return f
  }()

  private static func anchorDate(for scheduled: String?) -> Date {
    if let scheduled, let d = KitDayFormat.date(fromWire: scheduled) { return d }
    return KitDayFormat.todayDate() ?? DayClock.appNow
  }

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
    self.weekdays = Set(selection.weekdays ?? [])
    let sampleDate = Self.anchorDate(for: selection.sampleScheduled)
    let cal = Calendar.current
    if let ow = selection.ordinalWeekday {
      self.monthlyMode = .ordinal
      self.ordinal = ow.ordinal
      self.ordinalWeekdayNum = ow.weekday
      self.monthDay = cal.component(.day, from: sampleDate)
    } else if let md = selection.monthDay {
      self.monthlyMode = .dayOfMonth
      self.monthDay = md
      self.ordinal = min(4, max(1, (cal.component(.day, from: sampleDate) - 1) / 7 + 1))
      self.ordinalWeekdayNum = cal.component(.weekday, from: sampleDate)
    } else {
      self.monthlyMode = .anchor
      self.monthDay = cal.component(.day, from: sampleDate)
      self.ordinal = min(4, max(1, (cal.component(.day, from: sampleDate) - 1) / 7 + 1))
      self.ordinalWeekdayNum = cal.component(.weekday, from: sampleDate)
    }
    self.customExpanded = selection.hasCustomRule
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

  private var resolvedWeekdays: [Int]? {
    guard afterCompletion == false, unit == .week, !weekdays.isEmpty else { return nil }
    return weekdays.sorted()
  }

  private var resolvedMonthDay: Int? {
    guard afterCompletion == false, unit == .month || unit == .year,
          monthlyMode == .dayOfMonth else { return nil }
    return monthDay
  }

  private var resolvedOrdinalWeekday: RecurrenceOrdinalWeekday? {
    guard afterCompletion == false, unit == .month || unit == .year,
          monthlyMode == .ordinal else { return nil }
    return RecurrenceOrdinalWeekday(ordinal: ordinal, weekday: ordinalWeekdayNum)
  }

  private var supportsCustomOptions: Bool {
    canPickFixedSchedule && afterCompletion == false
      && (unit == .week || unit == .month || unit == .year)
  }

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
    let nextWeekdays = didEditScheduleDetail ? resolvedWeekdays : selection.weekdays
    let nextMonthDay = didEditScheduleDetail ? resolvedMonthDay : selection.monthDay
    let nextOrdinal = didEditScheduleDetail ? resolvedOrdinalWeekday : selection.ordinalWeekday
    // Axis by axis against what was opened, so re-picking a value the
    // selection already carries pushes no CloudKit change and no undo entry.
    guard unit != selection.unit
            || interval != selection.interval
            || afterCompletion != selection.afterCompletion
            || paused != selection.paused
            || nextWeekdays != selection.weekdays
            || nextMonthDay != selection.monthDay
            || nextOrdinal != selection.ordinalWeekday else { return nil }
    return SeptaskKitRecurrencePanelResult(
      unit: unit,
      interval: interval,
      afterCompletion: afterCompletion,
      paused: paused,
      setsScheduleDetail: didEditScheduleDetail,
      weekdays: resolvedWeekdays,
      monthDay: resolvedMonthDay,
      ordinalWeekday: resolvedOrdinalWeekday
    )
  }

  // MARK: Build

  private func build() {
    var views: [NSView] = [buildIntervalRow(), buildUnitStrip()]

    if canPickFixedSchedule {
      let preset = KitDateCell(radius: 8, height: Self.rowHeight) { [weak self] in
        self?.chooseWeekdaysPreset()
      }
      preset.fillRow(
        symbol: "briefcase",
        tint: SeptaskKitTheme.inkSecondary,
        title: String(localized: "Weekdays (Mon to Fri)", comment: "Repeat quick preset")
      )
      weekdaysPresetCell = preset
      views.append(preset)
    }

    cadenceDescription.font = .systemFont(ofSize: SeptenaTypeScale.size(.footnote))
    cadenceDescription.textColor = SeptaskKitTheme.inkSecondary
    cadenceDescription.lineBreakMode = .byWordWrapping
    cadenceDescription.maximumNumberOfLines = 4
    views.append(cadenceDescription)

    views.append(KitSurface.separator())
    views.append(contentsOf: buildAnchorCells())

    if canPickFixedSchedule {
      let toggle = KitDateCell(radius: 8, height: Self.rowHeight) { [weak self] in
        self?.toggleCustomOptions()
      }
      toggle.fillRow(
        symbol: customExpanded ? "chevron.down" : "chevron.right",
        tint: SeptaskKitTheme.inkSecondary,
        title: String(localized: "Custom options…", comment: "Repeat progressive disclosure toggle")
      )
      customToggleCell = toggle
      views.append(toggle)

      buildCustomContainer()
      views.append(customContainer)
    }

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

      let stop = KitDateCell(radius: 8, height: Self.rowHeight) { [weak self] in
        self?.stopRepeating()
      }
      stop.fillRow(symbol: "xmark.circle", tint: SeptaskKitTheme.iconMuted,
                   title: String(localized: "Don’t Repeat", comment: "Repeat editor stop"))
      stopCell = stop
      views.append(stop)
    }

    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.detachesHiddenViews = true
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
    updateValues()
  }

  private func buildCustomContainer() {
    customContainer.orientation = .vertical
    customContainer.alignment = .leading
    customContainer.spacing = 8
    customContainer.detachesHiddenViews = true

    // Weekly: 7 compact weekday pills (Mon..Sun).
    weekdaySection.orientation = .vertical
    weekdaySection.alignment = .leading
    weekdaySection.spacing = 6

    let pillStrip = NSStackView()
    pillStrip.orientation = .horizontal
    pillStrip.spacing = 4
    pillStrip.distribution = .fillEqually
    for option in Self.weekdayOptions {
      let cell = KitDateCell(radius: 8, height: Self.pillHeight) { [weak self] in
        self?.toggleWeekday(option.weekday)
      }
      cell.fillTitle(option.short)
      cell.setAccessibilityTitle(option.full)
      pillStrip.addArrangedSubview(cell)
      weekdayCells.append((option.weekday, cell))
    }
    weekdaySection.addArrangedSubview(pillStrip)
    pillStrip.widthAnchor.constraint(equalTo: weekdaySection.widthAnchor).isActive = true

    // Monthly / Yearly: Same day | On day | Ordinal
    monthlySection.orientation = .vertical
    monthlySection.alignment = .leading
    monthlySection.spacing = 8
    monthlySection.detachesHiddenViews = true

    let modeStrip = NSStackView()
    modeStrip.orientation = .horizontal
    modeStrip.spacing = Self.unitSpacing
    modeStrip.distribution = .fillEqually
    let modes: [(MonthlyMode, String)] = [
      (.anchor, String(localized: "Same day", comment: "Monthly repeat mode")),
      (.dayOfMonth, String(localized: "On day", comment: "Monthly repeat mode")),
      (.ordinal, String(localized: "Ordinal", comment: "Monthly repeat mode")),
    ]
    for (mode, title) in modes {
      let cell = KitDateCell(radius: 8, height: Self.pillHeight) { [weak self] in
        self?.chooseMonthlyMode(mode)
      }
      cell.fillTitle(title)
      modeStrip.addArrangedSubview(cell)
      monthlyModeCells.append((mode, cell))
    }
    monthlySection.addArrangedSubview(modeStrip)
    modeStrip.widthAnchor.constraint(equalTo: monthlySection.widthAnchor).isActive = true

    // Day-of-month selector (1..31 or Last day)
    let dayLabel = NSTextField(labelWithString: String(localized: "Day", comment: "Monthly day label"))
    dayLabel.font = .systemFont(ofSize: SeptenaTypeScale.size(.footnote))
    dayLabel.textColor = SeptaskKitTheme.inkSecondary
    dayLabel.setContentHuggingPriority(.required, for: .horizontal)

    monthDayPopUp.controlSize = .small
    monthDayPopUp.font = .systemFont(ofSize: SeptenaTypeScale.size(.footnote))
    for d in 1...31 {
      monthDayPopUp.addItem(withTitle: "\(d)")
      monthDayPopUp.lastItem?.tag = d
    }
    monthDayPopUp.addItem(withTitle: String(localized: "Last day", comment: "Monthly last day option"))
    monthDayPopUp.lastItem?.tag = -1
    monthDayPopUp.target = self
    monthDayPopUp.action = #selector(monthDayChanged)

    let daySpacer = NSView()
    daySpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    monthDayRow.orientation = .horizontal
    monthDayRow.alignment = .centerY
    monthDayRow.spacing = 8
    monthDayRow.addArrangedSubview(dayLabel)
    monthDayRow.addArrangedSubview(monthDayPopUp)
    monthDayRow.addArrangedSubview(daySpacer)
    monthlySection.addArrangedSubview(monthDayRow)
    monthDayRow.widthAnchor.constraint(equalTo: monthlySection.widthAnchor).isActive = true

    // Ordinal weekday selector (1st..4th / Last + Sunday..Saturday)
    let ordLabel = NSTextField(labelWithString: String(localized: "On the", comment: "Ordinal repeat prefix"))
    ordLabel.font = .systemFont(ofSize: SeptenaTypeScale.size(.footnote))
    ordLabel.textColor = SeptaskKitTheme.inkSecondary
    ordLabel.setContentHuggingPriority(.required, for: .horizontal)

    ordinalPopUp.controlSize = .small
    ordinalPopUp.font = .systemFont(ofSize: SeptenaTypeScale.size(.footnote))
    for item in Self.ordinalOptions {
      ordinalPopUp.addItem(withTitle: item.title)
      ordinalPopUp.lastItem?.tag = item.value
    }
    ordinalPopUp.target = self
    ordinalPopUp.action = #selector(ordinalChanged)

    ordinalWeekdayPopUp.controlSize = .small
    ordinalWeekdayPopUp.font = .systemFont(ofSize: SeptenaTypeScale.size(.footnote))
    for item in Self.fullWeekdayOptions {
      ordinalWeekdayPopUp.addItem(withTitle: item.title)
      ordinalWeekdayPopUp.lastItem?.tag = item.value
    }
    ordinalWeekdayPopUp.target = self
    ordinalWeekdayPopUp.action = #selector(ordinalChanged)

    let ordSpacer = NSView()
    ordSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    ordinalRow.orientation = .horizontal
    ordinalRow.alignment = .centerY
    ordinalRow.spacing = 6
    ordinalRow.addArrangedSubview(ordLabel)
    ordinalRow.addArrangedSubview(ordinalPopUp)
    ordinalRow.addArrangedSubview(ordinalWeekdayPopUp)
    ordinalRow.addArrangedSubview(ordSpacer)
    monthlySection.addArrangedSubview(ordinalRow)
    ordinalRow.widthAnchor.constraint(equalTo: monthlySection.widthAnchor).isActive = true

    customContainer.addArrangedSubview(weekdaySection)
    customContainer.addArrangedSubview(monthlySection)
    weekdaySection.widthAnchor.constraint(equalTo: customContainer.widthAnchor).isActive = true
    monthlySection.widthAnchor.constraint(equalTo: customContainer.widthAnchor).isActive = true
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

  /// day / week / month / year as four choice cells — the repeat board's
  /// answer to the date board's day strip, in the same cell, wash, and walk.
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
        : String(localized: "On the scheduled date (set a When date first)",
                 comment: "Repeat anchor mode, unavailable"),
      titleColor: offerable ? SeptaskKitTheme.inkPrimary : SeptaskKitTheme.iconMuted)

    anchorCells = [completion, scheduled]
    return anchorCells
  }

  private func rebuildWalkableCells() {
    var walkable: [KitDateCell] = []
    walkable.append(contentsOf: unitCells)
    if let preset = weekdaysPresetCell { walkable.append(preset) }
    walkable.append(anchorCells[0])
    if canPickFixedSchedule { walkable.append(anchorCells[1]) }
    if let toggle = customToggleCell, !toggle.isHidden {
      walkable.append(toggle)
      if !customContainer.isHidden {
        if !weekdaySection.isHidden {
          walkable.append(contentsOf: weekdayCells.map(\.cell))
        }
        if !monthlySection.isHidden {
          walkable.append(contentsOf: monthlyModeCells.map(\.cell))
        }
      }
    }
    if let pause = pauseCell { walkable.append(pause) }
    if let stop = stopCell { walkable.append(stop) }
    cells = walkable
    for cell in cells {
      cell.onHover = { [weak self] hovered in self?.focus(cell: hovered) }
    }
    if !cells.isEmpty {
      focusIndex = min(cells.count - 1, max(0, focusIndex))
    } else {
      focusIndex = 0
    }
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
      ? RegistryActions.title(.taskPauseResumeRepeat, .active)
      : RegistryActions.title(.taskPauseResumeRepeat)
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
    let isWeekdaysPreset = unit == .week
      && (interval ?? selection.interval) == 1
      && afterCompletion == false
      && weekdays == Set([2, 3, 4, 5, 6])
    weekdaysPresetCell?.isCurrentValue = isWeekdaysPreset
    anchorCells[0].isCurrentValue = afterCompletion == true
    anchorCells[1].isCurrentValue = afterCompletion == false

    let showCustom = supportsCustomOptions
    customToggleCell?.isHidden = !showCustom
    customToggleCell?.updateRow(
      symbol: customExpanded ? "chevron.down" : "chevron.right",
      title: customExpanded
        ? String(localized: "Hide custom options", comment: "Repeat progressive disclosure collapse")
        : String(localized: "Custom options…", comment: "Repeat progressive disclosure expand")
    )
    customContainer.isHidden = !showCustom || !customExpanded
    weekdaySection.isHidden = unit != .week
    monthlySection.isHidden = !(unit == .month || unit == .year)

    for (day, cell) in weekdayCells {
      cell.isCurrentValue = weekdays.contains(day)
    }
    for (mode, cell) in monthlyModeCells {
      cell.isCurrentValue = monthlyMode == mode
    }
    monthDayRow.isHidden = monthlyMode != .dayOfMonth
    ordinalRow.isHidden = monthlyMode != .ordinal
    monthDayPopUp.selectItem(withTag: monthDay)
    ordinalPopUp.selectItem(withTag: ordinal)
    ordinalWeekdayPopUp.selectItem(withTag: ordinalWeekdayNum)

    rebuildWalkableCells()
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
        localized: "\(rows) tasks with different repeat settings. Only the settings you change will be updated.",
        comment: "Repeat editor summary, mixed selection")
      return
    }
    let candidate = Recurrence(
      unit: unit,
      interval: count,
      afterCompletion: afterCompletion,
      weekdays: resolvedWeekdays,
      monthDay: resolvedMonthDay,
      ordinalWeekday: resolvedOrdinalWeekday
    )
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
    case .year:
      unitName = count == 1
        ? String(localized: "year", comment: "Repeat cadence unit")
        : String(localized: "years", comment: "Repeat cadence unit, plural")
    }
    let sentence: String
    if !afterCompletion && (candidate.weekdays != nil || candidate.monthDay != nil || candidate.ordinalWeekday != nil) {
      sentence = String(localized: "Repeats: \(candidate.shortLabel).",
                        comment: "Repeat editor summary, custom fixed schedule")
    } else {
      sentence = afterCompletion
        ? String(localized: "A new copy appears \(count) \(unitName) after this one is checked off.",
                 comment: "Repeat editor summary, after completion")
        : String(localized: "A new copy appears \(count) \(unitName) after the scheduled date.",
                 comment: "Repeat editor summary, fixed schedule")
    }
    var parts = [sentence]
    if let nextWire = candidate.nextDate(completedOn: DayClock.appToday,
                                         scheduled: selection.sampleScheduled),
       let nextDate = KitDayFormat.date(fromWire: nextWire) {
      let formatted = Self.nextPreviewFormatter.string(from: nextDate)
      parts.append(String(localized: "Next: \(formatted).",
                          comment: "Repeat editor live next occurrence preview"))
    }
    if rows > 1 {
      parts.append(String(localized: "Applies to \(rows) tasks.",
                          comment: "Repeat editor multi-selection footnote"))
    }
    cadenceDescription.stringValue = parts.joined(separator: " ")
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

  private func chooseWeekdaysPreset() {
    didEdit = true
    didEditScheduleDetail = true
    unit = .week
    intervalField.integerValue = 1
    intervalStepper.integerValue = 1
    afterCompletion = false
    weekdays = Set([2, 3, 4, 5, 6])
    monthlyMode = .anchor
    updateValues()
  }

  private func toggleCustomOptions() {
    customExpanded.toggle()
    updateValues()
  }

  private func toggleWeekday(_ day: Int) {
    didEdit = true
    didEditScheduleDetail = true
    if weekdays.contains(day) {
      weekdays.remove(day)
    } else {
      weekdays.insert(day)
    }
    updateValues()
  }

  private func chooseMonthlyMode(_ mode: MonthlyMode) {
    didEdit = true
    didEditScheduleDetail = true
    monthlyMode = mode
    updateValues()
  }

  @objc private func monthDayChanged() {
    didEdit = true
    didEditScheduleDetail = true
    monthDay = monthDayPopUp.selectedTag()
    updateDescription()
  }

  @objc private func ordinalChanged() {
    didEdit = true
    didEditScheduleDetail = true
    ordinal = ordinalPopUp.selectedTag()
    ordinalWeekdayNum = ordinalWeekdayPopUp.selectedTag()
    updateDescription()
  }

  @objc private func intervalChanged() {
    didEdit = true
    // Clearing the field is how a mixed selection stays mixed on this axis.
    if let value = interval {
      intervalStepper.integerValue = value
      intervalField.integerValue = value
    }
    weekdaysPresetCell?.isCurrentValue = unit == .week
      && (interval ?? selection.interval) == 1
      && afterCompletion == false
      && weekdays == Set([2, 3, 4, 5, 6])
    updateDescription()
  }

  @objc private func stepperChanged() {
    didEdit = true
    intervalField.integerValue = intervalStepper.integerValue
    weekdaysPresetCell?.isCurrentValue = unit == .week
      && (interval ?? selection.interval) == 1
      && afterCompletion == false
      && weekdays == Set([2, 3, 4, 5, 6])
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

// MARK: - Reminder editor (TR2)

/// Progressive-disclosure Reminder popover — the fourth TIER 1 anchored
/// popover in the date-board family (`When`, `Deadline`, `Repeat`, `Reminder`).
@MainActor
enum SeptaskKitReminderPopover {
  static func present(initial: TaskReminder?,
                      anyHasReminder: Bool? = nil,
                      relativeTo rect: NSRect,
                      of view: NSView,
                      onCommit: @escaping (TaskReminder?) -> Void) {
    let board = KitReminderBoard(initial: initial,
                                 anyHasReminder: anyHasReminder ?? (initial != nil))
    let handle = KitPopoverHandle()
    board.onCommit = { reminder in
      onCommit(reminder)
      handle.close()
    }
    board.onCancel = { handle.close() }
    KitPopover.present(board, relativeTo: rect, of: view, focus: board, handle: handle)
  }
}

@MainActor
private final class KitReminderBoard: NSView {

  var onCommit: ((TaskReminder?) -> Void)?
  var onCancel: (() -> Void)?

  private let initial: TaskReminder?
  private let anyHasReminder: Bool
  private var mode: TaskReminderMode
  private var optionsExpanded: Bool

  private let datePicker = NSDatePicker()
  private var optionsToggleCell: KitDateCell?
  private var modeToggleCell: KitDateCell?
  private var deniedNoticeCell: KitDateCell?
  private var setCell: KitDateCell?
  private var clearCell: KitDateCell?
  private var presetCells: [KitDateCell] = []

  private var cells: [KitDateCell] = []
  private var focusIndex = 0

  private static let width: CGFloat = 360
  private static let padding: CGFloat = 8
  private static let rowHeight: CGFloat = 32

  init(initial: TaskReminder?, anyHasReminder: Bool) {
    self.initial = initial
    self.anyHasReminder = anyHasReminder
    self.mode = initial?.mode ?? .floating
    self.optionsExpanded = (initial?.mode == .fixed)
    super.init(frame: .zero)
    build()
    checkNotificationAuth()
  }

  required init?(coder: NSCoder) { fatalError("KitReminderBoard is code-only") }

  override var acceptsFirstResponder: Bool { true }
  override func becomeFirstResponder() -> Bool { true }

  private func build() {
    var views: [NSView] = []

    // Non-blocking denied-permission notice (hidden unless OS auth == .denied).
    let denied = KitDateCell(radius: 8, height: Self.rowHeight) {
      TaskReminderScheduler.openNotificationSettings()
    }
    denied.fillRow(
      symbol: "bell.slash",
      tint: SeptaskKitTheme.overdueRed,
      title: String(localized: "Notifications are off. Open Settings",
                    comment: "Reminder denied permission notice"),
      titleColor: SeptaskKitTheme.overdueRed
    )
    denied.isHidden = true
    deniedNoticeCell = denied
    views.append(denied)

    // Quick presets — one click sets & closes.
    for preset in TaskReminder.quickPresets() {
      let cell = KitDateCell(radius: 8, height: Self.rowHeight) { [weak self] in
        guard let self else { return }
        self.commit(TaskReminder.make(date: preset.date, mode: self.mode))
      }
      cell.fillRow(symbol: "bell", tint: SeptaskKitTheme.inkSecondary, title: preset.title)
      presetCells.append(cell)
      views.append(cell)
    }

    views.append(KitSurface.separator())

    // Custom date & time picker row
    let customLabel = NSTextField(labelWithString: String(localized: "Custom",
                                                          comment: "Custom reminder time label"))
    customLabel.font = .systemFont(ofSize: SeptenaTypeScale.size(.footnote))
    customLabel.textColor = SeptaskKitTheme.inkSecondary
    customLabel.setContentHuggingPriority(.required, for: .horizontal)

    datePicker.datePickerStyle = .textFieldAndStepper
    datePicker.datePickerElements = [.yearMonthDay, .hourMinute]
    datePicker.font = .systemFont(ofSize: SeptenaTypeScale.size(.body))
    datePicker.dateValue = initial?.effectiveFireDate()
      ?? TaskReminder.quickPresets().first?.date
      ?? DayClock.appNow.addingTimeInterval(3600)

    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let customRow = NSStackView(views: [customLabel, datePicker, spacer])
    customRow.orientation = .horizontal
    customRow.alignment = .centerY
    customRow.spacing = 8
    customRow.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
    views.append(customRow)

    let setButton = KitDateCell(radius: 8, height: Self.rowHeight) { [weak self] in
      guard let self else { return }
      self.window?.endEditing(for: nil)
      self.commit(TaskReminder.make(date: self.datePicker.dateValue, mode: self.mode))
    }
    setButton.fillRow(
      symbol: "checkmark.circle",
      tint: SeptaskKitTheme.inkPrimary,
      title: String(localized: "Set Custom Reminder", comment: "Commit custom reminder date/time")
    )
    setCell = setButton
    views.append(setButton)

    // Progressive-disclosure timezone mode option (floating default, fixed opt-in).
    let toggle = KitDateCell(radius: 8, height: Self.rowHeight) { [weak self] in
      self?.toggleOptions()
    }
    toggle.fillRow(
      symbol: optionsExpanded ? "chevron.down" : "chevron.right",
      tint: SeptaskKitTheme.inkSecondary,
      title: String(localized: "Time zone options…", comment: "Reminder options disclosure")
    )
    optionsToggleCell = toggle
    views.append(toggle)

    let modeCell = KitDateCell(radius: 8, height: Self.rowHeight) { [weak self] in
      self?.toggleMode()
    }
    modeCell.fillRow(
      symbol: "globe",
      tint: SeptaskKitTheme.inkSecondary,
      title: modeTitle
    )
    modeCell.isHidden = !optionsExpanded
    modeToggleCell = modeCell
    views.append(modeCell)

    if anyHasReminder {
      views.append(KitSurface.separator())
      let clear = KitDateCell(radius: 8, height: Self.rowHeight) { [weak self] in
        self?.commit(nil)
      }
      clear.fillRow(
        symbol: "xmark.circle",
        tint: SeptaskKitTheme.iconMuted,
        title: String(localized: "Clear Reminder", comment: "Remove task reminder")
      )
      clearCell = clear
      views.append(clear)
    }

    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.detachesHiddenViews = true
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

    updateUI()
  }

  private var modeTitle: String {
    mode == .fixed
      ? String(localized: "Fixed time zone (fires at exact instant)", comment: "Reminder fixed timezone mode")
      : String(localized: "Floating local time (follows device time zone)", comment: "Reminder floating timezone mode")
  }

  private func checkNotificationAuth() {
    Task { @MainActor [weak self] in
      let status = await TaskReminderScheduler.shared.authorizationStatus()
      guard let self else { return }
      self.deniedNoticeCell?.isHidden = (status != .denied)
      self.rebuildWalkableCells()
      self.applyFocus()
    }
  }

  private func toggleOptions() {
    optionsExpanded.toggle()
    updateUI()
  }

  private func toggleMode() {
    mode = (mode == .floating) ? .fixed : .floating
    updateUI()
  }

  private func updateUI() {
    optionsToggleCell?.updateRow(
      symbol: optionsExpanded ? "chevron.down" : "chevron.right",
      title: optionsExpanded
        ? String(localized: "Hide time zone options", comment: "Reminder options collapse")
        : String(localized: "Time zone options…", comment: "Reminder options expand")
    )
    modeToggleCell?.isHidden = !optionsExpanded
    modeToggleCell?.updateRow(symbol: "globe", title: modeTitle)
    modeToggleCell?.isCurrentValue = (mode == .fixed)
    rebuildWalkableCells()
    applyFocus()
  }

  private func rebuildWalkableCells() {
    var walkable: [KitDateCell] = []
    if let denied = deniedNoticeCell, !denied.isHidden { walkable.append(denied) }
    walkable.append(contentsOf: presetCells)
    if let setCell { walkable.append(setCell) }
    if let toggle = optionsToggleCell { walkable.append(toggle) }
    if let modeCell = modeToggleCell, !modeCell.isHidden { walkable.append(modeCell) }
    if let clearCell { walkable.append(clearCell) }
    cells = walkable
    for cell in cells {
      cell.onHover = { [weak self] hovered in self?.focus(cell: hovered) }
    }
    if !cells.isEmpty {
      focusIndex = min(cells.count - 1, max(0, focusIndex))
    } else {
      focusIndex = 0
    }
  }

  private func commit(_ reminder: TaskReminder?) {
    if reminder != nil {
      Task { await TaskReminderScheduler.shared.requestAuthorizationIfNeeded() }
    }
    onCommit?(reminder)
  }

  private func focus(cell: KitDateCell) {
    guard let index = cells.firstIndex(where: { $0 === cell }) else { return }
    focusIndex = index
    applyFocus()
  }

  private func step(_ delta: Int) {
    guard !cells.isEmpty else { return }
    focusIndex = min(cells.count - 1, max(0, focusIndex + delta))
    applyFocus()
  }

  private func applyFocus() {
    for (index, cell) in cells.enumerated() { cell.isFocused = index == focusIndex }
  }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 126, 123: step(-1)
    case 125, 124: step(1)
    case 36, 76:
      guard cells.indices.contains(focusIndex) else { return }
      cells[focusIndex].activate()
    default: super.keyDown(with: event)
    }
  }

  override func cancelOperation(_ sender: Any?) {
    onCancel?()
  }
}

// MARK: - Board

/// The popover's body: a seven-day strip starting today and the registry's
/// date board rows — plus the key handling that walks them.
///
/// Navigation is LINEAR, not grid-shaped: each day in order, then each row
/// in order. ↓ and → both step forward in time, ↑ and ← both step back, so
/// "down" always means "later" no matter which part of the board holds focus.
/// A ragged (row, column) model made ↓ jump from a day to Clear, which reads
/// as a different axis than the one the user is walking.
@MainActor
private final class KitDateBoard: NSView {

  private let kind: SeptaskKitDatePopover.Kind
  private let onPick: (Date?, Bool) -> Void
  private let onCancel: () -> Void
  private let onTimeSlotChange: ((String?, Int?) -> Void)?
  /// When only: the Repeat row (docs/TASK_ROW_MENU_SPEC.md). Both nil hides it.
  private let repeatTitle: String?
  private let onRepeat: (() -> Void)?
  private var startTime: String?
  private var durationMinutes: Int?
  private var timeCell: KitDateCell?
  private let timeControlsContainer = NSStackView()
  private let startTimePicker = NSDatePicker()
  private var durationPills: [(minutes: Int, pill: KitPillButton)] = []

  /// Every focusable cell in order: the seven days, then the visible rows.
  private var cells: [KitDateCell] = []
  private var dayCells: [KitDateCell] = []
  private var rowCells: [KitDateCell] = []
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
  /// The task's current value for this attribute, if any.
  private var initialDate: Date?
  /// Typed date entry on the week page: printable keys collect here, Return
  /// parses and applies (`SeptenaDateParser`), Esc clears, ⌫ deletes. Arrows keep
  /// walking the strip.
  private var typed = ""
  private let typedLabel = NSTextField(labelWithString: "")

  /// Panel padding. The highlight is INSET from the popover edge (the
  /// palette shape in `SelectionLanguage`, not the full-bleed list-row one),
  /// so a selected row never collides with the popover's rounded corners.
  private static let padding: CGFloat = 8
  private static let rowHeight: CGFloat = 32
  /// Rows are one list: the gap only keeps two highlights from touching.
  private static let rowSpacing: CGFloat = 2
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
       initialStartTime: String? = nil,
       initialDurationMinutes: Int? = nil,
       onTimeSlotChange: ((String?, Int?) -> Void)? = nil,
       repeatTitle: String? = nil,
       onRepeat: (() -> Void)? = nil,
       onPick: @escaping (Date?, Bool) -> Void, onCancel: @escaping () -> Void) {
    self.kind = kind
    self.repeatTitle = repeatTitle
    self.onRepeat = onRepeat
    self.startTime = initialStartTime
    self.durationMinutes = initialDurationMinutes
    self.onTimeSlotChange = onTimeSlotChange
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
    initialDate = initial

    let strip = NSStackView()
    strip.orientation = .horizontal
    strip.spacing = Self.daySpacing
    strip.distribution = .fillEqually
    for offset in Self.dayOffsets {
      let date = KitDayFormat.day(offset: offset) ?? today
      let cell = KitDateCell(radius: 10, height: Self.dayHeight) { [weak self] in
        self?.pick(date)
      }
      cell.fillDay(date, isToday: offset == 0)
      // The task's current value wears the neutral current-value ground.
      if let initial, Calendar.current.isDate(date, inSameDayAs: initial) {
        cell.isCurrentValue = true
      }
      cell.widthAnchor.constraint(equalToConstant: Self.dayWidth).isActive = true
      strip.addArrangedSubview(cell)
      dayCells.append(cell)
    }

    // A current value past the strip is named on the calendar row, so the
    // popover always shows what the task has now.
    let beyondStrip = initial.map { value in
      !Self.dayOffsets.contains { offset in
        KitDayFormat.day(offset: offset).map {
          Calendar.current.isDate($0, inSameDayAs: value)
        } ?? false
      }
    } ?? false

    typedLabel.font = SeptaskKitTheme.meta
    typedLabel.textColor = SeptaskKitTheme.iconMuted
    typedLabel.lineBreakMode = .byTruncatingTail
    updateTypedLabel()

    let separator = NSBox()
    separator.boxType = .separator

    let stack = NSStackView(views: [typedLabel, strip, separator])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = Self.rowSpacing
    stack.detachesHiddenViews = true
    stack.setCustomSpacing(8, after: typedLabel)
    stack.setCustomSpacing(8, after: strip)
    stack.setCustomSpacing(4, after: separator)

    var calendarCell: KitDateCell?
    for row in RegistrySurfaces.dateBoardRows(for: kind, on: RegistryPlatform.current) {
      var title = row.label(for: kind)
      let action: () -> Void
      switch row.kind {
      case .tomorrow:
        action = { [weak self] in
          guard let tomorrow = KitDayFormat.day(offset: 1) else { return }
          self?.pick(tomorrow)
        }
      case .calendar:
        if beyondStrip, let initial {
          title = RegistrySurfaces.dateBoardCalendarLabel(
            date: Self.setFormatter.string(from: initial))
        }
        action = { [weak self] in self?.showCalendar() }
      case .clear:
        action = { [weak self] in self?.onPick(nil, false) }
      case .repeatRule:
        guard let repeatTitle, let onRepeat else { continue }
        title = repeatTitle
        action = onRepeat
      case .time:
        guard onTimeSlotChange != nil else { continue }
        action = { [weak self] in self?.revealTimeControls() }
      }
      let cell = KitDateCell(radius: 8, height: Self.rowHeight, action: action)
      cell.fillRow(symbol: row.sfSymbol, tint: SeptaskKitTheme.inkSecondary, title: title)
      // A constant, not the strip's anchor: the stack detaches a hidden row
      // (Add time), and a constraint across views would not survive that.
      cell.widthAnchor.constraint(equalToConstant: Self.boardWidth).isActive = true
      stack.addArrangedSubview(cell)
      rowCells.append(cell)
      if row.kind == .calendar {
        cell.isCurrentValue = beyondStrip
        calendarCell = cell
      } else if row.kind == .time {
        timeCell = cell
      }
    }

    // Progressive-disclosure optional start/end time section (`.when` only,
    // docs/TASK_TIMES_AND_ICAL_SPEC.md §2).
    if let timeCell {
      timeControlsContainer.orientation = .vertical
      timeControlsContainer.alignment = .leading
      timeControlsContainer.spacing = 6
      // The same inset as a row, so the controls sit in the rows' column.
      timeControlsContainer.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 4, right: 10)
      timeControlsContainer.translatesAutoresizingMaskIntoConstraints = false

      let topRow = NSStackView()
      topRow.orientation = .horizontal
      topRow.alignment = .centerY
      topRow.spacing = 8

      let lbl = NSTextField(labelWithString: String(localized: "Time", comment: "SeptaskKit: start time label"))
      lbl.font = .systemFont(ofSize: SeptenaTypeScale.size(.footnote), weight: .medium)
      lbl.textColor = .labelColor

      startTimePicker.datePickerStyle = .textFieldAndStepper
      startTimePicker.datePickerElements = .hourMinute
      startTimePicker.dateValue = TaskTimeSlot.pickerDate(from: startTime)
      startTimePicker.target = self
      startTimePicker.action = #selector(startTimeChanged)

      let clearTimeBtn = NSButton()
      clearTimeBtn.isBordered = false
      clearTimeBtn.bezelStyle = .inline
      clearTimeBtn.title = String(localized: "Clear", comment: "SeptaskKit: clear start time")
      clearTimeBtn.font = .systemFont(ofSize: SeptenaTypeScale.size(.caption1))
      clearTimeBtn.contentTintColor = SeptaskKitTheme.inkSecondary
      clearTimeBtn.target = self
      clearTimeBtn.action = #selector(clearTimePressed)

      topRow.addArrangedSubview(lbl)
      topRow.addArrangedSubview(startTimePicker)
      topRow.addArrangedSubview(clearTimeBtn)

      let durRow = NSStackView()
      durRow.orientation = .horizontal
      durRow.alignment = .centerY
      durRow.spacing = 6
      durationPills = []
      for preset in TaskTimeSlot.quickDurations {
        let pill = KitPillButton()
        pill.title = preset.label
        pill.isOn = durationMinutes == preset.minutes
        pill.onPress = { [weak self] _ in self?.toggleDuration(preset.minutes) }
        durRow.addArrangedSubview(pill)
        durationPills.append((preset.minutes, pill))
      }

      timeControlsContainer.addArrangedSubview(topRow)
      timeControlsContainer.addArrangedSubview(durRow)
      stack.addArrangedSubview(timeControlsContainer)
      timeControlsContainer.widthAnchor.constraint(equalTo: strip.widthAnchor).isActive = true

      let hasTime = startTime != nil
      timeCell.isHidden = hasTime
      timeControlsContainer.isHidden = !hasTime
    }

    // The strip sets the width; everything else matches it.
    for view in [typedLabel, separator] as [NSView] {
      view.widthAnchor.constraint(equalTo: strip.widthAnchor).isActive = true
    }

    refreshCells()
    for cell in dayCells + rowCells {
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
    } else if beyondStrip, let calendarCell, let index = cells.firstIndex(where: { $0 === calendarCell }) {
      // Past the strip: start on "Pick another date", which opens on it.
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
    // The focused day; else the task's own value (it may be months out);
    // else today.
    calendarDate = currentFocusDate() ?? initialDate ?? KitDayFormat.todayDate() ?? Date()
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

  private func revealTimeControls() {
    if startTime == nil {
      startTime = "09:00"
      startTimePicker.dateValue = TaskTimeSlot.pickerDate(from: startTime)
      onTimeSlotChange?(startTime, durationMinutes)
    }
    timeCell?.isHidden = true
    timeControlsContainer.isHidden = false
    refreshCells()
  }

  @objc private func startTimeChanged() {
    startTime = TaskTimeSlot.hhmm(from: startTimePicker.dateValue)
    onTimeSlotChange?(startTime, durationMinutes)
  }

  private func toggleDuration(_ minutes: Int) {
    if startTime == nil {
      startTime = TaskTimeSlot.hhmm(from: startTimePicker.dateValue)
    }
    durationMinutes = durationMinutes == minutes ? nil : minutes
    for entry in durationPills { entry.pill.isOn = entry.minutes == durationMinutes }
    onTimeSlotChange?(startTime, durationMinutes)
  }

  @objc private func clearTimePressed() {
    startTime = nil
    durationMinutes = nil
    for entry in durationPills { entry.pill.isOn = false }
    timeControlsContainer.isHidden = true
    timeCell?.isHidden = false
    refreshCells()
    onTimeSlotChange?(nil, nil)
  }

  // MARK: Focus

  /// The Add time row leaves the walk while its controls show.
  private func refreshCells() {
    rowCells.forEach { $0.isFocused = false }
    cells = dayCells + rowCells.filter { !$0.isHidden }
    focusIndex = min(focusIndex, cells.count - 1)
    applyFocus()
  }

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
    if !showingCalendar, handleTyping(event) { return }
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
  /// one key never skips a level — and clears a typed date before that.
  override func cancelOperation(_ sender: Any?) {
    if showingCalendar {
      showBoard()
    } else if !typed.isEmpty {
      typed = ""
      updateTypedLabel()
    } else {
      onCancel()
    }
  }

  // MARK: Typed entry

  /// Week page only. Returns true when the key belonged to the typed date.
  /// Arrows never do; Space and Return only while something is typed.
  private func handleTyping(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.isDisjoint(with: [.command, .control, .option]) else { return false }
    switch event.keyCode {
    case 51, 117:                                // ⌫ / ⌦
      guard !typed.isEmpty else { return false }
      typed.removeLast()
      updateTypedLabel()
      return true
    case 36, 76:                                 // Return / Enter
      guard !typed.isEmpty else { return false }
      if let date = typedDate {
        pick(date)
      } else {
        NSSound.beep()
      }
      return true
    case 53:                                     // Escape
      guard !typed.isEmpty else { return false }
      typed = ""
      updateTypedLabel()
      return true
    case 49:                                     // Space
      guard !typed.isEmpty else { return false }
      typed.append(" ")
      updateTypedLabel()
      return true
    case 123, 124, 125, 126, 48:                 // arrows, Tab
      return false
    default:
      guard let characters = event.characters, !characters.isEmpty,
            characters.unicodeScalars.allSatisfy({ scalar in
              CharacterSet.alphanumerics.contains(scalar) || "+-/.,".unicodeScalars.contains(scalar)
            })
      else { return false }
      typed.append(characters)
      updateTypedLabel()
      return true
    }
  }

  private var typedDate: Date? {
    guard let today = KitDayFormat.todayDate() else { return nil }
    return SeptenaDateParser.parse(typed, today: today)
  }

  /// The line above the strip: a hint while nothing is typed, then the typed
  /// text and the date it means.
  private func updateTypedLabel() {
    if typed.isEmpty {
      typedLabel.textColor = SeptaskKitTheme.iconMuted
      typedLabel.stringValue = String(localized: "Type a date: tomorrow, fri, +3, dec 4",
                                      comment: "SeptaskKit: date popover typed-entry hint")
      return
    }
    typedLabel.textColor = SeptaskKitTheme.inkPrimary
    let meaning = typedDate.map { Self.setFormatter.string(from: $0) }
      ?? String(localized: "Not a date", comment: "SeptaskKit: date popover typed-entry no match")
    typedLabel.stringValue = "\(typed)  →  \(meaning)"
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
    // One icon column: symbols differ in width, and titles must line up.
    image.widthAnchor.constraint(equalToConstant: SeptenaTypeScale.size(.body) + 6).isActive = true

    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: SeptenaTypeScale.size(.body))
    label.textColor = titleColor
    label.lineBreakMode = .byTruncatingTail

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

// MARK: - Tag popover (⇧⌘T, docs/TAGS_SPEC.md §4)

/// Lightweight AppKit type-to-filter/assign/create tag popover anchored to a
/// task row, composer pill, or inspector button. Supports single & multi-select
/// with shared `TaskUndo`, plus a "Manage Tags…" modal sheet.
@MainActor
enum SeptaskKitTagPopover {
  static func present(taskIDs: [String],
                      relativeTo rect: NSRect,
                      of positioningView: NSView,
                      onChanged: @escaping () -> Void) {
    guard !taskIDs.isEmpty else { return }
    let handle = KitPopoverHandle()
    let board = KitTagBoard(taskIDs: taskIDs,
                            hostWindow: positioningView.window,
                            onChanged: onChanged,
                            onClose: { handle.close() })
    KitPopover.present(board, relativeTo: rect, of: positioningView,
                       focus: board.searchField, handle: handle)
  }
}

@MainActor
private final class KitTagBoard: NSView, NSTextFieldDelegate {
  private let taskIDs: [String]
  private weak var hostWindow: NSWindow?
  private let onChanged: () -> Void
  private let onClose: () -> Void

  let searchField = NSTextField()
  private let listStack = NSStackView()
  private let emptyLabel = NSTextField(labelWithString: "")
  private let manageButton = NSButton()
  private var allTags: [TaskTag] = []

  private var context: ModelContext { LocalStore.shared.container.mainContext }
  private var mutator: TaskMutator { SeptenaServices.shared.taskMutator }

  init(taskIDs: [String],
       hostWindow: NSWindow?,
       onChanged: @escaping () -> Void,
       onClose: @escaping () -> Void) {
    self.taskIDs = taskIDs
    self.hostWindow = hostWindow
    self.onChanged = onChanged
    self.onClose = onClose
    super.init(frame: NSRect(x: 0, y: 0, width: 256, height: 268))
    translatesAutoresizingMaskIntoConstraints = false

    searchField.placeholderString = String(localized: "Filter or create tag…",
                                           comment: "SeptaskKit: tag popover search/create field")
    searchField.font = .systemFont(ofSize: SeptenaTypeScale.size(.callout))
    searchField.isBordered = true
    searchField.bezelStyle = .roundedBezel
    searchField.delegate = self
    searchField.translatesAutoresizingMaskIntoConstraints = false

    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.translatesAutoresizingMaskIntoConstraints = false

    let doc = KitTagFlippedView()
    doc.translatesAutoresizingMaskIntoConstraints = false
    listStack.orientation = .vertical
    listStack.alignment = .leading
    listStack.spacing = 2
    listStack.translatesAutoresizingMaskIntoConstraints = false
    doc.addSubview(listStack)
    scroll.documentView = doc

    emptyLabel.font = .systemFont(ofSize: SeptenaTypeScale.size(.footnote))
    emptyLabel.textColor = SeptaskKitTheme.inkSecondary
    emptyLabel.alignment = .center
    emptyLabel.lineBreakMode = .byWordWrapping
    emptyLabel.maximumNumberOfLines = 2
    emptyLabel.translatesAutoresizingMaskIntoConstraints = false

    manageButton.isBordered = false
    manageButton.bezelStyle = .inline
    manageButton.title = String(localized: "Manage Tags…", comment: "SeptaskKit: manage tags button")
    manageButton.font = .systemFont(ofSize: SeptenaTypeScale.size(.footnote))
    manageButton.contentTintColor = SeptaskKitTheme.inkSecondary
    manageButton.target = self
    manageButton.action = #selector(openManageTags)
    manageButton.translatesAutoresizingMaskIntoConstraints = false

    let divider = NSBox()
    divider.boxType = .separator
    divider.translatesAutoresizingMaskIntoConstraints = false

    addSubview(searchField)
    addSubview(scroll)
    addSubview(emptyLabel)
    addSubview(divider)
    addSubview(manageButton)

    let clip = scroll.contentView
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 256),
      heightAnchor.constraint(equalToConstant: 268),
      searchField.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
      scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      scroll.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -6),
      doc.topAnchor.constraint(equalTo: clip.topAnchor),
      doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
      doc.widthAnchor.constraint(equalTo: clip.widthAnchor),
      listStack.topAnchor.constraint(equalTo: doc.topAnchor),
      listStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
      listStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
      listStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
      emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
      emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
      emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -16),
      divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      divider.bottomAnchor.constraint(equalTo: manageButton.topAnchor, constant: -6),
      manageButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      manageButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
    ])

    reload()
  }

  required init?(coder: NSCoder) { fatalError("KitTagBoard is code-only") }

  private func currentTagSets() -> [String: [String]] {
    let tasks = LocalCache.allTasks(in: context)
    var out: [String: [String]] = [:]
    for id in taskIDs {
      if let t = tasks.first(where: { $0.id == id }) { out[id] = t.tags }
    }
    return out
  }

  private func filteredTags() -> [TaskTag] {
    let q = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return allTags }
    return allTags.filter { $0.name.localizedCaseInsensitiveContains(q) }
  }

  private func reload() {
    allTags = LocalCache.allTags(in: context)
    for v in listStack.arrangedSubviews {
      listStack.removeArrangedSubview(v)
      v.removeFromSuperview()
    }
    let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let matches = filteredTags()
    let sets = currentTagSets()

    for tag in matches {
      let count = sets.values.filter { $0.contains(tag.id) }.count
      let state: Int = count == 0 ? 0 : (count == sets.count ? 2 : 1)
      let row = makeRowButton(tag: tag, state: state)
      listStack.addArrangedSubview(row)
      row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
    }

    let exactExists = allTags.contains { $0.name.localizedCaseInsensitiveCompare(query) == .orderedSame }
    if !query.isEmpty, !exactExists {
      let createBtn = NSButton()
      createBtn.isBordered = false
      createBtn.bezelStyle = .inline
      createBtn.alignment = .left
      createBtn.font = .systemFont(ofSize: SeptenaTypeScale.size(.callout), weight: .medium)
      createBtn.title = String(localized: "Create \"\(query)\"", comment: "SeptaskKit: create tag option")
      createBtn.contentTintColor = NSColor.labelColor
      createBtn.target = self
      createBtn.action = #selector(createFromSearch)
      createBtn.translatesAutoresizingMaskIntoConstraints = false
      createBtn.heightAnchor.constraint(equalToConstant: 26).isActive = true
      listStack.addArrangedSubview(createBtn)
      createBtn.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
    }

    if matches.isEmpty && query.isEmpty {
      emptyLabel.stringValue = String(localized: "Type a name and press Return to create a tag.",
                                      comment: "SeptaskKit: empty tag popover hint")
      emptyLabel.isHidden = false
    } else {
      emptyLabel.isHidden = true
    }
  }

  private func makeRowButton(tag: TaskTag, state: Int) -> NSView {
    let row = KitTagPopoverRow(tag: tag, state: state) { [weak self] in
      self?.toggle(tag)
    }
    row.heightAnchor.constraint(equalToConstant: 26).isActive = true
    return row
  }

  private func toggle(_ tag: TaskTag) {
    let before = currentTagSets()
    guard !before.isEmpty else { return }
    let allHave = before.values.allSatisfy { $0.contains(tag.id) }
    var after: [String: [String]] = [:]
    for (id, tags) in before {
      let next = allHave ? tags.filter { $0 != tag.id } : (tags.contains(tag.id) ? tags : tags + [tag.id])
      after[id] = next
      mutator.setTaskTags(id: id, tagIDs: next)
    }
    TaskUndo.recordTaskTags(before: before, after: after, mutator: mutator)
    reload()
    onChanged()
  }

  @objc private func createFromSearch() {
    commitSearchReturn()
  }

  private func commitSearchReturn() {
    let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { onClose(); return }
    if let exact = allTags.first(where: { $0.name.localizedCaseInsensitiveCompare(query) == .orderedSame }) {
      toggle(exact)
      searchField.stringValue = ""
      reload()
      return
    }
    let matches = filteredTags()
    if matches.count == 1 {
      toggle(matches[0])
      searchField.stringValue = ""
      reload()
      return
    }
    guard let created = mutator.createTag(name: query) else { return }
    TaskUndo.recordTagCreate(created, mutator: mutator)
    toggle(created)
    searchField.stringValue = ""
    reload()
  }

  @objc private func openManageTags() {
    let window = hostWindow ?? self.window?.parent
    let notify = onChanged
    onClose()
    guard let window else { return }
    let hosting = NSHostingController(
      rootView: ManageTagsSheet()
        .modelContainer(LocalStore.shared.container)
    )
    let sheetWindow = NSWindow(contentViewController: hosting)
    sheetWindow.title = String(localized: "Manage Tags", comment: "Manage tags sheet title")
    sheetWindow.styleMask = [.titled, .closable]
    window.beginSheet(sheetWindow) { _ in notify() }
  }

  func controlTextDidChange(_ obj: Notification) {
    reload()
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    if commandSelector == #selector(NSResponder.insertNewline(_:)) {
      commitSearchReturn()
      return true
    }
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      onClose()
      return true
    }
    return false
  }
}

@MainActor
private final class KitTagFlippedView: NSView {
  override var isFlipped: Bool { true }
}

@MainActor
private final class KitTagPopoverRow: NSView {
  private let onTap: () -> Void
  private var hovered = false
  private var tracking: NSTrackingArea?

  init(tag: TaskTag, state: Int, onTap: @escaping () -> Void) {
    self.onTap = onTap
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    let dot = NSView()
    dot.wantsLayer = true
    dot.layer?.cornerRadius = 3.5
    dot.layer?.backgroundColor = TagColorPalette.nsColor(for: tag.color).cgColor
    dot.translatesAutoresizingMaskIntoConstraints = false

    let label = NSTextField(labelWithString: tag.name)
    label.font = .systemFont(ofSize: SeptenaTypeScale.size(.callout))
    label.textColor = .labelColor
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false

    let mark = NSImageView()
    mark.translatesAutoresizingMaskIntoConstraints = false
    if state == 2 {
      mark.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
      mark.contentTintColor = .labelColor
    } else if state == 1 {
      mark.image = NSImage(systemSymbolName: "minus", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
      mark.contentTintColor = SeptaskKitTheme.inkSecondary
    }

    addSubview(dot)
    addSubview(label)
    addSubview(mark)
    NSLayoutConstraint.activate([
      dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      dot.centerYAnchor.constraint(equalTo: centerYAnchor),
      dot.widthAnchor.constraint(equalToConstant: 7),
      dot.heightAnchor.constraint(equalToConstant: 7),
      label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      mark.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
      mark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      mark.centerYAnchor.constraint(equalTo: centerYAnchor),
      mark.widthAnchor.constraint(equalToConstant: 14),
    ])
  }

  required init?(coder: NSCoder) { fatalError("KitTagPopoverRow is code-only") }

  override func draw(_ dirtyRect: NSRect) {
    guard hovered else { return }
    SeptaskKitTheme.listSelectionFill(emphasized: true).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                              owner: self, userInfo: nil)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
  override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
  override func mouseUp(with event: NSEvent) { onTap() }
}
#endif
