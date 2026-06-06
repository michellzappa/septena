import SwiftUI
import Charts

// Body mini-app — Withings weigh-ins dashboard mirroring the webapp.
// Top: latest weight / fat / weekly Δ / muscle / hydration / bone mass.
// Middle: up to five 21-day trend charts with linear-regression trend
// line + 7-day projection (weight + fat + muscle).
// Bottom: per-weigh-in LogRows for the last 21 days.

struct BodyDestinationView: View {
  @Environment(SectionTheme.self) private var theme

  @State private var rows: [WithingsRow] = []
  @State private var targets: AppTargets?
  @State private var loading = true

  private var accent: Color { theme.color(for: "body") }

  // Server is newest-first; chronological (oldest → newest) for charts.
  private var chronological: [WithingsRow] {
    rows.reversed()
  }

  // Latest non-null helper.
  private func latest<T>(_ keyPath: KeyPath<WithingsRow, T?>) -> T? {
    rows.first(where: { $0[keyPath: keyPath] != nil })?[keyPath: keyPath]
  }

  private func latestRow<T>(_ keyPath: KeyPath<WithingsRow, T?>) -> WithingsRow? {
    rows.first(where: { $0[keyPath: keyPath] != nil })
  }

  var body: some View {
    SectionDrawer(sectionKey: "body", title: "Body") {
      statsSection
      chartsSection
      DrawerSection("Recent weigh-ins", padding: .none) {
        ForEach(rows) { row in
          LogRow(
            title: friendlyDate(row.date),
            detail: detailLine(row),
            trailing: row.weightKg.map { "\($0.decimalString()) kg" }
          )
        }
      }
      if !loading && rows.isEmpty {
        ContentUnavailableView("No Withings data",
                               systemImage: theme.icon(for: "body"),
                               description: Text("Connect Withings in Settings › Integrations."))
      }
    }
    .trackScreen("body")
    .tint(accent)
    .task {
      paintFromCache()
      await load()
    }
  }

  // MARK: - Stats

  private var statsSection: some View {
    StatGrid(columns: 3) {
        statTile(label: "Weight",
                 value: latest(\.weightKg).map { $0.decimalString() },
                 unit: "kg",
                 target: targets.flatMap { t in
                   if let mn = t.weightMinKg, let mx = t.weightMaxKg {
                     return "\(Int(mn))–\(Int(mx)) kg"
                   }
                   return nil
                 },
                 color: accent)
        statTile(label: "Body Fat",
                 value: latest(\.fatPct).map { $0.decimalString() },
                 unit: "%",
                 target: targets.flatMap { t in
                   if let mn = t.fatMinPct, let mx = t.fatMaxPct {
                     return "\(Int(mn))–\(Int(mx))%"
                   }
                   return nil
                 },
                 color: accent.opacity(0.7))
        weeklyDeltaTile
        if latest(\.muscleMassKg) != nil {
          statTile(label: "Muscle",
                   value: latest(\.muscleMassKg).map { $0.decimalString() },
                   unit: "kg",
                   target: nil,
                   color: accent.opacity(0.85))
        }
        if latest(\.hydrationKg) != nil {
          statTile(label: "Hydration",
                   value: latest(\.hydrationKg).map { $0.decimalString() },
                   unit: "kg",
                   target: nil,
                   color: accent.opacity(0.6))
        }
        if latest(\.boneMassKg) != nil {
          statTile(label: "Bone Mass",
                   value: latest(\.boneMassKg).map { $0.decimalString() },
                   unit: "kg",
                   target: nil,
                   color: accent.opacity(0.5))
        }
    }
  }

  private func statTile(label: String, value: String?, unit: String,
                        target: String?, color: Color) -> some View {
    StatTile {
      VStack(spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
          Text(value ?? "—")
            .font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
            .foregroundStyle(color)
          Text(unit)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Text(label)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(target ?? " ")
          .font(.caption2)
          .foregroundStyle(.secondary.opacity(0.7))
      }
    }
  }

