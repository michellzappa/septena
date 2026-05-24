import SwiftUI
import SwiftData

// Caffeine mini-app — today's sessions log, reads from SwiftData and
// writes through CaffeineMutator.

struct CaffeineDestinationView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme

  @State private var today: CaffeineDayResponse? = nil
  @State private var loading = true
  @State private var editing: CaffeineEntry? = nil
  @State private var history: [CaffeineHistoryPoint] = []

  private var caffeine: CaffeineMutator { SeptenaServices.shared.caffeineMutator }

  private var accent: Color { theme.color(for: "caffeine") }

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
                trailing: entry.time
              )
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets())
            .contextMenu {
              Button { editing = entry } label: {
                Label("Edit", systemImage: "pencil")
              }
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
    .task { reload() }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in
      reload()
    }
    .sheet(item: $editing) { entry in
      EditCaffeineEntrySheet(
        date: today?.date ?? SeptenaDate.today,
        original: entry,
        onSave: { _ in reload() }
      )
    }
  }

  private func delete(_ entry: CaffeineEntry) {
    caffeine.deleteEntry(id: entry.id)
    reload()
    Haptics.warning()
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

  private func reload() {
    today = ChecklistMirror.loadCaffeineDay(context: modelContext, date: SeptenaDate.today)
    history = ChecklistMirror.loadCaffeineHistory(context: modelContext, days: 365).daily
    loading = false
  }
}
