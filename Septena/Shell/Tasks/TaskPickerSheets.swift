import SwiftUI

// The three modal pickers a task row can open — When (date), Repeat
// (recurrence), and Move (area/project). Self-contained sheet UI; split out of
// TaskComponents.swift, which was carrying them alongside the row primitives.

// MARK: - Date picker sheet

/// Shared picker for both "When" (scheduled) and "Deadline" (due) — the modal
/// wrapper around `TaskDateBoard`, which owns the layout and is the same board
/// the composer's When and Deadline pills expand and the AppKit shell's ⌘S /
/// ⌘⇧D popover mirrors.
///
/// Only the title and the clear label differ between When and Deadline. Each
/// control commits and dismisses, so there is no confirm button. What this
/// replaced: a four-chip quick row (Today / Tomorrow / This weekend / Next
/// week) above a strip that ALREADY held every one of those days — Today
/// appeared twice — plus a "Set Date · Wed, Jul 8" button only the calendar
/// path needed. The separate Today row went the same way; today is the
/// strip's first cell.
struct DatePickerSheet: View {
  @Environment(DayClock.self) private var clock
  let title: String
  let initialDate: Date?
  let clearLabel: String      // e.g. "No Date" / "Remove Deadline"
  let onPick: (Date?) -> Void
  @Environment(\.dismiss) private var dismiss

  private var cal: Calendar { Calendar.current }
  private var anchorDay: Date {
    cal.startOfDay(for: SeptenaDate.parse(clock.today) ?? clock.now)
  }

  /// Fitted sheet height: 7-day strip (today first) + calendar button + Clear.
  /// `.large` stays available as a drag-up fallback for big Dynamic Type.
  static let sheetHeight: CGFloat = 276

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        TaskDateBoard(
          selected: initialDate.map { cal.startOfDay(for: $0) },
          todayActive: initialDate.map { cal.isDate($0, inSameDayAs: anchorDay) } ?? false,
          clearLabel: clearLabel,
          onToday: { commit(anchorDay) },
          onPick: { commit($0) },
          onClear: { commit(nil) })
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 6)

        Spacer(minLength: 0)
      }
      .padding(.bottom, 12)
      .navigationTitle(title)
      .septenaInlineTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
    .macSheetFrame(width: 420, height: Self.sheetHeight + 60)
  }

  private func commit(_ day: Date?) {
    onPick(day.map { cal.startOfDay(for: $0) })
    dismiss()
  }
}

// MARK: - Reminder picker sheet (TR2)

/// Progressive-disclosure Reminder sheet for iOS/iPadOS row context menus.
struct ReminderPickerSheet: View {
  @Environment(SectionTheme.self) private var theme
  let initial: TaskReminder?
  let onPick: (TaskReminder?) -> Void
  @Environment(\.dismiss) private var dismiss

  @State private var pickedDate: Date
  @State private var mode: TaskReminderMode
  @State private var showOptions: Bool
  @State private var notificationsDenied = false

  init(initial: TaskReminder?, onPick: @escaping (TaskReminder?) -> Void) {
    self.initial = initial
    self.onPick = onPick
    let defaultDate = initial?.effectiveFireDate()
      ?? TaskReminder.quickPresets().first?.date
      ?? DayClock.appNow.addingTimeInterval(3600)
    _pickedDate = State(initialValue: defaultDate)
    _mode = State(initialValue: initial?.mode ?? .floating)
    _showOptions = State(initialValue: initial?.mode == .fixed)
  }

