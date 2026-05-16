import SwiftUI

// MARK: - Checkbox

struct TaskCheckbox: View {
  @Environment(SectionTheme.self) private var theme
  /// Optional override — used by non-task items (habits/supplements/chores)
  /// to wear their section accent. `nil` means inherit list tint.
  var tint: Color? = nil
  let isDone: Bool
  /// When true (and not done), the checkbox renders as a sun-in-circle
  /// instead of a plain circle. Used by closed task rows to signal
  /// 'promoted to Today' — moves the today indicator into the same spot
  /// as completion so it no longer sits inline with the title.
  var isToday: Bool = false
  let onToggle: () -> Void

  #if os(macOS)
  private static let glyphSize: CGFloat = 16
  #else
  private static let glyphSize: CGFloat = 22
  #endif

  private var glyphName: String {
    if isDone { return "largecircle.fill.circle" }
    if isToday { return "sun.max.circle" }
    return "circle"
  }

  private var glyphTint: Color {
    if !isDone && isToday { return .orange }
    return tint ?? theme.accent
  }

  var body: some View {
    Button(action: onToggle) {
      Image(systemName: glyphName)
        .font(.system(size: Self.glyphSize, weight: .regular))
        .foregroundStyle(glyphTint)
        .frame(width: Theme.checkboxTap, height: Theme.checkboxTap)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Screen title

struct ScreenTitle: View {
  let icon: String
  let iconTint: Color
  let title: String

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .font(.title2)
        .foregroundStyle(iconTint)
      Text(title)
        .font(.septenaScreenTitle)
        .foregroundStyle(.primary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, Theme.hPadding)
    .padding(.top, 12)
    .padding(.bottom, 18)
  }
}


// MARK: - Inline edit task row

struct InlineEditTaskRow: View {
  @Environment(SectionTheme.self) private var theme
  let task: SeptenaTask
  @Binding var title: String
  @Binding var notes: String
  let isDone: Bool
  /// Whether to render the sun-in-checkbox glyph. Driven by the caller
  /// so it can suppress the indicator on the Today filter (where every
  /// row carries it implicitly).
  var isToday: Bool = false
  /// Auto-focus the title field on appear. True when the row was just
  /// created via ⌘N / + (so the user can start typing immediately);
  /// false for editing an existing task (user explicitly taps the
  /// field to start editing).
  var autoFocus: Bool = false
  /// Labels resolved from current data (project title or area title) so the
  /// chip reads "Septena" instead of the raw id.
  var projectTitle: String? = nil
  var areaTitle: String? = nil
  var onToggleDone: () -> Void
  var onCommit: () -> Void
  var onCancel: () -> Void
  var onSchedule: (() -> Void)? = nil
  var onDeadline: (() -> Void)? = nil
  var onMove: (() -> Void)? = nil
  var onRepeat: (() -> Void)? = nil
  @FocusState private var focused: Field?
  /// Set true the moment the user cancels, so the onChange(focused) blur
  /// handler doesn't race in and auto-commit before the card tears down.
  @State private var cancelling = false

  enum Field { case title, notes }

  // Uses Theme.checkboxTap and Theme.iconTextGap so the notes' left
  // edge lines up with the title text and matches every other row.

  private func handleCancel() {
    cancelling = true
    onCancel()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // ── Title row — pinned to the top of the rowTapHeight band so the
      //    title's Y matches the closed taskBody (which is also pinned
      //    top). Notes + actions grow *below* this band.
      HStack(alignment: .firstTextBaseline, spacing: Theme.iconTextGap) {
        TaskCheckbox(isDone: isDone, isToday: isToday, onToggle: onToggleDone)
          .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }

        TextField("Title", text: $title, axis: .vertical)
          .textFieldStyle(.plain)
          .focusEffectDisabled()
          .font(.septenaTaskTitle)
          .focused($focused, equals: .title)
          .lineLimit(1...5)
          .submitLabel(.done)
          .onSubmit { onCommit() }
          .onChange(of: title) { _, new in
            if new.contains("\n") {
              title = new.replacingOccurrences(of: "\n", with: "")
              onCommit()
            }
          }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, Theme.hPadding)
      // Match the closed taskBody's explicit vertical padding — anchors
      // the title's Y to a fixed offset from row top so the TextField's
      // baseline lands exactly where the closed Text's baseline was.
      .padding(.vertical, Theme.rowTapHeight >= 44 ? 11 : 5)

      // ── Notes — left-aligned with the title. Notes leading must equal
      //    Theme.hPadding + (TaskCheckbox tap width) + (HStack spacing 12)
      //    so the notes' left edge sits at the same X as the title.
      //    TaskCheckbox is 22pt tap on macOS, 28pt on iOS — pick per
      //    platform so the alignment lines up on both.
      TextField("Notes", text: $notes, axis: .vertical)
        .textFieldStyle(.plain)
        .focusEffectDisabled()
        .font(.septenaNotes)
        .foregroundStyle(.secondary)
        .focused($focused, equals: .notes)
        .lineLimit(2...16)
        .padding(.leading, Theme.hPadding + Theme.checkboxTap + Theme.iconTextGap)
        .padding(.trailing, Theme.hPadding)
        .padding(.bottom, 10)

      // ── Bottom row: all icons on the right (Things-style). Calendar
      //    (when), repeat, move target, deadline flag — order matches the
      //    closed-row trailing chip so the eye doesn't have to jump.
      HStack(spacing: 0) {
        Spacer()
        actionIcons
      }
      .padding(.horizontal, Theme.hPadding)
      .padding(.bottom, 12)
    }
    .background(Theme.cardSurface)
    .modifier(InlineCardChrome())
    .onAppear {
      // Auto-focus the title for fresh ⌘N / + drafts so the keyboard
      // opens and the user can start typing immediately. Small delay
      // lets the row finish inserting before grabbing focus.
      if autoFocus {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
          focused = .title
        }
      }
    }
    .background(commitShortcut)
    .background(cancelShortcut)
    // Absorb taps inside the card so the parent's "tap empty area to dismiss"
    // gesture doesn't fire when tapping the card's own padding/background.
    .contentShape(Rectangle())
    .onTapGesture { /* swallow */ }
    // Belt-and-suspenders for Esc — the hidden cancelShortcut button above is
    // the reliable path (keyboardShortcut(.cancelAction) is window-wide).
    // These fire on iOS / iPad where the cancelAction shortcut may not be
    // routed when no menu bar exists.
    .septenaOnEscape { handleCancel() }
    .onKeyPress(.escape) { handleCancel(); return .handled }
    // Tapping a task opens the inline card but does NOT auto-focus the
    // title. The user taps the title (or notes) to start editing.
    // Keyboard dismissed (via scroll-down or tap-outside) → commit. Without
    // this, blur leaves the card open with no field focused.
    .onChange(of: focused) { _, new in
      // Skip the blur-commit when we're already on the cancel path —
      // otherwise Esc would commit whatever's in the title field as the
      // editor tears down.
      guard new == nil, !cancelling else { return }
      if title.trimmingCharacters(in: .whitespaces).isEmpty {
        onCancel()
      } else {
        onCommit()
      }
    }
  }

  private var commitShortcut: some View {
    Button("Commit") { onCommit() }
      .keyboardShortcut("k", modifiers: .command)
      .opacity(0)
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
  }

  /// Window-wide Esc shortcut — fires reliably even while an NSTextField
  /// is first responder (which swallows Esc and stops `.onExitCommand` from
  /// receiving it).
  private var cancelShortcut: some View {
    Button("Cancel") { handleCancel() }
      .keyboardShortcut(.cancelAction)
      .opacity(0)
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
  }

  // MARK: - Right-side action icons (icon-only, no capsule background)

  private func whenIcon(for d: Date?) -> String {
    guard let d else { return "calendar" }
    let cal = Calendar.current
    if cal.isDateInToday(d)    { return "sun.max.fill" }
    if cal.isDateInTomorrow(d) { return "sunrise.fill" }
    return "calendar"
  }

  private func whenIconTint(for d: Date?) -> Color {
    guard let d else { return Theme.inkSecondary.opacity(0.6) }
    return Calendar.current.isDateInToday(d) ? .yellow : Theme.inkSecondary
  }

  @ViewBuilder
  private var actionIcons: some View {
    let parsed = task.scheduled.flatMap(SeptenaDate.parse)
    HStack(spacing: 22) {
      // When — calendar / sun (today) / sunrise (tomorrow); reflects state
      actionIcon(
        systemName: whenIcon(for: parsed),
        tint: whenIconTint(for: parsed),
        action: { onSchedule?() }
      )
      // Repeat — colored when set, muted when unset
      actionIcon(
        systemName: "arrow.triangle.2.circlepath",
        tint: task.recurrence == nil ? Theme.inkSecondary.opacity(0.6) : Theme.inkPrimary,
        action: { onRepeat?() }
      )
      // Move — icon reflects target (project / area / inbox)
      actionIcon(
        systemName: moveIcon,
        tint: (projectTitle != nil || areaTitle != nil) ? Theme.inkPrimary : Theme.inkSecondary.opacity(0.6),
        action: { onMove?() }
      )
      // Deadline — red when overdue/today, muted otherwise
      actionIcon(
        systemName: "flag",
        tint: deadlineIconTint,
        action: { onDeadline?() }
      )
    }
  }

  private var moveIcon: String {
    if projectTitle != nil { return "number" }
    if areaTitle != nil    { return "folder" }
    return "tray"
  }

  private var deadlineIconTint: Color {
    guard let d = task.due.flatMap(SeptenaDate.parse) else {
      return Theme.inkSecondary.opacity(0.6)
    }
    return dueTint(d)
  }

  @ViewBuilder
  private func actionIcon(systemName: String, tint: Color, action: @escaping () -> Void) -> some View {
    Button(action: { Haptics.pick(); action() }) {
      Image(systemName: systemName)
        .font(.system(size: Theme.cardActionIconSize, weight: .regular))
        .foregroundStyle(tint)
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func dueTint(_ d: Date) -> Color {
    let today = Calendar.current.startOfDay(for: Date())
    return Calendar.current.startOfDay(for: d) <= today ? Theme.overdueRed : Theme.inkSecondary
  }

}

// MARK: - Week strip

/// Lean 7-day strip: today + next 6 days as Reminders-style chips
/// (weekday letter on top, day number below). One tap = one pick.
/// Used by both the When and Deadline pickers so quick scheduling
/// within the coming week never opens a full calendar.
struct WeekStrip: View {
  @Environment(SectionTheme.self) private var theme
  /// Currently-selected day (start-of-day), or nil for none.
  let selected: Date?
  let onPick: (Date) -> Void

  private static let cal = Calendar.current
  private static let weekdayFmt: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "EEEEE"; return f   // single letter
  }()

  private var days: [Date] {
    let start = Self.cal.startOfDay(for: Date())
    return (0..<7).compactMap { Self.cal.date(byAdding: .day, value: $0, to: start) }
  }

  var body: some View {
    HStack(spacing: 6) {
      ForEach(days, id: \.self) { d in
        let isSelected = selected.map { Self.cal.isDate($0, inSameDayAs: d) } ?? false
        let isToday = Self.cal.isDateInToday(d)
        Button {
          Haptics.pick()
          onPick(Self.cal.startOfDay(for: d))
        } label: {
          VStack(spacing: 2) {
            Text(Self.weekdayFmt.string(from: d))
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(isSelected ? Color.white : Theme.inkSecondary)
            Text("\(Self.cal.component(.day, from: d))")
              .font(.system(size: 17, weight: .semibold, design: .rounded))
              .foregroundStyle(isSelected ? Color.white
                               : (isToday ? theme.accent : Theme.inkPrimary))
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 8)
          .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(isSelected ? theme.accent
                    : (isToday ? theme.accent.opacity(0.12) : Color.clear))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .strokeBorder(isSelected ? Color.clear : Theme.inkSecondary.opacity(0.18),
                            lineWidth: 0.5)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
  }
}

// MARK: - When picker sheet

/// "When" — schedule a task for a date or clear the scheduled date. Lean:
/// a 7-day strip up top covers the common case; "Pick a date…" reveals
/// the graphical calendar for anything further out. `due` has its own
/// picker (DeadlinePickerSheet) because deadlines are concrete dates only.
struct WhenPickerSheet: View {
  @Environment(SectionTheme.self) private var theme
  let onPick: (Date?) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var customDate = Date()
  @State private var showingCustom = false

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        WeekStrip(selected: nil) { d in
          onPick(d); dismiss()
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 8)
        .padding(.bottom, 12)

        Hairline()

        if showingCustom {
          DatePicker("Date", selection: $customDate, displayedComponents: [.date])
            .datePickerStyle(.graphical)
            .padding(.horizontal, Theme.hPadding)
          Spacer()
          Button {
            onPick(Calendar.current.startOfDay(for: customDate))
            dismiss()
          } label: {
            Text("Set Date")
              .font(.system(size: 16, weight: .semibold))
              .foregroundStyle(.white)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 14)
              .background(theme.accent)
              .clipShape(Capsule())
          }
          .buttonStyle(.plain)
          .padding(.horizontal, Theme.hPadding)
          .padding(.bottom, 20)
        } else {
          option(icon: "calendar", tint: Theme.inkSecondary, title: "Pick a Date…") {
            showingCustom = true
          }
          Hairline()
          option(icon: "xmark.circle", tint: .secondary, title: "No Date") {
            onPick(nil); dismiss()
          }
          Spacer()
        }
      }
      .navigationTitle("When")
      .septenaInlineTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
  }

  @ViewBuilder
  private func option(icon: String, tint: Color, title: String, action: @escaping () -> Void) -> some View {
    Button(action: { Haptics.pick(); action() }) {
      HStack(spacing: 14) {
        Image(systemName: icon)
          .font(.system(size: 18))
          .foregroundStyle(tint)
          .frame(width: 24)
        Text(title)
          .font(.septenaSidebarRow)
          .foregroundStyle(.primary)
        Spacer()
      }
      .padding(.horizontal, Theme.hPadding)
      .frame(height: Theme.sidebarRowHeight)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Deadline picker sheet

/// "Deadline" — set a hard due date, or clear it. Deliberately *just* a
/// date picker (no Today/Tomorrow shortcuts) because deadlines are
/// concrete dates, not loose intentions. Matches the reference design's Deadline sheet.
struct DeadlinePickerSheet: View {
  @Environment(SectionTheme.self) private var theme
  let initialDate: Date?
  let onPick: (Date?) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var date: Date

  @State private var showingCalendar = false

  init(initialDate: Date? = nil, onPick: @escaping (Date?) -> Void) {
    self.initialDate = initialDate
    self.onPick = onPick
    let seed = initialDate ?? Calendar.current.startOfDay(for: Date())
    _date = State(initialValue: seed)
    // If the initial deadline is within the next 7 days, the strip
    // already covers it — keep the calendar collapsed for a lean sheet.
    let today = Calendar.current.startOfDay(for: Date())
    let inStripRange: Bool = {
      guard let initialDate else { return true }
      let day = Calendar.current.startOfDay(for: initialDate)
      let days = Calendar.current.dateComponents([.day], from: today, to: day).day ?? 0
      return days >= 0 && days < 7
    }()
    _showingCalendar = State(initialValue: !inStripRange)
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        WeekStrip(selected: date) { d in
          date = d
          onPick(d); dismiss()
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 8)
        .padding(.bottom, 12)

        Hairline()

        if showingCalendar {
          DatePicker("Deadline", selection: $date, displayedComponents: [.date])
            .datePickerStyle(.graphical)
            .padding(.horizontal, Theme.hPadding)
        } else {
          Button {
            withAnimation(.easeInOut(duration: 0.18)) { showingCalendar = true }
          } label: {
            HStack(spacing: 14) {
              Image(systemName: "calendar")
                .font(.system(size: 18))
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: 24)
              Text("Pick a Date…")
                .font(.septenaSidebarRow)
                .foregroundStyle(.primary)
              Spacer()
            }
            .padding(.horizontal, Theme.hPadding)
            .frame(height: Theme.sidebarRowHeight)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }

        Spacer()

        VStack(spacing: 10) {
          Button {
            onPick(Calendar.current.startOfDay(for: date))
            dismiss()
          } label: {
            Text(initialDate == nil ? "Set Deadline" : "Update Deadline")
              .font(.system(size: 16, weight: .semibold))
              .foregroundStyle(.white)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 14)
              .background(theme.accent)
              .clipShape(Capsule())
          }
          .buttonStyle(.plain)

          Button {
            Haptics.warning()
            onPick(nil)
            dismiss()
          } label: {
            Text("No Deadline")
              .font(.system(size: 15, weight: .medium))
              .foregroundStyle(initialDate == nil ? Theme.inkSecondary : Theme.overdueRed)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 12)
          }
          .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.bottom, 20)
      }
      .navigationTitle("Deadline")
      .septenaInlineTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
  }
}

