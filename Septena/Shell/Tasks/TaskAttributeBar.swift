import SwiftUI

// The composer's elective-pill rail — a single row of circular icon buttons
// (When / Deadline / Repeat / List / Attachments / Discuss) under the title &
// notes — and the inline panels a button expands into. Split out of
// TaskComposer.swift.
//
// `TaskAttributeBar` is the entry point; the pill and the three inline panels
// are private to this file.

// MARK: - Attribute pill bar

/// The horizontal rail of elective pills under the title. Owns which date /
/// repeat editor is expanded inline; the List picker opens as a sheet.
struct TaskAttributeBar: View {
  @Binding var draft: TaskDraft
  let areas: [Area]
  let projects: [Project]
  let accent: Color
  /// Neutral chrome: the inline (Things-style) editor keeps the whole rail
  /// monochrome — filled pills wear a gray capsule, not the section accent — so
  /// the open editor reads as calm form, with color reserved for the checkbox.
  /// The drawer keeps the accent tint.
  var neutral: Bool = false
  /// The composer's shared keyboard cursor — pills bind to `.pill(attr)` so Tab
  /// can land on them and they can draw the focus ring.
  @FocusState.Binding var focus: TaskEditFocus?
  /// One-shot keyboard-activation channel: when the composer sets this to a
  /// pill (Space / Return on a focused pill), the bar runs `select` and clears
  /// it. Pointer taps call `select` directly.
  @Binding var activate: Attribute?
  /// Edit mode only — when set and no conversation exists yet, a Discuss pill
  /// joins the rail to kick off the on-device conversation flow.
  var discussTask: SeptenaTask? = nil
  /// Written whenever `showsDiscuss` changes so the composer can Tab to the pill.
  @Binding var discussVisible: Bool

  /// The electives, in rail order. Each is fully described by the enum (icon /
  /// label / how it presents); per-attribute *values* are derived from the draft
  /// in `value(for:)` / `isSet(_:)`, and each editor lives in its own panel. So
  /// every pill is wired identically — one `ForEach`, one `select(_:)` — and the
  /// rail grows by adding a case, not another hand-written call.
  enum Attribute: Identifiable {
    case when, deadline, repeatRule, list, attachments
    /// Edit-mode AI kickoff — rendered separately, not part of `draftCases`.
    case discuss
    var id: Self { self }

    /// Scheduling / filing electives — the `ForEach` rail.
    static let draftCases: [Attribute] = [.when, .deadline, .repeatRule, .list]

    var icon: String {
      switch self {
      case .when:       "calendar"
      case .deadline:   "flag"
      case .repeatRule: "repeat"
      case .list:       "folder"
      case .attachments:"paperclip"
      case .discuss:    "bubble.left.and.bubble.right"
      }
    }
    var label: String {
      switch self {
      case .when:       "When"
      case .deadline:   "Deadline"
      case .repeatRule: "Repeat"
      case .list:       "List"
      case .attachments:"Attachments"
      case .discuss:    "Discuss"
      }
    }
    /// List opens a sheet — a rich, searchable area/project picker reused across
    /// the Tasks surfaces. Every other pill expands an inline panel under the rail.
    var presentsSheet: Bool { self == .list }
  }

  /// The currently expanded inline pill (never `.list`, which presents a sheet).
  @State private var expanded: Attribute?
  @State private var showingList = false
  @State private var discussStarted: Bool
  @State private var discussWorking = false

