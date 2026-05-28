import SwiftUI

// GitHub-style contribution heatmap, ported from the webapp's
// `ContributionGrid` + `ChecklistConsistencyGrid`. Each column is a week
// (Mon→Sun), each cell a day, color ramp derived from a section accent.
//
// Used in destination views to show "past weeks of progress" at a glance.
// Driver: a closure that maps an ISO date to a 0…4 level + optional count.

struct HeatmapDay {
  /// 0 = empty, 1…4 = increasing intensity along the accent ramp.
  let level: Int
  /// Tooltip-style label for accessibility / future hover overlays.
  let label: String
}

struct ConsistencyHeatmap: View {
  let endDate: Date
  /// Earliest date with data. Determines the left edge column (snapped to
  /// the Monday of that week); the heatmap renders fewer columns when data
  /// is younger than the viewport. Pass `nil` to fill the whole viewport.
  let firstDataDate: Date?
  let accent: Color
  let getDay: (String) -> HeatmapDay
  /// Optional tap handler — receives the ISO date of the cell tapped.
  /// When non-nil, cells within `tappableWindowDays` of `endDate` become
  /// `Button`s; older cells stay visually identical but inert. The
  /// caller drives the backfill sheet from this callback.
  var onTap: ((String) -> Void)? = nil
  /// How far back (inclusive) `onTap` fires. Defaults to 30 — matches the
  /// scope chosen for event-stamped edit sheets.
  var tappableWindowDays: Int = 30

  private let cell: CGFloat = 12
  private let gap: CGFloat = 3

  /// When the user has "Differentiate Without Color" enabled, we overlay
  /// small dot glyphs whose count tracks the intensity level — so the
  /// information the opacity ramp encodes for sighted users is still
  /// available without relying on color.
  @Environment(\.accessibilityDifferentiateWithoutColor)
  private var differentiateWithoutColor

