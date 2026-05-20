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

  // Smaller rounded square than the old circle glyph — reads as a checkbox,
  // not a progress dot. Sizes are the visible box, not the tap area.
  #if os(macOS)
  private static let boxSize: CGFloat = 14
  private static let boxCorner: CGFloat = 3.5
  private static let boxStroke: CGFloat = 1.2
  private static let checkSize: CGFloat = 9
  #else
  private static let boxSize: CGFloat = 18
  private static let boxCorner: CGFloat = 4.5
  private static let boxStroke: CGFloat = 1.4
  private static let checkSize: CGFloat = 12
  #endif

  /// Checkbox chrome is neutral gray by default; Today rows swap stroke
  /// and fill to `Theme.todayAccent` so the checkbox itself signals the
  /// promotion (no inset sun glyph).
  private var boxStrokeColor: Color {
    isToday ? Theme.todayAccent : Theme.inkSecondary.opacity(0.55)
  }
  private var boxFillColor: Color {
    isToday ? Theme.todayAccent : Theme.inkSecondary.opacity(0.85)
  }

  var body: some View {
    Button(action: onToggle) {
      ZStack {
        if isDone {
          RoundedRectangle(cornerRadius: Self.boxCorner, style: .continuous)
            .fill(boxFillColor)
            .frame(width: Self.boxSize, height: Self.boxSize)
          Image(systemName: "checkmark")
            .font(.system(size: Self.checkSize, weight: .bold))
            .foregroundStyle(.white)
        } else {
          RoundedRectangle(cornerRadius: Self.boxCorner, style: .continuous)
            .strokeBorder(boxStrokeColor, lineWidth: Self.boxStroke)
            .frame(width: Self.boxSize, height: Self.boxSize)
        }
      }
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
//
// Reminders-style inline editor. No card chrome, no embedded action icons
// — the row stays a row. The user edits title (and optionally notes)
// in place; everything else (dates, repeat, list, delete) lives behind
// the `info.circle` button on the trailing edge, which opens the
// TaskDetailsSheet. This replaces the prior Things-style expanding card.

struct InlineEditTaskRow: View {
  @Environment(SectionTheme.self) private var theme
  @Environment(\.scenePhase) private var scenePhase
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
  var onToggleDone: () -> Void
  var onCommit: () -> Void
  var onCancel: () -> Void
  var onOpenDetails: () -> Void

  @FocusState private var focused: Field?
  /// Set true the moment the user cancels, so the onChange(focused) blur
  /// handler doesn't race in and auto-commit before the editor tears down.
  @State private var cancelling = false
  /// Notes affordance state — Reminders-style. Hidden by default for
  /// tasks without notes (no placeholder line on open); the user taps
  /// "＋ Notes" to reveal the field. If the task arrives with notes
  /// already set, the field shows automatically on appear.
  @State private var showNotes = false

  enum Field { case title, notes }

  private func handleCancel() {
    cancelling = true
    onCancel()
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.iconTextGap) {
      TaskCheckbox(isDone: isDone, isToday: isToday, onToggle: onToggleDone)
        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }

      VStack(alignment: .leading, spacing: 4) {
        // Single-line on purpose: a multi-line (`axis: .vertical`)
        // TextField makes iOS inject a system Done bar above the
        // keyboard, which fights our floating glass accessory. Long
        // titles still truncate cleanly in the closed row.
        //
        // `.fixedSize(vertical: true)` clamps the TextField to its
        // intrinsic text height — without it, plain-style TextField
        // adds a few pixels of internal padding that shifts the
        // baseline up vs the closed-row `Text`. The result: title
        // stays put on tap; notes grows the row downward.
        TextField("Title", text: $title)
          .textFieldStyle(.plain)
          .focusEffectDisabled()
          .font(.septenaTaskTitle)
          .focused($focused, equals: .title)
          .submitLabel(.return)
          .onSubmit {
            SeptenaLog.info("[Edit] TextField onSubmit (Enter) title=\"\(title)\"")
            onCommit()
          }
          .fixedSize(horizontal: false, vertical: true)
        // Notes — hidden until the user taps "＋ Notes" (or until the
        // task arrives with notes already set). Multi-line on edit,
        // single-line truncated when unfocused. Reminders-style: an
        // empty 'Add Note' placeholder shouldn't shout on a fresh row.
        if showNotes || !notes.isEmpty {
          TextField("Note", text: $notes, axis: .vertical)
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .font(.septenaNotes)
            .foregroundStyle(.secondary)
            .focused($focused, equals: .notes)
            .lineLimit(1...8)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Button {
            Haptics.pick()
            showNotes = true
            focused = .notes
          } label: {
            HStack(spacing: 4) {
              Image(systemName: "plus")
                .font(.septenaNotes.weight(.semibold))
                .imageScale(.small)
              Text("Notes")
                .font(.septenaNotes)
            }
            .foregroundStyle(Theme.inkSecondary.opacity(0.7))
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Add notes")
        }
      }

      // Info button — Reminders' "i" affordance, always visible while
      // editing. Opens the consolidated details pane for every other
      // field (when, deadline, repeat, list, delete).
      Button(action: { Haptics.pick(); onOpenDetails() }) {
        Image(systemName: "info.circle")
          .font(.title3)
          .foregroundStyle(theme.accent)
          .frame(width: 28, height: 28)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }
      .accessibilityLabel("Task details")
    }
    .padding(.horizontal, Theme.hPadding)
    .padding(.vertical, Theme.rowVPadding)
    .onAppear {
      // Reveal notes inline if the task already has them — the "+ Notes"
      // affordance is only for the empty-notes case.
      if !notes.isEmpty { showNotes = true }
    }
    // The row mounts mid-expand-animation; assigning FocusState immediately
    // races UIKit's input-session setup and the field silently fails to
    // become first responder (logs "performInputOperation requires a valid
    // sessionID"). Sleeping one tick lets the row settle before we claim
    // focus — the difference between "Enter saves the title" and "Enter
    // saves an empty draft."
    .task {
      if autoFocus {
        try? await Task.sleep(for: .milliseconds(50))
        focused = .title
        SeptenaLog.info("[Edit] InlineEditTaskRow autoFocus claimed title field (title=\"\(title)\")")
      }
    }
    // Save-on-blur safety net: if the row vanishes for any reason (parent
    // tore it down, navigation, sheet presented over it, list reload)
    // and the user *didn't* explicitly cancel, commit the draft.
    // onCommit is idempotent — its guard returns immediately if the
    // parent has already cleared editingTaskId.
    .onDisappear {
      if !cancelling {
        SeptenaLog.info("[Edit] InlineEditTaskRow onDisappear → onCommit (title=\"\(title)\")")
        onCommit()
      } else {
        SeptenaLog.info("[Edit] InlineEditTaskRow onDisappear (cancelling) — skipping commit")
      }
    }
    .background(commitShortcut)
    .background(cancelShortcut)
    // Absorb taps inside the editor so the parent's "tap empty area to
    // dismiss" gesture doesn't fire when tapping our own padding.
    .contentShape(Rectangle())
    .onTapGesture { /* swallow */ }
    .septenaOnEscape { handleCancel() }
    .onKeyPress(.escape) { handleCancel(); return .handled }
    // Save-on-blur — fires when focus moves out of *both* fields
    // (intra-row focus shifts go field → field without hitting nil,
    // so the editor stays open while the user moves between
    // title/notes; the commit only triggers when keyboard goes away).
    .onChange(of: focused) { old, new in
      SeptenaLog.info("[Edit] focus change \(String(describing: old)) → \(String(describing: new)) title=\"\(title)\"")
      guard new == nil, !cancelling else { return }
      if title.trimmingCharacters(in: .whitespaces).isEmpty {
        SeptenaLog.info("[Edit] blur with empty title → onCancel")
        onCancel()
      } else {
        SeptenaLog.info("[Edit] blur with title → onCommit")
        onCommit()
      }
    }
    // App backgrounded mid-edit — iOS may yank the keyboard without
    // routing focus through nil first, so cover this path explicitly.
    .onChange(of: scenePhase) { _, new in
      if new != .active && !cancelling { onCommit() }
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

}

// MARK: - Task details sheet
//
// One sheet, every secondary attribute. Each row shows the current value
// and opens the relevant existing picker (When / Deadline / Repeat /
// Move) on tap. Mirrors Reminders' Details sheet — a single jumping-off
// point instead of four separate icon affordances inside the row.

struct TaskDetailsSheet: View {
  @Environment(SectionTheme.self) private var theme
  @Environment(\.dismiss) private var dismiss

  let task: SeptenaTask
  let projectTitle: String?
  let areaTitle: String?
  /// Saves edited title + notes back to the parent. Called on dismiss and
  /// when the sheet hands off to a sub-picker, so in-flight edits aren't
  /// lost when the user opens (say) the When picker from inside Details.
  let onSaveTitleNotes: (_ title: String, _ notes: String) -> Void
  let onOpenWhen: () -> Void
  let onOpenDeadline: () -> Void
  let onOpenRepeat: () -> Void
  let onOpenMove: () -> Void
  let onDelete: () -> Void
  /// Closes the pane from inside (Done button). Parent clears
  /// `selectedTaskId`, which retracts the inspector binding.
  let onDone: () -> Void

  @State private var titleDraft: String = ""
  @State private var notesDraft: String = ""
  @FocusState private var focused: Field?
  enum Field { case title, notes }

  private func save() {
    onSaveTitleNotes(titleDraft, notesDraft)
  }

  var body: some View {
    NavigationStack {
      List {
        // Title + notes live at the top of the pane so the sheet feels
        // like the task itself, not just a metadata picker.
        Section {
          TextField("Title", text: $titleDraft, axis: .vertical)
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .font(.septenaTaskTitle)
            .focused($focused, equals: .title)
            .lineLimit(1...5)

          TextField("Notes", text: $notesDraft, axis: .vertical)
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .font(.septenaNotes)
            .foregroundStyle(.secondary)
            .focused($focused, equals: .notes)
            .lineLimit(1...12)
        }

        Section {
          detailRow(
            icon: whenIcon, tint: whenTint,
            title: "When", value: whenLabel
          ) { save(); onOpenWhen() }

          detailRow(
            icon: "flag", tint: deadlineTint,
            title: "Deadline", value: deadlineLabel
          ) { save(); onOpenDeadline() }

          detailRow(
            icon: "arrow.triangle.2.circlepath",
            tint: task.recurrence == nil ? Theme.inkSecondary : Theme.inkPrimary,
            title: "Repeat", value: repeatLabel
          ) { save(); onOpenRepeat() }
        }

        Section {
          detailRow(
            icon: moveIcon,
            tint: (projectTitle != nil || areaTitle != nil) ? Theme.inkPrimary : Theme.inkSecondary,
            title: "List", value: moveLabel
          ) { save(); onOpenMove() }
        }

        Section {
          Button(role: .destructive) {
            Haptics.warning()
            onDelete()
          } label: {
            Label("Delete Task", systemImage: "trash")
              .foregroundStyle(Theme.overdueRed)
          }
        }
      }
      #if os(macOS)
      .listStyle(.inset)
      #else
      .listStyle(.insetGrouped)
      #endif
      .scrollContentBackground(.hidden)
      .background(Theme.paperBackground)
      .navigationTitle("Details")
      .septenaInlineTitle()
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { save(); onDone() }
        }
      }
      .onAppear {
        titleDraft = task.title
        notesDraft = task.notes ?? ""
      }
      .onDisappear { save() }
    }
  }

  // MARK: - Row primitive

  @ViewBuilder
  private func detailRow(icon: String, tint: Color, title: String,
                         value: String, action: @escaping () -> Void) -> some View {
    Button(action: { Haptics.pick(); action() }) {
      HStack(spacing: 14) {
        Image(systemName: icon)
          .font(.system(size: 17))
          .foregroundStyle(tint)
          .frame(width: 24)
        Text(title)
          .font(.septenaSidebarRow)
          .foregroundStyle(Theme.inkPrimary)
        Spacer()
        Text(value)
          .font(.septenaMeta)
          .foregroundStyle(Theme.inkSecondary)
        Image(systemName: "chevron.right")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(Theme.inkSecondary.opacity(0.5))
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  // MARK: - Labels

  private var whenIcon: String {
    guard let d = task.scheduled.flatMap(SeptenaDate.parse) else { return "calendar" }
    let cal = Calendar.current
    if cal.isDateInToday(d)    { return "sun.max.fill" }
    if cal.isDateInTomorrow(d) { return "sunrise.fill" }
    return "calendar"
  }
  private var whenTint: Color {
    guard let d = task.scheduled.flatMap(SeptenaDate.parse) else { return Theme.inkSecondary }
    return Calendar.current.isDateInToday(d) ? .yellow : Theme.inkPrimary
  }
  private var whenLabel: String {
    guard let d = task.scheduled.flatMap(SeptenaDate.parse) else { return "None" }
    return shortDate(d)
  }

  private var deadlineTint: Color {
    guard let d = task.due.flatMap(SeptenaDate.parse) else { return Theme.inkSecondary }
    let today = Calendar.current.startOfDay(for: Date())
    return Calendar.current.startOfDay(for: d) <= today ? Theme.overdueRed : Theme.inkPrimary
  }
  private var deadlineLabel: String {
    guard let d = task.due.flatMap(SeptenaDate.parse) else { return "None" }
    return shortDate(d)
  }

  private var repeatLabel: String {
    guard let r = task.recurrence else { return "Never" }
    let unit: String = {
      switch r.unit {
      case .day:   return r.interval == 1 ? "day"   : "\(r.interval) days"
      case .week:  return r.interval == 1 ? "week"  : "\(r.interval) weeks"
      case .month: return r.interval == 1 ? "month" : "\(r.interval) months"
      }
    }()
    let base = "Every \(unit)"
    // Server stamps `next_occurrence` on open recurring tasks — show it so the
    // user sees when the next instance will land without doing the math.
    if let next = task.nextOccurrence.flatMap(SeptenaDate.parse) {
      return "\(base) · next \(shortDate(next))"
    }
    return base
  }

  private var moveIcon: String {
    if projectTitle != nil { return "number" }
    if areaTitle    != nil { return "folder" }
    return "tray"
  }
  private var moveLabel: String {
    projectTitle ?? areaTitle ?? "Inbox"
  }

  private func shortDate(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d)    { return "Today" }
    if cal.isDateInTomorrow(d) { return "Tomorrow" }
    let f = DateFormatter(); f.dateFormat = "MMM d"
    return f.string(from: d)
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

// MARK: - Date picker sheet

/// Shared picker for both "When" (scheduled) and "Deadline" (due). 7-day
/// strip up top for the common case; "Pick a Date…" reveals the graphical
/// calendar for anything further out. Only the title, button labels, and
/// clear semantics differ between the two — layout is identical.
struct DatePickerSheet: View {
  @Environment(SectionTheme.self) private var theme
  let title: String
  let initialDate: Date?
  let setLabel: String        // e.g. "Set Date" / "Set Deadline"
  let updateLabel: String     // e.g. "Update Date" / "Update Deadline"
  let clearLabel: String      // e.g. "No Date" / "Remove Deadline"
  let onPick: (Date?) -> Void
  @Environment(\.dismiss) private var dismiss
  @Environment(\.a11yMotion) private var motion
  @State private var date: Date
  @State private var showingCalendar: Bool

  init(
    title: String,
    initialDate: Date? = nil,
    setLabel: String,
    updateLabel: String,
    clearLabel: String,
    onPick: @escaping (Date?) -> Void
  ) {
    self.title = title
    self.initialDate = initialDate
    self.setLabel = setLabel
    self.updateLabel = updateLabel
    self.clearLabel = clearLabel
    self.onPick = onPick
    let seed = initialDate ?? Calendar.current.startOfDay(for: Date())
    _date = State(initialValue: seed)
    // Open the calendar up-front only when the existing date sits
    // outside the strip — the strip already covers the next 7 days.
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
        WeekStrip(selected: initialDate.map { Calendar.current.startOfDay(for: $0) }) { d in
          onPick(d); dismiss()
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 6)
        .padding(.bottom, 8)

        Hairline()

        if showingCalendar {
          DatePicker(title, selection: $date, displayedComponents: [.date])
            .datePickerStyle(.graphical)
            .padding(.horizontal, Theme.hPadding)
        } else {
          Button {
            motion.run(.easeInOut(duration: 0.18)) { showingCalendar = true }
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

        Spacer(minLength: 0)

        VStack(spacing: 6) {
          Button {
            onPick(Calendar.current.startOfDay(for: date))
            dismiss()
          } label: {
            Text(initialDate == nil ? setLabel : updateLabel)
              .font(.system(size: 16, weight: .semibold))
              .foregroundStyle(.white)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 12)
              .background(theme.accent)
              .clipShape(Capsule())
          }
          .buttonStyle(.plain)

          Button {
            Haptics.warning()
            onPick(nil)
            dismiss()
          } label: {
            Text(clearLabel)
              .font(.system(size: 15, weight: .medium))
              .foregroundStyle(initialDate == nil ? Theme.inkSecondary : Theme.overdueRed)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 8)
          }
          .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.bottom, 12)
      }
      .navigationTitle(title)
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
