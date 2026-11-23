import SwiftUI

// The composer's elective-pill rail — a single row of icon + label capsules
// under the title & notes, in the registry's `taskAttributes` order — and the
// inline panels a button expands into. Split out of
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
  /// The composer's Tab loop, handed to the checklist so arrows and Tab walk
  /// out of the steps the same way they walk between them.
  var moveFocus: ((Bool) -> Void)? = nil

  /// The electives. Order, label and icon come from the registry
  /// (`registry/surfaces.json` `taskAttributes`, ADR 0020) so the AppKit
  /// composer and every other client show the same rail; per-attribute
  /// *values* are derived from the draft in `value(for:)` / `isSet(_:)`, and
  /// each editor lives in its own panel. So every pill is wired identically:
  /// one `ForEach`, one `select(_:)`. The raw value is the registry id.
  enum Attribute: String, Identifiable {
    case when, deadline, reminder, repeatRule = "repeat", star, list, tags, checklist, attachments
    /// Edit-mode AI kickoff — shown only before a conversation exists.
    case discuss
    var id: Self { self }

    private var registry: RegistryTaskAttribute { RegistrySurfaces.taskAttribute(rawValue) }

    /// Every pill that ships on this platform, in registry rail order.
    static let rail: [Attribute] = RegistrySurfaces.taskAttributePills(on: RegistryPlatform.current)
      .compactMap { Attribute(rawValue: $0.id) }
    /// The pills a draft without a saved task can use (registry `editOnly` false).
    static let draftCases: [Attribute] = rail.filter { !$0.editOnly }

    var icon: String { registry.sfSymbol }
    var label: String { registry.label }
    /// Needs a saved task (tags, checklist, attachments, discuss).
    var editOnly: Bool { registry.editOnly }
    /// List opens a sheet — a rich, searchable area/project picker reused across
    /// the Tasks surfaces. Every other pill expands an inline panel under the rail.
    var presentsSheet: Bool { self == .list }
  }

  /// Edit-only pill values, read once per render from the live task.
  private struct EditOnlyState {
    let tagNames: [String]
    let stepsDone: Int
    let stepsTotal: Int
    let attachments: Int

    @MainActor init(task: SeptenaTask) {
      let ctx = LocalStore.shared.container.mainContext
      let live = LocalCache.liveTasks(ids: [task.id], in: ctx).first ?? task
      tagNames = LocalCache.resolvedTags(for: live, tagsByID: LocalCache.tagsByID(in: ctx)).map(\.name)
      let steps = LocalCache.checklistItems(forTaskID: task.id, in: ctx)
      stepsDone = steps.filter(\.checked).count
      stepsTotal = steps.count
      attachments = SeptenaServices.shared.taskAttachmentStore.attachmentCount(taskID: task.id)
    }
  }

  /// The currently expanded inline pill (never `.list`, which presents a sheet).
  @State private var expanded: Attribute?
  @State private var showingList = false
  @State private var discussStarted: Bool
  @State private var discussWorking = false
  /// The Checklist pill was tapped on a task with no steps yet. A task WITH
  /// steps shows its checklist without this (same as the Mac composer).
  @State private var checklistOpened = false
  /// Bumped by the Checklist pill while the checklist already shows: the
  /// panel appends a step and focuses it (Mac `appendItemAndFocus`).
  @State private var checklistAddRequest = 0

  init(draft: Binding<TaskDraft>, areas: [Area], projects: [Project], accent: Color,
       neutral: Bool = false, focus: FocusState<TaskEditFocus?>.Binding,
       activate: Binding<Attribute?>, discussTask: SeptenaTask? = nil,
       discussVisible: Binding<Bool> = .constant(false),
       moveFocus: ((Bool) -> Void)? = nil) {
    _draft = draft
    self.areas = areas
    self.projects = projects
    self.accent = accent
    self.neutral = neutral
    _focus = focus
    _activate = activate
    self.discussTask = discussTask
    _discussVisible = discussVisible
    self.moveFocus = moveFocus
    _discussStarted = State(initialValue: discussTask?.conversation.hasStarted ?? true)
  }

  var body: some View {
    let edit = discussTask.map(EditOnlyState.init(task:))
    return VStack(alignment: .leading, spacing: 10) {
      // Steps sit open under the notes whenever the task has any, so opening a
      // task shows its checklist without a tap. The pill only starts one.
      if let task = discussTask, checklistOpened || (edit?.stepsTotal ?? 0) > 0 {
        TaskChecklistPanel(taskID: task.id, addRequest: checklistAddRequest,
                           focus: $focus, moveFocus: moveFocus)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }

      // Horizontal rail of icon + label capsules — scrolls sideways inside its
      // bounded slot so the rail never widens its card past the screen. "Today"
      // lives inside the When control rather than duplicating the rail.
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(Attribute.rail) { attr in
            if shows(attr) {
              AttributePill(icon: attr.icon, label: attr.label,
                            value: value(for: attr, edit: edit), isSet: isSet(attr, edit: edit),
                            isActive: attr != .discuss && expanded == attr,
                            isLoading: attr == .discuss && discussWorking,
                            isFocused: focus == .pill(attr),
                            accent: accent, neutral: neutral) { select(attr) }
                .focused($focus, equals: .pill(attr))
                .disabled(attr == .discuss && discussWorking)
            }
          }
        }
        // Small inset so the capsule glass edge and focus ring don't clip
        // against the scroll viewport's bounds.
        .padding(.vertical, 2)
        .padding(.horizontal, 1)
      }
      .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
      .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

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

  /// Whether a pill is on the rail: edit-only pills need a saved task, and
  /// Discuss only shows before a conversation exists.
  private func shows(_ attr: Attribute) -> Bool {
    if attr == .discuss { return showsDiscuss }
    return !attr.editOnly || discussTask != nil
  }

  /// The value shown on a pill (its `nil` falls back to the plain label). All
  /// values are derived from the draft — the single read-side of the rail.
  private func value(for attr: Attribute, edit: EditOnlyState?) -> String? {
    switch attr {
    case .discuss:
      return discussWorking ? RegistrySurfaces.taskAttribute(attr.rawValue).workingLabel : nil
    case .tags:
      guard let names = edit?.tagNames, !names.isEmpty else { return nil }
      return names.count == 1 ? names[0] : RegistrySurfaces.taskAttributeCount(attr.rawValue, count: names.count)
    case .checklist:
      guard let edit, edit.stepsTotal > 0 else { return nil }
      return "\(edit.stepsDone)/\(edit.stepsTotal)"
    case .attachments:
      guard let count = edit?.attachments, count > 0 else { return nil }
      return RegistrySurfaces.taskAttributeCount(attr.rawValue, count: count)
    // "When" folds in Today: a task pinned to today (no date) reads "Today", a
    // future planning date reads its date, nothing set reads as Anytime (nil).
    case .when:
      let slot = TaskTimeSlot.format(startTime: draft.startTime, durationMinutes: draft.durationMinutes)
      if let s = draft.scheduled {
        let base = Self.dateLabel(s)
        return slot.map { "\(base) · \($0)" } ?? base
      }
      if draft.onToday {
        let today = String(localized: "Today", comment: "Relative date")
        return slot.map { "\(today) · \($0)" } ?? today
      }
      return slot
    case .deadline:
      return draft.deadline.map(Self.dateLabel)
    case .reminder:
      return draft.reminder?.badgeText()?.text
    case .repeatRule:
      return draft.recurrence?.shortLabel
    // The filled pill already says it; no second word for "starred".
    case .star:
      return nil
    // The List pill always names its destination — "Inbox" by default, the area
    // or project once filed (but tinted only when explicitly filed, see isSet).
    case .list:
      return draft.listLabel(areas: areas, projects: projects)
    }
  }

  /// Whether a pill counts as "filled" — drives the accent tint.
  private func isSet(_ attr: Attribute, edit: EditOnlyState?) -> Bool {
    switch attr {
    case .discuss:     discussWorking
    case .tags:        !(edit?.tagNames.isEmpty ?? true)
    case .checklist:   (edit?.stepsTotal ?? 0) > 0
    case .attachments: (edit?.attachments ?? 0) > 0
    case .when:        draft.scheduled != nil || draft.onToday
    case .deadline:    draft.deadline != nil
    case .reminder:    draft.reminder != nil
    case .repeatRule:  draft.recurrence != nil
    case .star:        draft.starred
    case .list:        draft.areaId != nil || draft.projectId != nil
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
      case .when:       InlineWhenPanel(draft: $draft, accent: accent, fill: panelFill)
      case .deadline:   InlineDatePanel(date: $draft.deadline, fill: panelFill)
      case .reminder:   InlineReminderPanel(reminder: $draft.reminder,
                                            accent: accent,
                                            fill: panelFill) {
        a11yAnimate(.snappy(duration: 0.22)) { expanded = nil }
      }
      case .repeatRule: InlineRepeatPanel(recurrence: $draft.recurrence,
                                          hasScheduledDate: draft.scheduled != nil,
                                          scheduledDate: SeptenaDate.format(draft.scheduled),
                                          accent: accent,
                                          fill: panelFill) {
        a11yAnimate(.snappy(duration: 0.22)) { expanded = nil }
      }
      case .tags:
        if let task = discussTask {
          TaskTagsPanel(taskID: task.id, accent: accent, fill: panelFill)
        }
      case .attachments:
        if let task = discussTask { TaskAttachmentsPanel(taskID: task.id) }
      // The checklist is not a pill panel: it renders above the rail.
      case .discuss, .star, .list, .checklist, .none: EmptyView()
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
    if attr == .star {
      focus = .pill(.star)
      Haptics.selection()
      a11yAnimate(.snappy(duration: 0.18)) { draft.starred.toggle() }
      return
    }
    // Checklist: open it (the panel seeds a first blank step and focuses it),
    // or, when it already shows, append a step and focus that.
    if attr == .checklist {
      let showing = checklistOpened
        || discussTask.map { EditOnlyState(task: $0).stepsTotal > 0 } == true
      a11yAnimate(.snappy(duration: 0.22)) {
        expanded = nil
        if showing { checklistAddRequest += 1 } else { checklistOpened = true }
      }
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
    if cal.isDateInToday(d) { return String(localized: "Today", comment: "Relative date") }
    if cal.isDateInTomorrow(d) { return String(localized: "Tomorrow", comment: "Relative date") }
    return SeptenaDate.monthDay(d)
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

  private static let height: CGFloat = 34
  /// A long value (a list name, a tag) truncates at this many characters
  /// instead of making one pill eat the rail. The rail's horizontal scroll
  /// proposes no width, so a frame cap would not truncate; cut the string.
  private static let maxChars = 24
  private var shownText: String {
    let text = value ?? label
    return text.count > Self.maxChars ? String(text.prefix(Self.maxChars - 1)) + "…" : text
  }

  /// Capsule fill — flat surface, no floating-glass elevation shadow.
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
      // Icon + short label (the set value when there is one). An icon alone
      // was too obscure; the rail scrolls, so pills keep their natural width.
      HStack(spacing: 5) {
        if isLoading {
          ProgressView()
            .controlSize(.mini)
        } else {
          Image(systemName: icon)
            .font(.system(size: 13, weight: .semibold))
        }
        Text(shownText)
          .font(.subheadline.weight(.medium))
          .lineLimit(1)
      }
      .foregroundStyle((isSet || isActive) ? Theme.inkPrimary : Theme.inkSecondary)
      .padding(.horizontal, 12)
      .frame(height: Self.height)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .modifier(AttributePillGlassBackground(
      circleFill: circleFill,
      tint: (isSet || isActive) ? (neutral ? Theme.inkPrimary.opacity(isActive ? 0.20 : 0.12) : accent.opacity(isActive ? 0.36 : 0.22)) : nil,
      reduceTransparency: reduceTransparency
    ))
    .overlay {
      Capsule()
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
      content.background(Capsule().fill(circleFill))
    } else {
      #if os(iOS)
      if let tint {
        content.glassEffect(.regular.tint(tint).interactive(), in: .capsule)
      } else {
        content.glassEffect(.regular.interactive(), in: .capsule)
      }
      #else
      content
        .background(.thinMaterial, in: Capsule())
        .background(Capsule().fill(tint ?? .clear))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
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
  let accent: Color
  let fill: Color
  @State private var showTimeControls = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      TaskDateBoard(
        selected: draft.scheduled,
        todayActive: draft.onToday && draft.scheduled == nil,
        clearLabel: (draft.scheduled != nil || draft.onToday || draft.startTime != nil) ? "No Date" : nil,
        onToday: { a11yAnimate(.snappy(duration: 0.2)) { draft.setToday() } },
        onPick: { d in a11yAnimate(.snappy(duration: 0.2)) { draft.setScheduled(d) } },
        onClear: { a11yAnimate(.snappy(duration: 0.2)) { draft.clearWhen(); showTimeControls = false } })

      Divider()

      if showTimeControls || draft.startTime != nil {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Label("Time", systemImage: "clock")
              .font(.septenaLabel)
              .foregroundStyle(Theme.inkPrimary)
            Spacer()
            DatePicker(
              "Start time",
              selection: Binding(
                get: { TaskTimeSlot.pickerDate(from: draft.startTime) },
                set: { newDate in
                  draft.startTime = TaskTimeSlot.hhmm(from: newDate)
                  if !draft.onToday && draft.scheduled == nil { draft.setToday() }
                }
              ),
              displayedComponents: .hourAndMinute
            )
            .labelsHidden()
            Button("Clear") {
              a11yAnimate(.snappy(duration: 0.18)) {
                draft.startTime = nil
                draft.durationMinutes = nil
                showTimeControls = false
              }
            }
            .buttonStyle(.plain)
            .font(.septenaCaption)
            .foregroundStyle(Theme.inkSecondary)
            .contentShape(Rectangle())
          }

          HStack(spacing: 6) {
            ForEach(TaskTimeSlot.quickDurations, id: \.minutes) { preset in
              SelectableChip(preset.label,
                             isSelected: draft.durationMinutes == preset.minutes,
                             tint: accent) {
                Haptics.selection()
                a11yAnimate(.snappy(duration: 0.18)) {
                  if draft.startTime == nil { draft.startTime = "09:00" }
                  if !draft.onToday && draft.scheduled == nil { draft.setToday() }
                  draft.durationMinutes = draft.durationMinutes == preset.minutes ? nil : preset.minutes
                }
              }
            }
            Spacer(minLength: 0)
          }
        }
      } else {
        Button {
          a11yAnimate(.snappy(duration: 0.2)) {
            showTimeControls = true
            if draft.startTime == nil { draft.startTime = "09:00" }
            if !draft.onToday && draft.scheduled == nil { draft.setToday() }
          }
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "clock")
              .scaledFont(size: 12)
            Text("Add time")
              .font(.septenaLabel)
            Spacer(minLength: 0)
          }
          .foregroundStyle(Theme.inkSecondary)
          .padding(.vertical, 2)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(12)
    .background(fill,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .onAppear {
      showTimeControls = draft.startTime != nil
    }
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

// MARK: - Inline reminder editor (TR2)

private struct InlineReminderPanel: View {
  @Binding var reminder: TaskReminder?
  let accent: Color
  let fill: Color
  var onStop: () -> Void = {}

  @State private var pickedDate: Date = DayClock.appNow.addingTimeInterval(3600)
  @State private var mode: TaskReminderMode = .floating
  @State private var showOptions = false
  @State private var notificationsDenied = false

  private func apply(date: Date, mode: TaskReminderMode) {
    pickedDate = date
    self.mode = mode
    reminder = TaskReminder.make(date: date, mode: mode)
    Task {
      let granted = await TaskReminderScheduler.shared.requestAuthorizationIfNeeded()
      notificationsDenied = !granted
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if notificationsDenied {
        Button {
          TaskReminderScheduler.openNotificationSettings()
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "bell.slash")
              .font(.caption.weight(.semibold))
            Text("Notifications are off. Open Settings")
              .font(.caption.weight(.medium))
            Spacer(minLength: 0)
          }
          .foregroundStyle(Theme.overdueRed)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(TaskReminder.quickPresets(), id: \.title) { preset in
            SelectableChip(preset.title, isSelected: false, tint: accent) {
              apply(date: preset.date, mode: mode)
            }
          }
        }
      }

      DatePicker(
        "Remind at",
        selection: Binding(
          get: { pickedDate },
          set: { apply(date: $0, mode: mode) }
        ),
        displayedComponents: [.date, .hourAndMinute]
      )
      .datePickerStyle(.compact)
      .font(.septenaSidebarRow)

      Button {
        a11yAnimate(.snappy(duration: 0.2)) { showOptions.toggle() }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: showOptions ? "chevron.down" : "chevron.right")
            .font(.caption.weight(.semibold))
          Text(showOptions ? "Hide time zone options" : "Time zone options…")
            .font(.caption.weight(.medium))
          Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.inkSecondary)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if showOptions {
        Toggle(
          "Fixed time zone",
          isOn: Binding(
            get: { mode == .fixed },
            set: { isFixed in
              let next: TaskReminderMode = isFixed ? .fixed : .floating
              mode = next
              if reminder != nil {
                apply(date: pickedDate, mode: next)
              }
            }
          )
        )
        .font(.septenaSidebarRow)
        .tint(accent)
      }

      if reminder != nil {
        Button(role: .destructive) {
          reminder = nil
          onStop()
        } label: {
          Label("Clear Reminder", systemImage: "xmark.circle")
            .font(.septenaLabel)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.overdueRed)
      }
    }
    .padding(12)
    .background(fill,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .onAppear {
      if let existing = reminder {
        pickedDate = existing.effectiveFireDate() ?? DayClock.appNow.addingTimeInterval(3600)
        mode = existing.mode
        showOptions = existing.mode == .fixed
      } else {
        pickedDate = TaskReminder.quickPresets().first?.date ?? DayClock.appNow.addingTimeInterval(3600)
        mode = .floating
        showOptions = false
      }
    }
    .task {
      notificationsDenied = await TaskReminderScheduler.shared.authorizationStatus() == .denied
    }
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
        SelectableChip("Weekdays (Mon to Fri)", isSelected: isWeekdays, tint: accent) {
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

// MARK: - Inline Checklist panel

/// The step ⌘K ticks instead of the task: set while a checklist step holds the
/// keyboard, nil otherwise. The task list's ⌘K handler reads it first (same
/// rule as the Mac's `KitChecklistView.toggleFocusedStep`).
@MainActor @Observable
final class FocusedChecklistStep {
  static let shared = FocusedChecklistStep()
  var toggle: (() -> Void)?
}

/// The task's checklist inside the SwiftUI task editor (iPhone, iPad). Drawn
/// and driven like the Mac composer's `KitChecklistView`: steps read as part
/// of the document under the notes (notes-size text, no card), ↑/↓ and Tab
/// walk title → notes → steps → rail, Return inserts below, Backspace on an
/// empty step deletes it, ⌘K ticks the focused step. Move and delete sit in
/// the row's context menu (long-press here, right-click on the Mac), with the
/// same × delete button on the row. Every edit records on `TaskUndo`.
private struct TaskChecklistPanel: View {
  let taskID: String
  /// Each change appends a step and focuses it (the Checklist pill).
  var addRequest: Int = 0
  @FocusState.Binding var focus: TaskEditFocus?
  /// The composer's focus loop (`TaskComposerCard.moveFocus`), which lists
  /// every step between notes and the rail.
  var moveFocus: ((Bool) -> Void)?

  @State private var items: [ChecklistItem] = []
  @State private var drafts: [String: String] = [:]

  private var mutator: TaskMutator { SeptenaServices.shared.taskMutator }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
        checklistRow(item: item, index: idx, total: items.count)
      }

      if !items.isEmpty {
        Button {
          addStep()
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "plus")
              .font(.system(size: 11, weight: .medium))
              .frame(width: 24)
            Text("Add step")
              .font(.septenaLabel)
            Spacer(minLength: 0)
          }
          .foregroundStyle(Theme.inkSecondary)
          .padding(.vertical, 2)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Add checklist step"))
      }
    }
    .onAppear {
      reload()
      if items.isEmpty { addStep() }
    }
    .onChange(of: addRequest) { _, _ in addStep() }
    .onChange(of: focus) { oldValue, newValue in
      if case .step(let id)? = oldValue, newValue != oldValue,
         let item = items.first(where: { $0.id == id }) {
        commitTitle(item)
      }
      publishFocusedStep(newValue)
    }
    .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in
      reload()
    }
    .onDisappear {
      flushAllDrafts()
      FocusedChecklistStep.shared.toggle = nil
    }
  }

  private func checklistRow(item: ChecklistItem, index: Int, total: Int) -> some View {
    let binding = Binding<String>(
      get: { drafts[item.id] ?? item.title },
      set: { newValue in
        // Multi-line paste splits into 1 step per non-empty line.
        if newValue.contains("\n") || newValue.contains("\r") {
          let lines = newValue
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
          if lines.count > 1 {
            splitPaste(item, lines: lines)
            return
          }
          drafts[item.id] = lines.first ?? ""
        } else {
          drafts[item.id] = newValue
        }
      }
    )

    let spokenTitle = item.title.isEmpty ? "Untitled step" : item.title
    let spokenState = item.checked ? "checked" : "unchecked"

    return HStack(spacing: 6) {
      Button {
        toggle(item)
      } label: {
        Image(systemName: item.checked ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 15, weight: .regular))
          .foregroundStyle(item.checked ? Theme.inkSecondary : Theme.iconMuted)
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(Text("\(spokenTitle), checklist item \(index + 1) of \(total), \(spokenState)"))

      TextField("Checklist item", text: binding)
        .textFieldStyle(.plain)
        .font(.septenaTaskTitle)
        .foregroundStyle(item.checked ? Theme.inkSecondary : Theme.inkPrimary)
        .strikethrough(item.checked, color: Theme.inkSecondary)
        .focused($focus, equals: .step(item.id))
        .onSubmit {
          commitTitle(item)
          insertBelow(item)
        }
        .onKeyPress(.upArrow) { moveFocus?(false); return .handled }
        .onKeyPress(.downArrow) { moveFocus?(true); return .handled }
        .onKeyPress(keys: [.tab]) { press in
          moveFocus?(!press.modifiers.contains(.shift)); return .handled
        }
        .onKeyPress(.delete) {
          guard (drafts[item.id] ?? item.title).isEmpty else { return .ignored }
          delete(item, focusPrevious: true)
          return .handled
        }
        .accessibilityLabel(Text("\(spokenTitle), checklist item \(index + 1) of \(total), \(spokenState)"))

      Button {
        delete(item, focusPrevious: false)
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(Theme.iconMuted)
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(Text("Delete step"))
    }
    .contextMenu {
      if index > 0 {
        Button {
          moveOrder(itemID: item.id, delta: -1)
        } label: {
          Label("Move Up", systemImage: "arrow.up")
        }
      }
      if index + 1 < total {
        Button {
          moveOrder(itemID: item.id, delta: 1)
        } label: {
          Label("Move Down", systemImage: "arrow.down")
        }
      }
      Button(role: .destructive) {
        delete(item, focusPrevious: false)
      } label: {
        Label("Delete Step", systemImage: "trash")
      }
    }
  }

  /// ⌘K targets the focused step while one of THIS task's steps holds focus.
  private func publishFocusedStep(_ value: TaskEditFocus?) {
    if case .step(let id)? = value, items.contains(where: { $0.id == id }) {
      FocusedChecklistStep.shared.toggle = { [id] in
        guard let item = items.first(where: { $0.id == id }) else { return }
        toggle(item)
      }
    } else {
      FocusedChecklistStep.shared.toggle = nil
    }
  }

  private func reload() {
    let loaded = LocalCache.checklistItems(forTaskID: taskID, in: LocalStore.shared.container.mainContext)
    items = loaded
    for item in loaded where focus != .step(item.id) {
      drafts[item.id] = item.title
    }
  }

  private func flushAllDrafts() {
    for item in items { commitTitle(item) }
  }

  private func commitTitle(_ item: ChecklistItem) {
    guard let raw = drafts[item.id] else { return }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed != item.title else { return }
    var after = item
    after.title = trimmed
    mutator.updateChecklistItem(id: item.id, title: trimmed)
    TaskUndo.recordChecklistUpdate(before: item, after: after, mutator: mutator)
    if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].title = trimmed }
  }

  private func addStep() {
    flushAllDrafts()
    guard let created = mutator.addChecklistItem(taskID: taskID, title: "") else { return }
    TaskUndo.recordChecklistAdd(created, mutator: mutator)
    drafts[created.id] = ""
    reload()
    focus = .step(created.id)
  }

  private func insertBelow(_ item: ChecklistItem) {
    flushAllDrafts()
    let idx = items.firstIndex(where: { $0.id == item.id }) ?? (items.count - 1)
    let pos: Double?
    if idx + 1 < items.count {
      let mid = (items[idx].position + items[idx + 1].position) / 2.0
      pos = (mid > items[idx].position && mid < items[idx + 1].position) ? mid : nil
    } else {
      pos = nil
    }
    guard let created = mutator.addChecklistItem(taskID: taskID, title: "", position: pos) else { return }
    TaskUndo.recordChecklistAdd(created, mutator: mutator)
    drafts[created.id] = ""
    reload()
    focus = .step(created.id)
  }

  private func toggle(_ item: ChecklistItem) {
    flushAllDrafts()
    Haptics.commit()
    var after = item
    after.checked.toggle()
    mutator.updateChecklistItem(id: item.id, checked: after.checked)
    TaskUndo.recordChecklistUpdate(before: item, after: after, mutator: mutator)
    a11yAnimate(.snappy(duration: 0.18)) { reload() }
  }

  private func moveOrder(itemID: String, delta: Int) {
    flushAllDrafts()
    guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
    let target = idx + delta
    guard items.indices.contains(target) else { return }
    let beforeIDs = items.map(\.id)
    var afterIDs = beforeIDs
    afterIDs.swapAt(idx, target)
    mutator.reorderChecklistItems(taskID: taskID, orderedIDs: afterIDs)
    TaskUndo.recordChecklistReorder(taskID: taskID, beforeIDs: beforeIDs, afterIDs: afterIDs, mutator: mutator)
    a11yAnimate(.snappy(duration: 0.18)) { reload() }
  }

  private func delete(_ item: ChecklistItem, focusPrevious: Bool) {
    let idx = items.firstIndex(where: { $0.id == item.id })
    let prevID = idx.flatMap { $0 > 0 ? items[$0 - 1].id : nil }
    let hadFocus = focus == .step(item.id)
    drafts.removeValue(forKey: item.id)
    mutator.deleteChecklistItem(id: item.id)
    TaskUndo.recordChecklistDelete(item, mutator: mutator)
    a11yAnimate(.snappy(duration: 0.18)) { reload() }
    if hadFocus { focus = (focusPrevious ? prevID : nil).map { .step($0) } }
  }

  private func splitPaste(_ item: ChecklistItem, lines: [String]) {
    guard let first = lines.first else { return }
    drafts[item.id] = first
    commitTitle(item)
    let rest = Array(lines.dropFirst())
    guard !rest.isEmpty else { return }
    let idx = items.firstIndex(where: { $0.id == item.id }) ?? (items.count - 1)
    let belowPos = idx + 1 < items.count
      ? items[idx + 1].position
      : (items[idx].position + TaskOrder.gap * Double(rest.count + 1))
    let span = belowPos - items[idx].position
    var lastID = item.id
    for (offset, text) in rest.enumerated() {
      let pos = items[idx].position + span * Double(offset + 1) / Double(rest.count + 1)
      if let created = mutator.addChecklistItem(taskID: taskID, title: text, position: pos) {
        TaskUndo.recordChecklistAdd(created, mutator: mutator)
        drafts[created.id] = text
        lastID = created.id
      }
    }
    reload()
    focus = .step(lastID)
  }
}