  init(draft: Binding<TaskDraft>, areas: [Area], projects: [Project], accent: Color,
       neutral: Bool = false, focus: FocusState<TaskEditFocus?>.Binding,
       activate: Binding<Attribute?>, discussTask: SeptenaTask? = nil,
       discussVisible: Binding<Bool> = .constant(false)) {
    _draft = draft
    self.areas = areas
    self.projects = projects
    self.accent = accent
    self.neutral = neutral
    _focus = focus
    _activate = activate
    self.discussTask = discussTask
    _discussVisible = discussVisible
    _discussStarted = State(initialValue: discussTask?.conversation.hasStarted ?? true)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Single horizontal row of circular icon buttons — all 6 fit comfortably
      // on one row even on compact iPhone widths. "Today" lives inside the When
      // control rather than duplicating the rail.
      HStack(spacing: 8) {
        ForEach(Attribute.draftCases) { attr in
          AttributePill(icon: attr.icon, label: attr.label,
                        value: value(for: attr), isSet: isSet(attr),
                        isActive: expanded == attr, isFocused: focus == .pill(attr),
                        accent: accent, neutral: neutral) { select(attr) }
            .focused($focus, equals: .pill(attr))
        }
        if let task = discussTask {
          let count = SeptenaServices.shared.taskAttachmentStore.attachmentCount(taskID: task.id)
          AttributePill(icon: Attribute.attachments.icon, label: Attribute.attachments.label,
                        value: count == 0 ? nil : "\(count) file\(count == 1 ? "" : "s")",
                        isSet: count > 0, isActive: expanded == .attachments,
                        isFocused: focus == .pill(.attachments), accent: accent, neutral: neutral) {
            select(.attachments)
          }
          .focused($focus, equals: .pill(.attachments))
        }
        if showsDiscuss {
          AttributePill(icon: Attribute.discuss.icon, label: Attribute.discuss.label,
                        value: discussWorking ? "Thinking…" : nil,
                        isSet: discussWorking, isActive: false,
                        isLoading: discussWorking,
                        isFocused: focus == .pill(.discuss),
                        accent: accent, neutral: neutral) { select(.discuss) }
            .focused($focus, equals: .pill(.discuss))
            .disabled(discussWorking)
        }
      }

      inlineEditor
    }
    .onAppear(perform: reloadDiscussState)
    .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in
      reloadDiscussState()
    }
    .sheet(isPresented: $showingList) {
      MovePickerSheet(areas: areas, projects: projects,
                      currentAreaId: draft.areaId, currentProjectId: draft.projectId) { a, p in
        draft.areaId = a; draft.projectId = p
      }
      #if os(iOS)
      .presentationDetents([.large, .medium])
      #endif
    }
    // Keyboard Space / Return on a focused pill arrives here.
    .onChange(of: activate) { _, attr in
      guard let attr else { return }
      activate = nil
      select(attr)
    }
  }

  private var showsDiscuss: Bool {
    discussTask != nil && !discussStarted && OnDeviceAI.isAvailable
  }

  /// The value shown on a pill (its `nil` falls back to the plain label). All
  /// values are derived from the draft — the single read-side of the rail.
  private func value(for attr: Attribute) -> String? {
    switch attr {
    case .discuss: return nil
    case .attachments: return nil
    // "When" folds in Today: a task pinned to today (no date) reads "Today", a
    // future planning date reads its date, nothing set reads as Anytime (nil).
    case .when:
      if let s = draft.scheduled { return Self.dateLabel(s) }
      return draft.onToday ? "Today" : nil
    case .deadline:
      return draft.deadline.map(Self.dateLabel)
    case .repeatRule:
      return draft.recurrence?.shortLabel
    // The List pill always names its destination — "Inbox" by default, the area
    // or project once filed (but tinted only when explicitly filed, see isSet).
    case .list:
      return draft.listLabel(areas: areas, projects: projects)
    }
  }

  /// Whether a pill counts as "filled" — drives the accent tint.
  private func isSet(_ attr: Attribute) -> Bool {
    switch attr {
    case .discuss:    discussWorking
    case .attachments: discussTask.map { SeptenaServices.shared.taskAttachmentStore.attachmentCount(taskID: $0.id) > 0 } ?? false
    case .when:       draft.scheduled != nil || draft.onToday
    case .deadline:   draft.deadline != nil
    case .repeatRule: draft.recurrence != nil
    case .list:       draft.areaId != nil || draft.projectId != nil
    }
  }

  /// Inline cards already sit on `Theme.cardSurface` (`secondaryGroupedBackground`),
  /// so expanded picker panels inside them step down to `Theme.mutedSurface` to
  /// keep a distinct surface; the drawer sits on `groupedBackground`.
  private var panelFill: Color {
    neutral ? Theme.mutedSurface : Theme.secondaryGroupedBackground
  }

  @ViewBuilder
  private var inlineEditor: some View {
    // One transition for every inline panel — they all slide down from the rail.
    Group {
      switch expanded {
      case .when:       InlineWhenPanel(draft: $draft, fill: panelFill)
      case .deadline:   InlineDatePanel(date: $draft.deadline, fill: panelFill)
      case .repeatRule: InlineRepeatPanel(recurrence: $draft.recurrence,
                                          hasScheduledDate: draft.scheduled != nil,
                                          scheduledDate: SeptenaDate.format(draft.scheduled),
                                          accent: accent,
                                          fill: panelFill) {
        a11yAnimate(.snappy(duration: 0.22)) { expanded = nil }
      }
      case .attachments:
        if let task = discussTask { TaskAttachmentsPanel(taskID: task.id) }
      case .discuss, .list, .none: EmptyView()
      }
    }
    .transition(.opacity.combined(with: .move(edge: .top)))
  }

  /// The single dispatch for every pill: sheet-backed pills open their sheet,
  /// inline pills toggle the expanded panel. Per-attribute setup (Repeat seeding
  /// a default) lives in each panel's `onAppear`, so this stays uniform.
  private func select(_ attr: Attribute) {
    if attr == .discuss {
      startDiscuss()
      return
    }
    // Move the keyboard cursor onto the pill (also drops the title field's
    // keyboard before a calendar opens — what `onInteractStart` used to do).
    focus = .pill(attr)
    a11yAnimate(.snappy(duration: 0.22)) {
      if attr.presentsSheet {
        expanded = nil
        showingList = true
      } else {
        expanded = (expanded == attr) ? nil : attr
      }
    }
  }

  private func startDiscuss() {
    guard let task = discussTask, showsDiscuss, !discussWorking else { return }
    focus = .pill(.discuss)
    discussWorking = true
    Task {
      _ = await ConversationEngine.advance(task: task)
      discussWorking = false
      reloadDiscussState()
    }
  }

  private func reloadDiscussState() {
    guard let id = discussTask?.id else {
      discussStarted = true
      discussVisible = false
      return
    }
    discussStarted = SeptenaServices.shared.taskMutator.conversation(id: id)?.hasStarted ?? false
    discussVisible = showsDiscuss
  }

  /// "Today" / "Tomorrow" / "May 14" for a pill value.
  static func dateLabel(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "Today" }
    if cal.isDateInTomorrow(d) { return "Tomorrow" }
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("MMMd")
    return f.string(from: d)
  }
}