// MARK: - Recurrence picker sheet

/// "Repeat" — set or clear a recurrence rule. v1: daily / weekly / monthly,
/// interval stepper, and fixed-vs-after-completion toggle. the reference design's canonical
/// picker has more (weekday selection, ends-rules) — to be added when needed.
struct RecurrencePickerSheet: View {
  @Environment(SectionTheme.self) private var theme
  let initial: Recurrence?
  let onPick: (Recurrence?) -> Void
  @Environment(\.dismiss) private var dismiss

  @State private var unit: Recurrence.Unit
  @State private var interval: Int
  @State private var afterCompletion: Bool

  init(initial: Recurrence?, onPick: @escaping (Recurrence?) -> Void) {
    self.initial = initial
    self.onPick = onPick
    _unit = State(initialValue: initial?.unit ?? .day)
    _interval = State(initialValue: initial?.interval ?? 1)
    _afterCompletion = State(initialValue: initial?.afterCompletion ?? true)
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        // Unit segmented
        Picker("Unit", selection: $unit) {
          Text("Day").tag(Recurrence.Unit.day)
          Text("Week").tag(Recurrence.Unit.week)
          Text("Month").tag(Recurrence.Unit.month)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 16)

        // Interval stepper
        HStack {
          Text("Every")
            .font(.septenaSidebarRow)
            .foregroundStyle(Theme.inkPrimary)
          Spacer()
          Stepper(value: $interval, in: 1...99) {
            Text("\(interval) \(unitNoun(plural: interval != 1))")
              .font(.septenaSidebarRow)
              .foregroundStyle(Theme.inkSecondary)
          }
          .labelsHidden()
          Text("\(interval) \(unitNoun(plural: interval != 1))")
            .font(.septenaSidebarRow)
            .foregroundStyle(Theme.inkSecondary)
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 18)

        // Fixed vs after-completion toggle
        Toggle(isOn: $afterCompletion) {
          VStack(alignment: .leading, spacing: 2) {
            Text("After completion")
              .font(.septenaSidebarRow)
              .foregroundStyle(Theme.inkPrimary)
            Text(afterCompletion
                 ? "Next instance \(interval) \(unitNoun(plural: interval != 1)) after you mark this done."
                 : "Next instance \(interval) \(unitNoun(plural: interval != 1)) after the previous scheduled date.")
              .font(.caption)
              .foregroundStyle(Theme.inkSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .tint(theme.accent)
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 18)

        Spacer()

        VStack(spacing: 10) {
          Button {
            onPick(Recurrence(unit: unit, interval: interval, afterCompletion: afterCompletion))
            dismiss()
          } label: {
            Text(initial == nil ? "Set Repeat" : "Update Repeat")
              .font(.system(size: 16, weight: .semibold))
              .foregroundStyle(.white)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 14)
              .background(theme.accent)
              .clipShape(Capsule())
          }
          .buttonStyle(.plain)

          if initial != nil {
            Button {
              Haptics.warning()
              onPick(nil)
              dismiss()
            } label: {
              Text("Don't Repeat")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.overdueRed)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.bottom, 20)
      }
      .navigationTitle("Repeat")
      .septenaInlineTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
  }

  private func unitNoun(plural: Bool) -> String {
    switch unit {
    case .day:   return plural ? "days" : "day"
    case .week:  return plural ? "weeks" : "week"
    case .month: return plural ? "months" : "month"
    }
  }
}

// MARK: - Move picker sheet

struct MovePickerSheet: View {
  let areas: [Area]
  let projects: [Project]
  var currentAreaId: String? = nil
  var currentProjectId: String? = nil
  let onPick: (_ areaId: String?, _ projectId: String?) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          // Inbox first — drop both area and project.
          if matches("Inbox") {
            row(.inbox, title: "Inbox",
                selected: currentAreaId == nil && currentProjectId == nil) {
              onPick(nil, nil); dismiss()
            }
          }

