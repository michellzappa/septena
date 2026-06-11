import SwiftUI
import SwiftData

// Gut mini-app — today's movements (and any open discomfort window).
// Reads from local SwiftData (CloudKit-synced) and writes via GutMutator.

struct GutDestinationView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme
  @Environment(DayClock.self) private var clock

  @State private var today: GutDayResponse? = nil
  @State private var loading = true
  @State private var editing: GutEntry? = nil
  @State private var creating: Bool = false
  /// Trailing-7-day event instants for the rhythm wheel (see `rhythmSection`).
  @State private var weekPoints: [WheelPoint] = []
  /// The day the drawer is viewing. Bound to `SectionDrawer`'s
  /// `currentDate` slot so the user can step prev/next from the date
  /// strip and `reload()` re-fetches for that day. Defaults to today.
  @State private var viewingDate: String = SeptenaDate.today

  private var gut: GutMutator { SeptenaServices.shared.gutMutator }

  private var accent: Color { theme.color(for: "gut") }

  /// The rhythm wheel is a today-only affordance (a past-day view is odd).
  private var isViewingToday: Bool { viewingDate == SeptenaDate.today }

  var body: some View {
    SectionDrawer(sectionKey: "gut",
                  onLog: { _ in creating = true },
                  currentDate: $viewingDate) {
      DrawerSection("Today", padding: .none) {
        if let today, !today.entries.isEmpty {
          ForEach(Array(today.entries.reversed())) { entry in
            LogEntryRow(
              title: bristolLabel(entry.bristol),
              detail: detailLine(entry),
              trailing: entry.time,
              tint: accent,
              isSelected: editing?.id == entry.id,
              onEdit: { editing = entry },
              onDelete: { delete(entry) }
            )
          }
        } else if !loading {
          Text("Nothing logged yet.")
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
      }
      rhythmSection
    }
    .tint(accent)
    .sectionReload(on: viewingDate, onDataChange: true,
                   forSections: ["gut"]) { await reload() }
    // Adaptive: sheet on iPhone, docked inspector on iPad/macOS so editing
    // a logged entry keeps the day's log visible alongside it.
    .drawerDetail(edit: $editing, create: $creating) { entry in
      EditGutEntrySheet(
        date: viewingDate,
        original: entry,
        onSave: { _ in Task { await reload() } }
      )
    }
  }

  private func delete(_ entry: GutEntry) {
    gut.deleteEntry(id: entry.id)
    Task { await reload() }
    Haptics.warning()
  }

  // Standard Bristol Stool Scale short forms — keep it clinical, not cute.
  private func bristolLabel(_ b: Int) -> String {
    switch b {
    case 1: return "Type 1 · hard lumps"
    case 2: return "Type 2 · lumpy"
    case 3: return "Type 3 · cracked"
    case 4: return "Type 4 · smooth"
    case 5: return "Type 5 · soft blobs"
    case 6: return "Type 6 · mushy"
    case 7: return "Type 7 · liquid"
    default: return "Type \(b)"
    }
  }

  private func detailLine(_ e: GutEntry) -> String? {
    var parts: [String] = []
    if let v = e.volume { parts.append(v) }
    if e.blood > 0 { parts.append("blood \(e.blood)") }
    if let h = e.discomfortHours, h > 0, let lvl = e.discomfortLevel {
      parts.append("\(lvl) \("\(h.decimalString(1))h")")
    }
    if let n = e.note, !n.isEmpty { parts.append(n) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func reload() async {
    let date = viewingDate
    today = await MirrorReader.shared.read {
      ChecklistMirror.loadGutDay(context: $0, date: date)
    }
    await reloadWeek()
    loading = false
  }

  // MARK: - Rhythm wheel
  //
  // A 24-hour dial of *when* movements land over the trailing 7 days, faded by
  // recency — gut regularity is a time-of-day signal. See `TimeOfDayWheel`.
  // Today only, and only with enough events to read a pattern.

  private struct WheelPoint: Identifiable, Sendable {
    let id: String
    let at: Date
  }

  /// Start of *today* in the local calendar, from the shared day clock so it
  /// honors day-rollover. Falls back to the device midnight if unparseable.
  private var todayStart: Date {
    SeptenaDate.parse(clock.today).map { Calendar.current.startOfDay(for: $0) }
      ?? Calendar.current.startOfDay(for: clock.now)
  }

  private func reloadWeek() async {
    let weekStart = Calendar.current.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
    weekPoints = await MirrorReader.shared.read { ctx in
      let desc = FetchDescriptor<GutEventEntity>(
        predicate: #Predicate { $0.occurredAt >= weekStart },
        sortBy: [SortDescriptor(\.occurredAt)]
      )
      return ((try? ctx.fetch(desc)) ?? []).map { WheelPoint(id: $0.id, at: $0.occurredAt) }
    }
  }

  private var wheelEvents: [TimeOfDayWheel.Event] {
    let start = todayStart
    return weekPoints.compactMap {
      TimeOfDayWheel.Event(id: $0.id, occurredAt: $0.at, todayStart: start, windowDays: 7)
    }
  }

  private var nowFraction: Double {
    let c = Calendar.current.dateComponents([.hour, .minute], from: clock.now)
    return (Double(c.hour ?? 0) * 60 + Double(c.minute ?? 0)) / 1440
  }

  @ViewBuilder
  private var rhythmSection: some View {
    let events = wheelEvents
    if isViewingToday, events.count >= 3 {
      DrawerSection("When movements happen", padding: .tight) {
        TimeOfDayWheel(events: events, accent: accent, windowDays: 7, nowFraction: nowFraction)
          .frame(maxWidth: .infinity)
      }
    }
  }
}