  private func save(_ reminder: TaskReminder?) {
    if reminder != nil {
      Task { await TaskReminderScheduler.shared.requestAuthorizationIfNeeded() }
    }
    onPick(reminder)
    dismiss()
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if notificationsDenied {
            Button {
              TaskReminderScheduler.openNotificationSettings()
            } label: {
              HStack(spacing: 8) {
                Image(systemName: "bell.slash")
                Text("Notifications are off — Open Settings")
                  .font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
              }
              .foregroundStyle(Theme.overdueRed)
              .padding(12)
              .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 12))
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }

          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
              ForEach(TaskReminder.quickPresets(), id: \.title) { preset in
                SelectableChip(preset.title, isSelected: false, tint: theme.accent) {
                  save(TaskReminder.make(date: preset.date, mode: mode))
                }
              }
            }
          }

          VStack(alignment: .leading, spacing: 12) {
            DatePicker(
              "Remind at",
              selection: $pickedDate,
              displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)

            Button {
              a11yAnimate(.snappy(duration: 0.2)) { showOptions.toggle() }
            } label: {
              HStack(spacing: 6) {
                Image(systemName: showOptions ? "chevron.down" : "chevron.right")
                  .font(.caption.weight(.semibold))
                Text(showOptions ? "Hide time zone options" : "Time zone options…")
                  .font(.subheadline.weight(.medium))
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
                  set: { mode = $0 ? .fixed : .floating }
                )
              )
              .tint(theme.accent)
            }
          }
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 12)
      }

      HStack(spacing: 10) {
        if initial != nil {
          Button {
            Haptics.warning()
            save(nil)
          } label: {
            Text("Clear Reminder")
          }
          .buttonStyle(.bordered)
          .tint(Theme.inkPrimary)
        }

        Spacer(minLength: 0)

        Button("Cancel") { dismiss() }
          .buttonStyle(.bordered)

        Button("Save") {
          save(TaskReminder.make(date: pickedDate, mode: mode))
        }
        .buttonStyle(.borderedProminent)
        .tint(theme.accent)
      }
      .padding(.horizontal, Theme.hPadding)
      .padding(.vertical, 14)
      .navigationTitle("Reminder")
      .septenaInlineTitle()
    }
    .macSheetFrame(width: 440, height: 340)
    .task {
      notificationsDenied = await TaskReminderScheduler.shared.authorizationStatus() == .denied
    }
  }
}

// MARK: - Recurrence picker sheet

/// "Repeat" — set or clear a recurrence rule. The iOS and AppKit editors use
/// the same compact Things-inspired structure: a mode picker in the heading,
/// one explanatory rule card, and a small action footer.
struct RecurrencePickerSheet: View {
  @Environment(SectionTheme.self) private var theme
  let initial: Recurrence?
  /// A fixed-schedule rule anchors on the task's scheduled date. Without one it
  /// silently degrades into an after-completion rule, so the toggle is held ON
  /// and explained rather than offering a choice that doesn't do what it says.
  var hasScheduledDate: Bool = true
  /// Optional YYYY-MM-DD scheduled date for live "Next: …" preview.
  var scheduledDate: String? = nil
  let initialPaused: Bool
  let onPick: (Recurrence?) -> Void
  let onPauseChanged: ((Bool) -> Void)?
  @Environment(\.dismiss) private var dismiss

  private enum MonthlyMode: Int, CaseIterable {
    case anchor = 0
    case dayOfMonth = 1
    case ordinal = 2
  }

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

  @State private var unit: Recurrence.Unit
  @State private var interval: Int
  @State private var afterCompletion: Bool
  @State private var paused: Bool
  @State private var weekdays: Set<Int>
  @State private var monthlyMode: MonthlyMode
  @State private var monthDay: Int
  @State private var ordinal: Int
  @State private var ordinalWeekdayNum: Int
  @State private var showCustom: Bool

  init(initial: Recurrence?, onPick: @escaping (Recurrence?) -> Void) {
    self.init(initial: initial, hasScheduledDate: true, scheduledDate: nil,
              initialPaused: false, onPick: onPick, onPauseChanged: nil)
  }

  init(initial: Recurrence?, hasScheduledDate: Bool,
       scheduledDate: String? = nil,
       initialPaused: Bool = false,
       onPick: @escaping (Recurrence?) -> Void,
       onPauseChanged: ((Bool) -> Void)? = nil) {
    self.initial = initial
    self.hasScheduledDate = hasScheduledDate
    self.scheduledDate = scheduledDate
    self.initialPaused = initialPaused
    self.onPick = onPick
    self.onPauseChanged = onPauseChanged
    _unit = State(initialValue: initial?.unit ?? .day)
    _interval = State(initialValue: initial?.interval ?? 1)
    // With no date the effective anchor IS completion — show what will happen.
    _afterCompletion = State(initialValue: hasScheduledDate ? (initial?.afterCompletion ?? true) : true)
    _paused = State(initialValue: initialPaused)
    _weekdays = State(initialValue: Set(initial?.weekdays ?? []))
    let anchor = scheduledDate.flatMap(SeptenaDate.parse) ?? DayClock.appNow
    let cal = Calendar.current
    let anchorDay = cal.component(.day, from: anchor)
    let anchorOrdinal = min(4, max(1, (anchorDay - 1) / 7 + 1))
    let anchorWeekday = cal.component(.weekday, from: anchor)
    if let ow = initial?.ordinalWeekday {
      _monthlyMode = State(initialValue: .ordinal)
      _monthDay = State(initialValue: anchorDay)
      _ordinal = State(initialValue: ow.ordinal)
      _ordinalWeekdayNum = State(initialValue: ow.weekday)
    } else if let md = initial?.monthDay {
      _monthlyMode = State(initialValue: .dayOfMonth)
      _monthDay = State(initialValue: md)
      _ordinal = State(initialValue: anchorOrdinal)
      _ordinalWeekdayNum = State(initialValue: anchorWeekday)
    } else {
      _monthlyMode = State(initialValue: .anchor)
      _monthDay = State(initialValue: anchorDay)
      _ordinal = State(initialValue: anchorOrdinal)
      _ordinalWeekdayNum = State(initialValue: anchorWeekday)
    }
    let hasCustom = initial?.weekdays != nil
      || initial?.monthDay != nil
      || initial?.ordinalWeekday != nil
    _showCustom = State(initialValue: hasCustom)
  }

