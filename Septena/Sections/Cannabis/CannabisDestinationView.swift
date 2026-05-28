import SwiftUI
import SwiftData

// Cannabis mini-app — reads from SwiftData (CloudKit-synced), writes
// through CannabisMutator. Grams = 0.05 per vape use is a hardcoded
// constant; the capsule lifecycle no longer roundtrips through FastAPI.

struct CannabisDestinationView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme

  @State private var today: CannabisDayResponse? = nil
  @State private var loading = true
  @State private var editing: CannabisEntry? = nil
  @State private var managingTypes = false
  /// Driven by `CannabisPlugin.logActions`: tapping "Log vape" / "Log
  /// edible" sets this to the method id; the sheet opens in create mode
  /// with `presetMethod` seeded.
  @State private var loggingMethod: LoggingMethod? = nil
  private struct LoggingMethod: Identifiable, Hashable {
    let method: String
    var id: String { method }
  }
  @State private var history: [CannabisHistoryPoint] = []
  /// Day the drawer is currently viewing — driven by the drawer's
  /// `currentDate` date strip. Defaults to today; heatmap taps jump it
  /// to the picked day.
  @State private var viewingDate: String = SeptenaDate.today

  /// Capsule dot count for the legacy HitDots indicator.
  /// 3 uses × 0.05g = 0.15g per capsule (Storz & Bickel default).
  private let usesPerCapsule: Int = 3

  private var cannabis: CannabisMutator { SeptenaServices.shared.cannabisMutator }

  private var accent: Color { theme.color(for: "cannabis") }

  var body: some View {
    SectionDrawer(sectionKey: "cannabis",
                  title: "Cannabis",
                  onLog: handleLogAction,
                  currentDate: $viewingDate) {
      summary
      DrawerSection("Today", padding: .none) {
        if let today, !today.entries.isEmpty {
          ForEach(Array(today.entries.reversed())) { entry in
            LogEntryRow(
              title: methodLabel(entry.method),
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
      if !history.isEmpty {
        ActivityHeatmapSection(
          title: "Cannabis days",
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
          },
          onTapDay: { iso in viewingDate = iso }
        )
      }
    }
    .trackScreen("cannabis")
    .tint(accent)
    .task { reload() }
    .onChange(of: viewingDate) { _, _ in reload() }
    .sheet(isPresented: $managingTypes) {
      CannabisTypeSheet()
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }
    .sheet(item: $editing) { entry in
      EditCannabisEntrySheet(
        date: viewingDate,
        original: entry,
        onSave: { _ in reload() }
      )
    }
    .sheet(item: $loggingMethod) { wrap in
      EditCannabisEntrySheet(
        date: viewingDate,
        original: nil,
        presetMethod: wrap.method,
        onSave: { _ in reload() }
      )
    }
    .onReceive(NotificationCenter.default.publisher(for: .septenaDataChanged)) { _ in
      reload()
    }
  }

  private func delete(_ entry: CannabisEntry) {
    cannabis.deleteEntry(id: entry.id)
    reload()
    Haptics.warning()
  }

  /// Dispatch table for `CannabisPlugin.logActions` ids.
  private func handleLogAction(_ id: String) {
    switch id {
    case "log-vape":   loggingMethod = .init(method: "vape")
    case "log-edible": loggingMethod = .init(method: "edible")
    case "manage":     managingTypes = true
    default:           loggingMethod = .init(method: "vape")
    }
  }

  private var summary: some View {
    DrawerSection {
      StatStrip(stats: summaryStats)
    }
  }

  private var summaryStats: [Stat] {
    var out: [Stat] = [
      Stat(value: "\(today?.sessionCount ?? 0)", label: "today", tint: accent),
    ]
    if let g = today?.totalG, g > 0 {
      out.append(Stat(value: String(format: "%.2f", g),
                      label: "grams", tint: accent, unit: "g"))
    }
    return out
  }

  private func methodLabel(_ m: String) -> String {
    m.capitalized
  }

  private func detailLine(_ e: CannabisEntry) -> String? {
    var parts: [String] = []
    if let s = e.strain, !s.isEmpty { parts.append(s) }
    if let hit = e.hit { parts.append(hitDots(hit: hit)) }
    if let g = e.grams, g > 0 { parts.append(String(format: "%.2fg", g)) }
    if let eff = e.effect, !eff.isEmpty { parts.append(eff) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  // Mirrors the webapp's HitDots (cannabis-dashboard.tsx): filled circles for
  // hits taken, hollow for remaining slots in the capsule.
  private func hitDots(hit: Int) -> String {
    let total = max(usesPerCapsule, hit)
    let clamped = max(0, min(hit, total))
    return String(repeating: "●", count: clamped)
      + String(repeating: "○", count: total - clamped)
  }

  private func reload() {
    today = ChecklistMirror.loadCannabisDay(context: modelContext, date: viewingDate)
    history = ChecklistMirror.loadCannabisHistory(context: modelContext, days: 365).daily
    loading = false
  }
}