  var body: some View {
    GeometryReader { geo in
      // Guard against non-finite proposed width — SwiftUI can pass NaN
      // during transient layout passes (sheet animations, container
      // size hand-offs). `Int(floor(.nan))` is undefined behaviour and
      // would either trap or produce a negative count that propagates
      // into a negative-frame CoreGraphics warning. Falling back to 1
      // week renders a single column harmlessly until the next pass.
      let proposedWidth = geo.size.width
      let weeksThatFit: Int = {
        guard proposedWidth.isFinite, proposedWidth > 0 else { return 1 }
        return max(1, Int(floor((proposedWidth + gap) / (cell + gap))))
      }()
      let weeks = Self.weekColumns(
        endDate: endDate,
        firstDataDate: firstDataDate,
        maxWeeks: weeksThatFit
      )
      HStack(alignment: .top, spacing: gap) {
        ForEach(weeks.indices, id: \.self) { i in
          VStack(spacing: gap) {
            ForEach(0..<7, id: \.self) { row in
              cellView(date: weeks[i][row])
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .frame(height: 7 * cell + 6 * gap)
  }

  @ViewBuilder
  private func cellView(date: Date?) -> some View {
    if let date = date, date <= endDate {
      let iso = Self.iso(date)
      let day = getDay(iso)
      let cellBody = ZStack {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
          .fill(color(for: day.level))
        if differentiateWithoutColor && day.level > 0 {
          levelGlyph(for: day.level)
        }
      }
      .frame(width: cell, height: cell)

      if let onTap, Self.isWithinTappableWindow(date: date,
                                                endDate: endDate,
                                                windowDays: tappableWindowDays) {
        // Wrapping in a Button keeps the tap target the size of the cell
        // (12pt — small but matches the heatmap's grain). `.plain` style
        // strips the default tint so the color ramp stays untouched.
        Button { onTap(iso) } label: { cellBody }
          .buttonStyle(.plain)
          .accessibilityLabel(day.label)
          .accessibilityValue(Self.levelDescription(for: day.level))
          .accessibilityAddTraits(.isButton)
      } else {
        cellBody
          .accessibilityLabel(day.label)
          .accessibilityValue(Self.levelDescription(for: day.level))
      }
    } else {
      Color.clear.frame(width: cell, height: cell)
    }
  }

  /// `date` is within `windowDays` days of `endDate` (inclusive of both
  /// endpoints) — i.e. today and the previous N-1 days are tappable.
  private static func isWithinTappableWindow(date: Date,
                                             endDate: Date,
                                             windowDays: Int) -> Bool {
    let cal = Calendar.current
    let days = cal.dateComponents([.day],
                                  from: cal.startOfDay(for: date),
                                  to: cal.startOfDay(for: endDate)).day ?? Int.max
    return days >= 0 && days < windowDays
  }

  /// Five-stop ramp matching the webapp: muted → faint accent → full accent.
  private func color(for level: Int) -> Color {
    switch max(0, min(level, 4)) {
    case 0: return Color.secondary.opacity(0.15)
    case 1: return accent.opacity(0.25)
    case 2: return accent.opacity(0.45)
    case 3: return accent.opacity(0.70)
    default: return accent
    }
  }

  /// Dot row rendered at the bottom of each non-empty cell when the user
  /// has Differentiate Without Color on. Dot count = level (1…4) so the
  /// signal mirrors the opacity ramp. White fill with a hairline stroke
  /// keeps the glyphs legible on every accent at every intensity.
  @ViewBuilder
  private func levelGlyph(for level: Int) -> some View {
    VStack(spacing: 0) {
      Spacer(minLength: 0)
      HStack(spacing: 1) {
        ForEach(0..<min(level, 4), id: \.self) { _ in
          Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 0.3))
            .frame(width: 1.5, height: 1.5)
        }
      }
      .padding(.bottom, 2)
    }
  }

  /// VoiceOver value for a cell. Read after the date/count label, so a full
  /// announcement reads like "January 15, 3 of 5 habits, high".
  static func levelDescription(for level: Int) -> String {
    switch max(0, min(level, 4)) {
    case 0: return "none"
    case 1: return "low"
    case 2: return "moderate"
    case 3: return "high"
    default: return "full"
    }
  }

  // MARK: - Week columns (Mon-start, like the webapp)

  /// Builds a column-major matrix of [week][weekday] dates that ends on the
  /// week containing `endDate`, with up to `maxWeeks` columns. The left edge
  /// is the Monday of the week containing `firstDataDate` (or the viewport
  /// boundary when `firstDataDate` is nil). Only cells past `endDate` are
  /// nil; the leftmost column is always a full Mon→Sun so there's no gap.
  private static func weekColumns(
    endDate: Date,
    firstDataDate: Date?,
    maxWeeks: Int
  ) -> [[Date?]] {
    var cal = Calendar(identifier: .iso8601)
    cal.firstWeekday = 2 // Monday
    let lastMonday = mondayOfWeek(for: endDate, calendar: cal)
    let lastSunday = cal.date(byAdding: .day, value: 6, to: lastMonday)!
    // Viewport's earliest Monday given how many weeks fit on screen.
    let viewportFirstMonday = cal.date(byAdding: .weekOfYear,
                                       value: -(maxWeeks - 1),
                                       to: lastMonday)!
    // If we have a known first-data date, clamp forward so we don't render
    // empty pre-data columns. Otherwise just respect the viewport.
    let firstMonday: Date = {
      guard let first = firstDataDate else { return viewportFirstMonday }
      let dataMonday = mondayOfWeek(for: first, calendar: cal)
      return max(viewportFirstMonday, dataMonday)
    }()
    var columns: [[Date?]] = []
    var cursor = firstMonday
    while cursor <= lastSunday {
      var week: [Date?] = []
      for offset in 0..<7 {
        let d = cal.date(byAdding: .day, value: offset, to: cursor)!
        // Only hide cells that are past endDate (right-side partial week).
        // Left-side cells before firstDataDate are passed through so the
        // first column is always a complete Mon→Sun — getDay returns level 0
        // for those days, matching the visual weight of any other empty cell.
        week.append(d > endDate ? nil : d)
      }
      columns.append(week)
      cursor = cal.date(byAdding: .day, value: 7, to: cursor)!
    }
    return columns
  }

  private static func mondayOfWeek(for date: Date, calendar: Calendar) -> Date {
    let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
    return calendar.date(from: comps) ?? date
  }

  static func iso(_ date: Date) -> String {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .iso8601)
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
  }

  static func date(fromISO iso: String) -> Date? {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .iso8601)
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd"
    return f.date(from: iso)
  }
}

// MARK: - Checklist-style wrapper (habits / supplements / chores)

/// Renders the heatmap inside a destination view as a list section,
/// mirroring the webapp's "<noun> consistency" card: header with percent,
/// the grid, then current/best streak tiles.
struct ChecklistHeatmapSection<Point>: View where Point: Hashable {
  let title: String
  let noun: String
  let accent: Color
  let daily: [Point]
  let date: (Point) -> String
  let done: (Point) -> Int
  let total: (Point) -> Int
  /// Forwarded to the underlying heatmap. Non-nil enables the backfill
  /// flow: tapping a cell within the last 30 days fires this with the
  /// ISO date.
  var onTapDay: ((String) -> Void)? = nil

