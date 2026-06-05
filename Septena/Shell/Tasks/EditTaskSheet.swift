import SwiftUI

// Edit/create form for a task, hosted by `.adaptiveDetail` (bottom sheet on
// iPhone, docked inspector on iPad/macOS) through `AdaptiveEditScaffold` —
// the same cross-surface chrome every other section uses. Replaces the old
// bespoke inline-expand row editor, whose hand-tuned mix of implicit
// List-row animation + plain state + async focus fought SwiftUI at every turn.
//
// Layout is Reminders-style: title + notes are the primary surface, and an
// icon bar (calendar · flag · repeat · folder · trash) rides above the
// keyboard via `safeAreaInset(.bottom)`. Tapping an icon reveals that field's
// editor inline (single active reveal); the icon tints when its field is set.
//
// The form owns NO navigation/dismiss — the scaffold closes after `save()`.

struct EditTaskSheet: View {
  @Environment(TaskMutator.self) private var mutator
  @Environment(SectionTheme.self) private var theme
  // Close the enclosing presentation. The scaffold owns Cancel/Save, but
  // Delete bypasses it, so the form needs its own handle. Same resolution the
  // scaffold uses: the adaptive-detail closer with a `dismiss` fallback.
  @Environment(\.dismiss) private var dismiss
  @Environment(\.adaptiveDetailClose) private var adaptiveClose

  /// The task being edited, or `nil` to create a fresh one.
  let original: SeptenaTask?
  let areas: [Area]
  let projects: [Project]
  /// Seed values for a fresh create, derived from the active filter
  /// (Today → today, a project view → that project, etc.).
  var createDefaults: CreateDefaults = .init()
  /// Called after a successful save/delete so the list reloads. The argument
  /// is the edited row when we can patch it optimistically, else `nil`.
  let onDone: (SeptenaTask?) -> Void

  struct CreateDefaults {
    var today = false
    var scheduled: Date? = nil
    var area: String? = nil
    var project: String? = nil
    var status: TaskStatus? = nil
  }

  // MARK: - Draft state

  @State private var title = ""
  @State private var notes = ""
  @State private var scheduled: Date? = nil
  @State private var deadline: Date? = nil
  @State private var recurrence: Recurrence? = nil
  @State private var areaId: String? = nil
  @State private var projectId: String? = nil

  /// Which detail editor is revealed (Reminders-style single disclosure).
  private enum Reveal { case when, deadline, repeatRule, list }
  @State private var reveal: Reveal? = nil
  @State private var seeded = false

  @FocusState private var titleFocused: Bool

  private var trimmedTitle: String {
    title.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    AdaptiveEditScaffold(
      title: original == nil ? "New To-Do" : "Edit To-Do",
      saveTitle: original == nil ? "Add" : "Save",
      canSave: !trimmedTitle.isEmpty,
      onSave: save
    ) {
      formBody
        .onAppear(perform: seed)
        .safeAreaInset(edge: .bottom, spacing: 0) { iconBar }
    }
  }

  // MARK: - Form

  @ViewBuilder private var formBody: some View {
    Form {
      Section {
        TextField("Title", text: $title, axis: .vertical)
          .font(.septenaTaskTitle)
          .focused($titleFocused)
          .submitLabel(.done)
        TextField("Notes", text: $notes, axis: .vertical)
          .font(.septenaNotes)
          .foregroundStyle(.secondary)
          .lineLimit(1...8)
      }

      switch reveal {
      case .when:       whenSection
      case .deadline:   deadlineSection
      case .repeatRule: repeatSection
      case .list:       listSection
      case .none:       EmptyView()
      }
    }
  }

  // MARK: - Icon bar (above keyboard / bottom of inspector)

