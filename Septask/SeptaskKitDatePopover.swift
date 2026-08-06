#if os(macOS)
import AppKit

// The AppKit shell's date pickers: ⌘S "When" and ⌘⇧D "Deadline", presented as
// a native NSPopover anchored to the selected row (the platform's standard
// device for a small scoped editor — no sheet, no modal window).
//
// Layout is quick choices over a calendar, the shape Reminders and Things both
// use: the common answers are one click, the calendar covers the rest.
// "When" writes scheduled/today; "Deadline" writes the hard date. Both offer
// Clear. Every write goes through TaskMutator via the caller's closure — this
// type owns presentation only.
@MainActor
final class SeptaskKitDatePopover: NSViewController {

  enum Kind {
    case when
    case deadline

    var quickChoices: [(title: String, offset: Int?)] {
      switch self {
      case .when:
        // nil offset = Today (the today flag, not a scheduled date).
        return [("Today", nil), ("Tomorrow", 1), ("Next Week", 7)]
      case .deadline:
        return [("Today", 0), ("Tomorrow", 1), ("Next Week", 7)]
      }
    }

    var clearTitle: String {
      switch self {
      case .when: return "Clear (Anytime)"
      case .deadline: return "No Deadline"
      }
    }
  }

  /// `nil` date = the caller clears; `today` distinguishes the Today flag
  /// from a dated schedule for `.when`.
  typealias Handler = (_ date: Date?, _ today: Bool) -> Void

  private let kind: Kind
  private let handler: Handler
  private let picker = NSDatePicker()
  private weak var popover: NSPopover?

  init(kind: Kind, initial: Date?, handler: @escaping Handler) {
    self.kind = kind
    self.handler = handler
    super.init(nibName: nil, bundle: nil)
    picker.dateValue = initial ?? KitDayFormat.todayDate() ?? Date()
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
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 2
    stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

    for (title, offset) in kind.quickChoices {
      let button = NSButton(title: title, target: self, action: #selector(quickChoice(_:)))
      button.bezelStyle = .recessed
      button.isBordered = false
      button.tag = offset ?? -1
      button.contentTintColor = .controlAccentColor
      stack.addArrangedSubview(button)
    }

    picker.datePickerStyle = .clockAndCalendar
    picker.datePickerElements = [.yearMonthDay]
    picker.target = self
    picker.action = #selector(calendarChoice)
    stack.addArrangedSubview(picker)

    let clear = NSButton(title: kind.clearTitle, target: self, action: #selector(clearChoice))
    clear.bezelStyle = .recessed
    clear.isBordered = false
    stack.addArrangedSubview(clear)

    view = stack
  }

  // MARK: - Choices

  @objc private func quickChoice(_ sender: NSButton) {
    // tag -1 is the Today flag (`.when` only); every other tag is a day offset
    // from the app's today (DayClock, so time travel is honored).
    if sender.tag < 0 {
      finish(date: nil, today: true)
    } else {
      finish(date: KitDayFormat.day(offset: sender.tag), today: false)
    }
  }

  @objc private func calendarChoice() {
    finish(date: picker.dateValue, today: false)
  }

  @objc private func clearChoice() {
    finish(date: nil, today: false)
  }

  private func finish(date: Date?, today: Bool) {
    handler(date, today)
    popover?.performClose(nil)
  }
}
#endif
