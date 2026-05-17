import SwiftUI
import EventKit

// Calendar mini-app — read-only feed of the next 7 days of events from
// every visible system calendar (same access model as RemindersBridge).
// Grouped by day, each event rendered as a LogRow with the start–end
// time as trailing meta; the leading dot picks up the source calendar's
// color so multiple calendars are still distinguishable.

struct CalendarDestinationView: View {
  @Environment(SectionTheme.self) private var theme

  @State private var bridge = CalendarBridge.shared
  @State private var events: [EKEvent] = []
  @State private var loading = true

  private var accent: Color { theme.color(for: "calendar") }

  /// Group events by date string for sectioning. Sort sections ascending
  /// since the feed runs forward in time.
  private var sections: [(date: String, items: [EKEvent])] {
    let cal = Calendar.current
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
    let grouped = Dictionary(grouping: events) { e in
      fmt.string(from: cal.startOfDay(for: e.startDate))
    }
    return grouped.keys.sorted().map { d in (d, grouped[d] ?? []) }
  }

  var body: some View {
    List {
      switch bridge.access {
      case .granted:    grantedBody
      case .notDetermined: askForAccess
      case .denied, .writeOnly: deniedNotice
      }
    }
    #if os(macOS)
    .listStyle(.inset)
    #else
    .listStyle(.insetGrouped)
    #endif
    .background(Theme.groupedBackground)
    .navigationTitle("Calendar")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
    .tint(accent)
    .task { load() }
    .refreshable { load() }
  }

  @ViewBuilder
  private var grantedBody: some View {
    if sections.isEmpty {
      ContentUnavailableView("Nothing scheduled",
                             systemImage: "calendar",
                             description: Text("Next 7 days are clear."))
    } else {
      ForEach(sections, id: \.date) { sec in
        Section(friendlyDate(sec.date)) {
          ForEach(sec.items, id: \.eventIdentifier) { event in
            LogRow(
              title: event.title ?? "(Untitled)",
              detail: subtitleFor(event),
              trailing: timeRangeFor(event),
              accent: calendarColor(event) ?? accent
            )
            .listRowInsets(EdgeInsets())
          }
        }
      }
    }
  }

  private var askForAccess: some View {
    Section {
      VStack(alignment: .leading, spacing: 12) {
        Text("See your calendar on the Week dashboard")
          .font(.headline)
        Text("Septena reads events from your visible calendars to show what's next. It never writes or shares them.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Button("Grant access") {
          Task {
            _ = await bridge.requestAccess()
            load()
          }
        }
        .buttonStyle(.borderedProminent)
        .tint(accent)
      }
      .padding(.vertical, 6)
    }
  }

  private var deniedNotice: some View {
    Section {
      VStack(alignment: .leading, spacing: 8) {
        Text("Calendar access denied")
          .font(.headline)
        Text("Grant access in Settings → Privacy → Calendars.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Loading

  private func load() {
    loading = true
    events = bridge.upcomingEvents(days: 7)
    loading = false
  }

  // MARK: - Helpers

  private func calendarColor(_ event: EKEvent) -> Color? {
    guard let cgColor = event.calendar?.cgColor else { return nil }
    return Color(cgColor: cgColor)
  }

  private func subtitleFor(_ event: EKEvent) -> String? {
    var parts: [String] = []
    if let cal = event.calendar?.title, !cal.isEmpty { parts.append(cal) }
    if let loc = event.location, !loc.isEmpty { parts.append(loc) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func timeRangeFor(_ event: EKEvent) -> String? {
    if event.isAllDay { return "all-day" }
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return "\(f.string(from: event.startDate))–\(f.string(from: event.endDate))"
  }

  private func friendlyDate(_ iso: String) -> String {
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
    guard let d = fmt.date(from: iso) else { return iso }
    let cal = Calendar.current
    if cal.isDateInToday(d)    { return "Today" }
    if cal.isDateInTomorrow(d) { return "Tomorrow" }
    let days = cal.dateComponents([.day], from: Date(), to: d).day ?? 0
    if days < 7 {
      let w = DateFormatter(); w.dateFormat = "EEEE"
      return w.string(from: d)
    }
    let p = DateFormatter(); p.dateFormat = "MMM d"
    return p.string(from: d)
  }
}
