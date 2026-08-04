import SwiftUI

// The composer's elective-pill rail — the row of Today / When / Deadline /
// Repeat / List / Notes capsules under the title — and the inline panels a
// pill expands into. Split out of TaskComposer.swift.
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
    // Notes IS an elective, but a special one: its pill only shows while notes
    // are empty/unrevealed; selecting it reveals the multi-line notes field
    // above the rail (see `TaskComposerCard.showsNotesField`) rather than
    // expanding an inline panel. Not part of `draftCases` — it's rendered
    // conditionally, like `.attachments`.
    case notes, when, deadline, repeatRule, list, attachments
    /// Edit-mode AI kickoff — rendered separately, not part of `draftCases`.
    case discuss
    var id: Self { self }

    /// Scheduling / filing electives — the `ForEach` rail.
    static let draftCases: [Attribute] = [.when, .deadline, .repeatRule, .list]

    var icon: String {
      switch self {
      case .notes:      "text.alignleft"
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
      case .notes:      "Notes"
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
      // Pills wrap onto extra rows as needed (FlowLayout) so every elective
      // stays visible — no offscreen horizontal scroll. "Today" isn't its own
      // pill: it's the same stored state as When=Today, so it lives inside the
      // When control (quick chip) instead of duplicating the rail. Flat
      // capsule fills (no floating glass) — these sit inline on the form card.
      FlowLayout(spacing: 8) {
        // Notes lead the rail, but only while collapsed — once the field is
        // revealed (notes present or focused) it hosts the notes instead, so
        // the pill and the field are never both on screen.
        if draft.notes.isEmpty, focus != .notes {
          AttributePill(icon: Attribute.notes.icon, label: Attribute.notes.label,
                        value: nil, isSet: false, isActive: false,
                        isFocused: focus == .pill(.notes),
                        accent: accent, neutral: neutral) { revealNotes() }
            .focused($focus, equals: .pill(.notes))
        }
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
    case .notes: return nil
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
    case .notes:      !draft.notes.isEmpty
    case .discuss:    discussWorking
    case .attachments: discussTask.map { SeptenaServices.shared.taskAttachmentStore.attachmentCount(taskID: $0.id) > 0 } ?? false
    case .when:       draft.scheduled != nil || draft.onToday
    case .deadline:   draft.deadline != nil
    case .repeatRule: draft.recurrence != nil
    case .list:       draft.areaId != nil || draft.projectId != nil
    }
  }

  @ViewBuilder
  private var inlineEditor: some View {
    // One transition for every inline panel — they all slide down from the rail.
    Group {
      switch expanded {
      case .when:       InlineWhenPanel(draft: $draft, accent: accent)
      case .deadline:   InlineDatePanel(date: $draft.deadline, accent: accent)
      case .repeatRule: InlineRepeatPanel(recurrence: $draft.recurrence, accent: accent) {
        a11yAnimate(.snappy(duration: 0.22)) { expanded = nil }
      }
      case .attachments:
        if let task = discussTask { TaskAttachmentsPanel(taskID: task.id) }
      // Notes reveals a field above the rail, not an inline panel here.
      case .notes, .discuss, .list, .none: EmptyView()
      }
    }
    .transition(.opacity.combined(with: .move(edge: .top)))
  }

  /// The single dispatch for every pill: sheet-backed pills open their sheet,
  /// inline pills toggle the expanded panel. Per-attribute setup (Repeat seeding
  /// a default, Notes autofocusing) lives in each panel's `onAppear`, so this
  /// stays uniform.
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

  /// Reveal the notes field above the rail and drop the keyboard cursor into
  /// it. `showsNotesField` keys off `focus == .notes`, so this both shows the
  /// field and focuses it in one move.
  private func revealNotes() {
    a11yAnimate(.snappy(duration: 0.22)) { focus = .notes }
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
  /// The keyboard cursor is on this pill — draw the focus ring (the system ring
  /// never shows with macOS keyboard navigation off).
  var isFocused: Bool = false
  let accent: Color
  /// Monochrome rail (inline editor): filled/active pills wear a neutral gray
  /// capsule and the focus ring goes gray, so no section accent leaks into the
  /// open editor. See `TaskAttributeBar.neutral`.
  var neutral: Bool = false
  let action: () -> Void

  /// Capsule fill — flat surface, no floating-glass elevation shadow.
  private var capsuleFill: Color {
    guard isSet || isActive else { return Theme.mutedSurface }
    return neutral ? Theme.inkPrimary.opacity(0.10) : accent.opacity(0.42)
  }
  private var ringColor: Color { neutral ? Theme.selectionNeutral : accent }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: icon)
          .font(.system(size: 12, weight: .semibold))
        // Text follows the value when one exists (so the List pill can read
        // "Inbox" while still untinted); tint stays driven by `isSet`.
        Text(value ?? label)
          .font(.septenaLabel)
          .lineLimit(1)
      }
      .foregroundStyle(isSet ? Theme.inkPrimary : Theme.inkSecondary)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .background(Capsule().fill(capsuleFill))
    .overlay {
      Capsule()
        .strokeBorder(ringColor, lineWidth: 2)
        .opacity(isFocused ? 1 : 0)
        .allowsHitTesting(false)
    }
  }
}

