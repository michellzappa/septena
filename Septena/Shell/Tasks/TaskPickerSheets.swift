import SwiftUI

// The three modal pickers a task row can open — When (date), Repeat
// (recurrence), and Move (area/project). Self-contained sheet UI; split out of
// TaskComponents.swift, which was carrying them alongside the row primitives.

// MARK: - Date picker sheet

/// Shared picker for both "When" (scheduled) and "Deadline" (due). 7-day
/// strip up top for the common case; a single capsule button pops the full
/// month calendar (popover on iPad/Mac, small sheet on iPhone) for anything
/// further out. Only the title, button labels, and clear semantics differ
/// between the two — layout is identical.
struct DatePickerSheet: View {
  @Environment(SectionTheme.self) private var theme
  @Environment(DayClock.self) private var clock
  let title: String
  let initialDate: Date?
  let setLabel: String        // e.g. "Set Date" / "Set Deadline"
  let updateLabel: String     // e.g. "Update Date" / "Update Deadline"
  let clearLabel: String      // e.g. "No Date" / "Remove Deadline"
  let onPick: (Date?) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var date: Date
  @State private var showingCalendar: Bool
  @State private var configuredStrip = false

  private var cal: Calendar { Calendar.current }

  private var anchorDay: Date {
    cal.startOfDay(for: SeptenaDate.parse(clock.today) ?? clock.now)
  }
  private var tomorrow: Date { cal.date(byAdding: .day, value: 1, to: anchorDay) ?? anchorDay }
  /// The coming Saturday — or today, if today is already the weekend.
  private var weekend: Date {
    if cal.isDateInWeekend(anchorDay) { return anchorDay }
    var comps = DateComponents(); comps.weekday = 7   // Saturday
    let next = cal.nextDate(after: anchorDay, matching: comps, matchingPolicy: .nextTime)
    return cal.startOfDay(for: next ?? anchorDay)
  }
  /// The upcoming Monday.
  private var nextWeek: Date {
    var comps = DateComponents(); comps.weekday = 2   // Monday
    let next = cal.nextDate(after: anchorDay, matching: comps, matchingPolicy: .nextTime)
    return cal.startOfDay(for: next ?? anchorDay)
  }

  /// Fitted sheet height: a semantic pill row + 7-day strip + calendar button +
  /// actions. `.large` stays available as a drag-up fallback for big Dynamic
  /// Type (or when the pills wrap to a second row on a narrow phone).
  static let sheetHeight: CGFloat = 380

