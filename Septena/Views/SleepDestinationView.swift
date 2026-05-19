import SwiftUI
import Charts

// Sleep mini-app — Oura-backed dashboard mirroring the webapp.
// Top: score rings + duration/stress stats. Middle: four 7-day charts
// (score/readiness, stages stacked, total sleep, stress vs recovery).
// Bottom: per-night LogRows for the last 14 nights.

struct SleepDestinationView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme

  @State private var nights: [OuraNight] = []
  @State private var loading = true

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
    List {
      scoresSection
      durationSection
      chartsSection
      Section("Recent nights") {
        ForEach(nights.prefix(14)) { night in
          LogRow(
            title: friendlyDate(night.date),
            detail: detailLine(night),
            trailing: night.totalH.map(formatHours),
            accent: accent
          )
          .listRowInsets(EdgeInsets())
        }
      }
      if nights.count > 14 {
        ActivityHeatmapSection(
          title: "Sleep score",
          accent: accent,
          daily: nights,
          date: { $0.date },
          value: { Double($0.sleepScore ?? 0) },
          levelFor: { v in
            let s = Int(v)
            if s <= 0 { return 0 }
            if s >= 85 { return 4 }
            if s >= 75 { return 3 }
            if s >= 65 { return 2 }
            return 1
          },
          labelFor: { v in "score \(Int(v))" },
          subtitleFor: { active, total, _ in
            "\(active) of \(total) nights logged"
          }
        )
      }
      if !loading && nights.isEmpty {
        ContentUnavailableView("No Oura data",
                               systemImage: theme.icon(for: "sleep"),
                               description: Text("Check your Oura sync in the webapp."))
      }
    }
    #if os(macOS)
    .listStyle(.inset)
    #else
    .listStyle(.insetGrouped)
    #endif
    .background(Theme.groupedBackground)
    .navigationTitle("Sleep")
    .trackScreen("sleep")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
    .tint(accent)
    .task {
      paintFromCache()
      await load()
    }
  }

  // MARK: - Top stat rows

  private var scoresSection: some View {
    Section {
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
        scoreRing(value: latest(\.sleepScore) ?? latest(\.efficiency),
                  label: "Sleep Score", target: "85+", color: accent)
        scoreRing(value: latest(\.readinessScore),
                  label: "Readiness", target: "85+", color: accent.opacity(0.7))
        scoreRing(value: latest(\.efficiency),
                  label: "Efficiency", target: "85%+", color: accent.opacity(0.55))
        bedtimeTile
      }
      .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
      .listRowBackground(Color.clear)
    }
  }

  private var durationSection: some View {
    Section {
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
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
      .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 6, trailing: 12))
      .listRowBackground(Color.clear)
    }
  }

  // MARK: - Tile primitives

  private func scoreRing(value: Int?, label: String, target: String, color: Color) -> some View {
    let pct = value.map { min(1.0, Double($0) / 100.0) } ?? 0
    return VStack(spacing: 6) {
      ZStack {
        Circle()
          .stroke(Color.secondary.opacity(0.2), lineWidth: 4)
        Circle()
          .trim(from: 0, to: pct)
          .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
          .rotationEffect(.degrees(-90))
        Text(value.map(String.init) ?? "—")
          .font(.system(.title3, design: .rounded).weight(.semibold))
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
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
    .background(Theme.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 16))
  }

  private func statTile(label: String, value: String?, target: String, color: Color) -> some View {
    VStack(spacing: 4) {
      Text(value ?? "—")
        .font(.system(.title2, design: .rounded).weight(.semibold))
        .foregroundStyle(color)
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(target)
        .font(.caption2)
        .foregroundStyle(.secondary.opacity(0.7))
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 14)
    .background(Theme.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 16))
  }

  private var bedtimeTile: some View {
    VStack(spacing: 6) {
      VStack(spacing: 1) {
        Text("BEDTIME")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(latest(\.bedtime) ?? "—")
          .font(.system(.body, design: .rounded).weight(.semibold))
      }
      VStack(spacing: 1) {
        Text("WAKE")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(latest(\.wakeTime) ?? "—")
          .font(.system(.body, design: .rounded).weight(.semibold))
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
    .background(Theme.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 16))
  }

  private var stressTile: some View {
    let mins = latest(\.stressHighMin)
    let summary = latest(\.stressSummary)
    let recovery = latest(\.recoveryHighMin)
    return VStack(spacing: 4) {
      Text(mins.map { "\($0)m" } ?? "—")
        .font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
        .foregroundStyle(stressColor(summary))
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
    .frame(maxWidth: .infinity)
    .padding(.vertical, 14)
    .background(Theme.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 16))
  }

  private func stressColor(_ summary: String?) -> Color {
    switch summary {
    case "stressful":            return .red
    case "restored", "restorative": return .green
    case "normal":               return .orange
    default:                     return .secondary
    }
  }

  // MARK: - Charts

  @ViewBuilder
  private var chartsSection: some View {
    if !last7.isEmpty {
      Section {
        scoreReadinessChart
          .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 6, trailing: 12))
          .listRowBackground(Color.clear)
        stagesChart
          .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 6, trailing: 12))
          .listRowBackground(Color.clear)
        totalSleepChart
          .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 6, trailing: 12))
          .listRowBackground(Color.clear)
        if last7.contains(where: { $0.stressHighMin != nil }) {
          stressRecoveryChart
            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 6, trailing: 12))
            .listRowBackground(Color.clear)
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
    return chartCard(title: "Score & Readiness", caption: "↑ 85+") {
      Chart {
        ForEach(last7) { n in
          if let s = n.sleepScore {
            LineMark(x: .value("Day", weekdayLabel(n.date)),
                     y: .value("Score", s),
                     series: .value("Series", "Sleep"))
              .foregroundStyle(accent)
              .interpolationMethod(.monotone)
              .accessibilityLabel(weekdayFull(n.date))
              .accessibilityValue("Sleep score \(s)")
          }
          if let r = n.readinessScore {
            LineMark(x: .value("Day", weekdayLabel(n.date)),
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
      ? "Seven-night averages: deep \(String(format: "%.1f", avgDeep)) hours, REM \(String(format: "%.1f", avgRem)) hours."
      : ""
    let summary = "Sleep stages chart. Deep, REM, and light hours per night. \(avgText)"
    return chartCard(title: "Sleep Stages", caption: "hours") {
      Chart {
        ForEach(last7) { n in
          if let d = n.deepH {
            BarMark(x: .value("Day", weekdayLabel(n.date)),
                    y: .value("Deep", d))
              .foregroundStyle(accent)
              .accessibilityLabel(weekdayFull(n.date))
              .accessibilityValue("Deep \(String(format: "%.1f", d)) hours")
          }
          if let r = n.remH {
            BarMark(x: .value("Day", weekdayLabel(n.date)),
                    y: .value("REM", r))
              .foregroundStyle(accent.opacity(0.7))
              .accessibilityLabel(weekdayFull(n.date))
              .accessibilityValue("REM \(String(format: "%.1f", r)) hours")
          }
          if let l = n.lightH {
            BarMark(x: .value("Day", weekdayLabel(n.date)),
                    y: .value("Light", l))
              .foregroundStyle(accent.opacity(0.4))
              .accessibilityLabel(weekdayFull(n.date))
              .accessibilityValue("Light \(String(format: "%.1f", l)) hours")
          }
        }
      }
      .chartForegroundStyleScale([
        "Deep":  accent,
        "REM":   accent.opacity(0.7),
        "Light": accent.opacity(0.4)
      ])
      .chartLegend(position: .bottom, alignment: .center, spacing: 8)
      .frame(height: 140)
    }
    .a11yCombineKeepingChildren(summary)
  }

  private var totalSleepChart: some View {
    let totals = last7.compactMap { $0.totalH }
    let avg = totals.isEmpty ? 0 : totals.reduce(0, +) / Double(totals.count)
    let avgText = avg > 0
      ? "Seven-night average \(String(format: "%.1f", avg)) hours."
      : ""
    let summary = "Total sleep chart. Target 7 to 9 hours. \(avgText)"
    return chartCard(title: "Total Sleep", caption: "↑ 7–9 h") {
      Chart {
        ForEach(last7) { n in
          if let t = n.totalH {
            LineMark(x: .value("Day", weekdayLabel(n.date)),
                     y: .value("Hours", t))
              .foregroundStyle(accent)
              .interpolationMethod(.monotone)
              .accessibilityHidden(true)
            PointMark(x: .value("Day", weekdayLabel(n.date)),
                      y: .value("Hours", t))
              .foregroundStyle(accent)
              .symbolSize(40)
              .accessibilityLabel(weekdayFull(n.date))
              .accessibilityValue("\(String(format: "%.1f", t)) hours")
          }
        }
        RuleMark(y: .value("Target", 7))
          .foregroundStyle(accent.opacity(0.4))
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
          .accessibilityHidden(true)
      }
      .chartYScale(domain: 0...10)
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
    return chartCard(title: "Stress & Recovery", caption: "min/day") {
      Chart {
        ForEach(last7) { n in
          if let s = n.stressHighMin {
            BarMark(x: .value("Day", weekdayLabel(n.date)),
                    y: .value("Stress", s))
              .foregroundStyle(stressColor(n.stressSummary))
              .accessibilityLabel(weekdayFull(n.date))
              .accessibilityValue("Stress \(s) minutes")
          }
          if let r = n.recoveryHighMin {
            BarMark(x: .value("Day", weekdayLabel(n.date)),
                    y: .value("Recovery", r))
              .foregroundStyle(Color.green)
              .accessibilityLabel(weekdayFull(n.date))
              .accessibilityValue("Recovery \(r) minutes")
          }
        }
      }
      .chartForegroundStyleScale([
        "Stress":   Color.red,
        "Recovery": Color.green
      ])
      .chartLegend(position: .bottom, alignment: .center, spacing: 8)
      .frame(height: 140)
    }
    .a11yCombineKeepingChildren(summary)
  }

  @ViewBuilder
  private func chartCard<C: View>(title: String, caption: String?, @ViewBuilder _ content: () -> C) -> some View {
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
      }
      content()
    }
    .padding(12)
    .background(Theme.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 16))
  }

  // MARK: - Loading

  private static let cacheKey = "sleep.nights"

  private func paintFromCache() {
    if let v = ResponseCache.load([OuraNight].self, forKey: Self.cacheKey) { nights = v }
    loading = false
  }

  private func load() async {
    loading = true
    if let n = try? await client.ouraHistory(days: 365) {
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
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    fmt.timeZone = .current
    guard let d = fmt.date(from: iso) else { return iso }
    let cal = Calendar.current
    if cal.isDateInToday(d)     { return "Today" }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    let days = cal.dateComponents([.day], from: d, to: Date()).day ?? 0
    if days < 7 {
      let weekday = DateFormatter()
      weekday.dateFormat = "EEEE"
      return weekday.string(from: d)
    }
    let pretty = DateFormatter()
    pretty.dateFormat = "MMM d"
    return pretty.string(from: d)
  }

  private func weekdayLabel(_ iso: String) -> String {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    fmt.timeZone = .current
    guard let d = fmt.date(from: iso) else { return iso }
    let wd = DateFormatter()
    wd.dateFormat = "EEE"
    return wd.string(from: d)
  }

  // Full weekday name for VoiceOver — visual axis uses abbreviated form.
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
