#if os(macOS)
import AppKit

// The AppKit shell's date pickers: ⌘S "When" and ⌘⇧D "Deadline", presented as
// a native NSPopover anchored to the selected row (the platform's standard
// device for a small scoped editor — no sheet, no modal window).
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
final class SeptaskKitDatePopover: NSViewController {

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

  private let kind: Kind
  private let initial: Date?
  private let handler: Handler
  private var board: KitDateBoard?
  private weak var popover: NSPopover?

  init(kind: Kind, initial: Date?, handler: @escaping Handler) {
    self.kind = kind
    self.initial = initial
    self.handler = handler
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("SeptaskKitDatePopover is code-only") }

  /// Anchor to `rect` in `view` and show. Returns nothing — the handler fires
  /// on choice, and the popover closes itself.
  static func present(kind: Kind, initial: Date?, relativeTo rect: NSRect,
                      of view: NSView, handler: @escaping Handler) {
    let controller = SeptaskKitDatePopover(kind: kind, initial: initial, handler: handler)
    let popover = NSPopover()
    popover.contentViewController = controller
    popover.behavior = .transient
    controller.popover = popover
    popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
  }

  override func loadView() {
    // Genuine vibrancy, not the flat/washed-out look a bare `NSStackView`
    // popover falls back to — same `.popover` material + rounded, masked
    // layer as `SeptaskKitQuickFind`/`SeptaskKitQuickEntry`'s panels, so
    // every floating AppKit surface in the shell reads as one glass family.
    let content = NSVisualEffectView()
    content.material = .popover
    content.state = .active
    content.wantsLayer = true
    content.layer?.cornerRadius = 14
    content.layer?.masksToBounds = true

    let board = KitDateBoard(kind: kind, initial: initial) { [weak self] date, today in
      self?.finish(date: date, today: today)
    } onCancel: { [weak self] in
      self?.popover?.performClose(nil)
    }
    board.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(board)
    NSLayoutConstraint.activate([
      board.topAnchor.constraint(equalTo: content.topAnchor),
      board.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      board.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      board.bottomAnchor.constraint(equalTo: content.bottomAnchor),
    ])
    self.board = board
    view = content
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    // Claim first responder so ↑/↓/←/→/Return reach the board. Without this
    // the popover window routes keys nowhere and the picker is mouse-only.
    if let board { view.window?.makeFirstResponder(board) }
  }

  private func finish(date: Date?, today: Bool) {
    handler(date, today)
    popover?.performClose(nil)
  }
}

// MARK: - Repeat editor

/// The value returned by the AppKit Repeat editor. The rule and its paused
/// state are committed together so a resumed series can never accidentally
/// lose its cadence (or create an occurrence while the panel is open).
struct SeptaskKitRecurrencePanelResult {
  let recurrence: Recurrence?
  let paused: Bool
}

/// Things-inspired Repeat editor for the native shell. Repeat is deliberately
/// a panel, not a menu of presets: the same surface edits the cadence, anchor
/// mode, and pause state, and it can also stop the series.
@MainActor
final class SeptaskKitRecurrencePanelController: NSWindowController, NSWindowDelegate {
  private static var current: SeptaskKitRecurrencePanelController?

  private let initial: Recurrence?
  private let hasScheduledDate: Bool
  private var paused: Bool
  private let onCommit: (SeptaskKitRecurrencePanelResult) -> Void
  private var didFinish = false

  private let modePopup = NSPopUpButton()
  private let unitPopup = NSPopUpButton()
  private let intervalField = NSTextField(string: "1")
  private let intervalStepper = NSStepper()
  private let scheduleHint = NSTextField(labelWithString: "")
  private let cadenceDescription = NSTextField(labelWithString: "")
  private let modeFallback = NSTextField(labelWithString: "After completion")
  private let pauseButton = NSButton()