  private var candidateRecurrence: Recurrence {
    let fixed = hasScheduledDate && !afterCompletion
    let resolvedWeekdays: [Int]? = (fixed && unit == .week && !weekdays.isEmpty)
      ? weekdays.sorted() : nil
    let resolvedMonthDay: Int? = (fixed && (unit == .month || unit == .year) && monthlyMode == .dayOfMonth)
      ? monthDay : nil
    let resolvedOrdinal: RecurrenceOrdinalWeekday? = (fixed && (unit == .month || unit == .year) && monthlyMode == .ordinal)
      ? RecurrenceOrdinalWeekday(ordinal: ordinal, weekday: ordinalWeekdayNum) : nil
    return Recurrence(unit: unit,
                      interval: interval,
                      afterCompletion: fixed ? false : true,
                      weekdays: resolvedWeekdays,
                      monthDay: resolvedMonthDay,
                      ordinalWeekday: resolvedOrdinal)
  }

  private var supportsCustomOptions: Bool {
    hasScheduledDate && !afterCompletion && (unit == .week || unit == .month || unit == .year)
  }

  private var nextPreviewLabel: String? {
    guard let wire = candidateRecurrence.nextDate(completedOn: DayClock.appToday,
                                                  scheduled: scheduledDate),
          let date = SeptenaDate.parse(wire) else { return nil }
    return Self.nextPreviewFormatter.string(from: date)
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 0) {
          HStack(spacing: 10) {
            ZStack {
              Circle()
                .fill(theme.accent.opacity(0.18))
              Image(systemName: "arrow.clockwise")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.accent)
            }
            .frame(width: 30, height: 30)

            Text("Repeat")
              .font(.system(size: 18, weight: .semibold))
              .foregroundStyle(Theme.inkPrimary)

            Spacer(minLength: 8)

            if hasScheduledDate {
              Picker("Repeat", selection: $afterCompletion) {
                Text("after completion").tag(true)
                Text("on scheduled date").tag(false)
              }
              .pickerStyle(.menu)
              .tint(Theme.inkPrimary)
            } else {
              Text("after completion")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.inkPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 8))
            }
          }
          .padding(.horizontal, Theme.hPadding)
          .padding(.top, 16)

          // Quick preset strip — calm defaults with 1-tap Weekdays & Yearly.
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
              SelectableChip("Daily",
                             isSelected: unit == .day && interval == 1,
                             tint: theme.accent) {
                unit = .day; interval = 1; weekdays = []; monthlyMode = .anchor
              }
              if hasScheduledDate {
                SelectableChip("Weekdays",
                               isSelected: !afterCompletion && unit == .week && interval == 1
                                 && weekdays == Set([2, 3, 4, 5, 6]),
                               tint: theme.accent) {
                  unit = .week; interval = 1; afterCompletion = false
                  weekdays = Set([2, 3, 4, 5, 6]); monthlyMode = .anchor
                }
              }
              SelectableChip("Weekly",
                             isSelected: unit == .week && interval == 1 && weekdays.isEmpty,
                             tint: theme.accent) {
                unit = .week; interval = 1; weekdays = []; monthlyMode = .anchor
              }
              SelectableChip("Monthly",
                             isSelected: unit == .month && interval == 1 && monthlyMode == .anchor,
                             tint: theme.accent) {
                unit = .month; interval = 1; weekdays = []; monthlyMode = .anchor
              }
              SelectableChip("Yearly",
                             isSelected: unit == .year && interval == 1 && monthlyMode == .anchor,
                             tint: theme.accent) {
                unit = .year; interval = 1; weekdays = []; monthlyMode = .anchor
              }
            }
            .padding(.horizontal, Theme.hPadding)
          }
          .padding(.top, 12)

          VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
              Text("\(interval)")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.inkPrimary)
                .frame(width: 44, height: 38)
                .background(Theme.paperBackground, in: RoundedRectangle(cornerRadius: 10))

              Stepper("", value: $interval, in: 1...99)
                .labelsHidden()

              Picker("Unit", selection: $unit) {
                Text(interval == 1 ? "day" : "days").tag(Recurrence.Unit.day)
                Text(interval == 1 ? "week" : "weeks").tag(Recurrence.Unit.week)
                Text(interval == 1 ? "month" : "months").tag(Recurrence.Unit.month)
                Text(interval == 1 ? "year" : "years").tag(Recurrence.Unit.year)
              }
              .pickerStyle(.menu)
              .tint(Theme.inkPrimary)

              Text(cadenceDescription())
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.inkPrimary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if supportsCustomOptions {
              Button {
                a11yAnimate(.snappy(duration: 0.2)) { showCustom.toggle() }
              } label: {
                HStack(spacing: 6) {
                  Image(systemName: showCustom ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                  Text(showCustom ? "Hide custom options" : "Custom options…")
                    .font(.subheadline.weight(.medium))
                  Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.inkSecondary)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)

              if showCustom {
                if unit == .week {
                  HStack(spacing: 6) {
                    ForEach(Self.weekdayPills, id: \.day) { item in
                      SelectableChip(item.short,
                                     isSelected: weekdays.contains(item.day),
                                     tint: theme.accent,
                                     shape: .roundedRect,
                                     fillsWidth: true) {
                        if weekdays.contains(item.day) {
                          weekdays.remove(item.day)
                        } else {
                          weekdays.insert(item.day)
                        }
                      }
                      .accessibilityLabel(item.full)
                    }
                  }
                } else if unit == .month || unit == .year {
                  Picker("Monthly rule", selection: $monthlyMode) {
                    Text("Same day").tag(MonthlyMode.anchor)
                    Text("On day").tag(MonthlyMode.dayOfMonth)
                    Text("Ordinal").tag(MonthlyMode.ordinal)
                  }
                  .pickerStyle(.segmented)

                  if monthlyMode == .dayOfMonth {
                    HStack(spacing: 8) {
                      Text("Day")
                        .font(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                      Picker("Day of month", selection: $monthDay) {
                        ForEach(1...31, id: \.self) { day in
                          Text("\(day)").tag(day)
                        }
                        Text("Last day").tag(-1)
                      }
                      .pickerStyle(.menu)
                      .tint(Theme.inkPrimary)
                    }
                  } else if monthlyMode == .ordinal {
                    HStack(spacing: 8) {
                      Text("On the")
                        .font(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                      Picker("Ordinal", selection: $ordinal) {
                        ForEach(Self.ordinalChoices, id: \.value) { item in
                          Text(item.label).tag(item.value)
                        }
                      }
                      .pickerStyle(.menu)
                      .tint(Theme.inkPrimary)

                      Picker("Weekday", selection: $ordinalWeekdayNum) {
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

            if let next = nextPreviewLabel {
              Text("\(candidateRecurrence.shortLabel) · Next: \(next)")
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
          }
          .padding(18)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 16))
          .padding(.horizontal, Theme.hPadding)
          .padding(.top, 12)

          if initial != nil, let onPauseChanged {
            Button {
              paused.toggle()
              onPauseChanged(paused)
            } label: {
              Label(paused ? "Resume Repeat" : "Pause Repeat",
                    systemImage: paused ? "play.circle" : "pause.circle")
            }
            .buttonStyle(.bordered)
            .tint(theme.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.hPadding)
            .padding(.top, 12)
          }
        }
      }

      HStack(spacing: 10) {
        if initial != nil {
          Button {
            Haptics.warning()
            onPick(nil)
            dismiss()
          } label: {
            Text("Don't Repeat")
          }
          .buttonStyle(.bordered)
          .tint(Theme.inkPrimary)
        }

        Spacer(minLength: 0)

        Button("Cancel") { dismiss() }
          .buttonStyle(.bordered)

        Button("OK") {
          onPick(candidateRecurrence)
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .tint(theme.accent)
      }
      .padding(.horizontal, Theme.hPadding)
      .padding(.vertical, 14)
      .navigationTitle("Repeat")
      .septenaInlineTitle()
    }
    .macSheetFrame(width: 520, height: 400)
  }

  private func cadenceDescription() -> String {
    afterCompletion
      ? "after it’s checked off."
      : "after the scheduled date."
  }
}

// MARK: - Move picker sheet

struct MovePickerSheet: View {
  let areas: [Area]
  let projects: [Project]
  var currentAreaId: String? = nil
  var currentProjectId: String? = nil
  /// The Inbox row is not useful when every selected task is already there.
  var hidesInboxTarget: Bool = false
  /// When moving multiple tasks, hides the single-row highlight and retitles the sheet.
  var bulkCount: Int = 1
  let onPick: (_ areaId: String?, _ projectId: String?) -> Void
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @State private var query = ""
  // Real done/(done+open) ratio per project id, so the pie glyph matches the
  // sidebar instead of a placeholder. Loaded once on appear.
  @State private var progressByProject: [String: Double] = [:]

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 4) {
          // Inbox first — drop both area and project.
          if !hidesInboxTarget && matches("Inbox") {
            row(.inbox, title: "Inbox",
                selected: showCurrentSelection && currentAreaId == nil && currentProjectId == nil) {
              onPick(nil, nil); dismiss()
            }
          }

          // Top-level projects (no area)
          ForEach(filteredTopProjects) { p in
            row(.project, title: p.title, projectId: p.id,
                selected: showCurrentSelection && p.id == currentProjectId) {
              onPick(nil, p.id); dismiss()
            }
          }

          // Areas with their projects nested directly underneath, mirroring
          // the sidebar's hierarchy.
          ForEach(filteredAreas) { area in
            row(.area, title: area.title, emoji: area.emoji,
                selected: showCurrentSelection && currentProjectId == nil && area.id == currentAreaId) {
              onPick(area.id, nil); dismiss()
            }
            ForEach(projectsIn(area.id)) { p in
              row(.project, title: p.title, projectId: p.id,
                  selected: showCurrentSelection && p.id == currentProjectId, indent: true) {
                onPick(area.id, p.id); dismiss()
              }
            }
          }
        }
        .padding(.vertical, 8)
      }
      .background(Theme.paperBackground)
      .task { loadProgress() }
      .septenaAlwaysVisibleSearch(text: $query)
      .navigationTitle(bulkCount > 1 ? "Move \(bulkCount) Tasks" : "Move")
      .septenaInlineTitle()
      .toolbar {
        // Picking a row is the commit; the only other choice is to leave
        // without moving, so the toolbar offers Cancel, not a no-op Done.
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
    .macSheetFrame(width: 460, height: 520)
  }

  // MARK: - Filtering

  private var showCurrentSelection: Bool { bulkCount == 1 }

  private var q: String { query.lowercased() }

  private func matches(_ s: String) -> Bool {
    q.isEmpty || s.lowercased().contains(q)
  }

  private var filteredTopProjects: [Project] {
    projects.filter { $0.area == nil && $0.status == .active && matches($0.title) }
  }

  private var filteredAreas: [Area] {
    areas.filter { area in
      matches(area.title) || !projectsIn(area.id).isEmpty
    }
  }

  private func projectsIn(_ areaId: String) -> [Project] {
    projects.filter { $0.area == areaId && $0.status == .active && matches($0.title) }
  }

  // MARK: - Progress

  // done / (done + open) per project, mirroring the sidebar's aggregate so the
  // pie glyph reads identically here. Cancelled tasks count toward neither side.
  private func loadProgress() {
    var done: [String: Int] = [:]
    var total: [String: Int] = [:]
    for t in LocalCache.tasksWithProject(in: modelContext) {
      guard let pid = t.project else { continue }
      switch t.status {
      case .done: done[pid, default: 0] += 1; total[pid, default: 0] += 1
      case .open: total[pid, default: 0] += 1
      case .cancelled: break
      }
    }
    progressByProject = total.reduce(into: [:]) { acc, kv in
      acc[kv.key] = Double(done[kv.key] ?? 0) / Double(kv.value)
    }
  }

  // MARK: - Row primitive

  private enum RowKind { case inbox, area, project }

  @ViewBuilder
  private func row(_ kind: RowKind, title: String, projectId: String? = nil,
                   emoji: String? = nil, selected: Bool,
                   indent: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: { Haptics.pick(); action() }) {
      HStack(spacing: 12) {
        icon(for: kind, projectId: projectId, emoji: emoji)
          .frame(width: 24, alignment: .center)
        Text(title)
          .scaledFont(size: 16, weight: kind == .area ? .semibold : .regular)
          .foregroundStyle(Theme.inkPrimary)
        Spacer()
        if selected {
          Image(systemName: "checkmark")
            .scaledFont(size: 14, weight: .semibold)
            .foregroundStyle(Theme.inkSecondary)
        }
      }
      .padding(.leading, indent ? Theme.hPadding + 24 : Theme.hPadding)
      .padding(.trailing, Theme.hPadding)
      .padding(.vertical, 2)
      .frame(minHeight: 40)
      .contentShape(Rectangle())
      .background {
        if selected {
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Theme.mutedSurface)
        }
      }
    }
    .buttonStyle(PlainHoverRowButtonStyle())
  }

  @ViewBuilder
  private func icon(for kind: RowKind, projectId: String? = nil, emoji: String? = nil) -> some View {
    switch kind {
    case .inbox:
      Image(systemName: "tray.fill")
        .scaledFont(size: 16)
        .foregroundStyle(Theme.iconMuted)
    case .area:
      AreaIcon(diameter: 14, lineWidth: 1.5, emoji: emoji)
    case .project:
      // Pie glyph — same component as sidebar / detail page, driven by the
      // project's real done/open ratio.
      ProjectProgressIcon(progress: projectId.flatMap { progressByProject[$0] } ?? 0,
                          tint: Theme.inkSecondary, diameter: 14)
    }
  }
}

