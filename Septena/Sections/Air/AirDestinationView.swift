import SwiftUI
import Charts

// Air mini-app — sensor snapshot above a per-day stats list. CO2 is the
// headline number (the band drives the accent overlay); temp / humidity
// trail.
//
// Data flow (post-Mac-Mini): AranetBridge connects to the Aranet4 over
// CoreBluetooth while this view is on screen; each reading lands in
// AirStore (SwiftData) which also computes the summary + 7-day history.
// The legacy FastAPI client.airSummary() path is gone — air data is now
// fully local on the iOS device that captured it. CloudKit fan-out across
// devices is the next pass (see AirStore.swift header).

struct AirDestinationView: View {
  @Environment(SectionTheme.self) private var theme
  @Environment(AranetBridge.self) private var bridge
  @Environment(AirStore.self) private var store
  @Environment(PollenClient.self) private var pollen

  @State private var summary: AirSummary? = nil
  @State private var history: [AirHistoryPoint] = []
  /// Hour-resolution series powering the CO2/temp/humidity 24h charts.
  /// Refreshed on appear + on every `.septenaAirChanged` post — same
  /// trigger as `summary`/`history` so all three stay in sync.
  @State private var series24h: [AirReadingEntity] = []

  private var accent: Color { theme.color(for: "air") }

  /// CO2 band → swatch. Falls back to section accent when unknown.
  private func bandColor(_ band: String?) -> Color {
    switch band {
    case "good": return .green
    case "ok":   return .yellow
    case "poor": return .orange
    case "bad":  return .red
    default:     return accent
    }
  }

  var body: some View {
    List {
      summarySection
      pollenSection
      co2Last24hChart
      tempLast24hChart
      humidityLast24hChart
      co2SevenDayMaxChart
      pollenHistoryChart
      if history.isEmpty && summary?.latest == nil {
        Section {
          ContentUnavailableView {
            Label("No air data yet", systemImage: theme.icon(for: "air"))
          } description: {
            Text(emptyDescription)
          } actions: {
            if bridge.state == .idle ||
               bridge.state == .disconnected ||
               bridge.state == .bluetoothOff ||
               bridge.state == .unauthorized {
              Button("Connect Aranet") { bridge.start() }
                .buttonStyle(.borderedProminent)
            }
          }
        }
      }
    }
    #if os(macOS)
    .listStyle(.inset)
    #else
    .listStyle(.insetGrouped)
    #endif
    .background(Theme.groupedBackground)
    .navigationTitle("Air")
    .trackScreen("air")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
    .tint(accent)
    .onAppear {
      // Don't auto-start the bridge here — building CBCentralManager is
      // what triggers iOS's Bluetooth permission prompt, and surprising
      // the user with that on first launch of the Air tab (before they
      // even know there's a sensor feature) is poor UX. We do *resume*
      // a previously-started session though: if the user has already
      // granted permission and connected once, `bridge.start()` is
      // cheap and silent — no second prompt — and reuses the stored
      // peripheral UUID for an instant reconnect.
      if bridge.hasKnownPeripheral { bridge.start() }
      refresh()
      // Fire pollen refresh as a side task — it's cached for 6h, so
      // most appearances are a no-op. First load asks for location
      // permission inline; the user can dismiss the prompt and the
      // section gracefully shows the "denied" CTA instead.
      // History fans out on the same auth/permission gate so it
      // populates the bar chart without a second prompt.
      Task {
        await pollen.refresh()
        await pollen.refreshHistory()
      }
    }
    .onDisappear {
      // Don't `stop()` — the user may flip to Settings to inspect the
      // device and then back, and a re-scan each time is wasteful. The
      // bridge stays connected; the system will drop it when the app
      // suspends.
    }
    .onReceive(NotificationCenter.default
      .publisher(for: .septenaAirChanged)) { _ in
      refresh()
    }
  }

  // MARK: - Pollen

