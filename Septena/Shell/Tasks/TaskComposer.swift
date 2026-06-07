import SwiftUI

// The liquid-glass task composer — one floating card used for both creating
// and editing a task. Title + notes sit at the top; the electives (Today,
// When, Deadline, Repeat, List) are glass pills underneath. A pill shows its
// glyph + label when unset and its glyph + value (accent-tinted glass) when
// set. Tapping a date/repeat pill expands its editor inline inside the card;
// the longer List picker opens as a sheet. See docs/DesignSpec.md §5.5 —
// glass is the floating-control material; content rows stay on system fills.

// MARK: - Composer card

struct TaskComposerCard: View {
  enum Mode {
    case create(TaskFilter)
    case edit(SeptenaTask)
  }

  let mode: Mode
  let areas: [Area]
  let projects: [Project]
  let accent: Color
  /// Close the card (animated by the caller).
  let onDismiss: () -> Void
  /// Fired after a successful create/edit so the list reloads.
  let onDone: () -> Void

  @Environment(TaskMutator.self) private var mutator
  @State private var draft = TaskDraft()
  @State private var seeded = false
  @FocusState private var titleFocused: Bool

  private var isEditing: Bool {
    if case .edit = mode { return true }
    return false
  }

  private var headerTitle: String { isEditing ? "Edit To-Do" : "New Task" }

  private var destinationLabel: String {
    if case .create = mode { return draft.listLabel(areas: areas, projects: projects) }
    return ""
  }

  var body: some View {
    // Vertically centered: with the keyboard up, SwiftUI's avoidance lifts the
    // card so it settles midway (just above the keyboard) instead of pinned to
    // the very top. The card is compact enough to fit; expanding a date/repeat
    // pill drops the keyboard (see onInteractStart), freeing room to grow.
    ZStack {
      // Dimmed scrim — tap anywhere outside the card to cancel.
      Color.black.opacity(0.22)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }

      VStack(alignment: .leading, spacing: 12) {
        header

        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 10) {
            TextField("What needs doing?", text: $draft.title)
              .textFieldStyle(.plain)
              .font(.septenaTaskTitle)
              .focused($titleFocused)
              .submitLabel(.done)
              .onSubmit { if draft.canSave { commit() } }

            Button(action: commit) {
              Image(systemName: isEditing ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                .font(.system(size: 26))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(draft.canSave ? accent : Theme.inkSecondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!draft.canSave)
          }

          Divider()

          // Optional notes — room to paste or explain context.
          TextField("Notes or pasted context (optional)", text: $draft.notes, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.septenaNotes)
            .foregroundStyle(Theme.inkSecondary)
            .lineLimit(1...5)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.secondaryGroupedBackground,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))

        TaskAttributeBar(
          draft: $draft,
          areas: areas,
          projects: projects,
          accent: accent,
          onInteractStart: { titleFocused = false }
        )
      }
      .padding(16)
      .background(.ultraThinMaterial,
                  in: RoundedRectangle(cornerRadius: 22, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .strokeBorder(Color.white.opacity(0.12))
      )
      .shadow(color: .black.opacity(0.20), radius: 22, y: 10)
      .padding(.horizontal, 14)
    }
    .onAppear(perform: seed)
  }

  // MARK: - Header

  @ViewBuilder
  private var header: some View {
    HStack(spacing: 8) {
      Text(headerTitle)
        .font(.septenaSectionTitle)
        .foregroundStyle(Theme.inkPrimary)
      Spacer()
      if case .create = mode {
        Text("Adding to \(destinationLabel)")
          .font(.septenaMeta)
          .foregroundStyle(Theme.inkSecondary)
      } else if case .edit(let task) = mode {
        Menu {
          Button { mutator.moveToSomeday(id: task.id); finish() } label: {
            Label("Move to Someday", systemImage: "moon.stars")
          }
          Button { mutator.cancel(id: task.id); finish() } label: {
            Label("Cancel Task", systemImage: "xmark.circle")
          }
          Divider()
          Button(role: .destructive) { mutator.delete(id: task.id); finish() } label: {
            Label("Delete To-Do", systemImage: "trash")
          }
        } label: {
          Image(systemName: "ellipsis.circle")
            .font(.system(size: 20))
            .foregroundStyle(Theme.inkSecondary)
        }
      }
    }
  }

  // MARK: - Lifecycle

  private func seed() {
    guard !seeded else { return }
    seeded = true
    switch mode {
    case .create(let filter):
      draft = TaskDraft(filter: filter)
      // Focus after the present animation settles — inside a fullScreenCover an
      // immediate focus is dropped before the field joins the responder chain,
      // so the keyboard wouldn't come up on open.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { titleFocused = true }
    case .edit(let task):
      draft = TaskDraft(task: task)
      // Opening the editor counts as engagement — clear any agent cue.
      mutator.acknowledge(id: task.id)
    }
  }

  private func commit() {
    guard draft.canSave else { return }
    Haptics.tick()
    switch mode {
    case .create:
      draft.create(via: mutator)
      AddInfoSection.tasks.notifyTilesChanged()
    case .edit(let task):
      draft.update(task, via: mutator)
    }
    finish()
  }

  /// Reload the caller's list and close.
  private func finish() {
    onDone()
    onDismiss()
  }
}

