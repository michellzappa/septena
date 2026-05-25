import SwiftUI
import EventKit

// Today log — flat chronological list of everything done today across all
// sections. Mirrors the webapp's /timeline view. Tapped from the timeline
// strip on the Week dashboard.
//
// Data is passed in from WeekDashboardView (already loaded). Local state
// copies enable optimistic removal after mutations.

struct TodayLogView: View {
  @Environment(SectionTheme.self) private var theme
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(ChecklistMutator.self) private var checklistMutator
  @Environment(TaskMutator.self) private var taskMutator

  let date: String

  // All data sources — same payload WeekDashboardView already has.
  let habits: [HabitDayItem]
  let supplements: [SupplementDayItem]
  let chores: [ChoreItem]
  let tasks: [SeptenaTask]
  let caffeine: [CaffeineEntry]
  let cannabis: [CannabisEntry]
  let gut: [GutEntry]
  let nutrition: [NutritionEntry]
  let training: [ExerciseEntry]
  let calendar: [EKEvent]
  let mood: [MoodEntry]

  // Local mutable copies for optimistic UI after mutations.
  @State private var events: [TodayEvent] = []

  // Edit sheets for consumable log entries.
  @State private var editingCaffeine: CaffeineEntry? = nil
  @State private var editingCannabis: CannabisEntry? = nil
  @State private var editingGut: GutEntry? = nil
  @State private var editingMood: MoodEntry? = nil

  var body: some View {
    List {
      if events.isEmpty {
        Section {
          Text("Nothing logged yet today.")
            .foregroundStyle(.secondary)
        }
      } else {
        Section {
          ForEach(events) { event in
            row(for: event)
              .listRowInsets(EdgeInsets())
              .contextMenu { contextMenu(for: event) }
          }
        }
      }
    }
    #if os(macOS)
    .listStyle(.inset)
    #else
    .listStyle(.insetGrouped)
    #endif
    .background(Theme.groupedBackground)
    .navigationTitle("Today")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
    .onAppear { events = buildEvents() }
    .sheet(item: $editingCaffeine) { entry in
      EditCaffeineEntrySheet(date: date, original: entry) { updated in
        // Label rendering lives in CaffeinePlugin alongside the Today
        // event production — single source of truth for the section.
        replaceEvent(id: "caf-\(entry.id)", title: CaffeinePlugin.label(for: updated),
                     detail: updated.beans, time: updated.time, kind: .caffeine(updated))
      }
    }
    .sheet(item: $editingCannabis) { entry in
      EditCannabisEntrySheet(date: date, original: entry) { updated in
        replaceEvent(id: "cnb-\(entry.id)", title: CannabisPlugin.label(for: updated),
                     detail: updated.strain, time: updated.time, kind: .cannabis(updated))
      }
    }
    .sheet(item: $editingGut) { entry in
      EditGutEntrySheet(date: date, original: entry) { updated in
        replaceEvent(id: "gut-\(entry.id)", title: GutPlugin.bristolLabel(updated.bristol),
                     detail: GutPlugin.detail(for: updated), time: updated.time, kind: .gut(updated))
      }
    }
    .sheet(item: $editingMood) { entry in
      EditMoodEntrySheet(date: date, original: entry) {
        // EditMoodEntrySheet writes through MoodMutator which fires
        // `septenaDataChanged`; the parent reload re-renders TodayLogView
        // with fresh data. No optimistic replace needed.
      }
    }
  }

  // MARK: - Row

  private func rowContent(for event: TodayEvent) -> some View {
    HStack(spacing: 10) {
      Circle()
        .fill(event.color)
        .frame(width: 8, height: 8)
        .padding(.leading, Theme.hPadding)
      LogRow(title: event.title, detail: event.detail, trailing: event.timeLabel)
    }
  }

  @ViewBuilder
  private func row(for event: TodayEvent) -> some View {
    switch event.kind {
    case .caffeine(let e):
      Button { editingCaffeine = e } label: { rowContent(for: event) }
        .buttonStyle(.plain)
    case .cannabis(let e):
      Button { editingCannabis = e } label: { rowContent(for: event) }
        .buttonStyle(.plain)
    case .gut(let e):
      Button { editingGut = e } label: { rowContent(for: event) }
        .buttonStyle(.plain)
    case .mood(let e):
      Button { editingMood = e } label: { rowContent(for: event) }
        .buttonStyle(.plain)
    default:
      rowContent(for: event)
    }
  }

  // MARK: - Context menus

