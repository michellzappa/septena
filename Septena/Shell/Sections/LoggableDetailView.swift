import SwiftUI
import SwiftData

// Read-only "infobox" for a single habit or supplement — reached by tapping
// the row body (the checkbox still checks it off). Mirrors the chore detail
// view's chrome and presentation, but the intelligence here is consistency,
// not cadence: current + best streak, a 30-day completion rate, and a
// five-week consistency grid. Everything is DERIVED at read time from the
// item's dated `done` rows (via the `fetch` closure, backed by
// `ChecklistMirror.habitCompletionDates` / `supplementCompletionDates`) — no
// stored stats, no migration.
//
// Presented through `.adaptiveDetail` (sheet on iPhone, docked inspector on
// iPad/macOS); carries its own Close · title · Edit chrome and hands "Edit"
// back to the parent through `onEdit`.

struct LoggableDetailView: View {
  let title: String
  let emoji: String?
  let accent: Color
  /// Past-tense verb for the count line — "done" (habits) / "taken"
  /// (supplements). Yields "Done 12 days" / "Taken 12 days".
  let doneVerb: String
  /// Loads this item's completion dates (YYYY-MM-DD, ascending) from a context.
  let fetch: (ModelContext) -> [String]
  /// Routes the toolbar "Edit" back to the parent so it can open the existing
  /// edit sheet for the same item.
  let onEdit: () -> Void

  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @Environment(\.adaptiveDetailClose) private var adaptiveClose

  @State private var dates: [String] = []

  private var isInspector: Bool { adaptiveClose != nil }
  private func close() { (adaptiveClose ?? { dismiss() })() }

  private var stats: ConsistencyStats { ConsistencyStats.make(dates: dates) }

  var body: some View {
    Group {
      if isInspector {
        scroll.safeAreaInset(edge: .top, spacing: 0) { inspectorHeader }
      } else {
        NavigationStack {
          scroll
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
              ToolbarItem(placement: .cancellationAction) {
                Button("Close", action: close).keyboardShortcut(.cancelAction)
              }
              ToolbarItem(placement: .primaryAction) { Button("Edit", action: onEdit) }
            }
        }
      }
    }
    .tint(accent)
    .task { reload() }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in reload() }
  }

  private func reload() { dates = fetch(modelContext) }

  // MARK: Chrome

  private var inspectorHeader: some View {
    HStack {
      Button("Close", action: close).keyboardShortcut(.cancelAction)
      Spacer()
      Text(title).font(.headline).lineLimit(1)
      Spacer()
      Button("Edit", action: onEdit).fontWeight(.semibold)
    }
    .tint(accent)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.bar)
  }

  private var scroll: some View {
    ScrollView {
      VStack(spacing: Theme.Spacing.xxl) {
        masthead
        tiles
        consistencyCard
        if !stats.recentDates.isEmpty { recentCard }
      }
      .padding(.horizontal, Theme.pageGutter)
      .padding(.top, Theme.Spacing.lg)
      .padding(.bottom, 24)
    }
    .background(Theme.groupedBackground)
  }

  // MARK: Sections

  private var masthead: some View {
    VStack(spacing: Theme.Spacing.sm) {
      Text(emoji ?? "•").font(.system(size: 48))
      Text(stats.totalCount == 0
           ? "No history yet"
           : "\(doneVerb.capitalized) \(stats.totalCount) \(stats.totalCount == 1 ? "day" : "days")")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
  }

  private var tiles: some View {
    StatGrid(columns: 3) {
      tile(value: "\(stats.currentStreak)",
           caption: "day streak",
           accentValue: stats.currentStreak > 0)
      tile(value: "\(stats.bestStreak)", caption: "best streak")
      tile(value: "\(stats.last30Percent)%", caption: "last 30 days")
    }
  }

  @ViewBuilder
  private func tile(value: String, caption: String, accentValue: Bool = false) -> some View {
    StatTile {
      VStack(spacing: 4) {
        Text(value)
          .font(.system(.title2, design: .rounded).weight(.semibold))
          .foregroundStyle(accentValue ? accent : Theme.inkPrimary)
        Text(caption)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .padding(.horizontal, 4)
    }
  }

  private var consistencyCard: some View {
    DrawerSection("Last 5 weeks") {
      ConsistencyGrid(doneOrdinals: stats.ordinals, accent: accent)
        .padding(.vertical, 4)
    }
  }

  private var recentCard: some View {
    DrawerSection("Recent") {
      VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
        ForEach(stats.recentDates, id: \.self) { date in
          HStack {
            Text(relativeDay(date))
            Spacer()
            Text(weekday(date)).foregroundStyle(.secondary)
          }
          .font(.subheadline)
        }
      }
    }
  }

  // MARK: Formatting

  private func relativeDay(_ iso: String) -> String {
    guard let date = SeptenaDate.parse(iso),
          let today = SeptenaDate.parse(SeptenaDate.today) else { return iso }
    let days = Calendar.current.dateComponents([.day], from: today, to: date).day ?? 0
    switch days {
    case 0: return "Today"
    case -1: return "Yesterday"
    case let d where d < -1 && d > -7: return "\(-d) days ago"
    default:
      let f = DateFormatter(); f.dateFormat = "MMM d"
      return f.string(from: date)
    }
  }

  private func weekday(_ iso: String) -> String {
    guard let date = SeptenaDate.parse(iso) else { return "" }
    let f = DateFormatter(); f.dateFormat = "EEE"
    return f.string(from: date)
  }
}