  static func present(initial: Recurrence?, paused: Bool,
                      hasScheduledDate: Bool,
                      onCommit: @escaping (SeptaskKitRecurrencePanelResult) -> Void) {
    if let current {
      current.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = SeptaskKitRecurrencePanelController(
      initial: initial,
      paused: paused,
      hasScheduledDate: hasScheduledDate,
      onCommit: onCommit)
    current = controller
    controller.showWindow(nil)
    controller.window?.center()
    controller.window?.makeKeyAndOrderFront(nil)
  }

  init(initial: Recurrence?, paused: Bool, hasScheduledDate: Bool,
       onCommit: @escaping (SeptaskKitRecurrencePanelResult) -> Void) {
    self.initial = initial
    self.hasScheduledDate = hasScheduledDate
    self.paused = paused
    self.onCommit = onCommit

    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
                        styleMask: [.titled, .closable, .utilityWindow],
                        backing: .buffered, defer: false)
    panel.title = String(localized: "Repeat", comment: "Repeat editor title")
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.minSize = NSSize(width: 480, height: 250)
    super.init(window: panel)
    panel.delegate = self
    panel.titleVisibility = .visible
    // An NSWindowController has no `loadView`, so the body is built here and
    // installed as the panel's contentView. `present` calls `showWindow`
    // straight after init, which would otherwise put an empty panel on screen.
    buildContent(in: panel)
  }

  required init?(coder: NSCoder) { fatalError("SeptaskKitRecurrencePanelController is code-only") }

  private func buildContent(in panel: NSPanel) {
    let root = NSVisualEffectView()
    root.material = .popover
    root.state = .active
    root.wantsLayer = true
    root.layer?.cornerRadius = 12

    let iconBadge = NSView()
    iconBadge.wantsLayer = true
    iconBadge.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.18).cgColor
    iconBadge.layer?.cornerRadius = 14
    iconBadge.translatesAutoresizingMaskIntoConstraints = false
    let titleIcon = NSImageView(image: NSImage(systemSymbolName: "arrow.clockwise",
                                                accessibilityDescription: nil) ?? NSImage())
    titleIcon.contentTintColor = .systemBlue
    titleIcon.image = titleIcon.image?.withSymbolConfiguration(
      .init(pointSize: 17, weight: .semibold))
    titleIcon.translatesAutoresizingMaskIntoConstraints = false
    iconBadge.addSubview(titleIcon)
    NSLayoutConstraint.activate([
      iconBadge.widthAnchor.constraint(equalToConstant: 28),
      iconBadge.heightAnchor.constraint(equalToConstant: 28),
      titleIcon.centerXAnchor.constraint(equalTo: iconBadge.centerXAnchor),
      titleIcon.centerYAnchor.constraint(equalTo: iconBadge.centerYAnchor),
    ])

    let title = NSTextField(labelWithString: String(localized: "Repeat",
                                                    comment: "Repeat editor heading"))
    title.font = .systemFont(ofSize: 17, weight: .semibold)
    let titleGroup = NSStackView(views: [iconBadge, title])
    titleGroup.orientation = .horizontal
    titleGroup.alignment = .centerY
    titleGroup.spacing = 8

    modePopup.addItems(withTitles: [
      String(localized: "after completion", comment: "Repeat anchor mode"),
      String(localized: "on scheduled date", comment: "Repeat anchor mode")
    ])
    modePopup.selectItem(at: initial?.afterCompletion == false ? 1 : 0)
    modePopup.target = self
    modePopup.action = #selector(modeChanged)
    modePopup.controlSize = .regular
    modePopup.widthAnchor.constraint(equalToConstant: 190).isActive = true
    modePopup.isHidden = !hasScheduledDate

    modeFallback.font = .systemFont(ofSize: 14)
    modeFallback.textColor = .labelColor
    modeFallback.isHidden = hasScheduledDate
    modeFallback.setContentHuggingPriority(.required, for: .horizontal)

    let modeControl: NSView = hasScheduledDate ? modePopup : modeFallback
    let heading = NSStackView(views: [titleGroup, NSView(), modeControl])
    heading.orientation = .horizontal
    heading.alignment = .centerY
    heading.spacing = 8

    intervalField.alignment = .right
    intervalField.controlSize = .regular
    intervalField.font = .systemFont(ofSize: 14)
    intervalField.widthAnchor.constraint(equalToConstant: 44).isActive = true
    intervalField.target = self
    intervalField.action = #selector(intervalChanged)
    intervalField.formatter = NumberFormatter()
    (intervalField.formatter as? NumberFormatter)?.minimum = 1
    (intervalField.formatter as? NumberFormatter)?.maximum = 99

