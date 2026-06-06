import SwiftUI
import SwiftData

// Per-day browse sheet for caffeine entries — opens when the user taps a
// past cell in `CaffeineDestinationView`'s ActivityHeatmap. Lists every
// entry logged on that day and lets the user tap one to open the existing
// edit sheet (where they can fix the date and move it back to today).
//
// View + edit only — no "+ Add". Backfill of brand-new entries stays in
// the "log now, edit date" flow off the main capture button.

struct BrowseCaffeineDaySheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme

  /// ISO date the sheet is browsing.
  let date: String

  @State private var response: CaffeineDayResponse? = nil
  @State private var editing: CaffeineEntry? = nil

  private var caffeine: CaffeineMutator { SeptenaServices.shared.caffeineMutator }
  private var accent: Color { theme.color(for: "caffeine") }

  var body: some View {
    NavigationStack {
      List {
        if let resp = response {
          if resp.entries.isEmpty {
            // Empty-cell case is intentional: user may have sent an entry
            // here and not know it. Sheet still opens and reports honestly.
            ContentUnavailableView(
              "Nothing logged on \(SeptenaDate.friendlyLabel(date))",
              systemImage: theme.icon(for: "caffeine"),
              description: Text("If you think an entry got moved here by mistake, check nearby days too.")
            )
          } else {
            Section {
              ForEach(Array(resp.entries.reversed())) { entry in
                Button { editing = entry } label: {
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
      EditCaffeineEntrySheet(
        date: date,
        original: entry,
        onSave: { _ in reload() }
      )
    }
  }

  private func reload() {
    response = ChecklistMirror.loadCaffeineDay(context: modelContext, date: date)
  }

  private func delete(_ entry: CaffeineEntry) {
    caffeine.deleteEntry(id: entry.id)
    reload()
    Haptics.warning()
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
    if let g = e.grams { parts.append("\(g.decimalString(1))g") }
    if let n = e.note, !n.isEmpty { parts.append(n) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}
