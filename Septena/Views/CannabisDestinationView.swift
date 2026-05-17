import SwiftUI

// Cannabis mini-app — same shape as Caffeine: today's sessions log +
// a 7-day history list. Entries note method (vape/edible), strain,
// optional effect.

struct CannabisDestinationView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme

  @State private var today: CannabisDayResponse? = nil
  @State private var history: [CannabisHistoryPoint] = []
  @State private var loading = true

  private var accent: Color { theme.color(for: "cannabis") }

  var body: some View {
    List {
      summary
      Section("Today") {
        if let today, !today.entries.isEmpty {
          ForEach(Array(today.entries.reversed())) { entry in
            LogRow(
              title: methodLabel(entry.method),
              detail: detailLine(entry),
              trailing: entry.time,
              accent: accent
            )
            .listRowInsets(EdgeInsets())
          }
        } else if !loading {
          Text("Nothing logged yet.")
            .foregroundStyle(.secondary)
        }
      }
      if !history.isEmpty {
        Section("7-day history") {
          ForEach(Array(history.reversed()), id: \.date) { p in
            LogRow(
              title: friendlyDate(p.date),
              detail: (p.totalG ?? 0) > 0
                ? String(format: "%.2f g", p.totalG ?? 0)
                : nil,
              trailing: "\(p.sessions) session\(p.sessions == 1 ? "" : "s")",
              accent: accent
            )
            .listRowInsets(EdgeInsets())
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
    .navigationTitle("Cannabis")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
    .tint(accent)
    .task { await load() }
  }

  private var summary: some View {
    Section {
      HStack(alignment: .top, spacing: 24) {
        stat(value: "\(today?.sessionCount ?? 0)",
             label: "today",
             tint: accent)
        if let g = today?.totalG, g > 0 {
          stat(value: String(format: "%.2f", g),
               label: "grams",
               tint: accent,
               unit: "g")
        }
        Spacer()
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

  private func methodLabel(_ m: String) -> String {
    m.capitalized
  }

  private func detailLine(_ e: CannabisEntry) -> String? {
    var parts: [String] = []
    if let s = e.strain, !s.isEmpty { parts.append(s) }
    if let hit = e.hit { parts.append("hit \(hit)") }
    if let g = e.grams, g > 0 { parts.append(String(format: "%.2fg", g)) }
    if let eff = e.effect, !eff.isEmpty { parts.append(eff) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func friendlyDate(_ iso: String) -> String {
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
    guard let d = fmt.date(from: iso) else { return iso }
    let cal = Calendar.current
    if cal.isDateInToday(d)     { return "Today" }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    let w = DateFormatter(); w.dateFormat = "EEEE"
    return w.string(from: d)
  }

  private func load() async {
    loading = true
    async let t = try? await client.cannabisDay(date: SeptenaDate.today)
    async let h = try? await client.cannabisHistory(days: 7)
    let (tRes, hRes) = await (t, h)
    today = tRes
    history = hRes?.daily ?? []
    loading = false
  }
}