// MARK: - Inline Tags panel

/// Progressive-disclosure inline tags editor inside the SwiftUI task editor
/// (iOS/iPadOS & SwiftUI sheets). Shows tap-to-toggle chips, an inline
/// "New tag…" field, and a quiet "Manage…" sheet trigger.
private struct TaskTagsPanel: View {
  let taskID: String
  let accent: Color
  let fill: Color

  @State private var allTags: [TaskTag] = []
  @State private var assignedIDs: [String] = []
  @State private var newTagName: String = ""
  @State private var showingManageTags = false

  private var mutator: TaskMutator { SeptenaServices.shared.taskMutator }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !allTags.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(allTags) { tag in
              let assigned = assignedIDs.contains(tag.id)
              SelectableChip(isSelected: assigned,
                             tint: tag.color != nil ? TagColorPalette.color(for: tag.color) : accent) {
                toggle(tag)
              } label: {
                HStack(spacing: 4) {
                  if tag.color != nil {
                    Circle()
                      .fill(TagColorPalette.color(for: tag.color))
                      .frame(width: 6, height: 6)
                  }
                  Text(tag.name)
                }
              }
            }
          }
        }
      }

      HStack(spacing: 8) {
        Image(systemName: "plus")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Theme.inkSecondary)
        TextField("New tag…", text: $newTagName)
          .textFieldStyle(.plain)
          .font(.septenaLabel)
          .onSubmit { createAndAssign() }
        if !newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Button("Add") { createAndAssign() }
            .buttonStyle(.plain)
            .font(.septenaLabel)
            .foregroundStyle(Theme.inkPrimary)
            .contentShape(Rectangle())
        } else if !allTags.isEmpty {
          Button("Manage…") { showingManageTags = true }
            .buttonStyle(.plain)
            .font(.septenaCaption)
            .foregroundStyle(Theme.inkSecondary)
            .contentShape(Rectangle())
        }
      }
      .padding(.top, allTags.isEmpty ? 0 : 2)
    }
    .padding(12)
    .background(fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .sheet(isPresented: $showingManageTags, onDismiss: reload) {
      ManageTagsSheet()
    }
    .onAppear { reload() }
    .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in reload() }
  }

  private func reload() {
    let ctx = LocalStore.shared.container.mainContext
    allTags = LocalCache.allTags(in: ctx)
    assignedIDs = LocalCache.liveTasks(ids: [taskID], in: ctx).first?.tags ?? []
  }

  private func toggle(_ tag: TaskTag) {
    let before = assignedIDs
    let after = before.contains(tag.id)
      ? before.filter { $0 != tag.id }
      : before + [tag.id]
    Haptics.commit()
    mutator.setTaskTags(id: taskID, tagIDs: after)
    TaskUndo.recordTaskTags(before: [taskID: before], after: [taskID: after], mutator: mutator)
    a11yAnimate(.snappy(duration: 0.18)) { reload() }
  }

  private func createAndAssign() {
    let trimmed = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if let existing = allTags.first(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
      if !assignedIDs.contains(existing.id) { toggle(existing) }
      newTagName = ""
      return
    }
    guard let created = mutator.createTag(name: trimmed) else { return }
    TaskUndo.recordTagCreate(created, mutator: mutator)
    let before = assignedIDs
    let after = before + [created.id]
    mutator.setTaskTags(id: taskID, tagIDs: after)
    TaskUndo.recordTaskTags(before: [taskID: before], after: [taskID: after], mutator: mutator)
    newTagName = ""
    reload()
  }
}
