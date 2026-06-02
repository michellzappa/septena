import SwiftUI
import EventKit

// Day timeline — single-row visualization of one date's events. Adapted
// from septena-app's TodayTimeline:
//   • Horizontal rail (compact: wake → bedtime; can be passed a full
//     0–24 range too)
//   • Sun marker at wake_time (from Oura), moon at the median ideal
//     bedtime, sleep-shaded bands on the wings
//   • One dot per event, clustered by (section, ~10-min bucket) so a
//     meal logged as four foods reads as a single fatter dot
//   • Duration "pills" for training sessions and calendar events
//   • Now indicator (only when viewing today)
//   • Section accents pulled from SectionTheme so dot colors match the
//     user's Septena palette
//
// Data is passed in — parents collect once and slice per date — so the
// component is dumb and fast even when 7 stack vertically.

struct DayTimelineView: View {
  let date: String                    // YYYY-MM-DD
  var oura: OuraNight? = nil
  var caffeine: [CaffeineEntry] = []
  var cannabis: [CannabisEntry] = []
  var nutrition: [NutritionEntry] = []
  var gut: [GutEntry] = []
  var mood: [MoodEntry] = []
  var habits: [HabitDayItem] = []
  var supplements: [SupplementDayItem] = []
  var chores: [ChoreItem] = []
  var training: [ExerciseEntry] = []
  var tasks: [SeptenaTask] = []
  var calendar: [EKEvent] = []
  /// Used to source the fasting band color (`macro_colors.fasting`).
  var macroColors: MacroColors? = nil

  @Environment(SectionTheme.self) private var theme
  @Environment(DayClock.self) private var clock

  private var isToday: Bool { date == clock.today }

  // MARK: - Body