// MARK: - Attribute pill bar

/// The horizontal rail of elective pills under the title. Owns which date /
/// repeat editor is expanded inline; the List picker opens as a sheet.
struct TaskAttributeBar: View {
  @Binding var draft: TaskDraft
  let areas: [Area]
  let projects: [Project]
  let accent: Color
  /// Called when a pill expands / a sheet opens, so the card can drop the
  /// title-field keyboard before showing a calendar.
  let onInteractStart: () -> Void

  enum Expanded { case when, deadline, repeatRule }
  @State private var expanded: Expanded?
  @State private var showingList = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Pills wrap onto extra rows as needed (FlowLayout) so every elective
      // stays visible — no offscreen horizontal scroll. "Today" isn't its own
      // pill: it's the same stored state as When=Today, so it lives inside the
      // When control (quick chip) instead of duplicating the rail.
      FlowLayout(spacing: 8) {
        AttributePill(icon: "calendar", label: "When",
                      value: whenValue, isSet: whenIsSet, isActive: expanded == .when,
                      accent: accent) { toggle(.when) }

        AttributePill(icon: "flag", label: "Deadline",
                      value: draft.deadline.map(Self.dateLabel),
                      isSet: draft.deadline != nil, isActive: expanded == .deadline,
                      accent: accent) { toggle(.deadline) }

        AttributePill(icon: "repeat", label: "Repeat",
                      value: draft.recurrence?.shortLabel,
                      isSet: draft.recurrence != nil, isActive: expanded == .repeatRule,
                      accent: accent) { toggleRepeat() }

        AttributePill(icon: "folder", label: "List",
                      value: listValue,
                      isSet: draft.areaId != nil || draft.projectId != nil,
                      isActive: false, accent: accent) {
          onInteractStart()
          withAnimation(.snappy(duration: 0.2)) { expanded = nil }
          showingList = true
        }
      }

      inlineEditor
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
  }

  /// The List pill shows its destination only when explicitly filed somewhere
  /// (so an unset pill reads "List", not "Inbox").
  private var listValue: String? {
    (draft.areaId != nil || draft.projectId != nil)
      ? draft.listLabel(areas: areas, projects: projects)
      : nil
  }

  /// "When" folds in Today: a task pinned to today (no date) reads "Today",
  /// a future planning date reads its date.
  private var whenIsSet: Bool { draft.scheduled != nil || draft.onToday }
  private var whenValue: String? {
    if let s = draft.scheduled { return Self.dateLabel(s) }
    return draft.onToday ? "Today" : nil
  }

  @ViewBuilder
  private var inlineEditor: some View {
    switch expanded {
    case .when:
      InlineWhenPanel(onToday: $draft.onToday, scheduled: $draft.scheduled, accent: accent)
        .transition(.opacity.combined(with: .move(edge: .top)))
    case .deadline:
      InlineDatePanel(date: $draft.deadline, accent: accent)
        .transition(.opacity.combined(with: .move(edge: .top)))
    case .repeatRule:
      InlineRepeatPanel(recurrence: $draft.recurrence, accent: accent)
        .transition(.opacity.combined(with: .move(edge: .top)))
    case nil:
      EmptyView()
    }
  }

  private func toggle(_ field: Expanded) {
    onInteractStart()
    withAnimation(.snappy(duration: 0.22)) {
      expanded = (expanded == field) ? nil : field
    }
  }

  private func toggleRepeat() {
    onInteractStart()
    withAnimation(.snappy(duration: 0.22)) {
      if expanded == .repeatRule {
        expanded = nil
      } else {
        // Tapping Repeat turns it on with a sensible default (Things-style);
        // the panel's "Don't Repeat" clears it.
        if draft.recurrence == nil { draft.recurrence = Recurrence(unit: .week) }
        expanded = .repeatRule
      }
    }
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
  let accent: Color
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: icon)
          .font(.system(size: 12, weight: .semibold))
        Text(isSet ? (value ?? label) : label)
          .font(.septenaLabel)
          .lineLimit(1)
      }
      .foregroundStyle(isSet ? Theme.inkPrimary : Theme.inkSecondary)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .glassEffect(
      .regular.tint((isSet || isActive) ? accent.opacity(0.42) : .clear).interactive(),
      in: .capsule
    )
  }
}