    intervalStepper.minValue = 1
    intervalStepper.maxValue = 99
    intervalStepper.increment = 1
    intervalStepper.valueWraps = false
    intervalStepper.controlSize = .regular
    intervalStepper.target = self
    intervalStepper.action = #selector(stepperChanged)
    intervalStepper.widthAnchor.constraint(equalToConstant: 20).isActive = true

    unitPopup.addItems(withTitles: [
      String(localized: "day", comment: "Repeat unit"),
      String(localized: "week", comment: "Repeat unit"),
      String(localized: "month", comment: "Repeat unit")
    ])
    unitPopup.selectItem(at: unitIndex(for: initial?.unit ?? .week))
    unitPopup.target = self
    unitPopup.action = #selector(unitChanged)
    unitPopup.widthAnchor.constraint(equalToConstant: 100).isActive = true

    intervalField.bezelStyle = .roundedBezel
    intervalField.drawsBackground = true
    intervalField.backgroundColor = .controlBackgroundColor

    cadenceDescription.font = .systemFont(ofSize: 14)
    cadenceDescription.textColor = .labelColor
    cadenceDescription.lineBreakMode = .byWordWrapping
    cadenceDescription.maximumNumberOfLines = 2
    cadenceDescription.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let intervalRow = NSStackView(views: [intervalField, intervalStepper, unitPopup,
                                          cadenceDescription])
    intervalRow.orientation = .horizontal
    intervalRow.alignment = .centerY
    intervalRow.spacing = 8

