import SwiftUI
import SwiftData

// MoodDestinationView — the section's main pane.
//
// Three bands:
// 1. Three slot cards (morning / afternoon / evening). Each shows the
//    most-recent log for that bucket, or an empty "Log <bucket>" button.
//    Slots are soft — logging more than once in a bucket is allowed; the
//    card shows the latest, and the day list below carries the full set.
// 2. Today's full timeline of logs.
// 3. 30-day heatmap — three rows (one per bucket) × 30 columns, colored
//    by quadrant, opacity by log density.

struct MoodDestinationView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme
  @Environment(DayClock.self) private var clock

  private var accent: Color { theme.color(for: "mood") }

  @State private var today: MoodDayResponse? = nil
  @State private var monthEntries: [MoodEntry] = []
  /// Trailing-7-day check-in instants (with quadrant) for the rhythm wheel.
  @State private var weekPoints: [WheelPoint] = []
  @State private var addingNew = false
  @State private var editing: MoodEntry? = nil
  @State private var loading = true
  /// Day the drawer's date strip is pointing at. In Log mode the list
  /// follows this date; Patterns is cross-day and ignores it.
  @State private var viewingDate: String = SeptenaDate.today
  // Mood is an editable dual section: Log = the day's check-ins; Patterns =
  // 30-day quadrant breakdown + 7-day rhythm wheel. Default Log; remembered.
  @State private var mode: DrawerMode = .remembered(for: "mood", default: .log)
  /// Whether the one-shot empty-state nudge has run for this appearance.
  @State private var didNudge = false

  private var isViewingToday: Bool { viewingDate == SeptenaDate.today }

  var body: some View {
    SectionDrawer(sectionKey: "mood",
                  quickAdd: DrawerQuickAdd("Log mood") { addingNew = true },
                  currentDate: $viewingDate,
                  mode: $mode,
                  log: {
      todaySection
    }, patterns: {
      breakdownSection
      rhythmSection
      if monthEntries.isEmpty, wheelEvents.count < 3, !loading {
        DrawerSection("Patterns") {
          Text("Not enough check-ins yet to chart your week — keep logging and your rhythm and quadrant mix appear here.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
    })
    .sectionReload(on: viewingDate, onDataChange: true,
                   forSections: ["mood"]) { await reload() }
    .adaptiveDetail(isPresented: $addingNew) {
      AddMoodPage(onLogged: { Task { await reload() } })
    }
    .adaptiveDetail(item: $editing) { entry in
      EditMoodEntrySheet(date: viewingDate,
                         original: entry,
                         onSave: { Task { await reload() } })
    }
  }

  // MARK: - Today list

  @ViewBuilder
  private var todaySection: some View {
    if let today, today.entries.count > 0 {
      DrawerSection(isViewingToday ? "All logs today" : "Logs", padding: .none) {
        ForEach(today.entries.reversed()) { entry in
          LogEntryRow(
            title: entry.emotion,
            detail: entry.note?.isEmpty == false ? entry.note : nil,
            trailing: String(entry.time.prefix(5)),
            leading: quadrantDot(entry),
            tint: accent,
            isSelected: editing?.id == entry.id,
            onEdit: { editing = entry },
            onDelete: { delete(entry) }
          )
        }
      }
    } else if !loading {
      DrawerSection {
        Text(isViewingToday ? "No check-ins yet today." : "No check-ins on this day.")
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Quadrant breakdown (30d)

  @ViewBuilder
  private var breakdownSection: some View {
    if !monthEntries.isEmpty {
      DrawerSection("Where you spent your time") {
        QuadrantBreakdownView(entries: monthEntries)
      }
    }
  }

  // MARK: - Rhythm wheel
  //
  // A 24-hour dial of *when* you check in over the trailing 7 days, each dot
  // tinted its mood quadrant and faded by recency — surfaces the diurnal swing.
  // See `TimeOfDayWheel`. Today only, and only with enough events to read.

  private struct WheelPoint: Identifiable, Sendable {
    let id: String
    let at: Date
    let quadrant: String
  }

  private var todayStart: Date {
    SeptenaDate.parse(clock.today).map { Calendar.current.startOfDay(for: $0) }
      ?? Calendar.current.startOfDay(for: clock.now)
  }

  private func reloadWeek() async {
    let weekStart = Calendar.current.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
    weekPoints = await MirrorReader.shared.read { ctx in
      let desc = FetchDescriptor<MoodEventEntity>(
        predicate: #Predicate { $0.occurredAt >= weekStart },
        sortBy: [SortDescriptor(\.occurredAt)]
      )
      return ((try? ctx.fetch(desc)) ?? []).map {
        WheelPoint(id: $0.id, at: $0.occurredAt, quadrant: $0.quadrant)
      }
    }
  }

  private var wheelEvents: [TimeOfDayWheel.Event] {
    let start = todayStart
    return weekPoints.compactMap { p in
      TimeOfDayWheel.Event(id: p.id, occurredAt: p.at, todayStart: start, windowDays: 7,
                           color: MoodQuadrant(rawValue: p.quadrant)?.color)
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
      DrawerSection("When you check in", padding: .tight) {
        TimeOfDayWheel(events: events, accent: accent, windowDays: 7, nowFraction: nowFraction)
          .frame(maxWidth: .infinity)
      }
    }
  }

  /// Leading quadrant-color dot — the row's only section-specific glyph.
  private func quadrantDot(_ entry: MoodEntry) -> AnyView {
    AnyView(
      Circle()
        .fill((MoodQuadrant(rawValue: entry.quadrant)?.color ?? .gray).opacity(0.85))
        .frame(width: 12, height: 12)
    )
  }

  private func delete(_ entry: MoodEntry) {
    SeptenaServices.shared.moodMutator.deleteEntry(id: entry.id)
    Haptics.warning()
    Task { await reload() }
  }

  private func reload() async {
    let date = viewingDate
    // The monthly breakdown renders only when viewing today, so only
    // refresh it in that mode — saves a fetch when time-travelling.
    let wantsMonth = isViewingToday
    let result = await MirrorReader.shared.read { ctx in
      (day: ChecklistMirror.loadMoodDay(context: ctx, date: date),
       month: wantsMonth ? Self.loadMonthEntries(context: ctx) : nil)
    }
    today = result.day
    if let month = result.month {
      monthEntries = month
    }
    if isViewingToday { await reloadWeek() }
    loading = false
    applyEmptyStateNudgeIfNeeded()
  }

  private func applyEmptyStateNudgeIfNeeded() {
    DrawerMode.nudgeEmptyDayToPatterns(mode: $mode, didNudge: $didNudge,
                                       isViewingToday: isViewingToday,
                                       isEmpty: today?.entries.isEmpty ?? true)
  }

  private static func loadMonthEntries(context: ModelContext) -> [MoodEntry] {
    let today = SeptenaDate.today
    guard let todayDate = SeptenaDate.parse(today) else { return [] }
    let start = Calendar.current.date(byAdding: .day, value: -29, to: todayDate) ?? todayDate
    let startStr = SeptenaDate.format(start) ?? today
    let entities = (try? context.fetch(FetchDescriptor<MoodEventEntity>(
      predicate: #Predicate { $0.date >= startStr && $0.date <= today }
    ))) ?? []
    return entities.map {
      MoodEntry(id: $0.id, time: EventTimestamp.hhmm(from: $0.occurredAt), bucket: $0.bucket,
                quadrant: $0.quadrant, arousal: $0.arousal, valence: $0.valence,
                emotion: $0.emotion, note: $0.note)
    }
  }
}

// MARK: - Quadrant breakdown (% of last 30d in each quadrant)

private struct QuadrantBreakdownView: View {
  let entries: [MoodEntry]

  private var counts: [(MoodQuadrant, Int)] {
    MoodQuadrant.allCases.map { q in
      (q, entries.filter { $0.quadrant == q.rawValue }.count)
    }
  }
  private var total: Int { entries.count }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      // Stacked bar
      GeometryReader { geo in
        HStack(spacing: 2) {
          ForEach(counts, id: \.0) { q, n in
            if n > 0 {
              q.color.opacity(0.85)
                .frame(width: geo.size.width * CGFloat(n) / CGFloat(max(total, 1)))
            }
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
      }
      .frame(height: 14)
      // Legend rows
      ForEach(counts, id: \.0) { q, n in
        HStack(spacing: 8) {
          Circle().fill(q.color).frame(width: 10, height: 10)
          Text(q.title).font(.caption)
          Spacer()
          Text(total == 0 ? "0%" : "\(Int(round(Double(n) / Double(total) * 100)))%")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}
