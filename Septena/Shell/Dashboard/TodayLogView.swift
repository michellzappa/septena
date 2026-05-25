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
        replaceEvent(id: "caf-\(entry.id)", title: caffeineLabel(updated),
                     detail: updated.beans, time: updated.time, kind: .caffeine(updated))
      }
    }
    .sheet(item: $editingCannabis) { entry in
      EditCannabisEntrySheet(date: date, original: entry) { updated in
        replaceEvent(id: "cnb-\(entry.id)", title: cannabisLabel(updated),
                     detail: updated.strain, time: updated.time, kind: .cannabis(updated))
      }
    }
    .sheet(item: $editingGut) { entry in
      EditGutEntrySheet(date: date, original: entry) { updated in
        replaceEvent(id: "gut-\(entry.id)", title: bristolLabel(updated.bristol),
                     detail: gutDetail(updated), time: updated.time, kind: .gut(updated))
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

    let cH = theme.color(for: "habits")
    let cS = theme.color(for: "supplements")
    let cR = theme.color(for: "chores")
    let cT = theme.color(for: "tasks")
    let cC = theme.color(for: "caffeine")
    let cZ = theme.color(for: "cannabis")
    let cG = theme.color(for: "gut")
    let cN = theme.color(for: "nutrition")
    let cTr = theme.color(for: "training")
    let cCal = theme.color(for: "calendar")

    for h in habits where h.done {
      guard let t = h.time else { continue }
      let label = [h.emoji, h.name].compactMap { $0 }.joined(separator: " ")
      out.append(TodayEvent(
        id: "habit-\(h.id)", time: t, section: "habits",
        color: cH, title: label, detail: nil, kind: .habit(h)
      ))
    }

    for s in supplements where s.done {
      guard let t = s.time else { continue }
      let label = [s.emoji, s.name].compactMap { $0 }.joined(separator: " ")
      out.append(TodayEvent(
        id: "supp-\(s.id)", time: t, section: "supplements",
        color: cS, title: label, detail: nil, kind: .supplement(s)
      ))
    }

    for c in chores where c.lastCompleted == date {
      let t = c.lastCompletedTime ?? "00:00"
      let label = [c.emoji, c.name].compactMap { $0 }.joined(separator: " ")
      out.append(TodayEvent(
        id: "chore-\(c.id)", time: t, section: "chores",
        color: cR, title: label, detail: nil, kind: .chore(c)
      ))
    }

    for task in tasks where task.status == .done {
      guard let ts = task.completedAt, ts.hasPrefix(date), ts.count >= 16 else { continue }
      let hhmm = String(ts.dropFirst(11).prefix(5))
      out.append(TodayEvent(
        id: "task-\(task.id)", time: hhmm, section: "tasks",
        color: cT, title: task.title, detail: nil, kind: .task(task)
      ))
    }

    for e in caffeine {
      let label = caffeineLabel(e)
      out.append(TodayEvent(
        id: "caf-\(e.id)", time: e.time, section: "caffeine",
        color: cC, title: label, detail: e.beans, kind: .caffeine(e)
      ))
    }

    for e in cannabis {
      let label = cannabisLabel(e)
      out.append(TodayEvent(
        id: "cnb-\(e.id)", time: e.time, section: "cannabis",
        color: cZ, title: label, detail: e.strain, kind: .cannabis(e)
      ))
    }

    for e in gut {
      out.append(TodayEvent(
        id: "gut-\(e.id)", time: e.time, section: "gut",
        color: cG, title: bristolLabel(e.bristol), detail: gutDetail(e), kind: .gut(e)
      ))
    }

    for e in mood {
      // Use the quadrant color directly rather than the section accent
      // — the affective dimension is the whole point of a mood log; a
      // single section-wide color would erase it.
      let quadColor = MoodQuadrant(rawValue: e.quadrant)?.color ?? .gray
      out.append(TodayEvent(
        id: "mood-\(e.id)", time: String(e.time.prefix(5)), section: "mood",
        color: quadColor, title: e.emotion, detail: e.note, kind: .mood(e)
      ))
    }

    for e in nutrition where e.date == date {
      let name = e.foods.first ?? "Meal"
      let prefix = e.emoji.map { "\($0) " } ?? ""
      let more = e.foods.count > 1 ? " +\(e.foods.count - 1)" : ""
      let detail = "\(Int(e.proteinG))g protein · \(Int(e.kcal)) kcal"
      out.append(TodayEvent(
        id: "nut-\(e.id)", time: e.time, section: "nutrition",
        color: cN, title: "\(prefix)\(name)\(more)", detail: detail, kind: .nutrition(e)
      ))
    }

    for e in training where e.date == date {
      guard let name = e.exercise else { continue }
      let t = e.concludedAt.map { String($0.dropFirst(11).prefix(5)) } ?? "00:00"
      let detail = trainingDetail(e)
      out.append(TodayEvent(
        id: "tr-\(e.id)", time: t, section: "training",
        color: cTr, title: name, detail: detail, kind: .training(e)
      ))
    }

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

  private func caffeineLabel(_ e: CaffeineEntry) -> String {
    switch e.method {
    case "v60":    return "V60"
    case "matcha": return "Matcha"
    case "aeropress": return "Aeropress"
    case "espresso": return "Espresso"
    default:       return e.method.capitalized
    }
  }

  private func cannabisLabel(_ e: CannabisEntry) -> String {
    switch e.method {
    case "vape":   return "Vape"
    case "edible": return "Edible"
    default:       return e.method.capitalized
    }
  }

  private func bristolLabel(_ n: Int) -> String {
    switch n {
    case 1: return "Type 1 — Separate lumps"
    case 2: return "Type 2 — Lumpy sausage"
    case 3: return "Type 3 — Cracked sausage"
    case 4: return "Type 4 — Smooth sausage"
    case 5: return "Type 5 — Soft blobs"
    case 6: return "Type 6 — Fluffy pieces"
    case 7: return "Type 7 — Liquid"
    default: return "Bristol \(n)"
    }
  }

  private func gutDetail(_ e: GutEntry) -> String? {
    var parts: [String] = []
    if let vol = e.volume { parts.append(vol) }
    if e.blood > 0 { parts.append("blood \(e.blood)") }
    if let note = e.note { parts.append(note) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func trainingDetail(_ e: ExerciseEntry) -> String? {
    var parts: [String] = []
    if let w = e.weight { parts.append("\(Int(w))kg") }
    if let s = e.sets, let r = e.reps { parts.append("\(s)×\(r)") }
    else if let s = e.sets { parts.append("\(s) sets") }
    if let d = e.durationMin { parts.append("\(Int(d)) min") }
    if let dist = e.distanceM, dist > 0 {
      parts.append(String(format: "%.1f km", dist / 1000))
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func hhmmToDouble(_ s: String) -> Double {
    let parts = s.split(separator: ":")
    guard parts.count == 2,
          let h = Double(parts[0]),
          let m = Double(parts[1]) else { return 0 }
    return h + m / 60
  }
}

// MARK: - Event model

private enum TodayEventKind {
  case habit(HabitDayItem)
  case supplement(SupplementDayItem)
  case chore(ChoreItem)
  case task(SeptenaTask)
  case caffeine(CaffeineEntry)
  case cannabis(CannabisEntry)
  case gut(GutEntry)
  case nutrition(NutritionEntry)
  case training(ExerciseEntry)
  case calendar(EKEvent)
  case mood(MoodEntry)
}

private struct TodayEvent: Identifiable {
  let id: String
  let time: String      // HH:MM — used for sort and display
  let section: String
  let color: Color
  let title: String
  let detail: String?
  let kind: TodayEventKind

  var timeLabel: String { time }
}
