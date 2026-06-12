import SwiftUI
import SwiftData
import EventKit

/// Shared date formatters — hoisted out of the (now generic) view, since
/// generic types can't hold static stored properties.
private enum RhythmFmt {
  static let ymd: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
    return f
  }()
  static let isoLocal: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    f.timeZone = .current
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()
}

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
struct RhythmHomepageView<MenuContent: View>: View {
  let items: [HomepageDomainData]
  /// Oura nights (already loaded by the dashboard) — sleep plots as a band
  /// (bedtime → wake) rather than a dot, since it's a duration, not an instant.
  var sleepNights: [OuraNight] = []
  let onTap: (DomainTapAction) -> Void
  /// Long-press / right-click quick-add menu per section — same plumbing as
  /// the other renderers. Caller hands back `EmptyView` for menu-less sections.
  @ViewBuilder let menuContent: (HomepageDomainData) -> MenuContent

  @Environment(\.modelContext) private var modelContext
  @Environment(DayClock.self) private var clock
  @Environment(SectionTheme.self) private var theme

  @State private var events: [TimeOfDayWheel.Event] = []
  @State private var bands: [TimeOfDayWheel.Band] = []
  /// Per-section buckets feeding the tile mini wheels. The big overlay dial is
  /// just the flattened union of these, so the two never disagree.
  @State private var eventsBySection: [String: [TimeOfDayWheel.Event]] = [:]
  @State private var bandsBySection: [String: [TimeOfDayWheel.Band]] = [:]
  /// Today's calendar events as time-block pills — shown only in the
  /// today-focused view (tap the dial), where a day's schedule is legible.
  @State private var calendarBands: [TimeOfDayWheel.Band] = []

  private let windowDays = 7

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

  /// Section tiles — Rings-style cells, each carrying a mini wheel of *that one
  /// section's* trailing-7-day rhythm in its accent, so the strip is small
  /// multiples that decompose the overlay above. Sections with no timed data
  /// this window fall back to the colored glyph (still a stable color key +
  /// launcher). One per enabled section; tap opens it.
  private var sectionTiles: some View {
    let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]
    return LazyVGrid(columns: columns, spacing: 8) {
      ForEach(timedItems, id: \.id) { item in
        Button { onTap(item.tap) } label: {
          VStack(spacing: 6) {
            tileMark(for: item)
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
        .contextMenu { menuContent(item) }
      }
    }
  }

  /// Sections that can plot on a 24-hour dial — those whose plugin declares
  /// `producesTimedEvents`. Drops dial-less sections (Body, Groceries, GitHub,
  /// …) so the strip never shows a tile that can only ever be a dead glyph.
  private var timedItems: [HomepageDomainData] {
    items.filter {
      SectionRegistry.plugin(forKey: $0.domain.rawValue)?.producesTimedEvents ?? false
    }
  }

  /// A section tile's mark: its own mini wheel when it has timed events/bands
  /// this window, else the colored glyph.
  @ViewBuilder
  private func tileMark(for item: HomepageDomainData) -> some View {
    let key = item.domain.rawValue
    let ev = eventsBySection[key] ?? []
    let bd = bandsBySection[key] ?? []
    if ev.isEmpty && bd.isEmpty {
      SectionGlyph(icon: item.icon, accent: item.accent)
    } else {
      TimeOfDayWheel(events: ev, accent: item.accent, bands: bd,
                     windowDays: windowDays, diameter: 84, compact: true)
    }
  }

  private func reload() async {
    let snap = RhythmData.load(
      visible: Set(items.map { $0.domain.rawValue }),
      colors: byKey.mapValues { $0.accent },
      sleepNights: sleepNights,
      todayStart: todayStart,
      now: clock.now,
      windowDays: windowDays,
      calendarFallback: theme.color(for: "calendar"),
      context: modelContext
    )
    eventsBySection = snap.eventsBySection
    bandsBySection = snap.bandsBySection
    events = snap.events
    bands = snap.bands
    calendarBands = snap.calendarBands
  }
}

// MARK: - Shared rhythm snapshot loader

/// The one cross-section "rhythm" fetch (§8): both 24-hour dials — the Rhythm
/// homepage mode above and the front-door `DayDialHero` — load through here,
/// so the two can never disagree about what a day's dots and bands are.
@MainActor
enum RhythmData {
  struct Snapshot {
    var eventsBySection: [String: [TimeOfDayWheel.Event]] = [:]
    var bandsBySection: [String: [TimeOfDayWheel.Band]] = [:]
    var calendarBands: [TimeOfDayWheel.Band] = []
    var events: [TimeOfDayWheel.Event] { eventsBySection.values.flatMap { $0 } }
    var bands: [TimeOfDayWheel.Band] { bandsBySection.values.flatMap { $0 } }
  }