  @ViewBuilder
  private func contextMenu(for event: TodayEvent) -> some View {
    switch event.kind {
    case .habit(let h):
      Button {
        remove(id: event.id)
        checklistMutator.toggleHabit(id: h.id, date: date, done: false)
        Haptics.tap()
      } label: {
        Label("Mark as not done", systemImage: "xmark.circle")
      }

    case .supplement(let s):
      Button {
        remove(id: event.id)
        checklistMutator.toggleSupplement(id: s.id, date: date, done: false)
        Haptics.tap()
      } label: {
        Label("Mark as not done", systemImage: "xmark.circle")
      }

    case .chore(let c):
      Button {
        remove(id: event.id)
        checklistMutator.uncompleteChore(id: c.id, date: date)
        Haptics.tap()
      } label: {
        Label("Mark as not done", systemImage: "xmark.circle")
      }

    case .task(let t):
      Button {
        remove(id: event.id)
        taskMutator.uncomplete(id: t.id)
        Haptics.tap()
      } label: {
        Label("Mark as not done", systemImage: "xmark.circle")
      }

    case .caffeine(let e):
      Button(role: .destructive) {
        remove(id: event.id)
        SeptenaServices.shared.caffeineMutator.deleteEntry(id: e.id)
        Haptics.warning()
      } label: {
        Label("Delete", systemImage: "trash")
      }

    case .cannabis(let e):
      Button(role: .destructive) {
        remove(id: event.id)
        SeptenaServices.shared.cannabisMutator.deleteEntry(id: e.id)
        Haptics.warning()
      } label: {
        Label("Delete", systemImage: "trash")
      }

    case .gut(let e):
      Button(role: .destructive) {
        remove(id: event.id)
        SeptenaServices.shared.gutMutator.deleteEntry(id: e.id)
        Haptics.warning()
      } label: {
        Label("Delete", systemImage: "trash")
      }

    case .mood(let e):
      Button(role: .destructive) {
        remove(id: event.id)
        SeptenaServices.shared.moodMutator.deleteEntry(id: e.id)
        Haptics.warning()
      } label: {
        Label("Delete", systemImage: "trash")
      }

    case .nutrition(let e):
      Button(role: .destructive) {
        remove(id: event.id)
        SeptenaServices.shared.nutritionMutator.deleteEntry(id: e.file)
        Haptics.warning()
      } label: {
        Label("Delete", systemImage: "trash")
      }

    case .training(let e):
      Button(role: .destructive) {
        remove(id: event.id)
        SeptenaServices.shared.trainingMutator.deleteEntry(id: e.id)
        Haptics.warning()
      } label: {
        Label("Delete", systemImage: "trash")
      }

    case .calendar:
      EmptyView()
    }
  }

  // MARK: - Optimistic mutations

  private func remove(id: String) {
    events.removeAll { $0.id == id }
  }

  private func replaceEvent(id: String, title: String, detail: String?,
                             time: String, kind: TodayEventKind) {
    guard let idx = events.firstIndex(where: { $0.id == id }) else { return }
    let old = events[idx]
    events[idx] = TodayEvent(id: old.id, time: time, section: old.section,
                              color: old.color, title: title, detail: detail, kind: kind)
  }

  // MARK: - Event building

  private func buildEvents() -> [TodayEvent] {
    var out: [TodayEvent] = []

    let cCal = theme.color(for: "calendar")

    // habits, supplements, chores, tasks migrated to their plugins.
    // caffeine, cannabis, gut migrated to their plugins (see
    // SectionRegistry loop below).

    // Mood is migrated to SectionPlugin. Future sections will follow
    // the same pattern: their inline loops collapse to a single call
    // through SectionRegistry. The non-migrated sections above stay
    // inline until each gets its own plugin commit.
    let todayCtx = TodayContext(
      theme: theme,
      habits: habits, supplements: supplements, chores: chores,
      tasks: tasks, caffeine: caffeine, cannabis: cannabis,
      gut: gut, nutrition: nutrition, training: training,
      calendar: calendar, mood: mood
    )
    for plugin in SectionRegistry.all {
      out.append(contentsOf: plugin.todayEvents(date: date, ctx: todayCtx))
    }

    // nutrition + training migrated to their plugins (see
    // SectionRegistry loop).

    let cal = Foundation.Calendar.current
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
    if let dayStart = fmt.date(from: date) {
      for e in calendar where !e.isAllDay {
        let startH = e.startDate.timeIntervalSince(dayStart) / 3600
        guard startH >= 0 && startH < 24 else { continue }
        let hh = Int(startH); let mm = Int((startH - Double(hh)) * 60)
        let hhmm = String(format: "%02d:%02d", hh, mm)
        let title = e.title ?? "Event"
        let calColor = e.calendar?.cgColor.map { Color($0) } ?? cCal
        out.append(TodayEvent(
          id: "cal-\(e.eventIdentifier ?? title)", time: hhmm, section: "calendar",
          color: calColor, title: title, detail: nil, kind: .calendar(e)
        ))
      }
    }

    // Per-section "Show in Today" filter. Calendar isn't a manifest
    // section, so it's never filtered out here — visibility is governed
    // by the user's calendar picker in Integrations.
    let mutedSections: Set<String> = Set(
      settingsStore.sections
        .filter { !$0.showInToday || !$0.isEnabled }
        .map(\.key)
    )
    let visible = mutedSections.isEmpty
      ? out
      : out.filter { !mutedSections.contains($0.section) }

    return visible.sorted { hhmmToDouble($0.timeLabel) > hhmmToDouble($1.timeLabel) }
  }

  // MARK: - Label helpers

  // `caffeineLabel` moved to CaffeinePlugin.label(for:) along with the
  // Today block. Other section labels will follow as they migrate.

  // `cannabisLabel` moved to CannabisPlugin.label(for:) alongside the
  // Today block.

  // `bristolLabel` + `gutDetail` moved to GutPlugin.

  // `trainingDetail` moved to TrainingPlugin.detail(for:).

  private func hhmmToDouble(_ s: String) -> Double {
    let parts = s.split(separator: ":")
    guard parts.count == 2,
          let h = Double(parts[0]),
          let m = Double(parts[1]) else { return 0 }
    return h + m / 60
  }
}

// Event model now lives in Septena/Shell/Dashboard/TodayEvent.swift so
// that SectionPlugin implementations can construct events directly.
