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
  /// Debounce token for `.septenaDataChanged`-driven reloads — coalesces the
  /// optimistic post with CloudKit's echo. Cancelled and replaced per post.
  @State private var reloadTask: Task<Void, Never>?

  private let windowDays = 7

  /// Roll the dial over at wake (sleep → 4am cutoff → midnight) rather than
  /// calendar midnight, so a late night stays on the same dial. Shared default
  /// with `DayDialHero`; off → plain midnight buckets. See `WakingDay`.
  @AppStorage(SettingsKey.wheelWakingDay) private var wakingDayEnabled = true

  /// Section accent + title + tap, keyed for fast lookup while mapping the
  /// flat event list and building the legend.
  private var byKey: [String: HomepageDomainData] {
    Dictionary(items.map { ($0.domain.rawValue, $0) }, uniquingKeysWith: { a, _ in a })
  }

  /// The dial's day boundary, built from the loaded Oura nights.
  private var wakingDay: WakingDay {
    WakingDay.from(nights: sleepNights, enabled: wakingDayEnabled)
  }

  /// `dayKey` of the current waking day — the wheel's "today". In the small
  /// hours this is still yesterday's civil date until you wake.
  private var todayStart: Date {
    wakingDay.dayKey(containing: clock.now)
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
    // Reload on appear, waking-day rollover (todayStart flips at wake/cutoff,
    // not just midnight — clock.now ticks it within 60s), and any logged write.
    .task(id: todayStart) { await reload() }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { note in
      // Reload only when a section the dial actually plots changed (or the post
      // is unscoped — a CloudKit batch). A scoped change to a dial-less section
      // (goals, coach, groceries…) no longer triggers a full cross-section sweep.
      guard note.affectsAnySection(of: dialSections) else { return }
      scheduleReload()
    }
  }

  /// Sections the dial can render — gates the data-changed listener so only
  /// relevant edits reload it. The visible set already covers the timed
  /// sections; the extras are the non-`LoggedEvent` streams `RhythmData` reads.
  private var dialSections: Set<String> {
    Set(items.map { $0.domain.rawValue })
      .union(["tasks", "intake", "training", "sleep", "calendar"])
  }

  /// Coalesce the optimistic scoped post and CloudKit's unscoped echo (which
  /// arrive a fraction of a second apart for the same local edit) into one
  /// reload, so a single toggle pays for one cross-section fetch, not two.
  private func scheduleReload() {
    reloadTask?.cancel()
    reloadTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      await reload()
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
          .tileHover(cornerRadius: 14)
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
    let snap = await RhythmData.load(
      visible: Set(items.map { $0.domain.rawValue }),
      colors: byKey.mapValues { $0.accent },
      sleepNights: sleepNights,
      todayStart: todayStart,
      now: clock.now,
      windowDays: windowDays,
      calendarFallback: theme.color(for: "calendar"),
      wakingDay: wakingDay,
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

  /// `Sendable` projection of the raw SwiftData rows the dial needs, fetched on
  /// a background `ModelContext` so the store work stays off the main thread.
  /// No `Color` (not `Sendable`) and no `@Model` entity crosses back — only flat
  /// values; the main actor resolves colors and builds the wheel structs from
  /// these (see `load`).
  struct RawRows: Sendable {
    var timed: [TimedEvent] = []
    var tasks: [TaskRow] = []
    var intake: [IntakeRow] = []
    /// Intake kind id → its stored color token, resolved to a `Color` on main.
    var intakeKindColors: [String: String] = [:]
    var training: [TrainingRow] = []
  }
  struct TaskRow: Sendable { let id: String; let completedAt: String }
  struct IntakeRow: Sendable { let id: String; let occurredAt: Date; let kindID: String }
  typealias TrainingRow = TrainingSessionSpans.Entry

  /// The store-touching half of `load`: every window-bounded SwiftData fetch,
  /// run on a background context off the main thread. Pure value-in / value-out
  /// (`nonisolated`), so it's safe to call from a detached task. Predicates are
  /// unchanged from the old inline fetches.
  nonisolated static func fetchRows(visible: Set<String>, weekStart: Date,
                                    context: ModelContext) -> RawRows {
    var r = RawRows()
    // Training renders as session pills (durations), not dots — drop it from the
    // instant-event stream; it comes back as bands via the training rows below.
    r.timed = LoggedEvents.timed(since: weekStart, in: context)
      .filter { visible.contains($0.sectionKey) && $0.sectionKey != "training" }
    if visible.contains("tasks") {
      // `completedAt` is an ISO-local string that sorts lexicographically, so a
      // string `>=` is a valid date bound — keeps history out of the fetch.
      let cutoff = RhythmFmt.isoLocal.string(from: weekStart)
      let desc = FetchDescriptor<TaskEntity>(
        predicate: #Predicate { $0.statusRaw == "done" && $0.deletedAt == nil && ($0.completedAt ?? "") >= cutoff })
      r.tasks = ((try? context.fetch(desc)) ?? []).compactMap { t in
        t.completedAt.map { TaskRow(id: t.id, completedAt: $0) }
      }
    }
    if visible.contains("intake") {
      let rows = (try? context.fetch(
        FetchDescriptor<IntakeEventEntity>(predicate: #Predicate { $0.occurredAt >= weekStart }))) ?? []
      r.intake = rows.map { IntakeRow(id: $0.id, occurredAt: $0.occurredAt, kindID: $0.kindID) }
      // One fetch of the kinds, mapped id → color token; the join is in-memory.
      let kinds = (try? context.fetch(FetchDescriptor<IntakeKindEntity>())) ?? []
      for k in kinds { r.intakeKindColors[k.id] = k.color }
    }
    if visible.contains("training") {
      let rows = (try? context.fetch(
        FetchDescriptor<ExerciseEntryEntity>(predicate: #Predicate { $0.occurredAt >= weekStart }))) ?? []
      r.training = rows.map {
        TrainingRow(date: $0.date,
                    concludedAt: $0.concludedAt,
                    loggedAt: $0.loggedAt,
                    durationMin: $0.durationMin,
                    occurredAt: $0.occurredAt)
      }
    }
    return r
  }

  static func load(visible: Set<String>,
                   colors: [String: Color],
                   sleepNights: [OuraNight],
                   todayStart: Date,
                   now: Date,
                   windowDays: Int,
                   calendarFallback: Color,
                   wakingDay: WakingDay = WakingDay(enabled: false),
                   context: ModelContext) async -> Snapshot {
    let weekStart = Calendar.current.date(byAdding: .day, value: -(windowDays - 1), to: todayStart) ?? todayStart

    // The SwiftData fetches (the heavy part) run on a background context off the
    // main thread; only flat `Sendable` rows come back. The `ModelContainer` is
    // `Sendable`, so a detached task can spin its own `ModelContext` from it.
    let container = context.container
    let rows = await Task.detached(priority: .userInitiated) {
      fetchRows(visible: visible, weekStart: weekStart, context: ModelContext(container))
    }.value

    // Bucket events/bands by section so each tile can draw its own mini wheel;
    // the overlay dial is the flattened union of the buckets. `Color` resolution
    // + struct construction stay here on the main actor (`Color` isn't `Sendable`).
    var snap = Snapshot()
    for t in rows.timed {
      guard let e = TimeOfDayWheel.Event(
        id: t.id, occurredAt: t.occurredAt, todayStart: todayStart,
        windowDays: windowDays, color: colors[t.sectionKey],
        magnitude: t.magnitude, wakingDay: wakingDay
      ) else { continue }
      snap.eventsBySection[t.sectionKey, default: []].append(e)
    }
    // Tasks aren't `LoggedEvent`s — add completed tasks as dots so the wheel
    // matches the timeline (which plots done tasks at their completedAt time).
    if visible.contains("tasks") {
      let te = taskEvents(rows: rows.tasks, todayStart: todayStart, windowDays: windowDays,
                          color: colors["tasks"], wakingDay: wakingDay)
      if !te.isEmpty { snap.eventsBySection["tasks", default: []].append(contentsOf: te) }
    }
    // Intake plots per *kind* color (coffee, matcha, … each carry their own),
    // not the flat section accent — so it gets its own path rather than the
    // section-keyed `timed` stream.
    if visible.contains("intake") {
      let ie = intakeEvents(rows: rows.intake, kindColors: rows.intakeKindColors,
                            todayStart: todayStart, windowDays: windowDays,
                            sectionColor: colors["intake"], wakingDay: wakingDay)
      if !ie.isEmpty { snap.eventsBySection["intake", default: []].append(contentsOf: ie) }
    }

    let sleep = sleepBands(nights: sleepNights, todayStart: todayStart, windowDays: windowDays,
                           visible: visible, sleepColor: colors["sleep"], wakingDay: wakingDay)
    if !sleep.isEmpty { snap.bandsBySection["sleep"] = sleep }
    if visible.contains("training") {
      let train = trainingBands(rows: rows.training, todayStart: todayStart,
                                windowDays: windowDays, color: colors["training"],
                                wakingDay: wakingDay)
      if !train.isEmpty { snap.bandsBySection["training"] = train }
    }
    // Calendar for the *displayed* day (today, or a scrubbed past day) — the
    // `todayStart` the rest of this load is keyed to. EventKit, kept on main.
    snap.calendarBands = calendarBands(on: todayStart, fallback: calendarFallback)
    return snap
  }

  /// Completed tasks as dots, placed at their local `completedAt` time —
  /// mirrors `DayTimelineView`'s task handling. The `Event` init bounds them to
  /// the window. Rows are the window-bounded fetch from `fetchRows`.
  private static func taskEvents(rows: [TaskRow], todayStart: Date, windowDays: Int,
                                 color: Color?, wakingDay: WakingDay) -> [TimeOfDayWheel.Event] {
    rows.compactMap { t in
      guard let when = RhythmFmt.isoLocal.date(from: t.completedAt) else { return nil }
      return TimeOfDayWheel.Event(id: t.id, occurredAt: when, todayStart: todayStart,
                                  windowDays: windowDays, color: color, wakingDay: wakingDay)
    }
  }

  /// Intake events as dots, each tinted by its *kind*'s own color (each kind
  /// defines one) rather than the flat section accent.
  /// Falls back to the section color for a kind with no color set.
  private static func intakeEvents(rows: [IntakeRow], kindColors: [String: String],
                                   todayStart: Date, windowDays: Int,
                                   sectionColor: Color?, wakingDay: WakingDay) -> [TimeOfDayWheel.Event] {
    guard !rows.isEmpty else { return [] }
    var kindColor: [String: Color] = [:]
    for (id, token) in kindColors { if let c = AdaptiveColor.adaptive(token) { kindColor[id] = c } }
    return rows.compactMap { e in
      TimeOfDayWheel.Event(id: e.id, occurredAt: e.occurredAt, todayStart: todayStart,
                           windowDays: windowDays,
                           color: kindColor[e.kindID] ?? sectionColor, wakingDay: wakingDay)
    }
  }

  /// Each day's training as a session band — `TrainingSessionSpans` is the
  /// single source of truth shared with `DayTimelineView`. Faded by recency.
  private static func trainingBands(rows: [TrainingRow], todayStart: Date, windowDays: Int,
                                    color: Color?, wakingDay: WakingDay) -> [TimeOfDayWheel.Band] {
    guard let color else { return [] }
    let cal = Calendar.current
    var out: [TimeOfDayWheel.Band] = []
    for (dateStr, dayRows) in Dictionary(grouping: rows, by: \.date) {
      guard let d = RhythmFmt.ymd.date(from: dateStr) else { continue }
      let daysAgo = wakingDay.daysAgo(d.addingTimeInterval(43_200), todayKey: todayStart, calendar: cal)
      guard daysAgo >= 0, daysAgo < windowDays else { continue }
      for (i, span) in TrainingSessionSpans.sessions(on: dateStr, entries: dayRows).enumerated() {
        let clamped = TrainingSessionSpans.withMinimumWidth(span)
        out.append(TimeOfDayWheel.Band(
          id: "\(dateStr)-train-\(i)",
          start: clamped.startHour / 24,
          end: min(clamped.endHour / 24, 0.9999),
          daysAgo: daysAgo,
          color: color,
          opaque: true
        ))
      }
    }
    return out
  }

  /// Today's (non-all-day) calendar events as bedtime-style pills — start →
  /// end fractions of the local day, each in its own calendar's color. Empty
  /// when calendar access isn't granted (no prompt from here). Clamped to the
  /// day so a multi-day event reads as a single block.
  private static func calendarBands(on day: Date, fallback: Color) -> [TimeOfDayWheel.Band] {
    // Screenshot builds have no real calendar access; synthesize a couple of
    // thin meeting arcs so the dial shows scheduled time alongside the logged
    // dots. Morning standup + an afternoon block.
    if DemoSeedMode.isOn {
      return [
        TimeOfDayWheel.Band(id: "demo-cal-1", start: 9.0 / 24, end: 9.5 / 24,
                            daysAgo: 0, color: fallback, thin: true),
        TimeOfDayWheel.Band(id: "demo-cal-2", start: 14.0 / 24, end: 15.5 / 24,
                            daysAgo: 0, color: fallback, thin: true),
      ]
    }
    guard CalendarBridge.shared.access == .granted else { return [] }
    let cal = Calendar.current
    let dayStart = cal.startOfDay(for: day)
    guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
    return CalendarBridge.shared.events(on: day).compactMap { e in
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
                                 visible: Set<String>, sleepColor: Color?,
                                 wakingDay: WakingDay) -> [TimeOfDayWheel.Band] {
    guard visible.contains("sleep"), let sleepColor else { return [] }
    let cal = Calendar.current
    return nights.compactMap { n in
      guard let b = frac(fromHHmm: n.bedtime),
            let w = frac(fromHHmm: n.wakeTime),
            let d = RhythmFmt.ymd.date(from: n.date) else { return nil }
      // The night ending the morning of `n.date` belongs to that date's waking
      // day (it's how the day began). Noon resolves to that same waking day.
      let daysAgo = wakingDay.daysAgo(d.addingTimeInterval(43_200), todayKey: todayStart, calendar: cal)
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
