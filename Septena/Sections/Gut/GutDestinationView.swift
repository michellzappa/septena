import SwiftUI
import SwiftData

// Gut mini-app — today's bowel movements (Bristol type, volume, note).
// Reads from local SwiftData (CloudKit-synced) and writes via GutMutator.

struct GutDestinationView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme
  @Environment(DayClock.self) private var clock

  @State private var today: GutDayResponse? = nil
  @State private var loading = true
  @State private var editing: GutEntry? = nil
  @State private var creating: Bool = false
  /// Trailing-30-day event instants for the rhythm wheel (see `rhythmSection`).
  @State private var weekPoints: [WheelPoint] = []
  /// Movement dates over the trailing ~17 weeks for the frequency heatmap.
  @State private var freqDates: [String] = []
  /// The day the drawer is viewing. Bound to `SectionDrawer`'s
  /// `currentDate` slot so the user can step prev/next from the date
  /// strip and `reload()` re-fetches for that day. Defaults to today.
  @State private var viewingDate: String = SeptenaDate.today
  // Gut is an editable dual section: Log = the day's movements; Patterns = the
  // 30-day rhythm wheel. Default Log; remembered per section.
  @State private var mode: DrawerMode = .remembered(for: "gut", default: .log)
  /// Whether the one-shot empty-state nudge has run for this appearance.
  @State private var didNudge = false

  private var gut: GutMutator { SeptenaServices.shared.gutMutator }

  private var accent: Color { theme.color(for: "gut") }

  /// The rhythm wheel is a today-only affordance (a past-day view is odd).
  private var isViewingToday: Bool { viewingDate == SeptenaDate.today }

  var body: some View {
    SectionDrawer(sectionKey: "gut",
                  quickAdd: DrawerQuickAdd("Log movement") { creating = true },
                  currentDate: $viewingDate,
                  mode: $mode,
                  log: {
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
          DrawerEmptyLogLine(isToday: isViewingToday)
        }
      }
    }, patterns: {
      EventFrequencySection(
        title: "How often", accent: accent, dates: freqDates,
        emptyText: loading ? nil : "Log a few movements and a daily-frequency heatmap appears here.")
      rhythmSection
    })
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
    if let n = e.note, !n.isEmpty { parts.append(n) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func reload() async {
    let date = viewingDate
    today = await MirrorReader.shared.read {
      ChecklistMirror.loadGutDay(context: $0, date: date)
    }
    await reloadWeek()
    await reloadFrequency()
    loading = false
    applyEmptyStateNudgeIfNeeded()
  }

  /// Movement dates over the trailing ~17 weeks (119 days) for the frequency
  /// heatmap — one entry per event, so multiple-per-day darkens that cell.
  private func reloadFrequency() async {
    let cutoff = Calendar.current.date(byAdding: .day, value: -118, to: todayStart) ?? todayStart
    freqDates = await MirrorReader.shared.read { ctx in
      let desc = FetchDescriptor<GutEventEntity>(
        predicate: #Predicate { $0.occurredAt >= cutoff }
      )
      return ((try? ctx.fetch(desc)) ?? []).map(\.date)
    }
  }

  private func applyEmptyStateNudgeIfNeeded() {
    DrawerMode.nudgeEmptyDayToPatterns(mode: $mode, didNudge: $didNudge,
                                       isViewingToday: isViewingToday,
                                       isEmpty: today?.entries.isEmpty ?? true)
  }

  // MARK: - Rhythm wheel (Patterns mode)
  //
  // A 24-hour dial of *when* movements land over the trailing 30 days, faded by
  // recency — gut regularity is a time-of-day signal. See `TimeOfDayWheel`.
  // Cross-day by nature, so it's the section's Patterns view; needs enough
  // events to read a pattern, otherwise a gentle keep-logging placeholder.

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
    let weekStart = Calendar.current.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart
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
      TimeOfDayWheel.Event(id: $0.id, occurredAt: $0.at, todayStart: start, windowDays: 30)
    }
  }

  private var nowFraction: Double {
    let c = Calendar.current.dateComponents([.hour, .minute], from: clock.now)
    return (Double(c.hour ?? 0) * 60 + Double(c.minute ?? 0)) / 1440
  }

  @ViewBuilder
  private var rhythmSection: some View {
    let events = wheelEvents
    if events.count >= 3 {
      DrawerSection("When movements happen", padding: .tight) {
        TimeOfDayWheel(events: events, accent: accent, windowDays: 30,
                       nowFraction: nowFraction, aggregate: true)
          .frame(maxWidth: .infinity)
      }
    } else if !loading {
      DrawerSection("When movements happen") {
        Text("Not enough logged yet to read a rhythm — keep at it and a 30-day pattern shows here.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
  }
}
