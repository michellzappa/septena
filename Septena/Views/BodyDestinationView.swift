import SwiftUI

// Body mini-app — Withings weigh-ins. Top summary surfaces latest
// weight + fat%, then a list of recent measurements (most recent first)
// rendered as LogRows.

struct BodyDestinationView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(SectionTheme.self) private var theme

  @State private var rows: [WithingsRow] = []
  @State private var loading = true

  private var accent: Color { theme.color(for: "body") }

  /// Server returns newest-first; keep that order for the list and pick
  /// row[0] as "latest." The reverse for the trend bars happens elsewhere.
  private var latest: WithingsRow? { rows.first }

  var body: some View {
    List {
      summary
      Section("Recent weigh-ins") {
        ForEach(rows) { row in
          LogRow(
            title: friendlyDate(row.date),
            detail: detailLine(row),
            trailing: row.weightKg.map { String(format: "%.1f kg", $0) },
            accent: accent
          )
          .listRowInsets(EdgeInsets())
        }
      }
      if !loading && rows.isEmpty {
        ContentUnavailableView("No Withings data",
                               systemImage: "scalemass",
                               description: Text("Check your Withings sync in the webapp."))
      }
    }
    .listStyle(.insetGrouped)
    .background(Color(.systemGroupedBackground))
    .navigationTitle("Body")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
    .tint(accent)
    .task { await load() }
    .refreshable { await load() }
  }

  private var summary: some View {
    Section {
      if let l = latest {
        HStack(alignment: .top, spacing: 24) {
          stat(value: l.weightKg.map { String(format: "%.1f", $0) } ?? "—",
               label: "weight",
               tint: accent,
               unit: "kg")
          stat(value: l.fatPct.map { String(format: "%.1f", $0) } ?? "—",
               label: "fat",
               tint: .secondary,
               unit: "%")
          Spacer()
        }
        if l.muscleMassKg != nil || l.fatMassKg != nil {
          HStack(spacing: 18) {
            mini("Muscle", value: l.muscleMassKg.map { String(format: "%.1f kg", $0) })
            mini("Fat mass", value: l.fatMassKg.map { String(format: "%.1f kg", $0) })
            mini("Hydration", value: l.hydrationKg.map { String(format: "%.1f kg", $0) })
            Spacer()
          }
          .padding(.top, 4)
        }
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

  private func detailLine(_ r: WithingsRow) -> String? {
    var parts: [String] = []
    if let f = r.fatPct { parts.append(String(format: "%.1f%% fat", f)) }
    if let m = r.muscleMassKg { parts.append(String(format: "%.1f kg muscle", m)) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func friendlyDate(_ iso: String) -> String {
    let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
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
    if let r = try? await client.withingsHistory(days: 14) {
      rows = r
    }
    loading = false
  }
}
