import SwiftUI
import Charts

// Body mini-app — Withings weigh-ins dashboard mirroring the webapp.
// Top: latest weight / fat / weekly Δ / muscle / hydration / bone mass.
// Middle: up to five 21-day trend charts with linear-regression trend
// line + 7-day projection (weight + fat + muscle).
// Bottom: per-weigh-in LogRows for the last 21 days.

struct BodyDestinationView: View {
  @Environment(SeptenaClient.self) private var client
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
    List {
      statsSection
      chartsSection
      Section("Recent weigh-ins") {
        ForEach(rows) { row in
          LogRow(
            title: friendlyDate(row.date),
            detail: detailLine(row),
            trailing: row.weightKg.map { String(format: "%.1f kg", $0) }
          )
          .listRowInsets(EdgeInsets())
        }
      }
      if !loading && rows.isEmpty {
        ContentUnavailableView("No Withings data",
                               systemImage: theme.icon(for: "body"),
                               description: Text("Check your Withings sync in the webapp."))
      }
    }
    #if os(macOS)
    .listStyle(.inset)
    #else
    .listStyle(.insetGrouped)
    #endif
    .background(Theme.groupedBackground)
    .navigationTitle("Body")
    .trackScreen("body")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
    .tint(accent)
    .task {
      paintFromCache()
      await load()
    }
  }

  // MARK: - Stats

  private var statsSection: some View {
    Section {
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
        statTile(label: "Weight",
                 value: latest(\.weightKg).map { String(format: "%.1f", $0) },
                 unit: "kg",
                 target: targets.flatMap { t in
                   if let mn = t.weightMinKg, let mx = t.weightMaxKg {
                     return "\(Int(mn))–\(Int(mx)) kg"
                   }
                   return nil
                 },
                 color: accent)
        statTile(label: "Body Fat",
                 value: latest(\.fatPct).map { String(format: "%.1f", $0) },
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
                   value: latest(\.muscleMassKg).map { String(format: "%.1f", $0) },
                   unit: "kg",
                   target: nil,
                   color: accent.opacity(0.85))
        }
        if latest(\.hydrationKg) != nil {
          statTile(label: "Hydration",
                   value: latest(\.hydrationKg).map { String(format: "%.1f", $0) },
                   unit: "kg",
                   target: nil,
                   color: accent.opacity(0.6))
        }
        if latest(\.boneMassKg) != nil {
          statTile(label: "Bone Mass",
                   value: latest(\.boneMassKg).map { String(format: "%.1f", $0) },
                   unit: "kg",
                   target: nil,
                   color: accent.opacity(0.5))
        }
      }
      .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
      .listRowBackground(Color.clear)
    }
  }

  private func statTile(label: String, value: String?, unit: String,
                        target: String?, color: Color) -> some View {
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
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
    .background(Theme.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 16))
  }

  private var weeklyDeltaTile: some View {
    let delta = weeklyWeightDelta()
    let formatted: String? = delta.map { (d: Double) -> String in
      let sign = d > 0 ? "+" : ""
      return "\(sign)\(String(format: "%.1f", d))"
    }
    let color: Color = (delta ?? 0) <= 0 ? accent : .orange
    return VStack(spacing: 4) {
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
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
    .background(Theme.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 16))
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
      Section {
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
      let projText = projection.map { "Projection in 7 days \(String(format: "%.1f", $0)) \(unit)." } ?? ""
      let summary = "\(title) trend chart. "
                  + "Window average \(String(format: "%.1f", avg)) \(unit). "
                  + projText
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(title)
            .font(.subheadline.weight(.semibold))
          if let caption {
            Text(caption)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          if let p = projection {
            Text("→ \(String(format: "%.1f", p)) \(unit) in 7d")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
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
              .accessibilityValue("\(String(format: "%.1f", p.value)) \(unit)")
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
      .padding(12)
      .background(Theme.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 16))
      .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 6, trailing: 12))
      .listRowBackground(Color.clear)
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
    let loadedRows = try? await client.withingsHistory(days: 21)
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
    if let f = r.fatPct { parts.append(String(format: "%.1f%% fat", f)) }
    if let m = r.muscleMassKg { parts.append(String(format: "%.1f kg muscle", m)) }
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
    let p = DateFormatter(); p.dateFormat = "MMM d"
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
