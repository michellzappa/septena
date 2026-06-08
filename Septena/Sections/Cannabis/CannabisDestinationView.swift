import SwiftUI
import SwiftData

// Cannabis mini-app — reads from SwiftData (CloudKit-synced), writes
// through CannabisMutator. Grams = 0.05 per vape use is a hardcoded
// constant; the capsule lifecycle no longer roundtrips through FastAPI.

struct CannabisDestinationView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(SectionTheme.self) private var theme
  @Environment(LogCommitCenter.self) private var logCommit: LogCommitCenter?

  @State private var today: CannabisDayResponse? = nil
  @State private var loading = true
  @State private var editing: CannabisEntry? = nil
  /// Driven by `CannabisPlugin.logActions`: tapping "Log vape" / "Log
  /// edible" sets this to the method id; the sheet opens in create mode
  /// with `presetMethod` seeded.
  @State private var loggingMethod: LoggingMethod? = nil
  private struct LoggingMethod: Identifiable, Hashable {
    let method: String
    var id: String { method }
  }
  /// Day the drawer is currently viewing — driven by the drawer's
  /// `currentDate` date strip. Defaults to today.
  @State private var viewingDate: String = SeptenaDate.today

  /// Capsule dot count for the legacy HitDots indicator.
  /// 3 uses × 0.05g = 0.15g per capsule (Storz & Bickel default).
  private let usesPerCapsule: Int = 3

  private var cannabis: CannabisMutator { SeptenaServices.shared.cannabisMutator }

  private var accent: Color { theme.color(for: "cannabis") }

  /// The smart vape leading log actions are today-only affordances.
  private var isViewingToday: Bool { viewingDate == SeptenaDate.today }

  var body: some View {
    SectionDrawer(sectionKey: "cannabis",
                  onLog: handleLogAction,
                  leadingLogActions: leadingLogActions,
                  currentDate: $viewingDate) {
      DrawerSection("Today", padding: .none) {
        if let today, !today.entries.isEmpty {
          ForEach(Array(today.entries.reversed())) { entry in
            LogEntryRow(
              title: methodLabel(entry.method),
              detail: detailLine(entry),
              trailing: entry.time,
              tint: accent,
              isSelected: editing?.id == entry.id,
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
    .tint(accent)
    .sectionReload(on: viewingDate, onDataChange: true) { await reload() }
    .adaptiveDetail(item: $editing) { entry in
      EditCannabisEntrySheet(
        date: viewingDate,
        original: entry,
        onSave: { _ in Task { await reload() } }
      )
    }
    .sheet(item: $loggingMethod) { wrap in
      EditCannabisEntrySheet(
        date: viewingDate,
        original: nil,
        presetMethod: wrap.method,
        onSave: { _ in Task { await reload() } }
      )
    }
  }

  private func delete(_ entry: CannabisEntry) {
    cannabis.deleteEntry(id: entry.id)
    Task { await reload() }
    Haptics.warning()
  }

  // Most recent vape today — drives the smart "Continue / New capsule" row,
  // same logic as AddCannabisPage and the dashboard tile menu.
  private var lastVape: CannabisEntry? {
    today?.entries.reversed().first { $0.method == "vape" }
  }
  private var hasActiveCapsule: Bool {
    guard let h = lastVape?.hit else { return false }
    return h >= 1 && h < usesPerCapsule
  }
  private var smartHit: Int { hasActiveCapsule ? (lastVape!.hit! + 1) : 1 }

  /// Smart vape rows injected above the plugin's log actions in the "+" menu.
  /// While a capsule has room we offer *both* "Continue · Hit N" and "New
  /// capsule"; once the last hit filled the capsule we never suggest hit+1 —
  /// only "New capsule". Mirrors the dashboard tile and logs directly (the
  /// fast path). Today only.
  private var leadingLogActions: [LogAction] {
    guard isViewingToday else { return [] }
    var out: [LogAction] = []
    if hasActiveCapsule {
      out.append(LogAction(id: "continue",
                           title: "Continue · Hit \(smartHit)",
                           systemImage: "arrow.clockwise"))
    }
    out.append(LogAction(id: "new-capsule",
                         title: "New capsule",
                         systemImage: "plus.circle"))
    return out
  }

  /// Dispatch table for `CannabisPlugin.logActions` ids (plus the dynamic
  /// "continue" / "new-capsule" leading actions).
  private func handleLogAction(_ id: String) {
    switch id {
    case "continue":
      logVape(hit: smartHit)
    case "new-capsule":
      logVape(hit: 1)
    case "log-vape":   loggingMethod = .init(method: "vape")
    case "log-edible": loggingMethod = .init(method: "edible")
    default:           loggingMethod = .init(method: "vape")
    }
  }

  private func logVape(hit: Int) {
    SectionLog.newLog(section: "cannabis", accent: accent,
                      announce: "Logged vape.", logCommit: logCommit) {
      cannabis.addEntry(date: SeptenaDate.today, time: SeptenaDate.nowHHMM,
                        method: "vape", hit: hit)
      AddInfoSection.cannabis.notifyTilesChanged()
    }
  }

  private func methodLabel(_ m: String) -> String {
    m.capitalized
  }

  private func detailLine(_ e: CannabisEntry) -> String? {
    var parts: [String] = []
    if let hit = e.hit { parts.append(hitDots(hit: hit)) }
    if let g = e.grams, g > 0 { parts.append("\(g.decimalString(2))g") }
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

  private func reload() async {
    let date = viewingDate
    today = await MirrorReader.shared.read {
      ChecklistMirror.loadCannabisDay(context: $0, date: date)
    }
    loading = false
  }
}
