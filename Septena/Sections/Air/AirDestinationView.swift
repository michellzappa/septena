import SwiftUI

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
      if !history.isEmpty {
        Section("7-day average") {
          ForEach(Array(history.reversed()), id: \.date) { p in
            LogRow(
              title: friendlyDate(p.date),
              detail: detailLine(p),
              trailing: p.co2Avg.map { "\(Int($0)) ppm" }
            )
            .listRowInsets(EdgeInsets())
          }
        }
      }
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
      Task { await pollen.refresh() }
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

  /// Pull the current aggregation from AirStore. Cheap — the store
  /// walks the SwiftData rows directly; no network, no decode.
  private func refresh() {
    summary = store.summary()
    history = store.history(days: 7).daily
  }
}
