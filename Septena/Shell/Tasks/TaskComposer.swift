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
  @Environment(\.modelContext) private var modelContext
  @State private var draft = TaskDraft()
  @State private var seeded = false
  /// Drives the fade/pop-in (the cover present animation is suppressed, so this
  /// is the entrance the user sees).
  @State private var shown = false
  @FocusState private var titleFocused: Bool
  /// SuggestionEngine's learned area/project pick for the current title (the
  /// "Suggested" chip). Recomputed as the title changes; create-mode only.
  @State private var suggestedList: SuggestionEngine.Suggestion?

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
      // Dimmed scrim — tapping outside commits the task (Reminders-style) when
      // there's something to save, otherwise just closes (no phantom task).
      Color.black.opacity(0.22)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { dismissSaving() }

      VStack(alignment: .leading, spacing: 12) {
        header

        VStack(alignment: .leading, spacing: 8) {
          TextField("What needs doing?", text: $draft.title, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.septenaTaskTitle)
            .focused($titleFocused)
            .lineLimit(1...4)
            // macOS: a vertical-axis field doesn't insert a newline on plain
            // Return (Option-Return does) — it fires onSubmit, so the iOS
            // newline-as-save trick below never triggers. Commit here instead.
            .onSubmit { if draft.canSave { commit() } }

          Divider()

          // Optional notes — room to paste or explain context.
          TextField("Notes", text: $draft.notes, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.septenaNotes)
            .foregroundStyle(Theme.inkSecondary)
            .lineLimit(3...10)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.secondaryGroupedBackground,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))

        quickEntryChips

        TaskAttributeBar(
          draft: $draft,
          areas: areas,
          projects: projects,
          accent: accent,
          onInteractStart: { titleFocused = false }
        )

        // The agent exchange lives with the task, below the fields (edit mode
        // only — a not-yet-created task has no id/conversation). Renders nothing
        // until a conversation exists. docs/TASK_CONVERSATIONS_PHASE1.md.
        if case .edit(let task) = mode {
          ConversationCard(taskID: task.id)
        }
      }
      .padding(16)
      // White (paper) glass: tint the translucent material with the system
      // background so it reads white in light mode instead of picking up the
      // dim scrim as gray. Stays adaptive — near-black in dark mode.
      .background {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        shape.fill(.ultraThinMaterial)
          .overlay(shape.fill(Theme.paperBackground.opacity(0.6)))
      }
      .overlay(
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .strokeBorder(Color.white.opacity(0.12))
      )
      .shadow(color: .black.opacity(0.20), radius: 22, y: 10)
      .padding(.horizontal, 14)
    }
    .opacity(shown ? 1 : 0)
    #if os(macOS)
    // Escape cancels — close without saving (the scrim tap commits; Esc doesn't).
    .onExitCommand { onDismiss() }
    #endif
    .onAppear(perform: seed)
    .onChange(of: draft.title) { _, newValue in
      // The title wraps (axis: .vertical) so long titles show in full instead
      // of truncating — but it stays single-line in spirit: a Return inserts a
      // newline, which we treat as "save". Strip it and commit (or just tidy it
      // away when there's nothing to save yet).
      if newValue.contains("\n") {
        draft.title = newValue.replacingOccurrences(of: "\n", with: " ")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.canSave { commit(); return }
      }
      updateSuggestion()
    }
  }

  private func updateSuggestion() {
    guard case .create = mode else { return }
    if draft.projectId != nil || draft.areaId != nil {
      suggestedList = nil
    } else {
      suggestedList = SuggestionEngine.shared.suggest(forText: draft.title)
    }
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
          // Conclude the task right from the editor — completes and closes.
          Button { mutator.complete(id: task.id); finish() } label: {
            Label("Complete", systemImage: "checkmark.circle")
          }
          // "Move to Someday" now lives in the When control. This menu keeps
          // the terminal actions.
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
      // Confirm / save — top-right, just past the … menu, instead of crammed
      // into the title row.
      confirmButton
    }
  }

  /// Commits the draft and closes. Create shows an up-arrow, edit a checkmark;
  /// dims until there's a savable title.
  private var confirmButton: some View {
    Button(action: commit) {
      Image(systemName: isEditing ? "checkmark.circle.fill" : "arrow.up.circle.fill")
        .font(.system(size: 26))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(draft.canSave ? accent : Theme.inkSecondary.opacity(0.4))
    }
    .buttonStyle(.plain)
    .disabled(!draft.canSave)
    .accessibilityLabel(isEditing ? "Save" : "Add Task")
  }

  // MARK: - Quick entry

  /// Date phrases and #project / @area / !today tokens detected in the title,
  /// limited to ones whose field isn't already set. Create-mode only — parsing
  /// an existing title on edit would surface noise.
  private var detectedTokens: [DetectedToken] {
    guard case .create = mode else { return [] }
    return TaskTitleParser.detect(in: draft.title, projects: projects, areas: areas)
      .filter(isUnset)
  }

  private func isUnset(_ token: DetectedToken) -> Bool {
    switch token.kind {
    case .today, .date: return !draft.onToday && draft.scheduled == nil && !draft.someday
    case .project:      return draft.projectId == nil
    case .area:         return draft.areaId == nil && draft.projectId == nil
    }
  }

  /// Whether to offer the learned "Suggested list" chip — only when the user
  /// hasn't filed the task somewhere already.
  private var listSuggestion: SuggestionEngine.Suggestion? {
    guard draft.projectId == nil, draft.areaId == nil else { return nil }
    return suggestedList
  }

  /// Tap-to-apply chips: tokens parsed out of the title (date / #project /
  /// @area / !today) plus the learned list suggestion. Nothing is applied
  /// silently — the user confirms each (and committing applies parsed tokens).
  @ViewBuilder
  private var quickEntryChips: some View {
    let tokens = detectedTokens
    let suggestion = listSuggestion
    if !tokens.isEmpty || suggestion != nil {
      FlowLayout(spacing: 8) {
        ForEach(tokens) { token in
          chip(icon: token.icon, leading: "plus", text: token.displayText) { apply(token) }
        }
        if let s = suggestion {
          chip(icon: s.kind == .project ? "number" : "folder",
               leading: "sparkles", text: s.title) { applySuggestedList() }
        }
      }
      .transition(.opacity)
    }
  }

  /// A small glass action chip: a leading hint glyph (`plus` to add a parsed
  /// token, `sparkles` for the smart suggestion), the field's icon, and a label.
  private func chip(icon: String, leading: String, text: String,
                    _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: leading).font(.system(size: 10, weight: .bold))
        Image(systemName: icon).font(.system(size: 11, weight: .semibold))
        Text(text).font(.septenaLabel).lineLimit(1)
      }
      .foregroundStyle(accent)
      .padding(.horizontal, 11)
      .padding(.vertical, 6)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.tint(accent.opacity(0.28)).interactive(), in: .capsule)
  }

  private func applySuggestedList() {
    guard let s = suggestedList else { return }
    Haptics.tick()
    withAnimation(.snappy(duration: 0.2)) {
      switch s.kind {
      case .project:
        draft.projectId = s.id
        draft.areaId = projects.first { $0.id == s.id }?.area
      case .area:
        draft.areaId = s.id; draft.projectId = nil
      }
      suggestedList = nil
    }
  }

  /// Apply a detected token to the draft and strip its phrase from the title.
  private func applyToken(_ token: DetectedToken) {
    switch token.kind {
    case .today:
      draft.setToday()
    case .date(let d):
      draft.setScheduled(d)
    case .project(let id, _):
      draft.projectId = id
      draft.areaId = projects.first { $0.id == id }?.area
    case .area(let id, _):
      draft.areaId = id; draft.projectId = nil
    }
    draft.title = TaskTitleParser.strip(token.phrase, from: draft.title)
  }

  private func apply(_ token: DetectedToken) {
    Haptics.tick()
    withAnimation(.snappy(duration: 0.2)) { applyToken(token) }
    updateSuggestion()
  }

  // MARK: - Lifecycle

  private func seed() {
    guard !seeded else { return }
    seeded = true
    // Fade/pop the card in (the cover present animation is suppressed).
    withAnimation(.snappy(duration: 0.24)) { shown = true }
    switch mode {
    case .create(let filter):
      draft = TaskDraft(filter: filter)
      // Train the list classifier once so the "Suggested" chip can query it
      // cheaply per keystroke.
      SuggestionEngine.shared.prepare(
        allTasks: LocalCache.allTasks(in: modelContext),
        projects: projects, areas: areas
      )
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
      // Apply any quick-entry tokens the user didn't tap, then create. The
      // isUnset guard means an earlier token (e.g. !today) wins over a later
      // conflicting one (a detected date) instead of being clobbered.
      for token in detectedTokens where isUnset(token) { applyToken(token) }
      draft.create(via: mutator)
      AddInfoSection.tasks.notifyTilesChanged()
    case .edit(let task):
      draft.update(task, via: mutator)
    }
    finish()
  }

  /// Tap-outside behaviour: commit when there's something worth saving,
  /// otherwise just close so an empty draft never creates a phantom task.
  private func dismissSaving() {
    if draft.canSave { commit() } else { onDismiss() }
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
  @Namespace private var glassNS

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Pills wrap onto extra rows as needed (FlowLayout) so every elective
      // stays visible — no offscreen horizontal scroll. "Today" isn't its own
      // pill: it's the same stored state as When=Today, so it lives inside the
      // When control (quick chip) instead of duplicating the rail. The
      // GlassEffectContainer lets the pills' glass morph/merge fluidly as their
      // values change (DesignSpec §5.5) rather than cross-fading.
      GlassEffectContainer(spacing: 8) {
        FlowLayout(spacing: 8) {
          AttributePill(icon: "calendar", label: "When",
                        value: whenValue, isSet: whenIsSet, isActive: expanded == .when,
                        accent: accent, glassID: "when", glassNS: glassNS) { toggle(.when) }

          AttributePill(icon: "flag", label: "Deadline",
                        value: draft.deadline.map(Self.dateLabel),
                        isSet: draft.deadline != nil, isActive: expanded == .deadline,
                        accent: accent, glassID: "deadline", glassNS: glassNS) { toggle(.deadline) }

          AttributePill(icon: "repeat", label: "Repeat",
                        value: draft.recurrence?.shortLabel,
                        isSet: draft.recurrence != nil, isActive: expanded == .repeatRule,
                        accent: accent, glassID: "repeat", glassNS: glassNS) { toggleRepeat() }

          AttributePill(icon: "folder", label: "List",
                        value: listValue,
                        isSet: draft.areaId != nil || draft.projectId != nil,
                        isActive: false, accent: accent,
                        glassID: "list", glassNS: glassNS) {
            onInteractStart()
            withAnimation(.snappy(duration: 0.2)) { expanded = nil }
            showingList = true
          }
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

  /// "When" folds in Today and Someday: a task pinned to today (no date) reads
  /// "Today", a future planning date reads its date, the Someday bucket reads
  /// "Someday".
  private var whenIsSet: Bool { draft.someday || draft.scheduled != nil || draft.onToday }
  private var whenValue: String? {
    if draft.someday { return "Someday" }
    if let s = draft.scheduled { return Self.dateLabel(s) }
    return draft.onToday ? "Today" : nil
  }

  @ViewBuilder
  private var inlineEditor: some View {
    switch expanded {
    case .when:
      InlineWhenPanel(draft: $draft, accent: accent)
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
  /// Stable identity inside the bar's `GlassEffectContainer`, so the pill's
  /// glass morphs in place (and merges with neighbours) as its value changes
  /// instead of cross-fading. See DesignSpec §5.5.
  let glassID: String
  let glassNS: Namespace.ID
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
    .glassEffectID(glassID, in: glassNS)
  }
}

// MARK: - Inline "When" editor

/// The scheduling control — the single home for Today, a planning date, and
/// the Someday bucket, so none of them needs its own pill. Quick chips (Today /
/// Tomorrow / Weekend / Someday) sit above a graphical calendar; picking today
/// normalizes back to the pinned-Today state, and Someday dims the calendar
/// since it's an explicitly date-free bucket. Expanded under the When pill.
private struct InlineWhenPanel: View {
  @Binding var draft: TaskDraft
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

  private var isSet: Bool { draft.someday || draft.scheduled != nil || draft.onToday }

  private var calendarBinding: Binding<Date> {
    Binding(get: { draft.scheduled ?? today },
            set: { d in withAnimation(.snappy(duration: 0.2)) { draft.setScheduled(d) } })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        chip("Today", active: draft.onToday && draft.scheduled == nil && !draft.someday) {
          draft.setToday()
        }
        chip("Tomorrow", active: isSameDay(draft.scheduled, tomorrow)) { draft.setScheduled(tomorrow) }
        chip("Weekend", active: isSameDay(draft.scheduled, weekend)) { draft.setScheduled(weekend) }
        chip("Someday", active: draft.someday) { draft.setSomeday() }
      }

      DatePicker("", selection: calendarBinding, displayedComponents: [.date])
        .datePickerStyle(.graphical)
        .tint(accent)
        // Someday is intentionally date-free — dim + disable the calendar so it
        // reads as "no date" rather than today's date.
        .opacity(draft.someday ? 0.4 : 1)
        .disabled(draft.someday)

      if isSet {
        Button(role: .destructive) {
          withAnimation(.snappy(duration: 0.2)) { draft.clearWhen() }
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
    Button { withAnimation(.snappy(duration: 0.2)) { action() } } label: {
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
        Text("Every \(intervalLabel())")
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

// MARK: - Presentation

extension View {
  /// Present the composer above the *current* context — including a sheet/drawer
  /// it's launched from — with a pop, not a slide. Hosting the cover on the
  /// launching view (rather than the app root) means it stacks on top of any
  /// sheet that view lives in, so the sheet survives underneath. The cover's
  /// bottom-slide is suppressed (the present/dismiss toggle runs in a
  /// non-animated transaction) and the card fades itself in. macOS (no
  /// full-screen covers) falls back to an in-place overlay.
  func taskComposerCover<Card: View>(
    isPresented: Binding<Bool>,
    @ViewBuilder card: @escaping () -> Card
  ) -> some View {
    modifier(TaskComposerCover(isPresented: isPresented, card: card))
  }
}

private struct TaskComposerCover<Card: View>: ViewModifier {
  @Binding var isPresented: Bool
  @ViewBuilder var card: () -> Card
  /// Internal mirror so we can toggle the cover in a non-animated transaction
  /// (killing the slide) regardless of how the caller flips `isPresented`.
  @State private var coverUp = false

  func body(content: Content) -> some View {
    #if os(iOS)
    content
      .fullScreenCover(isPresented: $coverUp) {
        card().presentationBackground(.clear)
      }
      .onChange(of: isPresented) { _, now in
        var txn = Transaction(); txn.disablesAnimations = true
        withTransaction(txn) { coverUp = now }
      }
      .onChange(of: coverUp) { _, now in
        // Cover closed (the card called its dismiss) — sync the source flag.
        if !now, isPresented { isPresented = false }
      }
    #else
    content
      .overlay { if isPresented { card() } }
      .animation(.snappy(duration: 0.22), value: isPresented)
    #endif
  }
}