          // Top-level projects (no area)
          ForEach(filteredTopProjects) { p in
            row(.project, title: p.title,
                selected: p.id == currentProjectId) {
              onPick(nil, p.id); dismiss()
            }
          }

          // Areas with their projects nested directly underneath, mirroring
          // the sidebar's hierarchy.
          ForEach(filteredAreas) { area in
            row(.area, title: area.title,
                selected: currentProjectId == nil && area.id == currentAreaId) {
              onPick(area.id, nil); dismiss()
            }
            ForEach(projectsIn(area.id)) { p in
              row(.project, title: p.title,
                  selected: p.id == currentProjectId, indent: true) {
                onPick(area.id, p.id); dismiss()
              }
            }
          }
        }
        .padding(.vertical, 8)
      }
      .background(Theme.paperBackground)
      .septenaAlwaysVisibleSearch(text: $query)
      .navigationTitle("Move")
      .septenaInlineTitle()
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  // MARK: - Filtering

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

  // MARK: - Row primitive

  private enum RowKind { case inbox, area, project }

  @ViewBuilder
  private func row(_ kind: RowKind, title: String, selected: Bool,
                   indent: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: { Haptics.pick(); action() }) {
      HStack(spacing: 12) {
        icon(for: kind)
          .frame(width: 24, alignment: .center)
        Text(title)
          .font(.system(size: 16, weight: kind == .area ? .semibold : .regular))
          .foregroundStyle(Theme.inkPrimary)
        Spacer()
        if selected {
          Image(systemName: "checkmark")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.inkSecondary)
        }
      }
      .padding(.leading, indent ? Theme.hPadding + 24 : Theme.hPadding)
      .padding(.trailing, Theme.hPadding)
      .frame(height: 38)
      .contentShape(Rectangle())
      .background(selected ? Theme.mutedSurface : Color.clear)
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private func icon(for kind: RowKind) -> some View {
    switch kind {
    case .inbox:
      Image(systemName: "tray.fill")
        .font(.system(size: 16))
        .foregroundStyle(Theme.iconMuted)
    case .area:
      AreaIcon(diameter: 14, lineWidth: 1.5)
    case .project:
      // Pie glyph — same component as sidebar / detail page.
      ProjectProgressIcon(progress: 0.25, tint: Theme.iconMuted, diameter: 14)
    }
  }
}