// MARK: - Tag colors, picker & Manage Tags sheet (docs/TAGS_SPEC.md)

enum TagColorPalette {
  struct Swatch: Identifiable, Hashable {
    let id: String
    let label: String
    let token: String?
    let color: Color
  }

  static let swatches: [Swatch] = [
    Swatch(id: "neutral", label: "Default", token: nil, color: Theme.inkSecondary),
    Swatch(id: "blue", label: "Blue", token: "blue", color: .blue),
    Swatch(id: "amber", label: "Amber", token: "amber", color: .orange),
    Swatch(id: "green", label: "Green", token: "green", color: .green),
    Swatch(id: "red", label: "Red", token: "red", color: .red),
    Swatch(id: "purple", label: "Purple", token: "purple", color: .purple),
    Swatch(id: "teal", label: "Teal", token: "teal", color: .teal),
    Swatch(id: "pink", label: "Pink", token: "pink", color: .pink),
  ]

  static func color(for token: String?) -> Color {
    swatches.first { $0.token == token }?.color ?? Theme.inkSecondary
  }

  #if os(macOS)
  static func nsColor(for token: String?) -> NSColor {
    switch token {
    case "blue":   return .systemBlue
    case "amber":  return .systemOrange
    case "green":  return .systemGreen
    case "red":    return .systemRed
    case "purple": return .systemPurple
    case "teal":   return .systemTeal
    case "pink":   return .systemPink
    default:       return .secondaryLabelColor
    }
  }
  #endif
}