// MARK: - Consistency grid

/// A five-week "did I do it" grid ending today — 35 cells, oldest top-left,
/// today bottom-right. Filled in the section accent when the item was done
/// that day, faint otherwise; today carries a ring. Echoes the app's heatmap
/// idiom at a single-item scale.
private struct ConsistencyGrid: View {
  let doneOrdinals: Set<Int>
  let accent: Color

  private static let span = 35
  private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

  var body: some View {
    let todayOrd = SeptenaDate.parse(SeptenaDate.today).flatMap {
      Calendar.current.ordinality(of: .day, in: .era, for: $0)
    } ?? 0
    LazyVGrid(columns: columns, spacing: 6) {
      ForEach(0..<Self.span, id: \.self) { i in
        let ord = todayOrd - (Self.span - 1 - i)
        let done = doneOrdinals.contains(ord)
        let isToday = ord == todayOrd
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(done ? accent : Theme.inkSecondary.opacity(0.12))
          .aspectRatio(1, contentMode: .fit)
          .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
              .strokeBorder(isToday ? accent : .clear, lineWidth: 1.5)
          )
      }
    }
  }
}

// MARK: - Derived stats

/// Consistency figures for a habit/supplement, derived at read time from its
/// completion dates. Pure value type — no I/O.
struct ConsistencyStats {
  let totalCount: Int
  let currentStreak: Int
  let bestStreak: Int
  /// Share of the last 30 days (incl. today) the item was done, 0–100.
  let last30Percent: Int
  /// Done-day ordinals (era-day numbers) for the consistency grid.
  let ordinals: Set<Int>
  /// Most-recent completion dates, newest first (capped for display).
  let recentDates: [String]

  static func make(dates: [String]) -> ConsistencyStats {
    let ords = Set(dates.compactMap(ordinal))
    let todayOrd = SeptenaDate.parse(SeptenaDate.today).flatMap {
      Calendar.current.ordinality(of: .day, in: .era, for: $0)
    }

    // Current streak: consecutive days back from today (or yesterday, so a
    // not-yet-done today doesn't read as a broken streak).
    var current = 0
    if let t = todayOrd {
      var cursor = ords.contains(t) ? t : t - 1
      while ords.contains(cursor) { current += 1; cursor -= 1 }
    }

    // Best streak: longest run of consecutive ordinals.
    let sorted = ords.sorted()
    var best = 0, run = 0, prev: Int? = nil
    for o in sorted {
      if let p = prev, o == p + 1 { run += 1 } else { run = 1 }
      best = max(best, run); prev = o
    }

    let last30 = todayOrd.map { t in ords.filter { $0 > t - 30 && $0 <= t }.count } ?? 0
    let pct = Int(round(Double(last30) * 100 / 30))

    return ConsistencyStats(
      totalCount: dates.count,
      currentStreak: current,
      bestStreak: best,
      last30Percent: pct,
      ordinals: ords,
      recentDates: Array(dates.reversed().prefix(12))
    )
  }

  private static func ordinal(_ iso: String) -> Int? {
    guard let d = SeptenaDate.parse(iso) else { return nil }
    return Calendar.current.ordinality(of: .day, in: .era, for: d)
  }
}
