#if os(macOS)
import AppKit

// The AppKit shell's date pickers: ⌘S "When" and ⌘⇧D "Deadline". TIER 1
// surfaces (SeptaskKitSurface.swift): each edits one attribute of one row, so
// each is a popover anchored to that row — no sheet, no modal window. The
// Repeat editor below is the third member of that family.
//
// Layout is a quick row over a ONE-WEEK day strip, the shape Things uses:
// scheduling answers "which of the next few days", so the popover shows the
// next seven days as labeled cells (weekday over day number) instead of a
// month grid. `NSDatePicker`'s `.clockAndCalendar` month was the old body; it
// read as a dense, alien control inside the popover and answered a question
// nobody asks here.
//
// The board is keyboard-first and walks ONE axis — time. ↓ and → step later,
// ↑ and ← step earlier, straight through Today → the seven days → Clear.
// Return picks, Escape closes. One highlight language throughout — the shell's
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

    /// First row. `.when`'s Today is the today FLAG, not a scheduled date;
    /// `.deadline`'s Today is an ordinary date.
    var todayTitle: String {
      String(localized: "Today", comment: "Relative date")
    }

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

/// The value the Repeat editor commits. The rule and its paused state are
/// committed together so a resumed series can never accidentally lose its
/// cadence (or create an occurrence while the editor is open).
struct SeptaskKitRecurrencePanelResult {
  let recurrence: Recurrence?
  let paused: Bool
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
  static func present(initial: Recurrence?, paused: Bool, hasScheduledDate: Bool,
                      relativeTo rect: NSRect, of view: NSView,
                      onCommit: @escaping (SeptaskKitRecurrencePanelResult) -> Void) {
    let board = KitRepeatBoard(initial: initial, paused: paused,
                               hasScheduledDate: hasScheduledDate)
    let handle = KitPopoverHandle()
    board.onTerminal = { result in
      onCommit(result)
      handle.close()
    }
    KitPopover.present(board, relativeTo: rect, of: view, focus: board, handle: handle) {
      // Dismissal accepts the draft — unless a terminal row already answered,
      // or nothing actually changed.
      guard let result = board.pendingResult else { return }
      onCommit(result)
    }
  }
}

/// The Repeat popover's body. Same vocabulary as the date board: a stack of
/// controls, a separator, then terminal rows in the shell's one row shape.
@MainActor
private final class KitRepeatBoard: NSView {

  /// Fired by a terminal row ("Don't Repeat") — commits and closes at once.
  var onTerminal: ((SeptaskKitRecurrencePanelResult) -> Void)?

  private let initial: Recurrence?
  private let hasScheduledDate: Bool
  private var paused: Bool
  /// The paused flag as opened, so `pendingResult` can tell an edit from a look.
  private let wasPaused: Bool
  private var didFinish = false

  private let intervalField = NSTextField(string: "1")
  private let intervalStepper = NSStepper()
  private let unitControl = NSSegmentedControl()
  private let modeControl = NSSegmentedControl()
  private let cadenceDescription = NSTextField(labelWithString: "")
  private let scheduleHint = NSTextField(labelWithString: "")
  private var pauseCell: KitDateCell?

  private static let width: CGFloat = 288

  init(initial: Recurrence?, paused: Bool, hasScheduledDate: Bool) {
    self.initial = initial
    self.hasScheduledDate = hasScheduledDate
    self.paused = paused
    self.wasPaused = paused
    super.init(frame: .zero)
    build()
  }

  required init?(coder: NSCoder) { fatalError("KitRepeatBoard is code-only") }

  override var acceptsFirstResponder: Bool { true }

  /// What dismissal should commit — nil once a terminal row has answered (so
  /// closing never writes twice) and nil when the draft still matches what was
  /// opened (so looking at the editor and closing it is not an edit, and does
  /// not push a CloudKit change or an undo entry).
  var pendingResult: SeptaskKitRecurrencePanelResult? {
    guard !didFinish else { return nil }
    let rule = Recurrence(unit: selectedUnit, interval: interval,
                          afterCompletion: afterCompletion)
    let nextPaused = initial == nil ? false : paused
    guard rule != initial || nextPaused != wasPaused else { return nil }
    return SeptaskKitRecurrencePanelResult(recurrence: rule, paused: nextPaused)
  }

