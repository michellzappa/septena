import SwiftUI
import SwiftData

// Per-item detail for a habit or supplement. Tapping the row body opens this
// (the checkbox still checks off). The intelligence is consistency: current +
// best streak, a 30-day completion rate, and a GitHub-style consistency
// heatmap — all derived at read time from the item's dated `done` rows (via
// the `fetch` closure, backed by `ChecklistMirror.habit/supplementCompletionDates`).
//
// This is now a thin builder over the shared `LogDetailScaffold` so habits,
// supplements, chores and training exercises all render the same surface.

struct LoggableDetailView: View {
  let title: String
  let emoji: String?
  let accent: Color
  /// Past-tense verb for the count line — "done" (habits) / "taken"
  /// (supplements). Yields "Done 12 days" / "Taken 12 days".
  let doneVerb: String
  /// Loads this item's completion dates (YYYY-MM-DD, ascending) from a context.
  let fetch: (ModelContext) -> [String]
  /// Optional loader for explicitly *skipped* dates (habits only). When
  /// present, skips appear in the recent list (as "Skipped") and as a faint
  /// level in the heatmap. nil for supplements, which have no skip state.
  var skippedFetch: ((ModelContext) -> [String])? = nil
  /// Routes the toolbar "Edit" to the parent's existing edit sheet.
  let onEdit: () -> Void

  var body: some View {
    LogDetailScaffold(
      title: title,
      accent: accent,
      load: { ctx in
        Self.detail(dates: fetch(ctx),
                    skipped: skippedFetch?(ctx) ?? [],
                    emoji: emoji,
                    doneVerb: doneVerb)
      },
      onEdit: onEdit
    )
  }

  /// Build the shared `LogDetail` from a habit/supplement's done + skipped
  /// dates. Streak / rate stats count dones only; the recent list and heatmap
  /// surface skips alongside them.
  static func detail(dates: [String], skipped: [String] = [],
                     emoji: String?, doneVerb: String) -> LogDetail {
    let stats = ConsistencyStats.make(dates: dates)
    var d = LogDetail()
    d.emoji = emoji
    d.subtitle = stats.totalCount == 0
      ? "No history yet"
      : "\(doneVerb.capitalized) \(stats.totalCount) \(stats.totalCount == 1 ? "day" : "days")"
    d.tiles = [
      LogStat(value: "\(stats.currentStreak)", caption: "day streak",
              tone: stats.currentStreak > 0 ? .accent : .normal),
      LogStat(value: "\(stats.bestStreak)", caption: "best streak"),
      LogStat(value: "\(stats.last30Percent)%", caption: "last 30 days"),
    ]

    let done = Set(dates), skips = Set(skipped)
    let allDates = dates + skipped

    if !allDates.isEmpty {
      d.heatmap = LogHeatmap(
        firstDate: LogDetailFormat.firstDate(allDates),
        level: { iso in done.contains(iso) ? 4 : (skips.contains(iso) ? 1 : 0) }
      )
    }

    // Recent is a continuous day-by-day timeline (not just the days it
    // happened) so the *gaps* are visible — each day reads done / skipped /
    // missed. Clamped to start no earlier than the first recorded day, so days
    // before the item had any history don't read as false misses.
    d.recent = recentTimeline(done: done, skipped: skips)
    return d
  }

  /// Last ~14 days, today first, each marked done/skipped/missed. Stops at the
  /// earliest recorded day so pre-history days aren't shown as missed.
  private static func recentTimeline(done: Set<String>, skipped: Set<String>,
                                     window: Int = 14) -> [LogRecent] {
    let cal = Calendar.current
    guard let today = SeptenaDate.parse(SeptenaDate.today),
          let todayOrd = cal.ordinality(of: .day, in: .era, for: today) else { return [] }
    let firstOrd = (done.union(skipped))
      .compactMap { SeptenaDate.parse($0).flatMap { cal.ordinality(of: .day, in: .era, for: $0) } }
      .min()
    guard let firstOrd else { return [] }
    let lowerBound = max(todayOrd - (window - 1), firstOrd)

    var rows: [LogRecent] = []
    var offset = 0
    while todayOrd - offset >= lowerBound {
      guard let date = cal.date(byAdding: .day, value: -offset, to: today),
            let iso = SeptenaDate.format(date) else { break }
      let status: LogRecent.Status = done.contains(iso) ? .done
        : skipped.contains(iso) ? .skipped : .missed
      let label: String? = status == .done ? "Done" : status == .skipped ? "Skipped" : "Missed"
      rows.append(LogRecent(title: LogDetailFormat.longDay(iso),
                            detail: label,
                            trailing: LogDetailFormat.relativeDay(iso),
                            status: status))
      offset += 1
    }
    return rows
  }
}

// ConsistencyStats moved to SeptenaCore/ConsistencyStats.swift so the
// milestone detectors share the same streak definition.
