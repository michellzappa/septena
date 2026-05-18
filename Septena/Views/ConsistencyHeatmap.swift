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
  let days: Int
  let endDate: Date
  let accent: Color
  let getDay: (String) -> HeatmapDay

  private let cell: CGFloat = 12
  private let gap: CGFloat = 3

  var body: some View {
    let weeks = Self.weekColumns(endDate: endDate, days: days)
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

  @ViewBuilder
  private func cellView(date: Date?) -> some View {
    if let date = date, date <= endDate {
      let iso = Self.iso(date)
      let day = getDay(iso)
      RoundedRectangle(cornerRadius: 2.5, style: .continuous)
        .fill(color(for: day.level))
        .frame(width: cell, height: cell)
        .accessibilityLabel(day.label)
    } else {
      Color.clear.frame(width: cell, height: cell)
    }
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

  // MARK: - Week columns (Mon-start, like the webapp)

  /// Builds a column-major matrix of [week][weekday] dates that ends on the
  /// week containing `endDate`. Missing slots before the window start /
  /// after `endDate` are `nil` so the grid stays rectangular.
  private static func weekColumns(endDate: Date, days: Int) -> [[Date?]] {
    var cal = Calendar(identifier: .iso8601)
    cal.firstWeekday = 2 // Monday
    let startDate = cal.date(byAdding: .day, value: -(days - 1), to: endDate) ?? endDate
    // Snap start to its week's Monday, end to its week's Sunday.
    let firstMonday = mondayOfWeek(for: startDate, calendar: cal)
    let lastSunday = cal.date(byAdding: .day, value: 6, to: mondayOfWeek(for: endDate, calendar: cal))!

    var columns: [[Date?]] = []
    var cursor = firstMonday
    while cursor <= lastSunday {
      var week: [Date?] = []
      for offset in 0..<7 {
        let d = cal.date(byAdding: .day, value: offset, to: cursor)!
        if d < startDate || d > endDate {
          week.append(nil)
        } else {
          week.append(d)
        }
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
  var days: Int = 112

  var body: some View {
    let end = Date()
    let endISO = ConsistencyHeatmap.iso(end)
    let stats = computeStats(endISO: endISO)

    Section {
      VStack(alignment: .leading, spacing: 14) {
        header(activeDays: stats.activeDays, totalDays: stats.totalDays)
        ConsistencyHeatmap(days: days, endDate: end, accent: accent) { iso in
          let bucket = stats.byDate[iso]
          let d = bucket?.done ?? 0
          let t = bucket?.total ?? 0
          let level = Self.level(done: d, total: t)
          let label = t > 0 ? "\(iso) · \(d)/\(t) \(noun)s" : "\(iso) · no \(noun)s"
          return HeatmapDay(level: level, label: label)
        }
        footer(totalDone: stats.totalDone, endISO: endISO)
        streakRow(current: stats.currentStreak, best: stats.longestStreak)
      }
      .padding(.vertical, 4)
    }
  }

  private func header(activeDays: Int, totalDays: Int) -> some View {
    let pct = totalDays > 0 ? Int((Double(activeDays) / Double(totalDays) * 100).rounded()) : 0
    let months = Int((Double(days) / 30).rounded())
    return HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.system(.subheadline, design: .rounded).weight(.semibold))
        Text("\(activeDays) active days over the last \(months) months")
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

  private func computeStats(endISO: String) -> Stats {
    var s = Stats()
    for p in daily {
      s.byDate[date(p)] = (done(p), total(p))
    }
    guard let endDate = ConsistencyHeatmap.date(fromISO: endISO) else { return s }
    let cal = Calendar(identifier: .iso8601)
    var best = 0, run = 0
    for i in 0..<days {
      guard let d = cal.date(byAdding: .day, value: -(days - 1 - i), to: endDate) else { continue }
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
