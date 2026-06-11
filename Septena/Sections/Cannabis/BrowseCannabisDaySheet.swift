import SwiftUI
import SwiftData

// Per-day browse sheet for cannabis sessions — opens when the user taps a
// past cell in `CannabisDestinationView`'s ActivityHeatmap. Same shape as
// `BrowseCaffeineDaySheet`: view + edit only, no add affordance.

struct BrowseCannabisDaySheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme

  let date: String

  @State private var response: CannabisDayResponse? = nil
  @State private var editing: CannabisEntry? = nil

  private let usesPerCapsule: Int = 3
  private var cannabis: CannabisMutator { SeptenaServices.shared.cannabisMutator }
  private var accent: Color { theme.color(for: "cannabis") }

  var body: some View {
    NavigationStack {
      List {
        if let resp = response {
          if resp.entries.isEmpty {
            ContentUnavailableView(
              "Nothing logged on \(SeptenaDate.friendlyLabel(date))",
              systemImage: theme.icon(for: "cannabis"),
              description: Text("If you think an entry got moved here by mistake, check nearby days too.")
            )
          } else {
            Section {
              ForEach(Array(resp.entries.reversed())) { entry in
                Button { editing = entry } label: {
                  LogRow(
                    title: entry.method.capitalized,
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
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { note in
      if note.affectsSection("cannabis") { reload() }
    }
    .sheet(item: $editing) { entry in
      EditCannabisEntrySheet(
        date: date,
        original: entry,
        onSave: { _ in reload() }
      )
    }
  }

  private func reload() {
    response = ChecklistMirror.loadCannabisDay(context: modelContext, date: date)
  }

  private func delete(_ entry: CannabisEntry) {
    cannabis.deleteEntry(id: entry.id)
    reload()
    Haptics.warning()
  }

  private func detailLine(_ e: CannabisEntry) -> String? {
    var parts: [String] = []
    if let hit = e.hit { parts.append(hitDots(hit: hit)) }
    if let g = e.grams, g > 0 { parts.append("\(g.decimalString(2))g") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func hitDots(hit: Int) -> String {
    let total = max(usesPerCapsule, hit)
    let clamped = max(0, min(hit, total))
    return String(repeating: "●", count: clamped)
      + String(repeating: "○", count: total - clamped)
  }
}