  var body: some View {
    let end = Date()
    let endISO = ConsistencyHeatmap.iso(end)
    let first = earliestDataDate()
    let stats = computeStats(endISO: endISO, firstDate: first)
    let pct = stats.totalDays > 0
      ? Int((Double(stats.activeDays) / Double(stats.totalDays) * 100).rounded())
      : 0

    DrawerSection {
      VStack(alignment: .leading, spacing: 14) {
        header(activeDays: stats.activeDays, totalDays: stats.totalDays)
        ConsistencyHeatmap(
          endDate: end,
          firstDataDate: first,
          accent: accent,
          getDay: { iso in
            let bucket = stats.byDate[iso]
            let d = bucket?.done ?? 0
            let t = bucket?.total ?? 0
            let level = Self.level(done: d, total: t)
            let label = t > 0 ? "\(iso) · \(d)/\(t) \(noun)s" : "\(iso) · no \(noun)s"
            return HeatmapDay(level: level, label: label)
          },
          onTap: onTapDay
        )
        .a11yCombineKeepingChildren(
          "\(title) heatmap, \(stats.activeDays) of \(stats.totalDays) days active, \(pct) percent. Current streak \(stats.currentStreak) days, best run \(stats.longestStreak)."
        )
        footer(totalDone: stats.totalDone, endISO: endISO)
        streakRow(current: stats.currentStreak, best: stats.longestStreak)
      }
    }
  }

  /// Earliest date we actually have data for. Drives the heatmap's start
  /// edge: with three weeks of data we render three columns, not 16 mostly
  /// empty ones. Falls back to `nil` (= fill viewport) for empty data.
  private func earliestDataDate() -> Date? {
    daily.compactMap { ConsistencyHeatmap.date(fromISO: date($0)) }.min()
  }

  private func header(activeDays: Int, totalDays: Int) -> some View {
    let pct = totalDays > 0 ? Int((Double(activeDays) / Double(totalDays) * 100).rounded()) : 0
    return HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.system(.subheadline, design: .rounded).weight(.semibold))
        Text("\(activeDays) of \(totalDays) days active")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 2) {
        Text("\(pct)%")
          .font(.system(.title2, design: .rounded).weight(.semibold))
          .foregroundStyle(accent)
        Text("days active")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func footer(totalDone: Int, endISO: String) -> some View {
    HStack {
      Text("\(totalDone) \(noun)s")
        .font(.caption)
        .foregroundStyle(accent.opacity(0.85))
        .monospacedDigit()
      Spacer()
      Text("today")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func streakRow(current: Int, best: Int) -> some View {
    HStack(spacing: 8) {
      streakTile(label: "CURRENT STREAK", value: "\(current) days", emphasized: false)
      streakTile(label: "BEST RUN", value: "\(best) days", emphasized: true)
    }
  }

  private func streakTile(label: String, value: String, emphasized: Bool) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label)
        .font(.system(.caption2, design: .rounded).weight(.semibold))
        .tracking(1.2)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(.body, design: .rounded).weight(.semibold))
        .foregroundStyle(emphasized ? accent : .primary)
        .monospacedDigit()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 8)
    .padding(.horizontal, 12)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
    )
  }

  // MARK: - Stats

  private struct Stats {
    var byDate: [String: (done: Int, total: Int)] = [:]
    var activeDays = 0
    var totalDays = 0
    var totalDone = 0
    var currentStreak = 0
    var longestStreak = 0
  }

  private func computeStats(endISO: String, firstDate: Date?) -> Stats {
    var s = Stats()
    for p in daily {
      s.byDate[date(p)] = (done(p), total(p))
    }
    guard let endDate = ConsistencyHeatmap.date(fromISO: endISO),
          let startDate = firstDate
    else { return s }
    let cal = Calendar(identifier: .iso8601)
    let dayCount = max(1, (cal.dateComponents([.day], from: startDate, to: endDate).day ?? 0) + 1)
    var best = 0, run = 0
    for i in 0..<dayCount {
      guard let d = cal.date(byAdding: .day, value: i, to: startDate) else { continue }
      let iso = ConsistencyHeatmap.iso(d)
      s.totalDays += 1
      let bucket = s.byDate[iso]
      let dn = bucket?.done ?? 0
      s.totalDone += dn
      if dn > 0 {
        s.activeDays += 1
        run += 1
        best = max(best, run)
      } else {
        run = 0
      }
    }
    s.longestStreak = best
    // Current streak — walk back from today, allow yesterday-start.
    var curr = 0
    var cursor = endDate
    if (s.byDate[ConsistencyHeatmap.iso(cursor)]?.done ?? 0) == 0,
       let prev = cal.date(byAdding: .day, value: -1, to: cursor) {
      cursor = prev
    }
    while (s.byDate[ConsistencyHeatmap.iso(cursor)]?.done ?? 0) > 0 {
      curr += 1
      guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
      cursor = prev
    }
    s.currentStreak = curr
    return s
  }

  private static func level(done: Int, total: Int) -> Int {
    guard total > 0 else { return 0 }
    let r = Double(done) / Double(total)
    if r >= 1 { return 4 }
    if r >= 0.75 { return 3 }
    if r >= 0.5 { return 2 }
    if r > 0 { return 1 }
    return 0
  }
}