  static func load(visible: Set<String>,
                   colors: [String: Color],
                   sleepNights: [OuraNight],
                   todayStart: Date,
                   now: Date,
                   windowDays: Int,
                   calendarFallback: Color,
                   context: ModelContext) -> Snapshot {
    let weekStart = Calendar.current.date(byAdding: .day, value: -(windowDays - 1), to: todayStart) ?? todayStart

    // Training renders as session pills (durations), not dots — pull it out of
    // the instant-event stream and add it to the bands below instead.
    let timed = LoggedEvents.timed(since: weekStart, in: context)
      .filter { visible.contains($0.sectionKey) && $0.sectionKey != "training" }

    // Bucket events/bands by section so each tile can draw its own mini wheel;
    // the overlay dial is the flattened union of the buckets.
    var snap = Snapshot()
    for t in timed {
      guard let e = TimeOfDayWheel.Event(
        id: t.id, occurredAt: t.occurredAt, todayStart: todayStart,
        windowDays: windowDays, color: colors[t.sectionKey]
      ) else { continue }
      snap.eventsBySection[t.sectionKey, default: []].append(e)
    }
    // Tasks aren't `LoggedEvent`s — add completed tasks as dots so the wheel
    // matches the timeline (which plots done tasks at their completedAt time).
    if visible.contains("tasks") {
      let te = taskEvents(todayStart: todayStart, windowDays: windowDays,
                          color: colors["tasks"], context: context)
      if !te.isEmpty { snap.eventsBySection["tasks", default: []].append(contentsOf: te) }
    }

    let sleep = sleepBands(nights: sleepNights, todayStart: todayStart, windowDays: windowDays,
                           visible: visible, sleepColor: colors["sleep"])
    if !sleep.isEmpty { snap.bandsBySection["sleep"] = sleep }
    if visible.contains("training") {
      let train = trainingBands(todayStart: todayStart, weekStart: weekStart,
                                windowDays: windowDays, color: colors["training"], context: context)
      if !train.isEmpty { snap.bandsBySection["training"] = train }
    }
    snap.calendarBands = todayCalendarBands(now: now, fallback: calendarFallback)
    return snap
  }

  /// Completed tasks as dots, placed at their local `completedAt` time —
  /// mirrors `DayTimelineView`'s task handling. The `Event` init bounds them to
  /// the window.
  private static func taskEvents(todayStart: Date, windowDays: Int,
                                 color: Color?, context: ModelContext) -> [TimeOfDayWheel.Event] {
    let desc = FetchDescriptor<TaskEntity>(predicate: #Predicate { $0.statusRaw == "done" })
    let rows = (try? context.fetch(desc)) ?? []
    return rows.compactMap { t in
      guard let cs = t.completedAt, let when = RhythmFmt.isoLocal.date(from: cs) else { return nil }
      return TimeOfDayWheel.Event(id: t.id, occurredAt: when, todayStart: todayStart,
                                  windowDays: windowDays, color: color)
    }
  }

  /// Each day's training as a session pill (bedtime-style band), grouping the
  /// day's exercise rows and merging gaps under 0.75h — the same session idea
  /// `DayTimelineView` draws as a bar. Faded by recency like the other bands.
  private static func trainingBands(todayStart: Date, weekStart: Date, windowDays: Int,
                                    color: Color?, context: ModelContext) -> [TimeOfDayWheel.Band] {
    guard let color else { return [] }
    let rows = (try? context.fetch(
      FetchDescriptor<ExerciseEntryEntity>(predicate: #Predicate { $0.occurredAt >= weekStart })
    )) ?? []
    let cal = Calendar.current
    var out: [TimeOfDayWheel.Band] = []
    for (dateStr, dayRows) in Dictionary(grouping: rows, by: \.date) {
      guard let d = RhythmFmt.ymd.date(from: dateStr) else { continue }
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
  private static func todayCalendarBands(now: Date, fallback: Color) -> [TimeOfDayWheel.Band] {
    guard CalendarBridge.shared.access == .granted else { return [] }
    let cal = Calendar.current
    let dayStart = cal.startOfDay(for: now)
    guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
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
        color: color,
        thin: true
      )
    }
  }

  /// Each recent night's sleep as a bedtime→wake arc, faded by recency. Only
  /// when the sleep section is enabled and we have a color for it.
  private static func sleepBands(nights: [OuraNight], todayStart: Date, windowDays: Int,
                                 visible: Set<String>, sleepColor: Color?) -> [TimeOfDayWheel.Band] {
    guard visible.contains("sleep"), let sleepColor else { return [] }
    let cal = Calendar.current
    return nights.compactMap { n in
      guard let b = frac(fromHHmm: n.bedtime),
            let w = frac(fromHHmm: n.wakeTime),
            let d = RhythmFmt.ymd.date(from: n.date) else { return nil }
      let daysAgo = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: todayStart).day ?? 0
      guard daysAgo >= 0, daysAgo < windowDays else { return nil }
      // Thin like the calendar pills — a night is context, not a headline;
      // the heavy stroke made sleep dominate the dial.
      return TimeOfDayWheel.Band(id: n.id, start: b, end: w, daysAgo: daysAgo,
                                 color: sleepColor, thin: true)
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
