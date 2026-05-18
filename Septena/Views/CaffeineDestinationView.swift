import SwiftUI

// Caffeine mini-app — today's sessions log + weekly grams histogram in
// the summary. Each entry is a LogRow (method · beans · grams + time).

struct CaffeineDestinationView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme

  @State private var today: CaffeineDayResponse? = nil
  @State private var history: [CaffeineHistoryPoint] = []
  @State private var loading = true

  private var accent: Color { theme.color(for: "caffeine") }

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
              detail: p.totalG.map { String(format: "%.1f g", $0) },
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
    .navigationTitle("Caffeine")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
    .tint(accent)
    .task {
      paintFromCache()
      await load()
    }
  }

  private enum CacheKey {
    static let today   = "caffeine.today"
    static let history = "caffeine.history"
  }

  private func paintFromCache() {
    if let v = ResponseCache.load(CaffeineDayResponse.self, forKey: CacheKey.today) { today = v }
    if let v = ResponseCache.load([CaffeineHistoryPoint].self, forKey: CacheKey.history) { history = v }
    loading = false
  }

  private var summary: some View {
    Section {
      HStack(alignment: .top, spacing: 24) {
        stat(value: "\(today?.sessionCount ?? 0)",
             label: "today",
             tint: accent)
        stat(value: today?.totalG.map { String(format: "%.1f", $0) } ?? "—",
             label: "grams",
             tint: accent,
             unit: "g")
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
    switch m {
    case "v60":    return "V60"
    case "matcha": return "Matcha"
    default:       return m.capitalized
    }
  }

  private func detailLine(_ e: CaffeineEntry) -> String? {
    var parts: [String] = []
    if let beans = e.beans, !beans.isEmpty { parts.append(beans) }
    if let g = e.grams { parts.append(String(format: "%.1fg", g)) }
    if let n = e.note, !n.isEmpty { parts.append(n) }
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
    async let t = try? await client.caffeineDay(date: SeptenaDate.today)
    async let h = try? await client.caffeineHistory(days: 7)
    let (tRes, hRes) = await (t, h)
    if let tRes {
      today = tRes
      ResponseCache.save(tRes, forKey: CacheKey.today)
    }
    if let daily = hRes?.daily {
      history = daily
      ResponseCache.save(daily, forKey: CacheKey.history)
    }
    loading = false
  }
}