  private var iconBar: some View {
    HStack(spacing: 2) {
      icon("calendar", set: scheduled != nil, toggle: .when) {
        if scheduled == nil { scheduled = Calendar.current.startOfDay(for: Date()) }
      }
      icon("flag", set: deadline != nil, toggle: .deadline) {
        if deadline == nil { deadline = Calendar.current.startOfDay(for: Date()) }
      }
      icon("repeat", set: recurrence != nil, toggle: .repeatRule) {
        if recurrence == nil { recurrence = Recurrence(unit: .week) }
      }
      icon("folder", set: projectId != nil || areaId != nil, toggle: .list)
      Spacer(minLength: 0)
      if original != nil {
        Button(role: .destructive) {
          Haptics.warning()
          if let id = original?.id {
            mutator.delete(id: id)
            onDone(nil)
          }
          (adaptiveClose ?? { dismiss() })()
        } label: {
          Image(systemName: "trash")
            .scaledFont(size: 16)
            .foregroundStyle(Theme.overdueRed)
            .frame(width: 40, height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Delete")
      }
    }
    .padding(.horizontal, Theme.hPadding)
    .padding(.vertical, 6)
    .background(.bar)
    .overlay(alignment: .top) { Hairline(leadingInset: 0) }
  }

  /// One icon-bar control. Tapping toggles its reveal section; `onActivate`
  /// runs first so a not-yet-set field can seed a sensible default.
  @ViewBuilder
  private func icon(_ systemImage: String, set: Bool, toggle target: Reveal,
                    onActivate: @escaping () -> Void = {}) -> some View {
    Button {
      Haptics.pick()
      if reveal == target {
        reveal = nil
      } else {
        onActivate()
        withAnimation(.easeInOut(duration: 0.18)) { reveal = target }
        titleFocused = false
      }
    } label: {
      Image(systemName: systemImage)
        .scaledFont(size: 16)
        .foregroundStyle(reveal == target ? Color.white : (set ? theme.accent : Theme.inkSecondary))
        .frame(width: 40, height: 34)
        .background(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(reveal == target ? theme.accent : Color.clear)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(systemImage)
  }

  // MARK: - Reveal sections

  @ViewBuilder private var whenSection: some View {
    Section("When") {
      WeekStrip(selected: scheduled) { scheduled = $0 }
        .listRowInsets(EdgeInsets(top: 8, leading: Theme.hPadding,
                                  bottom: 8, trailing: Theme.hPadding))
      DatePicker("Other date", selection: scheduledBinding, displayedComponents: [.date])
        .tint(theme.accent)
      if scheduled != nil {
        Button("Clear", role: .destructive) { scheduled = nil }
      }
    }
  }

  @ViewBuilder private var deadlineSection: some View {
    Section("Deadline") {
      WeekStrip(selected: deadline) { deadline = $0 }
        .listRowInsets(EdgeInsets(top: 8, leading: Theme.hPadding,
                                  bottom: 8, trailing: Theme.hPadding))
      DatePicker("Other date", selection: deadlineBinding, displayedComponents: [.date])
        .tint(theme.accent)
      if deadline != nil {
        Button("Remove Deadline", role: .destructive) { deadline = nil }
      }
    }
  }

  @ViewBuilder private var repeatSection: some View {
    Section("Repeat") {
      Picker("Unit", selection: recurrenceUnitBinding) {
        Text("Day").tag(Recurrence.Unit.day)
        Text("Week").tag(Recurrence.Unit.week)
        Text("Month").tag(Recurrence.Unit.month)
      }
      .pickerStyle(.segmented)
      Stepper(value: recurrenceIntervalBinding, in: 1...99) {
        Text("Every \(recurrence?.interval ?? 1) \(unitNoun(plural: (recurrence?.interval ?? 1) != 1))")
      }
      Toggle("After completion", isOn: recurrenceAfterCompletionBinding)
        .tint(theme.accent)
      Button("Don't Repeat", role: .destructive) { recurrence = nil }
    }
  }

  @ViewBuilder private var listSection: some View {
    Section("List") {
      Picker("List", selection: listBinding) {
        Text("Inbox").tag(ListTag.inbox)
        ForEach(topProjects) { p in
          Text(p.title).tag(ListTag.project(p.id))
        }
        ForEach(sortedAreas) { area in
          Text(area.title).tag(ListTag.area(area.id))
          ForEach(projectsIn(area.id)) { p in
            Text("  ↳ \(p.title)").tag(ListTag.project(p.id))
          }
        }
      }
      .pickerStyle(.menu)
      .tint(theme.accent)
    }
  }

  // MARK: - Bindings

  private var scheduledBinding: Binding<Date> {
    Binding(get: { scheduled ?? Calendar.current.startOfDay(for: Date()) },
            set: { scheduled = Calendar.current.startOfDay(for: $0) })
  }
  private var deadlineBinding: Binding<Date> {
    Binding(get: { deadline ?? Calendar.current.startOfDay(for: Date()) },
            set: { deadline = Calendar.current.startOfDay(for: $0) })
  }
  private var recurrenceUnitBinding: Binding<Recurrence.Unit> {
    Binding(get: { recurrence?.unit ?? .week },
            set: { recurrence = Recurrence(unit: $0, interval: recurrence?.interval ?? 1,
                                           afterCompletion: recurrence?.afterCompletion ?? true) })
  }
  private var recurrenceIntervalBinding: Binding<Int> {
    Binding(get: { recurrence?.interval ?? 1 },
            set: { recurrence = Recurrence(unit: recurrence?.unit ?? .week, interval: $0,
                                           afterCompletion: recurrence?.afterCompletion ?? true) })
  }
  private var recurrenceAfterCompletionBinding: Binding<Bool> {
    Binding(get: { recurrence?.afterCompletion ?? true },
            set: { recurrence = Recurrence(unit: recurrence?.unit ?? .week,
                                           interval: recurrence?.interval ?? 1, afterCompletion: $0) })
  }

  private enum ListTag: Hashable { case inbox, area(String), project(String) }
  private var listBinding: Binding<ListTag> {
    Binding(
      get: {
        if let p = projectId { return .project(p) }
        if let a = areaId { return .area(a) }
        return .inbox
      },
      set: { tag in
        switch tag {
        case .inbox:           areaId = nil; projectId = nil
        case .area(let a):     areaId = a;   projectId = nil
        case .project(let p):  projectId = p; areaId = projects.first { $0.id == p }?.area
        }
      }
    )
  }

  // MARK: - List sources

  private var topProjects: [Project] {
    projects.filter { $0.area == nil && $0.status == .active }
  }
  private var sortedAreas: [Area] { areas }
  private func projectsIn(_ areaId: String) -> [Project] {
    projects.filter { $0.area == areaId && $0.status == .active }
  }

  private func unitNoun(plural: Bool) -> String {
    switch recurrence?.unit ?? .week {
    case .day:   return plural ? "days" : "day"
    case .week:  return plural ? "weeks" : "week"
    case .month: return plural ? "months" : "month"
    }
  }

  // MARK: - Seed + Save

  private func seed() {
    guard !seeded else { return }
    seeded = true
    if let t = original {
      title = t.title
      notes = t.notes ?? ""
      scheduled = SeptenaDate.parse(t.scheduled)
      deadline = SeptenaDate.parse(t.deadline)
      recurrence = t.recurrence
      areaId = t.area
      projectId = t.project
      // An explicit Today pin reads as "scheduled today" in this editor.
      if t.today && scheduled == nil { scheduled = Calendar.current.startOfDay(for: Date()) }
      // Opening the editor counts as engagement — clear any agent cue.
      mutator.acknowledge(id: t.id)
    } else {
      scheduled = createDefaults.scheduled
      areaId = createDefaults.area
      projectId = createDefaults.project
      if createDefaults.today { scheduled = Calendar.current.startOfDay(for: Date()) }
      titleFocused = true
    }
  }

  private func save() {
    let t = trimmedTitle
    guard !t.isEmpty else { return }
    Haptics.tick()

    // Things-style scheduled mapping: scheduling *today* pins `today` and
    // clears the stored date; a future date stores the date with today=false.
    let schedIsToday = scheduled.map { Calendar.current.isDateInToday($0) } ?? false
    let storedScheduled = schedIsToday ? nil : scheduled
    let pinToday = schedIsToday

    if let orig = original {
      let id = orig.id
      if t != orig.title || notes != (orig.notes ?? "") {
        mutator.update(id: id, title: t, notes: notes)
      }
      // Scheduled / today
      mutator.schedule(id: id, date: storedScheduled)
      mutator.moveToToday(id: id, today: pinToday)
      // Deadline
      if deadline != SeptenaDate.parse(orig.deadline) {
        mutator.setDue(id: id, date: deadline)
      }
      // Repeat
      if recurrence != orig.recurrence {
        mutator.setRecurrence(id: id, recurrence: recurrence)
      }
      // List
      if projectId != orig.project { mutator.moveToProject(id: id, project: projectId) }
      if areaId != orig.area { mutator.moveToArea(id: id, area: areaId) }
      onDone(nil)
    } else {
      let created = mutator.create(
        title: t, area: areaId, project: projectId,
        scheduled: storedScheduled, due: deadline, today: pinToday,
        notes: notes.isEmpty ? nil : notes,
        status: createDefaults.status?.rawValue
      )
      if let r = recurrence { mutator.setRecurrence(id: created.id, recurrence: r) }
      onDone(nil)
    }
  }
}
