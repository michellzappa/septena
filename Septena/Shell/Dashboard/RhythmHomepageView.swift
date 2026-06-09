import SwiftUI
import SwiftData
import EventKit

/// Rhythm homepage renderer — the holistic counterpart to the per-section
/// detail wheel. One big 24-hour dial overlays *every* enabled section's
/// timestamped events from the trailing 7 days, each dot tinted its section
/// color and faded by recency. Answers "when does my day actually happen" —
/// eating, coffee, mood, gut — in a single read the per-day tiles can't give.
///
/// Reuses `TimeOfDayWheel` (the same component the nutrition / caffeine detail
/// views use) with per-event colors. Data comes from one cross-section fetch
/// (`LoggedEvents.timed(since:)`), not the per-day `HistorySeries` the other
/// layout modes consume — which is exactly why the wheel is a holistic mode
/// and not a per-domain grid.
struct RhythmHomepageView: View {
  let items: [HomepageDomainData]
  /// Oura nights (already loaded by the dashboard) — sleep plots as a band
  /// (bedtime → wake) rather than a dot, since it's a duration, not an instant.
  var sleepNights: [OuraNight] = []
  let onTap: (DomainTapAction) -> Void

  @Environment(\.modelContext) private var modelContext
  @Environment(DayClock.self) private var clock
  @Environment(SectionTheme.self) private var theme

  @State private var events: [TimeOfDayWheel.Event] = []
  @State private var bands: [TimeOfDayWheel.Band] = []
  /// Today's calendar events as time-block pills — shown only in the
  /// today-focused view (tap the dial), where a day's schedule is legible.
  @State private var calendarBands: [TimeOfDayWheel.Band] = []

  private let windowDays = 7