// MARK: - Inline "When" editor

/// The scheduling control — manages both the `today` pin and a planning
/// `Date?` so "Today" doesn't need its own pill. Quick chips (Today / Tomorrow
/// / Weekend) sit above a graphical calendar; picking today normalizes back to
/// the pinned-Today state. Expanded under the When pill.
private struct InlineWhenPanel: View {
  @Binding var onToday: Bool
  @Binding var scheduled: Date?
  let accent: Color

  private var cal: Calendar { Calendar.current }
  private var today: Date { cal.startOfDay(for: Date()) }
  private var tomorrow: Date { cal.date(byAdding: .day, value: 1, to: today) ?? today }
  /// Next Saturday.
  private var weekend: Date {
    var comps = DateComponents(); comps.weekday = 7
    let next = cal.nextDate(after: today, matching: comps, matchingPolicy: .nextTime) ?? today
    return cal.startOfDay(for: next)
  }

  private var isSet: Bool { scheduled != nil || onToday }

  private var calendarBinding: Binding<Date> {
    Binding(get: { scheduled ?? today }, set: { setDate($0) })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        chip("Today", active: onToday && scheduled == nil) { setToday() }
        chip("Tomorrow", active: isSameDay(scheduled, tomorrow)) { setDate(tomorrow) }
        chip("Weekend", active: isSameDay(scheduled, weekend)) { setDate(weekend) }
      }

      DatePicker("", selection: calendarBinding, displayedComponents: [.date])
        .datePickerStyle(.graphical)
        .tint(accent)

      if isSet {
        Button(role: .destructive) {
          withAnimation(.snappy(duration: 0.2)) { onToday = false; scheduled = nil }
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

  private func setToday() { onToday = true; scheduled = nil }
  private func setDate(_ d: Date) {
    let day = cal.startOfDay(for: d)
    if cal.isDateInToday(day) { setToday() }
    else { onToday = false; scheduled = day }
  }
  private func isSameDay(_ a: Date?, _ b: Date) -> Bool {
    a.map { cal.isDate($0, inSameDayAs: b) } ?? false
  }

  @ViewBuilder
  private func chip(_ title: String, active: Bool, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.septenaLabel)
        .foregroundStyle(active ? Theme.inkPrimary : Theme.inkSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.tint(active ? accent.opacity(0.42) : .clear).interactive(), in: .capsule)
  }
}

// MARK: - Inline date editor

/// A graphical calendar that writes a `Date?`. Selecting a day sets it;
/// "Clear" removes it. Lives inside the composer card when the Deadline pill
/// is expanded.
private struct InlineDatePanel: View {
  @Binding var date: Date?
  let accent: Color

  private var bound: Binding<Date> {
    Binding(get: { date ?? Calendar.current.startOfDay(for: Date()) },
            set: { date = Calendar.current.startOfDay(for: $0) })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      DatePicker("", selection: bound, displayedComponents: [.date])
        .datePickerStyle(.graphical)
        .tint(accent)
      if date != nil {
        Button(role: .destructive) {
          withAnimation(.snappy(duration: 0.2)) { date = nil }
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

  private var unit: Binding<Recurrence.Unit> {
    Binding(get: { recurrence?.unit ?? .week },
            set: { recurrence = Recurrence(unit: $0, interval: recurrence?.interval ?? 1,
                                           afterCompletion: recurrence?.afterCompletion ?? true) })
  }
  private var interval: Binding<Int> {
    Binding(get: { recurrence?.interval ?? 1 },
            set: { recurrence = Recurrence(unit: recurrence?.unit ?? .week, interval: $0,
                                           afterCompletion: recurrence?.afterCompletion ?? true) })
  }
  private var afterCompletion: Binding<Bool> {
    Binding(get: { recurrence?.afterCompletion ?? true },
            set: { recurrence = Recurrence(unit: recurrence?.unit ?? .week,
                                           interval: recurrence?.interval ?? 1, afterCompletion: $0) })
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
        Text("Every \(interval.wrappedValue) \(unitNoun(plural: interval.wrappedValue != 1))")
          .font(.septenaSidebarRow)
          .foregroundStyle(Theme.inkPrimary)
      }

      Toggle("After completion", isOn: afterCompletion)
        .font(.septenaSidebarRow)
        .tint(accent)

      Button(role: .destructive) {
        withAnimation(.snappy(duration: 0.2)) { recurrence = nil }
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
  }

  private func unitNoun(plural: Bool) -> String {
    switch recurrence?.unit ?? .week {
    case .day:   return plural ? "days" : "day"
    case .week:  return plural ? "weeks" : "week"
    case .month: return plural ? "months" : "month"
    }
  }
}