  // MARK: Build

  private func build() {
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
    intervalField.widthAnchor.constraint(equalToConstant: 46).isActive = true
    intervalField.setAccessibilityTitle(String(localized: "Repeat every",
                                               comment: "SeptaskKit: repeat interval a11y"))

    intervalStepper.minValue = 1
    intervalStepper.maxValue = 99
    intervalStepper.increment = 1
    intervalStepper.valueWraps = false
    intervalStepper.target = self
    intervalStepper.action = #selector(stepperChanged)

    let unitTitles = [String(localized: "day", comment: "Repeat unit"),
                      String(localized: "week", comment: "Repeat unit"),
                      String(localized: "month", comment: "Repeat unit")]
    unitControl.segmentCount = unitTitles.count
    for (index, title) in unitTitles.enumerated() {
      unitControl.setLabel(title, forSegment: index)
    }
    unitControl.segmentStyle = .rounded
    unitControl.trackingMode = .selectOne
    unitControl.selectedSegment = unitIndex(for: initial?.unit ?? .week)
    unitControl.target = self
    unitControl.action = #selector(unitChanged)

    let cadenceRow = NSStackView(views: [intervalField, intervalStepper, unitControl])
    cadenceRow.orientation = .horizontal
    cadenceRow.alignment = .centerY
    cadenceRow.spacing = 6

    cadenceDescription.font = .systemFont(ofSize: SeptenaTypeScale.size(.footnote))
    cadenceDescription.textColor = SeptaskKitTheme.inkSecondary
    cadenceDescription.lineBreakMode = .byWordWrapping
    cadenceDescription.maximumNumberOfLines = 2

    modeControl.segmentCount = 2
    modeControl.setLabel(String(localized: "after completion",
                                comment: "Repeat anchor mode"), forSegment: 0)
    modeControl.setLabel(String(localized: "on scheduled date",
                                comment: "Repeat anchor mode"), forSegment: 1)
    modeControl.segmentStyle = .rounded
    modeControl.trackingMode = .selectOne
    modeControl.selectedSegment = initial?.afterCompletion == false ? 1 : 0
    modeControl.target = self
    modeControl.action = #selector(modeChanged)
    modeControl.isHidden = !hasScheduledDate

    scheduleHint.font = .systemFont(ofSize: SeptenaTypeScale.size(.footnote))
    scheduleHint.textColor = SeptaskKitTheme.inkSecondary
    scheduleHint.lineBreakMode = .byWordWrapping
    scheduleHint.maximumNumberOfLines = 2
    scheduleHint.isHidden = hasScheduledDate
    scheduleHint.stringValue = String(
      localized: "Give the task a date to repeat on a fixed schedule.",
      comment: "Repeat editor missing schedule hint")

    var views: [NSView] = [cadenceRow, cadenceDescription]
    views.append(hasScheduledDate ? modeControl : scheduleHint)

    // Terminal rows — only a task that already repeats can be paused or
    // stopped. Same row shape and same highlight as the date board's Clear.
    if initial != nil {
      views.append(KitSurface.separator())

      let pause = KitDateCell(radius: 8, height: 32) { [weak self] in self?.togglePaused() }
      pause.fillRow(symbol: paused ? "play.circle" : "pause.circle",
                    tint: SeptaskKitTheme.iconMuted, title: pauseTitle)
      pauseCell = pause
      views.append(pause)

      let stop = KitDateCell(radius: 8, height: 32) { [weak self] in self?.stopRepeating() }
      stop.fillRow(symbol: "xmark.circle", tint: SeptaskKitTheme.iconMuted,
                   title: String(localized: "Don’t Repeat", comment: "Repeat editor stop"))
      views.append(stop)
    }

    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    let pad = KitSurface.padding + 4
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: Self.width),
      stack.topAnchor.constraint(equalTo: topAnchor, constant: pad),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
    ])
    for view in views where !(view is NSStackView) {
      view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    updateValues()
  }

  // MARK: Values

  private func unitIndex(for unit: Recurrence.Unit) -> Int {
    switch unit {
    case .day: return 0
    case .week: return 1
    case .month: return 2
    }
  }

  private var selectedUnit: Recurrence.Unit {
    switch unitControl.selectedSegment {
    case 0: return .day
    case 2: return .month
    default: return .week
    }
  }

  private var interval: Int { min(99, max(1, intervalField.integerValue)) }

  private var afterCompletion: Bool { modeControl.selectedSegment == 0 || !hasScheduledDate }

  private var pauseTitle: String {
    paused
      ? String(localized: "Resume Repeat", comment: "Repeat editor pause action")
      : String(localized: "Pause Repeat", comment: "Repeat editor pause action")
  }

  private func updateValues() {
    let value = min(99, max(1, initial?.interval ?? 1))
    intervalField.integerValue = value
    intervalStepper.integerValue = value
    updateDescription()
  }

  private func updateDescription() {
    let unitName: String
    switch selectedUnit {
    case .day: unitName = interval == 1 ? "day" : "days"
    case .week: unitName = interval == 1 ? "week" : "weeks"
    case .month: unitName = interval == 1 ? "month" : "months"
    }
    let anchor = afterCompletion
      ? "after previous item is checked off."
      : "after previous scheduled date."
    cadenceDescription.stringValue = "\(interval) \(unitName) \(anchor)"
  }

  // MARK: Actions

  @objc private func modeChanged() { updateDescription() }
  @objc private func unitChanged() { updateDescription() }

  @objc private func intervalChanged() {
    let value = interval
    intervalField.integerValue = value
    intervalStepper.integerValue = value
    updateDescription()
  }

  @objc private func stepperChanged() {
    intervalField.integerValue = intervalStepper.integerValue
    updateDescription()
  }

  private func togglePaused() {
    paused.toggle()
    pauseCell?.updateRow(symbol: paused ? "play.circle" : "pause.circle", title: pauseTitle)
  }

  private func stopRepeating() {
    guard !didFinish else { return }
    didFinish = true
    onTerminal?(SeptaskKitRecurrencePanelResult(recurrence: nil, paused: false))
  }
}

