import SwiftUI
import SwiftData

// Per-day browse sheet for gut entries — opens when the user taps a past
// cell in `GutDestinationView`'s ActivityHeatmap. Same shape as the
// caffeine/cannabis browse sheets: view + edit only.

struct BrowseGutDaySheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme

  let date: String

  @State private var response: GutDayResponse? = nil
  @State private var editing: GutEntry? = nil

  private var gut: GutMutator { SeptenaServices.shared.gutMutator }
  private var accent: Color { theme.color(for: "gut") }

  var body: some View {
    NavigationStack {
      List {
        if let resp = response {
          if resp.entries.isEmpty {
            ContentUnavailableView(
              "Nothing logged on \(SeptenaDate.friendlyLabel(date))",
              systemImage: theme.icon(for: "gut"),
              description: Text("If you think an entry got moved here by mistake, check nearby days too.")
            )
          } else {
            Section {
              ForEach(Array(resp.entries.reversed())) { entry in
                Button { editing = entry } label: {
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
            }
          }
        } else {
          Section { ProgressView() }
        }
      }
      #if os(iOS)
      .listStyle(.insetGrouped)
      #endif
      .navigationTitle(SeptenaDate.friendlyLabel(date))
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .tint(accent)
    }
    .task { reload() }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in
      reload()
    }
    .sheet(item: $editing) { entry in
      EditGutEntrySheet(
        date: date,
        original: entry,
        onSave: { _ in reload() }
      )
    }
  }

  private func reload() {
    response = ChecklistMirror.loadGutDay(context: modelContext, date: date)
  }

  private func delete(_ entry: GutEntry) {
    gut.deleteEntry(id: entry.id)
    reload()
    Haptics.warning()
  }

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
}
