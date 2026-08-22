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
/// path needed.
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

  /// Fitted sheet height: Today row + 7-day strip + calendar button + Clear.
  /// `.large` stays available as a drag-up fallback for big Dynamic Type.
  static let sheetHeight: CGFloat = 320

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
  let initialPaused: Bool
  let onPick: (Recurrence?) -> Void
  let onPauseChanged: ((Bool) -> Void)?
  @Environment(\.dismiss) private var dismiss

  @State private var unit: Recurrence.Unit
  @State private var interval: Int
  @State private var afterCompletion: Bool
  @State private var paused: Bool

  init(initial: Recurrence?, onPick: @escaping (Recurrence?) -> Void) {
    self.initial = initial
    self.initialPaused = false
    self.onPick = onPick
    self.onPauseChanged = nil
    _unit = State(initialValue: initial?.unit ?? .day)
    _interval = State(initialValue: initial?.interval ?? 1)
    _afterCompletion = State(initialValue: initial?.afterCompletion ?? true)
    _paused = State(initialValue: false)
  }

  init(initial: Recurrence?, hasScheduledDate: Bool, initialPaused: Bool = false,
       onPick: @escaping (Recurrence?) -> Void,
       onPauseChanged: ((Bool) -> Void)? = nil) {
    self.initial = initial
    self.hasScheduledDate = hasScheduledDate
    self.initialPaused = initialPaused
    self.onPick = onPick
    self.onPauseChanged = onPauseChanged
    _unit = State(initialValue: initial?.unit ?? .day)
    _interval = State(initialValue: initial?.interval ?? 1)
    // With no date the effective anchor IS completion — show what will happen.
    _afterCompletion = State(initialValue: hasScheduledDate ? (initial?.afterCompletion ?? true) : true)
    _paused = State(initialValue: initialPaused)
  }

  var body: some View {
    NavigationStack {
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
              Text("day").tag(Recurrence.Unit.day)
              Text("week").tag(Recurrence.Unit.week)
              Text("month").tag(Recurrence.Unit.month)
            }
            .pickerStyle(.menu)
            .tint(Theme.inkPrimary)

            Text(cadenceDescription())
              .font(.system(size: 15, weight: .medium))
              .foregroundStyle(Theme.inkPrimary)
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
        .padding(.top, 16)

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

        Spacer(minLength: 18)

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
            onPick(Recurrence(unit: unit, interval: interval, afterCompletion: afterCompletion))
            dismiss()
          }
          .buttonStyle(.borderedProminent)
          .tint(theme.accent)
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.bottom, 18)
      }
      .navigationTitle("Repeat")
      .septenaInlineTitle()
    }
    .macSheetFrame(width: 520, height: 330)
  }

  private func cadenceDescription() -> String {
    let unitName: String
    switch unit {
    case .day: unitName = interval == 1 ? "day" : "days"
    case .week: unitName = interval == 1 ? "week" : "weeks"
    case .month: unitName = interval == 1 ? "month" : "months"
    }
    return afterCompletion
      ? "\(unitName) after previous item is checked off."
      : "\(unitName) after previous scheduled date."
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
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
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