/// Modal tag picker for assigning tags to one or more tasks (iOS/SwiftUI
/// context menu & batch bar). Supports tap-to-toggle chips, inline create on
/// Return, and quick access to Manage Tags.
struct TagPickerSheet: View {
  let taskIDs: [String]
  let onDone: (() -> Void)?

  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext

  @State private var allTags: [TaskTag] = []
  @State private var newTagName: String = ""
  @State private var showingManageTags = false
  @FocusState private var fieldFocused: Bool

  private var mutator: TaskMutator { SeptenaServices.shared.taskMutator }

  init(taskIDs: [String], onDone: (() -> Void)? = nil) {
    self.taskIDs = taskIDs
    self.onDone = onDone
  }

  private var filteredTags: [TaskTag] {
    let q = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return allTags }
    return allTags.filter { $0.name.localizedCaseInsensitiveContains(q) }
  }

  private func currentTagSets() -> [String: [String]] {
    // Fetch only the selected tasks, not every task in the store.
    var out: [String: [String]] = [:]
    for t in LocalCache.liveTasks(ids: taskIDs, in: modelContext) { out[t.id] = t.tags }
    return out
  }

  private func assignmentState(for tagID: String) -> AssignmentState {
    let sets = currentTagSets()
    guard !sets.isEmpty else { return .none }
    let count = sets.values.filter { $0.contains(tagID) }.count
    if count == 0 { return .none }
    if count == sets.count { return .all }
    return .some
  }

  private enum AssignmentState { case none, some, all }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 8) {
          Image(systemName: "tag")
            .foregroundStyle(Theme.inkSecondary)
          TextField("Filter or create tag…", text: $newTagName)
            .textFieldStyle(.plain)
            .focused($fieldFocused)
            .onSubmit { createOrToggleFromField() }
          if !newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button("Add") { createOrToggleFromField() }
              .buttonStyle(.plain)
              .font(.septenaLabel)
              .foregroundStyle(Theme.inkPrimary)
              .contentShape(Rectangle())
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.mutedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, Theme.hPadding)

        if filteredTags.isEmpty && newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          VStack(spacing: 6) {
            Text("No tags yet")
              .font(.septenaLabel)
              .foregroundStyle(Theme.inkSecondary)
            Text("Type a name above and press Return to create your first tag.")
              .font(.septenaCaption)
              .foregroundStyle(Theme.inkSecondary)
              .multilineTextAlignment(.center)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 28)
          .padding(.horizontal, Theme.hPadding)
        } else {
          ScrollView {
            VStack(spacing: 2) {
              ForEach(filteredTags) { tag in
                let state = assignmentState(for: tag.id)
                Button {
                  toggle(tag)
                } label: {
                  HStack(spacing: 10) {
                    Circle()
                      .fill(TagColorPalette.color(for: tag.color))
                      .frame(width: 8, height: 8)
                    Text(tag.name)
                      .font(.septenaLabel)
                      .foregroundStyle(Theme.inkPrimary)
                    Spacer()
                    if state == .all {
                      Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.inkPrimary)
                    } else if state == .some {
                      Image(systemName: "minus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                    }
                  }
                  .padding(.horizontal, Theme.hPadding)
                  .padding(.vertical, 9)
                  .contentShape(Rectangle())
                }
                .buttonStyle(PlainHoverRowButtonStyle())
              }
            }
          }
        }

        Spacer(minLength: 0)
      }
      .padding(.top, 12)
      .navigationTitle(Text("Tags"))
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Manage…") { showingManageTags = true }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            onDone?()
            dismiss()
          }
        }
      }
      .sheet(isPresented: $showingManageTags, onDismiss: reload) {
        ManageTagsSheet()
      }
      .onAppear { reload() }
      .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in reload() }
    }
  }

  private func reload() {
    allTags = LocalCache.allTags(in: modelContext)
  }

  private func createOrToggleFromField() {
    let trimmed = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if let exact = allTags.first(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
      toggle(exact)
      newTagName = ""
      return
    }
    guard let created = mutator.createTag(name: trimmed) else { return }
    TaskUndo.recordTagCreate(created, mutator: mutator)
    toggle(created)
    newTagName = ""
    reload()
  }

  private func toggle(_ tag: TaskTag) {
    let before = currentTagSets()
    guard !before.isEmpty else { return }
    let removing = assignmentState(for: tag.id) == .all
    var after: [String: [String]] = [:]
    Haptics.tick()
    for (id, tags) in before {
      let next: [String]
      if removing {
        next = tags.filter { $0 != tag.id }
      } else {
        next = tags.contains(tag.id) ? tags : tags + [tag.id]
      }
      after[id] = next
      mutator.setTaskTags(id: id, tagIDs: next)
    }
    TaskUndo.recordTaskTags(before: before, after: after, mutator: mutator)
    reload()
  }
}

