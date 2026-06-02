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
  @State private var history: [GutHistoryPoint] = []
  /// The day the drawer is viewing. Bound to `SectionDrawer`'s
  /// `currentDate` slot so the user can step prev/next from the date
  /// strip and `reload()` re-fetches for that day. Defaults to today.
  @State private var viewingDate: String = SeptenaDate.today

  private var gut: GutMutator { SeptenaServices.shared.gutMutator }

  private var accent: Color { theme.color(for: "gut") }

  /// When the date strip is on a past day, hide the summary + heatmap
  /// and show only the day's log entries.
  private var isViewingToday: Bool { viewingDate == SeptenaDate.today }

  var body: some View {
    SectionDrawer(sectionKey: "gut",
                  title: "Gut",
                  onLog: { _ in creating = true },
                  currentDate: $viewingDate) {
      if isViewingToday {
        summary
      }
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
      if isViewingToday && !history.isEmpty {
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
          },
          // Heatmap tap jumps the drawer's date strip to that day —
          // no more BrowseGutDaySheet detour; the destination itself
          // re-fetches and renders the picked day inline.
          onTapDay: { iso in viewingDate = iso }
        )
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

  private var summary: some View {
    DrawerSection {
      StatStrip(stats: summaryStats)
    }
  }

  private var summaryStats: [Stat] {
    var out: [Stat] = [
      Stat(value: "\(today?.movementCount ?? 0)", label: "today", tint: accent),
    ]
    if let avg = avgBristolToday {
      out.append(Stat(value: String(format: "%.1f", avg),
                      label: "avg Bristol"))
    }
    if let d = today?.totalDiscomfortH, d > 0 {
      out.append(Stat(value: String(format: "%.1f", d),
                      label: "discomfort",
                      tint: .orange,
                      unit: "h"))
    }
    return out
  }

  private var avgBristolToday: Double? {
    guard let entries = today?.entries, !entries.isEmpty else { return nil }
    let sum = entries.reduce(0) { $0 + Double($1.bristol) }
    return sum / Double(entries.count)
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
    history = ChecklistMirror.loadGutHistory(context: modelContext, days: 365).daily
    loading = false
  }
}