// MARK: - Board

/// The popover's body: a Today row, a seven-day strip, and Clear — plus the
/// key handling that walks them.
///
/// Navigation is LINEAR, not grid-shaped: Today → each day in order → Clear.
/// ↓ and → both step forward in time, ↑ and ← both step back, so "down" always
/// means "later" no matter which part of the board holds focus. A ragged
/// (row, column) model made ↓ jump from a day to Clear, which reads as a
/// different axis than the one the user is walking.
@MainActor
private final class KitDateBoard: NSView {

  private let kind: SeptaskKitDatePopover.Kind
  private let onPick: (Date?, Bool) -> Void
  private let onCancel: () -> Void

  /// Every focusable cell in time order: Today, the seven days, then Clear.
  private var cells: [KitDateCell] = []
  private var focusIndex = 0

  /// Panel padding. The highlight is INSET from the popover edge (the
  /// palette shape in `SelectionLanguage`, not the full-bleed list-row one),
  /// so a selected row never collides with the popover's rounded corners.
  private static let padding: CGFloat = 8
  private static let rowHeight: CGFloat = 32
  private static let dayWidth: CGFloat = 40
  private static let dayHeight: CGFloat = 48
  private static let daySpacing: CGFloat = 6
  /// Today through a week out — the same window as SwiftUI's `WeekStrip`
  /// (`.upcoming` = offsets 0...6), so the two surfaces offer the same days.
  private static let dayOffsets = Array(0...6)

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
    // The app's today (DayClock/SeptenaDate), never the wall clock.
    let today = KitDayFormat.todayDate() ?? Date()