// MARK: - Pill

private struct AttributePill: View {
  let icon: String
  let label: String
  let value: String?
  let isSet: Bool
  let isActive: Bool
  var isLoading: Bool = false
  /// The keyboard cursor is on this pill — draw the focus ring (the system ring
  /// never shows with macOS keyboard navigation off).
  var isFocused: Bool = false
  let accent: Color
  /// Monochrome rail (inline editor): filled/active circles wear a neutral gray
  /// tint and the focus ring goes gray, so no section accent leaks into the
  /// open editor. See `TaskAttributeBar.neutral`.
  var neutral: Bool = false
  let action: () -> Void
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  private static let diameter: CGFloat = 34

  /// Circular fill — flat surface, no floating-glass elevation shadow.
  private var circleFill: Color {
    guard isSet || isActive else { return Theme.mutedSurface }
    if neutral {
      return Theme.inkPrimary.opacity(isActive ? 0.16 : 0.11)
    }
    return accent.opacity(isActive ? 0.42 : 0.30)
  }
  private var ringColor: Color { neutral ? Theme.selectionNeutral : accent }

  private var accessibleSummary: String {
    if let value { return "\(label): \(value)" }
    return label
  }

  var body: some View {
    Button(action: action) {
      Group {
        if isLoading {
          ProgressView()
            .controlSize(.mini)
        } else {
          Image(systemName: icon)
            .font(.system(size: 14, weight: .semibold))
        }
      }
      .foregroundStyle((isSet || isActive) ? Theme.inkPrimary : Theme.inkSecondary)
      .frame(width: Self.diameter, height: Self.diameter)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .modifier(AttributePillGlassBackground(
      circleFill: circleFill,
      tint: (isSet || isActive) ? (neutral ? Theme.inkPrimary.opacity(isActive ? 0.20 : 0.12) : accent.opacity(isActive ? 0.36 : 0.22)) : nil,
      reduceTransparency: reduceTransparency
    ))
    .overlay {
      Circle()
        .strokeBorder(ringColor, lineWidth: 2)
        .opacity(isFocused ? 1 : 0)
        .allowsHitTesting(false)
    }
    .accessibilityLabel(accessibleSummary)
    .help(accessibleSummary)
  }
}

private struct AttributePillGlassBackground: ViewModifier {
  let circleFill: Color
  let tint: Color?
  let reduceTransparency: Bool