  /// Locale-ordered short date for the confirm button ("Wed, Jul 8").
  private static let setDateFmt: DateFormatter = {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("EEEMMMd")
    return f
  }()

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
    _date = State(initialValue: initialDate ?? Date())
    _showingCalendar = State(initialValue: false)
  }

  private func configureStripIfNeeded() {
    guard !configuredStrip else { return }
    configuredStrip = true
    if initialDate == nil { date = anchorDay }
  }

  /// Language-first quick pick (Today / Tomorrow / This weekend / Next week).
  /// Same one-tap-and-dismiss contract as the day strip; highlights when the
  /// current value already lands on it. Matches the composer's `chip` capsule.
  @ViewBuilder
  private func quickChip(_ title: String, target: Date) -> some View {
    let active = initialDate.map { cal.isDate($0, inSameDayAs: target) } ?? false
    Button {
      Haptics.pick()
      onPick(cal.startOfDay(for: target)); dismiss()
    } label: {
      Text(title)
        .font(.septenaLabel)
        .foregroundStyle(active ? Theme.inkPrimary : Theme.inkSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .background(Capsule().fill(active ? theme.accent.opacity(0.42) : Theme.mutedSurface))
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        FlowLayout(spacing: 8) {
          quickChip("Today", target: anchorDay)
          quickChip("Tomorrow", target: tomorrow)
          quickChip("This weekend", target: weekend)
          quickChip("Next week", target: nextWeek)
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 10)
        .padding(.bottom, 8)

        WeekStrip(selected: initialDate.map { Calendar.current.startOfDay(for: $0) }) { d in
          onPick(d); dismiss()
        }
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .onAppear { configureStripIfNeeded() }

        Hairline()

        // One prominent, capsule-weight button that pops Apple's month
        // calendar in a single tap — popover on iPad/Mac, a small sheet on
        // iPhone. No inline reveal; the strip already covers the common week.
        Button {
          Haptics.pick()
          showingCalendar = true
        } label: {
          HStack(spacing: 8) {
            Image(systemName: "calendar")
              .scaledFont(size: 17)
              .foregroundStyle(Theme.inkSecondary)
            Text("Pick another date")
              .scaledFont(size: 16, weight: .medium)
              .foregroundStyle(.primary)
            Image(systemName: "chevron.right")
              .scaledFont(size: 13, weight: .semibold)
              .foregroundStyle(Theme.iconMuted)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 13)
          .background(Capsule().fill(Theme.inkSecondary.opacity(0.08)))
          .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
          .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 12)
        .popover(isPresented: $showingCalendar) {
          DatePicker("", selection: $date, displayedComponents: [.date])
            .datePickerStyle(.graphical)
            .labelsHidden()
            .tint(theme.accent)
            .padding(8)
            .frame(minWidth: 300, idealWidth: 320, minHeight: 320)
            .presentationDetents([.medium])
            .presentationCompactAdaptation(.sheet)
            .onChange(of: date) { showingCalendar = false }
        }

        Spacer(minLength: 0)

        VStack(spacing: 6) {
          Button {
            onPick(Calendar.current.startOfDay(for: date))
            dismiss()
          } label: {
            Text("\(initialDate == nil ? setLabel : updateLabel) · \(Self.setDateFmt.string(from: date))")
              .scaledFont(size: 16, weight: .semibold)
              .foregroundStyle(AdaptiveColor.inkOnSolidFill(theme.accent))
              .lineLimit(1)
              .minimumScaleFactor(0.8)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 12)
              .background(theme.accent)
              .clipShape(Capsule())
          }
          .buttonStyle(.plain)

          // Only offer "remove" when there's actually a date to clear.
          if initialDate != nil {
            Button {
              Haptics.warning()
              onPick(nil)
              dismiss()
            } label: {
              Text(clearLabel)
                .scaledFont(size: 15, weight: .medium)
                .foregroundStyle(Theme.overdueRed)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
          }
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
    .macSheetFrame(width: 420, height: Self.sheetHeight + 60)
  }
}

// MARK: - Recurrence picker sheet

/// "Repeat" — set or clear a recurrence rule. v1: daily / weekly / monthly,
/// interval stepper, and fixed-vs-after-completion toggle. the reference design's canonical
/// picker has more (weekday selection, ends-rules) — to be added when needed.
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
            Text(intervalLabel())
              .font(.septenaSidebarRow)
              .foregroundStyle(Theme.inkSecondary)
          }
          .labelsHidden()
          Text(intervalLabel())
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
                 ? "Next instance \(intervalLabel()) after you mark this done."
                 : "Next instance \(intervalLabel()) after the previous scheduled date.")
              .font(.caption)
              .foregroundStyle(Theme.inkSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .tint(theme.accent)
        .disabled(!hasScheduledDate)
        .padding(.horizontal, Theme.hPadding)
        .padding(.top, 18)

        if !hasScheduledDate {
          Text("Give the task a date to repeat on a fixed schedule.")
            .font(.caption)
            .foregroundStyle(Theme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.hPadding)
            .padding(.top, 8)
        }

        if initial != nil, let onPauseChanged {
          Button {
            paused.toggle()
            onPauseChanged(paused)
          } label: {
            Label(paused ? "Resume Repeat" : "Pause Repeat",
                  systemImage: paused ? "play.circle" : "pause.circle")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.bordered)
          .tint(theme.accent)
          .padding(.horizontal, Theme.hPadding)
          .padding(.top, 12)
        }

        Spacer()

        VStack(spacing: 10) {
          Button {
            onPick(Recurrence(unit: unit, interval: interval, afterCompletion: afterCompletion))
            dismiss()
          } label: {
            Text(initial == nil ? "Set Repeat" : "Update Repeat")
              .scaledFont(size: 16, weight: .semibold)
              .foregroundStyle(AdaptiveColor.inkOnSolidFill(theme.accent))
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
    .macSheetFrame(width: 420, height: 380)
  }

  /// Pluralized "N days/weeks/months" via the String Catalog (one/other).
  private func intervalLabel() -> String {
    switch unit {
    case .day:   return String(localized: "\(interval) days")
    case .week:  return String(localized: "\(interval) weeks")
    case .month: return String(localized: "\(interval) months")
    }
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
