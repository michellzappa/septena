import SwiftUI

// Nutrition mini-app — meal log grouped by day. Summary card shows
// today's macro totals against the user's configured targets. Each meal
// is a LogRow with the emoji + food list + macros + time.

struct NutritionDestinationView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme

  @State private var entries: [NutritionEntry] = []
  @State private var macros: MacrosConfig? = nil
  @State private var loading = true

  private var accent: Color { theme.color(for: "nutrition") }

  private var today: String { SeptenaDate.today }

  private var todayEntries: [NutritionEntry] { entries.filter { $0.date == today } }

  private var todayTotals: (protein: Double, fat: Double, carbs: Double, kcal: Double) {
    todayEntries.reduce(into: (0.0, 0.0, 0.0, 0.0)) { acc, e in
      acc.0 += e.proteinG; acc.1 += e.fatG; acc.2 += e.carbsG; acc.3 += e.kcal
    }
  }

  /// Group entries by date, today first, then descending.
  private var sections: [(date: String, items: [NutritionEntry])] {
    let grouped = Dictionary(grouping: entries, by: \.date)
    return grouped.keys.sorted(by: >).map { d in (d, grouped[d] ?? []) }
  }

  var body: some View {
    List {
      summary
      ForEach(sections, id: \.date) { sec in
        Section {
          ForEach(sec.items) { entry in
            LogRow(
              title: entryTitle(entry),
              detail: macroLine(entry),
              trailing: entry.time,
              accent: accent
            )
            .listRowInsets(EdgeInsets())
          }
        } header: {
          Text(friendlyDate(sec.date))
        }
      }
      if !loading && entries.isEmpty {
        ContentUnavailableView("No entries",
                               systemImage: "fork.knife",
                               description: Text("Log a meal in the webapp to see it here."))
      }
    }
    .listStyle(.insetGrouped)
    .background(Color(.systemGroupedBackground))
    .navigationTitle("Nutrition")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
    .tint(accent)
    .task { await load() }
    .refreshable { await load() }
  }

  // MARK: - Summary

  private var summary: some View {
    let t = todayTotals
    return Section {
      HStack(alignment: .top, spacing: 24) {
        stat(value: gFormat(t.protein), label: "protein", tint: accent, unit: "g")
        stat(value: kFormat(t.kcal),    label: "kcal",    tint: accent)
        Spacer()
        stat(value: "\(todayEntries.count)", label: "meals", tint: .secondary, alignment: .trailing)
      }
      if let m = macros {
        macroBar(label: "Protein", value: t.protein, target: m.protein.min, tint: accent)
        macroBar(label: "Carbs",   value: t.carbs,   target: m.carbs.max,   tint: .secondary)
        macroBar(label: "Fat",     value: t.fat,     target: m.fat.max,     tint: .secondary)
      }
    }
  }

  private func stat(value: String, label: String, tint: Color,
                    unit: String? = nil,
                    alignment: HorizontalAlignment = .leading) -> some View {
    VStack(alignment: alignment, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 2) {
        Text(value)
          .font(.system(.title2, design: .rounded).weight(.semibold))
          .foregroundStyle(tint)
        if let unit { Text(unit).font(.subheadline).foregroundStyle(.secondary) }
      }
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
  }

  private func macroBar(label: String, value: Double, target: Double, tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(label.uppercased())
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Text("\(gFormat(value))/\(gFormat(target))g")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      ProgressView(value: min(value, target * 1.5),
                   total: max(target, 1))
        .tint(tint)
    }
  }

  // MARK: - Helpers

  private func entryTitle(_ e: NutritionEntry) -> String {
    let emoji = e.emoji?.isEmpty == false ? "\(e.emoji!) " : ""
    return "\(emoji)\(e.foods.prefix(3).joined(separator: ", "))"
  }

  private func macroLine(_ e: NutritionEntry) -> String {
    "\(gFormat(e.proteinG))P · \(gFormat(e.carbsG))C · \(gFormat(e.fatG))F · \(kFormat(e.kcal)) kcal"
  }

  private func gFormat(_ v: Double) -> String {
    String(Int(v.rounded()))
  }

  private func kFormat(_ v: Double) -> String {
    String(Int(v.rounded()))
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

  // MARK: - Loading

  private func load() async {
    loading = true
    let since = sinceDate(daysBack: 14)
    async let e: [NutritionEntry]? = try? await client.nutritionEntries(since: since)
    async let m: MacrosConfig? = try? await client.nutritionMacrosConfig()
    let (entriesRes, macrosRes) = await (e, m)
    entries = entriesRes ?? []
    macros = macrosRes
    loading = false
  }

  private func sinceDate(daysBack: Int) -> String {
    let d = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: d)
  }
}