    let todayCell = KitDateCell(radius: 8, height: Self.rowHeight) { [weak self] in
      self?.pick(today)
    }
    todayCell.fillRow(symbol: "star.fill", tint: SeptaskKitTheme.todayAccent,
                      title: kind.todayTitle)

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

    let clearCell = KitDateCell(radius: 8, height: Self.rowHeight) { [weak self] in
      self?.onPick(nil, false)
    }
    clearCell.fillRow(symbol: "xmark.circle", tint: SeptaskKitTheme.iconMuted,
                      title: kind.clearTitle)

    let separator = NSBox()
    separator.boxType = .separator

    let stack = NSStackView(views: [todayCell, strip, separator, clearCell])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.setCustomSpacing(8, after: strip)
    stack.setCustomSpacing(4, after: separator)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    // Padding lives in these constants, NOT in `stack.edgeInsets` — the
    // insets came out flush against the popover edge, and a constraint
    // constant is unambiguous.
    let pad = Self.padding
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor, constant: pad),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
      // The strip sets the popover's width; the single-cell rows match it so
      // every highlight spans the same column.
      todayCell.widthAnchor.constraint(equalTo: strip.widthAnchor),
      clearCell.widthAnchor.constraint(equalTo: strip.widthAnchor),
      separator.widthAnchor.constraint(equalTo: strip.widthAnchor),
    ])

    cells = [todayCell] + dayCells + [clearCell]
    for cell in cells {
      cell.onHover = { [weak self] hovered in self?.focus(cell: hovered) }
    }

    // Start on the cell that already holds the task's value, so the arrows
    // walk from where the user is rather than from the top.
    if let initial, let index = Self.dayOffsets.firstIndex(where: { offset in
      guard let date = KitDayFormat.day(offset: offset) else { return false }
      return Calendar.current.isDate(date, inSameDayAs: initial)
    }) {
      focusIndex = index + 1   // +1: the Today row precedes the strip.
    }
    applyFocus()
  }

  /// Scheduling a task to today IS the today flag for `.when`, so the strip's
  /// first cell and the Today row commit the same thing. `.deadline` has no
  /// flag and always writes the date.
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
    switch event.keyCode {
    case 126, 123: step(-1)                     // ↑ / ← — earlier
    case 125, 124: step(1)                      // ↓ / → — later
    case 36, 76, 49: cells[focusIndex].activate()  // Return / Enter / Space
    case 53: onCancel()                         // Escape
    default: super.keyDown(with: event)
    }
  }

  override func cancelOperation(_ sender: Any?) { onCancel() }
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

  /// Symbol + title — the shape of a menu row.
  func fillRow(symbol: String, tint: NSColor, title: String) {
    let image = NSImageView()
    image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    image.symbolConfiguration = NSImage.SymbolConfiguration(
      pointSize: SeptenaTypeScale.size(.body), weight: .regular)
    image.contentTintColor = tint

    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: SeptenaTypeScale.size(.body))
    label.textColor = SeptaskKitTheme.inkPrimary

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

  /// Weekday over day number — the strip's cell, matched to SwiftUI's
  /// `WeekStrip` (11pt medium weekday, 17pt semibold rounded number) so the
  /// two surfaces read as one component. Today is marked with the gold ink
  /// the Today row's star uses — INK, never a second background fill, which
  /// would compete with the focus wash.
  func fillDay(_ date: Date, isToday: Bool) {
    isWeekend = Calendar.current.isDateInWeekend(date)

    let weekday = NSTextField(labelWithString: Self.weekday.string(from: date))
    weekday.font = .systemFont(ofSize: 11, weight: .medium)
    weekday.textColor = SeptaskKitTheme.inkSecondary
    weekday.alignment = .center

    let number = NSTextField(labelWithString: Self.number.string(from: date))
    number.font = Self.rounded(size: 17, weight: .semibold)
    number.textColor = isToday ? SeptaskKitTheme.todayAccent : SeptaskKitTheme.inkPrimary
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
