import SwiftUI

// Cannabis mini-app — today's sessions log. Entries note method
// (vape/edible), strain, optional effect. Weekly trends will be
// shown via graphs (not a list) in a later pass.

struct CannabisDestinationView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(HTTPOutbox.self) private var outbox
  @Environment(SectionTheme.self) private var theme

  @State private var today: CannabisDayResponse? = nil
  @State private var loading = true
  @State private var editing: CannabisEntry? = nil

  private var accent: Color { theme.color(for: "cannabis") }

  var body: some View {
    List {
      summary
      Section("Today") {
        if let today, !today.entries.isEmpty {
          ForEach(Array(today.entries.reversed())) { entry in
            Button {
              editing = entry
            } label: {
              LogRow(
                title: methodLabel(entry.method),
                detail: detailLine(entry),
                trailing: entry.time,
                accent: accent
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
    .task {
      paintFromCache()
      await load()
    }
    .sheet(item: $editing) { entry in
      EditCannabisEntrySheet(
        date: today?.date ?? SeptenaDate.today,
        original: entry,
        onSave: { updated in applyLocalUpdate(updated) }
      )
    }
  }

  private func applyLocalUpdate(_ updated: CannabisEntry) {
    guard let t = today else { return }
    var entries = t.entries
    guard let idx = entries.firstIndex(where: { $0.id == updated.id }) else { return }
    entries[idx] = updated
    today = CannabisDayResponse(
      date: t.date,
      entries: entries,
      sessionCount: t.sessionCount,
      totalG: entries.compactMap(\.grams).reduce(0, +)
    )
    if let today { ResponseCache.save(today, forKey: CacheKey.today) }
  }

  private func delete(_ entry: CannabisEntry) {
    guard let t = today else { return }
    let day = t.date
    outbox.enqueue(
      method: "DELETE",
      path: "/api/cannabis/entry/\(entry.id)?date=\(day)",
      body: nil,
      kind: "cannabis.delete"
    )
    let entries = t.entries.filter { $0.id != entry.id }
    today = CannabisDayResponse(
      date: t.date,
      entries: entries,
      sessionCount: max(0, t.sessionCount - 1),
      totalG: entries.compactMap(\.grams).reduce(0, +)
    )
    if let today { ResponseCache.save(today, forKey: CacheKey.today) }
    Haptics.warning()
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

  private enum CacheKey {
    static let today = "cannabis.today"
  }

  private func paintFromCache() {
    if let v = ResponseCache.load(CannabisDayResponse.self, forKey: CacheKey.today) { today = v }
    loading = false
  }

  private func load() async {
    loading = true
    if let tRes = try? await client.cannabisDay(date: SeptenaDate.today) {
      today = tRes
      ResponseCache.save(tRes, forKey: CacheKey.today)
    }
    loading = false
  }
}
