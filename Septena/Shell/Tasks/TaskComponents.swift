import SwiftUI

// MARK: - Checkbox

struct TaskCheckbox: View {
  @Environment(SectionTheme.self) private var theme
  /// Optional override — used by non-task items (habits/supplements/chores)
  /// to wear their section accent. `nil` means inherit list tint.
  var tint: Color? = nil
  let isDone: Bool
  /// When true (and not done), the checkbox stroke/fill switch to
  /// `Theme.todayAccent` to signal a task 'promoted to Today' — folding the
  /// today indicator into the checkbox itself, so it no longer sits as a
  /// separate glyph inline with the title.
  var isToday: Bool = false
  /// When true (and not done and not today), the checkbox stroke switches to
  /// `Theme.somedayAccent` (muted indigo) to signal a parked/deferred task.
  var isSomeday: Bool = false
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
  /// and fill to `Theme.todayAccent`; Someday rows use `Theme.somedayAccent`.
  private var boxStrokeColor: Color {
    if isToday   { return Theme.todayAccent }
    if isSomeday { return Theme.somedayAccent }
    return Theme.inkSecondary.opacity(0.55)
  }
  private var boxFillColor: Color {
    if isToday   { return Theme.todayAccent }
    if isSomeday { return Theme.somedayAccent }
    return Theme.inkSecondary.opacity(0.85)
  }