// MARK: - Activity-style wrapper (count or score per day)

/// Generic heatmap section for sources without a done/total denominator —
/// e.g. caffeine sessions, gut movements, sleep score. Caller supplies a
/// `levelFor` that maps the raw daily value to a 0…4 ramp slot and a
/// `labelFor` for the per-cell accessibility text.
struct ActivityHeatmapSection<Point>: View where Point: Hashable {
  let title: String
  let accent: Color
  let daily: [Point]
  let date: (Point) -> String
  /// Raw daily value (count, score, etc).
  let value: (Point) -> Double
  /// Map value → 0…4 (0 = empty).
  let levelFor: (Double) -> Int
  /// Cell tooltip / a11y label (e.g. "1 session").
  let labelFor: (Double) -> String
  /// Section subtitle, given (activeDays, totalDays, totalValue).
  let subtitleFor: (Int, Int, Double) -> String
  /// Optional: tapping a cell within the last 30 days fires this with the
  /// cell's ISO date. Used by event-stamped sections to open a per-day
  /// browse sheet for recovery / correction. Empty cells are tappable too
  /// — sometimes you've sent an entry to a quiet day and need to find it.
  var onTapDay: ((String) -> Void)? = nil

  var body: some View {
    let end = Date()
    let first = daily.compactMap { ConsistencyHeatmap.date(fromISO: date($0)) }.min()
    let byDate: [String: Double] = Dictionary(uniqueKeysWithValues: daily.map { (date($0), value($0)) })
    let activeDays = byDate.values.filter { $0 > 0 }.count
    let totalValue = byDate.values.reduce(0, +)
    let totalDays = totalDays(from: first, to: end)

    DrawerSection {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 2) {
            Text(title)
              .font(.system(.subheadline, design: .rounded).weight(.semibold))
            Text(subtitleFor(activeDays, totalDays, totalValue))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
        }
        ConsistencyHeatmap(
          endDate: end,
          firstDataDate: first,
          accent: accent,
          getDay: { iso in
            let v = byDate[iso] ?? 0
            let level = v > 0 ? levelFor(v) : 0
            let label = v > 0 ? "\(iso) · \(labelFor(v))" : "\(iso) · —"
            return HeatmapDay(level: level, label: label)
          },
          onTap: onTapDay
        )
        .a11yCombineKeepingChildren(
          "\(title) heatmap. \(subtitleFor(activeDays, totalDays, totalValue))"
        )
      }
    }
  }

  private func totalDays(from first: Date?, to end: Date) -> Int {
    guard let first else { return 0 }
    let cal = Calendar(identifier: .iso8601)
    return max(1, (cal.dateComponents([.day], from: first, to: end).day ?? 0) + 1)
  }
}