  var body: some View {
    VStack(spacing: 4) {
      header
      GeometryReader { geo in
        // Sanitize the proposed width before threading it through the
        // helper functions below — they all compute `pct(...) * w /
        // 100` for `.frame(width:)` and `.position(x:)`, and a NaN or
        // negative `w` (which SwiftUI can pass during transient
        // layout passes at app launch, sheet animations, or rotation)
        // cascades into NaN frame dimensions that CoreGraphics rejects
        // and log-spams once per shape per render pass. Clamping to a
        // safe 0 here is enough — children render at zero size for
        // the bad pass and recover on the next.
        let rawW = geo.size.width
        let w: CGFloat = (rawW.isFinite && rawW > 0) ? rawW : 0
        ZStack(alignment: .leading) {
          rail
          ForEach(Array(calendarBars.enumerated()), id: \.offset) { _, b in
            barPill(b, width: w)
          }
          sleepShade(width: w)
          ticks(width: w)
          fastingBands(width: w)
          ForEach(Array(trainingSessions.enumerated()), id: \.offset) { _, b in
            barPill(b, width: w)
          }
          ForEach(Array(clusters.enumerated()), id: \.offset) { _, c in
            dot(c, width: w)
          }
          if let wake = wakeHour { marker("sun.max.fill", at: wake, width: w) }
          if shouldShowMoon, let moon = moonHour { marker("moon.fill", at: moon, width: w, opacity: moonOpacity) }
          if isToday {
            nowIndicator(width: w)
          }
        }
      }
      .frame(height: 28)
      axisLabels
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack {
      Text(headerDate)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      Spacer()
      Text(headerRight)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
    .padding(.horizontal, 2)
  }

  private var headerDate: String {
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
    guard let d = fmt.date(from: date) else { return date }
    let cal = Calendar.current
    if cal.isDateInToday(d)     { return "Today" }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    let days = cal.dateComponents([.day], from: d, to: Date()).day ?? 0
    if days < 7 {
      let w = DateFormatter(); w.dateFormat = "EEEE"
      return w.string(from: d)
    }
    let p = DateFormatter(); p.dateFormat = "MMM d"
    return p.string(from: d)
  }

  private var headerRight: String {
    let n = clusters.count + bars.count
    let woke = (oura?.wakeTime).map { "woke \($0) · " } ?? ""
    return "\(woke)\(n) \(n == 1 ? "event" : "events")"
  }

  // MARK: - Pieces

  private var rail: some View {
    RoundedRectangle(cornerRadius: 14, style: .continuous)
      .fill(Theme.mutedSurface)
      .frame(height: 18)
      .frame(maxHeight: .infinity)
  }

  @ViewBuilder
  private func sleepShade(width: CGFloat) -> some View {
    if let wake = wakeHour {
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(Color.primary.opacity(0.06))
        .frame(width: max(0, pct(wake) * width / 100), height: 18)
        .frame(maxHeight: .infinity)
    }
    if shouldShowMoon, let moon = moonHour {
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(Color.primary.opacity(0.06))
        .frame(width: max(0, (100 - pct(moon)) * width / 100), height: 18)
        .frame(maxHeight: .infinity)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
  }

  private func ticks(width: CGFloat) -> some View {
    ForEach(hourMarks(width: width), id: \.self) { h in
      Rectangle()
        .fill(Color.primary.opacity(0.08))
        .frame(width: 1, height: 10)
        .position(x: pct(Double(h)) * width / 100, y: 14)
    }
  }

  // MARK: - Fasting bands
  //
  // Two thin horizontal stripes painted on top of the rail in the
  // user-configured fasting color:
  //   • Overnight tail — from wake (or 00:00 fallback) → today's first
  //     meal. The visible end of yesterday's overnight fast.
  //   • Post-dinner   — from today's last meal → now (or bedtime),
  //     gated on hour ≥ evening_hour + post-meal-grace, matching the
  //     web's `computeFastingState`.
  //
  // Stripes are drawn at h=2 so they read as a marker, not a wash, and
  // never intrude on bars/dots above them.

  private static let fastingFallbackColor = Color(hex: 0x8b5cf6)

  private var fastingColor: Color {
    Color(hexString: macroColors?.fasting) ?? Self.fastingFallbackColor
  }

  /// Today's nutrition entries, sorted by time-of-day.
  private var todayMealHours: [Double] {
    nutrition.filter { $0.date == date }
      .compactMap { parseHHMM($0.time) }
      .sorted()
  }

  /// Hardcoded to match `DEFAULT_EVENING_HOUR_24H` / `DEFAULT_POST_MEAL_GRACE_MIN`
  /// in lib/fasting.ts. Settings doesn't surface these to iOS yet — when it
  /// does, plumb them through `AppTargets` instead of these constants.
  private static let eveningHour: Double = 19
  private static let postMealGraceMin: Double = 30

  /// Right band start: only set when the day's last meal happened, we're
  /// past `eveningHour`, and grace has elapsed. Mirrors `computeFastingState`
  /// case B — for non-today dates we anchor "now" to end-of-day so completed
  /// days still surface their post-dinner fast.
  private var fastingFromHour: Double? {
    guard let last = todayMealHours.last else { return nil }
    let anchorHour = isToday ? nowHour : 24
    guard anchorHour >= Self.eveningHour else { return nil }
    let elapsedMin = (anchorHour - last) * 60
    guard elapsedMin >= Self.postMealGraceMin else { return nil }
    return last
  }

  @ViewBuilder
  private func fastingBands(width: CGFloat) -> some View {
    // Left (overnight) — wake → first meal.
    if let first = todayMealHours.first {
      let start = wakeHour ?? 0
      if first > start {
        Capsule(style: .continuous)
          .fill(fastingColor)
          .frame(width: max(0, (pct(first) - pct(start)) * width / 100), height: 2)
          .position(x: ((pct(start) + pct(first)) / 2) * width / 100, y: 14)
      }
    }
    // Right (post-dinner) — last meal → now (or bedtime, whichever first).
    if let from = fastingFromHour {
      let cap = isToday ? nowHour : 24
      let end = min(cap, moonHour ?? 24)
      if end > from {
        Capsule(style: .continuous)
          .fill(fastingColor)
          .frame(width: max(0, (pct(end) - pct(from)) * width / 100), height: 2)
          .position(x: ((pct(from) + pct(end)) / 2) * width / 100, y: 14)
      }
    }
  }

  /// Moon visibility — for non-today dates, always show. For today, only
  /// show once bedtime is "approaching" (within 4h) so the homepage stays
  /// clean in the morning and only flags bed time as evening sets in.
  private var shouldShowMoon: Bool {
    guard let moon = moonHour, moon < 24 else { return false }
    if !isToday { return true }
    if nowHour >= moon { return false }       // past bedtime → hide
    return moon - nowHour <= 4
  }

  /// Fades the moon from 0.4 (4h out) → 1.0 (at bedtime) so it gets more
  /// prominent the closer the user gets.
  private var moonOpacity: Double {
    guard isToday, let moon = moonHour else { return 0.7 }
    let hoursUntil = max(0, min(4, moon - nowHour))
    return 0.4 + (1.0 - hoursUntil / 4) * 0.6
  }

  private func barPill(_ b: Bar, width: CGFloat) -> some View {
    let x = pct(b.startHour) * width / 100
    let w = max(8, pct(b.endHour - b.startHour + windowStart) * width / 100)
    return RoundedRectangle(cornerRadius: 3, style: .continuous)
      .fill(b.color)
      .frame(width: w, height: b.thin ? 3 : 8)
      .frame(maxHeight: .infinity)
      .position(x: x + w / 2, y: 14)
  }

  private func dot(_ c: Cluster, width: CGFloat) -> some View {
    // Circle (not capsule) — width == height so multi-event clusters grow
    // in both dimensions instead of stretching horizontally into a pill.
    let size = min(CGFloat(8), CGFloat(5 + Double(c.count - 1) * 1))
    return Circle()
      .fill(c.color)
      .overlay(Circle().stroke(Theme.paperBackground, lineWidth: 1))
      .frame(width: size, height: size)
      .position(x: pct(c.hour) * width / 100, y: 14)
  }

  private func marker(_ symbol: String, at hour: Double, width: CGFloat,
                      opacity: Double = 1) -> some View {
    Image(systemName: symbol)
      .scaledFont(size: 11)
      .opacity(opacity)
      .position(x: pct(hour) * width / 100, y: 14)
  }

  private func nowIndicator(width: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: 1, style: .continuous)
      .fill(Color.primary.opacity(0.6))
      .frame(width: 2, height: 22)
      .position(x: pct(nowHour) * width / 100, y: 14)
  }

  private var axisLabels: some View {
    GeometryReader { geo in
      // Same sanitization as the main timeline GeometryReader — a NaN
      // width here positions every hour label at NaN, which CoreGraphics
      // rejects with the same log-spam.
      let rawW = geo.size.width
      let w: CGFloat = (rawW.isFinite && rawW > 0) ? rawW : 0
      ZStack(alignment: .leading) {
        ForEach(hourMarks(width: w), id: \.self) { h in
          Text("\(h)")
            .scaledFont(size: 9)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .position(x: pct(Double(h)) * w / 100, y: 6)
        }
      }
    }
    .frame(height: 12)
  }

  // MARK: - Window (wake → ideal bedtime, clipped to today's actual extent)

  private var wakeHour: Double? {
    oura?.wakeTime.flatMap(parseHHMM)
  }

  /// Use the Oura wake_time as a hint; bedtime hour comes from Oura's own
  /// bedtime when present. Skipping the 14-night median for v1.
  private var moonHour: Double? {
    if let bt = oura?.bedtime, let h = parseHHMM(bt) { return h }
    return nil
  }

  private var windowStart: Double {
    max(0, (wakeHour ?? 6) - 0.5)
  }

  private var windowEnd: Double {
    let latest: Double = {
      var values: [Double] = []
      if let m = moonHour { values.append(m + 0.5) }
      if isToday { values.append(nowHour + 0.5) }
      values.append(latestEventHour + 0.5)
      values.append(20)
      return values.max() ?? 24
    }()
    return min(24, latest)
  }

  private var windowSpan: Double { max(1, windowEnd - windowStart) }
  private func pct(_ hour: Double) -> Double {
    ((hour - windowStart) / windowSpan) * 100
  }

  private var nowHour: Double {
    let cal = Calendar.current
    let comps = cal.dateComponents([.hour, .minute], from: clock.now)
    return Double(comps.hour ?? 0) + Double(comps.minute ?? 0) / 60
  }

  /// Step size (in hours) for tick marks and axis labels given available pixels.
  /// ~18px per label comfortably fits "12"; halve the step as space opens up.
  private func labelStep(width: CGFloat) -> Int {
    let pxPerHour = width / CGFloat(max(1, windowSpan))
    if pxPerHour >= 18 { return 1 }
    if pxPerHour >= 9  { return 2 }
    if pxPerHour >= 5  { return 3 }
    return 6
  }

  /// Hours within the visible window at the appropriate step for this width.
  private func hourMarks(width: CGFloat) -> [Int] {
    let step = labelStep(width: width)
    let start = Int(windowStart.rounded(.up))
    let end   = Int(windowEnd.rounded(.down))
    guard end > start else { return [] }
    // Snap start up to the nearest multiple of step so labels land on even
    // hours (e.g. step=2 → 8,10,12 not 7,9,11).
    let snapped = start % step == 0 ? start : start + (step - start % step)
    return stride(from: snapped, through: end, by: step)
      .filter { Double($0) > windowStart + 0.2 && Double($0) < windowEnd - 0.2 }
      .map { $0 }
  }

  // MARK: - Events → dots / bars / clusters

  private struct Cluster {
    var hour: Double
    var color: Color
    var count: Int
  }

  private struct Bar {
    var startHour: Double
    var endHour: Double
    var color: Color
    var thin: Bool
  }

  private var latestEventHour: Double {
    var values: [Double] = []
    for e in caffeine    { if let h = parseHHMM(e.time) { values.append(h) } }
    for e in cannabis    { if let h = parseHHMM(e.time) { values.append(h) } }
    for e in nutrition where e.date == date { if let h = parseHHMM(e.time) { values.append(h) } }
    for e in gut         { if let h = parseHHMM(e.time) { values.append(h) } }
    for e in mood        { if let h = parseHHMM(String(e.time.prefix(5))) { values.append(h) } }
    for e in habits where e.done {
      if let t = e.time, let h = parseHHMM(t) { values.append(h) }
    }
    for e in supplements where e.done {
      if let t = e.time, let h = parseHHMM(t) { values.append(h) }
    }
    for c in chores where c.lastCompleted == date {
      if let t = c.lastCompletedTime, let h = parseHHMM(t) { values.append(h) }
    }
    for s in trainingSessions { values.append(s.endHour) }
    for b in calendarBars { values.append(b.endHour) }
    return values.max() ?? 0
  }

  /// Group exercise entries by (date + session) into start/end pairs.
  /// Start = earliest concluded_at, end = latest logged_at or
  /// start + cardio duration when logged_at is missing.
  private struct SessionAccum {
    var startHour: Double
    var totalDuration: Double = 0
    var lastLoggedHour: Double? = nil
  }

  private var trainingSessions: [Bar] {
    var byKey: [String: SessionAccum] = [:]
    for e in training where e.date == date {
      guard let concluded = e.concludedAt else { continue }
      // concludedAt is like "2026-05-17T07:42:11" — slice HH:MM.
      let startHHMM = String(concluded.dropFirst(11).prefix(5))
      guard let startH = parseHHMM(startHHMM) else { continue }
      let loggedHHMM = e.loggedAt.map { String($0.dropFirst(11).prefix(5)) }
      let loggedH = loggedHHMM.flatMap(parseHHMM)
      var s = byKey[startHHMM] ?? SessionAccum(startHour: startH)
      s.totalDuration += e.durationMin ?? 0
      if let lh = loggedH, lh > (s.lastLoggedHour ?? 0) { s.lastLoggedHour = lh }
      byKey[startHHMM] = s
    }
    let trainingColor = theme.color(for: "training")
    return byKey.values.map { s in
      let cardioEnd = s.totalDuration > 0 ? s.startHour + s.totalDuration / 60 : s.startHour
      let end = max(s.lastLoggedHour ?? s.startHour, cardioEnd)
      return Bar(startHour: s.startHour,
                 endHour: max(end, s.startHour + 0.05),
                 color: trainingColor,
                 thin: false)
    }
  }

  /// Calendar events that overlap `date`, rendered as thin pills from
  /// start → end. All-day events (no real time-of-day) are skipped — they
  /// would span the entire rail and drown out everything else.
  private var calendarBars: [Bar] {
    let cal = Foundation.Calendar.current
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
    guard let dayStart = fmt.date(from: date),
          let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
    let fallbackColor = theme.color(for: "calendar")
    var out: [Bar] = []
    for e in calendar {
      if e.isAllDay { continue }
      // Clamp the event to today's bounds so a meeting that crosses
      // midnight still renders correctly on each day it touches.
      let s = max(e.startDate, dayStart)
      let f = min(e.endDate, dayEnd)
      guard f > s else { continue }
      let startH = hourOfDay(s, in: cal, dayStart: dayStart)
      let endH = hourOfDay(f, in: cal, dayStart: dayStart)
      guard endH > startH else { continue }
      let eventColor = e.calendar?.cgColor.map { Color($0) } ?? fallbackColor
      out.append(Bar(startHour: startH, endHour: endH, color: eventColor, thin: true))
    }
    return out
  }

  private func hourOfDay(_ d: Date, in cal: Foundation.Calendar, dayStart: Date) -> Double {
    let secs = d.timeIntervalSince(dayStart)
    return max(0, min(24, secs / 3600))
  }

  private var bars: [Bar] { trainingSessions + calendarBars }

  private var clusters: [Cluster] {
    // (color, ~10-min bucket) keys collapse adjacent same-section events.
    var byKey: [String: Cluster] = [:]
    func add(_ hour: Double, color: Color) {
      let key = "\(color.description):\(Int((hour * 6).rounded()))"
      if let existing = byKey[key] {
        let n = existing.count + 1
        let h = (existing.hour * Double(existing.count) + hour) / Double(n)
        byKey[key] = Cluster(hour: h, color: color, count: n)
      } else {
        byKey[key] = Cluster(hour: hour, color: color, count: 1)
      }
    }

    let cN = theme.color(for: "nutrition")
    let cC = theme.color(for: "caffeine")
    let cZ = theme.color(for: "cannabis")
    let cG = theme.color(for: "gut")
    let cH = theme.color(for: "habits")
    let cS = theme.color(for: "supplements")
    let cR = theme.color(for: "chores")

    for e in nutrition where e.date == date {
      if let h = parseHHMM(e.time) { add(h, color: cN) }
    }
    for e in caffeine {
      if let h = parseHHMM(e.time) { add(h, color: cC) }
    }
    for e in cannabis {
      if let h = parseHHMM(e.time) { add(h, color: cZ) }
    }
    for e in gut {
      if let h = parseHHMM(e.time) { add(h, color: cG) }
    }
    // Mood dots — colored by quadrant rather than a single section
    // accent, so the timeline reads the affective valence at a glance
    // (yellow morning + blue evening = a real signal).
    for e in mood {
      if let h = parseHHMM(String(e.time.prefix(5))) {
        let color = MoodQuadrant(rawValue: e.quadrant)?.color ?? .gray
        add(h, color: color)
      }
    }
    for h_ in habits where h_.done {
      if let t = h_.time, let hh = parseHHMM(t) { add(hh, color: cH) }
    }
    for s in supplements where s.done {
      if let t = s.time, let hh = parseHHMM(t) { add(hh, color: cS) }
    }
    let cT = theme.color(for: "tasks")
    for t in tasks where t.status == .done {
      guard let ts = t.completedAt, ts.hasPrefix(date), ts.count >= 16 else { continue }
      let hhmm = String(ts.dropFirst(11).prefix(5))
      if let h = parseHHMM(hhmm) { add(h, color: cT) }
    }
    // Chores — dot at last_completed_time for each chore checked off
    // today. Matches web's today-timeline keying on `last_completed_time`.
    for c in chores where c.lastCompleted == date {
      if let t = c.lastCompletedTime, let h = parseHHMM(t) { add(h, color: cR) }
    }
    return Array(byKey.values).sorted { $0.hour < $1.hour }
  }

  // MARK: - Helpers

  /// "HH:MM" → fractional hour. Returns nil on malformed input.
  private func parseHHMM(_ s: String) -> Double? {
    let parts = s.split(separator: ":")
    guard parts.count == 2,
          let h = Double(parts[0]),
          let m = Double(parts[1]) else { return nil }
    return h + m / 60
  }
}
