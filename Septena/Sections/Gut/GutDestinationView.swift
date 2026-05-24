import SwiftUI
import SwiftData

// Gut mini-app — today's movements (and any open discomfort window).
// Reads from local SwiftData (CloudKit-synced) and writes via GutMutator.

struct GutDestinationView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme

  @State private var today: GutDayResponse? = nil
  @State private var loading = true
  @State private var editing: GutEntry? = nil
  @State private var history: [GutHistoryPoint] = []

  private var gut: GutMutator { SeptenaServices.shared.gutMutator }

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
          title: "Movement days",
          accent: accent,
          daily: history,
          date: { $0.date },
          value: { Double($0.movements) },
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
            return "\(n) \(n == 1 ? "movement" : "movements")"
          },
          subtitleFor: { active, total, sum in
            "\(active) of \(total) days · \(Int(sum)) movements"
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
    .navigationTitle("Gut")
    .trackScreen("gut")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.large)
    #endif
    .tint(accent)
    .task {
      reload()
    }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in
      reload()
    }
    .sheet(item: $editing) { entry in
      EditGutEntrySheet(
        date: today?.date ?? SeptenaDate.today,
        original: entry,
        onSave: { _ in reload() }
      )
    }
  }

  private func delete(_ entry: GutEntry) {
    gut.deleteEntry(id: entry.id)
    reload()
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

  private func reload() {
    today = ChecklistMirror.loadGutDay(context: modelContext, date: SeptenaDate.today)
    history = ChecklistMirror.loadGutHistory(context: modelContext, days: 365).daily
    loading = false
  }
}