    let ruleCard = NSVisualEffectView()
    ruleCard.material = .contentBackground
    ruleCard.blendingMode = .withinWindow
    ruleCard.state = .active
    ruleCard.wantsLayer = true
    ruleCard.layer?.cornerRadius = 14
    ruleCard.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.45).cgColor
    ruleCard.translatesAutoresizingMaskIntoConstraints = false
    ruleCard.addSubview(intervalRow)
    intervalRow.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      intervalRow.topAnchor.constraint(equalTo: ruleCard.topAnchor, constant: 18),
      intervalRow.leadingAnchor.constraint(equalTo: ruleCard.leadingAnchor, constant: 18),
      intervalRow.trailingAnchor.constraint(equalTo: ruleCard.trailingAnchor, constant: -18),
      intervalRow.bottomAnchor.constraint(equalTo: ruleCard.bottomAnchor, constant: -18),
    ])

    scheduleHint.font = .systemFont(ofSize: 12)
    scheduleHint.textColor = .secondaryLabelColor
    scheduleHint.lineBreakMode = .byWordWrapping
    scheduleHint.maximumNumberOfLines = 2
    scheduleHint.isHidden = hasScheduledDate
    scheduleHint.stringValue = String(localized: "Give the task a date to repeat on a fixed schedule.",
                                      comment: "Repeat editor missing schedule hint")

    let divider = NSBox()
    divider.boxType = .separator

    var controls: [NSView] = [heading, ruleCard, scheduleHint]
    if initial != nil {
      pauseButton.bezelStyle = .rounded
      pauseButton.title = paused
        ? String(localized: "Resume Repeat", comment: "Repeat editor pause action")
        : String(localized: "Pause Repeat", comment: "Repeat editor pause action")
      pauseButton.image = NSImage(systemSymbolName: paused ? "play.circle" : "pause.circle",
                                  accessibilityDescription: nil)
      pauseButton.imagePosition = .imageLeading
      pauseButton.target = self
      pauseButton.action = #selector(togglePaused)
      pauseButton.alignment = .left
      controls.append(pauseButton)
    }
    controls.append(divider)

    let cancel = NSButton(title: String(localized: "Cancel", comment: "Repeat editor cancel"),
                          target: self, action: #selector(cancel))
    cancel.bezelStyle = .rounded
    let stop = NSButton(title: String(localized: "Don’t Repeat", comment: "Repeat editor stop"),
                        target: self, action: #selector(stopRepeating))
    stop.bezelStyle = .rounded
    stop.isHidden = initial == nil
    let ok = NSButton(title: String(localized: "OK", comment: "Repeat editor confirm"),
                      target: self, action: #selector(commit))
    ok.bezelStyle = .rounded
    ok.keyEquivalent = "\r"
    ok.hasDestructiveAction = false

    let buttons = NSStackView(views: [cancel, stop, NSView(), ok])
    buttons.orientation = .horizontal
    buttons.alignment = .centerY
    buttons.spacing = 8

    let stack = NSStackView(views: controls + [buttons])
    stack.orientation = .vertical
    // AppKit's NSStackView has no `.fill` alignment (unlike SwiftUI). The
    // child width constraints below provide the same full-width layout.
    stack.alignment = .leading
    stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 18, right: 24)
    stack.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: root.topAnchor),
      stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
      ruleCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
      scheduleHint.widthAnchor.constraint(equalTo: stack.widthAnchor),
      buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
      ok.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),
      cancel.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),
      stop.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
    ])
    panel.contentView = root
    panel.setContentSize(NSSize(width: 520, height: initial == nil ? 250 : 305))
    updateValues()
  }

  private func unitIndex(for unit: Recurrence.Unit) -> Int {
    switch unit {
    case .day: return 0
    case .week: return 1
    case .month: return 2
    }
  }

  private var selectedUnit: Recurrence.Unit {
    switch unitPopup.indexOfSelectedItem {
    case 0: return .day
    case 2: return .month
    default: return .week
    }
  }

  private var interval: Int {
    min(99, max(1, Int(intervalField.integerValue)))
  }

  private var afterCompletion: Bool { modePopup.indexOfSelectedItem == 0 || !hasScheduledDate }

  private func updateValues() {
    let value = min(99, max(1, initial?.interval ?? 1))
    intervalField.integerValue = value
    intervalStepper.integerValue = value
    updateDescription()
  }

  private func updateDescription() {
    let unit = selectedUnit
    let unitName: String
    switch unit {
    case .day: unitName = interval == 1 ? "day" : "days"
    case .week: unitName = interval == 1 ? "week" : "weeks"
    case .month: unitName = interval == 1 ? "month" : "months"
    }
    let anchor = afterCompletion ? "after previous item is checked off." : "after previous scheduled date."
    cadenceDescription.stringValue = "\(interval) \(unitName) \(anchor)"
  }

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

  @objc private func togglePaused() {
    paused.toggle()
    pauseButton.title = paused
      ? String(localized: "Resume Repeat", comment: "Repeat editor pause action")
      : String(localized: "Pause Repeat", comment: "Repeat editor pause action")
    pauseButton.image = NSImage(systemSymbolName: paused ? "play.circle" : "pause.circle",
                                accessibilityDescription: nil)
  }

  @objc private func commit() {
    finish(SeptaskKitRecurrencePanelResult(
      recurrence: Recurrence(unit: selectedUnit,
                             interval: interval,
                             afterCompletion: afterCompletion),
      paused: initial == nil ? false : paused))
  }

  @objc private func stopRepeating() {
    finish(SeptaskKitRecurrencePanelResult(recurrence: nil, paused: false))
  }

  @objc private func cancel() { window?.performClose(nil) }

  private func finish(_ result: SeptaskKitRecurrencePanelResult) {
    guard !didFinish else { return }
    didFinish = true
    onCommit(result)
    window?.close()
  }

  func windowWillClose(_ notification: Notification) {
    if !didFinish { didFinish = true }
    Self.current = nil
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
    setAccessibilityTitle(title)
  }

  /// Weekday over day number — the strip's cell, matched to SwiftUI's
  /// `WeekStrip` (11pt medium weekday, 17pt semibold rounded number) so the
  /// two surfaces read as one component. Today is marked with the gold ink
  /// the Today row's star uses — INK, never a second background fill, which
  /// would compete with the focus wash.
  func fillDay(_ date: Date, isToday: Bool) {
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
    guard isFocused else { return }
    SeptaskKitTheme.listSelectionFill(emphasized: true).setFill()
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