// MARK: - Inline "When" editor

/// The scheduling control — the single home for Today and a planning date, so
/// neither needs its own pill. Quick chips (Today / Tomorrow / Weekend) sit
/// above a graphical calendar; picking today normalizes back to the
/// pinned-Today state. Leaving it unset keeps the task in Anytime. Expanded
/// under the When pill.
private struct InlineWhenPanel: View {
  @Binding var draft: TaskDraft
  let accent: Color
  @Environment(DayClock.self) private var clock

  private var cal: Calendar { Calendar.current }
  private var today: Date {
    cal.startOfDay(for: SeptenaDate.parse(clock.today) ?? clock.now)
  }
  private var tomorrow: Date { cal.date(byAdding: .day, value: 1, to: today) ?? today }
  /// Next Saturday.
  private var weekend: Date {
    var comps = DateComponents(); comps.weekday = 7
    let next = cal.nextDate(after: today, matching: comps, matchingPolicy: .nextTime) ?? today
    return cal.startOfDay(for: next)
  }

  private var isSet: Bool { draft.scheduled != nil || draft.onToday }

  private var calendarBinding: Binding<Date> {
    Binding(get: { draft.scheduled ?? today },
            set: { d in a11yAnimate(.snappy(duration: 0.2)) { draft.setScheduled(d) } })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        chip("Today", active: draft.onToday && draft.scheduled == nil) {
          draft.setToday()
        }
        chip("Tomorrow", active: isSameDay(draft.scheduled, tomorrow)) { draft.setScheduled(tomorrow) }
        chip("Weekend", active: isSameDay(draft.scheduled, weekend)) { draft.setScheduled(weekend) }
      }

      DatePicker("", selection: calendarBinding, displayedComponents: [.date])
        .datePickerStyle(.graphical)
        .tint(accent)

