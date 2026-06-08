import SwiftUI
import SwiftData

// Caffeine mini-app — today's sessions log, reads from SwiftData and
// writes through CaffeineMutator.

struct CaffeineDestinationView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme
  @Environment(DayClock.self) private var clock
  @Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?

  @State private var today: CaffeineDayResponse? = nil
  @State private var loading = true
  /// Trailing-7-day event instants for the rhythm wheel — a separate,
  /// lightweight fetch from the per-day `today` response above (the wheel
  /// is the only surface that needs a week at once). Sendable id+instant
  /// pairs so the read can cross the mirror's actor boundary.
  @State private var weekPoints: [WheelPoint] = []
  @State private var editing: CaffeineEntry? = nil
  @State private var managingTypes = false
  /// Driven by `CaffeinePlugin.logActions`: tapping "Log V60" / "Log
  /// Matcha" / "Log other" sets this to the method id; the sheet opens
  /// in create mode with `presetMethod` seeded.
  @State private var loggingMethod: LoggingMethod? = nil
  private struct LoggingMethod: Identifiable, Hashable {
    let method: String
    var id: String { method }
  }
  /// Day the drawer is currently viewing — driven by the drawer's
  /// `currentDate` date strip. Defaults to today.
  @State private var viewingDate: String = SeptenaDate.today

  private var caffeine: CaffeineMutator { SeptenaServices.shared.caffeineMutator }

  private var accent: Color { theme.color(for: "caffeine") }

  /// The "Repeat" leading log action is a today-only affordance.
  private var isViewingToday: Bool { viewingDate == SeptenaDate.today }

  var body: some View {
    SectionDrawer(sectionKey: "caffeine",
                  onLog: handleLogAction,
                  leadingLogActions: leadingLogActions,
                  currentDate: $viewingDate) {
      rhythmSection
      DrawerSection("Today", padding: .none) {
        if let today, !today.entries.isEmpty {
          ForEach(Array(today.entries.reversed())) { entry in
            LogEntryRow(
              title: methodLabel(entry.method),
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
    }
    .tint(accent)
    .sectionReload(on: viewingDate, onDataChange: true) { await reload() }
    .sheet(isPresented: $managingTypes) {
      CaffeineTypeSheet()
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }
    .adaptiveDetail(item: $editing) { entry in
      EditCaffeineEntrySheet(
        date: viewingDate,
        original: entry,
        onSave: { _ in Task { await reload() } }
      )
    }
    .sheet(item: $loggingMethod) { wrap in
      EditCaffeineEntrySheet(
        date: viewingDate,
        original: nil,
        presetMethod: wrap.method,
        onSave: { _ in Task { await reload() } }
      )
    }
  }

  private func delete(_ entry: CaffeineEntry) {
    caffeine.deleteEntry(id: entry.id)
    Task { await reload() }
    Haptics.warning()
  }

  /// Smart "Repeat" row injected above the plugin's log actions in the "+"
  /// menu — mirrors the dashboard tile's quick-add so both surfaces show the
  /// same options. Only on today (a past-day repeat is odd) and only when
  /// there's an entry to repeat. Logs directly (the fast path); the static
  /// "Log V60/Matcha/other" items below it open the create sheet for detail.
  private var leadingLogActions: [LogAction] {
    guard isViewingToday, let last = today?.entries.last else { return [] }
    return [LogAction(id: "repeat",
                      title: "Repeat: \(last.beans ?? methodLabel(last.method))",
                      systemImage: "arrow.clockwise")]
  }

  /// Dispatch table for `CaffeinePlugin.logActions` ids (plus the dynamic
  /// "repeat" leading action). Keeping this close to the destination so
  /// adding a new menu item is a two-touch change.
  private func handleLogAction(_ id: String) {
    switch id {
    case "repeat":
      if let last = today?.entries.last {
        CaffeineCommit.logNew(method: last.method, beans: last.beans,
                              grams: last.grams, accent: accent, logCommit: logCommit)
      }
    case "log-v60":    loggingMethod = .init(method: "v60")
    case "log-matcha": loggingMethod = .init(method: "matcha")
    case "log-other":  loggingMethod = .init(method: "other")
    case "manage":     managingTypes = true
    default:           loggingMethod = .init(method: "v60")
    }
  }

  private func methodLabel(_ m: String) -> String {
    switch m {
    case "v60":    return "V60"
    case "matcha": return "Matcha"
    default:       return m.capitalized
    }
  }

  private func detailLine(_ e: CaffeineEntry) -> String? {
    var parts: [String] = []
    if let beans = e.beans, !beans.isEmpty { parts.append(beans) }
    if let g = e.grams { parts.append("\(g.decimalString(1))g") }
    if let n = e.note, !n.isEmpty { parts.append(n) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func reload() async {
    let date = viewingDate
    today = await MirrorReader.shared.read {
      ChecklistMirror.loadCaffeineDay(context: $0, date: date)
    }
    await reloadWeek()
    loading = false
  }

  // MARK: - Rhythm wheel
  //
  // A 24-hour dial of *when* caffeine lands over the trailing 7 days, faded by
  // recency. See `TimeOfDayWheel`. Only on today (a past-day rhythm view is
  // odd) and only with enough events to read a pattern.

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
      let desc = FetchDescriptor<CaffeineEventEntity>(
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
      DrawerSection("When you have caffeine", padding: .tight) {
        TimeOfDayWheel(events: events, accent: accent, windowDays: 7, nowFraction: nowFraction)
          .frame(maxWidth: .infinity)
      }
    }
  }
}