  private static let ymdFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
    return f
  }()

  /// Section accent + title + tap, keyed for fast lookup while mapping the
  /// flat event list and building the legend.
  private var byKey: [String: HomepageDomainData] {
    Dictionary(items.map { ($0.domain.rawValue, $0) }, uniquingKeysWith: { a, _ in a })
  }

  private var todayStart: Date {
    SeptenaDate.parse(clock.today).map { Calendar.current.startOfDay(for: $0) }
      ?? Calendar.current.startOfDay(for: clock.now)
  }

  private var nowFraction: Double {
    let c = Calendar.current.dateComponents([.hour, .minute], from: clock.now)
    return (Double(c.hour ?? 0) * 60 + Double(c.minute ?? 0)) / 1440
  }

  var body: some View {
    VStack(spacing: 18) {
      if events.isEmpty && bands.isEmpty && calendarBands.isEmpty {
        ContentUnavailableView(
          "No timed activity yet",
          systemImage: "clock",
          description: Text("Log meals, coffee, mood, or other timestamped sections and your daily rhythm shows up here.")
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
      } else {
        TimeOfDayWheel(
          // The dial owns its own dot/band colors; this accent only tints the
          // ring + ticks. Use a neutral so no single section frames the chart.
          events: events,
          accent: Theme.inkSecondary,
          bands: bands,
          todayBands: calendarBands,
          windowDays: windowDays,
          nowFraction: nowFraction,
          diameter: 300
        )
        sectionTiles
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
    // Reload on appear, day-rollover (clock.today), and any logged write.
    .task(id: clock.today) { await reload() }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in
      Task { await reload() }
    }
  }

  /// Section identity tiles — Rings-style cells stripped to just the colored
  /// glyph + name (no value), so the section's color lives here instead of an
  /// improvised legend. One per section present on the dial; tap opens it.
  private var sectionTiles: some View {
    let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]
    // Every enabled section gets a tile (like Rings) so the strip is a stable
    // color key + launcher, whether or not that section has events this window.
    return LazyVGrid(columns: columns, spacing: 8) {
      ForEach(items, id: \.domain) { item in
        Button { onTap(item.tap) } label: {
          VStack(spacing: 6) {
            SectionGlyph(icon: SectionManifest.byKey[item.domain.rawValue]?.iconSymbol ?? "circle.fill",
                         accent: item.accent)
            Text(item.title)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.primary)
              .lineLimit(1)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 12)
          .background(Theme.cardSurface)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
  }

  private func reload() async {
    let start = todayStart
    let weekStart = Calendar.current.date(byAdding: .day, value: -(windowDays - 1), to: start) ?? start
    let visible = Set(items.map { $0.domain.rawValue })
    let colors = byKey.mapValues { $0.accent }

    // Training renders as session pills (durations), not dots — pull it out of
    // the instant-event stream and add it to the bands below instead.
    let timed = LoggedEvents.timed(since: weekStart, in: modelContext)
      .filter { visible.contains($0.sectionKey) && $0.sectionKey != "training" }

    var mapped: [TimeOfDayWheel.Event] = []
    for t in timed {
      guard let e = TimeOfDayWheel.Event(
        id: t.id, occurredAt: t.occurredAt, todayStart: start,
        windowDays: windowDays, color: colors[t.sectionKey]
      ) else { continue }
      mapped.append(e)
    }
    // Tasks aren't `LoggedEvent`s — add completed tasks as dots so the wheel
    // matches the timeline (which plots done tasks at their completedAt time).
    if visible.contains("tasks") {
      mapped.append(contentsOf: taskEvents(todayStart: start, color: colors["tasks"]))
    }
    events = mapped

    var allBands = sleepBands(todayStart: start, visible: visible, sleepColor: colors["sleep"])
    if visible.contains("training") {
      allBands += trainingBands(todayStart: start, weekStart: weekStart, color: colors["training"])
    }
    bands = allBands
    calendarBands = todayCalendarBands()
  }

  private static let isoLocalFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    f.timeZone = .current
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()

  /// Completed tasks as dots, placed at their local `completedAt` time —
  /// mirrors `DayTimelineView`'s task handling. The `Event` init bounds them to
  /// the window.
  private func taskEvents(todayStart: Date, color: Color?) -> [TimeOfDayWheel.Event] {
    let desc = FetchDescriptor<TaskEntity>(predicate: #Predicate { $0.statusRaw == "done" })
    let rows = (try? modelContext.fetch(desc)) ?? []
    return rows.compactMap { t in
      guard let cs = t.completedAt, let when = Self.isoLocalFormatter.date(from: cs) else { return nil }
      return TimeOfDayWheel.Event(id: t.id, occurredAt: when, todayStart: todayStart,
                                  windowDays: windowDays, color: color)
    }
  }

  /// Each day's training as a session pill (bedtime-style band), grouping the
  /// day's exercise rows and merging gaps under 0.75h — the same session idea
  /// `DayTimelineView` draws as a bar. Faded by recency like the other bands.
  private func trainingBands(todayStart: Date, weekStart: Date, color: Color?) -> [TimeOfDayWheel.Band] {
    guard let color else { return [] }
    let rows = (try? modelContext.fetch(
      FetchDescriptor<ExerciseEntryEntity>(predicate: #Predicate { $0.occurredAt >= weekStart })
    )) ?? []
    let cal = Calendar.current
    var out: [TimeOfDayWheel.Band] = []
    for (dateStr, dayRows) in Dictionary(grouping: rows, by: \.date) {
      guard let d = Self.ymdFormatter.date(from: dateStr) else { continue }
      let daysAgo = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: todayStart).day ?? 0
      guard daysAgo >= 0, daysAgo < windowDays else { continue }
      // Per-entry spans (start hour → start + duration), then merge near ones.
      let spans = dayRows.compactMap { e -> (Double, Double)? in
        guard e.occurredAt > .distantPast else { return nil }
        let c = cal.dateComponents([.hour, .minute], from: e.occurredAt)
        let startH = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
        return (startH, startH + (e.durationMin ?? 0) / 60)
      }.sorted { $0.0 < $1.0 }
      var merged: [(Double, Double)] = []
      for s in spans {
        if var last = merged.last, s.0 <= last.1 + 0.75 {
          last.1 = max(last.1, s.1); merged[merged.count - 1] = last
        } else {
          merged.append(s)
        }
      }
      for (i, m) in merged.enumerated() {
        out.append(TimeOfDayWheel.Band(
          id: "\(dateStr)-train-\(i)",
          start: m.0 / 24,
          end: min(max(m.1, m.0 + 0.05) / 24, 0.9999),
          daysAgo: daysAgo,
          color: color
        ))
      }
    }
    return out
  }

  /// Today's (non-all-day) calendar events as bedtime-style pills — start →
  /// end fractions of the local day, each in its own calendar's color. Empty
  /// when calendar access isn't granted (no prompt from here). Clamped to the
  /// day so a multi-day event reads as a single block.
  private func todayCalendarBands() -> [TimeOfDayWheel.Band] {
    guard CalendarBridge.shared.access == .granted else { return [] }
    let cal = Calendar.current
    let dayStart = cal.startOfDay(for: clock.now)
    guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
    let fallback = theme.color(for: "calendar")
    return CalendarBridge.shared.todayEvents().compactMap { e in
      guard !e.isAllDay else { return nil }
      let s = max(e.startDate, dayStart)
      let f = min(e.endDate, dayEnd)
      guard f > s else { return nil }
      let color = e.calendar?.cgColor.map { Color($0) } ?? fallback
      return TimeOfDayWheel.Band(
        id: e.eventIdentifier ?? "\(s.timeIntervalSince1970)",
        start: s.timeIntervalSince(dayStart) / 86400,
        end: f.timeIntervalSince(dayStart) / 86400,
        daysAgo: 0,
        color: color
      )
    }
  }

  /// Each recent night's sleep as a bedtime→wake arc, faded by recency. Only
  /// when the sleep section is enabled and we have a color for it.
  private func sleepBands(todayStart: Date, visible: Set<String>, sleepColor: Color?) -> [TimeOfDayWheel.Band] {
    guard visible.contains("sleep"), let sleepColor else { return [] }
    let cal = Calendar.current
    return sleepNights.compactMap { n in
      guard let b = Self.frac(fromHHmm: n.bedtime),
            let w = Self.frac(fromHHmm: n.wakeTime),
            let d = Self.ymdFormatter.date(from: n.date) else { return nil }
      let daysAgo = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: todayStart).day ?? 0
      guard daysAgo >= 0, daysAgo < windowDays else { return nil }
      return TimeOfDayWheel.Band(id: n.id, start: b, end: w, daysAgo: daysAgo, color: sleepColor)
    }
  }

  private static func frac(fromHHmm s: String?) -> Double? {
    guard let s else { return nil }
    let parts = s.split(separator: ":")
    guard let h = Double(parts.first ?? "") else { return nil }
    let m = parts.count > 1 ? (Double(parts[1]) ?? 0) : 0
    return (h * 60 + m) / 1440
  }
}
