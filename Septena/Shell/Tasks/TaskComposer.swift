import SwiftUI

// The task composer — one form used for both creating and editing a task,
// hosted by the app's standard `AdaptiveEditScaffold` + `.adaptiveDetail`
// (a sheet on iPhone, a docked inspector on iPad/macOS — like every other edit
// drawer). Title + notes sit at the top; the electives (Today, When, Deadline,
// Repeat, List) are glass pills underneath. A pill shows its glyph + label when
// unset and its glyph + value (accent-tinted glass) when set. Tapping a
// date/repeat pill expands its editor inline; the List picker opens as a sheet.
// In edit mode the agent conversation is a section in the scroll. See
// docs/DesignSpec.md §5.5 — glass is the floating-control material.

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
  /// Fired after a successful create/edit (or a terminal action) so the list
  /// reloads. Closing is owned by the scaffold / `.adaptiveDetail`, not here.
  let onDone: () -> Void

  @Environment(TaskMutator.self) private var mutator
  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @Environment(\.adaptiveDetailClose) private var adaptiveClose
  @State private var draft = TaskDraft()
  @State private var seeded = false
  @FocusState private var titleFocused: Bool
  /// SuggestionEngine's learned area/project pick for the current title (the
  /// "Suggested" chip). Recomputed as the title changes; create-mode only.
  @State private var suggestedList: SuggestionEngine.Suggestion?

  private var isEditing: Bool {
    if case .edit = mode { return true }
    return false
  }

  private var headerTitle: String { isEditing ? "Edit To-Do" : "New Task" }
  private var saveTitle: String { isEditing ? "Save" : "Add" }

  /// Close through the docked-inspector hook with a sheet `dismiss()` fallback —
  /// the same close path `AdaptiveEditScaffold` uses, so terminal actions match.
  private func close() { (adaptiveClose ?? { dismiss() })() }

  var body: some View {
    // The standard adaptive edit drawer: a grouped sheet on iPhone, a docked
    // inspector on iPad/macOS, Cancel/Save chrome owned by the scaffold. The
    // content is a plain scroll — no custom detents — so it scrolls like every
    // other edit form. Save persists + reloads; the scaffold then closes.
    AdaptiveEditScaffold(
      title: headerTitle,
      saveTitle: saveTitle,
      accent: accent,
      canSave: draft.canSave,
      onSave: { persist(); onDone() }
    ) {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          titleNotesCard

          quickEntryChips

          TaskAttributeBar(
            draft: $draft,
            areas: areas,
            projects: projects,
            accent: accent,
            onInteractStart: { titleFocused = false }
          )

          // Edit mode only — a not-yet-created task has no id/conversation.
          // docs/TASK_CONVERSATIONS_PHASE1.md.
          if case .edit(let task) = mode {
            ConversationSection(task: task, accent: accent)
            terminalActions(task)
          }
        }
        .padding(16)
      }
      .scrollDismissesKeyboard(.interactively)
    }
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

  // MARK: - Title / notes

  private var titleNotesCard: some View {
    // Title only — notes moved to an elective pill in the attribute bar so the
    // card stays a single clean line; tapping the Notes pill expands an inline
    // editor like the When / Deadline / Repeat controls.
    TextField("What needs doing?", text: $draft.title, axis: .vertical)
      .textFieldStyle(.plain)
      .font(.septenaTaskTitle)
      .focused($titleFocused)
      .lineLimit(1...4)
      // macOS: a vertical-axis field fires onSubmit on plain Return (the iOS
      // newline-as-save trick never triggers there) — commit here instead.
      .onSubmit { if draft.canSave { commit() } }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .background(Theme.secondaryGroupedBackground,
                  in: RoundedRectangle(cornerRadius: 18, style: .continuous))
  }

  // MARK: - Terminal actions (edit mode)

  /// Complete / Cancel / Delete, at the bottom of the scroll (the scaffold owns
  /// the toolbar, so these standard destructive rows replace the old … menu).
  @ViewBuilder
  private func terminalActions(_ task: SeptenaTask) -> some View {
    VStack(spacing: 0) {
      actionRow("Complete", "checkmark.circle") { mutator.complete(id: task.id) }
      Divider().padding(.leading, 14)
      actionRow("Cancel Task", "xmark.circle") { mutator.cancel(id: task.id) }
      Divider().padding(.leading, 14)
      actionRow("Delete To-Do", "trash", destructive: true) { mutator.delete(id: task.id) }
    }
    .background(Theme.secondaryGroupedBackground,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
  }

  private func actionRow(_ title: String, _ icon: String, destructive: Bool = false,
                         _ action: @escaping () -> Void) -> some View {
    Button(role: destructive ? .destructive : nil) {
      action(); onDone(); close()
    } label: {
      Label(title, systemImage: icon)
        .font(.septenaSidebarRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(destructive ? Theme.overdueRed : Theme.inkPrimary)
  }

  private func updateSuggestion() {
    guard case .create = mode else { return }
    if draft.projectId != nil || draft.areaId != nil {
      suggestedList = nil
    } else {
      suggestedList = SuggestionEngine.shared.suggest(forText: draft.title)
    }
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
               leading: "lightbulb", text: s.title) { applySuggestedList() }
        }
      }
      .transition(.opacity)
    }
  }

  /// A small glass action chip: a leading hint glyph (`plus` to add a parsed
  /// token, `lightbulb` for the smart suggestion), the field's icon, and a label.
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
    switch mode {
    case .create(let filter):
      draft = TaskDraft(filter: filter)
      // Train the list classifier once so the "Suggested" chip can query it
      // cheaply per keystroke.
      SuggestionEngine.shared.prepare(
        allTasks: LocalCache.allTasks(in: modelContext),
        projects: projects, areas: areas
      )
      // Focus after the sheet settles — an immediate focus is dropped before the
      // field joins the responder chain, so the keyboard wouldn't come up.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { titleFocused = true }
    case .edit(let task):
      draft = TaskDraft(task: task)
      // Opening the editor counts as engagement — clear any agent cue.
      mutator.acknowledge(id: task.id)
    }
  }

  /// Writes the draft through the mutator. The scaffold's Save runs this then
  /// closes; the title-newline path runs it through `commit()`.
  private func persist() {
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
  }

  /// Persist + reload + close (the Return-to-save path; the scaffold's Save
  /// button does the same via its own close).
  private func commit() {
    guard draft.canSave else { return }
    Haptics.tick()
    persist()
    onDone()
    close()
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

  /// The electives, in rail order. Each is fully described by the enum (icon /
  /// label / how it presents); per-attribute *values* are derived from the draft
  /// in `value(for:)` / `isSet(_:)`, and each editor lives in its own panel. So
  /// every pill is wired identically — one `ForEach`, one `select(_:)` — and the
  /// rail grows by adding a case, not another hand-written call.
  enum Attribute: CaseIterable, Identifiable {
    case when, deadline, repeatRule, list, notes
    var id: Self { self }

    var icon: String {
      switch self {
      case .when:       "calendar"
      case .deadline:   "flag"
      case .repeatRule: "repeat"
      case .list:       "folder"
      case .notes:      "text.alignleft"
      }
    }
    var label: String {
      switch self {
      case .when:       "When"
      case .deadline:   "Deadline"
      case .repeatRule: "Repeat"
      case .list:       "List"
      case .notes:      "Notes"
      }
    }
    /// List opens a sheet — a rich, searchable area/project picker reused across
    /// the Tasks surfaces. Every other pill expands an inline panel under the rail.
    var presentsSheet: Bool { self == .list }
  }

  /// The currently expanded inline pill (never `.list`, which presents a sheet).
  @State private var expanded: Attribute?
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
          ForEach(Attribute.allCases) { attr in
            AttributePill(icon: attr.icon, label: attr.label,
                          value: value(for: attr), isSet: isSet(attr),
                          isActive: expanded == attr, accent: accent,
                          glassID: String(describing: attr), glassNS: glassNS) { select(attr) }
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

  /// The value shown on a pill (its `nil` falls back to the plain label). All
  /// values are derived from the draft — the single read-side of the rail.
  private func value(for attr: Attribute) -> String? {
    switch attr {
    // "When" folds in Today and Someday: a task pinned to today (no date) reads
    // "Today", a future planning date reads its date, Someday reads "Someday".
    case .when:
      if draft.someday { return "Someday" }
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
    // Notes shows its first line as a one-line preview; AttributePill truncates.
    case .notes:
      guard isSet(.notes) else { return nil }
      return draft.trimmedNotes.split(whereSeparator: \.isNewline).first.map(String.init)
    }
  }

  /// Whether a pill counts as "filled" — drives the accent tint.
  private func isSet(_ attr: Attribute) -> Bool {
    switch attr {
    case .when:       draft.someday || draft.scheduled != nil || draft.onToday
    case .deadline:   draft.deadline != nil
    case .repeatRule: draft.recurrence != nil
    case .list:       draft.areaId != nil || draft.projectId != nil
    case .notes:      !draft.trimmedNotes.isEmpty
    }
  }

  @ViewBuilder
  private var inlineEditor: some View {
    // One transition for every inline panel — they all slide down from the rail.
    Group {
      switch expanded {
      case .when:       InlineWhenPanel(draft: $draft, accent: accent)
      case .deadline:   InlineDatePanel(date: $draft.deadline, accent: accent)
      case .repeatRule: InlineRepeatPanel(recurrence: $draft.recurrence, accent: accent)
      case .notes:      InlineNotesPanel(notes: $draft.notes, accent: accent)
      case .list, .none: EmptyView()
      }
    }
    .transition(.opacity.combined(with: .move(edge: .top)))
  }

  /// The single dispatch for every pill: sheet-backed pills open their sheet,
  /// inline pills toggle the expanded panel. Per-attribute setup (Repeat seeding
  /// a default, Notes autofocusing) lives in each panel's `onAppear`, so this
  /// stays uniform.
  private func select(_ attr: Attribute) {
    onInteractStart()
    withAnimation(.snappy(duration: 0.22)) {
      if attr.presentsSheet {
        expanded = nil
        showingList = true
      } else {
        expanded = (expanded == attr) ? nil : attr
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
    // Expanding Repeat turns it on with a sensible default (Things-style); the
    // panel's "Don't Repeat" clears it. Owned here so the rail's dispatch stays
    // uniform — same pattern as the Notes panel autofocusing on appear.
    .onAppear { if recurrence == nil { recurrence = Recurrence(unit: .week) } }
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
private struct InlineNotesPanel: View {
  @Binding var notes: String
  let accent: Color
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      TextField("Notes", text: $notes, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.septenaNotes)
        .foregroundStyle(Theme.inkPrimary)
        .lineLimit(3...10)
        .focused($focused)

      if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Button(role: .destructive) {
          withAnimation(.snappy(duration: 0.2)) { notes = "" }
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
    .onAppear { focused = true }
  }
}

// MARK: - Presentation

extension View {
  /// Present the composer as the app's standard adaptive edit drawer — a sheet
  /// on iPhone, a docked inspector on iPad/macOS — the same `.adaptiveDetail`
  /// primitive every other section's edit form uses. The composer's
  /// `AdaptiveEditScaffold` supplies the Cancel/Save chrome and closes through
  /// the injected hook.
  func taskComposerDrawer<Card: View>(
    isPresented: Binding<Bool>,
    @ViewBuilder card: @escaping () -> Card
  ) -> some View {
    adaptiveDetail(isPresented: isPresented) { card() }
  }
}
