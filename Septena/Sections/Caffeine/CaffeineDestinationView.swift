import SwiftUI

// Caffeine mini-app — today's sessions log. Each entry is a LogRow
// (method · beans · grams + time). Weekly trends will be shown via
// graphs (not a list) in a later pass.

struct CaffeineDestinationView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(HTTPOutbox.self) private var outbox
  @Environment(SectionTheme.self) private var theme

  @State private var today: CaffeineDayResponse? = nil
  @State private var loading = true
  @State private var editing: CaffeineEntry? = nil
  @State private var history: [CaffeineHistoryPoint] = []

  private var accent: Color { theme.color(for: "caffeine") }

  var body: some View {
    List {
      summary
      Section("Today") {
        if let today, !today.entries.isEmpty {
          ForEach(Array(today.entries.reversed())) { entry in
            // Standard List "tap row → edit" pattern: Button with
            // `.plain` style preserves the row chrome; destructive
            // delete lives in the long-press context menu, matching the
            // rest of the app.
            Button {
              editing = entry
            } label: {
              LogRow(
                title: methodLabel(entry.method),
                detail: detailLine(entry),
                trailing: entry.time
              )
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets())
            .contextMenu {
              Button(role: .destructive) {
                delete(entry)
              } label: {
                Label("Delete", systemImage: "trash")
              }
            }
          }
        } else if !loading {
          Text("Nothing logged yet.")
            .foregroundStyle(.secondary)
        }
      }
      if !history.isEmpty {
        ActivityHeatmapSection(
          title: "Caffeine days",
          accent: accent,
          daily: history,
          date: { $0.date },
          value: { Double($0.sessions) },
          levelFor: { v in
            let n = Int(v)
            if n <= 0 { return 0 }
            if n == 1 { return 1 }
            if n == 2 { return 2 }
            if n == 3 { return 3 }
            return 4
          },
          labelFor: { v in
            let n = Int(v)
            return "\(n) \(n == 1 ? "session" : "sessions")"
          },
          subtitleFor: { active, total, sum in
            "\(active) of \(total) days · \(Int(sum)) sessions"
          }
        )
      }
    }
    #if os(macOS)
    .listStyle(.inset)
    #else
    .listStyle(.insetGrouped)
    #endif
    .background(Theme.groupedBackground)
    .navigationTitle("Caffeine")
    .trackScreen("caffeine")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
    .tint(accent)
    .task {
      paintFromCache()
      await load()
    }
    .sheet(item: $editing) { entry in
      EditCaffeineEntrySheet(
        date: today?.date ?? SeptenaDate.today,
        original: entry,
        onSave: { updated in applyLocalUpdate(updated) }
      )
    }
  }

  /// Swap an edited entry into the in-memory `today.entries` so the UI
  /// reflects the change immediately. The outbox carries the PUT to the
  /// server; the next `load()` will reconcile.
  private func applyLocalUpdate(_ updated: CaffeineEntry) {
    guard var t = today else { return }
    if let idx = t.entries.firstIndex(where: { $0.id == updated.id }) {
      var entries = t.entries
      entries[idx] = updated
      t = CaffeineDayResponse(
        date: t.date,
        entries: entries,
        sessionCount: t.sessionCount,
        totalG: entries.reduce(0.0) { $0 + ($1.grams ?? 0) }
      )
      today = t
      ResponseCache.save(t, forKey: CacheKey.today)
    }
  }

  private func delete(_ entry: CaffeineEntry) {
    guard var t = today else { return }
    let day = t.date
    outbox.enqueue(
      method: "DELETE",
      path: "/api/caffeine/entry/\(entry.id)?date=\(day)",
      body: nil,
      kind: "caffeine.delete"
    )
    let entries = t.entries.filter { $0.id != entry.id }
    t = CaffeineDayResponse(
      date: t.date,
      entries: entries,
      sessionCount: max(0, t.sessionCount - 1),
      totalG: entries.reduce(0.0) { $0 + ($1.grams ?? 0) }
    )
    today = t
    ResponseCache.save(t, forKey: CacheKey.today)
    Haptics.warning()
  }

  private enum CacheKey {
    static let today = "caffeine.today"
  }

  private func paintFromCache() {
    if let v = ResponseCache.load(CaffeineDayResponse.self, forKey: CacheKey.today) { today = v }
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

  private func load() async {
    loading = true
    if let tRes = try? await client.caffeineDay(date: SeptenaDate.today) {
      today = tRes
      ResponseCache.save(tRes, forKey: CacheKey.today)
    }
    if let h = try? await client.caffeineHistory(days: 365) {
      history = h.daily
    }
    loading = false
  }
}