      if isSet {
        Button(role: .destructive) {
          a11yAnimate(.snappy(duration: 0.2)) { draft.clearWhen() }
        } label: {
          Label("Clear", systemImage: "xmark.circle").font(.septenaLabel)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.overdueRed)
      }
    }
    .padding(12)
    .background(Theme.secondaryGroupedBackground,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private func isSameDay(_ a: Date?, _ b: Date) -> Bool {
    a.map { cal.isDate($0, inSameDayAs: b) } ?? false
  }

  @ViewBuilder
  private func chip(_ title: String, active: Bool, _ action: @escaping () -> Void) -> some View {
    Button { a11yAnimate(.snappy(duration: 0.2)) { action() } } label: {
      Text(title)
        .font(.septenaLabel)
        .foregroundStyle(active ? Theme.inkPrimary : Theme.inkSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .background(Capsule().fill(active ? accent.opacity(0.42) : Theme.mutedSurface))
  }
}

// MARK: - Inline date editor

/// A graphical calendar that writes a `Date?`. Selecting a day sets it;
/// "Clear" removes it. Lives inside the composer card when the Deadline pill
/// is expanded.
private struct InlineDatePanel: View {
  @Binding var date: Date?
  let accent: Color
  @Environment(DayClock.self) private var clock

  private var bound: Binding<Date> {
    let anchor = Calendar.current.startOfDay(
      for: SeptenaDate.parse(clock.today) ?? clock.now)
    return Binding(get: { date ?? anchor },
            set: { date = Calendar.current.startOfDay(for: $0) })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      DatePicker("", selection: bound, displayedComponents: [.date])
        .datePickerStyle(.graphical)
        .tint(accent)
      if date != nil {
        Button(role: .destructive) {
          a11yAnimate(.snappy(duration: 0.2)) { date = nil }
        } label: {
          Label("Clear", systemImage: "xmark.circle")
            .font(.septenaLabel)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.overdueRed)
      }
    }
    .padding(12)
    .background(Theme.secondaryGroupedBackground,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

// MARK: - Inline repeat editor

/// Unit + interval + after-completion controls writing a `Recurrence?`, the
/// inline twin of `RecurrencePickerSheet`. Expanded under the Repeat pill.
private struct InlineRepeatPanel: View {
  @Binding var recurrence: Recurrence?
  let accent: Color
  /// Collapse the rail's expanded panel. "Don't Repeat" calls it (clear + close);
  /// owned by `TaskAttributeBar.expanded`.
  var onStop: () -> Void = {}

  /// True once the user actually picks a value here (or the task already
  /// repeated when the panel opened). A panel opened but left untouched reverts
  /// on close — so merely *peeking* at Repeat never commits a recurrence, and
  /// re-tapping the pill (or clicking away) cleanly undoes the open.
  @State private var confirmed = false

  /// Every control write goes through here so any real interaction marks the
  /// recurrence as confirmed (and thus kept on close).
  private func write(_ r: Recurrence) { recurrence = r; confirmed = true }

  private var unit: Binding<Recurrence.Unit> {
    Binding(get: { recurrence?.unit ?? .week },
            set: { write(Recurrence(unit: $0, interval: recurrence?.interval ?? 1,
                                    afterCompletion: recurrence?.afterCompletion ?? true)) })
  }
  private var interval: Binding<Int> {
    Binding(get: { recurrence?.interval ?? 1 },
            set: { write(Recurrence(unit: recurrence?.unit ?? .week, interval: $0,
                                    afterCompletion: recurrence?.afterCompletion ?? true)) })
  }
  private var afterCompletion: Binding<Bool> {
    Binding(get: { recurrence?.afterCompletion ?? true },
            set: { write(Recurrence(unit: recurrence?.unit ?? .week,
                                    interval: recurrence?.interval ?? 1, afterCompletion: $0)) })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Picker("Unit", selection: unit) {
        Text("Day").tag(Recurrence.Unit.day)
        Text("Week").tag(Recurrence.Unit.week)
        Text("Month").tag(Recurrence.Unit.month)
      }
      .pickerStyle(.segmented)

      Stepper(value: interval, in: 1...99) {
        Text("Every \(intervalLabel())")
          .font(.septenaSidebarRow)
          .foregroundStyle(Theme.inkPrimary)
      }

      Toggle("After completion", isOn: afterCompletion)
        .font(.septenaSidebarRow)
        .tint(accent)

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
    .background(Theme.secondaryGroupedBackground,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    // Opening shows a weekly preview so the controls have something to bind, but
    // it's only a peek: `confirmed` stays false until a real edit, and an
    // untouched panel reverts to "no repeat" on close (`onDisappear`). A task
    // that already repeated counts as confirmed, so editing never loses it.
    .onAppear {
      if recurrence == nil { recurrence = Recurrence(unit: .week); confirmed = false }
      else { confirmed = true }
    }
    .onDisappear { if !confirmed { recurrence = nil } }
  }

  /// Pluralized "N days/weeks/months" via the String Catalog (one/other).
  private func intervalLabel() -> String {
    let n = interval.wrappedValue
    switch recurrence?.unit ?? .week {
    case .day:   return String(localized: "\(n) days")
    case .week:  return String(localized: "\(n) weeks")
    case .month: return String(localized: "\(n) months")
    }
  }
}

// MARK: - Inline notes editor

/// A multi-line notes field that writes `draft.notes`, expanded under the Notes
/// pill. Autofocuses on appear (you tapped the pill to write), and offers a
/// "Clear" when there's text — the same shape as the When / Deadline panels.
// MARK: - Presentation
