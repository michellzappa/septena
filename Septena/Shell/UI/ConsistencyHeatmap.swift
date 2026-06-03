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
