import SwiftUI

// Gut mini-app — today's movements (and any open discomfort window).
// Weekly trends will be shown via graphs (not a list) in a later pass.

struct GutDestinationView: View {
  @Environment(SeptenaClient.self) private var client
  @Environment(HTTPOutbox.self) private var outbox
  @Environment(SectionTheme.self) private var theme

  @State private var today: GutDayResponse? = nil
  @State private var loading = true
  @State private var editing: GutEntry? = nil

  private var accent: Color { theme.color(for: "gut") }

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
                title: bristolLabel(entry.bristol),
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
    .navigationTitle("Gut")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
    .tint(accent)
    .task {
      paintFromCache()
      await load()
    }
    .sheet(item: $editing) { entry in
      EditGutEntrySheet(
        date: today?.date ?? SeptenaDate.today,
        original: entry,
        onSave: { updated in applyLocalUpdate(updated) }
      )
    }
  }

  private func applyLocalUpdate(_ updated: GutEntry) {
    guard let t = today else { return }
    var entries = t.entries
    guard let idx = entries.firstIndex(where: { $0.id == updated.id }) else { return }
    entries[idx] = updated
    today = GutDayResponse(
      date: t.date,
      entries: entries,
      movementCount: t.movementCount,
      maxBlood: entries.map(\.blood).max() ?? 0,
      totalDiscomfortH: entries.compactMap(\.discomfortHours).reduce(0, +)
    )
    if let today { ResponseCache.save(today, forKey: CacheKey.today) }
  }

  private func delete(_ entry: GutEntry) {
    guard let t = today else { return }
    let day = t.date
    outbox.enqueue(
      method: "DELETE",
      path: "/api/gut/entry/\(entry.id)?date=\(day)",
      body: nil,
      kind: "gut.delete"
    )
    let entries = t.entries.filter { $0.id != entry.id }
    today = GutDayResponse(
      date: t.date,
      entries: entries,
      movementCount: max(0, t.movementCount - 1),
      maxBlood: entries.map(\.blood).max() ?? 0,
      totalDiscomfortH: entries.compactMap(\.discomfortHours).reduce(0, +)
    )
    if let today { ResponseCache.save(today, forKey: CacheKey.today) }
    Haptics.warning()
  }

  private var summary: some View {
    Section {
      HStack(alignment: .top, spacing: 24) {
        stat(value: "\(today?.movementCount ?? 0)",
             label: "today",
             tint: accent)
        if let avg = avgBristolToday {
          stat(value: String(format: "%.1f", avg),
               label: "avg Bristol",
               tint: .secondary)
        }
        if let d = today?.totalDiscomfortH, d > 0 {
          stat(value: String(format: "%.1f", d),
               label: "discomfort",
               tint: .orange,
               unit: "h")
        }
        Spacer()
      }
    }
  }

  private var avgBristolToday: Double? {
    guard let entries = today?.entries, !entries.isEmpty else { return nil }
    let sum = entries.reduce(0) { $0 + Double($1.bristol) }
    return sum / Double(entries.count)
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

  // Standard Bristol Stool Scale short forms — keep it clinical, not cute.
  private func bristolLabel(_ b: Int) -> String {
    switch b {
    case 1: return "Type 1 · hard lumps"
    case 2: return "Type 2 · lumpy"
    case 3: return "Type 3 · cracked"
    case 4: return "Type 4 · smooth"
    case 5: return "Type 5 · soft blobs"
    case 6: return "Type 6 · mushy"
    case 7: return "Type 7 · liquid"
    default: return "Type \(b)"
    }
  }

  private func detailLine(_ e: GutEntry) -> String? {
    var parts: [String] = []
    if let v = e.volume { parts.append(v) }
    if e.blood > 0 { parts.append("blood \(e.blood)") }
    if let h = e.discomfortHours, h > 0, let lvl = e.discomfortLevel {
      parts.append("\(lvl) \(String(format: "%.1fh", h))")
    }
    if let n = e.note, !n.isEmpty { parts.append(n) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private enum CacheKey {
    static let today = "gut.today"
  }

  private func paintFromCache() {
    if let v = ResponseCache.load(GutDayResponse.self, forKey: CacheKey.today) { today = v }
    loading = false
  }

  private func load() async {
    loading = true
    if let tRes = try? await client.gutDay(date: SeptenaDate.today) {
      today = tRes
      ResponseCache.save(tRes, forKey: CacheKey.today)
    }
    loading = false
  }
}