  private var weeklyDeltaTile: some View {
    let delta = weeklyWeightDelta()
    let formatted: String? = delta.map { (d: Double) -> String in
      let sign = d > 0 ? "+" : ""
      return "\(sign)\(d.decimalString())"
    }
    let color: Color = (delta ?? 0) <= 0 ? accent : .orange
    return StatTile {
      VStack(spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
          Text(formatted ?? "—")
            .font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
            .foregroundStyle(color)
          Text("kg")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Text("Weekly Δ")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("7d vs prior")
          .font(.caption2)
          .foregroundStyle(.secondary.opacity(0.7))
      }
    }
  }

  /// Recent 7-day mean vs prior 7-day mean (kg). nil if either window
  /// has no weigh-ins. Matches the web `weightDelta` computation.
  private func weeklyWeightDelta() -> Double? {
    let weights = chronological.compactMap { $0.weightKg }
    let recent = weights.suffix(7)
    let prior = weights.dropLast(7).suffix(7)
    guard !recent.isEmpty, !prior.isEmpty else { return nil }
    let recentAvg = recent.reduce(0, +) / Double(recent.count)
    let priorAvg = prior.reduce(0, +) / Double(prior.count)
    return (recentAvg - priorAvg).rounded(toPlaces: 1)
  }

  // MARK: - Charts

  @ViewBuilder
  private var chartsSection: some View {
    if !chronological.isEmpty {
      VStack(spacing: 8) {
        trendChart(title: "Weight",
                   caption: targets.flatMap { t in
                     if let mn = t.weightMinKg, let mx = t.weightMaxKg {
                       return "\(Int(mn))–\(Int(mx)) kg"
                     }
                     return nil
                   },
                   keyPath: \.weightKg,
                   unit: "kg",
                   showTrend: true)
        trendChart(title: "Body Fat", caption: "↓ 10–15%",
                   keyPath: \.fatPct, unit: "%",
                   showTrend: true)
        trendChart(title: "Muscle", caption: "kg",
                   keyPath: \.muscleMassKg, unit: "kg",
                   showTrend: true)
        trendChart(title: "Hydration", caption: "kg",
                   keyPath: \.hydrationKg, unit: "kg",
                   showTrend: false)
        trendChart(title: "Bone Mass", caption: "kg",
                   keyPath: \.boneMassKg, unit: "kg",
                   showTrend: false)
      }
    }
  }

