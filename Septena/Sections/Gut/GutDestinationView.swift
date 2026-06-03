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
  @State private var creating: Bool = false
  /// The day the drawer is viewing. Bound to `SectionDrawer`'s
  /// `currentDate` slot so the user can step prev/next from the date
  /// strip and `reload()` re-fetches for that day. Defaults to today.
  @State private var viewingDate: String = SeptenaDate.today

  private var gut: GutMutator { SeptenaServices.shared.gutMutator }

  private var accent: Color { theme.color(for: "gut") }

  var body: some View {
    SectionDrawer(sectionKey: "gut",
                  title: "Gut",
                  onLog: { _ in creating = true },
                  currentDate: $viewingDate) {
      DrawerSection("Today", padding: .none) {
        if let today, !today.entries.isEmpty {
          ForEach(Array(today.entries.reversed())) { entry in
            LogEntryRow(
              title: bristolLabel(entry.bristol),
              detail: detailLine(entry),
              trailing: entry.time,
              onEdit: { editing = entry },
              onDelete: { delete(entry) }
            )
          }
        } else if !loading {
          Text("Nothing logged yet.")
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
      }
    }
    .trackScreen("gut")
    .tint(accent)
    .task { reload() }
    .onChange(of: viewingDate) { _, _ in reload() }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in
      reload()
    }
    // Adaptive: sheet on iPhone, docked inspector on iPad/macOS so editing
    // a logged entry keeps the day's log visible alongside it.
    .adaptiveDetail(item: $editing) { entry in
      EditGutEntrySheet(
        date: viewingDate,
        original: entry,
        onSave: { _ in reload() }
      )
    }
    .adaptiveDetail(isPresented: $creating) {
      EditGutEntrySheet(
        date: viewingDate,
        original: nil,
        onSave: { _ in reload() }
      )
    }
  }

  private func delete(_ entry: GutEntry) {
    gut.deleteEntry(id: entry.id)
    reload()
    Haptics.warning()
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
    today = ChecklistMirror.loadGutDay(context: modelContext, date: viewingDate)
    loading = false
  }
}