  /// Pollen card: today's grass / tree / weed roll-up + overall band
  /// pulled from Open-Meteo. Hidden until the first successful fetch
  /// so we don't render empty rows during the location prompt.
  @ViewBuilder
  private var pollenSection: some View {
    switch pollen.state {
    case .denied:
      Section {
        VStack(alignment: .leading, spacing: 4) {
          Text("Pollen needs location access")
            .font(.subheadline.weight(.medium))
          Text("Allow location in iOS Settings → Privacy → Location → Septena to see daily pollen counts for your area.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } header: { Text("Pollen") }
    case .failed(let msg):
      Section {
        Text(msg).font(.caption).foregroundStyle(.orange)
      } header: { Text("Pollen") }
    default:
      if let p = pollen.today {
        Section {
          // Three big stats — grass / tree / weed are the rollups
          // a user actually cares about during allergy season. Birch
          // and friends live inside `tree`; ragweed/mugwort in `weed`.
          HStack(alignment: .top, spacing: 24) {
            pollenStat("Grass", value: p.grassMax ?? p.grass, species: "grass")
            pollenStat("Tree",  value: p.treeMax,             species: "tree")
            pollenStat("Weed",  value: p.weedMax,             species: "weed")
            Spacer()
          }
          // Overall band footer — single-glance "is today bad".
          if let bandLabel = pollenBandLabel(p.overallBand) {
            HStack(spacing: 6) {
              Circle()
                .fill(pollenBandColor(p.overallBand))
                .frame(width: 6, height: 6)
              Text("Overall: \(bandLabel)")
                .font(.caption)
                .foregroundStyle(.secondary)
              Spacer()
            }
            .padding(.top, 4)
          }
        } header: { Text("Pollen") } footer: {
          Text("Counts in grains/m³ from Open-Meteo. Cached for 6h.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func pollenStat(_ label: String, value: Double?, species: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value.map { String(format: "%.0f", $0) } ?? "—")
        .font(.system(.title3, design: .rounded).weight(.semibold))
        .foregroundStyle(pollenBandColor(bandRaw(species: species, value: value)))
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
  }

  /// Mirrors the threshold ladder in PollenClient; duplicated here so
  /// the view doesn't reach into PollenClient's internals just for a
  /// color. If you adjust thresholds in one place, update the other.
  private func bandRaw(species: String, value: Double?) -> String {
    guard let v = value else { return "unknown" }
    let key: String = species == "tree" ? "birch" : (species == "weed" ? "ragweed" : species)
    let t: (low: Double, medium: Double, high: Double)?
    switch key {
    case "grass":   t = (5, 20, 50)
    case "birch":   t = (10, 50, 200)
    case "ragweed": t = (5, 11, 25)
    default:        t = nil
    }
    guard let t else { return "unknown" }
    if v <= t.low    { return "low" }
    if v <= t.medium { return "medium" }
    if v <= t.high   { return "high" }
    return "very_high"
  }

  private func pollenBandColor(_ raw: String) -> Color {
    switch raw {
    case "low":       return .green
    case "medium":    return .yellow
    case "high":      return .orange
    case "very_high": return .red
    default:          return .secondary
    }
  }

  private func pollenBandLabel(_ raw: String) -> String? {
    switch raw {
    case "low":       return "Low"
    case "medium":    return "Medium"
    case "high":      return "High"
    case "very_high": return "Very high"
    default:          return nil
    }
  }

  // MARK: - Summary

  @ViewBuilder
  private var summarySection: some View {
    Section {
      HStack(alignment: .top, spacing: 24) {
        stat(value: summary?.latest?.co2Ppm.map { "\(Int($0))" } ?? "—",
             label: "CO2 ppm",
             tint: bandColor(summary?.co2Band))
        stat(value: summary?.latest?.tempC.map { String(format: "%.1f", $0) } ?? "—",
             label: "temp",
             tint: .secondary,
             unit: "°C")
        stat(value: summary?.latest?.humidityPct.map { "\(Int($0))" } ?? "—",
             label: "humidity",
             tint: .secondary,
             unit: "%")
        Spacer()
      }
      if let s = summary {
        HStack(spacing: 18) {
          mini("Today avg", value: s.today.co2Avg.map { "\(Int($0))" })
          mini("Today max", value: s.today.co2Max.map { "\(Int($0))" })
          mini("Over 1000", value: "\(s.today.minutesOver1000)m")
          Spacer()
        }
        .padding(.top, 4)
      }
      connectionFooter
    }
  }

  @ViewBuilder
  private var connectionFooter: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(statusColor)
        .frame(width: 6, height: 6)
      Text(statusLabel)
        .font(.caption)
        .foregroundStyle(.secondary)
      if let name = bridge.deviceName, bridge.state == .connected {
        Text("· \(name)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
    }
    .padding(.top, 4)
  }

  private var statusColor: Color {
    switch bridge.state {
    case .connected:    return .green
    case .connecting,
         .scanning:     return .yellow
    case .bluetoothOff,
         .unauthorized: return .red
    case .disconnected: return .orange
    case .idle:         return .secondary
    }
  }

  private var statusLabel: String {
    switch bridge.state {
    case .connected:    return "Connected"
    case .connecting:   return "Connecting…"
    case .scanning:     return "Scanning…"
    case .disconnected: return "Disconnected"
    case .bluetoothOff: return "Bluetooth off"
    case .unauthorized: return "Bluetooth permission denied"
    case .idle:         return "Idle"
    }
  }

  private var emptyDescription: String {
    switch bridge.state {
    case .bluetoothOff:
      return "Turn on Bluetooth to connect to your Aranet4."
    case .unauthorized:
      return "Allow Bluetooth in iOS Settings → Septena."
    default:
      return "Make sure your Aranet4 is nearby and powered on."
    }
  }

  private func stat(value: String, label: String, tint: Color,
                    unit: String? = nil) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 2) {
        Text(value)
          .font(.system(.title2, design: .rounded).weight(.semibold))
          .foregroundStyle(tint)
        if let unit { Text(unit).font(.subheadline).foregroundStyle(.secondary) }
      }
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
  }

  private func mini(_ label: String, value: String?) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(label.uppercased())
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(value ?? "—")
        .font(.footnote.monospacedDigit())
        .foregroundStyle(Theme.inkPrimary)
    }
  }

  private func detailLine(_ p: AirHistoryPoint) -> String? {
    var parts: [String] = []
    if let max_ = p.co2Max { parts.append("peak \(Int(max_))") }
    if p.minutesOver1000 > 0 { parts.append("\(p.minutesOver1000)m over 1000") }
    parts.append("\(p.readings) readings")
    return parts.joined(separator: " · ")
  }

  private func friendlyDate(_ iso: String) -> String {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
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

  // MARK: - Charts
  //
  // Five charts mirroring septena-app/components/air-dashboard.tsx:
  //   1. CO2 last 24h     — line + reference bands (1000-1400 warn, 1400+ bad)
  //   2. Temperature 24h  — line, auto y-domain
  //   3. Humidity 24h     — line + 40/60 comfort band lines
  //   4. CO2 7-day max    — line with dots, 1000 ref line
  //   5. Grass pollen 7d  — bar chart, max grains/m³ per day
  //
  // Each section gates on data availability so a fresh-install state
  // doesn't render empty cards. Reference bands/lines duplicate the
  // webapp's thresholds (1000 ok→poor, 1400 poor→bad, 40-60% humidity
  // comfort) so the visual language stays consistent.

  /// Fixed 24h X window shared by all three last-24h charts so the
  /// time axis lines up across them (and isn't compressed when one
  /// metric has fewer non-nil samples than another).
  private var last24hWindow: ClosedRange<Date> {
    let now = Date()
    return now.addingTimeInterval(-24 * 3600)...now
  }

  @ViewBuilder
  private var co2Last24hChart: some View {
    let pts = series24h.filter { $0.co2Ppm != nil }
    if pts.count >= 2 {
      Section {
        Chart {
          // Health threshold rules — webapp uses these as ReferenceLines.
          // The colored band rectangles the webapp shows behind the
          // line are harder to do cleanly in Swift Charts (RectangleMark
          // requires explicit x bounds); the rules carry the same info.
          RuleMark(y: .value("1000", 1000))
            .foregroundStyle(.orange.opacity(0.6))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [6, 3]))
          RuleMark(y: .value("1400", 1400))
            .foregroundStyle(.red.opacity(0.6))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [6, 3]))
          // Reading line + per-sample dots so every ad we captured
          // in the window is visible (Aranet broadcasts ~every 5s
          // when foreground-scanned, so density carries information).
          ForEach(pts) { p in
            LineMark(x: .value("Time", p.capturedAt),
                     y: .value("ppm", p.co2Ppm ?? 0))
              .foregroundStyle(accent)
              .interpolationMethod(.monotone)
            PointMark(x: .value("Time", p.capturedAt),
                      y: .value("ppm", p.co2Ppm ?? 0))
              .foregroundStyle(accent)
              .symbolSize(10)
          }
        }
        .chartXScale(domain: last24hWindow)
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 200)
      } header: { chartHeader("CO₂ last 24h", detail: co2Last24hDetail) }
    }
  }

  /// "avg N · max N ppm" summary string for the last-24h section
  /// header. Extracted so the section body stays clean of optional
  /// chaining ladders.
  private var co2Last24hDetail: String? {
    guard let s = summary?.last24h,
          let avg = s.co2Avg, let mx = s.co2Max else { return nil }
    return "avg \(Int(avg)) · max \(Int(mx)) ppm"
  }

  @ViewBuilder
  private var tempLast24hChart: some View {
    let pts = series24h.filter { $0.tempC != nil }
    if pts.count >= 2 {
      Section {
        Chart(pts) { p in
          LineMark(x: .value("Time", p.capturedAt),
                   y: .value("°C", p.tempC ?? 0))
            .foregroundStyle(.yellow)
            .interpolationMethod(.monotone)
          PointMark(x: .value("Time", p.capturedAt),
                    y: .value("°C", p.tempC ?? 0))
            .foregroundStyle(.yellow)
            .symbolSize(10)
        }
        .chartXScale(domain: last24hWindow)
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 140)
      } header: { chartHeader("Temperature", detail: "last 24h") }
    }
  }

  @ViewBuilder
  private var humidityLast24hChart: some View {
    let pts = series24h.filter { $0.humidityPct != nil }
    if pts.count >= 2 {
      Section {
        Chart {
          // 40-60% comfort band reference lines (matches webapp).
          RuleMark(y: .value("40%", 40))
            .foregroundStyle(.green.opacity(0.4))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [6, 3]))
          RuleMark(y: .value("60%", 60))
            .foregroundStyle(.green.opacity(0.4))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [6, 3]))
          ForEach(pts) { p in
            LineMark(x: .value("Time", p.capturedAt),
                     y: .value("%", Double(p.humidityPct ?? 0)))
              .foregroundStyle(.teal)
              .interpolationMethod(.monotone)
            PointMark(x: .value("Time", p.capturedAt),
                      y: .value("%", Double(p.humidityPct ?? 0)))
              .foregroundStyle(.teal)
              .symbolSize(10)
          }
        }
        .chartXScale(domain: last24hWindow)
        .chartYScale(domain: 0...100)
        .frame(height: 140)
      } header: { chartHeader("Humidity", detail: "last 24h") }
    }
  }

  @ViewBuilder
  private var co2SevenDayMaxChart: some View {
    // history is reversed in the original list; for the chart we want
    // oldest→newest so the x-axis reads left to right naturally.
    let pts = history.filter { $0.co2Max != nil }
    if pts.count >= 2 {
      Section {
        Chart(pts, id: \.date) { p in
          LineMark(x: .value("Day", p.date),
                   y: .value("ppm", p.co2Max ?? 0))
            .foregroundStyle(accent)
            .symbol(.circle)
          // Threshold rule.
          RuleMark(y: .value("1000", 1000))
            .foregroundStyle(.orange.opacity(0.5))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [6, 3]))
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis {
          AxisMarks(values: .automatic(desiredCount: 7)) { value in
            AxisValueLabel {
              if let iso = value.as(String.self) {
                Text(weekdayShort(iso))
              }
            }
            AxisGridLine()
          }
        }
        .frame(height: 160)
      } header: { chartHeader("CO₂ 7-day max", detail: "daily peak") }
    }
  }

  @ViewBuilder
  private var pollenHistoryChart: some View {
    let pts = pollen.history.filter { $0.grassMax != nil }
    if pts.count >= 2 {
      Section {
        Chart(pts) { p in
          BarMark(x: .value("Day", p.date),
                  y: .value("grains/m³", p.grassMax ?? 0))
            .foregroundStyle(.green)
            .cornerRadius(2)
        }
        .chartYScale(domain: .automatic(includesZero: true))
        .chartXAxis {
          AxisMarks(values: .automatic(desiredCount: 7)) { value in
            AxisValueLabel {
              if let iso = value.as(String.self) {
                Text(weekdayShort(iso))
              }
            }
            AxisGridLine()
          }
        }
        .frame(height: 160)
      } header: { chartHeader("Grass pollen 7 days", detail: "daily max") }
    }
  }

  private func chartHeader(_ title: String, detail: String?) -> some View {
    HStack(spacing: 6) {
      Text(title)
      if let detail {
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  /// Short weekday from a "yyyy-MM-dd" string. Falls back to MM-DD when
  /// the value can't be parsed.
  private func weekdayShort(_ iso: String) -> String {
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
    guard let d = fmt.date(from: iso) else { return String(iso.suffix(5)) }
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "Today" }
    let w = DateFormatter(); w.dateFormat = "EEE"
    return w.string(from: d)
  }

  /// Pull the current aggregation from AirStore. Cheap — the store
  /// walks the SwiftData rows directly; no network, no decode.
  private func refresh() {
    summary = store.summary()
    history = store.history(days: 7).daily
    series24h = store.readings24h()
  }
}