  @ViewBuilder
  private func trendChart(title: String, caption: String?,
                          keyPath: KeyPath<WithingsRow, Double?>,
                          unit: String, showTrend: Bool) -> some View {
    let points = chronological.compactMap { row -> (date: String, value: Double)? in
      guard let v = row[keyPath: keyPath] else { return nil }
      return (row.date, v)
    }
    if !points.isEmpty {
      let trend = showTrend ? linearTrend(points.map { $0.value }) : nil
      let projection = trend.map { projectedValue($0, count: points.count, days: 7) }
      let yDomain: ClosedRange<Double> = {
        var values = points.map { $0.value }
        if let t = trend {
          values.append(t.intercept)
          values.append(t.slope * Double(points.count + 6) + t.intercept)
        }
        let lo = values.min() ?? 0
        let hi = values.max() ?? 1
        let pad = max((hi - lo) * 0.1, 0.5)
        return (lo - pad)...(hi + pad)
      }()
      let valSum = points.map(\.value).reduce(0, +)
      let avg = points.isEmpty ? 0 : valSum / Double(points.count)
      let projText = projection.map { "Projection in 7 days \($0.decimalString()) \(unit)." } ?? ""
      let summary = "\(title) trend chart. "
                  + "Window average \(avg.decimalString()) \(unit). "
                  + projText
      ChartCard(
        title: title,
        detail: caption,
        accessory: {
          if let p = projection {
            Text("→ \(p.decimalString()) \(unit) in 7d")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      ) {
        Chart {
          ForEach(Array(points.enumerated()), id: \.offset) { idx, p in
            LineMark(x: .value("Day", idx),
                     y: .value(title, p.value),
                     series: .value("Series", "actual"))
              .foregroundStyle(accent)
              .interpolationMethod(.monotone)
              .accessibilityHidden(true)
            PointMark(x: .value("Day", idx),
                      y: .value(title, p.value))
              .foregroundStyle(accent)
              .symbolSize(28)
              .accessibilityLabel(weekdayFull(p.date))
              .accessibilityValue("\(p.value.decimalString()) \(unit)")
          }
          if let t = trend {
            ForEach(0..<(points.count + 7), id: \.self) { idx in
              LineMark(x: .value("Day", idx),
                       y: .value("Trend", t.slope * Double(idx) + t.intercept),
                       series: .value("Series", "trend"))
                .foregroundStyle(accent.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                .accessibilityHidden(true)
            }
          }
        }
        .chartXAxis(.hidden)
        .chartYScale(domain: yDomain)
        .frame(height: 160)
      }
      .a11yCombineKeepingChildren(summary)
    }
  }

  // MARK: - Linear regression

  private struct Trend { let slope: Double; let intercept: Double }

  private func linearTrend(_ ys: [Double]) -> Trend? {
    guard ys.count >= 3 else { return nil }
    let n = Double(ys.count)
    let xs = (0..<ys.count).map(Double.init)
    let sumX = xs.reduce(0, +)
    let sumY = ys.reduce(0, +)
    let sumXY = zip(xs, ys).map(*).reduce(0, +)
    let sumXX = xs.map { $0 * $0 }.reduce(0, +)
    let denom = n * sumXX - sumX * sumX
    guard denom != 0 else { return nil }
    let slope = (n * sumXY - sumX * sumY) / denom
    let intercept = (sumY - slope * sumX) / n
    return Trend(slope: slope, intercept: intercept)
  }

  private func projectedValue(_ t: Trend, count: Int, days: Int) -> Double {
    t.slope * Double(count - 1 + days) + t.intercept
  }

  // MARK: - Loading

  private enum CacheKey {
    static let rows    = "body.rows"
    static let targets = "body.targets"
  }

  private func paintFromCache() {
    if let v = ResponseCache.load([WithingsRow].self, forKey: CacheKey.rows) { rows = v }
    if let v = ResponseCache.load(AppTargets.self, forKey: CacheKey.targets) { targets = v }
    loading = false
  }

  private func load() async {
    loading = true
    let loadedRows = try? await WithingsProvider.shared.fetchHistory(days: 21)
    // Settings live in CloudKit — read from the local mirror, not FastAPI.
    let loadedSettings = SettingsMirror.loadSettings(context: LocalStore.shared.container.mainContext)
    if let loadedRows {
      let sorted = loadedRows.sorted { $0.date > $1.date }
      rows = sorted
      ResponseCache.save(sorted, forKey: CacheKey.rows)
    }
    if let t = loadedSettings?.targets {
      targets = t
      ResponseCache.save(t, forKey: CacheKey.targets)
    }
    loading = false
  }

  // MARK: - Format helpers

  private func detailLine(_ r: WithingsRow) -> String? {
    var parts: [String] = []
    if let f = r.fatPct { parts.append("\(f.decimalString())% fat") }
    if let m = r.muscleMassKg { parts.append("\(m.decimalString()) kg muscle") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func friendlyDate(_ iso: String) -> String {
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
    guard let d = fmt.date(from: iso) else { return iso }
    let cal = Calendar.current
    if cal.isDateInToday(d)     { return "Today" }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    let days = cal.dateComponents([.day], from: d, to: Date()).day ?? 0
    if days < 7 {
      let w = DateFormatter(); w.dateFormat = "EEEE"
      return w.string(from: d)
    }
    let p = DateFormatter(); p.setLocalizedDateFormatFromTemplate("MMMd")
    return p.string(from: d)
  }

  // Full weekday name for VoiceOver point labels — visual axis is hidden.
  private func weekdayFull(_ iso: String) -> String {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    guard let d = fmt.date(from: iso) else { return iso }
    let cal = Calendar.current
    if cal.isDateInToday(d)     { return "Today" }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    let w = DateFormatter(); w.dateFormat = "EEEE"
    return w.string(from: d)
  }
}

private extension Double {
  func rounded(toPlaces places: Int) -> Double {
    let mult = pow(10.0, Double(places))
    return (self * mult).rounded() / mult
  }
}
