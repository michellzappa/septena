import SwiftUI

// Sleep mini-app — Oura-backed log of recent nights. Top summary shows
// last night's score / total / deep / rem / HRV; list below is per-night
// LogRows for the last ~14 nights so you can scan trends.

struct SleepDestinationView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme

  @State private var nights: [OuraNight] = []
  @State private var loading = true

  private var accent: Color { theme.color(for: "sleep") }

  /// Server returns newest-first; keep that order for the list.
  private var lastNight: OuraNight? { nights.first }

  var body: some View {
    List {
      summary
      Section("Recent nights") {
        ForEach(nights) { night in
          LogRow(
            title: friendlyDate(night.date),
            detail: detailLine(night),
            trailing: night.totalH.map(formatHours),
            accent: accent
          )
          .listRowInsets(EdgeInsets())
        }
      }
      if !loading && nights.isEmpty {
        ContentUnavailableView("No Oura data",
                               systemImage: "moon.zzz",
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
    #if os(iOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
    .tint(accent)
    .task { await load() }
    .refreshable { await load() }
  }

  // MARK: - Summary

  private var summary: some View {
    Section {
      if let n = lastNight {
        HStack(alignment: .top, spacing: 24) {
          stat(value: n.totalH.map(formatHours) ?? "—", label: "last night", tint: accent)
          stat(value: n.sleepScore.map { "\($0)" } ?? "—", label: "score", tint: accent)
          Spacer()
          if let hrv = n.hrv {
            stat(value: "\(hrv)", label: "HRV", tint: .secondary, alignment: .trailing)
          }
        }
        if n.deepH != nil || n.remH != nil {
          HStack(spacing: 18) {
            phase("Deep", hours: n.deepH)
            phase("REM",  hours: n.remH)
            phase("Light", hours: n.lightH)
            phase("Awake", hours: n.awakeH)
            Spacer()
          }
          .padding(.top, 4)
        }
      } else if loading {
        ProgressView()
          .frame(maxWidth: .infinity)
      }
    }
  }

  private func stat(value: String, label: String, tint: Color,
                    alignment: HorizontalAlignment = .leading) -> some View {
    VStack(alignment: alignment, spacing: 2) {
      Text(value)
        .font(.system(.title2, design: .rounded).weight(.semibold))
        .foregroundStyle(tint)
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
  }

  private func phase(_ name: String, hours: Double?) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(name)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      Text(hours.map(formatHours) ?? "—")
        .font(.footnote.monospacedDigit())
        .foregroundStyle(Theme.inkPrimary)
    }
  }

  // MARK: - Loading

  private func load() async {
    loading = true
    if let n = try? await client.ouraHistory(days: 14) {
      nights = n
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
}