  func body(content: Content) -> some View {
    if reduceTransparency {
      content.background(Circle().fill(circleFill))
    } else {
      #if os(iOS)
      if let tint {
        content.glassEffect(.regular.tint(tint).interactive(), in: .circle)
      } else {
        content.glassEffect(.regular.interactive(), in: .circle)
      }
      #else
      content
        .background(.thinMaterial, in: Circle())
        .background(Circle().fill(tint ?? .clear))
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
      #endif
    }
  }
}
// MARK: - Inline "When" editor

/// The scheduling control — the single home for Today and a planning date, so
/// neither needs its own pill. Body is `TaskDateBoard`, the app's one task
/// date board, so the pill expands the SAME Today row / week strip / calendar
/// / Clear the When sheet and the AppKit ⌘S popover show. It used to be three
/// bespoke chips (Today / Tomorrow / Weekend) over a full month calendar — a
/// third date vocabulary in a surface that already had two.
///
/// Picking today normalizes back to the pinned-Today state. Leaving it unset
/// keeps the task in Anytime.
private struct InlineWhenPanel: View {
  @Binding var draft: TaskDraft
  let fill: Color

  var body: some View {
    TaskDateBoard(
      selected: draft.scheduled,
      todayActive: draft.onToday && draft.scheduled == nil,
      clearLabel: (draft.scheduled != nil || draft.onToday) ? "No Date" : nil,
      onToday: { a11yAnimate(.snappy(duration: 0.2)) { draft.setToday() } },
      onPick: { d in a11yAnimate(.snappy(duration: 0.2)) { draft.setScheduled(d) } },
      onClear: { a11yAnimate(.snappy(duration: 0.2)) { draft.clearWhen() } })
    .padding(12)
    .background(fill,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

// MARK: - Inline date editor

/// The Deadline pill's body — the same `TaskDateBoard` the When pill expands,
/// writing a plain `Date?`. Its Today row is an ordinary date (a deadline has
/// no today flag), which is the only way Deadline differs from When here.
/// It used to be a bare month calendar with no relative choices at all.
private struct InlineDatePanel: View {
  @Binding var date: Date?
  let fill: Color
  @Environment(DayClock.self) private var clock

  private var cal: Calendar { Calendar.current }
  private var today: Date {
    cal.startOfDay(for: SeptenaDate.parse(clock.today) ?? clock.now)
  }

  var body: some View {
    TaskDateBoard(
      selected: date,
      todayActive: date.map { cal.isDate($0, inSameDayAs: today) } ?? false,
      clearLabel: date != nil ? "Remove Deadline" : nil,
      onToday: { a11yAnimate(.snappy(duration: 0.2)) { date = today } },
      onPick: { d in a11yAnimate(.snappy(duration: 0.2)) { date = cal.startOfDay(for: d) } },
      onClear: { a11yAnimate(.snappy(duration: 0.2)) { date = nil } })
    .padding(12)
    .background(fill,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

// MARK: - Inline repeat editor

/// Unit + interval + after-completion controls writing a `Recurrence?`, the
/// inline twin of `RecurrencePickerSheet`. Expanded under the Repeat pill.
private struct InlineRepeatPanel: View {
  @Binding var recurrence: Recurrence?
  /// A fixed-schedule rule anchors on the task's scheduled date. Without one it
  /// silently degrades into an after-completion rule (the anchor falls back to
  /// the completion day), so the toggle is held ON and explained rather than
  /// offering a choice that doesn't do what it says.
  let hasScheduledDate: Bool
  var scheduledDate: String? = nil
  let accent: Color
  let fill: Color
  /// Collapse the rail's expanded panel. "Don't Repeat" calls it (clear + close);
  /// owned by `TaskAttributeBar.expanded`.
  var onStop: () -> Void = {}

  private enum MonthlyMode: Int { case anchor = 0, dayOfMonth = 1, ordinal = 2 }

  private static let weekdayPills: [(day: Int, short: String, full: String)] = [
    (2, "M", "Monday"), (3, "T", "Tuesday"), (4, "W", "Wednesday"),
    (5, "T", "Thursday"), (6, "F", "Friday"), (7, "S", "Saturday"),
    (1, "S", "Sunday"),
  ]

  private static let ordinalChoices: [(value: Int, label: String)] = [
    (1, "1st"), (2, "2nd"), (3, "3rd"), (4, "4th"), (-1, "Last"),
  ]

  private static let fullWeekdays: [(value: Int, label: String)] = [
    (1, "Sunday"), (2, "Monday"), (3, "Tuesday"), (4, "Wednesday"),
    (5, "Thursday"), (6, "Friday"), (7, "Saturday"),
  ]

  private static let nextPreviewFormatter: DateFormatter = {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("EEEMMMd")
    return f
  }()

  /// True once the user actually picks a value here (or the task already
  /// repeated when the panel opened). A panel opened but left untouched reverts
  /// on close — so merely *peeking* at Repeat never commits a recurrence, and
  /// re-tapping the pill (or clicking away) cleanly undoes the open.
  @State private var confirmed = false
  @State private var showCustom = false

  /// Every control write goes through here so any real interaction marks the
  /// recurrence as confirmed (and thus kept on close).
  private func write(_ r: Recurrence) { recurrence = r; confirmed = true }

  private var unit: Binding<Recurrence.Unit> {
    Binding(get: { recurrence?.unit ?? .week },
            set: { write(Recurrence(unit: $0, interval: recurrence?.interval ?? 1,
                                    afterCompletion: recurrence?.afterCompletion ?? true,
                                    weekdays: recurrence?.weekdays,
                                    monthDay: recurrence?.monthDay,
                                    ordinalWeekday: recurrence?.ordinalWeekday)) })
  }
  private var interval: Binding<Int> {
    Binding(get: { recurrence?.interval ?? 1 },
            set: { write(Recurrence(unit: recurrence?.unit ?? .week, interval: $0,
                                    afterCompletion: recurrence?.afterCompletion ?? true,
                                    weekdays: recurrence?.weekdays,
                                    monthDay: recurrence?.monthDay,
                                    ordinalWeekday: recurrence?.ordinalWeekday)) })
  }
  private var afterCompletion: Binding<Bool> {
    // Reads ON with no date because that IS the behavior — showing a stored
    // OFF the engine can't honor would misreport what the rule will do.
    Binding(get: { !hasScheduledDate || (recurrence?.afterCompletion ?? true) },
            set: { write(Recurrence(unit: recurrence?.unit ?? .week,
                                    interval: recurrence?.interval ?? 1,
                                    afterCompletion: $0,
                                    weekdays: recurrence?.weekdays,
                                    monthDay: recurrence?.monthDay,
                                    ordinalWeekday: recurrence?.ordinalWeekday)) })
  }

  private var currentMonthlyMode: MonthlyMode {
    if recurrence?.ordinalWeekday != nil { return .ordinal }
    if recurrence?.monthDay != nil { return .dayOfMonth }
    return .anchor
  }

  private var supportsCustomOptions: Bool {
    guard hasScheduledDate, let r = recurrence, !r.afterCompletion else { return false }
    return r.unit == .week || r.unit == .month || r.unit == .year
  }

  private var nextPreview: String? {
    guard let r = recurrence,
          let wire = r.nextDate(completedOn: DayClock.appToday, scheduled: scheduledDate),
          let date = SeptenaDate.parse(wire) else { return nil }
    return Self.nextPreviewFormatter.string(from: date)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Picker("Unit", selection: unit) {
        Text("Day").tag(Recurrence.Unit.day)
        Text("Week").tag(Recurrence.Unit.week)
        Text("Month").tag(Recurrence.Unit.month)
        Text("Year").tag(Recurrence.Unit.year)
      }
      .pickerStyle(.segmented)

      if hasScheduledDate {
        let isWeekdays = recurrence?.afterCompletion == false
          && recurrence?.unit == .week
          && recurrence?.interval == 1
          && Set(recurrence?.weekdays ?? []) == Set([2, 3, 4, 5, 6])
        SelectableChip("Weekdays (Mon–Fri)", isSelected: isWeekdays, tint: accent) {
          write(Recurrence(unit: .week, interval: 1, afterCompletion: false,
                           weekdays: [2, 3, 4, 5, 6]))
        }
      }

      Stepper(value: interval, in: 1...99) {
        Text("Every \(intervalLabel())")
          .font(.septenaSidebarRow)
          .foregroundStyle(Theme.inkPrimary)
      }

      Toggle("After completion", isOn: afterCompletion)
        .font(.septenaSidebarRow)
        .tint(accent)
        .disabled(!hasScheduledDate)

      if supportsCustomOptions {
        Button {
          a11yAnimate(.snappy(duration: 0.2)) { showCustom.toggle() }
        } label: {
          HStack(spacing: 6) {
            Image(systemName: showCustom ? "chevron.down" : "chevron.right")
              .font(.caption.weight(.semibold))
            Text(showCustom ? "Hide custom options" : "Custom options…")
              .font(.caption.weight(.medium))
            Spacer(minLength: 0)
          }
          .foregroundStyle(Theme.inkSecondary)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if showCustom {
          if recurrence?.unit == .week {
            let selectedDays = Set(recurrence?.weekdays ?? [])
            HStack(spacing: 4) {
              ForEach(Self.weekdayPills, id: \.day) { item in
                SelectableChip(item.short,
                               isSelected: selectedDays.contains(item.day),
                               tint: accent,
                               shape: .roundedRect,
                               fillsWidth: true) {
                  var next = selectedDays
                  if next.contains(item.day) { next.remove(item.day) } else { next.insert(item.day) }
                  write(Recurrence(unit: .week,
                                   interval: recurrence?.interval ?? 1,
                                   afterCompletion: false,
                                   weekdays: next.isEmpty ? nil : next.sorted()))
                }
                .accessibilityLabel(item.full)
              }
            }
          } else if recurrence?.unit == .month || recurrence?.unit == .year {
            let anchor = scheduledDate.flatMap(SeptenaDate.parse) ?? DayClock.appNow
            let cal = Calendar.current
            let defaultDay = cal.component(.day, from: anchor)
            let defaultOrd = min(4, max(1, (defaultDay - 1) / 7 + 1))
            let defaultWeekday = cal.component(.weekday, from: anchor)

            Picker("Monthly rule", selection: Binding(
              get: { currentMonthlyMode },
              set: { mode in
                switch mode {
                case .anchor:
                  write(Recurrence(unit: recurrence?.unit ?? .month,
                                   interval: recurrence?.interval ?? 1,
                                   afterCompletion: false))
                case .dayOfMonth:
                  write(Recurrence(unit: recurrence?.unit ?? .month,
                                   interval: recurrence?.interval ?? 1,
                                   afterCompletion: false,
                                   monthDay: recurrence?.monthDay ?? defaultDay))
                case .ordinal:
                  write(Recurrence(unit: recurrence?.unit ?? .month,
                                   interval: recurrence?.interval ?? 1,
                                   afterCompletion: false,
                                   ordinalWeekday: recurrence?.ordinalWeekday
                                     ?? RecurrenceOrdinalWeekday(ordinal: defaultOrd,
                                                                 weekday: defaultWeekday)))
                }
              }
            )) {
              Text("Same day").tag(MonthlyMode.anchor)
              Text("On day").tag(MonthlyMode.dayOfMonth)
              Text("Ordinal").tag(MonthlyMode.ordinal)
            }
            .pickerStyle(.segmented)

            if currentMonthlyMode == .dayOfMonth {
              HStack(spacing: 8) {
                Text("Day")
                  .font(.caption)
                  .foregroundStyle(Theme.inkSecondary)
                Picker("Day of month", selection: Binding(
                  get: { recurrence?.monthDay ?? defaultDay },
                  set: { day in
                    write(Recurrence(unit: recurrence?.unit ?? .month,
                                     interval: recurrence?.interval ?? 1,
                                     afterCompletion: false,
                                     monthDay: day))
                  }
                )) {
                  ForEach(1...31, id: \.self) { d in Text("\(d)").tag(d) }
                  Text("Last day").tag(-1)
                }
                .pickerStyle(.menu)
                .tint(Theme.inkPrimary)
              }
            } else if currentMonthlyMode == .ordinal {
              let currentOW = recurrence?.ordinalWeekday
                ?? RecurrenceOrdinalWeekday(ordinal: defaultOrd, weekday: defaultWeekday)
              HStack(spacing: 6) {
                Text("On the")
                  .font(.caption)
                  .foregroundStyle(Theme.inkSecondary)
                Picker("Ordinal", selection: Binding(
                  get: { currentOW.ordinal },
                  set: { ord in
                    write(Recurrence(unit: recurrence?.unit ?? .month,
                                     interval: recurrence?.interval ?? 1,
                                     afterCompletion: false,
                                     ordinalWeekday: RecurrenceOrdinalWeekday(ordinal: ord,
                                                                              weekday: currentOW.weekday)))
                  }
                )) {
                  ForEach(Self.ordinalChoices, id: \.value) { item in
                    Text(item.label).tag(item.value)
                  }
                }
                .pickerStyle(.menu)
                .tint(Theme.inkPrimary)

                Picker("Weekday", selection: Binding(
                  get: { currentOW.weekday },
                  set: { wd in
                    write(Recurrence(unit: recurrence?.unit ?? .month,
                                     interval: recurrence?.interval ?? 1,
                                     afterCompletion: false,
                                     ordinalWeekday: RecurrenceOrdinalWeekday(ordinal: currentOW.ordinal,
                                                                              weekday: wd)))
                  }
                )) {
                  ForEach(Self.fullWeekdays, id: \.value) { item in
                    Text(item.label).tag(item.value)
                  }
                }
                .pickerStyle(.menu)
                .tint(Theme.inkPrimary)
              }
            }
          }
        }
      }

      if let next = nextPreview, let r = recurrence {
        Text("\(r.shortLabel) · Next: \(next)")
          .font(.caption)
          .foregroundStyle(Theme.inkSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if !hasScheduledDate {
        Text("Give the task a date to repeat on a fixed schedule.")
          .font(.caption)
          .foregroundStyle(Theme.inkSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Button(role: .destructive) {
        recurrence = nil
        confirmed = true   // explicit clear; don't let onDisappear second-guess it
        onStop()
      } label: {
        Label("Don't Repeat", systemImage: "xmark.circle")
          .font(.septenaLabel)
      }
      .buttonStyle(.plain)
      .foregroundStyle(Theme.overdueRed)
    }
    .padding(12)
    .background(fill,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    // Opening shows a weekly preview so the controls have something to bind, but
    // it's only a peek: `confirmed` stays false until a real edit, and an
    // untouched panel reverts to "no repeat" on close (`onDisappear`). A task
    // that already repeated counts as confirmed, so editing never loses it.
    .onAppear {
      if recurrence == nil {
        recurrence = Recurrence(unit: .week)
        confirmed = false
        showCustom = false
      } else {
        confirmed = true
        showCustom = recurrence?.weekdays != nil
          || recurrence?.monthDay != nil
          || recurrence?.ordinalWeekday != nil
      }
    }
    .onDisappear { if !confirmed { recurrence = nil } }
  }

  /// Pluralized "N days/weeks/months/years" via the String Catalog (one/other).
  private func intervalLabel() -> String {
    let n = interval.wrappedValue
    switch recurrence?.unit ?? .week {
    case .day:   return String(localized: "\(n) days")
    case .week:  return String(localized: "\(n) weeks")
    case .month: return String(localized: "\(n) months")
    case .year:  return String(localized: "\(n) years")
    }
  }
}
