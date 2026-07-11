import SwiftUI
import Charts

// Sleep mini-app — Oura-backed dashboard mirroring the webapp.
// Top: score rings + duration/stress stats. Middle: four 7-day charts
// (score/readiness, stages stacked, total sleep, stress vs recovery).
// Bottom: per-night LogRows for the last 14 nights.

struct SleepDestinationView: View {
  @Environment(SectionTheme.self) private var theme

  // Hoisted formatters — these run in chart/row render paths, so allocating
  // a DateFormatter per call was wasteful. Configs preserved exactly.
  private static let ymdFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
  }()
  private static let ymdLocalTZFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current; return f
  }()
  private static let weekdayFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "EEEE"; return f
  }()
  private static let narrowWeekdayFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "EEEEE"; return f
  }()
  private static let monthDayFormatter: DateFormatter = {
    let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMd"); return f
  }()

  @State private var nights: [OuraNight] = []
  @State private var loading = true
  // Sleep is a read-only dual section: Log = score/duration readouts + the
  // nights list; Patterns = the four trend charts. Default Log (the "standard"
  // glanceable readout); no empty-state nudge since Sleep isn't user-authored.
  @State private var mode: DrawerMode = .remembered(for: "sleep", default: .log)

  private var accent: Color { theme.color(for: "sleep") }

  // Server returns newest-first; first element = most recent night.
  private var lastNight: OuraNight? { nights.first }

  // 7 most recent nights, chronological (oldest → newest) for charts.
  private var last7: [OuraNight] {
    Array(nights.prefix(7).reversed())
  }

  // Latest non-null helper — Oura sometimes omits fields on a given date.
  private func latest<T>(_ keyPath: KeyPath<OuraNight, T?>) -> T? {
    nights.first(where: { $0[keyPath: keyPath] != nil })?[keyPath: keyPath]
  }

  var body: some View {
    SectionDrawer(sectionKey: "sleep", mode: $mode,
                  log: {
      scoresSection
      durationSection
      DrawerSection("Recent nights", padding: .none) {
        ForEach(nights.prefix(14)) { night in
          LogRow(
            title: friendlyDate(night.date),
            detail: detailLine(night),
            trailing: night.totalH.map(formatHours)
          )
        }
      }
      // No-data state lives with the Log half (the default mode) — when Oura
      // isn't connected there are no charts to show on the Patterns side either.
      if !loading && nights.isEmpty {
        ContentUnavailableView("No Oura data",
                               systemImage: theme.icon(for: "sleep"),
                               description: Text("Connect Oura in Settings › Integrations."))
      }
    }, patterns: {
      chartsSection
    })
    .tint(accent)
    .task {
      paintFromCache()
      await load()
    }
  }

  // MARK: - Top stat rows

  private var scoresSection: some View {
    StatGrid {
      scoreRing(value: latest(\.sleepScore) ?? latest(\.efficiency),
                label: "Sleep Score", target: "85+", color: accent)
      scoreRing(value: latest(\.readinessScore),
                label: "Readiness", target: "85+", color: accent.opacity(0.7))
      scoreRing(value: latest(\.efficiency),
                label: "Efficiency", target: "85%+", color: accent.opacity(0.55))
      bedtimeTile
    }
  }

  private var durationSection: some View {
    StatGrid {
      statTile(label: "Total Sleep",
               value: latest(\.totalH).map(formatHours),
               target: "7–9 h",
               color: accent)
      statTile(label: "Deep Sleep",
               value: latest(\.deepH).map(formatHours),
               target: "1–2 h",
               color: accent.opacity(0.85))
      statTile(label: "REM Sleep",
               value: latest(\.remH).map(formatHours),
               target: "1.5–2 h",
               color: accent.opacity(0.7))
      stressTile
    }
  }

  // MARK: - Tile primitives
  //
  // Each variant keeps its bespoke inner layout (ring, stat, two-row
  // bedtime/wake, stress + recovery). The outer chrome — uniform width,
  // vertical padding, rounded secondary-grouped background — lives in
  // `StatTile` so adjusting any of that touches one place.

  private func scoreRing(value: Int?, label: String, target: String, color: Color) -> some View {
    let pct = value.map { min(1.0, Double($0) / 100.0) } ?? 0
    return StatTile {
      VStack(spacing: 6) {
        ZStack {
          Circle()
            .stroke(Color.secondary.opacity(0.2), lineWidth: 4)
          Circle()
            .trim(from: 0, to: pct)
            .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            .rotationEffect(.degrees(-90))
          Text(value.map(String.init) ?? "—")
            .font(.septenaHeroMetric(.title3))
            .foregroundStyle(color)
        }
        .frame(width: 56, height: 56)
        Text(label)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(target)
          .font(.caption2)
          .foregroundStyle(.secondary.opacity(0.7))
      }
    }
  }

  private func statTile(label: String, value: String?, target: String, color: Color) -> some View {
    StatTile(verticalPadding: 14) {
      VStack(spacing: 4) {
        Text(value ?? "—")
          .font(.septenaHeroMetric())
          .foregroundStyle(color)
        Text(label)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(target)
          .font(.caption2)
          .foregroundStyle(.secondary.opacity(0.7))
      }
    }
  }

  private var bedtimeTile: some View {
    StatTile {
      VStack(spacing: 6) {
        VStack(spacing: 1) {
          Text("BEDTIME")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
          Text(latest(\.bedtime) ?? "—")
            .font(.septenaMetric)
        }
        VStack(spacing: 1) {
          Text("WAKE")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
          Text(latest(\.wakeTime) ?? "—")
            .font(.septenaMetric)
        }
      }
    }
  }

  private var stressTile: some View {
    let mins = latest(\.stressHighMin)
    let summary = latest(\.stressSummary)
    let recovery = latest(\.recoveryHighMin)
    return StatTile(verticalPadding: 14) {
      VStack(spacing: 4) {
        Text(mins.map { "\($0)m" } ?? "—")
          .font(.septenaHeroMetric())
          .foregroundStyle(accent)
        Text("Stress")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(summary.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "—")
          .font(.caption2)
          .foregroundStyle(.secondary.opacity(0.7))
        if let r = recovery {
          Text("\(r)m recovery")
            .font(.caption2)
            .foregroundStyle(.secondary.opacity(0.6))
        }
      }
    }
  }

  // MARK: - Charts

  @ViewBuilder
  private var chartsSection: some View {
    if !last7.isEmpty {
      VStack(spacing: 8) {
        scoreReadinessChart
        stagesChart
        totalSleepChart
        if last7.contains(where: { $0.stressHighMin != nil }) {
          stressRecoveryChart
        }
      }
    }
  }

  private var scoreReadinessChart: some View {
    let sleepScores = last7.compactMap { $0.sleepScore }
    let readyScores = last7.compactMap { $0.readinessScore }
    let avgSleep = sleepScores.isEmpty ? 0 : sleepScores.reduce(0, +) / sleepScores.count
    let avgReady = readyScores.isEmpty ? 0 : readyScores.reduce(0, +) / readyScores.count
    let parts: [String] = [
      avgSleep > 0 ? "Seven-day sleep score average \(avgSleep)." : "",
      avgReady > 0 ? "Readiness average \(avgReady)." : ""
    ].filter { !$0.isEmpty }
    let summary = "Score and readiness chart. Target 85 or higher. " + parts.joined(separator: " ")
    return ChartCard(title: "Score & Readiness", detail: "↑ 85+") {
      Chart {
        ForEach(last7) { n in
          if let s = n.sleepScore {
            LineMark(x: .value("Day", n.date),
                     y: .value("Score", s),
                     series: .value("Series", "Sleep"))
              .foregroundStyle(accent)
              .interpolationMethod(.monotone)
              .accessibilityLabel(weekdayFull(n.date))
              .accessibilityValue("Sleep score \(s)")
          }
          if let r = n.readinessScore {
            LineMark(x: .value("Day", n.date),
                     y: .value("Score", r),
                     series: .value("Series", "Readiness"))
              .foregroundStyle(accent.opacity(0.55))
              .interpolationMethod(.monotone)
              .accessibilityLabel(weekdayFull(n.date))
              .accessibilityValue("Readiness \(r)")
          }
        }
        RuleMark(y: .value("Target", 85))
          .foregroundStyle(accent.opacity(0.4))
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
          .accessibilityHidden(true)
      }
      .chartYScale(domain: 0...100)
      .chartXScale(domain: last7.map(\.date))
      .chartXAxis {
        AxisMarks(values: last7.map(\.date)) { v in
          AxisValueLabel {
            if let iso = v.as(String.self) {
              Text(verbatim: weekdayInitial(iso)).font(.caption2)
            }
          }
          AxisTick()
          AxisGridLine()
        }
      }
      .frame(height: 140)
    }
    .a11yCombineKeepingChildren(summary)
  }

  private var stagesChart: some View {
    let deeps = last7.compactMap { $0.deepH }
    let rems  = last7.compactMap { $0.remH }
    let avgDeep = deeps.isEmpty ? 0 : deeps.reduce(0, +) / Double(deeps.count)
    let avgRem  = rems.isEmpty  ? 0 : rems.reduce(0, +) / Double(rems.count)
    let avgText = (avgDeep > 0 || avgRem > 0)
      ? "Seven-night averages: deep \(avgDeep.decimalString()) hours, REM \(avgRem.decimalString()) hours."
      : ""
    let summary = "Sleep stages chart. Deep, REM, and light hours per night. \(avgText)"
    return ChartCard(title: "Sleep Stages", detail: "hours") {
      Chart {
        ForEach(last7) { n in
          if let d = n.deepH {
            BarMark(x: .value("Day", n.date),
                    y: .value("Deep", d))
              .foregroundStyle(accent)
              .accessibilityLabel(weekdayFull(n.date))
              .accessibilityValue("Deep \(d.decimalString()) hours")
          }
          if let r = n.remH {
            BarMark(x: .value("Day", n.date),
                    y: .value("REM", r))
              .foregroundStyle(accent.opacity(0.7))
              .accessibilityLabel(weekdayFull(n.date))
              .accessibilityValue("REM \(r.decimalString()) hours")
          }
          if let l = n.lightH {
            BarMark(x: .value("Day", n.date),
                    y: .value("Light", l))
              .foregroundStyle(accent.opacity(0.4))
              .accessibilityLabel(weekdayFull(n.date))
              .accessibilityValue("Light \(l.decimalString()) hours")
          }
        }
      }
      .chartForegroundStyleScale([
        "Deep":  accent,
        "REM":   accent.opacity(0.7),
        "Light": accent.opacity(0.4)
      ])
      .chartLegend(position: .bottom, alignment: .center, spacing: 8)
      .chartXScale(domain: last7.map(\.date))
      .chartXAxis {
        AxisMarks(values: last7.map(\.date)) { v in
          AxisValueLabel {
            if let iso = v.as(String.self) {
              Text(verbatim: weekdayInitial(iso)).font(.caption2)
            }
          }
          AxisTick()
          AxisGridLine()
        }
      }
      .frame(height: 140)
    }
    .a11yCombineKeepingChildren(summary)
  }

  private var totalSleepChart: some View {
    let totals = last7.compactMap { $0.totalH }
    let avg = totals.isEmpty ? 0 : totals.reduce(0, +) / Double(totals.count)
    let avgText = avg > 0
      ? "Seven-night average \(avg.decimalString()) hours."
      : ""
    let summary = "Total sleep chart. Target 7 to 9 hours. \(avgText)"
    return ChartCard(title: "Total Sleep", detail: "↑ 7–9 h") {
      Chart {
        ForEach(last7) { n in
          if let t = n.totalH {
            LineMark(x: .value("Day", n.date),
                     y: .value("Hours", t))
              .foregroundStyle(accent)
              .interpolationMethod(.monotone)
              .accessibilityHidden(true)
            PointMark(x: .value("Day", n.date),
                      y: .value("Hours", t))
              .foregroundStyle(accent)
              .symbolSize(40)
              .accessibilityLabel(weekdayFull(n.date))
              .accessibilityValue("\(t.decimalString()) hours")
          }
        }
        RuleMark(y: .value("Target", 7))
          .foregroundStyle(accent.opacity(0.4))
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
          .accessibilityHidden(true)
      }
      .chartYScale(domain: 0...10)
      .chartXScale(domain: last7.map(\.date))
      .chartXAxis {
        AxisMarks(values: last7.map(\.date)) { v in
          AxisValueLabel {
            if let iso = v.as(String.self) {
              Text(verbatim: weekdayInitial(iso)).font(.caption2)
            }
          }
          AxisTick()
          AxisGridLine()
        }
      }
      .frame(height: 140)
    }
    .a11yCombineKeepingChildren(summary)
  }

  private var stressRecoveryChart: some View {
    let stresses = last7.compactMap { $0.stressHighMin }
    let recoveries = last7.compactMap { $0.recoveryHighMin }
    let avgStress = stresses.isEmpty ? 0 : stresses.reduce(0, +) / stresses.count
    let avgRecovery = recoveries.isEmpty ? 0 : recoveries.reduce(0, +) / recoveries.count
    let parts: [String] = [
      avgStress > 0   ? "Stress \(avgStress) minutes."     : "",
      avgRecovery > 0 ? "Recovery \(avgRecovery) minutes." : ""
    ].filter { !$0.isEmpty }
    let summary = "Stress and recovery chart. Minutes per day. Seven-day averages: " + parts.joined(separator: " ")
    return ChartCard(title: "Stress & Recovery", detail: "min/day") {
      Chart {
        ForEach(last7) { n in
          if let s = n.stressHighMin {
            BarMark(x: .value("Day", n.date),
                    y: .value("Stress", s))
              .foregroundStyle(accent)
              .accessibilityLabel(weekdayFull(n.date))
              .accessibilityValue("Stress \(s) minutes")
          }
          if let r = n.recoveryHighMin {
            BarMark(x: .value("Day", n.date),
                    y: .value("Recovery", r))
              .foregroundStyle(accent.opacity(0.55))
              .accessibilityLabel(weekdayFull(n.date))
              .accessibilityValue("Recovery \(r) minutes")
          }
        }
      }
      .chartForegroundStyleScale([
        "Stress":   accent,
        "Recovery": accent.opacity(0.55)
      ])
      .chartLegend(position: .bottom, alignment: .center, spacing: 8)
      .chartXScale(domain: last7.map(\.date))
      .chartXAxis {
        AxisMarks(values: last7.map(\.date)) { v in
          AxisValueLabel {
            if let iso = v.as(String.self) {
              Text(verbatim: weekdayInitial(iso)).font(.caption2)
            }
          }
          AxisTick()
          AxisGridLine()
        }
      }
      .frame(height: 140)
    }
    .a11yCombineKeepingChildren(summary)
  }

  // MARK: - Loading

  private static let cacheKey = "sleep.nights"

  private func paintFromCache() {
    if let v = ResponseCache.load([OuraNight].self, forKey: Self.cacheKey) { nights = v }
    loading = false
  }

  private func load() async {
    loading = true
    if let n = try? await OuraProvider.shared.fetchHistory(days: 365) {
      nights = n
      ResponseCache.save(n, forKey: Self.cacheKey)
    }
    loading = false
  }

  // MARK: - Format helpers

  /// 7.2 → "7h 12m" — the format Oura users expect.
  private func formatHours(_ h: Double) -> String {
    let total = Int((h * 60).rounded())
    let hh = total / 60
    let mm = total % 60
    return mm == 0 ? "\(hh)h" : "\(hh)h \(mm)m"
  }

  private func detailLine(_ n: OuraNight) -> String? {
    var parts: [String] = []
    if let s = n.sleepScore { parts.append("Score \(s)") }
    if let bt = n.bedtime, let wt = n.wakeTime { parts.append("\(bt)–\(wt)") }
    if let hrv = n.hrv { parts.append("HRV \(hrv)") }
    if let eff = n.efficiency { parts.append("\(eff)% eff") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func friendlyDate(_ iso: String) -> String {
    guard let d = Self.ymdLocalTZFormatter.date(from: iso) else { return iso }
    let cal = Calendar.current
    if cal.isDateInToday(d)     { return "Today" }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    let days = cal.dateComponents([.day], from: d, to: Date()).day ?? 0
    if days < 7 {
      return Self.weekdayFormatter.string(from: d)
    }
    return Self.monthDayFormatter.string(from: d)
  }

  private func weekdayInitial(_ iso: String) -> String {
    guard let d = Self.ymdFormatter.date(from: iso) else { return "" }
    return Self.narrowWeekdayFormatter.string(from: d)
  }

  // Full weekday name for VoiceOver — visual axis uses abbreviated form.
  private func weekdayFull(_ iso: String) -> String {
    guard let d = Self.ymdFormatter.date(from: iso) else { return iso }
    let cal = Calendar.current
    if cal.isDateInToday(d)     { return "Today" }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    return Self.weekdayFormatter.string(from: d)
  }
}