// MARK: - Paper-themed action sheet
//
// iOS Menu pops with system materials (translucent gray) and can't be
// re-themed. For action lists ("Cancel / Delete") we want
// the same warm-paper surface as the rest of the app, so we present a
// custom bottom sheet of action rows instead of a Menu.

struct ActionSheet: View {
  struct Action: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    var role: ButtonRole? = nil          // .destructive renders red
    /// When true, renders a trailing checkmark in the section accent — used
    /// for sort-mode rows where one of N is the current selection.
    var selected: Bool = false
    let perform: () -> Void
  }

  let title: String?
  let actions: [Action]
  @Environment(SectionTheme.self) private var theme
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      if let title {
        Text(title)
          .font(.septenaSectionTitle)
          .foregroundStyle(Theme.inkPrimary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, Theme.hPadding)
          .padding(.top, 18)
          .padding(.bottom, 8)
        Hairline()
      }

      ForEach(actions) { action in
        Button {
          action.perform()
          dismiss()
        } label: {
          HStack(spacing: 14) {
            Image(systemName: action.icon)
              .font(.system(size: 16))
              .foregroundStyle(action.role == .destructive ? Theme.overdueRed : Theme.inkSecondary)
              .frame(width: 22)
            Text(action.title)
              .font(.septenaSidebarRow)
              .foregroundStyle(action.role == .destructive ? Theme.overdueRed : Theme.inkPrimary)
            Spacer()
            if action.selected {
              Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.accent)
            }
          }
          .padding(.horizontal, Theme.hPadding)
          .frame(height: Theme.sidebarRowHeight)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Hairline()
      }

      Button("Cancel") { dismiss() }
        .font(.septenaButton)
        .foregroundStyle(theme.accent)
        .frame(maxWidth: .infinity)
        .frame(height: 56)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Theme.paperBackground.ignoresSafeArea())
  }
}

// MARK: - Hairline divider

struct Hairline: View {
  var leadingInset: CGFloat = Theme.hPadding
  var body: some View {
    Rectangle()
      .fill(Theme.divider)
      .frame(height: 0.5)
      .padding(.leading, leadingInset)
  }
}
