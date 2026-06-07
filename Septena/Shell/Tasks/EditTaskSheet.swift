import SwiftUI

// The full task editor — notes + metadata — hosted by `.adaptiveDetail`
// (bottom sheet on iPhone, docked inspector on iPad/macOS) through
// `AdaptiveEditScaffold`, the same chrome every other section uses. Reached by
// the row's (i) button; the row itself handles quick title rename inline and
// the above-keyboard pill handles quick scheduling, so this drawer is the
// "everything else" surface, Reminders-detail-style.
//
// The form owns NO navigation/dismiss — the scaffold closes after `save()`.

struct EditTaskSheet: View {
  @Environment(TaskMutator.self) private var mutator
  @Environment(SectionTheme.self) private var theme
  @Environment(\.dismiss) private var dismiss
  @Environment(\.adaptiveDetailClose) private var adaptiveClose

  let original: SeptenaTask
  let areas: [Area]
  let projects: [Project]
  /// Called after save/delete so the list reloads.
  let onDone: (SeptenaTask?) -> Void

  // MARK: - Draft state

  @State private var title = ""
  @State private var notes = ""
  @State private var onToday = false
  @State private var scheduled: Date? = nil
  @State private var deadline: Date? = nil
  @State private var recurrence: Recurrence? = nil
  @State private var areaId: String? = nil
  @State private var projectId: String? = nil
  @State private var seeded = false