  var body: some View {
    Button(action: onToggle) {
      ZStack {
        if isDone {
          RoundedRectangle(cornerRadius: Self.boxCorner, style: .continuous)
            .fill(boxFillColor)
            .frame(width: Self.boxSize, height: Self.boxSize)
          Image(systemName: "checkmark")
            .scaledFont(size: Self.checkSize, weight: .bold)
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

// MARK: - Shared task row
//
// Canonical closed (non-editing) task row: checkbox + title + optional
// subtitle/notes glyph + trailing date. Used by the Tasks drawer
// (`TasksDestinationView`) and intended to become the single row the deep
// `TaskListView` surface renders too, so both surfaces stay visually
// identical. Carries its own h/v padding so it drops straight into a
// `DrawerSection(padding: .none)` the same way `LogEntryRow` does.

/// Leading provenance cue for an MCP/Claude-created row the user hasn't
/// engaged yet. Calm and peripheral (Things-style): it clears on contact via
/// `TaskMutator.acknowledge` and auto-decays after `AgentCue.decayWindow`.
/// Deliberately NOT a sparkle — a small accent dot reads as an unread marker.
/// To change the glyph, swap the `Circle()` for an `Image(systemName:)` here.
struct AgentCueMarker: View {
  var tint: Color
  var body: some View {
    Circle()
      .fill(tint)
      .frame(width: 6, height: 6)
      .accessibilityLabel(Text("Added by Claude, not yet seen"))
  }
}

struct TaskRow: View {
  let task: SeptenaTask
  var accent: Color
  /// Show the "promoted to Today" sun glyph in the checkbox. Pass `false`
  /// inside the Today list itself (where every row is already today, so
  /// the indicator is noise) and `true` elsewhere.
  var showsTodayIndicator: Bool = false
  /// Optional trailing text (e.g. a deadline like "May 30"). Rendered in
  /// `trailingTint` when set, otherwise secondary ink.
  var trailing: String? = nil
  var trailingTint: Color? = nil
  let onToggle: () -> Void
  var onTap: (() -> Void)? = nil

  private var isInactive: Bool {
    task.status == .done || task.status == .cancelled
  }
  private var hasNotes: Bool {
    !(task.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.iconTextGap) {
      TaskCheckbox(
        tint: accent,
        isDone: task.status == .done,
        isToday: task.isOnToday && showsTodayIndicator,
        isSomeday: task.status == .someday,
        onToggle: onToggle
      )
      .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }

      if task.showsAgentCue() {
        AgentCueMarker(tint: accent)
          .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }
      }

      Text(task.title)
        .font(.septenaTaskTitle)
        .foregroundStyle(isInactive ? Theme.inkSecondary : Theme.inkPrimary)
        .strikethrough(isInactive)
        .opacity(isInactive ? 0.5 : 1)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)

      if hasNotes {
        Image(systemName: "text.alignleft")
          .scaledFont(size: 12)
          .foregroundStyle(Theme.inkSecondary)
      }

      if task.recurrence != nil {
        Image(systemName: "arrow.triangle.2.circlepath")
          .scaledFont(size: 12)
          .foregroundStyle(Theme.inkSecondary)
      }

      if let trailing {
        Text(trailing)
          .font(.caption)
          .foregroundStyle(trailingTint ?? Theme.inkSecondary)
      }
    }
    .padding(.horizontal, Theme.hPadding)
    .padding(.vertical, Theme.rowVPadding)
    .contentShape(Rectangle())
    .onTapGesture { onTap?() }
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


// MARK: - Task row

// One unified row — the title is ALWAYS a `TextField`, so opening the editor
// is pure focus, never a Text↔TextField swap (the swap is what used to nudge
// the title sideways). Notes + the info button appear only while editing; the
// meta line + trailing date show otherwise. When the row isn't being edited
// the title field is `.allowsHitTesting(false)` so it reads as plain text and
// taps fall through to the row's selection / tap-to-edit. Done / cancelled
// tasks render a strikethrough `Text` (a TextField can't strike) — but those
// are never edited, so the edit path itself still has zero swap.
struct TaskRowView<MetaLine: View, TrailingDate: View>: View {
  @Environment(SectionTheme.self) private var theme
  @Environment(\.scenePhase) private var scenePhase

  let task: SeptenaTask
  let filter: TaskFilter
  /// True when this row is being renamed inline (the parent owns
  /// `editingTaskId`). Inline editing is title-ONLY — notes + all metadata
  /// live in the detail drawer reached via the trailing (i) button. There's no
  /// row expansion, so opening the editor is pure focus (no height change to
  /// animate, no layout pass to race the focus claim).
  let isEditing: Bool
  let accent: Color
  /// Title scratch buffer owned by the parent; bound only while `isEditing`.
  @Binding var editingTitle: String
  @ViewBuilder let metaLine: () -> MetaLine
  @ViewBuilder let trailingDate: () -> TrailingDate
  let onToggle: () -> Void
  let onCommit: () -> Void
  let onCancel: () -> Void
  /// Open the full edit drawer (notes + metadata) for this row — the (i)
  /// button, Reminders-style.
  let onOpenDetail: () -> Void

  @FocusState private var focused: Field?
  /// Set true the moment the user cancels, so the blur handler doesn't race
  /// in and auto-commit before the parent tears the editor down.
  @State private var cancelling = false

  enum Field { case title }

  private var isInactive: Bool { task.status == .done || task.status == .cancelled }
  private var hasNotes: Bool {
    !(task.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func handleCancel() {
    cancelling = true
    onCancel()
  }

  /// Claim title focus one tick after edit begins — assigning FocusState in
  /// the same frame the row enables races UIKit's input-session setup and the
  /// field silently fails to become first responder.
  private func claimFocus() {
    Task {
      try? await Task.sleep(for: .milliseconds(50))
      focused = .title
    }
  }

  /// The trailing (i) button shown while renaming — opens the full edit
  /// drawer (notes + metadata). Reminders-style: inline handles the title, the
  /// drawer handles everything else.
  private var detailButton: some View {
    Button {
      Haptics.pick()
      onOpenDetail()
    } label: {
      Image(systemName: "info.circle")
        .scaledFont(size: 18)
        .foregroundStyle(accent)
        .frame(width: 36, height: 30)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Details")
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.iconTextGap) {
      TaskCheckbox(
        tint: accent,
        isDone: task.status == .done,
        isToday: task.isOnToday && filter != .today,
        isSomeday: task.status == .someday && filter != .someday,
        onToggle: onToggle
      )
      .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }

      // Agent-created cue — display mode only; opening the editor (which sets
      // isEditing) is itself an acknowledgment, so the marker shouldn't linger.
      if !isEditing && task.showsAgentCue() {
        AgentCueMarker(tint: accent)
          .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 5 }
      }

      VStack(alignment: .leading, spacing: 4) {
        titleView
        // The meta line is display-only; while renaming, the row collapses to
        // just the title field so there's no height change to animate.
        if !isEditing { metaLine() }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      // Trailing: the (i) detail button while renaming; the notes glyph +
      // date in display mode. (Multi-select uses the native edit-mode circle
      // on iOS / selection highlight on macOS — no custom checkmark.)
      if isEditing {
        detailButton
      } else {
        if hasNotes {
          Image(systemName: "text.alignleft")
            .scaledFont(size: 12)
            .foregroundStyle(Theme.inkSecondary)
        }
        trailingDate()
      }
    }
    .padding(.horizontal, Theme.hPadding)
    .padding(.vertical, Theme.rowVPadding)
    .contentShape(Rectangle())
    // Edit shortcuts only while this row is the editor, so every row doesn't
    // register a duplicate scene-wide ⌘K / Esc.
    .background { if isEditing { commitShortcut } }
    .background { if isEditing { cancelShortcut } }
    .onKeyPress(.escape) {
      guard isEditing else { return .ignored }
      handleCancel()
      return .handled
    }
    // Focus lifecycle: claim on edit-start, resign on edit-end.
    .onChange(of: isEditing) { _, editing in
      if editing { cancelling = false; claimFocus() }
      else { focused = nil }
    }
    .onAppear { if isEditing { claimFocus() } }
    // Save-on-blur — focus left both fields while editing. Empty title on a
    // fresh draft cancels (deletes the placeholder); otherwise commits.
    .onChange(of: focused) { _, new in
      guard new == nil, isEditing, !cancelling else { return }
      if editingTitle.trimmingCharacters(in: .whitespaces).isEmpty {
        onCancel()
      } else {
        onCommit()
      }
    }
    // App backgrounded mid-edit — iOS may yank the keyboard without routing
    // focus through nil first.
    .onChange(of: scenePhase) { _, new in
      if new != .active && isEditing && !cancelling { onCommit() }
    }
    // Editor torn down by a parent reload / navigation while still editing.
    .onDisappear {
      if isEditing && !cancelling { onCommit() }
    }
  }

  @ViewBuilder private var titleView: some View {
    if isInactive && !isEditing {
      Text(task.title)
        .font(.septenaTaskTitle)
        .foregroundStyle(Theme.inkSecondary)
        .strikethrough()
        .opacity(0.5)
        .lineLimit(1)
        .truncationMode(.tail)
    } else {
      // Always a TextField (open rows) — `.allowsHitTesting(isEditing)` lets a
      // non-editing row read as text while taps fall through to the row.
      TextField("Title", text: isEditing ? $editingTitle : .constant(task.title))
        .textFieldStyle(.plain)
        .focusEffectDisabled()
        .font(.septenaTaskTitle)
        .foregroundStyle(Theme.inkPrimary)
        .lineLimit(1)
        .focused($focused, equals: .title)
        .submitLabel(.return)
        .onSubmit { onCommit() }
        .allowsHitTesting(isEditing)
        .fixedSize(horizontal: false, vertical: true)
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

// MARK: - Week strip

/// Which 7-day window a `WeekStrip` covers.
enum WeekStripRange {
  /// Today + the next 6 days. The scheduling default (When / Deadline).
  case upcoming
  /// The previous 6 days + today, with today rightmost. Used by the
  /// drawer time-travel picker, where you look *back* at past logs.
  case recent
}

/// Lean 7-day strip: today + next 6 days as Reminders-style chips
/// (weekday letter on top, day number below). One tap = one pick.
/// Used by both the When and Deadline pickers so quick scheduling
/// within the coming week never opens a full calendar.
struct WeekStrip: View {
  @Environment(SectionTheme.self) private var theme
  /// Currently-selected day (start-of-day), or nil for none.
  let selected: Date?
  /// Window the strip spans. Defaults to `.upcoming` so existing
  /// scheduling callers are unaffected.
  var range: WeekStripRange = .upcoming
  let onPick: (Date) -> Void

  private static let cal = Calendar.current
  private static let weekdayFmt: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "EEEEE"; return f   // single letter
  }()

  private var days: [Date] {
    let today = Self.cal.startOfDay(for: Date())
    switch range {
    case .upcoming:
      return (0..<7).compactMap { Self.cal.date(byAdding: .day, value: $0, to: today) }
    case .recent:
      return (-6...0).compactMap { Self.cal.date(byAdding: .day, value: $0, to: today) }
    }
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
              .scaledFont(size: 11, weight: .medium)
              .foregroundStyle(isSelected ? Color.white : Theme.inkSecondary)
            Text("\(Self.cal.component(.day, from: d))")
              .scaledFont(size: 17, weight: .semibold, design: .rounded)
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
/// strip up top for the common case; "Pick a Date…" reveals a compact
/// date field for anything further out. Only the title, button labels, and
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

  /// Fitted sheet height. Content is fixed (the "Pick a Date…" row and the
  /// compact-field row share a height), so the sheet need not open half-screen.
  /// `.large` stays available as a drag-up fallback for big Dynamic Type.
  static let sheetHeight: CGFloat = 320

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
          // Compact field: a tidy row that pops Apple's native calendar
          // overlay. Fits the medium detent without the graphical grid's
          // clipping/scroll fight, and picks up the accent tint.
          HStack(spacing: 14) {
            Image(systemName: "calendar")
              .scaledFont(size: 18)
              .foregroundStyle(Theme.inkSecondary)
              .frame(width: 24)
            Text("Date")
              .font(.septenaSidebarRow)
              .foregroundStyle(.primary)
            Spacer()
            DatePicker("", selection: $date, displayedComponents: [.date])
              .labelsHidden()
              .datePickerStyle(.compact)
              .tint(theme.accent)
          }
          .padding(.horizontal, Theme.hPadding)
          .frame(height: Theme.sidebarRowHeight)
        } else {
          Button {
            motion.run(.easeInOut(duration: 0.18)) { showingCalendar = true }
          } label: {
            HStack(spacing: 14) {
              Image(systemName: "calendar")
                .scaledFont(size: 18)
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
              .scaledFont(size: 16, weight: .semibold)
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
              .scaledFont(size: 15, weight: .medium)
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
              .scaledFont(size: 16, weight: .semibold)
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
                .scaledFont(size: 15, weight: .medium)
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
        .scaledFont(size: 16)
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
              .scaledFont(size: 16)
              .foregroundStyle(action.role == .destructive ? Theme.overdueRed : Theme.inkSecondary)
              .frame(width: 22)
            Text(action.title)
              .font(.septenaSidebarRow)
              .foregroundStyle(action.role == .destructive ? Theme.overdueRed : Theme.inkPrimary)
            Spacer()
            if action.selected {
              Image(systemName: "checkmark")
                .scaledFont(size: 14, weight: .semibold)
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
