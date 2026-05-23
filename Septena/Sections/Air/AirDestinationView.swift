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