  private var trimmedTitle: String {
    title.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Per-section Tasks accent (not the global app accent), matching the list
  /// and drawer surfaces.
  private var accent: Color { theme.color(for: "tasks") }

  var body: some View {
    AdaptiveEditScaffold(
      title: "Edit To-Do",
      canSave: !trimmedTitle.isEmpty,
      onSave: save
    ) {
      Form {
        Section {
          TextField("Title", text: $title, axis: .vertical)
            .font(.septenaTaskTitle)
          TextField("Notes", text: $notes, axis: .vertical)
            .font(.septenaNotes)
            .foregroundStyle(.secondary)
            .lineLimit(2...6)
        }

        // Metadata — one compact section, each row led by the same glyph the
        // row/quick-actions use (sun · calendar · flag · repeat · folder).
        Section {
          Toggle(isOn: $onToday) {
            iconLabel("Today", "sun.max")
          }
          .tint(accent)

          Toggle(isOn: enabledBinding(for: scheduledBinding, default: today)) {
            iconLabel("When", "calendar")
          }
          .tint(accent)
          if scheduled != nil {
            DatePicker(selection: nonOptional(scheduledBinding), displayedComponents: [.date]) {
              iconLabel("Date", "calendar").labelStyle(.titleOnly)
            }
            .tint(accent)
          }

          Toggle(isOn: enabledBinding(for: deadlineBinding, default: today)) {
            iconLabel("Deadline", "flag")
          }
          .tint(accent)
          if deadline != nil {
            DatePicker(selection: nonOptional(deadlineBinding), displayedComponents: [.date]) {
              iconLabel("Date", "flag").labelStyle(.titleOnly)
            }
            .tint(accent)
          }

          Toggle(isOn: repeatEnabledBinding) {
            iconLabel("Repeat", "repeat")
          }
          .tint(accent)
          if recurrence != nil {
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
              .tint(accent)
          }

          Picker(selection: listBinding) {
            Text("Inbox").tag(ListTag.inbox)
            ForEach(topProjects) { p in Text(p.title).tag(ListTag.project(p.id)) }
            ForEach(areas) { area in
              Text(area.title).tag(ListTag.area(area.id))
              ForEach(projectsIn(area.id)) { p in
                Text("  ↳ \(p.title)").tag(ListTag.project(p.id))
              }
            }
          } label: {
            iconLabel("List", "folder")
          }
          .pickerStyle(.menu)
          .tint(accent)
        }

        // Status actions — mirror the row's context menu. These act
        // immediately and dismiss (like Delete), so they're grouped apart from
        // the Save-committed fields above.
        Section {
          Button(action: moveToSomeday) {
            iconLabel("Move to Someday", "moon.stars")
          }
          Button(action: cancelTask) {
            iconLabel("Cancel Task", "xmark.circle")
          }
        }

        Section {
          Button("Delete To-Do", role: .destructive, action: deleteTask)
        }
      }
      .onAppear(perform: seed)
    }
    // Tint the whole scaffold so the Cancel/Save controls (owned by the shared
    // scaffold, not this form) also pick up the Tasks accent.
    .tint(accent)
    // Open compact on iPhone (half-height), draggable taller. No-op for the
    // iPad/macOS inspector presentation.
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }

  /// A row label with the section's signature glyph, accent-tinted.
  private func iconLabel(_ title: String, _ systemImage: String) -> some View {
    Label {
      Text(title)
    } icon: {
      Image(systemName: systemImage).foregroundStyle(accent)
    }
  }

  private var today: Date { Calendar.current.startOfDay(for: Date()) }

  // MARK: - Bindings

  private var scheduledBinding: Binding<Date?> {
    Binding(get: { scheduled }, set: { scheduled = $0.map { Calendar.current.startOfDay(for: $0) } })
  }
  private var deadlineBinding: Binding<Date?> {
    Binding(get: { deadline }, set: { deadline = $0.map { Calendar.current.startOfDay(for: $0) } })
  }
  /// Maps an optional date to an on/off Toggle: turning it on seeds `default`,
  /// off clears it.
  private func enabledBinding(for date: Binding<Date?>, default def: Date) -> Binding<Bool> {
    Binding(get: { date.wrappedValue != nil },
            set: { date.wrappedValue = $0 ? def : nil })
  }
  /// Bridges an optional date binding to the non-optional one `DatePicker`
  /// needs (only shown when the value is already non-nil).
  private func nonOptional(_ date: Binding<Date?>) -> Binding<Date> {
    Binding(get: { date.wrappedValue ?? today }, set: { date.wrappedValue = $0 })
  }

  private var repeatEnabledBinding: Binding<Bool> {
    Binding(get: { recurrence != nil },
            set: { recurrence = $0 ? (recurrence ?? Recurrence(unit: .week)) : nil })
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
        case .inbox:          areaId = nil; projectId = nil
        case .area(let a):    areaId = a;   projectId = nil
        case .project(let p): projectId = p; areaId = projects.first { $0.id == p }?.area
        }
      }
    )
  }

  // MARK: - List sources

  private var topProjects: [Project] {
    projects.filter { $0.area == nil && $0.status == .active }
  }
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

  // MARK: - Seed / save / delete

  private func seed() {
    guard !seeded else { return }
    seeded = true
    title = original.title
    notes = original.notes ?? ""
    scheduled = SeptenaDate.parse(original.scheduled)
    deadline = SeptenaDate.parse(original.deadline)
    recurrence = original.recurrence
    areaId = original.area
    projectId = original.project
    onToday = original.today
    // Opening the editor counts as engagement — clear any agent cue.
    mutator.acknowledge(id: original.id)
  }

  private func save() {
    let t = trimmedTitle
    guard !t.isEmpty else { return }
    Haptics.tick()
    let id = original.id

    // Things-style scheduled mapping: scheduling *today* pins `today` and
    // clears the stored date; a future date stores the date with today=false.
    // The explicit Today toggle also pins it.
    let schedIsToday = scheduled.map { Calendar.current.isDateInToday($0) } ?? false
    let pinToday = onToday || schedIsToday

    if t != original.title || notes != (original.notes ?? "") {
      mutator.update(id: id, title: t, notes: notes)
    }
    mutator.schedule(id: id, date: schedIsToday ? nil : scheduled)
    mutator.moveToToday(id: id, today: pinToday)
    if deadline != SeptenaDate.parse(original.deadline) {
      mutator.setDue(id: id, date: deadline)
    }
    if recurrence != original.recurrence {
      mutator.setRecurrence(id: id, recurrence: recurrence)
    }
    if projectId != original.project { mutator.moveToProject(id: id, project: projectId) }
    if areaId != original.area { mutator.moveToArea(id: id, area: areaId) }
    onDone(nil)
  }

  // Status actions mirror the row's context menu: act immediately and close,
  // discarding any in-flight field edits (same as Delete).

  private func moveToSomeday() {
    Haptics.tick()
    mutator.moveToSomeday(id: original.id)
    onDone(nil)
    (adaptiveClose ?? { dismiss() })()
  }

  private func cancelTask() {
    Haptics.tick()
    mutator.cancel(id: original.id)
    onDone(nil)
    (adaptiveClose ?? { dismiss() })()
  }

  private func deleteTask() {
    Haptics.warning()
    mutator.delete(id: original.id)
    onDone(nil)
    (adaptiveClose ?? { dismiss() })()
  }
}
