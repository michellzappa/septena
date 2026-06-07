import SwiftUI
import Charts

// GitHub mini-app — read-only contribution heatmap + weekly commit
// sparkline, mirrored from the GitHub GraphQL API (see GitHubProvider).
// No CloudKit: GitHub is the source of truth, so we cache the last fetch
// via ResponseCache for instant cold-paint and refetch on appear.

struct GitHubDestinationView: View {
  @Environment(SectionTheme.self) private var theme

  @State private var contributions: GitHubContributions = .empty
  @State private var loading = true
  @State private var loadError: String? = nil
  @State private var provider = GitHubProvider.shared

  private var accent: Color { theme.color(for: "github") }
  private static let cacheKey = "github.contributions"

  /// ISO date → day, for O(1) heatmap cell lookup.
  private var byDate: [String: GitHubDay] {
    Dictionary(uniqueKeysWithValues: contributions.days.map { ($0.date, $0) })
  }

  var body: some View {
    SectionDrawer(sectionKey: "github") {
      if !contributions.days.isEmpty {
        summarySection
        heatmapSection
        weeklySparkline
      }
      emptyState
    }
    .tint(accent)
    .task {
      paintFromCache()
      await load()
    }
  }

  // MARK: - Sections

  private var summarySection: some View {
    DrawerSection {
      HStack(alignment: .top, spacing: 28) {
        stat(value: "\(contributions.total)",
             label: contributions.login.isEmpty ? "this year" : "@\(contributions.login)")
        stat(value: "\(currentStreak)", label: "day streak")
        stat(value: "\(bestDay)", label: "best day")
        Spacer(minLength: 0)
      }
    }
  }

  private func stat(value: String, label: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value)
        .font(.title2.weight(.semibold))
        .foregroundStyle(accent)
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var heatmapSection: some View {
    ChartCard(title: "Last year", detail: "\(contributions.total) contributions") {
      ConsistencyHeatmap(
        endDate: Date(),
        firstDataDate: contributions.days.first
          .flatMap { ConsistencyHeatmap.date(fromISO: $0.date) },
        accent: accent
      ) { iso in
        let count = byDate[iso]?.count ?? 0
        let contributions = String(localized: "\(count) contributions")
        return HeatmapDay(level: byDate[iso]?.level ?? 0,
                          label: "\(friendly(iso)): \(contributions)")
      }
    }
  }

  private var weeklySparkline: some View {
    let weeks = Array(weeklyBuckets.suffix(26))
    return ChartCard(title: "Weekly commits", detail: "last \(weeks.count) weeks") {
      Chart {
        ForEach(weeks, id: \.weekStart) { wk in
          BarMark(x: .value("Week", wk.weekStart),
                  y: .value("Commits", wk.total))
            .foregroundStyle(accent)
            .accessibilityLabel(wk.weekStart)
            .accessibilityValue("\(wk.total) commits")
        }
      }
      .chartXAxis(.hidden)
      .frame(height: 100)
    }
    .a11yCombineKeepingChildren(weeklySummary(weeks))
  }

  @ViewBuilder
  private var emptyState: some View {
    if !loading && contributions.days.isEmpty {
      if let loadError, provider.hasToken {
        ContentUnavailableView("Couldn’t load GitHub",
                               systemImage: "exclamationmark.triangle",
                               description: Text(loadError))
      } else {
        ContentUnavailableView("Not connected",
                               systemImage: theme.icon(for: "github"),
                               description: Text("Add a GitHub access token in Settings › Integrations."))
      }
    }
  }

  // MARK: - Derived

  /// Consecutive days with ≥1 contribution, counting back from the most
  /// recent day in the series. Honest: a gap today breaks it to 0.
  private var currentStreak: Int {
    var streak = 0
    for day in contributions.days.reversed() {
      if day.count > 0 { streak += 1 } else { break }
    }
    return streak
  }

  private var bestDay: Int {
    contributions.days.map(\.count).max() ?? 0
  }

  private struct WeekBucket { let weekStart: String; let total: Int }

  /// Sum contributions into ISO weeks (Monday-start), oldest → newest.
  private var weeklyBuckets: [WeekBucket] {
    var cal = Calendar(identifier: .iso8601)
    cal.firstWeekday = 2
    var totals: [Date: Int] = [:]
    for day in contributions.days {
      guard let d = ConsistencyHeatmap.date(fromISO: day.date) else { continue }
      let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
      guard let monday = cal.date(from: comps) else { continue }
      totals[monday, default: 0] += day.count
    }
    return totals.keys.sorted().map {
      WeekBucket(weekStart: ConsistencyHeatmap.iso($0), total: totals[$0] ?? 0)
    }
  }

  private func weeklySummary(_ weeks: [WeekBucket]) -> String {
    let totals = weeks.map(\.total)
    guard !totals.isEmpty else { return "Weekly commits chart. No data yet." }
    let avg = totals.reduce(0, +) / totals.count
    return "Weekly commits chart over the last \(weeks.count) weeks, averaging \(avg) per week."
  }

  private func friendly(_ iso: String) -> String {
    guard let d = ConsistencyHeatmap.date(fromISO: iso) else { return iso }
    return d.formatted(.dateTime.month(.abbreviated).day())
  }

  // MARK: - Loading

  private func paintFromCache() {
    if let v = ResponseCache.load(GitHubContributions.self, forKey: Self.cacheKey) {
      contributions = v
    }
    loading = false
  }

  private func load() async {
    guard provider.hasToken else { loading = false; return }
    loading = true
    defer { loading = false }
    do {
      let c = try await provider.fetchContributions(days: 365)
      contributions = c
      loadError = nil
      ResponseCache.save(c, forKey: Self.cacheKey)
    } catch {
      loadError = error.localizedDescription
    }
  }
}