/// Lightweight "Manage Tags" sheet reachable from Settings ▸ Tasks and every
/// tag popover/picker. Supports create, rename, color, merge (Tag A → Tag B),
/// and delete (`docs/TAGS_SPEC.md` §4).
struct ManageTagsSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext

  @State private var tags: [TaskTag] = []
  @State private var openCounts: [String: Int] = [:]
  @State private var newTagName: String = ""
  @State private var renameTarget: TaskTag? = nil
  @State private var renameDraft: String = ""

  private var mutator: TaskMutator { SeptenaServices.shared.taskMutator }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          HStack(spacing: 8) {
            TextField("New tag…", text: $newTagName)
              .onSubmit { addNewTag() }
            Button("Add") { addNewTag() }
              .disabled(newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }

        Section {
          if tags.isEmpty {
            Text("No tags yet. Tags stay hidden across Septena until you create one.")
              .font(.septenaCaption)
              .foregroundStyle(Theme.inkSecondary)
          } else {
            ForEach(tags) { tag in
              HStack(spacing: 10) {
                Circle()
                  .fill(TagColorPalette.color(for: tag.color))
                  .frame(width: 9, height: 9)
                Text(tag.name)
                  .foregroundStyle(Theme.inkPrimary)
                Spacer()
                let count = openCounts[tag.id] ?? 0
                if count > 0 {
                  Text("\(count)")
                    .font(.septenaCaption)
                    .foregroundStyle(Theme.inkSecondary)
                }
                Menu {
                  Button {
                    renameDraft = tag.name
                    renameTarget = tag
                  } label: {
                    Label("Rename…", systemImage: "pencil")
                  }
                  Menu {
                    ForEach(TagColorPalette.swatches) { swatch in
                      Button {
                        changeColor(tag, token: swatch.token)
                      } label: {
                        HStack {
                          Text(swatch.label)
                          if tag.color == swatch.token {
                            Image(systemName: "checkmark")
                          }
                        }
                      }
                    }
                  } label: {
                    Label("Color", systemImage: "paintpalette")
                  }
                  let others = tags.filter { $0.id != tag.id }
                  if !others.isEmpty {
                    Menu {
                      ForEach(others) { target in
                        Button(target.name) {
                          mutator.mergeTag(sourceID: tag.id, into: target.id)
                          reload()
                        }
                      }
                    } label: {
                      Label("Merge into…", systemImage: "arrow.triangle.merge")
                    }
                  }
                  Divider()
                  Button(role: .destructive) {
                    delete(tag)
                  } label: {
                    Label("Delete Tag", systemImage: "trash")
                  }
                } label: {
                  Image(systemName: "ellipsis.circle")
                    .foregroundStyle(Theme.inkSecondary)
                    .contentShape(Rectangle())
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                #endif
                .fixedSize()
                .accessibilityLabel(Text("Actions for \(tag.name)"))
              }
            }
          }
        } header: {
          Text("Tags")
        } footer: {
          Text("Renaming a tag updates every task immediately. Deleting a tag removes the tag without touching your tasks.")
        }
      }
      .formStyle(.grouped)
      .navigationTitle(Text("Manage Tags"))
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .alert("Rename Tag", isPresented: Binding(
        get: { renameTarget != nil },
        set: { if !$0 { renameTarget = nil } }
      )) {
        TextField("Tag name", text: $renameDraft)
        Button("Rename") {
          if let t = renameTarget { commitRename(t, newName: renameDraft) }
          renameTarget = nil
        }
        Button("Cancel", role: .cancel) { renameTarget = nil }
      }
      .onAppear { reload() }
      .onReceive(NotificationCenter.default.publisher(for: .septenaTasksChanged)) { _ in reload() }
    }
    #if os(macOS)
    .frame(minWidth: 380, minHeight: 360)
    #endif
  }

  private func reload() {
    tags = LocalCache.allTags(in: modelContext)
    var counts: [String: Int] = [:]
    for t in LocalCache.allTasks(in: modelContext) where t.status == .open && !t.isHeading {
      for tid in t.tags { counts[tid, default: 0] += 1 }
    }
    openCounts = counts
  }

  private func addNewTag() {
    let trimmed = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if let created = mutator.createTag(name: trimmed) {
      TaskUndo.recordTagCreate(created, mutator: mutator)
    }
    newTagName = ""
    reload()
  }

  private func commitRename(_ tag: TaskTag, newName: String) {
    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != tag.name else { return }
    var after = tag
    after.name = trimmed
    if mutator.updateTag(id: tag.id, name: trimmed) {
      TaskUndo.recordTagUpdate(before: tag, after: after, mutator: mutator)
    }
    reload()
  }

  private func changeColor(_ tag: TaskTag, token: String?) {
    guard tag.color != token else { return }
    var after = tag
    after.color = token
    if mutator.updateTag(id: tag.id, color: .some(token)) {
      TaskUndo.recordTagUpdate(before: tag, after: after, mutator: mutator)
    }
    reload()
  }

  private func delete(_ tag: TaskTag) {
    mutator.deleteTag(id: tag.id)
    TaskUndo.recordTagDelete(tag, mutator: mutator)
    reload()
  }
}
