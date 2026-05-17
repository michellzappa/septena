import SwiftUI

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
  var habits: [HabitDayItem] = []
  var supplements: [SupplementDayItem] = []
  var chores: [ChoreItem] = []
  var training: [ExerciseEntry] = []
  var tasks: [SeptenaTask] = []

  @Environment(SectionTheme.self) private var theme

  private var isToday: Bool { date == SeptenaDate.today }

  // MARK: - Body

  var body: some View {
    VStack(spacing: 4) {
      header
      GeometryReader { geo in
        let w = geo.size.width
        ZStack(alignment: .leading) {
          rail
          sleepShade(width: w)
          ticks(width: w)
          ForEach(Array(bars.enumerated()), id: \.offset) { _, b in
            barPill(b, width: w)
          }
          ForEach(Array(clusters.enumerated()), id: \.offset) { _, c in
            dot(c, width: w)
          }
          if let wake = wakeHour { marker("☀️", at: wake, width: w) }
          if let moon = moonHour, moon < 24 { marker("🌙", at: moon, width: w, opacity: 0.7) }
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
    if let moon = moonHour, moon < 24, !(isToday && nowHour >= moon) {
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(Color.primary.opacity(0.06))
        .frame(width: max(0, (100 - pct(moon)) * width / 100), height: 18)
        .frame(maxHeight: .infinity)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
  }

  private func ticks(width: CGFloat) -> some View {
    ForEach(tickHours, id: \.self) { h in
      Rectangle()
        .fill(Color.primary.opacity(0.08))
        .frame(width: 1, height: 10)
        .position(x: pct(Double(h)) * width / 100, y: 14)
    }
  }

  private func barPill(_ b: Bar, width: CGFloat) -> some View {
    let x = pct(b.startHour) * width / 100
    let w = max(8, pct(b.endHour - b.startHour + windowStart) * width / 100)
    return RoundedRectangle(cornerRadius: 3, style: .continuous)
      .fill(b.color)
      .frame(width: w, height: b.thin ? 4 : 8)
      .frame(maxHeight: .infinity)
      .position(x: x + w / 2, y: 14)
  }

  private func dot(_ c: Cluster, width: CGFloat) -> some View {
    let size = min(CGFloat(14), CGFloat(6 + (c.count - 1) * 2))
    return Circle()
      .fill(c.color)
      .overlay(Circle().stroke(Theme.paperBackground, lineWidth: 1))
      .frame(width: size, height: size)
      .position(x: pct(c.hour) * width / 100, y: 14)
  }

  private func marker(_ glyph: String, at hour: Double, width: CGFloat,
                      opacity: Double = 1) -> some View {
    Text(glyph)
      .font(.system(size: 11))
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
      ZStack(alignment: .leading) {
        ForEach(axisHours, id: \.self) { h in
          Text("\(h)")
            .font(.system(size: 9))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .position(x: pct(Double(h)) * geo.size.width / 100, y: 6)
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
    let comps = cal.dateComponents([.hour, .minute], from: Date())
    return Double(comps.hour ?? 0) + Double(comps.minute ?? 0) / 60
  }

  private var tickHours: [Int] {
    [6, 9, 12, 15, 18, 21].filter {
      Double($0) > windowStart + 0.5 && Double($0) < windowEnd - 0.5
    }
  }

  /// Sparse hour labels under the rail — start, mid, end.
  private var axisHours: [Int] {
    let start = Int(windowStart.rounded(.up))
    let end = Int(windowEnd.rounded(.down))
    if end - start <= 0 { return [] }
    var ticks: [Int] = [start]
    let mid = (start + end) / 2
    if mid != start && mid != end { ticks.append(mid) }
    ticks.append(end)
    return ticks
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
    for e in habits where e.done {
      if let t = e.time, let h = parseHHMM(t) { values.append(h) }
    }
    for e in supplements where e.done {
      if let t = e.time, let h = parseHHMM(t) { values.append(h) }
    }
    for s in trainingSessions { values.append(s.endHour) }
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

  /// Duration bars (training only for now — calendar pills could join later).
  private var bars: [Bar] { trainingSessions }

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
    // Chores don't have a per-completion timestamp on ChoreItem yet;
    // they're skipped here. Calendar pills also TBD.
    _ = chores
    _ = cR
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
