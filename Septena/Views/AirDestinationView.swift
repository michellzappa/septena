import SwiftUI

// Air mini-app — sensor snapshot above a per-day stats list. CO2 is the
// headline number (the band drives the accent overlay); temp / humidity
// trail. Read-only for now since readings come from the room sensor.

struct AirDestinationView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme

  @State private var summary: AirSummary? = nil
  @State private var history: [AirHistoryPoint] = []
  @State private var loading = true

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
      Section("7-day average") {
        ForEach(history, id: \.date) { p in
          LogRow(
            title: friendlyDate(p.date),
            detail: detailLine(p),
            trailing: p.co2Avg.map { "\(Int($0)) ppm" },
            accent: accent
          )
          .listRowInsets(EdgeInsets())
        }
      }
      if !loading && history.isEmpty && summary == nil {
        ContentUnavailableView("No air data",
                               systemImage: "wind",
                               description: Text("Check your sensor connection in the webapp."))
      }
    }
    #if os(macOS)
    .listStyle(.inset)
    #else
    .listStyle(.insetGrouped)
    #endif
    .background(Theme.groupedBackground)
    .navigationTitle("Air")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
    .tint(accent)
    .task { await load() }
    .refreshable { await load() }
  }

  private var summarySection: some View {
    Section {
      if let s = summary {
        HStack(alignment: .top, spacing: 24) {
          stat(value: s.latest?.co2Ppm.map { "\(Int($0))" } ?? "—",
               label: "CO2 ppm",
               tint: bandColor(s.co2Band))
          stat(value: s.latest?.tempC.map { String(format: "%.1f", $0) } ?? "—",
               label: "temp",
               tint: .secondary,
               unit: "°C")
          stat(value: s.latest?.humidityPct.map { "\(Int($0))" } ?? "—",
               label: "humidity",
               tint: .secondary,
               unit: "%")
          Spacer()
        }
        HStack(spacing: 18) {
          mini("Today avg", value: s.today.co2Avg.map { "\(Int($0))" })
          mini("Today max", value: s.today.co2Max.map { "\(Int($0))" })
          mini("Over 1000", value: "\(s.today.minutesOver1000)m")
          Spacer()
        }
        .padding(.top, 4)
      } else if loading {
        ProgressView().frame(maxWidth: .infinity)
      }
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

  private func load() async {
    loading = true
    async let s = try? await client.airSummary()
    async let h = try? await client.airHistory(days: 7)
    let (sRes, hRes) = await (s, h)
    summary = sRes
    history = hRes?.daily ?? []
    loading = false
  }
}
